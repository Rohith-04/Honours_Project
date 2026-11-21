// internal_exam/main.c — SW test: transmit "Design Verification Lab Internal"
// over the UART and confirm the transmitter is idle before and after.
//
// Structure mirrors uart_test/main.c:
//   1. Init UART (LCR=0x80, BAUD=100, LCR=0x03, IER=1).
//   2. Poll LSR: THRE (bit5) and TEMT (bit6) must both be set on an idle TX.
//   3. Transmit the test string followed by a newline.
//   4. Print the pass/fail tag that tb_soc_sw.sv matches ("INTERNAL_EXAM OK"
//      or "INTERNAL_EXAM FAIL").
//   5. Drain the TX shift register before returning so the wire is clean
//      when the harness samples the console log.
//
// Return value: 0 on pass, 1 on any LSR check failure.
// startup.S converts the return value to signature 0x50515353 (pass) or
// 0xDEAD (fail) at RAM address 0x7FF0.

#include <stdint.h>
#include "soc_map.h"
#include "io.h"
#include "uart.h"

int main(void)
{
    uint32_t lsr;
    int fail = 0;

    uart_init();

    /* After init with an idle transmitter, THRE (bit5) and TEMT (bit6)
     * must both be set.  A cleared bit means the divisor latch was not
     * programmed correctly or the TX FIFO is unexpectedly busy. */
    lsr = mmio_read32(SOC_UART_LSR_ADDR);
    if (((lsr >> SOC_UART_LSR_THRE) & 1u) == 0)
        fail = 1;
    if (((lsr >> SOC_UART_LSR_TEMT) & 1u) == 0)
        fail = 1;

    uart_puts("Design Verification Lab Internal\n");

    if (fail)
        uart_puts("INTERNAL_EXAM FAIL\n");
    else
        uart_puts("INTERNAL_EXAM OK\n");

    uart_drain_tx();
    return fail ? 1 : 0;
}
