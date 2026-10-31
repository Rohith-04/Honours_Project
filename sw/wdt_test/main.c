#include "nda.h"
#include "wdt.h"
#include "hpm.h"
#include "uart.h"
#include "phase2_irq.h"
static int32_t data[65];
int main(void)
{
    int fail = 0;
    uint32_t status;
    uart_init();
    for (unsigned i = 0; i < 65; i++) data[i] = (int32_t)i - 40;
#if HAVE_HPM
    hpm_control(3);
#endif
    phase2_irq_enable(SOC_IRQ_WDT);
    wdt_enable(128, 1);
    nda_start(SOC_NDA_OP_SUM, data, 65, 0);
    // EXTERNAL harness injects one temporary R-channel stall for this test.
    if (nda_wait(&status) || status != 0x76u) fail = 1;
    for (unsigned t = 0; !wdt_irq_count && t < 100000; t++) __asm__ volatile("nop");
    phase2_irq_disable();
    if (wdt_read(SOC_WDT_TRIP_COUNT) != 1 || wdt_irq_count != 1 || irq_error) fail = 1;
    // Discard the partial NDA result and recompute the whole job on the CPU.
    volatile int64_t fallback = software_sum(data, 65);
    if (fallback != -520) fail = 1;
#if HAVE_HPM
    hpm_control(5);
    if (hpm_read_snapshot(SOC_HPM_FALLBACKS_LO) != 1) fail = 1;
#endif
    // A second job must re-arm and complete without another injected stall.
    wdt_enable(SOC_WDT_TIMEOUT_DEFAULT, 0);
    nda_start(SOC_NDA_OP_SUM, data, 65, 0);
    if (nda_wait(&status) || status != 2 || nda_sum_result() != fallback ||
        wdt_read(SOC_WDT_TRIP_COUNT) != 1) fail = 1;
    wdt_write(SOC_WDT_CTRL, 0);
    uart_puts(fail ? "WDT FAIL\n" : "WDT OK\n");
    uart_drain_tx();
    return fail;
}
