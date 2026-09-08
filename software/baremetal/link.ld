OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128K }
PHDRS { code PT_LOAD FLAGS(5); host PT_LOAD FLAGS(6); data PT_LOAD FLAGS(6); }
SECTIONS {
    .text 0x80000000 : { KEEP(*(.text.init)) *(.text .text.*) *(.rodata .rodata.*) } > RAM :code
    ASSERT(. <= 0x80010000, "text overlaps host mailbox")
    .host 0x80010000 : { KEEP(*(.host)) } > RAM :host
    ASSERT(SIZEOF(.host) == 80, "host contract size changed")
    .data 0x80011000 : { *(.data .data.*) *(.sdata .sdata.*) } > RAM :data
    .bss MAX(ADDR(.data) + SIZEOF(.data), 0x80011000) (NOLOAD) : {
        . = ALIGN(8); __bss_start = .;
        *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON)
        . = ALIGN(8); __bss_end = .;
    } > RAM :data
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
    ASSERT(__bss_end <= __stack_top - 4096, "data overlaps stack reserve")
}
