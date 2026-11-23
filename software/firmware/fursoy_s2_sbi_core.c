#include "fursoy_s2_sbi.h"

#ifndef FURSOY_NUM_HARTS
#define FURSOY_NUM_HARTS SBI_MAX_HARTS
#endif

extern void _sbi_secondary_park(void) __attribute__((noreturn));

volatile uint64_t g_sbi_num_harts = FURSOY_NUM_HARTS;
volatile uint64_t g_sbi_dtb_addr  = DTB_DEFAULT_ADDR;

static sbi_hart_t g_harts[SBI_MAX_HARTS];
static volatile uint32_t g_uart_lock = 0;
static volatile uint32_t g_rfence_lock = 0;
static volatile uint32_t g_hsm_lock = 0;
static volatile uint64_t g_rfence_ack_mask = 0;

static inline uint64_t read_mhartid(void) {
    uint64_t v;
    __asm__ volatile("csrr %0, mhartid" : "=r"(v));
    return v;
}

static inline uint64_t read_mip(void) {
    uint64_t v;
    __asm__ volatile("csrr %0, mip" : "=r"(v));
    return v;
}

static inline void fence_rw(void) {
    __asm__ volatile("fence rw, rw" ::: "memory");
}

static void uart_putc_unlocked(uint8_t ch) {
    while ((UART_LSR & UART_LSR_THRE) == 0U) {
        /* wait for TX holding register empty */
    }
    UART_THR = (uint32_t)ch;
}

static void uart_puts_unlocked(const char *s) {
    while (*s) {
        uart_putc_unlocked((uint8_t)*s++);
    }
}

static void uart_puthex_unlocked(uint64_t val) {
    for (int sh = 60; sh >= 0; sh -= 4) {
        uint64_t nib = (val >> sh) & 0xFUL;
        uart_putc_unlocked((uint8_t)(nib < 10 ? ('0' + nib) : ('a' + nib - 10)));
    }
}

static void spin_lock_polling_msip(volatile uint32_t *lock, uint64_t self) {
    while (__atomic_exchange_n(lock, 1U, __ATOMIC_ACQUIRE) != 0U) {
        if (read_mip() & (1UL << 3)) {
            sbi_handle_msip(self);
        }
    }
}

static void spin_unlock(volatile uint32_t *lock) {
    __atomic_store_n(lock, 0U, __ATOMIC_RELEASE);
}

void sbi_init_bsp(uint64_t num_harts, uint64_t dtb_addr) {
    if (num_harts > SBI_MAX_HARTS) {
        num_harts = SBI_MAX_HARTS;
    }
    g_sbi_num_harts = (num_harts == 0UL) ? FURSOY_NUM_HARTS : num_harts;
    g_sbi_dtb_addr  = (dtb_addr != 0UL) ? dtb_addr : DTB_DEFAULT_ADDR;

    for (uint64_t h = 0; h < SBI_MAX_HARTS; h++) {
        g_harts[h].hsm_state   = (h == 0UL) ? SBI_HSM_STATE_STARTED : SBI_HSM_STATE_STOPPED;
        g_harts[h].start_addr  = 0UL;
        g_harts[h].opaque      = 0UL;
        g_harts[h].pending_ipi = 0U;
        g_harts[h].rfence_addr = 0UL;
        g_harts[h].rfence_size = 0UL;
        g_harts[h].rfence_asid = 0UL;
        if (h < g_sbi_num_harts) {
            CLINT_MSIP(h)     = 0U;
            CLINT_MTIMECMP(h) = ~0ULL;
        }
    }
    g_uart_lock       = 0U;
    g_rfence_lock     = 0U;
    g_hsm_lock        = 0U;
    g_rfence_ack_mask = 0ULL;
    fence_rw();
}

uint64_t sbi_secondary_wait_start(uint64_t hartid, uint64_t *out_start_addr, uint64_t *out_opaque) {
    if (hartid >= SBI_MAX_HARTS) {
        return 0UL;
    }
    CLINT_MSIP(hartid) = 0U;
    (void)CLINT_MSIP(hartid);
    fence_rw();

    uint64_t expected = SBI_HSM_STATE_START_PENDING;
    if (__atomic_compare_exchange_n(&g_harts[hartid].hsm_state, &expected,
                                    SBI_HSM_STATE_STARTED, 0,
                                    __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        *out_start_addr = g_harts[hartid].start_addr;
        *out_opaque     = g_harts[hartid].opaque;
        __atomic_store_n(&g_harts[hartid].pending_ipi, 0U, __ATOMIC_RELEASE);
        return 1UL;
    }
    uint64_t stop_pending = SBI_HSM_STATE_STOP_PENDING;
    (void)__atomic_compare_exchange_n(&g_harts[hartid].hsm_state, &stop_pending,
                                      SBI_HSM_STATE_STOPPED, 0,
                                      __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    /* Ensure mip_val is completely quiescent before returning to WFI in _sbi_secondary_park */
    if (hartid < g_sbi_num_harts) {
        CLINT_MTIMECMP(hartid) = ~0ULL;
    }
    uint64_t s_pend_bits = (1UL << 9) | (1UL << 5) | (1UL << 1);
    __asm__ volatile("csrc mip, %0" :: "r"(s_pend_bits));
    return 0UL;
}

void sbi_handle_msip(uint64_t hartid) {
    /* Serialize CLINT MSIP deassertion before atomically reading pending_ipi */
    CLINT_MSIP(hartid) = 0U;
    (void)CLINT_MSIP(hartid);
    fence_rw();

    uint32_t bits = __atomic_exchange_n(&g_harts[hartid].pending_ipi, 0U, __ATOMIC_ACQ_REL);
    if (bits & IPI_REASON_HALT) {
        __atomic_fetch_and(&g_rfence_ack_mask, ~(1ULL << hartid), __ATOMIC_RELEASE);
        __atomic_store_n(&g_harts[hartid].hsm_state, SBI_HSM_STATE_STOPPED, __ATOMIC_RELEASE);
        fence_rw();
        _sbi_secondary_park();
    }
    if (bits & IPI_BIT_SSIP) {
        uint64_t ssip = (1UL << 1);
        __asm__ volatile("csrs mip, %0" :: "r"(ssip));
    }
    if (bits & IPI_BIT_FENCE_I) {
        __asm__ volatile("fence.i" ::: "memory");
    }
    if (bits & (IPI_BIT_SFENCE_VMA | IPI_BIT_SFENCE_VMA_ASID)) {
        __asm__ volatile("sfence.vma zero, zero" ::: "memory");
    }
    if (bits & (IPI_BIT_FENCE_I | IPI_BIT_SFENCE_VMA | IPI_BIT_SFENCE_VMA_ASID)) {
        __atomic_fetch_and(&g_rfence_ack_mask, ~(1ULL << hartid), __ATOMIC_RELEASE);
    }
}

static uint64_t resolve_hart_mask(uint64_t hart_mask, uint64_t hart_mask_base) {
    uint64_t valid_all = (g_sbi_num_harts >= 64UL) ? ~0ULL : ((1ULL << g_sbi_num_harts) - 1ULL);
    if (hart_mask_base == ~0ULL) {
        return valid_all;
    }
    if (hart_mask_base >= g_sbi_num_harts) {
        return 0ULL;
    }
    return (hart_mask << hart_mask_base) & valid_all;
}

static sbi_ret_t sbi_do_send_ipi(uint64_t hart_mask, uint64_t hart_mask_base) {
    sbi_ret_t ret = { SBI_SUCCESS, 0L };
    uint64_t targets = resolve_hart_mask(hart_mask, hart_mask_base);
    if (hart_mask != 0UL && hart_mask_base != ~0ULL && hart_mask_base >= g_sbi_num_harts) {
        ret.error = SBI_ERR_INVALID_PARAM;
        return ret;
    }
    for (uint64_t h = 0; h < g_sbi_num_harts; h++) {
        if ((targets & (1ULL << h)) == 0ULL) continue;
        __atomic_fetch_or(&g_harts[h].pending_ipi, IPI_BIT_SSIP, __ATOMIC_ACQ_REL);
        fence_rw();
        CLINT_MSIP(h) = 1U;
    }
    return ret;
}

static sbi_ret_t sbi_do_rfence(uint64_t self, uint32_t bit,
                               uint64_t hart_mask, uint64_t hart_mask_base,
                               uint64_t start_addr, uint64_t size, uint64_t asid) {
    sbi_ret_t ret = { SBI_SUCCESS, 0L };
    if (hart_mask != 0UL && hart_mask_base != ~0ULL && hart_mask_base >= g_sbi_num_harts) {
        ret.error = SBI_ERR_INVALID_PARAM;
        return ret;
    }
    uint64_t targets = resolve_hart_mask(hart_mask, hart_mask_base);

    /* Serialize remote-fence broadcasts while remaining responsive to incoming MSIPs */
    spin_lock_polling_msip(&g_rfence_lock, self);

    uint64_t remote_mask = 0ULL;
    for (uint64_t h = 0; h < g_sbi_num_harts; h++) {
        if ((targets & (1ULL << h)) == 0ULL) continue;
        if (h == self) {
            if (bit == IPI_BIT_FENCE_I) {
                __asm__ volatile("fence.i" ::: "memory");
            } else {
                __asm__ volatile("sfence.vma zero, zero" ::: "memory");
            }
        } else if (__atomic_load_n(&g_harts[h].hsm_state, __ATOMIC_ACQUIRE) == SBI_HSM_STATE_STARTED) {
            g_harts[h].rfence_addr = start_addr;
            g_harts[h].rfence_size = size;
            g_harts[h].rfence_asid = asid;
            remote_mask |= (1ULL << h);
        }
    }

    if (remote_mask != 0ULL) {
        __atomic_store_n(&g_rfence_ack_mask, remote_mask, __ATOMIC_RELEASE);
        fence_rw();
        for (uint64_t h = 0; h < g_sbi_num_harts; h++) {
            if ((remote_mask & (1ULL << h)) == 0ULL) continue;
            __atomic_fetch_or(&g_harts[h].pending_ipi, bit, __ATOMIC_ACQ_REL);
            fence_rw();
            CLINT_MSIP(h) = 1U;
        }

        while (__atomic_load_n(&g_rfence_ack_mask, __ATOMIC_ACQUIRE) != 0ULL) {
            if (read_mip() & (1UL << 3)) {
                sbi_handle_msip(self);
            }
        }
    }

    spin_unlock(&g_rfence_lock);
    return ret;
}

static void sbi_halt_other_harts_and_self(uint64_t self, sbi_trap_regs_t *regs) {
    spin_lock_polling_msip(&g_hsm_lock, self);
    for (uint64_t h = 0; h < g_sbi_num_harts; h++) {
        if (h == self) continue;
        uint64_t cur = __atomic_load_n(&g_harts[h].hsm_state, __ATOMIC_ACQUIRE);
        if (cur != SBI_HSM_STATE_STOPPED) {
            __atomic_store_n(&g_harts[h].hsm_state, SBI_HSM_STATE_STOP_PENDING, __ATOMIC_RELEASE);
            __atomic_fetch_or(&g_harts[h].pending_ipi, IPI_REASON_HALT, __ATOMIC_ACQ_REL);
            fence_rw();
            CLINT_MSIP(h) = 1U;
        }
    }
    fence_rw();
    for (uint64_t h = 0; h < g_sbi_num_harts; h++) {
        if (h == self) continue;
        while (__atomic_load_n(&g_harts[h].hsm_state, __ATOMIC_ACQUIRE) != SBI_HSM_STATE_STOPPED) {
            /* Keep waiting until all online secondary harts enter _sbi_secondary_park */
        }
    }
    __atomic_store_n(&g_harts[self].hsm_state, SBI_HSM_STATE_STOPPED, __ATOMIC_RELEASE);
    fence_rw();
    spin_unlock(&g_hsm_lock);
    regs->mepc    = (uint64_t)(uintptr_t)_sbi_secondary_park;
    regs->mstatus = (regs->mstatus & ~((3UL << 11) | (1UL << 3))) | (3UL << 11);
}

static sbi_ret_t sbi_ecall_dispatch(uint64_t self, sbi_trap_regs_t *regs) {
    sbi_ret_t ret = { SBI_SUCCESS, 0L };
    long eid = (long)regs->a7;
    long fid = (long)regs->a6;

    switch (eid) {
        case SBI_EXT_BASE:
            switch (fid) {
                case 0: /* GET_SBI_SPEC_VERSION: v2.0 (major=2 in [30:24], minor=0 in [23:0]) */
                    ret.value = 0x02000000L;
                    break;
                case 1: /* GET_SBI_IMP_ID */
                    ret.value = 0xFFL;
                    break;
                case 2: /* GET_SBI_IMP_VERSION */
                    ret.value = 2L;
                    break;
                case 3: { /* PROBE_EXTENSION */
                    long probe_id = (long)regs->a0;
                    if (probe_id == SBI_EXT_BASE || probe_id == SBI_EXT_TIME ||
                        probe_id == SBI_EXT_IPI || probe_id == SBI_EXT_RFENCE ||
                        probe_id == SBI_EXT_HSM || probe_id == SBI_EXT_SRST ||
                        probe_id == SBI_EXT_DBCN) {
                        ret.value = 1L;
                    } else {
                        ret.value = 0L;
                    }
                    break;
                }
                case 4: /* GET_MVENDORID */
                case 5: /* GET_MARCHID */
                case 6: /* GET_MIMPID */
                    ret.value = 0L;
                    break;
                default:
                    ret.error = SBI_ERR_NOT_SUPPORTED;
                    break;
            }
            break;

        case SBI_EXT_TIME:
            if (fid == 0L) {
                CLINT_MTIMECMP(self) = regs->a0;
                uint64_t stip = (1UL << 5);
                uint64_t mtie = (1UL << 7);
                __asm__ volatile("csrc mip, %0" :: "r"(stip));
                __asm__ volatile("csrs mie, %0" :: "r"(mtie));
            } else {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            }
            break;

        case SBI_EXT_IPI:
            if (fid == 0L) {
                ret = sbi_do_send_ipi(regs->a0, regs->a1);
            } else {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            }
            break;

        case SBI_EXT_RFENCE:
            if (fid == 0L) {
                ret = sbi_do_rfence(self, IPI_BIT_FENCE_I, regs->a0, regs->a1, 0UL, 0UL, 0UL);
            } else if (fid == 1L) {
                ret = sbi_do_rfence(self, IPI_BIT_SFENCE_VMA, regs->a0, regs->a1, regs->a2, regs->a3, 0UL);
            } else if (fid == 2L) {
                ret = sbi_do_rfence(self, IPI_BIT_SFENCE_VMA_ASID, regs->a0, regs->a1, regs->a2, regs->a3, regs->a4);
            } else {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            }
            break;

        case SBI_EXT_HSM:
            switch (fid) {
                case 0L: { /* HART_START(hartid, start_addr, opaque) */
                    uint64_t target = regs->a0;
                    uint64_t start  = regs->a1;
                    uint64_t opaque = regs->a2;
                    if (target >= g_sbi_num_harts) {
                        ret.error = SBI_ERR_INVALID_PARAM;
                        break;
                    }
                    if (start < DRAM_BASE || start >= DRAM_END || (start & 0x3UL)) {
                        ret.error = SBI_ERR_INVALID_ADDRESS;
                        break;
                    }
                    spin_lock_polling_msip(&g_hsm_lock, self);
                    uint64_t cur = __atomic_load_n(&g_harts[target].hsm_state, __ATOMIC_ACQUIRE);
                    if (cur != SBI_HSM_STATE_STOPPED) {
                        spin_unlock(&g_hsm_lock);
                        ret.error = SBI_ERR_ALREADY_AVAILABLE;
                        break;
                    }
                    g_harts[target].start_addr = start;
                    g_harts[target].opaque     = opaque;
                    fence_rw();
                    __atomic_store_n(&g_harts[target].hsm_state, SBI_HSM_STATE_START_PENDING, __ATOMIC_RELEASE);
                    fence_rw();
                    CLINT_MSIP(target) = 1U;
                    spin_unlock(&g_hsm_lock);
                    break;
                }
                case 1L: { /* HART_STOP */
                    __atomic_store_n(&g_harts[self].hsm_state, SBI_HSM_STATE_STOPPED, __ATOMIC_RELEASE);
                    regs->mepc    = (uint64_t)(uintptr_t)_sbi_secondary_park;
                    regs->mstatus = (regs->mstatus & ~((3UL << 11) | (1UL << 3))) | (3UL << 11); /* MPP=M */
                    return ret; /* skip mepc += 4 */
                }
                case 2L: { /* HART_GET_STATUS(hartid) */
                    uint64_t target = regs->a0;
                    if (target >= g_sbi_num_harts) {
                        ret.error = SBI_ERR_INVALID_PARAM;
                    } else {
                        ret.value = (long)__atomic_load_n(&g_harts[target].hsm_state, __ATOMIC_ACQUIRE);
                    }
                    break;
                }
                default:
                    ret.error = SBI_ERR_NOT_SUPPORTED;
                    break;
            }
            break;

        case SBI_EXT_DBCN:
            if (fid == 0L) { /* CONSOLE_WRITE(num_bytes, base_addr_lo, base_addr_hi) */
                uint64_t len   = regs->a0;
                uint64_t paddr = regs->a1;
                if (regs->a2 != 0UL || paddr < DRAM_BASE || len > DRAM_SIZE || (paddr - DRAM_BASE) > (DRAM_SIZE - len)) {
                    ret.error = SBI_ERR_INVALID_PARAM;
                    break;
                }
                const volatile uint8_t *buf = (const volatile uint8_t *)(uintptr_t)paddr;
                spin_lock_polling_msip(&g_uart_lock, self);
                for (uint64_t i = 0; i < len; i++) {
                    uart_putc_unlocked(buf[i]);
                }
                spin_unlock(&g_uart_lock);
                ret.value = (long)len;
            } else if (fid == 1L) {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            } else if (fid == 2L) { /* CONSOLE_WRITE_BYTE(byte) */
                spin_lock_polling_msip(&g_uart_lock, self);
                uart_putc_unlocked((uint8_t)(regs->a0 & 0xFFUL));
                spin_unlock(&g_uart_lock);
            } else {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            }
            break;

        case SBI_EXT_SRST:
            if (fid == 0L) {
                sbi_halt_other_harts_and_self(self, regs);
                return ret;
            } else {
                ret.error = SBI_ERR_NOT_SUPPORTED;
            }
            break;

        case SBI_LEGACY_SET_TIMER:
            CLINT_MTIMECMP(self) = regs->a0;
            {
                uint64_t stip = (1UL << 5);
                uint64_t mtie = (1UL << 7);
                __asm__ volatile("csrc mip, %0" :: "r"(stip));
                __asm__ volatile("csrs mie, %0" :: "r"(mtie));
            }
            break;

        case SBI_LEGACY_CONSOLE_PUTCHAR:
            spin_lock_polling_msip(&g_uart_lock, self);
            uart_putc_unlocked((uint8_t)(regs->a0 & 0xFFUL));
            spin_unlock(&g_uart_lock);
            break;

        case SBI_LEGACY_SHUTDOWN:
            sbi_halt_other_harts_and_self(self, regs);
            return ret;

        default:
            ret.error = SBI_ERR_NOT_SUPPORTED;
            break;
    }

    regs->a0 = (uint64_t)ret.error;
    regs->a1 = (uint64_t)ret.value;
    regs->mepc += 4UL;
    return ret;
}

void sbi_handle_trap(sbi_trap_regs_t *regs) {
    uint64_t self   = read_mhartid();
    uint64_t mcause = regs->mcause;

    if ((int64_t)mcause < 0) {
        uint64_t code = mcause & ~(1ULL << 63);
        if (code == 3UL) {
            /* M-mode software interrupt (CLINT MSIP) */
            sbi_handle_msip(self);
        } else if (code == 7UL) {
            /* M-mode timer interrupt: delegate to S-mode via mip.STIP and mask MTIE */
            uint64_t mtie = (1UL << 7);
            uint64_t stip = (1UL << 5);
            __asm__ volatile("csrc mie, %0" :: "r"(mtie));
            __asm__ volatile("csrs mip, %0" :: "r"(stip));
        }
        return;
    }

    if (mcause == 9UL) {
        /* Supervisor ECALL (from S-mode) */
        (void)sbi_ecall_dispatch(self, regs);
        return;
    }

    /* Unexpected synchronous M-mode trap: print diagnostic and halt cleanly */
    spin_lock_polling_msip(&g_uart_lock, self);
    uart_puts_unlocked("!SBI! h=");
    uart_puthex_unlocked(self);
    uart_puts_unlocked(" mc=");
    uart_puthex_unlocked(mcause);
    uart_puts_unlocked(" epc=");
    uart_puthex_unlocked(regs->mepc);
    uart_puts_unlocked(" tval=");
    uart_puthex_unlocked(regs->mtval);
    uart_putc_unlocked('\n');
    spin_unlock(&g_uart_lock);
    regs->mepc += 4UL;
}
