// timer_test/main.c — Phase 1 SW test for timer_wrapper (poll only).
//
// Reload determinism while disabled, free-run to COMPARE=100 with sticky
// match flag, W1C clear, count-holds-while-disabled. Interrupt output
// (timer_irq_o) is TB-checked (harness watches the pin); C polls CTRL[1].
#include <stdint.h>
#include "soc_map.h"
#include "io.h"
#include "uart.h"

#define COMPARE_VAL 100u
#define POLL_MAX 1000000u

int main(void)
{
    uint32_t ctrl, count0, count1;
    uint32_t n = 0;
    int fail = 0;

    uart_init();
    uart_puts("TIMER TEST\n");

    // Deterministic reload while disabled, then enable.
    mmio_write32(SOC_TIMER_CTRL_ADDR, 0x0u); // disable
    mmio_write32(SOC_TIMER_COMPARE_ADDR, COMPARE_VAL);
    mmio_write32(SOC_TIMER_COUNT_ADDR, 0x0u);
    mmio_write32(SOC_TIMER_CTRL_ADDR, 0x1u); // enable

    // Poll for the sticky match flag.
    do {
        ctrl = mmio_read32(SOC_TIMER_CTRL_ADDR);
        n++;
    } while (((ctrl >> SOC_TIMER_CTRL_MATCH) & 1u) == 0 && n < POLL_MAX);
    if (((ctrl >> SOC_TIMER_CTRL_MATCH) & 1u) == 0)
        fail = 1; // never matched

    // W1C clear (keep enable set), confirm flag drops.
    mmio_write32(SOC_TIMER_CTRL_ADDR,
                 (1u << SOC_TIMER_CTRL_ENABLE) | (1u << SOC_TIMER_CTRL_MATCH));
    ctrl = mmio_read32(SOC_TIMER_CTRL_ADDR);
    if (((ctrl >> SOC_TIMER_CTRL_MATCH) & 1u) != 0)
        fail = 1;

    // Count holds while disabled.
    mmio_write32(SOC_TIMER_CTRL_ADDR, 0x0u);
    count0 = mmio_read32(SOC_TIMER_COUNT_ADDR);
    for (volatile int d = 0; d < 64; d++)
        ;
    count1 = mmio_read32(SOC_TIMER_COUNT_ADDR);
    if (count0 != count1)
        fail = 1;

    if (fail)
        uart_puts("TIMER FAIL\n");
    else
        uart_puts("TIMER OK\n");
    uart_drain_tx();
    return fail ? 1 : 0;
}
