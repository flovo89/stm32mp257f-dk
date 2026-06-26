/*
 * Pulse generator — TIM2 hardware PWM on PA5 (TIM2_CH4, AF8).
 *
 * TIM2 clock = 200 MHz (confirmed from previous FOC calibration:
 *   PSC=0, ARR=9999, centre-aligned mode → 10 kHz ✓ → f_clk = 200 MHz).
 *
 * Edge-aligned up-count:  f_out = f_clk / (ARR + 1)
 *   ARR = (200 MHz / freq_hz) - 1
 *   CCR4 = (ARR + 1) / 2  →  50 % duty cycle
 *
 * No ISR needed — TIM2 generates the waveform autonomously once started.
 */

#include "pulse_gen.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <stm32mp2xx_ll_tim.h>

LOG_MODULE_REGISTER(pulse_gen, LOG_LEVEL_INF);

#define TIM_CLK_HZ  200000000UL

/* GPIOA direct register access (non-secure alias) */
#define GPIOA_MODER  (*(volatile uint32_t *)(GPIOA_BASE_NS + 0x00UL))
#define GPIOA_AFRL   (*(volatile uint32_t *)(GPIOA_BASE_NS + 0x20UL))
#define GPIOA_BSRR   (*(volatile uint32_t *)(GPIOA_BASE_NS + 0x18UL))

/* RCC: TIM2 clock gate */
#define RCC_TIM2CFGR  (*(volatile uint32_t *)(RCC_BASE_NS + 0x704UL))
#define RCC_TIM2_EN   (1UL << 1)

/* PA5 bit-field helpers */
#define PA5_MODE_MASK  (3UL    << (5 * 2))
#define PA5_MODE_OUT   (1UL    << (5 * 2))  /* GPIO output */
#define PA5_MODE_AF    (2UL    << (5 * 2))  /* Alternate function */
#define PA5_AF_MASK    (0xFUL  << (5 * 4))
#define PA5_AF8        (8UL    << (5 * 4))  /* AF8 = TIM2_CH4 */
#define PA5_BSRR_CLR   (1UL   << (5 + 16)) /* BSRR reset bit → PA5 LOW */

static volatile uint32_t _freq_hz;

/* ── Public API ─────────────────────────────────────────────────────────────── */

void pulse_gen_init(void)
{
	/* Enable TIM2 bus clock */
	RCC_TIM2CFGR |= RCC_TIM2_EN;
	k_busy_wait(5);

	/* Halt any running counter. Clear DIER before SR: DIER persists across
	 * remoteproc restarts; stale UIE from the previous FOC firmware run
	 * causes a spurious TIM2 interrupt on the next GenerateEvent_UPDATE,
	 * which hits Zephyr's spurious-IRQ handler and silently halts the CPU. */
	LL_TIM_DisableCounter(TIM2_NS);
	TIM2_NS->DIER = 0;
	TIM2_NS->SR   = 0;

	/* Edge-aligned up-count with ARR preload */
	LL_TIM_SetCounterMode(TIM2_NS, LL_TIM_COUNTERMODE_UP);
	LL_TIM_SetPrescaler(TIM2_NS, 0);
	LL_TIM_SetAutoReload(TIM2_NS, 0);
	LL_TIM_EnableARRPreload(TIM2_NS);

	/* CH4 (PA5): PWM mode 1 — output HIGH while CNT < CCR4 */
	LL_TIM_OC_SetMode(TIM2_NS, LL_TIM_CHANNEL_CH4, LL_TIM_OCMODE_PWM1);
	LL_TIM_OC_EnablePreload(TIM2_NS, LL_TIM_CHANNEL_CH4);
	LL_TIM_OC_SetCompareCH4(TIM2_NS, 0);
	LL_TIM_CC_EnableChannel(TIM2_NS, LL_TIM_CHANNEL_CH4);

	/* PA5 starts as GPIO output LOW (TIM2 not yet driving it) */
	GPIOA_MODER = (GPIOA_MODER & ~PA5_MODE_MASK) | PA5_MODE_OUT;
	GPIOA_BSRR  = PA5_BSRR_CLR;

	_freq_hz = 0;

	LOG_INF("pulse_gen init — PA5 idle LOW, TIM2 ready");
}

void pulse_gen_set_freq(uint32_t freq_hz)
{
	if (freq_hz == 0) {
		LL_TIM_DisableCounter(TIM2_NS);
		GPIOA_MODER = (GPIOA_MODER & ~PA5_MODE_MASK) | PA5_MODE_OUT;
		GPIOA_BSRR  = PA5_BSRR_CLR;
		_freq_hz = 0;
		LOG_INF("pulse_gen: stopped, PA5 LOW");
		return;
	}

	if (freq_hz > PULSE_MAX_HZ) {
		freq_hz = PULSE_MAX_HZ;
	}

	uint32_t arr = (TIM_CLK_HZ / freq_hz) - 1;
	uint32_t ccr = (arr + 1) / 2;  /* 50 % duty cycle */

	LL_TIM_DisableCounter(TIM2_NS);
	LL_TIM_SetAutoReload(TIM2_NS, arr);
	LL_TIM_OC_SetCompareCH4(TIM2_NS, ccr);
	LL_TIM_GenerateEvent_UPDATE(TIM2_NS);  /* latch ARR and CCR4 preloads */
	TIM2_NS->SR = 0;
	/* Switch PA5 to AF8 (TIM2_CH4) then start the counter */
	GPIOA_AFRL  = (GPIOA_AFRL  & ~PA5_AF_MASK)   | PA5_AF8;
	GPIOA_MODER = (GPIOA_MODER & ~PA5_MODE_MASK) | PA5_MODE_AF;
	TIM2_NS->CR1 |= TIM_CR1_CEN;
	_freq_hz = freq_hz;
	LOG_INF("pulse_gen: %u Hz  ARR=%u CCR=%u", freq_hz, arr, ccr);
}

uint32_t pulse_gen_get_freq(void)   { return _freq_hz; }
bool     pulse_gen_is_enabled(void) { return _freq_hz > 0; }
