#ifndef SW_WDT_H
#define SW_WDT_H
#include "io.h"
#include "soc_map.h"
static inline void wdt_write(uint32_t offset, uint32_t value)
{ mmio_write32(SOC_WDT_BASE + offset, value); }
static inline uint32_t wdt_read(uint32_t offset)
{ return mmio_read32(SOC_WDT_BASE + offset); }
static inline void wdt_enable(uint32_t timeout, uint32_t irq_enable)
{
    wdt_write(SOC_WDT_TIMEOUT, timeout);
    wdt_write(SOC_WDT_STATUS, 1u);
    wdt_write(SOC_WDT_CTRL, 1u | (irq_enable ? 4u : 0u));
}
#endif
