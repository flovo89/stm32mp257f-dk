/*
 * RPMsg binary protocol for M33 → Linux data streaming.
 *
 * All binary frames start with PROTO_MAGIC (0xA5).  Text frames (heartbeat,
 * echo) do not start with this byte, so old tooling stays compatible.
 *
 * Frame layout:
 *   [magic:u8][type:u8][len:u8][seq:u8][...payload (len bytes)...]
 *
 * Consumers check byte[0]: 0xA5 → binary frame, else → legacy text.
 */

#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>

#define PROTO_MAGIC     0xA5u

/* Message types */
#define MSG_TYPE_ADC      0x01u   /* Two analog channels */
#define MSG_TYPE_ENCODER  0x02u   /* Quadrature encoder position */

/* Frame header — must be packed so sizeof == 4 */
struct __attribute__((packed)) proto_hdr {
	uint8_t  magic;   /* PROTO_MAGIC */
	uint8_t  type;    /* MSG_TYPE_xxx */
	uint8_t  len;     /* payload bytes that follow this header */
	uint8_t  seq;     /* 8-bit counter, wraps freely */
};

/* Payload for MSG_TYPE_ADC */
struct __attribute__((packed)) proto_adc_payload {
	uint32_t ts_ms;   /* k_uptime_get() at sample time */
	uint16_t raw[2];  /* 12-bit ADC values, index = channel number */
};

/* Complete ADC frame */
struct __attribute__((packed)) proto_adc_frame {
	struct proto_hdr         hdr;
	struct proto_adc_payload data;
};

#define PROTO_ADC_PAYLOAD_LEN  ((uint8_t)sizeof(struct proto_adc_payload))

/* Payload for MSG_TYPE_ENCODER */
struct __attribute__((packed)) proto_encoder_payload {
	uint32_t ts_ms;       /* k_uptime_get() at sample time */
	int32_t  position;    /* signed 4x quadrature count, since boot/reset */
	uint32_t index_count; /* number of Z (index) pulses seen */
};

/* Complete encoder frame */
struct __attribute__((packed)) proto_encoder_frame {
	struct proto_hdr             hdr;
	struct proto_encoder_payload data;
};

#define PROTO_ENCODER_PAYLOAD_LEN  ((uint8_t)sizeof(struct proto_encoder_payload))

#endif /* PROTOCOL_H */
