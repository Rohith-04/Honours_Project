/* linker.ld — honours_soc uart_test (RV32IMC, AXI true RAM 128 KB @ 0x0)
 * Follows Cores-VeeR-EL2/testbench/link.ld: text at 0 (reset vector),
 * data at 0x10000. Stack top at end of the 128 KB window (0x20000).
 */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
    . = 0x0;
    .text : {
        *(.text.init*)
        *(.text*)
    }
    _end = .;
    . = 0x10000;
    .data : ALIGN(0x800) {
        *(.*data)
        *(.rodata*)
        *(.sdata*)
        *(.srodata*)
    }
    .bss : ALIGN(8) {
        *(.bss*)
        *(.sbss*)
        *(COMMON)
    }
    _stack_top = 0x20000;
}
