/*
 * Triggered ADC sampler — M33 implementation.
 *
 * PF15 (GPIOF pin 15, RIFSC CID2): Zephyr GPIO rising-edge interrupt.
 *   Each rising edge increments an edge counter and (rate-limited) wakes
 *   adc_task to perform an ADC3 conversion.  The ISR itself does NO
 *   peripheral register access and does NOT call k_cycle_get_32() — both
 *   operations cause hangs on STM32MP25 at high interrupt rates due to
 *   bus stalls (ADC3) or nested SysTick preemption via k_spin_lock
 *   (k_cycle_get_32), which corrupts the subsequent TIM2 CR1 enable write.
 *
 * Frequency measurement: performed in sampler_get_in_freq_hz() (thread
 * context) by comparing edge counts over elapsed wall-clock time.
 *
 * ADC3 hardware notes (STM32MP25, confirmed 2026-06-16):
 *   - No hardware self-calibration.  Enable ADC first (ADEN=1, wait ADRDY).
 *     LL_ADC_StartCalibration() must NEVER be called — ADCAL never self-clears
 *     on this SoC and the ADC analog path becomes permanently broken.
 *   - PC7 MODER is CID1; the pin stays ANALOG from POR.  No MODER write needed.
 *   - Do NOT write RCC_GPIOxCFGR.  GPIO clocks are pre-enabled by TF-A.
 *   - ADC3 kernel clock: bits[13:12]=01 in RCC_ADC3CFGR → CK_ICN_LS_MCU.
 *   - ADC3 CCR prescaler /16 → ~12.5 MHz ADC clock.
 *   - Always clear ISR (EOC|OVR|EOS) before starting a conversion.
 */

#include "sampler.h"

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>
#include <stm32mp2xx_ll_adc.h>

LOG_MODULE_REGISTER(sampler, LOG_LEVEL_INF);

/* ── Hardware constants ──────────────────────────────────────────────────────── */

/* ADC3 Common instance (NS base = ADC3_BASE_NS + 0x300) */
#define ADC3_COMMON_NS  ((ADC_Common_TypeDef *)(ADC3_BASE_NS + 0x300UL))

/* RCC_ADC3CFGR at RCC_BASE_NS + 0x7EC
 *   bit 1        = ADC3 bus clock enable
 *   bits [13:12] = kernel clock select (01 = CK_ICN_LS_MCU)
 */
#define RCC_ADC3CFGR         (*(volatile uint32_t *)(RCC_BASE_NS + 0x7ECUL))
#define RCC_ADC3_EN          (1UL << 1)
#define RCC_ADC3_CKSEL_MASK  (3UL << 12)
#define RCC_ADC3_CKSEL_ICN   (1UL << 12)   /* CK_ICN_LS_MCU */

/* ── PF15 GPIO interrupt ─────────────────────────────────────────────────────── */

static const struct gpio_dt_spec _pulse_in =
	GPIO_DT_SPEC_GET(DT_PATH(zephyr_user), pulse_in_gpios);
static struct gpio_callback _gpio_cb;

/* ── Ring buffer (SPSC: adc_task writes at _head, status_task reads at _tail) ── */

static uint16_t   _buf[SAMPLER_RING_SIZE];
static volatile uint32_t _head;   /* write index (adc_task)    */
static volatile uint32_t _tail;   /* read  index (status_task) */

/* ── Edge counter (ISR writes, threads read) ─────────────────────────────────── */

static volatile uint32_t _total_edges;   /* total rising edges seen */

/* ── Frequency EMA (thread context only, updated in sampler_get_in_freq_hz) ──── */

static uint32_t _last_freq_edges;    /* edge count at last frequency update */
static uint32_t _last_freq_cyc;      /* CPU cycle at last frequency update  */
static uint32_t _avg_freq_hz;        /* EMA-smoothed frequency estimate      */

/* ── ADC trigger state (ISR sets pending, adc_task clears it) ───────────────── */

static volatile bool _adc_pending;   /* conversion queued, result not yet stored */

/* ── ADC task (thread context — all ADC3 register access lives here) ─────────── */

static K_SEM_DEFINE(_adc_sem, 0, 1);
static K_THREAD_STACK_DEFINE(_adc_stack, 1024);
static struct k_thread _adc_thread;

static void _adc_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1); ARG_UNUSED(a2); ARG_UNUSED(a3);

	while (1) {
		k_sem_take(&_adc_sem, K_FOREVER);

		ADC3_NS->ISR = ADC_ISR_EOC | ADC_ISR_OVR | ADC_ISR_EOS;
		LL_ADC_REG_StartConversion(ADC3_NS);

		uint32_t timeout = 100000u;
		while (!LL_ADC_IsActiveFlag_EOC(ADC3_NS) && --timeout) {
		}

		if (timeout == 0u) {
			LOG_ERR("ADC3 EOC timeout");
		} else {
			uint16_t raw = (uint16_t)LL_ADC_REG_ReadConversionData12(ADC3_NS);
			uint32_t head = _head;
			_buf[head & (SAMPLER_RING_SIZE - 1u)] = raw;
			_head = head + 1u;
		}
		_adc_pending = false;
	}
}

/* ── GPIO interrupt callback (ISR context — minimal: edge count + ADC wakeup) ── */

static void _edge_cb(const struct device *port, struct gpio_callback *cb,
		     uint32_t pins)
{
	ARG_UNUSED(port); ARG_UNUSED(cb); ARG_UNUSED(pins);

	_total_edges++;

	/* Wake ADC task for a new conversion if none is in progress.
	 * k_sem_give is ISR-safe; _adc_pending avoids double-posting the sem. */
	if (!_adc_pending) {
		_adc_pending = true;
		k_sem_give(&_adc_sem);
	}
}

/* ── ADC3 initialisation ─────────────────────────────────────────────────────── */

static void _adc3_init(void)
{
	/* Enable ADC3 peripheral clock; select CK_ICN_LS_MCU as kernel clock */
	RCC_ADC3CFGR = (RCC_ADC3CFGR & ~RCC_ADC3_CKSEL_MASK)
		       | RCC_ADC3_CKSEL_ICN | RCC_ADC3_EN;
	k_busy_wait(10);

	/* Disable all ADC interrupt sources before touching any other register.
	 * IER persists across remoteproc restarts (no power-cycle), so a
	 * previous firmware run may have left EOCIE or OVR enabled.  An
	 * unexpected ADC EOC IRQ would hit Zephyr's spurious-IRQ handler and
	 * halt the CPU silently while the remoteproc state remains "running". */
	ADC3_NS->IER = 0;

	/* CCR prescaler /16 → ~12.5 MHz ADC clock from CK_ICN_LS_MCU (~200 MHz) */
	LL_ADC_SetCommonClock(ADC3_COMMON_NS, LL_ADC_CLOCK_DIV16);

	/* 12-bit resolution, software trigger, single conversion mode */
	LL_ADC_SetResolution(ADC3_NS, LL_ADC_RESOLUTION_12B);
	LL_ADC_REG_SetTriggerSource(ADC3_NS, LL_ADC_REG_TRIG_SOFTWARE);
	LL_ADC_REG_SetContinuousMode(ADC3_NS, LL_ADC_REG_CONV_SINGLE);

	/* Preselect and configure channel 9 (PC7 / INP9) */
	LL_ADC_SetChannelPreselection(ADC3_NS, LL_ADC_CHANNEL_9);
	LL_ADC_REG_SetSequencerRanks(ADC3_NS, LL_ADC_REG_RANK_1,
				     LL_ADC_CHANNEL_9);

	/*
	 * Enable ADC FIRST, then wait for ADRDY.
	 * Never call LL_ADC_StartCalibration() on STM32MP25 — see file header.
	 * CALFACT = 0 (reset default = no offset correction) is fine here.
	 */
	LL_ADC_Enable(ADC3_NS);
	uint32_t timeout = 100000u;
	while (!LL_ADC_IsActiveFlag_ADRDY(ADC3_NS) && --timeout) {
	}
	if (!timeout) {
		LOG_ERR("ADC3 ADRDY timeout — check RCC_ADC3CFGR (0x%08x)",
			RCC_ADC3CFGR);
		return;
	}

	ADC3_NS->ISR = ADC_ISR_EOC | ADC_ISR_OVR | ADC_ISR_EOS;
	LOG_INF("ADC3 ready (PC7/INP9, 12-bit, ~12.5 MHz clock)");
}

/* ── Public API ──────────────────────────────────────────────────────────────── */

void sampler_init(void)
{
	_adc3_init();

	if (!gpio_is_ready_dt(&_pulse_in)) {
		LOG_ERR("PF15 GPIO not ready — check zephyr,user overlay node");
		return;
	}
	gpio_pin_configure_dt(&_pulse_in, GPIO_INPUT | GPIO_PULL_DOWN);
	gpio_pin_interrupt_configure_dt(&_pulse_in, GPIO_INT_EDGE_RISING);
	gpio_init_callback(&_gpio_cb, _edge_cb, BIT(_pulse_in.pin));
	gpio_add_callback(_pulse_in.port, &_gpio_cb);

	k_thread_create(&_adc_thread, _adc_stack, K_THREAD_STACK_SIZEOF(_adc_stack),
			_adc_task, NULL, NULL, NULL,
			K_PRIO_COOP(5), 0, K_NO_WAIT);
	k_thread_name_set(&_adc_thread, "adc_task");

	/* Seed the frequency measurement baseline */
	_last_freq_cyc   = k_cycle_get_32();
	_last_freq_edges = 0u;

	LOG_INF("sampler init — PF15 rising-edge trigger, ring buf %u",
		SAMPLER_RING_SIZE);
}

uint32_t sampler_get_in_freq_hz(void)
{
	uint32_t now_cyc   = k_cycle_get_32();
	uint32_t now_edges = _total_edges;

	uint32_t d_cyc   = now_cyc   - _last_freq_cyc;
	uint32_t d_edges = now_edges - _last_freq_edges;

	_last_freq_cyc   = now_cyc;
	_last_freq_edges = now_edges;

	if (d_edges == 0u || d_cyc == 0u) {
		/* No new edges in this window → signal absent; decay EMA */
		_avg_freq_hz = 0u;
		return 0u;
	}

	uint32_t inst_hz = (uint32_t)((uint64_t)d_edges *
				      sys_clock_hw_cycles_per_sec() / d_cyc);

	/* EMA with α = 1/8 for smoothing */
	if (_avg_freq_hz == 0u) {
		_avg_freq_hz = inst_hz;
	} else {
		_avg_freq_hz -= (_avg_freq_hz >> 3);
		_avg_freq_hz += (inst_hz     >> 3);
	}
	return _avg_freq_hz;
}

bool sampler_read_chunk(uint16_t *buf, uint8_t *out_count)
{
	uint32_t avail = _head - _tail;

	if (avail < SAMPLER_CHUNK_SIZE) {
		return false;
	}
	for (uint32_t i = 0u; i < SAMPLER_CHUNK_SIZE; i++) {
		buf[i] = _buf[(_tail + i) & (SAMPLER_RING_SIZE - 1u)];
	}
	_tail += SAMPLER_CHUNK_SIZE;
	*out_count = (uint8_t)SAMPLER_CHUNK_SIZE;
	return true;
}
