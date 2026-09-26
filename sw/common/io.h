// io.h — MMIO helpers. Every register write is followed by fence, per the
// VeeR EL2 PRM Memory Map chapter ("All memory-mapped register writes must
// be followed by a fence instruction"). Reads use a volatile pointer so the
// compiler cannot coalesce or drop them.
#ifndef SW_IO_H
#define SW_IO_H

#include <stdint.h>

static inline void mmio_write32(uint32_t addr, uint32_t val)
{
    *(volatile uint32_t *)addr = val;
    __asm__ volatile("fence" ::: "memory");
}

static inline uint32_t mmio_read32(uint32_t addr)
{
    uint32_t v = *(volatile uint32_t *)addr;
    return v;
}

#endif // SW_IO_H
