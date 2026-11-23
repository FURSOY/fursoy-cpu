OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    SBI_RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 2M
}

SECTIONS {
    .text 0x80000000 : {
        KEEP(*(.text.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > SBI_RAM

    .data : ALIGN(64) {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > SBI_RAM

    .bss (NOLOAD) : ALIGN(64) {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(64);
        __bss_end = .;
    } > SBI_RAM

    .stacks (NOLOAD) : ALIGN(64) {
        _sbi_stack_base = .;
        . += (4 * 4096);
        _sbi_stack_top = .;
    } > SBI_RAM

    ASSERT(_sbi_stack_top <= 0x80200000, "SBI image exceeds 2 MiB [0x80000000..0x80200000) window")
}
