/* main.c — uart_test: VeeR drives the SoC UART with "Hi\n"
 * Register model matches ips/uart + tb_core_uart monitor:
 *   LCR  +0x0C (8N1 = 0x03, DLAB bit 7), IER +0x04, BAUD +0x08,
 *   THR  +0x00, LSR +0x14 (THRE bit 5). Baud divisor 100 (1% TX/RX match).
 */
#include <stdint.h>

#define UART_BASE 0x20003000UL
#define UART_THR  (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_IER  (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_BAUD (*(volatile uint32_t *)(UART_BASE + 0x08))
#define UART_LCR  (*(volatile uint32_t *)(UART_BASE + 0x0C))
#define UART_LSR  (*(volatile uint32_t *)(UART_BASE + 0x14))

#define LSR_THRE (1U << 5)

static void uart_putc(char c)
{
    while ((UART_LSR & LSR_THRE) == 0)
        ;
    UART_THR = (uint32_t)c;
}

int main(void)
{
    /* 8N1 + DLAB=1 to open baud register */
    UART_LCR = 0x83U;
    UART_BAUD = 100U;
    /* 8N1, DLAB=0 */
    UART_LCR = 0x03U;
    /* Enable RX interrupt (DATA_READY gating, as in block TB) */
    UART_IER = 0x01U;

    uart_putc('H');
    uart_putc('i');
    uart_putc('\n');

    while (1)
        ;
    return 0;
}
