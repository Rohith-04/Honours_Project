// uart_test/main.c — Phase 1 SW test for the UART (TX + status, poll only).
//
// Inits the IP (LCR=0x80 -> BAUD=100 -> LCR=0x03 -> IER=1), checks THRE/TEMT
// idle state, then transmits the banner the TB matches. The console match
// IS the test (mentor-critical channel); the LSR self-check guards against
// a silently misconfigured divisor.
#include <stdint.h>
#include "soc_map.h"
#include "io.h"
#include "uart.h"

int main(void)
{
    uint32_t lsr;
    int fail = 0;

    uart_init();

    // After init with an idle transmitter, THRE (bit5) and TEMT (bit6)
    // must both be set.
    lsr = mmio_read32(SOC_UART_LSR_ADDR);
    if (((lsr >> SOC_UART_LSR_THRE) & 1u) == 0)
        fail = 1;
    if (((lsr >> SOC_UART_LSR_TEMT) & 1u) == 0)
        fail = 1;

    uart_puts("UART HELLO\n");
    if (fail)
        uart_puts("UART FAIL\n");
    else
        uart_puts("UART OK\n");
    uart_drain_tx();
    return fail ? 1 : 0;
}
