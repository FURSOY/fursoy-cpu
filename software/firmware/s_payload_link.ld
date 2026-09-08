/* Linker script for Fursoy Slice-0 S-Mode Verification Payload.
 * Loaded at 0x8020_0000 (standard Linux kernel entry offset).
 */
OUTPUT_ARCH(riscv)
ENTRY(payload_start)

MEMORY {
    S_RAM (rwx) : ORIGIN = 0x80200000, LENGTH = 4M
}

PHDRS {
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS {
    .text 0x80200000 : {
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > S_RAM :text

    .data : {
        . = ALIGN(8);
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > S_RAM :data

    .bss (NOLOAD) : {
        . = ALIGN(8);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    } > S_RAM :data

    __payload_stack_top = ORIGIN(S_RAM) + LENGTH(S_RAM);
}
