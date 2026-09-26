// uart.h — minimal polled UART driver for the ips/uart core as exposed by
// uart_wrapper (native register map, see doc/interfaces/uart.md).
//
// Init sequence (reset: LCR=0 8N1 DLAB=0, IER=0, divisor=868):
//   LCR=0x80 (DLAB=1) -> BAUD=100 -> LCR=0x03 (8N1, DLAB=0) -> IER=1.
// IER=1 is mandatory: the IP gates LSR DATA_READY on the irq-enable bit,
// so an RX test with IER=0 never sees data-ready.
// Baud 100 @100MHz: TX bit ~=1010ns, RX samples at (div-1); ~1% mismatch.
// TX polls LSR THRE before each byte.
#ifndef SW_UART_H
#define SW_UART_H

#include <stdint.h>
#include "soc_map.h"
#include "io.h"

#define UART_LCR_DLAB 0x80u
#define UART_LCR_8N1  0x03u
#define UART_DIVISOR  100u

static inline void uart_init(void)
{
    mmio_write32(SOC_UART_LCR_ADDR, UART_LCR_DLAB);
    mmio_write32(SOC_UART_BAUD_ADDR, UART_DIVISOR);
    mmio_write32(SOC_UART_LCR_ADDR, UART_LCR_8N1);
    mmio_write32(SOC_UART_IER_ADDR, 0x1u);
}

static inline void uart_putc(char c)
{
    // Wait for THRE (bit5) before pushing THR.
    while ((mmio_read32(SOC_UART_LSR_ADDR) & (1u << SOC_UART_LSR_THRE)) == 0)
        ;
    mmio_write32(SOC_UART_THR_ADDR, (uint32_t)(unsigned char)c);
}

static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static inline void uart_drain_tx(void)
{
    // Wait until both THRE (bit5) and TEMT (bit6): shift register empty.
    while ((mmio_read32(SOC_UART_LSR_ADDR) &
            ((1u << SOC_UART_LSR_THRE) | (1u << SOC_UART_LSR_TEMT))) !=
           ((1u << SOC_UART_LSR_THRE) | (1u << SOC_UART_LSR_TEMT)))
        ;
}

#endif // SW_UART_H
