/*
 * STM32MP257F-DK Cortex-M33 application
 *
 * Communicates with Linux (A35) via RPMsg / OpenAMP over shared DDR using
 * the resource-table mechanism expected by Linux remoteproc.
 *
 * Endpoint "m33-ctrl": echoes every message received from Linux and sends
 * a heartbeat every 10 s.
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

LOG_MODULE_REGISTER(m33_app, LOG_LEVEL_DBG);

#define RPMSG_CHAN_NAME "m33-ctrl"

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
K_THREAD_STACK_DEFINE(mng_stack, THREAD_STACK);
K_THREAD_STACK_DEFINE(app_stack, THREAD_STACK);
static struct k_thread mng_thread;
static struct k_thread app_thread;

/* ── IPM / mailbox ─────────────────────────────────────────────────────── */

static void ipm_callback(const struct device *dev, void *ctx,
			 uint32_t id, volatile void *data)
{
	ARG_UNUSED(dev);
	ARG_UNUSED(ctx);
	ARG_UNUSED(data);
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

/* ── RPMsg endpoint ─────────────────────────────────────────────────────── */

static int ep_recv(struct rpmsg_endpoint *ept, void *data, size_t len,
		   uint32_t src, void *priv)
{
	ARG_UNUSED(src);
	ARG_UNUSED(priv);

	char buf[128];
	size_t n = MIN(len, sizeof(buf) - 2);

	memcpy(buf, data, n);
	/* strip any existing null/newline so we normalise to \n-terminated */
	while (n > 0 && (buf[n - 1] == '\0' || buf[n - 1] == '\n'))
		n--;
	buf[n++] = '\n';
	buf[n]   = '\0';
	LOG_INF("A35→M33: %.*s", (int)(n - 1), buf);
	rpmsg_send(ept, buf, n);

	return RPMSG_SUCCESS;
}

static void ep_unbound(struct rpmsg_endpoint *ept)
{
	LOG_WRN("RPMsg endpoint unbound");
}

static void ns_bind_cb(struct rpmsg_device *rdev, const char *name, uint32_t src)
{
	ARG_UNUSED(rdev);
	LOG_WRN("unexpected NS announcement: %s src=0x%x", name, src);
}

/* ── Platform init ──────────────────────────────────────────────────────── */

static int platform_init(void)
{
	struct metal_init_params mp = METAL_INIT_DEFAULTS;
	void *rsc_table;
	int rsc_size;
	int ret;

	ret = metal_init(&mp);
	if (ret) {
		LOG_ERR("metal_init: %d", ret);
		return ret;
	}

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
	if (!vdev) {
		LOG_ERR("rproc_virtio_create_vdev failed");
		return NULL;
	}

	rproc_virtio_wait_remote_ready(vdev);

	vring = rsc_table_get_vring0(rsc_table);
	ret = rproc_virtio_init_vring(vdev, 0, vring->notifyid,
				      (void *)vring->da, rsc_io,
				      vring->num, vring->align);
	if (ret) {
		LOG_ERR("init vring0: %d", ret);
		goto fail;
	}

	vring = rsc_table_get_vring1(rsc_table);
	ret = rproc_virtio_init_vring(vdev, 1, vring->notifyid,
				      (void *)vring->da, rsc_io,
				      vring->num, vring->align);
	if (ret) {
		LOG_ERR("init vring1: %d", ret);
		goto fail;
	}

	ret = rpmsg_init_vdev(&rvdev, vdev, ns_bind_cb, shm_io, NULL);
	if (ret) {
		LOG_ERR("rpmsg_init_vdev: %d", ret);
		goto fail;
	}

	return rpmsg_virtio_get_rpmsg_device(&rvdev);

fail:
	rproc_virtio_remove_vdev(vdev);
	return NULL;
}

/* ── Application thread: wait for endpoint creation, then heartbeat ─────── */

static void app_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1);
	ARG_UNUSED(a2);
	ARG_UNUSED(a3);

	LOG_INF("Waiting for endpoint to be ready...");
	k_sem_take(&bound_sem, K_FOREVER);
	LOG_INF("M33 ready — sending heartbeat every 10 s");

#if HAVE_LED
	gpio_pin_configure_dt(&led, GPIO_OUTPUT_INACTIVE);
#endif

	uint32_t count = 0;
	char msg[64];

	while (1) {
		if (ctrl_ept.dest_addr != RPMSG_ADDR_ANY) {
			snprintf(msg, sizeof(msg), "M33 heartbeat #%u\n", count++);
			int ret = rpmsg_send(&ctrl_ept, msg, strlen(msg));

			if (ret < 0) {
				LOG_WRN("rpmsg_send: %d", ret);
			}
		}

#if HAVE_LED
		gpio_pin_toggle_dt(&led);
#endif
		k_sleep(K_SECONDS(10));
	}
}

/* ── Management thread: platform init + vdev loop ──────────────────────── */

static void mng_task(void *a1, void *a2, void *a3)
{
	ARG_UNUSED(a1);
	ARG_UNUSED(a2);
	ARG_UNUSED(a3);

	void *rsc_table;
	int rsc_size;

	LOG_INF("STM32MP257F M33 starting");

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

	/* M33 announces its endpoint to Linux via NS (VIRTIO_DEV_DEVICE pattern).
	 * Linux will see the channel and the user can communicate via /dev/rpmsgN. */
	int ret = rpmsg_create_ept(&ctrl_ept, rpdev, RPMSG_CHAN_NAME,
				   RPMSG_ADDR_ANY, RPMSG_ADDR_ANY,
				   ep_recv, ep_unbound);
	if (ret) {
		LOG_ERR("rpmsg_create_ept: %d", ret);
		ipm_set_enabled(ipm_dev, 0);
		metal_finish();
		return;
	}
	LOG_INF("endpoint '" RPMSG_CHAN_NAME "' announced at addr 0x%x", ctrl_ept.addr);
	k_sem_give(&bound_sem);

	while (1) {
		k_sem_take(&vdev_sem, K_FOREVER);
		rproc_virtio_notified(rvdev.vdev, VRING1_ID);
	}
}

/* ── Entry point ────────────────────────────────────────────────────────── */

int main(void)
{
	k_thread_create(&mng_thread, mng_stack, THREAD_STACK,
			mng_task, NULL, NULL, NULL,
			K_PRIO_COOP(8), 0, K_NO_WAIT);

	k_thread_create(&app_thread, app_stack, THREAD_STACK,
			app_task, NULL, NULL, NULL,
			K_PRIO_COOP(7), 0, K_NO_WAIT);

	return 0;
}
