#ifndef FOC_H
#define FOC_H

#include <stdint.h>
#include <stdbool.h>

/*
 * Field-Oriented Control (FOC) for 3-phase BLDC motor.
 *
 * Motor parameters — adjust for your motor:
 *   MOTOR_POLE_PAIRS  : electrical / mechanical angle ratio
 *   SHUNT_R_OHMS      : current sense shunt resistance (Ω)
 *   INA240_GAIN       : INA240 amplifier gain (20, 50, 100, or 200 V/V)
 *   VDC_V             : DC bus voltage (V)
 *   IQ_MAX_A          : peak allowed phase current (A)
 */

#define MOTOR_POLE_PAIRS  7U
#define ENCODER_CPR       4096U   /* 4× quadrature × 1024 PPR */
#define FOC_FS_HZ         10000U  /* FOC loop rate (= PWM freq) */
#define FOC_DT            (1.0f / (float)FOC_FS_HZ)

#define SHUNT_R_OHMS      0.01f   /* 10 mΩ */
#define INA240_GAIN       50.0f   /* INA240A2 variant */
#define ADC_VREF_MV       1800.0f /* 1.8 V ADC reference */
#define ADC_MIDPOINT      2048    /* zero-current ADC code (INA240 REF = VCC/2) */
#define VDC_V             24.0f   /* DC bus voltage */
#define IQ_MAX_A          5.0f    /* peak current per axis */

/* Motor control modes */
#define MOTOR_MODE_OFF      0
#define MOTOR_MODE_SPEED    1
#define MOTOR_MODE_ANGLE    2
#define MOTOR_MODE_OPENLOOP 3   /* open-loop: setpoint = q-axis voltage in V */

/* Motor states */
#define MOTOR_STATE_OFF   0
#define MOTOR_STATE_RUN   1
#define MOTOR_STATE_FAULT 2

/* Snapshot of motor state for RPMsg reporting */
struct foc_status {
	uint16_t adc_raw[2];   /* raw ADC readings (IA, IB) */
	float    speed_rads;   /* mechanical speed (rad/s) */
	float    angle_rad;    /* mechanical angle [0, 2π) */
	float    id_ma;        /* d-axis current (mA) */
	float    iq_ma;        /* q-axis current (mA) */
	uint8_t  state;
	uint8_t  fault;
};

/* Initialise FOC — call after PWM and ADC are ready */
int  m33_foc_init(void);

/* Set the control target from RPMsg (called from any thread) */
void m33_foc_set_command(uint8_t mode, float setpoint);

/* Retrieve latest motor status for reporting (thread-safe snapshot) */
void m33_foc_get_status(struct foc_status *out);

/* FOC step — called from TIM2 update ISR at FOC_FS_HZ (ISR-safe only) */
void m33_foc_step(void);

#endif /* FOC_H */
