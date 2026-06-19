/*
 * STM32MP257F-DK Cortex-M33 FOC motor control application.
 *
 * Endpoint "m33-ctrl" (RPMsg / OpenAMP):
 *
 *   M33 → Linux (binary frames, see protocol.h):
 *     MSG_TYPE_ADC          (0x01): raw ADC + timestamp at 50 Hz
 *     MSG_TYPE_ENCODER      (0x02): encoder position at 50 Hz
 *     MSG_TYPE_MOTOR_STATUS (0x04): speed/angle/Id/Iq at 50 Hz
 *     Text heartbeat every 10 s (legacy)
 *
 *   Linux → M33 (binary frame):
 *     MSG_TYPE_MOTOR_CMD (0x03): mode + setpoint
 *       mode 0 = off, 1 = speed (rad/s), 2 = angle (rad)
 *
 * FOC control loop runs at 10 kHz from TIM2 update ISR (PWM-synchronous).
 *
 * Sensor report interval: 20 ms (50 Hz) — adequate for web dashboard.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/ipm.h>
#include <zephyr/drivers/gpio.h>
#include <openamp/open_amp.h>
#include <metal/sys.h>
#include <metal/io.h>
#include <resource_table.h>
#include <addr_translation.h>
#include <zephyr/logging/log.h>
#include <string.h>
#include <stdio.h>

#include "protocol.h"
#include "adc.h"
#include "encoder.h"
#include "pwm.h"
#include "foc.h"

LOG_MODULE_REGISTER(m33_app, LOG_LEVEL_DBG);

#define RPMSG_CHAN_NAME   "m33-ctrl"
#define SENSOR_INTERVAL_MS  20   /* 50 Hz sensor + status reporting */

#if !DT_HAS_CHOSEN(zephyr_ipc_shm)
#error "Add a board overlay that sets zephyr,ipc_shm and zephyr,ipc chosen nodes"
#endif

#define SHM_NODE       DT_CHOSEN(zephyr_ipc_shm)
#define SHM_START_ADDR DT_REG_ADDR(SHM_NODE)
#define SHM_SIZE       DT_REG_SIZE(SHM_NODE)

#define LED_NODE DT_ALIAS(led0)
#if DT_NODE_HAS_STATUS(LED_NODE, okay)
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(LED_NODE, gpios);
#define HAVE_LED 1
#else
#define HAVE_LED 0
#endif

static const struct device *const ipm_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_ipc));

static metal_phys_addr_t shm_physmap  = SHM_START_ADDR;
static metal_phys_addr_t rsc_physmap;
static struct metal_io_region shm_io_inst;
static struct metal_io_region rsc_io_inst;
static struct metal_io_region *shm_io = &shm_io_inst;
static struct metal_io_region *rsc_io = &rsc_io_inst;

static struct rpmsg_virtio_device rvdev;
static struct rpmsg_device *rpdev;
static struct rpmsg_endpoint ctrl_ept;

static K_SEM_DEFINE(vdev_sem,  0, 1);
static K_SEM_DEFINE(bound_sem, 0, 1);

#define THREAD_STACK 2048
K_THREAD_STACK_DEFINE(mng_stack,    THREAD_STACK);
K_THREAD_STACK_DEFINE(app_stack,    THREAD_STACK);
K_THREAD_STACK_DEFINE(sensor_stack, 3072);
static struct k_thread mng_thread;
static struct k_thread app_thread;
static struct k_thread sensor_thread;

/* ── IPM / mailbox ──────────────────────────────────────────────────────────── */

static void ipm_callback(const struct device *dev, void *ctx,
			 uint32_t id, volatile void *data)
{
	ARG_UNUSED(dev); ARG_UNUSED(ctx); ARG_UNUSED(data);
	k_sem_give(&vdev_sem);
}

int mailbox_notify(void *priv, uint32_t id)
{
	ARG_UNUSED(priv);
#if CONFIG_IPM_MAX_DATA_SIZE > 0
	ipm_send(ipm_dev, 0, id, &id, sizeof(id));
#else
	ipm_send(ipm_dev, 0, id, NULL, 0);
#endif
	return 0;
}

/* ── RPMsg endpoint ─────────────────────────────────────────────────────────── */

static int ep_recv(struct rpmsg_endpoint *ept, void *data, size_t len,
		   uint32_t src, void *priv)
{
	ARG_UNUSED(src); ARG_UNUSED(priv);

	const uint8_t *buf = (const uint8_t *)data;

	/* Binary motor command frame */
	if (len >= sizeof(struct proto_motor_cmd_frame) &&
	    buf[0] == PROTO_MAGIC &&
	    buf[1] == MSG_TYPE_MOTOR_CMD) {

		const struct proto_motor_cmd_frame *f =
			(const struct proto_motor_cmd_frame *)buf;
		LOG_INF("motor cmd: mode=%u setpoint=%.3f",
			f->data.mode, (double)f->data.setpoint);
		m33_foc_set_command(f->data.mode, f->data.setpoint);
		return RPMSG_SUCCESS;
	}

	/* Legacy: echo text frames back */
	char echo[128];
	size_t n = MIN(len, sizeof(echo) - 2);
	memcpy(echo, data, n);
	while (n > 0 && (echo[n-1] == '\0' || echo[n-1] == '\n')) { n--; }
	echo[n++] = '\n';
	echo[n]   = '\0';
	LOG_INF("A35→M33: %.*s", (int)(n - 1), echo);
	rpmsg_send(ept, echo, n);
	return RPMSG_SUCCESS;
}

static void ep_unbound(struct rpmsg_endpoint *ept)
{
	ARG_UNUSED(ept);
	/* Stop motor when Linux disconnects */
	m33_foc_set_command(MOTOR_MODE_OFF, 0.0f);
	LOG_WRN("RPMsg endpoint unbound — motor stopped");
}

static void ns_bind_cb(struct rpmsg_device *rdev, const char *name, uint32_t src)
{
	ARG_UNUSED(rdev);
	LOG_WRN("unexpected NS announcement: %s src=0x%x", name, src);
}

/* ── Platform init ──────────────────────────────────────────────────────────── */

static int platform_init(void)
{
	struct metal_init_params mp = METAL_INIT_DEFAULTS;
	void *rsc_table;
	int rsc_size, ret;

	ret = metal_init(&mp);
	if (ret) { LOG_ERR("metal_init: %d", ret); return ret; }

	metal_io_init(shm_io, (void *)SHM_START_ADDR, &shm_physmap,
		      SHM_SIZE, -1, 0, addr_translation_get_ops(shm_physmap));

	rsc_table_get(&rsc_table, &rsc_size);
	rsc_physmap = (uintptr_t)rsc_table;
	metal_io_init(rsc_io, rsc_table, &rsc_physmap, rsc_size, -1, 0, NULL);

	if (!device_is_ready(ipm_dev)) {
		LOG_ERR("IPM device not ready");
		return -ENODEV;
	}
	ipm_register_callback(ipm_dev, ipm_callback, NULL);
	ipm_set_enabled(ipm_dev, 1);
	return 0;
}

static struct rpmsg_device *platform_create_rpmsg_vdev(void *rsc_table)
{
	struct fw_rsc_vdev_vring *vring;
	struct virtio_device *vdev;
	int ret;

	vdev = rproc_virtio_create_vdev(VIRTIO_DEV_DEVICE, VDEV_ID,
					rsc_table_to_vdev(rsc_table),
					rsc_io, NULL, mailbox_notify, NULL);
	if (!vdev) { LOG_ERR("rproc_virtio_create_vdev failed"); return NULL; }

	rproc_virtio_wait_remote_ready(vdev);

	vring = rsc_table_get_vring0(rsc_table);
	ret = rproc_virtio_init_vring(vdev, 0, vring->notifyid,
				      (void *)vring->da, rsc_io,
				      vring->num, vring->align);
	if (ret) { LOG_ERR("init vring0: %d", ret); goto fail; }

	vring = rsc_table_get_vring1(rsc_table);
	ret = rproc_virtio_init_vring(vdev, 1, vring->notifyid,
				      (void *)vring->da, rsc_io,
				      vring->num, vring->align);
	if (ret) { LOG_ERR("init vring1: %d", ret); goto fail; }

	ret = rpmsg_init_vdev(&rvdev, vdev, ns_bind_cb, shm_io, NULL);
	if (ret) { LOG_ERR("rpmsg_init_vdev: %d", ret); goto fail; }

	return rpmsg_virtio_get_rpmsg_device(&rvdev);

fail:
	rproc_virtio_remove_vdev(vdev);
	return NULL;
}

/* ── Sensor / status thread (50 Hz) ─────────────────────────────────────────── */

static void sensor_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1); ARG_UNUSED(a2); ARG_UNUSED(a3);

	k_sem_take(&bound_sem, K_FOREVER);
	k_sem_give(&bound_sem);

	if (m33_adc_init() < 0) {
		LOG_ERR("ADC init failed");
		return;
	}
	if (m33_encoder_init() < 0) {
		LOG_ERR("Encoder init failed");
	}
	/* Init PWM hardware (does NOT start counter — ISR not yet firing) */
	if (m33_pwm_init(m33_foc_step) < 0) {
		LOG_ERR("PWM init failed");
		return;
	}
	/* Init FOC state before starting the ISR */
	if (m33_foc_init() < 0) {
		LOG_ERR("FOC init failed");
		return;
	}
	/* Start TIM2 counter — ISR begins, FOC state is now valid */
	m33_pwm_start();

	LOG_INF("FOC running at %u Hz, sensor reports at %u Hz",
		PWM_FREQ_HZ, 1000U / SENSOR_INTERVAL_MS);

	uint8_t seq_adc = 0, seq_enc = 0, seq_sts = 0;
	uint32_t diag_tick = 0;

	while (1) {
		k_sleep(K_MSEC(SENSOR_INTERVAL_MS));

		/* Every 2 s: log PWM shadow state and live GPIOF ODR */
		if (++diag_tick >= (2000U / SENSOR_INTERVAL_MS)) {
			diag_tick = 0;
			uint16_t pa, pb, pc;
			bool pen;
			uint32_t odr;
			m33_pwm_get_state(&pa, &pb, &pc, &pen, &odr);
			LOG_INF("PWM: en=%u da=%u db=%u dc=%u GPIOF_ODR=0x%04x PF13=%u PF14=%u",
				(unsigned)pen, pa, pb, pc,
				(unsigned)(odr & 0xFFFFu),
				(unsigned)((odr >> 13) & 1u),
				(unsigned)((odr >> 14) & 1u));
		}

		if (ctrl_ept.dest_addr == RPMSG_ADDR_ANY) {
			continue;
		}

		/* --- ADC frame (raw values from FOC snapshot) --- */
		struct foc_status st;
		m33_foc_get_status(&st);

		struct proto_adc_frame adc_frame = {
			.hdr  = { PROTO_MAGIC, MSG_TYPE_ADC,
				  PROTO_ADC_PAYLOAD_LEN, seq_adc++ },
			.data = { (uint32_t)k_uptime_get(),
				  { st.adc_raw[0], st.adc_raw[1] } },
		};
		rpmsg_send(&ctrl_ept, &adc_frame, sizeof(adc_frame));

		/* --- Encoder frame --- */
		struct proto_encoder_frame enc_frame = {
			.hdr  = { PROTO_MAGIC, MSG_TYPE_ENCODER,
				  PROTO_ENCODER_PAYLOAD_LEN, seq_enc++ },
			.data = { (uint32_t)k_uptime_get(),
				  m33_encoder_get_position(),
				  m33_encoder_get_index_count() },
		};
		rpmsg_send(&ctrl_ept, &enc_frame, sizeof(enc_frame));

		/* --- Motor status frame --- */
		struct proto_motor_status_frame sts_frame = {
			.hdr  = { PROTO_MAGIC, MSG_TYPE_MOTOR_STATUS,
				  PROTO_MOTOR_STATUS_PAYLOAD_LEN, seq_sts++ },
			.data = {
				.ts_ms       = (uint32_t)k_uptime_get(),
				.speed_rads  = st.speed_rads,
				.angle_rad   = st.angle_rad,
				.id_ma       = st.id_ma,
				.iq_ma       = st.iq_ma,
				.state       = st.state,
				.fault       = st.fault,
			},
		};
		rpmsg_send(&ctrl_ept, &sts_frame, sizeof(sts_frame));
	}
}

/* ── Application thread: heartbeat ─────────────────────────────────────────── */

static void app_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1); ARG_UNUSED(a2); ARG_UNUSED(a3);

	k_sem_take(&bound_sem, K_FOREVER);

#if HAVE_LED
	gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
#endif

	uint32_t count = 0;
	char msg[64];

	while (1) {
		if (ctrl_ept.dest_addr != RPMSG_ADDR_ANY) {
			snprintf(msg, sizeof(msg), "M33 heartbeat #%u\n", count++);
			rpmsg_send(&ctrl_ept, msg, strlen(msg));
		}
#if HAVE_LED
		gpio_pin_toggle_dt(&led);
#endif
		k_sleep(K_SECONDS(10));
	}
}

/* ── Management thread ──────────────────────────────────────────────────────── */

static void mng_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1); ARG_UNUSED(a2); ARG_UNUSED(a3);

	void *rsc_table;
	int rsc_size;

	LOG_INF("STM32MP257F M33 FOC starting");

	if (platform_init() < 0) {
		LOG_ERR("platform_init failed");
		return;
	}

	rsc_table_get(&rsc_table, &rsc_size);
	rpdev = platform_create_rpmsg_vdev(rsc_table);
	if (!rpdev) {
		LOG_ERR("platform_create_rpmsg_vdev failed");
		ipm_set_enabled(ipm_dev, 0);
		metal_finish();
		return;
	}

	int ret = rpmsg_create_ept(&ctrl_ept, rpdev, RPMSG_CHAN_NAME,
				   RPMSG_ADDR_ANY, RPMSG_ADDR_ANY,
				   ep_recv, ep_unbound);
	if (ret) {
		LOG_ERR("rpmsg_create_ept: %d", ret);
		ipm_set_enabled(ipm_dev, 0);
		metal_finish();
		return;
	}
	LOG_INF("endpoint '" RPMSG_CHAN_NAME "' ready");
	k_sem_give(&bound_sem);

	while (1) {
		k_sem_take(&vdev_sem, K_FOREVER);
		rproc_virtio_notified(rvdev.vdev, VRING1_ID);
	}
}

/* ── Entry point ────────────────────────────────────────────────────────────── */

int main(void)
{
	k_thread_create(&mng_thread, mng_stack, THREAD_STACK,
			mng_task, NULL, NULL, NULL,
			K_PRIO_COOP(8), 0, K_NO_WAIT);

	k_thread_create(&app_thread, app_stack, THREAD_STACK,
			app_task, NULL, NULL, NULL,
			K_PRIO_COOP(7), 0, K_NO_WAIT);

	k_thread_create(&sensor_thread, sensor_stack,
			K_THREAD_STACK_SIZEOF(sensor_stack),
			sensor_task, NULL, NULL, NULL,
			K_PRIO_COOP(6), 0, K_NO_WAIT);

	return 0;
}
