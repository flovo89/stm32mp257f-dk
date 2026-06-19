/*
 * RPMsg binary protocol for M33 ↔ Linux data streaming.
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
#define MSG_TYPE_ADC          0x01u   /* Two analog channels (M33 → Linux) */
#define MSG_TYPE_ENCODER      0x02u   /* Quadrature encoder position (M33 → Linux) */
#define MSG_TYPE_MOTOR_CMD    0x03u   /* Motor command (Linux → M33) */
#define MSG_TYPE_MOTOR_STATUS 0x04u   /* Motor status (M33 → Linux) */

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

/*
 * Motor command — sent from Linux to M33.
 *   mode 0 = off
 *   mode 1 = speed control  (setpoint in rad/s mechanical)
 *   mode 2 = position control (setpoint in rad mechanical)
 */
struct __attribute__((packed)) proto_motor_cmd_payload {
	uint8_t  mode;       /* MOTOR_MODE_xxx */
	float    setpoint;   /* rad/s or rad, little-endian float32 */
	uint16_t reserved;
};

/* Complete motor command frame */
struct __attribute__((packed)) proto_motor_cmd_frame {
	struct proto_hdr               hdr;
	struct proto_motor_cmd_payload data;
};

#define PROTO_MOTOR_CMD_PAYLOAD_LEN  ((uint8_t)sizeof(struct proto_motor_cmd_payload))

/* Motor status — sent from M33 to Linux at ~50 Hz when running */
struct __attribute__((packed)) proto_motor_status_payload {
	uint32_t ts_ms;            /* k_uptime_get() */
	float    speed_rads;       /* mechanical speed (rad/s) */
	float    angle_rad;        /* mechanical angle [0, 2π) */
	float    id_ma;            /* d-axis current (mA) */
	float    iq_ma;            /* q-axis current (mA) */
	uint8_t  state;            /* motor state (0=off,1=run,2=fault) */
	uint8_t  fault;            /* fault flags (reserved, 0=none) */
};

/* Complete motor status frame */
struct __attribute__((packed)) proto_motor_status_frame {
	struct proto_hdr                  hdr;
	struct proto_motor_status_payload data;
};

#define PROTO_MOTOR_STATUS_PAYLOAD_LEN  ((uint8_t)sizeof(struct proto_motor_status_payload))

#endif /* PROTOCOL_H */
