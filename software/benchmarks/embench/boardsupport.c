#include "boardsupport.h"
#include "bench_libc.h"
#include <stdio.h>

static uint64_t g_emb_c0 = 0;
static uint64_t g_emb_i0 = 0;

void initialise_board(void) {
}

void start_trigger(void) {
    bench_cpi_start();
    g_emb_i0 = bench_rdinstret();
    g_emb_c0 = bench_rdcycle();
}

void stop_trigger(void) {
    uint64_t c1 = bench_rdcycle();
    uint64_t i1 = bench_rdinstret();
    bench_cpi_stop();
    printf("[EMBENCH_RESULT] gsf=%d cycles=%llu instret=%llu\n",
           (int)GLOBAL_SCALE_FACTOR,
           (unsigned long long)(c1 - g_emb_c0),
           (unsigned long long)(i1 - g_emb_i0));
}
