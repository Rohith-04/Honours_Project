#include "nda.h"
#include "uart.h"
#include "phase2_irq.h"

static int32_t data[2048] __attribute__((aligned(4096)));

static int run_case(unsigned op, unsigned offset, unsigned n)
{
    const int32_t *a = data + offset;
    int32_t best = a[0];
    unsigned index = 0;
    int64_t sum = software_sum(a, n);
    for (unsigned i = 1; i < n; i++) {
        if ((op == SOC_NDA_OP_MIN && a[i] < best) ||
            (op != SOC_NDA_OP_MIN && a[i] > best)) { best = a[i]; index = i; }
    }
    uint32_t status;
    nda_start(op, a, n, 0);
    if (nda_wait(&status) || status != 2u) return 1;
    if (op == SOC_NDA_OP_SUM) return nda_sum_result() != sum;
    if ((int32_t)nda_reg(SOC_NDA_RESULT_LO) != best) return 1;
    return nda_reg(SOC_NDA_RESULT_HI) != (op == SOC_NDA_OP_ARGMAX ? index : 0u);
}

int main(void)
{
    int fail = 0;
    const unsigned lengths[] = {1, 3, 16, 17, 65, 129};
    uart_init();
    uart_puts("NDA TEST\n");
    for (unsigned i = 0; i < 2048; i++) data[i] = (int32_t)(i & 31u) - 17;
    data[1023] = (int32_t)0x80000000u;
    data[1024] = 0x7fffffff;
    data[1026] = 0x7fffffff; // first-index tie across the boundary
    for (unsigned op = 0; op < 4; op++)
        for (unsigned j = 0; j < 6; j++) fail |= run_case(op, 1022, lengths[j]);
    for (unsigned i = 0; i < 17; i++) data[i] = 0x7fffffff;
    fail |= run_case(SOC_NDA_OP_SUM, 0, 17);
    for (unsigned i = 0; i < 17; i++) data[i] = (int32_t)0x80000000u;
    fail |= run_case(SOC_NDA_OP_SUM, 0, 17);
    fail |= run_case(SOC_NDA_OP_ARGMAX, 0, 17);
    // Exercise every static job error through real CPU MMIO.
    const unsigned ops[] = {0, 4, 0, 0, 0};
    const unsigned srcs[] = {0, 0, 2, 0x10000, 0xfffc};
    const unsigned lens[] = {0, 1, 1, 1, 2};
    for (unsigned i = 0; i < 5; i++) {
        uint32_t status;
        nda_start(ops[i], (const int32_t *)srcs[i], lens[i], 0);
        if (nda_wait(&status) || status != (6u | ((i + 1u) << 4))) fail = 1;
    }
    nda_write(SOC_NDA_STATUS, 6);
    uart_puts(fail ? "NDA POLL FAIL\n" : "NDA POLL OK\n");
    phase2_irq_enable(SOC_IRQ_NDA);
    nda_start(SOC_NDA_OP_SUM, data, 17, 1);
    for (unsigned t = 0; !nda_irq_count && t < 100000; t++) __asm__ volatile("nop");
    phase2_irq_disable();
    if (nda_irq_count != 1 || irq_error || nda_sum_result() != software_sum(data, 17)) fail = 1;
    uart_puts(fail ? "NDA FAIL\n" : "NDA OK\n");
    uart_drain_tx();
    return fail;
}
