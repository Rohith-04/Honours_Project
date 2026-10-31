#ifndef SW_PHASE2_IRQ_H
#define SW_PHASE2_IRQ_H
#include "nda.h"
#include "wdt.h"
// VeeR default PIC; the harness routes sources 1..4 as UART/timer/NDA/WDT.
#define PIC_BASE SOC_PIC_BASE
static volatile uint32_t nda_irq_count, wdt_irq_count, irq_error;
static void __attribute__((interrupt("machine"), aligned(4))) phase2_irq(void)
{
    uint32_t cause, claim;
    __asm__ volatile("csrr %0, mcause" : "=r"(cause));
    if (cause != 0x8000000bu) { irq_error = cause | 1u; __asm__ volatile("csrw mie, zero"); return; }
    __asm__ volatile("csrw 0xbca, zero; csrr %0, 0xfc8" : "=r"(claim) :: "memory");
    unsigned id = (claim >> 2) & 255u;
    if (id == SOC_IRQ_NDA) {
        nda_write(SOC_NDA_STATUS, 6u);
        nda_irq_count++;
    } else if (id == SOC_IRQ_WDT) {
        wdt_write(SOC_WDT_STATUS, 1u);
        wdt_irq_count++;
    } else if (id != 0) { irq_error = id; __asm__ volatile("csrw mie, zero"); }
    if (id) mmio_write32(PIC_BASE + 0x5000u + id * 4u, 0);
}
static inline void phase2_irq_enable(unsigned id)
{
    __asm__ volatile("csrci mstatus, 8" ::: "memory");
    mmio_write32(PIC_BASE + 0x3000u, 0);
    mmio_write32(PIC_BASE + id * 4u, 1);
    mmio_write32(PIC_BASE + 0x4000u + id * 4u, 0); // active-high level
    mmio_write32(PIC_BASE + 0x5000u + id * 4u, 0);
    mmio_write32(PIC_BASE + 0x2000u + id * 4u, 1);
    __asm__ volatile("csrw 0xbc8, zero; csrw 0xbc9, zero; csrw 0xbcb, zero; csrw 0xbcc, zero" ::: "memory");
    __asm__ volatile("csrw mtvec, %0" :: "r"(phase2_irq) : "memory");
    __asm__ volatile("csrs mie, %0; csrsi mstatus, 8" :: "r"(1u << 11) : "memory");
}
static inline void phase2_irq_disable(void)
{ __asm__ volatile("csrci mstatus, 8; csrw mie, zero" ::: "memory"); }
#endif
