/*
 * STM32MP257F-DK Cortex-M33 application — pulse generator + triggered ADC sampler.
 *
 * Endpoint "m33-ctrl" (RPMsg / OpenAMP):
 *
 *   Linux → M33 (binary frame):
 *     MSG_TYPE_SET_FREQ  (0x01): freq_hz u32  —  0=stop, 1..1 MHz=run
 *
 *   M33 → Linux (binary frame):
 *     MSG_TYPE_STATUS    (0x02): ts_ms, out_freq_hz, out_enabled, in_freq_hz  at 10 Hz
 *     MSG_TYPE_ADC_CHUNK (0x03): ts_ms + 128 × u16 ADC raw values (as available)
 *     Text heartbeat every 10 s (legacy, for rpmsg-chat.sh)
 *
 *   Text frames (not starting with 0xA5) are echoed back unchanged.
 *
 * Pins:
 *   PA5  — TIM2_CH4 AF8 — pulse generator output (0–1 MHz)
 *   PF15 — GPIO input  — rising-edge trigger for ADC sampling
 *   PC7  — ADC3 INP9   — ADC input sampled on each PF15 rising edge
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
#include "pulse_gen.h"
#include "sampler.h"

LOG_MODULE_REGISTER(m33_app, LOG_LEVEL_DBG);

#define RPMSG_CHAN_NAME    "m33-ctrl"
#define STATUS_INTERVAL_MS  100    /* 10 Hz status reports */

#if !DT_HAS_CHOSEN(zephyr_ipc_shm)
#error "Add a board overlay with zephyr,ipc_shm and zephyr,ipc chosen nodes"
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
static struct rpmsg_device       *rpdev;
static struct rpmsg_endpoint      ctrl_ept;

static K_SEM_DEFINE(vdev_sem,  0, 1);
static K_SEM_DEFINE(bound_sem, 0, 1);

K_THREAD_STACK_DEFINE(mng_stack,    4096);
K_THREAD_STACK_DEFINE(app_stack,    2048);
K_THREAD_STACK_DEFINE(status_stack, 2048);
static struct k_thread mng_thread;
static struct k_thread app_thread;
static struct k_thread status_thread;

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

	if (len >= sizeof(struct proto_set_freq_frame) &&
	    buf[0] == PROTO_MAGIC &&
	    buf[1] == MSG_TYPE_SET_FREQ) {

		const struct proto_set_freq_frame *f =
			(const struct proto_set_freq_frame *)buf;
		LOG_INF("SET_FREQ: %u Hz", f->data.freq_hz);
		pulse_gen_set_freq(f->data.freq_hz);
		return RPMSG_SUCCESS;
	}

	/* Legacy: echo text frames back (rpmsg-chat.sh) */
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
	pulse_gen_set_freq(0);
	LOG_WRN("RPMsg endpoint unbound — output stopped");
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

/* ── Status thread (10 Hz) ──────────────────────────────────────────────────── */

static void status_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1); ARG_UNUSED(a2); ARG_UNUSED(a3);

	k_sem_take(&bound_sem, K_FOREVER);
	k_sem_give(&bound_sem);

	pulse_gen_init();
	sampler_init();

	uint8_t seq = 0;

	/* Static frame buffer avoids 265-byte stack allocation per loop */
	static struct proto_adc_chunk_frame s_chunk;

	while (1) {
		k_sleep(K_MSEC(STATUS_INTERVAL_MS));

		if (ctrl_ept.dest_addr == RPMSG_ADDR_ANY) {
			continue;
		}

		/* Send STATUS at 10 Hz */
		struct proto_status_frame f = {
			.hdr  = { PROTO_MAGIC, MSG_TYPE_STATUS,
				  PROTO_STATUS_PAYLOAD_LEN, seq++ },
			.data = {
				.ts_ms       = (uint32_t)k_uptime_get(),
				.out_freq_hz = pulse_gen_get_freq(),
				.out_enabled = pulse_gen_is_enabled() ? 1u : 0u,
				.in_freq_hz  = sampler_get_in_freq_hz(),
			},
		};
		rpmsg_send(&ctrl_ept, &f, sizeof(f));

		/* Drain ADC ring buffer — up to 8 chunks per STATUS tick.
		 * At 10 kHz input this handles 1000 samples / 100 ms cleanly. */
		for (int c = 0; c < 8; c++) {
			if (!sampler_read_chunk(s_chunk.data.samples,
						&s_chunk.data.count)) {
				break;
			}
			s_chunk.hdr.magic = PROTO_MAGIC;
			s_chunk.hdr.type  = MSG_TYPE_ADC_CHUNK;
			s_chunk.hdr.len   = PROTO_ADC_CHUNK_PAYLOAD_LEN;
			s_chunk.hdr.seq   = seq++;
			s_chunk.data.ts_ms = (uint32_t)k_uptime_get();
			rpmsg_send(&ctrl_ept, &s_chunk, sizeof(s_chunk));
		}
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

	LOG_INF("STM32MP257F M33 pulse generator starting");

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
	k_yield();  /* let status_task run before we drain vdev_sem */

	while (1) {
		k_sem_take(&vdev_sem, K_FOREVER);
		rproc_virtio_notified(rvdev.vdev, VRING1_ID);
	}
}

/* ── Entry point ────────────────────────────────────────────────────────────── */

int main(void)
{
	/* Create highest-priority threads first so they are already waiting on
	 * bound_sem when mng_task eventually gives it.  If mng_task were created
	 * first it would preempt main() (cooperative > preemptive priority) and
	 * give bound_sem before the other threads even exist, causing status_task
	 * to block forever. */
	k_thread_create(&status_thread, status_stack,
			K_THREAD_STACK_SIZEOF(status_stack),
			status_task, NULL, NULL, NULL,
			K_PRIO_COOP(6), 0, K_NO_WAIT);

	k_thread_create(&app_thread, app_stack,
			K_THREAD_STACK_SIZEOF(app_stack),
			app_task, NULL, NULL, NULL,
			K_PRIO_COOP(7), 0, K_NO_WAIT);

	k_thread_create(&mng_thread, mng_stack,
			K_THREAD_STACK_SIZEOF(mng_stack),
			mng_task, NULL, NULL, NULL,
			K_PRIO_COOP(8), 0, K_NO_WAIT);

	return 0;
}
