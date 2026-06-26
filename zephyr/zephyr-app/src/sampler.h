/*
 * Triggered ADC sampler — public API.
 *
 * PF15 (GPIOF pin 15, RIFSC CID2): rising-edge trigger input.
 * PC7  (ADC3 INP9,  CID1 / ANALOG reset state): sampled on each trigger.
 *
 * Samples are collected in a 512-entry ring buffer (SAMPLER_RING_SIZE).
 * sampler_read_chunk() returns SAMPLER_CHUNK_SIZE samples at a time.
 * sampler_get_in_freq_hz() reports the measured frequency of the trigger
 * signal using an exponential moving average of edge-to-edge intervals.
 */

#ifndef SAMPLER_H
#define SAMPLER_H

#include <stdint.h>
#include <stdbool.h>

/* Must match PROTO_ADC_CHUNK_COUNT in protocol.h */
#define SAMPLER_RING_SIZE   512u   /* power of 2 */
#define SAMPLER_CHUNK_SIZE  128u   /* samples per RPMsg ADC_CHUNK message */

void     sampler_init(void);
uint32_t sampler_get_in_freq_hz(void);
bool     sampler_read_chunk(uint16_t *buf, uint8_t *out_count);

#endif /* SAMPLER_H */
