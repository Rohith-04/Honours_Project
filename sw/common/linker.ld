/* linker.ld — Phase 1 SW memory layout: everything in 64 KiB AXI RAM.
 *
 * RAM 0x0000_0000 - 0x0000_FFFF. Reset vector is 0x0 so .text.init (with
 * _start) goes first. Stack grows down from 0x0001_0000. The .signature
 * section is pinned at 0x0000_7FF0: code+data of these tiny tests stays
 * well below it and the stack stays well above, so the TB's result-word
 * check never collides with either.
 */
MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

ENTRY(_start)

SECTIONS
{
    .text.init 0x00000000 : {
        KEEP(*(.text.init))
    } > RAM

    .text : {
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss (NOLOAD) : {
        *(.bss*)
        *(.sbss*)
        *(COMMON)
    } > RAM

    /* Pinned result word for the TB signature check. */
    .signature 0x00007FF0 (NOLOAD) : {
        KEEP(*(.signature))
    } > RAM

    PROVIDE(_stack_top = ORIGIN(RAM) + LENGTH(RAM));
}
