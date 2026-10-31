#ifndef SW_HPM_H
#define SW_HPM_H
#include "io.h"
#include "soc_map.h"
// Bus/fallback counters run continuously; ENABLE gates CYCLES/NDA_BUSY.
// Snapshot before reading pairs. Reads do not change the saved snapshot.
static inline void hpm_control(uint32_t value)
{ mmio_write32(SOC_HPM_BASE + SOC_HPM_CTRL, value); }
static inline uint64_t hpm_read_snapshot(uint32_t offset)
{
    uint64_t lo = mmio_read32(SOC_HPM_BASE + offset);
    uint64_t hi = mmio_read32(SOC_HPM_BASE + offset + 4u);
    return (hi << 32) | lo;
}
#endif
