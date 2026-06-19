/*
 * Quadrature encoder reader for AMT103-D0500-I5000-S (CUI Devices) on M33.
 *
 * A/B are decoded in software via GPIO EXTI (both-edge) using the standard
 * 4x quadrature state-transition table — no hardware timer encoder mode is
 * available here: the only M33/CID2-accessible general-purpose timer is
 * TIM2, and none of the available CID2 IO candidates map to its TI1/TI2
 * inputs that encoder mode requires.
 *
 * Z (index) is not wired — PF15 is repurposed as encoder A since PF13/PF14
 * are used for phase B/C PWM output.
 *
 * Wiring note: AMT10-series outputs are push-pull at the encoder's supply
 * voltage. Power the encoder from 3.3V (or level-shift A/B down) before
 * connecting it to these GPIOs — STM32 GPIOs are not 5V tolerant here.
 */

#include "encoder.h"

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(m33_encoder, LOG_LEVEL_INF);

#define ENCODER_NODE DT_PATH(zephyr_user)

static const struct gpio_dt_spec a_gpio =
	GPIO_DT_SPEC_GET(ENCODER_NODE, encoder_a_gpios);
static const struct gpio_dt_spec b_gpio =
	GPIO_DT_SPEC_GET(ENCODER_NODE, encoder_b_gpios);

static struct gpio_callback a_cb;
static struct gpio_callback b_cb;

static volatile int32_t position;
static uint8_t ab_state;

/* Quadrature state-transition table, index = (prev_state << 2) | new_state */
static const int8_t QEM[16] = {
	 0, -1, +1,  0,
	+1,  0,  0, -1,
	-1,  0,  0, +1,
	 0, +1, -1,  0,
};

static void ab_changed(const struct device *dev, struct gpio_callback *cb,
		       uint32_t pins)
{
	ARG_UNUSED(dev);
	ARG_UNUSED(cb);
	ARG_UNUSED(pins);

	uint8_t new_state = (uint8_t)((gpio_pin_get_dt(&a_gpio) << 1) |
				       gpio_pin_get_dt(&b_gpio));

	position += QEM[(ab_state << 2) | new_state];
	ab_state = new_state;
}

int m33_encoder_init(void)
{
	int rc;

	if (!gpio_is_ready_dt(&a_gpio) || !gpio_is_ready_dt(&b_gpio)) {
		LOG_ERR("encoder GPIO controller not ready");
		return -ENODEV;
	}

	rc  = gpio_pin_configure_dt(&a_gpio, GPIO_INPUT);
	rc |= gpio_pin_configure_dt(&b_gpio, GPIO_INPUT);
	if (rc) {
		LOG_ERR("encoder GPIO configure failed: %d", rc);
		return rc;
	}

	ab_state = (uint8_t)((gpio_pin_get_dt(&a_gpio) << 1) |
			      gpio_pin_get_dt(&b_gpio));

	gpio_init_callback(&a_cb, ab_changed, BIT(a_gpio.pin));
	gpio_init_callback(&b_cb, ab_changed, BIT(b_gpio.pin));

	gpio_add_callback(a_gpio.port, &a_cb);
	gpio_add_callback(b_gpio.port, &b_cb);

	gpio_pin_interrupt_configure_dt(&a_gpio, GPIO_INT_EDGE_BOTH);
	gpio_pin_interrupt_configure_dt(&b_gpio, GPIO_INT_EDGE_BOTH);

	LOG_INF("encoder ready — A=PF15 B=PG5, 4x quadrature decode (no Z)");
	return 0;
}

int32_t m33_encoder_get_position(void)
{
	return position;
}

uint32_t m33_encoder_get_index_count(void)
{
	return 0;
}

void m33_encoder_reset(void)
{
	position = 0;
}
