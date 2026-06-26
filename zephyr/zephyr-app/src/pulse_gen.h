/*
 * Pulse generator — 50 % duty-cycle square wave on PA5 (TIM2_CH4, AF8).
 *
 * TIM2 runs in edge-aligned up-count mode; no ISR required.
 * PA5 is held LOW as GPIO output when the generator is stopped.
 */

#ifndef PULSE_GEN_H
#define PULSE_GEN_H

#include <stdint.h>
#include <stdbool.h>

#define PULSE_MAX_HZ  1000000UL   /* 1 MHz upper limit */

/* Initialise TIM2 and PA5.  Output starts disabled (PA5 held LOW). */
void     pulse_gen_init(void);

/* Set output frequency in Hz.  0 = disable (PA5 LOW).
 * Values above PULSE_MAX_HZ are clamped to PULSE_MAX_HZ. */
void     pulse_gen_set_freq(uint32_t freq_hz);

uint32_t pulse_gen_get_freq(void);
bool     pulse_gen_is_enabled(void);

#endif /* PULSE_GEN_H */
