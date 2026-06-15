/*
 * ADC abstraction for STM32MP257F M33.
 *
 * Uses ADC3 (channels 3 & 12) directly via the STM32 LL HAL.
 * ADC3 is the only ADC instance assigned to M33/CID2 in the default RIFSC
 * configuration (ADC12 is CID1/A35-only and must not be accessed from M33).
 *
 * Pins (expansion header CN13):
 *   PG3 → ADC3_INP3  (ch0)   RIFSC GPIOG pin 3: SEM_EN (M33-accessible)
 *   PC3 → ADC3_INP12 (ch1)   RIFSC GPIOC pin 3: CID2   (M33-direct)
 *
 * NOTE: Linux must NOT load an IIO driver for ADC3 (disable the adc3 node
 *       in the Linux DTB, or set status = "disabled").
 */

#ifndef ADC_H
#define ADC_H

#include <stdint.h>

/* Initialise ADC3 and configure both analog input pins.
 * Returns 0 on success, negative errno on failure. */
int m33_adc_init(void);

/* Read both channels in a single call.
 * raw[0] = ADC3_INP3 (PG3), raw[1] = ADC3_INP12 (PC3).
 * Values are 12-bit (0 – 4095).
 * Returns 0 on success, negative errno on timeout/error. */
int m33_adc_read(uint16_t raw[2]);

#endif /* ADC_H */
