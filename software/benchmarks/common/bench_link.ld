OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 256M
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text.init : {
        KEEP(*(.text.init))
    } > RAM

    .text : {
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(16) {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > RAM

    .data : ALIGN(16) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(16) {
        __bss_start = .;
        *(.sbss .sbss.*)
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > RAM

    . = ALIGN(64);
    __heap_start = .;
    __heap_end   = ORIGIN(RAM) + 240M;
    __stack_top  = ORIGIN(RAM) + 255M;

    /DISCARD/ : {
        *(.note.*)
        *(.eh_frame*)
        *(.comment*)
    }
}
