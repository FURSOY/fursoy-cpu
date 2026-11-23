#include <stdint.h>

#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

#ifndef TORTURE_ITERS
#define TORTURE_ITERS 1200U
#endif

#define UART_THR        (*(volatile uint32_t *)0x10000000UL)
#define SHM_CTRL_BASE   0x80500000UL
#define ALIAS_BASE      0x80600000UL
#define ALIAS_LINES     32U
#define ALIAS_STRIDE    0x8000UL  /* 32 KiB: aliases BOTH 4 KiB L1D Set 0 and 32 KiB L2 Set 0 */
#define SMC_BASE        0x80700000UL
#define SMC_SHARED_ADDR 0x80700400UL

typedef struct {
    volatile uint64_t init_done;
    uint64_t _pad0[7];
    volatile uint64_t bar_cnt;
    uint64_t _pad1[7];
    volatile uint64_t lrsc_sum_d;
    uint64_t _pad2[7];
    volatile uint32_t lrsc_sum_w;
    uint32_t _pad3[15];
    volatile uint64_t amo_sum_d;
    uint64_t _pad4[7];
    volatile uint32_t amo_sum_w;
    uint32_t _pad5[15];
    volatile int64_t  amo_min_d;
    uint64_t _pad6[7];
    volatile int64_t  amo_max_d;
    uint64_t _pad7[7];
    volatile uint64_t swap_slots[8];
    volatile uint64_t final_tokens[4];
    volatile uint64_t expect_lrsc_d[4];
    volatile uint64_t expect_lrsc_w[4];
    volatile uint64_t expect_amo_d[4];
    volatile uint64_t expect_amo_w[4];
    volatile uint64_t fail_flag;
} torture_shm_t;

#define SHM ((torture_shm_t *)SHM_CTRL_BASE)

static inline void fence_rw(void) { __asm__ volatile("fence rw, rw" ::: "memory"); }
static inline void fence_w(void)  { __asm__ volatile("fence rw, w"  ::: "memory"); }
static inline void fence_i(void)  { __asm__ volatile("fence.i"      ::: "memory"); }

static void uart_puts(const char *s) {
    while (*s) {
        UART_THR = (uint32_t)(uint8_t)(*s++);
    }
}

static void uart_putu64(uint64_t v) {
    char buf[24];
    int n = 0;
    if (v == 0) {
        UART_THR = '0';
        return;
    }
    while (v > 0) {
        buf[n++] = (char)('0' + (v % 10ULL));
        v /= 10ULL;
    }
    while (n > 0) {
        UART_THR = (uint32_t)(uint8_t)buf[--n];
    }
}

static void torture_barrier(uint64_t *epoch) {
    uint64_t target;
    (*epoch)++;
    target = (*epoch) * (uint64_t)NUM_HARTS;
    __atomic_fetch_add(&SHM->bar_cnt, 1ULL, __ATOMIC_ACQ_REL);
    while (__atomic_load_n(&SHM->bar_cnt, __ATOMIC_ACQUIRE) < target) {
    }
    fence_rw();
}

static inline uint64_t xorshift64(uint64_t *state) {
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *state = x;
    return x;
}

static void write_smc_stub(uintptr_t addr, int32_t imm) {
    volatile uint32_t *p = (volatile uint32_t *)addr;
    /* addi a0, zero, (imm & 0x7FF); jalr zero, 0(ra) */
    uint32_t uimm = (uint32_t)imm & 0x7FFU;
    p[0] = 0x00000513U | (uimm << 20);
    p[1] = 0x00008067U;
}

static uint64_t call_smc_stub(uintptr_t addr) {
    typedef uint64_t (*fn_t)(void);
    fn_t fn = (fn_t)addr;
    return fn();
}

void torture_main(uint64_t hartid) {
    uint64_t epoch = 0;
    uint8_t shadow[ALIAS_LINES][16];

    for (uint32_t k = 0; k < ALIAS_LINES; k++) {
        for (uint32_t b = 0; b < 16; b++) {
            shadow[k][b] = 0;
        }
    }

    if (hartid == 0) {
        volatile uint64_t *clr = (volatile uint64_t *)SHM_CTRL_BASE;
        for (uint32_t i = 0; i < (sizeof(torture_shm_t) / 8U) + 16U; i++) {
            clr[i] = 0ULL;
        }
        for (uint32_t k = 0; k < ALIAS_LINES; k++) {
            volatile uint64_t *lp = (volatile uint64_t *)(ALIAS_BASE + (uint64_t)k * ALIAS_STRIDE);
            for (uint32_t w = 0; w < 8U; w++) {
                lp[w] = 0ULL;
            }
        }
        SHM->amo_min_d = 0x7FFFFFFFFFFFFFFFLL;
        SHM->amo_max_d = 0LL;
        for (uint32_t s = 0; s < 8U; s++) {
            SHM->swap_slots[s] = (uint64_t)(s + 1U) * 0x1111ULL;
        }
        fence_rw();
        __atomic_store_n(&SHM->init_done, 1ULL, __ATOMIC_RELEASE);
    } else {
        while (__atomic_load_n(&SHM->init_done, __ATOMIC_ACQUIRE) == 0ULL) {
        }
    }

    torture_barrier(&epoch);

    uint64_t rng = 0xA5A55A5A12345678ULL ^ ((hartid + 1ULL) * 0x9E3779B97F4A7C15ULL);
    uint64_t my_lrsc_d = 0;
    uint64_t my_lrsc_w = 0;
    uint64_t my_amo_d  = 0;
    uint64_t my_amo_w  = 0;
    uint64_t held_token = (hartid + 1ULL) * 0x10001ULL;
    uint64_t init_token = held_token;
    int64_t  min_seen   = 0x7FFFFFFFFFFFFFFFLL;
    int64_t  max_seen   = 0LL;

    for (uint32_t iter = 0; iter < TORTURE_ITERS; iter++) {
        uint64_t r = xorshift64(&rng);
        uint32_t line_idx = (uint32_t)(r & (ALIAS_LINES - 1U));
        uintptr_t lane_addr = (uintptr_t)(ALIAS_BASE + (uint64_t)line_idx * ALIAS_STRIDE + hartid * 16ULL);
        uint32_t op = (uint32_t)((r >> 8) & 0x7U);

        /* Cross-hart FENCE.I SMC sync every 256 iterations */
        if ((iter & 255U) == 0U) {
            if (hartid == 0) {
                write_smc_stub(SMC_SHARED_ADDR, (int32_t)((iter + 19U) & 0x3FFU));
                fence_rw();
            }
            torture_barrier(&epoch);
            fence_i();
            uint64_t got = call_smc_stub(SMC_SHARED_ADDR);
            if (got != (uint64_t)((iter + 19U) & 0x3FFU)) {
                __atomic_store_n(&SHM->fail_flag, 1ULL, __ATOMIC_RELEASE);
            }
            torture_barrier(&epoch);
        }

        if (op <= 2U) {
            /* Sub-word store + verify load on Set-0 aliasing line (sb/sh/sw/sd + lb/lh/lw/ld) */
            uint32_t width_sel = (uint32_t)((r >> 12) & 0x3U);
            uint32_t off = (uint32_t)((r >> 16) & 0xFU);
            uint64_t val = xorshift64(&rng);

            if (width_sel == 0U) {
                uint8_t v8 = (uint8_t)val;
                *(volatile uint8_t *)(lane_addr + off) = v8;
                shadow[line_idx][off] = v8;
                int8_t  s8 = *(volatile int8_t *)(lane_addr + off);
                uint8_t u8 = *(volatile uint8_t *)(lane_addr + off);
                if (u8 != shadow[line_idx][off] || s8 != (int8_t)shadow[line_idx][off]) {
                    __atomic_store_n(&SHM->fail_flag, 2ULL, __ATOMIC_RELEASE);
                }
            } else if (width_sel == 1U) {
                off &= ~1U;
                uint16_t v16 = (uint16_t)val;
                *(volatile uint16_t *)(lane_addr + off) = v16;
                shadow[line_idx][off]     = (uint8_t)(v16 & 0xFFU);
                shadow[line_idx][off + 1] = (uint8_t)(v16 >> 8);
                int16_t  s16 = *(volatile int16_t *)(lane_addr + off);
                uint16_t u16 = *(volatile uint16_t *)(lane_addr + off);
                uint16_t exp = (uint16_t)shadow[line_idx][off] | ((uint16_t)shadow[line_idx][off + 1] << 8);
                if (u16 != exp || s16 != (int16_t)exp) {
                    __atomic_store_n(&SHM->fail_flag, 3ULL, __ATOMIC_RELEASE);
                }
            } else if (width_sel == 2U) {
                off &= ~3U;
                uint32_t v32 = (uint32_t)val;
                *(volatile uint32_t *)(lane_addr + off) = v32;
                for (uint32_t b = 0; b < 4U; b++) {
                    shadow[line_idx][off + b] = (uint8_t)((v32 >> (b * 8U)) & 0xFFU);
                }
                int32_t  s32 = *(volatile int32_t *)(lane_addr + off);
                uint32_t u32 = *(volatile uint32_t *)(lane_addr + off);
                uint32_t exp = 0;
                for (uint32_t b = 0; b < 4U; b++) {
                    exp |= ((uint32_t)shadow[line_idx][off + b] << (b * 8U));
                }
                if (u32 != exp || s32 != (int32_t)exp) {
                    __atomic_store_n(&SHM->fail_flag, 4ULL, __ATOMIC_RELEASE);
                }
            } else {
                off &= ~7U;
                *(volatile uint64_t *)(lane_addr + off) = val;
                for (uint32_t b = 0; b < 8U; b++) {
                    shadow[line_idx][off + b] = (uint8_t)((val >> (b * 8U)) & 0xFFU);
                }
                uint64_t u64 = *(volatile uint64_t *)(lane_addr + off);
                uint64_t exp = 0;
                for (uint32_t b = 0; b < 8U; b++) {
                    exp |= ((uint64_t)shadow[line_idx][off + b] << (b * 8U));
                }
                if (u64 != exp) {
                    __atomic_store_n(&SHM->fail_flag, 5ULL, __ATOMIC_RELEASE);
                }
            }
        } else if (op == 3U) {
            /* LR.D / SC.D shared increment */
            uint64_t oldv, newv, fail;
            do {
                __asm__ volatile(
                    "lr.d %0, (%3)\n"
                    "addi %1, %0, 1\n"
                    "sc.d %2, %1, (%3)\n"
                    : "=&r"(oldv), "=&r"(newv), "=&r"(fail)
                    : "r"(&SHM->lrsc_sum_d)
                    : "memory");
            } while (fail != 0ULL);
            my_lrsc_d++;
        } else if (op == 4U) {
            /* LR.W / SC.W shared increment */
            uint32_t oldv, newv, fail;
            do {
                __asm__ volatile(
                    "lr.w %0, (%3)\n"
                    "addi %1, %0, 1\n"
                    "sc.w %2, %1, (%3)\n"
                    : "=&r"(oldv), "=&r"(newv), "=&r"(fail)
                    : "r"(&SHM->lrsc_sum_w)
                    : "memory");
            } while (fail != 0U);
            my_lrsc_w++;
        } else if (op == 5U) {
            /* Mixed AMOs: amoadd.d, amoadd.w, amomin.d, amomax.d */
            uint64_t prev64;
            uint32_t prev32;
            int64_t cand = (int64_t)((r >> 20) & 0xFFFFU) + 1;
            __asm__ volatile("amoadd.d %0, %1, (%2)" : "=r"(prev64) : "r"(1ULL), "r"(&SHM->amo_sum_d) : "memory");
            my_amo_d++;
            __asm__ volatile("amoadd.w %0, %1, (%2)" : "=r"(prev32) : "r"(1U), "r"(&SHM->amo_sum_w) : "memory");
            my_amo_w++;
            if (cand < min_seen) min_seen = cand;
            if (cand > max_seen) max_seen = cand;
            __asm__ volatile("amomin.d zero, %0, (%1)" :: "r"(cand), "r"(&SHM->amo_min_d) : "memory");
            __asm__ volatile("amomax.d zero, %0, (%1)" :: "r"(cand), "r"(&SHM->amo_max_d) : "memory");
        } else if (op == 6U) {
            /* Token-conserving amoswap.d + fence */
            uint32_t slot = (uint32_t)((r >> 24) & 7U);
            uint64_t swapped;
            __asm__ volatile("amoswap.d %0, %1, (%2)"
                             : "=r"(swapped)
                             : "r"(held_token), "r"(&SHM->swap_slots[slot])
                             : "memory");
            held_token = swapped;
            fence_rw();
        } else {
            /* Self-modifying FENCE.I instruction burst on hart-private executable line */
            uintptr_t buf_addr = (uintptr_t)(SMC_BASE + hartid * 0x100UL);
            int32_t imm = (int32_t)((iter ^ (uint32_t)(r >> 32)) & 0x3FFU);
            write_smc_stub(buf_addr, imm);
            fence_w();
            fence_i();
            uint64_t got = call_smc_stub(buf_addr);
            if (got != (uint64_t)imm) {
                __atomic_store_n(&SHM->fail_flag, 6ULL, __ATOMIC_RELEASE);
            }
        }
    }

    SHM->expect_lrsc_d[hartid] = my_lrsc_d;
    SHM->expect_lrsc_w[hartid] = my_lrsc_w;
    SHM->expect_amo_d[hartid]  = my_amo_d;
    SHM->expect_amo_w[hartid]  = my_amo_w;

    /* Publish held_token without overwriting swap_slots so total token sum stays invariant */
    SHM->final_tokens[hartid] = held_token;
    fence_rw();

    torture_barrier(&epoch);

    if (hartid == 0) {
        uint64_t exp_lr_d = 0, exp_lr_w = 0, exp_amo_d = 0, exp_amo_w = 0;
        uint64_t exp_token_sum = 0, act_token_sum = 0;
        for (uint32_t s = 0; s < 8U; s++) {
            exp_token_sum += (uint64_t)(s + 1U) * 0x1111ULL;
            act_token_sum += SHM->swap_slots[s];
        }
        for (uint32_t h = 0; h < NUM_HARTS; h++) {
            exp_lr_d  += SHM->expect_lrsc_d[h];
            exp_lr_w  += SHM->expect_lrsc_w[h];
            exp_amo_d += SHM->expect_amo_d[h];
            exp_amo_w += SHM->expect_amo_w[h];
            exp_token_sum += (uint64_t)(h + 1U) * 0x10001ULL;
            act_token_sum += SHM->final_tokens[h];
        }
        /* Final pass verifying all aliasing lines still hold shadow-consistent non-corrupted data */
        if (SHM->fail_flag != 0ULL ||
            SHM->lrsc_sum_d != exp_lr_d ||
            SHM->lrsc_sum_w != (uint32_t)exp_lr_w ||
            SHM->amo_sum_d  != exp_amo_d ||
            SHM->amo_sum_w  != (uint32_t)exp_amo_w ||
            act_token_sum   != exp_token_sum ||
            SHM->amo_min_d  > min_seen ||
            SHM->amo_max_d  < max_seen) {
            uart_puts("[TORTURE_FAIL]\n");
        } else {
            (void)init_token;
            uart_puts("[TORTURE] lrsc_d=");
            uart_putu64(SHM->lrsc_sum_d);
            uart_puts(" lrsc_w=");
            uart_putu64(SHM->lrsc_sum_w);
            uart_puts(" amo_d=");
            uart_putu64(SHM->amo_sum_d);
            uart_puts(" amo_w=");
            uart_putu64(SHM->amo_sum_w);
            uart_puts("\n");
            uart_puts("[TORTURE_ALL_PASS]\n");
        }
    }

    /* Verify shadow on all harts after final thrashing barrier */
    for (uint32_t k = 0; k < ALIAS_LINES; k++) {
        volatile uint8_t *lp = (volatile uint8_t *)(ALIAS_BASE + (uint64_t)k * ALIAS_STRIDE + hartid * 16ULL);
        for (uint32_t b = 0; b < 16U; b++) {
            if (lp[b] != shadow[k][b]) {
                __atomic_store_n(&SHM->fail_flag, 7ULL, __ATOMIC_RELEASE);
            }
        }
    }
    torture_barrier(&epoch);
    if (hartid == 0 && SHM->fail_flag != 0ULL) {
        uart_puts("[TORTURE_SHADOW_FAIL]\n");
    }
}
