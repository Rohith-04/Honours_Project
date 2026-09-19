// startup.S — minimal RV32IMC boot for honours_soc
// Modelled on Cores-VeeR-EL2/testbench/{link.ld,crt0.s} but without
// defines.h/tohost: program is linked at 0x0 (m00 window), sp set to top
// of the 128 KB true RAM, then main() is called. main must not return
// (it spins after UART TX); if it does, trap here in an infinite loop.
    .section .text.init
    .align 4
    .globl _start
    .option nopic
_start:
    la sp, _stack_top
    call main
1:
    j 1b
