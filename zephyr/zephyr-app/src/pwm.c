/*
 * 3-phase PWM driver for STM32MP257F M33 — TIM2 direct LL HAL access.
 *
 * Hardware:
 *   TIM2_NS  (32-bit GP timer, RIFSC CID2, APB1)
 *   Center-aligned mode 3 (CMS=11): compare flags on both up and down counts.
 *   ARR=9999, PSC=0 → 200 MHz / (2×10000) = 10 kHz switching frequency.
 *
 *   CH4 → PA5  (GPIOA pin 5,  CID2, AF8 = TIM2_CH4) — Phase A hardware PWM
 *   CH2 → PF13 (GPIOF pin 13, CID2, GPIO output)    — Phase B software PWM
 *   CH3 → PF14 (GPIOF pin 14, CID2, GPIO output)    — Phase C software PWM
 *   EN  — no hardware pin; tie bridge enable to 3V3, use duty=0 to disable
 *
 * Phases B and C are in the same GPIOF port, so the update ISR sets both
 * high with a single atomic BSRR write at the start of each 100 µs period.
 *
 * Software phase center-aligned equivalence:
 *   Update ISR (CNT=0):         SET   pin high  (start of pulse)
 *   CCx ISR (CNT=CCRx, up):     CLEAR pin low   (end of first half)
 *   CCx ISR (CNT=CCRx, down):   SET   pin high  (start of second half)
 *
 * Why only one hardware channel: PA5 (TIM2_CH4, AF8) is the only CID2-accessible
 * pin with a TIM2 AF on this board. All other TIM2 AF pins are CID1.
 */

#include "pwm.h"

#include <zephyr/kernel.h>
#include <zephyr/irq.h>
#include <zephyr/logging/log.h>

#include <stm32mp2xx_ll_tim.h>

LOG_MODULE_REGISTER(m33_pwm, LOG_LEVEL_INF);

/* ── GPIO direct-register macros ──────────────────────────────────────────── */

/* GPIOA: PA5 (TIM2_CH1 AF1) */
#define GPIOA_MODER  (*(volatile uint32_t *)(GPIOA_BASE_NS + 0x00UL))
#define GPIOA_AFRL   (*(volatile uint32_t *)(GPIOA_BASE_NS + 0x20UL))

/* GPIOF: PF13 (phase B), PF14 (phase C) */
#define PWM_GPIOF_MODER  (*(volatile uint32_t *)(GPIOF_BASE_NS + 0x00UL))
#define GPIOF_ODR    (*(volatile uint32_t *)(GPIOF_BASE_NS + 0x14UL))
#define GPIOF_BSRR   (*(volatile uint32_t *)(GPIOF_BASE_NS + 0x18UL))

/* BSRR: bits [15:0] set pin, bits [31:16] reset pin */
#define PF13_SET  (1UL << 13)
#define PF13_CLR  (1UL << 29)
#define PF14_SET  (1UL << 14)
#define PF14_CLR  (1UL << 30)
/* Combined: set/clear both phases B and C at once */
#define PF13_14_SET  (PF13_SET | PF14_SET)
#define PF13_14_CLR  (PF13_CLR | PF14_CLR)

/* ── RCC TIM2 clock enable ────────────────────────────────────────────────── */
#define RCC_TIM2CFGR  (*(volatile uint32_t *)(RCC_BASE_NS + 0x704UL))
#define RCC_TIM2_EN   (1UL << 1)

/* ── Module state ─────────────────────────────────────────────────────────── */

static pwm_foc_cb_t  foc_callback;
static volatile uint16_t shadow_b;
static volatile uint16_t shadow_c;
static volatile bool     enabled;

/* ── ISR ──────────────────────────────────────────────────────────────────── */

static void tim2_isr(const void *arg)
{
	ARG_UNUSED(arg);
	uint32_t sr = TIM2_NS->SR;

	/* Update event — CMS=11 fires UIF at both CNT=0 (underflow, DIR→0)
	 * and CNT=ARR (overflow, DIR→1).  We only want the 10 kHz underflow
	 * event; skip the 10 kHz overflow event to avoid 20 kHz ISR rate. */
	if (sr & TIM_SR_UIF) {
		TIM2_NS->SR = ~TIM_SR_UIF;

		if (!(TIM2_NS->CR1 & TIM_CR1_DIR)) {
			/* Underflow (CNT=0): start of new PWM period — set phases high */
			if (enabled) {
				uint32_t bsrr = 0;
				if (shadow_b > 0) { bsrr |= PF13_SET; } else { bsrr |= PF13_CLR; }
				if (shadow_c > 0) { bsrr |= PF14_SET; } else { bsrr |= PF14_CLR; }
				GPIOF_BSRR = bsrr;
			} else {
				GPIOF_BSRR = PF13_14_CLR;
			}

			if (foc_callback) {
				foc_callback();
			}
		}
	}

	/* CH2 compare event — Phase B (PF13) */
	if (sr & TIM_SR_CC2IF) {
		TIM2_NS->SR = ~TIM_SR_CC2IF;
		if (enabled) {
			GPIOF_BSRR = (TIM2_NS->CR1 & TIM_CR1_DIR) ? PF13_SET : PF13_CLR;
		}
	}

	/* CH3 compare event — Phase C (PF14) */
	if (sr & TIM_SR_CC3IF) {
		TIM2_NS->SR = ~TIM_SR_CC3IF;
		if (enabled) {
			GPIOF_BSRR = (TIM2_NS->CR1 & TIM_CR1_DIR) ? PF14_SET : PF14_CLR;
		}
	}
}

/* ── Public API ───────────────────────────────────────────────────────────── */

int m33_pwm_init(pwm_foc_cb_t foc_cb)
{
	foc_callback = foc_cb;
	shadow_b     = 0;
	shadow_c     = 0;
	enabled      = false;

	/* 1. Enable TIM2 bus clock */
	RCC_TIM2CFGR |= RCC_TIM2_EN;
	k_busy_wait(5);

	/* Stop the counter unconditionally — it may still be running from a
	 * previous firmware load (M33 reset does not automatically halt TIM2). */
	LL_TIM_DisableCounter(TIM2_NS);
	TIM2_NS->SR = 0;

	/* 2. Configure PA5 (TIM2_CH4) as AF8 */
	GPIOA_MODER = (GPIOA_MODER & ~(3UL << (5 * 2))) | (2UL << (5 * 2));
	GPIOA_AFRL  = (GPIOA_AFRL  & ~(0xFUL << (5 * 4))) | (8UL << (5 * 4));
	{
		uint32_t ma = GPIOA_MODER;
		uint32_t fa = GPIOA_AFRL;
		LOG_INF("PA5 check: MODER_A=0x%08x PA5mode=%u AFRL_A=0x%08x PA5af=%u",
			ma, (ma >> (5 * 2)) & 3U, fa, (fa >> (5 * 4)) & 0xFU);
	}

	/* 3. Configure PF13 and PF14 as GPIO outputs (mode=01) */
	PWM_GPIOF_MODER = (PWM_GPIOF_MODER
		& ~((3UL << (13 * 2)) | (3UL << (14 * 2))))
		|  ((1UL << (13 * 2)) | (1UL << (14 * 2)));
	GPIOF_BSRR = PF13_14_CLR;

	/* Verify GPIO config: drive both pins HIGH, read back ODR, then clear */
	GPIOF_BSRR = PF13_14_SET;
	k_busy_wait(10);
	uint32_t moder_chk = PWM_GPIOF_MODER;
	uint32_t odr_chk   = GPIOF_ODR;
	GPIOF_BSRR = PF13_14_CLR;
	LOG_INF("GPIO check: MODER=0x%08x PF13mode=%u PF14mode=%u ODR_PF13=%u ODR_PF14=%u",
		moder_chk,
		(moder_chk >> (13 * 2)) & 3U,
		(moder_chk >> (14 * 2)) & 3U,
		(odr_chk >> 13) & 1U,
		(odr_chk >> 14) & 1U);

	/* 4. Configure TIM2 */
	LL_TIM_SetPrescaler(TIM2_NS, 0);
	LL_TIM_SetAutoReload(TIM2_NS, PWM_ARR);
	LL_TIM_SetCounterMode(TIM2_NS, LL_TIM_COUNTERMODE_CENTER_UP_DOWN);
	LL_TIM_EnableARRPreload(TIM2_NS);

	/* CH4 (PA5): PWM mode 1 — Phase A hardware */
	LL_TIM_OC_SetMode(TIM2_NS, LL_TIM_CHANNEL_CH4, LL_TIM_OCMODE_PWM1);
	LL_TIM_OC_EnablePreload(TIM2_NS, LL_TIM_CHANNEL_CH4);
	LL_TIM_OC_SetCompareCH4(TIM2_NS, 0);
	LL_TIM_CC_EnableChannel(TIM2_NS, LL_TIM_CHANNEL_CH4);
	{
		uint32_t ccmr2 = TIM2_NS->CCMR2;
		uint32_t ccer  = TIM2_NS->CCER;
		LOG_INF("TIM2 CH4: CCMR2=0x%08x OC4M=%u CC4E=%u",
			ccmr2, (ccmr2 >> 12) & 0xFU, (ccer >> 12) & 1U);
	}

	/* CH2: frozen compare-only — Phase B software (PF13) */
	LL_TIM_OC_SetMode(TIM2_NS, LL_TIM_CHANNEL_CH2, LL_TIM_OCMODE_FROZEN);
	LL_TIM_OC_EnablePreload(TIM2_NS, LL_TIM_CHANNEL_CH2);
	LL_TIM_OC_SetCompareCH2(TIM2_NS, 0);
	LL_TIM_CC_EnableChannel(TIM2_NS, LL_TIM_CHANNEL_CH2);

	/* CH3: frozen compare-only — Phase C software (PF14) */
	LL_TIM_OC_SetMode(TIM2_NS, LL_TIM_CHANNEL_CH3, LL_TIM_OCMODE_FROZEN);
	LL_TIM_OC_EnablePreload(TIM2_NS, LL_TIM_CHANNEL_CH3);
	LL_TIM_OC_SetCompareCH3(TIM2_NS, 0);
	LL_TIM_CC_EnableChannel(TIM2_NS, LL_TIM_CHANNEL_CH3);

	/* 5. Generate update event to latch preload registers, then clear flags */
	LL_TIM_GenerateEvent_UPDATE(TIM2_NS);
	TIM2_NS->SR = 0;

	/* 6. Enable update, CC2 (phase B), CC3 (phase C) interrupts */
	LL_TIM_EnableIT_UPDATE(TIM2_NS);
	LL_TIM_EnableIT_CC2(TIM2_NS);
	LL_TIM_EnableIT_CC3(TIM2_NS);

	/* 7. Register ISR — irq_enable() deferred to m33_pwm_start() */
	IRQ_CONNECT(TIM2_IRQn, 1, tim2_isr, NULL, 0);

	LOG_INF("TIM2 PWM init done — PA5=CH4(A) PF13=sw(B) PF14=sw(C), f=%u Hz",
		PWM_FREQ_HZ);
	return 0;
}

void m33_pwm_start(void)
{
	TIM2_NS->SR = 0;
	NVIC_ClearPendingIRQ(TIM2_IRQn);
	irq_enable(TIM2_IRQn);
	LL_TIM_EnableCounter(TIM2_NS);
	LOG_INF("TIM2 10 kHz FOC loop started");
}

void m33_pwm_set_duty3(uint16_t a, uint16_t b, uint16_t c)
{
	if (a > PWM_ARR) a = PWM_ARR;
	if (b > PWM_ARR) b = PWM_ARR;
	if (c > PWM_ARR) c = PWM_ARR;

	LL_TIM_OC_SetCompareCH4(TIM2_NS, a);
	LL_TIM_OC_SetCompareCH2(TIM2_NS, b);
	LL_TIM_OC_SetCompareCH3(TIM2_NS, c);
	shadow_b = b;
	shadow_c = c;
}

void m33_pwm_enable(bool en)
{
	enabled = en;
	if (!en) {
		GPIOF_BSRR = PF13_14_CLR;
		LL_TIM_OC_SetCompareCH4(TIM2_NS, 0);
		LL_TIM_OC_SetCompareCH2(TIM2_NS, 0);
		LL_TIM_OC_SetCompareCH3(TIM2_NS, 0);
		shadow_b = 0;
		shadow_c = 0;
	}
}

void m33_pwm_get_state(uint16_t *a, uint16_t *b, uint16_t *c, bool *en,
		       uint32_t *gpiof_odr)
{
	*a        = (uint16_t)LL_TIM_OC_GetCompareCH4(TIM2_NS);
	*b        = shadow_b;
	*c        = shadow_c;
	*en       = enabled;
	*gpiof_odr = GPIOF_ODR;
}
