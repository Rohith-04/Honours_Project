// gpio_test/main.c — Phase 1 SW test for gpio_wrapper (poll only).
//
// Exercises DIR/OUT programming with register readbacks, output patterns,
// and an input readback (TB drives gpio_in to 8'hA5 — see tb_soc_sw.sv).
// Reports over UART; returns 0 on success. Mirrors the unit-test cases
// (masked/full patterns, RO behavior is TB-checked, not C-checked).
#include <stdint.h>
#include "soc_map.h"
#include "io.h"
#include "uart.h"

#define GPIO_EXPECT_IN 0xA5u

int main(void)
{
    uint32_t v;
    int fail = 0;

    uart_init();
    uart_puts("GPIO TEST\n");

    // All-output: DIR=0xFF, drive patterns, read back OUT.
    mmio_write32(SOC_GPIO_DIR_ADDR, 0xFFu);
    v = mmio_read32(SOC_GPIO_DIR_ADDR);
    if ((v & 0xFFu) != 0xFFu)
        fail = 1;

    const uint32_t patterns[] = {0x55u, 0xAAu, 0xFFu, 0x00u};
    for (unsigned i = 0; i < 4; i++) {
        mmio_write32(SOC_GPIO_OUT_ADDR, patterns[i]);
        v = mmio_read32(SOC_GPIO_OUT_ADDR);
        if ((v & 0xFFu) != patterns[i])
            fail = 1;
    }

    // All-input: DIR=0x00, TB drives pins to 0xA5, check IN.
    mmio_write32(SOC_GPIO_DIR_ADDR, 0x00u);
    // 2-cycle sync margin (IN passes through one flop): small delay.
    for (volatile int d = 0; d < 16; d++)
        ;
    v = mmio_read32(SOC_GPIO_IN_ADDR);
    if ((v & 0xFFu) != GPIO_EXPECT_IN)
        fail = 1;

    // Back to outputs driven low for a clean idle state.
    mmio_write32(SOC_GPIO_DIR_ADDR, 0xFFu);
    mmio_write32(SOC_GPIO_OUT_ADDR, 0x00u);

    if (fail)
        uart_puts("GPIO FAIL\n");
    else
        uart_puts("GPIO OK\n");
    uart_drain_tx();
    return fail ? 1 : 0;
}
