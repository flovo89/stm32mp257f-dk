/*
 * Quadrature encoder reader for AMT103-D0500-I5000-S (CUI Devices) on M33.
 *
 * Signals: A = PF13, B = PF14, Z (index, once per revolution) = PF15.
 * All three are GPIOF/RIFSC-CID2 pins, directly configurable from M33.
 */

#ifndef ENCODER_H
#define ENCODER_H

#include <stdint.h>

/* Configure A/B/Z GPIOs and attach EXTI callbacks for quadrature decode.
 * Returns 0 on success, negative errno on failure. */
int m33_encoder_init(void);

/* Signed 4x quadrature position, accumulated since init/last reset. */
int32_t m33_encoder_get_position(void);

/* Number of index (Z) pulses seen since init/last reset. */
uint32_t m33_encoder_get_index_count(void);

/* Zero both counters. */
void m33_encoder_reset(void);

#endif /* ENCODER_H */
