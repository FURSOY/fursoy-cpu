OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    /* 2 MiB firmware region reserved from DRAM base */
    FW_RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 0x00200000
}

SECTIONS
{
    . = ORIGIN(FW_RAM);

    .text.init : {
        *(.text.init)
    } > FW_RAM

    .text : {
        *(.text .text.*)
    } > FW_RAM

    .rodata : {
        *(.rodata .rodata.*)
    } > FW_RAM

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > FW_RAM

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > FW_RAM

    /* Dedicated 64 KiB Machine Stack inside firmware memory */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        __stack_bottom = .;
        . += 0x10000;
        __stack_top = .;
    } > FW_RAM

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
