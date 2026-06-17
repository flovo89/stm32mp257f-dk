/*
 * ADC3 driver for STM32MP257F M33 — direct LL HAL access.
 *
 * Peripheral ownership: M33/CID2 (RIFSC ADC3_ID = 59, RIF_CID2, RIF_CFEN).
 * ADC12 (RIFSC ID 58) is CID1/A35-only — do NOT use it from M33.
 *
 * Hardware:
 *   ADC3 (NS) @ 0x404F0000
 *   ADC3_COMMON (NS) @ 0x404F0300
 *   RCC_ADC3CFGR @ 0x442007EC
 *   ch0 = ADC3_INP9 → PC7  (expansion connector, GPIOC CID1, reset-ANALOG)
 *   ch1 = ADC3_INP6 → PF11 (expansion connector, GPIOF CID1, reset-ANALOG)
 *
 * Clock: kernel clock = CK_ICN_LS_MCU (200 MHz), prescaler /16 → fADC 12.5 MHz.
 * Resolution: 12-bit.  Software trigger.  Single-channel per conversion.
 *
 * Note: ADC3 has no internal voltage monitor channels (VDDCORE/VDDCPU are
 * only available on ADC2 which is CID1/A35).  Connect an external voltage
 * to PC7 and/or PF11 on the expansion connector to get non-zero readings.
 */

#include "adc.h"

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <stm32mp2xx_ll_adc.h>

LOG_MODULE_REGISTER(m33_adc, LOG_LEVEL_INF);

/* ── Hardware addresses ─────────────────────────────────────────────────── */

/* RCC_BASE_NS = 0x44200000 is defined by CMSIS stm32mp257fxx_cm33.h */

/* ADC3 bus clock + kernel clock select in RCC */
#define RCC_ADC3CFGR         (*(volatile uint32_t *)(RCC_BASE_NS + 0x7ECUL))
#define RCC_ADC3KERSEL_MASK  (3UL << 12)
#define RCC_ADC3KERSEL_ICN   (1UL << 12)  /* CK_ICN_LS_MCU = 0b01 */
#define RCC_ADC3EN           (1UL << 1)

/* GPIOC (PC7 = ADC3_INP9) and GPIOF (PF11 = ADC3_INP6) — both CID1, reset-ANALOG */
#define GPIOC_MODER          (*(volatile uint32_t *)(GPIOC_BASE_NS + 0x00UL))
#define GPIOC_IDR            (*(volatile uint32_t *)(GPIOC_BASE_NS + 0x10UL))
#define GPIOF_MODER          (*(volatile uint32_t *)(GPIOF_BASE_NS + 0x00UL))
#define GPIOF_IDR            (*(volatile uint32_t *)(GPIOF_BASE_NS + 0x10UL))

/* Calibration / enable timeout (in busy-wait loops at ~1 μs/iter) */
#define TIMEOUT_LOOPS        50000U   /* 50 ms */

/* ── Internal helpers ───────────────────────────────────────────────────── */

static int wait_flag_set(volatile uint32_t *reg, uint32_t mask,
			 unsigned int loops)
{
	while (loops--) {
		if (*reg & mask) {
			return 0;
		}
		k_busy_wait(1);
	}
	return -ETIMEDOUT;
}

static int wait_flag_clear(volatile uint32_t *reg, uint32_t mask,
			   unsigned int loops)
{
	while (loops--) {
		if (!(*reg & mask)) {
			return 0;
		}
		k_busy_wait(1);
	}
	return -ETIMEDOUT;
}

/* ── ADC single-channel conversion ─────────────────────────────────────── */

static int read_one(ADC_TypeDef *adc, uint32_t ll_channel, uint16_t *out)
{
	LL_ADC_REG_SetSequencerRanks(adc, LL_ADC_REG_RANK_1, ll_channel);

	/* Clear EOC/OVR/EOS so we wait for THIS conversion, not a stale flag. */
	adc->ISR = ADC_ISR_EOC | ADC_ISR_OVR | ADC_ISR_EOS;

	LL_ADC_REG_StartConversion(adc);

	int rc = wait_flag_set(&adc->ISR, ADC_ISR_EOC, TIMEOUT_LOOPS);

	if (rc < 0) {
		LOG_ERR("ADC EOC timeout (ISR=0x%08x)", adc->ISR);
		LL_ADC_REG_StopConversion(adc);
		return rc;
	}

	*out = (uint16_t)(adc->DR & 0xFFFFU);
	return 0;
}

/* ── Public API ─────────────────────────────────────────────────────────── */

int m33_adc_init(void)
{
	/*
	 * 1. Set GPIO pins to ANALOG mode.
	 *
	 * Do NOT write RCC_GPIOxCFGR here — protected by RCC sub-resource CID
	 * filtering (CID1+semaphore), triggers IAC 156 from M33.  GPIO clocks
	 * are pre-enabled by TF-A.  PC7/PF11 are CID1 pins, so these MODER
	 * writes from M33/CID2 are ignored by RIF — harmless, since both pins
	 * already reset to ANALOG and stay that way (nothing else claims them).
	 */
	GPIOC_MODER |= (3UL << (7 * 2));   /* PC7  = analog (INP9) */
	GPIOF_MODER |= (3UL << (11 * 2));  /* PF11 = analog (INP6) */

	/* Log digital pin states — expected 0 if unconnected, 1 if at 1.8V. */
	LOG_INF("PC7 digital=%u  PF11 digital=%u (0=unconnected/0V, 1=1.8V)",
		(unsigned int)((GPIOC_IDR >> 7) & 1U),
		(unsigned int)((GPIOF_IDR >> 11) & 1U));

	/* 2. Select kernel clock and enable gate.
	 *    ck_flexgen_47 (Linux default, mux=0b00) is unconfigured.
	 *    Use ck_icn_ls_mcu (mux=0b01) — 200 MHz, always running. */
	RCC_ADC3CFGR = (RCC_ADC3CFGR & ~RCC_ADC3KERSEL_MASK) | RCC_ADC3KERSEL_ICN;
	RCC_ADC3CFGR |= RCC_ADC3EN;
	k_busy_wait(5);

	ADC_TypeDef *adc = ADC3_NS;

	/* 3. Exit deep power-down BEFORE touching any ADC register.
	 *    While DEEPPWD=1, all ADC register writes are silently discarded. */
	LL_ADC_DisableDeepPowerDown(adc);
	k_busy_wait(15);

	/* 4. Set prescaler DIV16: 200 MHz / 16 = 12.5 MHz ADC clock. */
	LL_ADC_SetCommonClock(ADC3_COMMON_NS, LL_ADC_CLOCK_DIV16);

	/* 5. Single-ended calibration — non-fatal on timeout.
	 *    Calibration appears to hang on this board (possible VDDA settling
	 *    issue).  Skip and rely on ADRDY to confirm the ADC is functional. */
	LL_ADC_StartCalibration(adc, LL_ADC_SINGLE_ENDED);
	int rc = wait_flag_clear(&adc->CR, ADC_CR_ADCAL, TIMEOUT_LOOPS);

	if (rc < 0) {
		LOG_WRN("ADC3 calibration timeout — skipping");
		LL_ADC_StopCalibration(adc);
		k_busy_wait(5);
	}

	/* 6. Enable ADC */
	LL_ADC_Enable(adc);
	rc = wait_flag_set(&adc->ISR, ADC_ISR_ADRDY, TIMEOUT_LOOPS);
	if (rc < 0) {
		LOG_ERR("ADC3 ADRDY timeout");
		return rc;
	}

	/* 7. One-time sequencer / resolution configuration */
	LL_ADC_REG_SetTriggerSource(adc, LL_ADC_REG_TRIG_SOFTWARE);
	LL_ADC_REG_SetSequencerLength(adc, LL_ADC_REG_SEQ_SCAN_DISABLE);
	LL_ADC_SetResolution(adc, LL_ADC_RESOLUTION_12B);

	/* Pre-select channel 9 (PC7) and channel 6 (PF11) in PCSEL */
	LL_ADC_SetChannelPreselection(adc, LL_ADC_CHANNEL_9);
	LL_ADC_SetChannelPreselection(adc, LL_ADC_CHANNEL_6);

	/* Sampling time: 47.5 cycles (~3.8 μs at 12.5 MHz) */
	LL_ADC_SetChannelSamplingTime(adc, LL_ADC_CHANNEL_9,
				      LL_ADC_SAMPLINGTIME_47CYCLES_5);
	LL_ADC_SetChannelSamplingTime(adc, LL_ADC_CHANNEL_6,
				      LL_ADC_SAMPLINGTIME_47CYCLES_5);

	LOG_INF("ADC3 ready — ch0=PC7/INP9, ch1=PF11/INP6");
	return 0;
}

int m33_adc_read(uint16_t raw[2])
{
	int rc;

	rc = read_one(ADC3_NS, LL_ADC_CHANNEL_9, &raw[0]);
	if (rc < 0) {
		return rc;
	}

	return read_one(ADC3_NS, LL_ADC_CHANNEL_6, &raw[1]);
}
