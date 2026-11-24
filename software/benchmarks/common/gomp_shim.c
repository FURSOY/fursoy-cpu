#include "bench_libc.h"
#include <stdint.h>

#ifndef NUM_HARTS
#define NUM_HARTS 1
#endif

extern volatile int g_bench_all_done;

typedef void (*gomp_fn_t)(void *);

static volatile gomp_fn_t g_omp_fn __attribute__((aligned(64))) = 0;
static void *volatile g_omp_data __attribute__((aligned(64))) = 0;
static volatile uint64_t g_omp_epoch __attribute__((aligned(64))) = 0;
static volatile uint64_t g_omp_done_cnt __attribute__((aligned(64))) = 0;

static inline uint64_t atomic_add_u64(volatile uint64_t *ptr, uint64_t val) {
    uint64_t prev;
    __asm__ volatile("amoadd.d.aqrl %0, %2, (%1)"
                     : "=r"(prev)
                     : "r"(ptr), "r"(val)
                     : "memory");
    return prev;
}

int omp_get_num_threads(void) {
    return NUM_HARTS;
}

int omp_get_max_threads(void) {
    return NUM_HARTS;
}

int omp_get_thread_num(void) {
    return (int)bench_mhartid();
}

void GOMP_barrier(void) {
    /* Minimal barrier for standalone barrier pragmas if emitted */
    static volatile uint64_t g_bar_cnt __attribute__((aligned(64))) = 0;
    static uint64_t per_hart_epoch[8] __attribute__((aligned(64))) = {0};
    uint64_t h = bench_mhartid();
    per_hart_epoch[h]++;
    uint64_t target = per_hart_epoch[h] * (uint64_t)NUM_HARTS;
    atomic_add_u64(&g_bar_cnt, 1ULL);
    while (g_bar_cnt < target) {
        __asm__ volatile("" ::: "memory");
    }
    __asm__ volatile("fence r, rw" ::: "memory");
}

void GOMP_parallel(void (*fn)(void *), void *data, unsigned num_threads, unsigned int flags) {
    (void)num_threads;
    (void)flags;
    if (NUM_HARTS <= 1) {
        fn(data);
        return;
    }
    g_omp_fn = fn;
    g_omp_data = data;
    __asm__ volatile("fence w, w" ::: "memory");
    uint64_t next_epoch = g_omp_epoch + 1ULL;
    g_omp_epoch = next_epoch;
    __asm__ volatile("fence rw, rw" ::: "memory");

    fn(data);

    atomic_add_u64(&g_omp_done_cnt, 1ULL);
    uint64_t target = next_epoch * (uint64_t)NUM_HARTS;
    while (g_omp_done_cnt < target) {
        __asm__ volatile("" ::: "memory");
    }
    __asm__ volatile("fence r, rw" ::: "memory");
}

void bench_secondary_main(uint64_t hartid) {
    (void)hartid;
    uint64_t seen_epoch = 0;
    for (;;) {
        while (g_omp_epoch == seen_epoch) {
            if (g_bench_all_done) {
                return;
            }
            __asm__ volatile("" ::: "memory");
        }
        __asm__ volatile("fence r, rw" ::: "memory");
        seen_epoch = g_omp_epoch;
        gomp_fn_t fn = g_omp_fn;
        void *data = g_omp_data;
        if (fn) {
            fn(data);
        }
        atomic_add_u64(&g_omp_done_cnt, 1ULL);
        uint64_t target = seen_epoch * (uint64_t)NUM_HARTS;
        while (g_omp_done_cnt < target) {
            __asm__ volatile("" ::: "memory");
        }
        __asm__ volatile("fence r, rw" ::: "memory");
    }
}
