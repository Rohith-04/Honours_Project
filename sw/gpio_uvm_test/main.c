// Software-originated GPIO verification. Every register access executes on
// VeeR through the adapter and fabric; UVM supplies no bus transactions.
// The legacy software harness provides the independent fixed input 0xA5.
#include <stdint.h>
#include "soc_map.h"
#include "io.h"
#include "uart.h"

static int check_output(uint32_t pattern)
{
    mmio_write32(SOC_GPIO_OUT_ADDR, 0xFFFFFF00u | pattern);
    // Compare the whole register: implemented upper bits must read zero.
    return mmio_read32(SOC_GPIO_OUT_ADDR) != pattern ||
           mmio_read32(SOC_GPIO_IN_ADDR) != 0xA5u;
}

int main(void)
{
    int fail = 0;
    const uint32_t mask = (1u << SOC_GPIO_WIDTH) - 1u;
    const uint32_t patterns[] = {0x00u, 0xFFu, 0xAAu, 0x55u};
    fail |= mmio_read32(SOC_GPIO_OUT_ADDR) != 0;
    fail |= mmio_read32(SOC_GPIO_DIR_ADDR) != 0;
    uart_init();
    uart_puts("GPIO SOFTWARE PATTERNS\n");
    mmio_write32(SOC_GPIO_DIR_ADDR, 0xFFFFFFFFu);
    fail |= mmio_read32(SOC_GPIO_DIR_ADDR) != mask;
    for (unsigned i = 0; i < sizeof(patterns) / sizeof(patterns[0]); i++)
        fail |= check_output(patterns[i]);
    // Explicit walking-one/zero on OUT, with a readback of each pattern.
    for (unsigned i = 0; i < SOC_GPIO_WIDTH; i++) {
        uint32_t selected = 1u << i;
        fail |= check_output(selected);
        fail |= check_output(mask ^ selected);
    }
    mmio_write32(SOC_GPIO_OUT_ADDR, 0xA5u);
    for (unsigned i = 0; i < SOC_GPIO_WIDTH; i++) {
        uint32_t selected = 1u << i;
        mmio_write32(SOC_GPIO_DIR_ADDR, mask ^ selected);
        fail |= mmio_read32(SOC_GPIO_DIR_ADDR) != (mask ^ selected);
        fail |= mmio_read32(SOC_GPIO_OUT_ADDR) != 0xA5u;
        fail |= mmio_read32(SOC_GPIO_IN_ADDR) != 0xA5u;
        mmio_write32(SOC_GPIO_DIR_ADDR, mask);
        fail |= mmio_read32(SOC_GPIO_DIR_ADDR) != mask;
    }
    mmio_write32(SOC_GPIO_DIR_ADDR, 0);
    fail |= mmio_read32(SOC_GPIO_IN_ADDR) != 0xA5u;
    mmio_write32(SOC_GPIO_DIR_ADDR, mask);
    mmio_write32(SOC_GPIO_OUT_ADDR, 0);
    uart_puts(fail ? "GPIO FAIL\n" : "GPIO OK\n");
    uart_drain_tx();
    return fail ? 1 : 0;
}
