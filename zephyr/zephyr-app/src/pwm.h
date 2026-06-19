#ifndef PWM_H
#define PWM_H

#include <stdint.h>
#include <stdbool.h>

/*
 * 3-phase center-aligned PWM via TIM2 (CID2, APB1).
 *
 * Pin assignment (all CID2):
 *   PA5  → TIM2_CH1 AF1  — Phase A  (hardware PWM)
 *   PF13 → GPIO output   — Phase B  (software PWM, CH2 compare ISR)
 *   PF14 → GPIO output   — Phase C  (software PWM, CH3 compare ISR)
 *   EN   — no pin; tie bridge enable to 3V3, use duty=0 to disable
 *
 * Switching frequency: 10 kHz (center-aligned, ARR = 9999 @ 200 MHz).
 * FOC callback fires at 10 kHz from the TIM2 update interrupt.
 */

#define PWM_ARR      9999U    /* TIM2 auto-reload value */
#define PWM_FREQ_HZ  10000U   /* resulting switching frequency */

/* Called from TIM2 update ISR at 10 kHz — must not call Zephyr blocking APIs */
typedef void (*pwm_foc_cb_t)(void);

/* Configure TIM2 and GPIOs — does NOT start the counter or ISR */
int  m33_pwm_init(pwm_foc_cb_t foc_cb);
/* Start TIM2 counter — ISR begins firing at 10 kHz from this call */
void m33_pwm_start(void);
void m33_pwm_set_duty3(uint16_t a, uint16_t b, uint16_t c); /* 0 … PWM_ARR */
void m33_pwm_enable(bool en);
/* Diagnostic — returns last duty values written, enabled flag, and GPIOF ODR */
void m33_pwm_get_state(uint16_t *a, uint16_t *b, uint16_t *c, bool *en,
		       uint32_t *gpiof_odr);

#endif /* PWM_H */
