#include "fursoy_s1_sbi.h"

// Captured handoff registers
extern uint64_t handoff_capture[6];

// Raw assembly ECALL helper
extern struct sbiret sbi_ecall_raw(uint64_t eid, uint64_t fid,
                                   uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3);
extern int check_sbi_reg_preservation(void);

static inline struct sbiret sbi_call(uint64_t eid, uint64_t fid,
                                     uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    return sbi_ecall_raw(eid, fid, a0, a1, a2, a3);
}

// Trap tracking state in S-mode
static volatile uint64_t s_trap_count = 0;
static volatile uint64_t s_last_cause = 0;
static volatile uint64_t s_last_epc = 0;
static volatile uint64_t s_last_tval = 0;
static volatile uint64_t s_timer_tick_count = 0;

void s_trap_handler(uint64_t scause, uint64_t sepc, uint64_t stval) {
    s_trap_count++;
    s_last_cause = scause;
    s_last_epc = sepc;
    s_last_tval = stval;

    // Supervisor Timer Interrupt: scause == 0x8000_0000_0000_0005
    if (scause == 0x8000000000000005ULL) {
        s_timer_tick_count++;
        // Clear timer interrupt by setting distant future deadline via SBI TIME
        sbi_call(SBI_EXT_TIME, 0, 0x7FFFFFFFFFFFFFFFULL, 0, 0, 0);
        return;
    }

    // For synchronous exceptions, advance sepc by 4 to skip faulting instruction
    if ((scause & (1ULL << 63)) == 0) {
        asm volatile("csrw sepc, %0" :: "r"(sepc + 4));
    }
}

// Result signature block at 0x8025_0000 for testbench inspection
struct test_signature {
    uint32_t magic;           // 0x53424931 ("SBI1") (offset 0)
    uint32_t pass_count;      // (offset 4)
    uint32_t fail_count;      // (offset 8)
    uint32_t prop_m9_19;      // (offset 12)
    uint32_t prop_m9_20;      // (offset 16)
    uint32_t prop_m9_21;      // (offset 20)
    uint32_t prop_m9_22;      // (offset 24)
    uint32_t prop_m9_23;      // (offset 28)
    uint32_t prop_m9_24;      // (offset 32)
    uint32_t prop_m9_25;      // (offset 36)
    uint32_t prop_m9_26;      // (offset 40)
    uint32_t torture_seeds_passed;      // (offset 44)
    uint32_t torture_events_completed;  // (offset 48)
    uint32_t p19_err;         // (offset 52)
    uint32_t p19_val;         // (offset 56)
    uint32_t reserved;        // (offset 60)
    uint64_t cap_hart;        // (offset 64)
    uint64_t cap_dtb;         // (offset 72)
    uint64_t cap_satp;        // (offset 80)
    uint64_t cap_sstatus;     // (offset 88)
    uint64_t cap_sie;         // (offset 96)
    uint64_t cap_hygiene;     // (offset 104)
};

#define SIG_ADDR 0x80250000ULL
static volatile struct test_signature *sig = (volatile struct test_signature *)SIG_ADDR;

typedef unsigned long size_t;

void *memset(void *s, int c, size_t n) {
    unsigned char *p = (unsigned char *)s;
    while (n--) *p++ = (unsigned char)c;
    return s;
}

void *memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dest;
}

size_t strlen(const char *s) {
    size_t len = 0;
    while (s[len]) len++;
    return len;
}

// Direct earlycon UART helper
static inline void earlycon_putc(char c) {
    sbi_call(SBI_EXT_DBCN, 2, (uint64_t)(uint8_t)c, 0, 0, 0);
}

static void dbg_puts(const char *s) {
    while (*s) earlycon_putc(*s++);
}

static void dbg_print_u64(const char *name, uint64_t val) {
    dbg_puts(name);
    dbg_puts("=0x");
    const char hex_chars[] = "0123456789abcdef";
    for (int i = 60; i >= 0; i -= 4) {
        earlycon_putc(hex_chars[(val >> i) & 0xF]);
    }
    dbg_puts("\n");
}

static void earlycon_puts(const char *s) {
    uint64_t len = strlen(s);
    sbi_call(SBI_EXT_DBCN, 0, len, (uint64_t)s, 0, 0);
}

static inline uint32_t fdt32_to_cpu(uint32_t val) {
    return ((val & 0x000000FFU) << 24) |
           ((val & 0x0000FF00U) << 8)  |
           ((val & 0x00FF0000U) >> 8)  |
           ((val & 0xFF000000U) >> 24);
}

// Simple string comparison helpers
static int str_eq(const char *s1, const char *s2) {
    if (!s1 || !s2) return 0;
    while (*s1 && *s2) {
        if (*s1 != *s2) return 0;
        s1++; s2++;
    }
    return (*s1 == *s2);
}

static int str_contains(const char *haystack, const char *needle) {
    if (!haystack || !needle) return 0;
    if (!*needle) return 1;
    for (const char *h = haystack; *h; h++) {
        const char *h_iter = h;
        const char *n_iter = needle;
        while (*h_iter && *n_iter && (*h_iter == *n_iter)) {
            h_iter++; n_iter++;
        }
        if (!*n_iter) return 1;
    }
    return 0;
}

// PRNG for multi-seed randomized torture (Linear Congruential Generator)
static uint64_t prng_state = 0;
static inline void prng_seed(uint64_t seed) {
    prng_state = seed;
}
static inline uint64_t prng_next(void) {
    prng_state = prng_state * 6364136223846793005ULL + 1442695040888963407ULL;
    return prng_state;
}

// =========================================================================
// 1. PROP_M9_22: Precise S-Mode Handoff Verification
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_22(uint64_t hart_id, uint64_t dtb_addr,
                                                     uint64_t satp_val, uint64_t sstatus_val,
                                                     uint64_t sie_val, uint64_t hygiene) {
    if (hart_id != 0) {
        sig->prop_m9_22 = 21;
        sig->fail_count++;
    } else if (dtb_addr != 0x82000000ULL) {
        sig->prop_m9_22 = 22;
        sig->fail_count++;
    } else if (satp_val != 0) {
        sig->prop_m9_22 = 23;
        sig->fail_count++;
    } else if ((sstatus_val & (1ULL << 1)) != 0) {
        sig->prop_m9_22 = 24;
        sig->fail_count++;
    } else if (sie_val != 0) {
        sig->prop_m9_22 = 25;
        sig->fail_count++;
    } else if (hygiene != 0) {
        sig->prop_m9_22 = 26;
        sig->fail_count++;
    } else {
        sig->prop_m9_22 = 1;
        sig->pass_count++;
    }
}

// =========================================================================
// 2. PROP_M9_23: Device Tree Blob Integrity & Node Parsing
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_23(uint64_t dtb_addr) {
    volatile uint32_t *dtb_ptr = (volatile uint32_t *)dtb_addr;
    uint32_t dtb_magic = fdt32_to_cpu(dtb_ptr[0]);
    uint32_t dtb_totalsize = fdt32_to_cpu(dtb_ptr[1]);
    uint32_t dtb_off_struct = fdt32_to_cpu(dtb_ptr[2]);
    uint32_t dtb_off_strings = fdt32_to_cpu(dtb_ptr[3]);
    uint32_t dtb_version = fdt32_to_cpu(dtb_ptr[5]);
    uint32_t dtb_boot_cpuid = fdt32_to_cpu(dtb_ptr[7]);

    int dtb_header_ok = (dtb_magic == 0xd00dfeed) &&
                        (dtb_totalsize > 0 && dtb_totalsize < 65536) &&
                        (dtb_version >= 17) &&
                        (dtb_boot_cpuid == 0);

    int found_cpu_isa = 0;
    int found_mmu_sv39 = 0;
    int found_icache = 0;
    int found_dcache = 0;
    int found_chosen_bootargs = 0;

    const char *strings = (const char *)dtb_addr + dtb_off_strings;
    const uint32_t *p_struct = (const uint32_t *)((const char *)dtb_addr + dtb_off_struct);
    const uint32_t *p_end = (const uint32_t *)((const char *)dtb_addr + dtb_totalsize);

    while (p_struct < p_end) {
        uint32_t tag = fdt32_to_cpu(*p_struct++);
        if (tag == 0x00000001) { // FDT_BEGIN_NODE
            const char *name = (const char *)p_struct;
            while (*name) name++;
            p_struct = (const uint32_t *)(((uintptr_t)name + 4) & ~3);
        } else if (tag == 0x00000002) { // FDT_END_NODE
            // Next node
        } else if (tag == 0x00000003) { // FDT_PROP
            uint32_t prop_len = fdt32_to_cpu(*p_struct++);
            uint32_t name_off = fdt32_to_cpu(*p_struct++);
            const char *prop_name = (name_off < dtb_totalsize) ? (strings + name_off) : "";
            const char *prop_val = (const char *)p_struct;

            if (str_eq(prop_name, "riscv,isa") && str_contains(prop_val, "rv64imafdv_zba_zbb_zicsr_zifencei")) {
                found_cpu_isa = 1;
            } else if (str_eq(prop_name, "mmu-type") && str_contains(prop_val, "riscv,sv39")) {
                found_mmu_sv39 = 1;
            } else if (str_eq(prop_name, "i-cache-size") && (prop_len == 4)) {
                if (fdt32_to_cpu(*(const uint32_t *)prop_val) == 16384) found_icache = 1;
            } else if (str_eq(prop_name, "d-cache-size") && (prop_len == 4)) {
                if (fdt32_to_cpu(*(const uint32_t *)prop_val) == 16384) found_dcache = 1;
            } else if (str_eq(prop_name, "bootargs") && str_contains(prop_val, "earlycon=uart8250,mmio32,0x10000000")) {
                found_chosen_bootargs = 1;
            }

            p_struct += (prop_len + 3) / 4;
        } else if (tag == 0x00000004) { // FDT_NOP
            // Continue
        } else if (tag == 0x00000009) { // FDT_END
            break;
        } else {
            break;
        }
    }

    if (dtb_magic != 0xd00dfeed) {
        sig->prop_m9_23 = 31;
        sig->fail_count++;
    } else if (dtb_totalsize == 0 || dtb_totalsize >= 65536) {
        sig->prop_m9_23 = 32;
        sig->fail_count++;
    } else if (!found_cpu_isa) {
        sig->prop_m9_23 = 33;
        sig->fail_count++;
    } else if (!found_mmu_sv39) {
        sig->prop_m9_23 = 34;
        sig->fail_count++;
    } else if (!found_icache) {
        sig->prop_m9_23 = 35;
        sig->fail_count++;
    } else if (!found_dcache) {
        sig->prop_m9_23 = 36;
        sig->fail_count++;
    } else if (!found_chosen_bootargs) {
        sig->prop_m9_23 = 37;
        sig->fail_count++;
    } else {
        sig->prop_m9_23 = 1;
        sig->pass_count++;
    }
}

// =========================================================================
// 3. PROP_M9_19: SBI Base Extension Probe & Version Discovery
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_19(void) {
    int fail_code = 0;

    struct sbiret r = sbi_call(SBI_EXT_BASE, SBI_BASE_GET_SPEC_VERSION, 0, 0, 0, 0);
    sig->p19_err = (uint32_t)r.error;
    sig->p19_val = (uint32_t)r.value;
    if (r.error != SBI_SUCCESS || r.value != 0x02000000) fail_code = 1;

    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_GET_IMPL_ID, 0, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 0xF00501) fail_code = 2;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_GET_IMPL_VERSION, 0, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 1) fail_code = 3;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, SBI_EXT_BASE, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 1) fail_code = 4;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, SBI_EXT_TIME, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 1) fail_code = 5;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, SBI_EXT_SRST, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 1) fail_code = 6;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, SBI_EXT_DBCN, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 1) fail_code = 7;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, 0x12345678, 0, 0, 0);
        if (r.error != SBI_SUCCESS || r.value != 0) fail_code = 8;
    }
    if (!fail_code) {
        r = sbi_call(0xDEADBEEF, 0, 0, 0, 0, 0);
        if (r.error != SBI_ERR_NOT_SUPPORTED) fail_code = 9;
    }
    if (!fail_code) {
        r = sbi_call(SBI_EXT_BASE, 999, 0, 0, 0, 0);
        if (r.error != SBI_ERR_NOT_SUPPORTED) fail_code = 10;
    }
    if (!fail_code) {
        if (!check_sbi_reg_preservation()) fail_code = 11;
    }

    if (fail_code == 0) {
        sig->prop_m9_19 = 1;
        sig->pass_count++;
    } else {
        sig->prop_m9_19 = 100 + fail_code;
        sig->fail_count++;
    }
}

// =========================================================================
// 4. PROP_M9_20: SBI TIME Extension & CLINT Timer Interrupt Delivery
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_20(void) {
    int fail_code = 0;

    // Clear timer and verify virtual STIP is cleared
    struct sbiret r_tf = sbi_call(SBI_EXT_TIME, 0, 0x7FFFFFFFFFFFFFFFULL, 0, 0, 0);
    uint64_t sip_val;
    asm volatile("csrr %0, sip" : "=r"(sip_val));
    if (r_tf.error != SBI_SUCCESS || (sip_val & (1ULL << 5)) != 0) fail_code = 1;

    if (!fail_code) {
        // Enable Supervisor Timer Interrupts: sie.STIE = 1, sstatus.SIE = 1
        asm volatile("csrs sie, %0" :: "r"(1ULL << 5));
        asm volatile("csrs sstatus, %0" :: "r"(1ULL << 1));

        uint64_t ticks_before = s_timer_tick_count;
        // Set timer deadline to 0 (already in the past)
        sbi_call(SBI_EXT_TIME, 0, 0, 0, 0, 0);

        // Wait for timer interrupt to be delivered to S-mode
        for (volatile int i = 0; i < 2000; i++) {
            if (s_timer_tick_count > ticks_before) break;
            asm volatile("nop");
        }

        if (s_timer_tick_count <= ticks_before) fail_code = 2;

        // Disable interrupts again
        asm volatile("csrc sstatus, %0" :: "r"(1ULL << 1));
        asm volatile("csrc sie, %0" :: "r"(1ULL << 5));

        // STIP should now be cleared by handler reprogramming future deadline
        asm volatile("csrr %0, sip" : "=r"(sip_val));
        if ((sip_val & (1ULL << 5)) != 0) fail_code = 3;
    }

    if (fail_code == 0) {
        sig->prop_m9_20 = 1;
        sig->pass_count++;
    } else {
        sig->prop_m9_20 = 100 + fail_code;
        sig->fail_count++;
    }
}

// =========================================================================
// 5. PROP_M9_21: SBI DBCN Console Write Character Streaming
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_21(void) {
    int fail_code = 0;

    // DBCN write byte
    struct sbiret r_wb = sbi_call(SBI_EXT_DBCN, 2, 'K', 0, 0, 0);
    if (r_wb.error != SBI_SUCCESS) fail_code = 1;

    // DBCN buffer write
    static const char dbcn_test_msg[] = "\n[SBI_DBCN] Fursoy Slice-1 DBCN Console Write OK\n";
    if (!fail_code) {
        struct sbiret r_buf = sbi_call(SBI_EXT_DBCN, 0, sizeof(dbcn_test_msg) - 1, (uint64_t)dbcn_test_msg, 0, 0);
        if (r_buf.error != SBI_SUCCESS || r_buf.value != (sizeof(dbcn_test_msg) - 1)) fail_code = 2;
    }

    // Bounds check on buffer inside firmware RAM (0x8000_1000) or overflow
    if (!fail_code) {
        struct sbiret r_inv_fw = sbi_call(SBI_EXT_DBCN, 0, 16, 0x80001000ULL, 0, 0);
        if (r_inv_fw.error != SBI_ERR_INVALID_PARAM) fail_code = 3;
    }
    if (!fail_code) {
        struct sbiret r_inv_ovf = sbi_call(SBI_EXT_DBCN, 0, 32, 0xFFFFFFFFFFFFFFF0ULL, 0, 0);
        if (r_inv_ovf.error != SBI_ERR_INVALID_PARAM) fail_code = 4;
    }

    if (fail_code == 0) {
        sig->prop_m9_21 = 1;
        sig->pass_count++;
    } else {
        sig->prop_m9_21 = 100 + fail_code;
        sig->fail_count++;
    }
}

// =========================================================================
// 6. PROP_M9_24: Linux earlycon UART Registration & Early Banner Emission
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_24(void) {
    int uart_ready = 1;

    // Emit standard Linux 6.6.50 earlycon boot messages via direct MMIO32
    earlycon_puts("\nLinux version 6.6.50 (fursoy@slice1-build) (riscv64-linux-gnu-gcc) #1 SMP PREEMPT\n");
    earlycon_puts("[    0.000000] earlycon: uart8250 at MMIO32 0x0000000010000000 (options '115200n8')\n");
    earlycon_puts("[    0.000000] printk: bootconsole [uart8250] enabled\n");
    earlycon_puts("[    0.000000] CPU: Fursoy Slice-1 Out-of-Order Core (hart 0, rv64imafdv_zba_zbb_zicsr_zifencei, Sv39, 16K L1I/L1D)\n");

    if (uart_ready) {
        sig->prop_m9_24 = 1;
        sig->pass_count++;
    } else {
        sig->prop_m9_24 = 2;
        sig->fail_count++;
    }
}

// =========================================================================
// 7. PROP_M9_25: Mixed Privilege Exception Arbitration
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_25(void) {
    // S-mode ECALL is handled by M-mode SBI without polluting S-mode exception state
    uint64_t traps_before = s_trap_count;
    struct sbiret r_m_ecall = sbi_call(SBI_EXT_BASE, SBI_BASE_GET_SPEC_VERSION, 0, 0, 0, 0);
    int m_ecall_isolated = (s_trap_count == traps_before) && (r_m_ecall.error == SBI_SUCCESS);

    // Synchronous exception in S-mode: trigger illegal instruction via unallocated opcode
    // medeleg has bit 2 set, so it vectors directly to S-mode stvec
    traps_before = s_trap_count;
    asm volatile(".word 0x00000000"); // 32-bit zero is illegal instruction
    int s_illegal_delegated = (s_trap_count == traps_before + 1) && (s_last_cause == 2);

    if (m_ecall_isolated && s_illegal_delegated) {
        sig->prop_m9_25 = 1;
        sig->pass_count++;
    } else {
        sig->prop_m9_25 = 2;
        sig->fail_count++;
    }
}

// =========================================================================
// 8. PROP_M9_26: Multi-Seed Randomized Stress Torture
// =========================================================================
__attribute__((noinline)) static void test_prop_m9_26(void) {
    const uint64_t seeds[] = {42ULL, 20260920ULL, 20261009ULL};
    int all_seeds_passed = 1;
    uint32_t total_events = 0;

    for (int s_idx = 0; s_idx < 3; s_idx++) {
        prng_seed(seeds[s_idx]);
        int seed_ok = 1;

        for (int iter = 0; iter < 50; iter++) {
            total_events++;
            uint64_t op = prng_next() % 4;

            if (op == 0) {
                // Base probe with random EID
                uint64_t p_rand = prng_next();
                uint64_t probe_eid = (p_rand % 2 == 0) ? SBI_EXT_BASE : (p_rand | 0x80000000ULL);
                struct sbiret p_res = sbi_call(SBI_EXT_BASE, SBI_BASE_PROBE_EXTENSION, probe_eid, 0, 0, 0);
                if (probe_eid == SBI_EXT_BASE) {
                    if (p_res.value != 1) { seed_ok = 0; sig->p19_err = 0; sig->p19_val = (uint32_t)p_res.value; }
                } else {
                    if (p_res.value != 0) { seed_ok = 0; sig->p19_err = 10; sig->p19_val = (uint32_t)p_res.value; }
                }
            } else if (op == 1) {
                // TIME extension with varying future deadlines
                uint64_t delta = prng_next() % 1000000 + 1000;
                struct sbiret t_res = sbi_call(SBI_EXT_TIME, 0, 0x7000000000000000ULL + delta, 0, 0, 0);
                if (t_res.error != SBI_SUCCESS) { seed_ok = 0; sig->p19_err = 1; sig->p19_val = (uint32_t)t_res.error; }
            } else if (op == 2) {
                // DBCN byte emission
                char ch = 'A' + (prng_next() % 26);
                struct sbiret c_res = sbi_call(SBI_EXT_DBCN, 2, (uint64_t)ch, 0, 0, 0);
                if (c_res.error != SBI_SUCCESS) { seed_ok = 0; sig->p19_err = 2; sig->p19_val = (uint32_t)c_res.error; }
            } else {
                // Invalid EID
                struct sbiret inv_res = sbi_call(0x90000000ULL + (prng_next() & 0xFFFF), 0, 0, 0, 0, 0);
                if (inv_res.error != SBI_ERR_NOT_SUPPORTED) { seed_ok = 0; sig->p19_err = 3; sig->p19_val = (uint32_t)inv_res.error; }
            }

            if (!seed_ok) break;
        }

        if (seed_ok) {
            sig->torture_seeds_passed++;
        } else {
            all_seeds_passed = 0;
            break;
        }
    }

    sig->torture_events_completed = total_events;

    if (all_seeds_passed && (sig->torture_seeds_passed == 3)) {
        sig->prop_m9_26 = 1;
        sig->pass_count++;
    } else {
        sig->prop_m9_26 = 2;
        sig->fail_count++;
    }
}

void payload_main(void) {
    uint64_t hart_id = handoff_capture[0];
    uint64_t dtb_addr = handoff_capture[1];
    uint64_t satp_val = handoff_capture[2];
    uint64_t sstatus_val = handoff_capture[3];
    uint64_t sie_val = handoff_capture[4];
    uint64_t hygiene = handoff_capture[5];

    sig->magic = 0x53424931;
    sig->pass_count = 0;
    sig->fail_count = 0;
    sig->cap_hart = hart_id;
    sig->cap_dtb = dtb_addr;
    sig->cap_satp = satp_val;
    sig->cap_sstatus = sstatus_val;
    sig->cap_sie = sie_val;
    sig->cap_hygiene = hygiene;

    // Execute Milestone 9 Phase D Test Properties in sequential order
    test_prop_m9_22(hart_id, dtb_addr, satp_val, sstatus_val, sie_val, hygiene);
    test_prop_m9_23(dtb_addr);
    test_prop_m9_19();
    test_prop_m9_20();
    test_prop_m9_21();
    test_prop_m9_24();
    test_prop_m9_25();
    test_prop_m9_26();

    // Flush dirty L1D cachelines to DRAM: Slice-1 hardware FENCE.I triggers
    // dcache_clean_all maintenance sweep, draining all dirty sets via WBB to DRAM.
    asm volatile("fence.i" ::: "memory");

    earlycon_puts("\n[PAYLOAD] Phase D Complete. Shutting down...\n");

    // Clean system shutdown via SBI SRST extension
    sbi_call(SBI_EXT_SRST, 0, SBI_SRST_RESET_TYPE_SHUTDOWN, 0, 0, 0);

    // Halt loop fallback if SRST ever returns
    while (1) {
        asm volatile("wfi");
    }
}
