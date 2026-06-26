/*
 * RPMsg binary protocol — M33 pulse generator ↔ Linux.
 *
 * Frame layout:  [magic:u8][type:u8][len:u8][seq:u8][payload (len bytes)]
 * Text frames (rpmsg-chat.sh) do not start with PROTO_MAGIC and are echoed
 * back unchanged for diagnostic use.
 */

#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>

#define PROTO_MAGIC         0xA5u
#define MSG_TYPE_SET_FREQ   0x01u   /* Linux → M33: set output frequency    */
#define MSG_TYPE_STATUS     0x02u   /* M33 → Linux: current state (~10 Hz)  */
#define MSG_TYPE_ADC_CHUNK  0x03u   /* M33 → Linux: ADC sample batch        */

/* Common 4-byte header */
struct __attribute__((packed)) proto_hdr {
	uint8_t  magic;   /* PROTO_MAGIC */
	uint8_t  type;    /* MSG_TYPE_xxx */
	uint8_t  len;     /* payload bytes following this header */
	uint8_t  seq;     /* 8-bit wrapping counter */
};

/* SET_FREQ payload — Linux → M33 (4 bytes) */
struct __attribute__((packed)) proto_set_freq_payload {
	uint32_t freq_hz;   /* 0 = stop, 1..1 000 000 = run */
};

struct __attribute__((packed)) proto_set_freq_frame {
	struct proto_hdr              hdr;
	struct proto_set_freq_payload data;
};

#define PROTO_SET_FREQ_PAYLOAD_LEN  ((uint8_t)sizeof(struct proto_set_freq_payload))

/* STATUS payload — M33 → Linux (13 bytes) */
struct __attribute__((packed)) proto_status_payload {
	uint32_t ts_ms;       /* k_uptime_get() */
	uint32_t out_freq_hz; /* pulse generator output frequency (0 if stopped) */
	uint8_t  out_enabled; /* 1 = output running, 0 = stopped */
	uint32_t in_freq_hz;  /* measured input frequency on PF15 (0 if no signal) */
};

struct __attribute__((packed)) proto_status_frame {
	struct proto_hdr            hdr;
	struct proto_status_payload data;
};

#define PROTO_STATUS_PAYLOAD_LEN  ((uint8_t)sizeof(struct proto_status_payload))

/* ADC_CHUNK payload — M33 → Linux (261 bytes)
 * Sent whenever SAMPLER_CHUNK_SIZE new ADC samples have accumulated.
 * count is always PROTO_ADC_CHUNK_COUNT; the field is kept for protocol clarity.
 */
#define PROTO_ADC_CHUNK_COUNT  128u   /* must match SAMPLER_CHUNK_SIZE */

struct __attribute__((packed)) proto_adc_chunk_payload {
	uint32_t ts_ms;                          /* timestamp of first sample     */
	uint8_t  count;                          /* valid samples (= CHUNK_COUNT) */
	uint16_t samples[PROTO_ADC_CHUNK_COUNT]; /* ADC raw, 12-bit in 16-bit     */
};

struct __attribute__((packed)) proto_adc_chunk_frame {
	struct proto_hdr               hdr;
	struct proto_adc_chunk_payload data;
};

/* NOTE: sizeof() = 261 bytes which exceeds uint8_t; hdr.len carries 0xFF as sentinel.
 * Python parsers must use the fixed CHUNK_LEN constant, not hdr.len, for ADC chunks. */
#define PROTO_ADC_CHUNK_PAYLOAD_LEN  0xFFu

#endif /* PROTOCOL_H */
