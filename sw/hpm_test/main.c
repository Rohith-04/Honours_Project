#include "hpm.h"
#include "nda.h"
#include "uart.h"
static int32_t data[65];
int main(void)
{
    int fail = 0;
    uart_init();
#if HAVE_HPM
    for (unsigned i = 0; i < 65; i++) data[i] = (int)i - 32;
    hpm_control(3); // clear and enable
    uint32_t status;
    nda_start(SOC_NDA_OP_SUM, data, 65, 0);
    if (nda_wait(&status) || status != 2) fail = 1;
    hpm_control(0); // disable before snapshot so no enable-edge ambiguity
    hpm_control(4);
    uint64_t cycles = hpm_read_snapshot(SOC_HPM_CYCLES_LO);
    if (!cycles || !hpm_read_snapshot(SOC_HPM_CPU_AR_LO) ||
        !hpm_read_snapshot(SOC_HPM_CPU_AW_LO) ||
        hpm_read_snapshot(SOC_HPM_NDA_AR_LO) != 5 ||
        hpm_read_snapshot(SOC_HPM_NDA_RBEATS_LO) != 65 ||
        !hpm_read_snapshot(SOC_HPM_NDA_BUSY_LO) ||
        hpm_read_snapshot(SOC_HPM_FALLBACKS_LO) != 0) fail = 1;
    if (hpm_read_snapshot(SOC_HPM_CYCLES_LO) != cycles) fail = 1;
    hpm_control(4); // gated cycle counter must remain frozen
    if (hpm_read_snapshot(SOC_HPM_CYCLES_LO) != cycles) fail = 1;
    hpm_control(2);
    hpm_control(4);
    if (hpm_read_snapshot(SOC_HPM_NDA_AR_LO) || hpm_read_snapshot(SOC_HPM_CYCLES_LO)) fail = 1;
#else
    uart_puts("HPM disabled: CSR accesses skipped\n");
#endif
    uart_puts(fail ? "HPM FAIL\n" : "HPM OK\n");
    uart_drain_tx();
    return fail;
}
