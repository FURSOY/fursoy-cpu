OUTPUT_ARCH("riscv")
ENTRY(payload_start)

MEMORY
{
    /* S-mode Payload region starting at 0x8020_0000 */
    PAYLOAD_RAM (rwx) : ORIGIN = 0x80200000, LENGTH = 0x00E00000
}

SECTIONS
{
    . = ORIGIN(PAYLOAD_RAM);

    .text.entry : {
        *(.text.entry)
    } > PAYLOAD_RAM

    .text : {
        *(.text .text.*)
    } > PAYLOAD_RAM

    .rodata : {
        *(.rodata .rodata.*)
    } > PAYLOAD_RAM

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > PAYLOAD_RAM

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > PAYLOAD_RAM

    /* Dedicated 64 KiB Supervisor Stack */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        __payload_stack_bottom = .;
        . += 0x10000;
        __payload_stack_top = .;
    } > PAYLOAD_RAM

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
