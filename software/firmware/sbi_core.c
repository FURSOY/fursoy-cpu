#include "sbi.h"

// Write single byte to UART using strictly naturally aligned 32-bit MMIO access
static inline void uart_putc(char c) {
    *(volatile uint32_t *)UART_THR = (uint32_t)(uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) {
        uart_putc(*s++);
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
    uart_puts("\n[SBI PANIC] Unexpected M-mode trap!\n");
    halt_loop();
}

// M-mode MTIP handler
void sbi_timer_trap_handler(void) {
    // 1. Prevent repeated machine timer traps by masking MTIE in mie
    asm volatile("csrc mie, %0" :: "r"(1ULL << 7));
    // 2. Assert virtual STIP in mip so delegated STIP becomes visible to S-mode
    asm volatile("csrs mip, %0" :: "r"(1ULL << 5));
}

struct sbiret sbi_ecall_dispatch(uint64_t eid, uint64_t fid,
                                 uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    struct sbiret ret;
    ret.error = SBI_SUCCESS;
    ret.value = 0;

    switch (eid) {
    case SBI_EXT_BASE:
        switch (fid) {
        case SBI_BASE_GET_SPEC_VERSION:
            ret.value = 0x02000000; // SBI v2.0
            break;
        case SBI_BASE_GET_IMPL_ID:
            ret.value = 0xF00501;   // Fursoy Minimal SBI Implementation ID
            break;
        case SBI_BASE_GET_IMPL_VERSION:
            ret.value = 1;          // Implementation version 1
            break;
        case SBI_BASE_PROBE_EXTENSION:
            if (a0 == SBI_EXT_BASE || a0 == SBI_EXT_TIME ||
                a0 == SBI_EXT_SRST || a0 == SBI_EXT_DBCN) {
                ret.value = 1;
            } else {
                ret.value = 0;
            }
            break;
        case SBI_BASE_GET_MVENDORID:
        case SBI_BASE_GET_MARCHID:
        case SBI_BASE_GET_MIMPID:
            ret.value = 0;
            break;
        default:
            ret.error = SBI_ERR_NOT_SUPPORTED;
            break;
        }
        break;

    case SBI_EXT_TIME:
        if (fid == 0) {
            uint64_t stime_value = a0;
            // 1. Clear virtual STIP
            asm volatile("csrc mip, %0" :: "r"(1ULL << 5));

            if (stime_value == (uint64_t)-1) {
                // Disable timer
                asm volatile("csrc mie, %0" :: "r"(1ULL << 7));
                *(volatile uint64_t *)CLINT_MTIMECMP = (uint64_t)-1;
            } else {
                // Write deadline to CLINT mtimecmp
                *(volatile uint64_t *)CLINT_MTIMECMP = stime_value;
                // Enable MTIE
                asm volatile("csrs mie, %0" :: "r"(1ULL << 7));
            }
            ret.error = SBI_SUCCESS;
            ret.value = 0;
        } else {
            ret.error = SBI_ERR_NOT_SUPPORTED;
        }
        break;

    case SBI_EXT_SRST:
        if (fid == 0) {
            uint64_t reset_type = a0;
            if (reset_type == SBI_SRST_RESET_TYPE_SHUTDOWN) {
                uart_puts("Fursoy platform halted.\n");
                halt_loop();
            } else if (reset_type == SBI_SRST_RESET_TYPE_COLD_REBOOT ||
                       reset_type == SBI_SRST_RESET_TYPE_WARM_REBOOT) {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            } else {
                ret.error = SBI_ERR_INVALID_PARAM;
            }
        } else {
            ret.error = SBI_ERR_NOT_SUPPORTED;
        }
        break;

    case SBI_EXT_DBCN:
        switch (fid) {
        case 0: { // sbi_debug_console_write(num_bytes, base_addr_lo, base_addr_hi)
            uint64_t num_bytes = a0;
            uint64_t base_addr = (a2 == 0) ? a1 : (((uint64_t)a2 << 32) | (a1 & 0xFFFFFFFFULL));
            if (num_bytes == 0) {
                ret.error = SBI_SUCCESS;
                ret.value = 0;
                break;
            }
            // Check overflow and validate that physical buffer lies strictly inside permitted supervisor DRAM:
            // 0x8020_0000 .. 0x9000_0000 (256 MiB DRAM starting above 2 MiB firmware reservation)
            if (base_addr < 0x80200000ULL ||
                (base_addr + num_bytes) > 0x90000000ULL ||
                (base_addr + num_bytes) < base_addr) {
                ret.error = SBI_ERR_INVALID_PARAM;
                ret.value = 0;
                break;
            }
            const uint8_t *src = (const uint8_t *)base_addr;
            for (uint64_t i = 0; i < num_bytes; i++) {
                uart_putc((char)src[i]);
            }
            ret.error = SBI_SUCCESS;
            ret.value = num_bytes;
            break;
        }
        case 1: { // sbi_debug_console_read
            // Deterministic non-interactive console: 0 bytes read
            ret.error = SBI_SUCCESS;
            ret.value = 0;
            break;
        }
        case 2: { // sbi_debug_console_write_byte(byte)
            uart_putc((char)(uint8_t)a0);
            ret.error = SBI_SUCCESS;
            ret.value = 0;
            break;
        }
        default:
            ret.error = SBI_ERR_NOT_SUPPORTED;
            break;
        }
        break;

    default:
        ret.error = SBI_ERR_NOT_SUPPORTED;
        break;
    }

    return ret;
}
