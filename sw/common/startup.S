// =============================================================================
// startup.S — VeeR EL2 reset entry for Phase 1 SW tests.
//
// - Linked at 0x0000_0000 (see linker.ld); harness drives rst_vec=0.
// - Sets mtvec to the trap handler, stack pointer to top of RAM,
//   configures mrac CSR 0x7C0: region 1 (UART/Timer/GPIO) and region 5
//   (NDA/HPM/WDT) side-effecting + non-cacheable, everything else kept
//   idempotent + non-cacheable (safe bring-up: no caching, strict order).
//   Follows with fence + fence.i per the PRM Memory Map chapter.
// - Calls main(), then reports: a0==0 from main means PASS.
//   Writes the .signature result word, emits ebreak for the TB harness.
// - Trap handler: records 0xDEAD in the result word and ebreaks (any trap
//   in these poll-only tests is a failure).
// =============================================================================
    .section .text.init, "ax"
    .globl _start
    .type _start, @function
_start:
    // Trap vector first: any early trap must land somewhere sane.
    la   t0, trap_handler
    csrw mtvec, t0

    // Stack top (see linker.ld PROVIDE _stack_top = 0x00010000).
    la   sp, _stack_top

    // mfdc bit2 (wbcd): disable Write Buffer coalescing so back-to-back
    // MMIO writes (e.g. UART THR bytes) can never merge. Fence.i before
    // and after, per the PRM Core Control chapter. Mirrors the practice
    // in Cores-VeeR-EL2/testbench/asm/icache.s.
    fence.i
    li   t0, 0x4
    csrw 0x7f9, t0
    fence.i

    // MRAC side-effect bits: region 1 bit 3, region 5 bit 11.
    li   t0, 0x808      // regions 1 and 5: side-effecting, non-cacheable
    csrw 0x7c0, t0
    fence
    fence.i

    // Initialize C zero-storage independently of simulation RAM contents.
    la   t0, __bss_start
    la   t1, __bss_end
.Lbss:
    bgeu t0, t1, .Lbss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    .Lbss
.Lbss_done:
    // Clear result word to 0 (= running, not yet passed).
    la   t0, sw_result
    sw   zero, 0(t0)
    fence

    jal  ra, main        // a0 = 0 on success by convention

    // a0==0 -> PASS pattern, else 0xDEAD.
    la   t0, sw_result
    beqz a0, .Lpass
    li   t1, 0xDEAD
    sw   t1, 0(t0)
    fence
    j    .Lhalt
.Lpass:
    li   t1, 0x50515353  // 'PASS'
    sw   t1, 0(t0)
    fence
.Lhalt:
    ebreak
    j    .Lhalt          // if debugger resumes, halt again

    .section .text, "ax"
    .globl trap_handler
    .type trap_handler, @function
trap_handler:
    la   t0, sw_result
    li   t1, 0xDEAD
    sw   t1, 0(t0)
    fence
    ebreak
    j    trap_handler    // resume -> trap again (stay visibly failed)
