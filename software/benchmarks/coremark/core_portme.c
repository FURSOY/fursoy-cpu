#include "coremark.h"
#include "bench_libc.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = MULTITHREAD;

static CORETIMETYPE start_time_val, stop_time_val;
static uint64_t start_instret_val, stop_instret_val;

void start_time(void) {
    bench_cpi_start();
    start_instret_val = bench_rdinstret();
    GETMYTIME(&start_time_val);
}

void stop_time(void) {
    GETMYTIME(&stop_time_val);
    stop_instret_val = bench_rdinstret();
    bench_cpi_stop();
    ee_printf("[COREMARK_CYCLES] contexts=%u iters=%d cycles=%llu instret=%llu\n",
              (unsigned)default_num_contexts,
              (int)ITERATIONS,
              (unsigned long long)MYTIMEDIFF(stop_time_val, start_time_val),
              (unsigned long long)(stop_instret_val - start_instret_val));
}

CORE_TICKS get_time(void) {
    return (CORE_TICKS)MYTIMEDIFF(stop_time_val, start_time_val);
}

secs_ret time_in_secs(CORE_TICKS ticks) {
    return ((secs_ret)ticks) / (secs_ret)EE_TICKS_PER_SEC;
}

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void portable_fini(core_portable *p) {
    p->portable_id = 0;
}

void *portable_malloc(ee_size_t size) {
    return malloc(size);
}

void portable_free(void *p) {
    free(p);
}

#if (MULTITHREAD > 1)
extern volatile int g_bench_all_done;

static core_results *volatile g_cm_res[8] __attribute__((aligned(64))) = {0};
static volatile uint32_t g_cm_started_cnt = 0;
static volatile uint64_t g_cm_epoch __attribute__((aligned(64))) = 0;
static volatile uint64_t g_cm_done_cnt __attribute__((aligned(64))) = 0;

static inline uint64_t cm_atomic_add_u64(volatile uint64_t *ptr, uint64_t val) {
    uint64_t prev;
    __asm__ volatile("amoadd.d.aqrl %0, %2, (%1)"
                     : "=r"(prev)
                     : "r"(ptr), "r"(val)
                     : "memory");
    return prev;
}

ee_u8 core_start_parallel(core_results *res) {
    uint32_t idx = g_cm_started_cnt++;
    g_cm_res[idx] = res;
    if (g_cm_started_cnt == default_num_contexts) {
        __asm__ volatile("fence w, w" ::: "memory");
        uint64_t next_epoch = g_cm_epoch + 1ULL;
        g_cm_epoch = next_epoch;
        __asm__ volatile("fence rw, rw" ::: "memory");
        /* Hart 0 runs context 0 concurrently with secondary harts 1..N-1 */
        iterate(g_cm_res[0]);
        cm_atomic_add_u64(&g_cm_done_cnt, 1ULL);
        uint64_t target = next_epoch * (uint64_t)default_num_contexts;
        while (g_cm_done_cnt < target) {
            __asm__ volatile("" ::: "memory");
        }
        __asm__ volatile("fence r, rw" ::: "memory");
    }
    return 0;
}

ee_u8 core_stop_parallel(core_results *res) {
    (void)res;
    if (g_cm_started_cnt > 0) {
        g_cm_started_cnt--;
    }
    return 0;
}

void bench_secondary_main(uint64_t hartid) {
    uint64_t seen_epoch = 0;
    for (;;) {
        while (g_cm_epoch == seen_epoch) {
            if (g_bench_all_done) {
                return;
            }
            __asm__ volatile("" ::: "memory");
        }
        __asm__ volatile("fence r, rw" ::: "memory");
        seen_epoch = g_cm_epoch;
        if (hartid < default_num_contexts && g_cm_res[hartid]) {
            iterate(g_cm_res[hartid]);
        }
        cm_atomic_add_u64(&g_cm_done_cnt, 1ULL);
        uint64_t target = seen_epoch * (uint64_t)default_num_contexts;
        while (g_cm_done_cnt < target) {
            __asm__ volatile("" ::: "memory");
        }
        __asm__ volatile("fence r, rw" ::: "memory");
    }
}
#endif
