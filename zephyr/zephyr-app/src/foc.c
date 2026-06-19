/*
 * Field-Oriented Control (FOC) for 3-phase BLDC motor.
 *
 * Control structure (runs at FOC_FS_HZ = 10 kHz from TIM2 update ISR):
 *
 *   ADC (Ia, Ib) ──► Clarke ──► Park(θ_e) ──► PI(Id,Iq) ──► inv.Park ──► SVPWM
 *                                                                            │
 *   Encoder ──────────────────────────────────────────────────────────────── θ_e
 *
 * Outer loops (run every SPEED_LOOP_DIV FOC cycles = 1 kHz):
 *   Speed mode  : PI speed controller → Iq reference
 *   Angle mode  : P position controller → ω reference → PI speed → Iq reference
 *
 * Current conversion (INA240 bidirectional current sensor):
 *   I = (ADC - ADC_MIDPOINT) × (VREF / 4095) / (GAIN × SHUNT_R)
 *
 * SVPWM uses zero-sequence injection (equivalent to SV-PWM, no sector lookup).
 */

#include "foc.h"
#include "pwm.h"
#include "encoder.h"

#include <math.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <stm32mp2xx_ll_adc.h>   /* ADC3_NS, LL_ADC_CHANNEL_9/6, etc. */

LOG_MODULE_REGISTER(m33_foc, LOG_LEVEL_INF);

#define SPEED_LOOP_DIV  10U   /* outer loop runs every 10 FOC cycles = 1 kHz */
#define TWO_PI          6.283185307f
#define SQRT3           1.732050808f
#define INV_SQRT3       0.577350269f

/* ── PI controller ─────────────────────────────────────────────────────────── */

typedef struct {
	float kp, ki;
	float integral;
	float out_min, out_max;
} pi_t;

static float pi_step(pi_t *c, float err, float dt)
{
	float out = c->kp * err + c->ki * c->integral;

	/* Clamp with anti-windup: stop integrating when saturated */
	if (out > c->out_max) {
		return c->out_max;
	} else if (out < c->out_min) {
		return c->out_min;
	}
	c->integral += err * dt;
	return out;
}

static void pi_reset(pi_t *c)
{
	c->integral = 0.0f;
}

/* ── Motor state ────────────────────────────────────────────────────────────── */

static volatile uint8_t  cmd_mode;       /* written by RPMsg thread */
static volatile float    cmd_setpoint;   /* written by RPMsg thread */

/* Current PI controllers (d and q axes) */
static pi_t pi_id = { .kp = 2.0f, .ki = 500.0f, .out_min = -VDC_V, .out_max = VDC_V };
static pi_t pi_iq = { .kp = 2.0f, .ki = 500.0f, .out_min = -VDC_V, .out_max = VDC_V };

/* Speed PI controller */
static pi_t pi_spd = { .kp = 0.5f, .ki = 2.0f,
	.out_min = -IQ_MAX_A, .out_max = IQ_MAX_A };

/* Position P controller (gain only, no integral) */
#define KP_POS  3.0f

/* Outer loop rate (rad/s limit to prevent runaway from position P) */
#define OMEGA_MAX  100.0f   /* 100 rad/s mechanical ~ 955 RPM */

static float     iq_ref;    /* q-axis current reference (A) */
static int32_t   prev_enc;  /* encoder position at previous FOC tick */
static uint8_t   outer_cnt; /* outer loop divider counter */
static uint8_t   state;     /* MOTOR_STATE_xxx */

/* Status snapshot (written in ISR, read by RPMsg thread) */
static struct foc_status snap;

/* ── Math helpers ────────────────────────────────────────────────────────────── */

static inline float adc_to_current(uint16_t raw)
{
	float v = ((float)raw - ADC_MIDPOINT) * (ADC_VREF_MV / 1000.0f) / 4095.0f;
	return v / (INA240_GAIN * SHUNT_R_OHMS) * 1000.0f; /* result in mA */
}

static inline float fclampf(float v, float lo, float hi)
{
	return v < lo ? lo : (v > hi ? hi : v);
}

/* Clarke transform: 3-phase → αβ frame (Ic = -Ia - Ib via KCL) */
static inline void clarke(float ia_ma, float ib_ma, float *ialpha, float *ibeta)
{
	*ialpha = ia_ma;
	*ibeta  = (ia_ma + 2.0f * ib_ma) * INV_SQRT3;
}

/* Park transform: αβ → dq rotating frame */
static inline void park(float ia, float ib, float cos_t, float sin_t,
			float *id, float *iq)
{
	*id =  ia * cos_t + ib * sin_t;
	*iq = -ia * sin_t + ib * cos_t;
}

/* Inverse Park: dq → αβ */
static inline void inv_park(float vd, float vq, float cos_t, float sin_t,
			     float *va, float *vb)
{
	*va = vd * cos_t - vq * sin_t;
	*vb = vd * sin_t + vq * cos_t;
}

/*
 * SVPWM via zero-sequence injection.
 * Inputs  : Vα, Vβ (V), Vdc (V)
 * Outputs : duty_a/b/c in [0 … PWM_ARR]
 */
static void svpwm(float valpha, float vbeta, float vdc,
		  uint16_t *da, uint16_t *db, uint16_t *dc)
{
	/* Inverse Clarke to get 3-phase voltages */
	float va =  valpha;
	float vb = -0.5f * valpha + (SQRT3 * 0.5f) * vbeta;
	float vc = -0.5f * valpha - (SQRT3 * 0.5f) * vbeta;

	/* Zero-sequence injection for center-aligned SVM */
	float vmin = va < vb ? (va < vc ? va : vc) : (vb < vc ? vb : vc);
	float vmax = va > vb ? (va > vc ? va : vc) : (vb > vc ? vb : vc);
	float v0   = -(vmin + vmax) * 0.5f;

	float half = vdc * 0.5f;
	float fa = fclampf((va + v0 + half) / vdc, 0.0f, 1.0f);
	float fb = fclampf((vb + v0 + half) / vdc, 0.0f, 1.0f);
	float fc = fclampf((vc + v0 + half) / vdc, 0.0f, 1.0f);

	*da = (uint16_t)(fa * (float)PWM_ARR);
	*db = (uint16_t)(fb * (float)PWM_ARR);
	*dc = (uint16_t)(fc * (float)PWM_ARR);
}

/* ── ADC read for ISR (no k_busy_wait, bare counter loop) ───────────────────── */

static bool foc_adc_read(uint16_t raw[2])
{
	ADC_TypeDef *adc = ADC3_NS;
	uint32_t t;

	/* Channel 9 — PC7 (Ia) */
	LL_ADC_REG_SetSequencerRanks(adc, LL_ADC_REG_RANK_1, LL_ADC_CHANNEL_9);
	adc->ISR = ADC_ISR_EOC | ADC_ISR_OVR | ADC_ISR_EOS;
	LL_ADC_REG_StartConversion(adc);
	for (t = 1000U; t && !(adc->ISR & ADC_ISR_EOC); t--) {
	}
	if (!t) { return false; }
	raw[0] = (uint16_t)(adc->DR & 0xFFFFU);

	/* Channel 6 — PF11 (Ib) */
	LL_ADC_REG_SetSequencerRanks(adc, LL_ADC_REG_RANK_1, LL_ADC_CHANNEL_6);
	adc->ISR = ADC_ISR_EOC | ADC_ISR_OVR | ADC_ISR_EOS;
	LL_ADC_REG_StartConversion(adc);
	for (t = 1000U; t && !(adc->ISR & ADC_ISR_EOC); t--) {
	}
	if (!t) { return false; }
	raw[1] = (uint16_t)(adc->DR & 0xFFFFU);

	return true;
}

/* ── Public API ─────────────────────────────────────────────────────────────── */

int m33_foc_init(void)
{
	cmd_mode     = MOTOR_MODE_OFF;
	cmd_setpoint = 0.0f;
	iq_ref       = 0.0f;
	prev_enc     = m33_encoder_get_position();
	outer_cnt    = 0;
	state        = MOTOR_STATE_OFF;
	memset(&snap, 0, sizeof(snap));

	LOG_INF("FOC init — pole_pairs=%u encoder_cpr=%u fs=%u Hz",
		MOTOR_POLE_PAIRS, ENCODER_CPR, FOC_FS_HZ);
	return 0;
}

void m33_foc_set_command(uint8_t mode, float setpoint)
{
	cmd_mode     = mode;
	cmd_setpoint = setpoint;

	if (mode == MOTOR_MODE_OFF || mode == MOTOR_MODE_OPENLOOP) {
		pi_reset(&pi_id);
		pi_reset(&pi_iq);
		pi_reset(&pi_spd);
		iq_ref = 0.0f;
	}
}

void m33_foc_get_status(struct foc_status *out)
{
	/* Disable IRQ briefly for a consistent snapshot */
	unsigned int key = irq_lock();
	*out = snap;
	irq_unlock(key);
}

/* ── FOC step (called from TIM2 update ISR at 10 kHz) ───────────────────────── */

void m33_foc_step(void)
{
	uint16_t raw[2];
	uint16_t da, db, dc;

	/* --- Open-loop mode: bypass current sensing, apply fixed Vq --------- */
	if (cmd_mode == MOTOR_MODE_OPENLOOP) {
		int32_t enc_now  = m33_encoder_get_position();
		int32_t enc_diff = enc_now - prev_enc;
		prev_enc         = enc_now;

		int32_t pos_mod  = ((enc_now % (int32_t)ENCODER_CPR) + ENCODER_CPR)
				   % (int32_t)ENCODER_CPR;
		float mech_angle = (float)pos_mod * TWO_PI / (float)ENCODER_CPR;
		float speed_rads = (float)enc_diff * TWO_PI / (float)ENCODER_CPR / FOC_DT;
		float elec_angle = fmodf(mech_angle * (float)MOTOR_POLE_PAIRS, TWO_PI);
		float cos_t      = cosf(elec_angle);
		float sin_t      = sinf(elec_angle);

		if (state != MOTOR_STATE_RUN) {
			state = MOTOR_STATE_RUN;
			m33_pwm_enable(true);
		}

		float vq = fclampf(cmd_setpoint, -VDC_V / SQRT3, VDC_V / SQRT3);
		float valpha, vbeta;
		inv_park(0.0f, vq, cos_t, sin_t, &valpha, &vbeta);
		svpwm(valpha, vbeta, VDC_V, &da, &db, &dc);
		m33_pwm_set_duty3(da, db, dc);

		snap.adc_raw[0] = 0;
		snap.adc_raw[1] = 0;
		snap.speed_rads = speed_rads;
		snap.angle_rad  = mech_angle;
		snap.id_ma      = 0.0f;
		snap.iq_ma      = 0.0f;
		snap.state      = state;
		snap.fault      = 0;
		return;
	}

	/* --- Sample currents (closed-loop modes only) ------------------------ */
	if (!foc_adc_read(raw)) {
		state = MOTOR_STATE_FAULT;
		m33_pwm_enable(false);
		return;
	}

	float ia_ma = adc_to_current(raw[0]);
	float ib_ma = adc_to_current(raw[1]);

	/* --- Encoder: mechanical angle and speed ----------------------------- */
	int32_t enc_now  = m33_encoder_get_position();
	int32_t enc_diff = enc_now - prev_enc;
	prev_enc         = enc_now;

	int32_t pos_mod   = ((enc_now % (int32_t)ENCODER_CPR) + ENCODER_CPR)
			    % (int32_t)ENCODER_CPR;
	float mech_angle  = (float)pos_mod * TWO_PI / (float)ENCODER_CPR;
	float speed_rads  = (float)enc_diff * TWO_PI / (float)ENCODER_CPR / FOC_DT;

	/* --- Electrical angle ------------------------------------------------ */
	float elec_angle  = fmodf(mech_angle * (float)MOTOR_POLE_PAIRS, TWO_PI);
	float cos_t = cosf(elec_angle);
	float sin_t = sinf(elec_angle);

	/* --- Clarke → Park --------------------------------------------------- */
	float ialpha, ibeta;
	clarke(ia_ma, ib_ma, &ialpha, &ibeta);

	float id_ma, iq_ma;
	park(ialpha, ibeta, cos_t, sin_t, &id_ma, &iq_ma);
	/* Convert mA → A for PI controllers (iq_ref is in A from IQ_MAX_A) */
	float id_A = id_ma * 0.001f;
	float iq_A = iq_ma * 0.001f;

	/* --- Outer loop (1 kHz) ---------------------------------------------- */
	uint8_t mode = cmd_mode;

	if (++outer_cnt >= SPEED_LOOP_DIV) {
		outer_cnt = 0;
		float dt_outer = FOC_DT * (float)SPEED_LOOP_DIV;

		if (mode == MOTOR_MODE_SPEED) {
			iq_ref = pi_step(&pi_spd, cmd_setpoint - speed_rads, dt_outer);

		} else if (mode == MOTOR_MODE_ANGLE) {
			float angle_err = cmd_setpoint - mech_angle;
			while (angle_err >  3.14159265f) { angle_err -= TWO_PI; }
			while (angle_err < -3.14159265f) { angle_err += TWO_PI; }
			float omega_ref = fclampf(KP_POS * angle_err, -OMEGA_MAX, OMEGA_MAX);
			iq_ref = pi_step(&pi_spd, omega_ref - speed_rads, dt_outer);

		} else {
			iq_ref = 0.0f;
			pi_reset(&pi_spd);
		}
	}

	/* --- Current controllers (inner loop, 10 kHz) ------------------------ */
	if (mode == MOTOR_MODE_OFF) {
		m33_pwm_set_duty3(0, 0, 0);
		if (state == MOTOR_STATE_RUN) {
			m33_pwm_enable(false);
			state = MOTOR_STATE_OFF;
			pi_reset(&pi_id);
			pi_reset(&pi_iq);
		}
	} else {
		if (state != MOTOR_STATE_RUN) {
			state = MOTOR_STATE_RUN;
			m33_pwm_enable(true);
		}

		float vd = pi_step(&pi_id,  0.0f - id_A,       FOC_DT);
		float vq = pi_step(&pi_iq, iq_ref - iq_A,      FOC_DT);

		/* Voltage magnitude limit */
		float v_lim = VDC_V / SQRT3;
		float vmag2 = vd * vd + vq * vq;
		if (vmag2 > v_lim * v_lim) {
			float scale = v_lim / sqrtf(vmag2);
			vd *= scale;
			vq *= scale;
		}

		float valpha, vbeta;
		inv_park(vd, vq, cos_t, sin_t, &valpha, &vbeta);

		svpwm(valpha, vbeta, VDC_V, &da, &db, &dc);
		m33_pwm_set_duty3(da, db, dc);
	}

	/* --- Update status snapshot ------------------------------------------ */
	snap.adc_raw[0] = raw[0];
	snap.adc_raw[1] = raw[1];
	snap.speed_rads = speed_rads;
	snap.angle_rad  = mech_angle;
	snap.id_ma      = id_ma;
	snap.iq_ma      = iq_ma;
	snap.state      = state;
	snap.fault = 0;
}
