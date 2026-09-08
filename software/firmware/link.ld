/* Linker script for Fursoy Slice-0 Minimal SBI Firmware.
 * Execution starts at 0x8000_0000 inside the 2 MiB firmware reservation
 * (0x8000_0000 .. 0x801F_FFFF).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    FW_RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 2M
}

PHDRS {
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS {
    .text 0x80000000 : {
        KEEP(*(.text.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > FW_RAM :text

    .data : {
        . = ALIGN(8);
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > FW_RAM :data

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > FW_RAM :data

    /* 64 KiB stack at the top of 2 MiB firmware reservation */
    __stack_top = ORIGIN(FW_RAM) + LENGTH(FW_RAM);
    ASSERT(__bss_end <= __stack_top - 0x10000, "firmware data overlaps stack reserve")
}
