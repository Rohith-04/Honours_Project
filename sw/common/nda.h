// Synchronous NDA driver. All addresses/fields come from the generated map.
#ifndef SW_NDA_H
#define SW_NDA_H
#include "io.h"
#include "soc_map.h"

static inline uint32_t nda_reg(uint32_t offset)
{ return mmio_read32(SOC_NDA_BASE + offset); }
static inline void nda_write(uint32_t offset, uint32_t value)
{ mmio_write32(SOC_NDA_BASE + offset, value); }
static inline void nda_start(uint32_t op, const int32_t *src, uint32_t n,
                             uint32_t irq_enable)
{
    // Publish CPU stores before the independent AXI master reads the array.
    __asm__ volatile("fence rw,rw" ::: "memory");
    nda_write(SOC_NDA_OP, op);
    nda_write(SOC_NDA_SRC_BASE, (uint32_t)src);
    nda_write(SOC_NDA_LEN, n);
    nda_write(SOC_NDA_CTRL, 1u | (irq_enable ? 4u : 0u));
}
static inline int nda_wait(uint32_t *status)
{
    for (unsigned i = 0; i < 100000u; i++) {
        *status = nda_reg(SOC_NDA_STATUS);
        if (*status & (1u << SOC_NDA_STATUS_DONE)) return 0;
    }
    return -1;
}
static inline int64_t nda_sum_result(void)
{
    uint64_t lo = nda_reg(SOC_NDA_RESULT_LO);
    uint64_t hi = nda_reg(SOC_NDA_RESULT_HI);
    return (int64_t)((hi << 32) | lo);
}
static inline int64_t software_sum(const int32_t *a, unsigned n)
{
    int64_t result = 0;
    for (unsigned i = 0; i < n; i++) result += a[i];
    return result;
}
#endif
