// Deliberately failing software fixture: prove a C failure cannot become a
// UVM PASS. This program still exercises GPIO so the passive model is active.
#include "soc_map.h"
#include "io.h"
#include "uart.h"
int main(void)
{
    uart_init();
    mmio_write32(SOC_GPIO_DIR_ADDR, 0xFFu);
    mmio_write32(SOC_GPIO_OUT_ADDR, 0x5Au);
    (void)mmio_read32(SOC_GPIO_OUT_ADDR);
    uart_puts("GPIO FAIL\n");
    uart_drain_tx();
    return 1;
}
