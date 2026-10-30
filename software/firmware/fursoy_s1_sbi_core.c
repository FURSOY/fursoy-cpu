#include "fursoy_s1_sbi.h"

static inline void uart_putc(char c) {
    uint32_t val = (uint32_t)(uint8_t)c;
    asm volatile("nop; nop; nop; nop" ::: "memory");
    *(volatile uint32_t *)UART_THR = val;
    asm volatile("nop; nop; nop; nop" ::: "memory");
}

static void uart_puts(const char *s) {
    while (*s) {
        uart_putc(*s++);
    }
}

static void uart_puthex(uint64_t val) {
    for (int i = 15; i >= 0; i--) {
        uint32_t nibble = (uint32_t)((val >> (i * 4)) & 0xF);
        uart_putc(nibble < 10 ? ('0' + nibble) : ('A' + nibble - 10));
    }
}

// Fixed halt loop for SRST shutdown
__attribute__((noreturn)) void halt_loop(void) {
    // Disable interrupts before halting
    asm volatile("csrw mie, zero");
    while (1) {
        asm volatile("wfi");
    }
}

// Deterministic panic handler for unexpected M-mode traps
__attribute__((noreturn)) void sbi_panic(uint64_t cause, uint64_t epc, uint64_t tval) {
    uart_puts("\n[SBI PANIC] cause=0x");
    uart_puthex(cause);
    uart_puts(" epc=0x");
    uart_puthex(epc);
    uart_puts(" tval=0x");
    uart_puthex(tval);
    uart_puts("\n");
    halt_loop();
}

// M-mode MTIP handler
void sbi_timer_trap_handler(void) {
    // 1. Prevent repeated machine timer traps by masking MTIE in mie
    asm volatile("csrc mie, %0" :: "r"(1ULL << 7));
    // 2. Assert virtual STIP in mip so delegated STIP becomes visible to S-mode
    asm volatile("csrs mip, %0" :: "r"(1ULL << 5));
}

