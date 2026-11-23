OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    PAYLOAD_RAM (rwx) : ORIGIN = 0x80200000, LENGTH = 16M
}

SECTIONS {
    .text 0x80200000 : {
        KEEP(*(.text.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > PAYLOAD_RAM

    .data : ALIGN(64) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > PAYLOAD_RAM

    .bss (NOLOAD) : ALIGN(64) {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(64);
        __bss_end = .;
    } > PAYLOAD_RAM
}
