// =============================================================================
// Fursoy Slice-2 Milestone S2-M5 Multi-Hart Userspace SMP Validation Workload
// =============================================================================
// Verifies:
// 1. sched_setaffinity / sched_getcpu migration across all online CPUs 0..N-1
//    -> prints [SMP_AFFINITY_PASS]
// 2. N simultaneous pthreads (pinned 1-per-CPU) exercising pthread_barrier_wait,
//    C11 <stdatomic.h> fetch_add + CAS contention, pthread_mutex serialization,
//    and cross-CPU shared-memory producer/consumer coherence
//    -> prints [SMP_PTHREADS_PASS]
// =============================================================================

#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAX_CPUS 8
#define MAX_FPU_THREADS 16
#define FPU_ROUNDS 6
#define ITERS_PER_THREAD 2000
#define SLICE_WORDS 64

static void fail(const char *msg) {
    fprintf(stderr, "[SMP_TEST_FAIL] %s (errno=%d)\n", msg, errno);
    fflush(stderr);
    exit(1);
}

static int pin_to_cpu(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        return -1;
    }
    sched_yield();
    return 0;
}

static void verify_affinity_migration(int ncpus) {
    printf("[SMP_TEST] Testing sched_setaffinity migration across %d CPUs...\n", ncpus);
    fflush(stdout);
    for (int round = 0; round < 2; round++) {
        for (int c = 0; c < ncpus; c++) {
            if (pin_to_cpu(c) != 0) {
                fail("sched_setaffinity failed in main thread");
            }
            int cur = sched_getcpu();
            if (cur != c) {
                fprintf(stderr, "[SMP_TEST_FAIL] expected cpu=%d got cpu=%d\n", c, cur);
                exit(1);
            }
        }
    }
    // Restore full affinity mask before spawning workers
    cpu_set_t all;
    CPU_ZERO(&all);
    for (int c = 0; c < ncpus; c++) CPU_SET(c, &all);
    if (sched_setaffinity(0, sizeof(all), &all) != 0) {
        fail("Failed to restore full CPU affinity mask");
    }
    printf("[SMP_AFFINITY_PASS] Verified main-thread migration across CPUs 0..%d\n", ncpus - 1);
    fflush(stdout);
}

typedef struct {
    int tid;
    int ncpus;
    int observed_cpu;
    uint64_t local_checksum;
} worker_arg_t;

static pthread_barrier_t g_barrier;
static pthread_mutex_t   g_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t  g_atomic_counter = 0;
static _Atomic uint64_t  g_cas_counter = 0;
static uint64_t          g_mutex_counter = 0;
static _Atomic uint64_t  g_shared_buf[MAX_CPUS][SLICE_WORDS];

static void *worker_fn(void *arg_ptr) {
    worker_arg_t *arg = (worker_arg_t *)arg_ptr;
    int cpu = arg->tid;

    if (pin_to_cpu(cpu) != 0) {
        fail("worker sched_setaffinity failed");
    }
    arg->observed_cpu = sched_getcpu();
    if (arg->observed_cpu != cpu) {
        fprintf(stderr, "[SMP_TEST_FAIL] worker %d ran on cpu %d\n", cpu, arg->observed_cpu);
        exit(1);
    }

    // Barrier 1: align all N workers simultaneously across all N harts
    int rc = pthread_barrier_wait(&g_barrier);
    if (rc != 0 && rc != PTHREAD_BARRIER_SERIAL_THREAD) {
        fail("pthread_barrier_wait #1 failed");
    }

    // Phase A: heavy C11 atomic fetch_add + CAS contention
    for (int i = 0; i < ITERS_PER_THREAD; i++) {
        atomic_fetch_add_explicit(&g_atomic_counter, 1ULL, memory_order_acq_rel);

        uint64_t old_val = atomic_load_explicit(&g_cas_counter, memory_order_relaxed);
        while (!atomic_compare_exchange_weak_explicit(
                   &g_cas_counter, &old_val, old_val + (uint64_t)(cpu + 1),
                   memory_order_acq_rel, memory_order_relaxed)) {
        }
    }

    // Phase B: pthread_mutex mutual exclusion check
    for (int i = 0; i < 200; i++) {
        if (pthread_mutex_lock(&g_mutex) != 0) fail("pthread_mutex_lock failed");
        g_mutex_counter += (uint64_t)(cpu + 1);
        if (pthread_mutex_unlock(&g_mutex) != 0) fail("pthread_mutex_unlock failed");
    }

    // Phase C: cross-CPU shared array write -> barrier -> neighbor verification
    for (int w = 0; w < SLICE_WORDS; w++) {
        uint64_t pattern = ((uint64_t)(cpu + 1) << 32) ^ (0x5a5a0000ULL + (uint64_t)w * 131ULL);
        atomic_store_explicit(&g_shared_buf[cpu][w], pattern, memory_order_release);
    }

    rc = pthread_barrier_wait(&g_barrier);
    if (rc != 0 && rc != PTHREAD_BARRIER_SERIAL_THREAD) {
        fail("pthread_barrier_wait #2 failed");
    }

    int peer = (cpu + 1) % arg->ncpus;
    uint64_t chk = 0;
    for (int w = 0; w < SLICE_WORDS; w++) {
        uint64_t expected = ((uint64_t)(peer + 1) << 32) ^ (0x5a5a0000ULL + (uint64_t)w * 131ULL);
        uint64_t got = atomic_load_explicit(&g_shared_buf[peer][w], memory_order_acquire);
        if (got != expected) {
            fprintf(stderr, "[SMP_TEST_FAIL] coherence mismatch cpu=%d peer=%d w=%d got=0x%llx exp=0x%llx\n",
                    cpu, peer, w, (unsigned long long)got, (unsigned long long)expected);
            exit(1);
        }
        chk ^= got;
    }
    arg->local_checksum = chk;
    return NULL;
}

/* =============================================================================
 * S2.5-M3b Oversubscribed Multi-Threaded RV64FD Preemption & Context-Switch Test
 * ============================================================================= */

static inline uint64_t make_fp64_bits(int tid, int round, int reg) {
    uint64_t exp = (uint64_t)(1023 + ((tid + reg) & 7));
    uint64_t mant = ((uint64_t)(tid + 1) << 44) ^
                    ((uint64_t)(round + 1) << 36) ^
                    ((uint64_t)(reg + 1) << 28) ^
                    ((uint64_t)(tid * 37 + reg * 13 + round * 7 + 0xA5A5) & 0xFFFFFFFULL);
    return (exp << 52) | (mant & 0x000FFFFFFFFFFFFFULL);
}

static __attribute__((noinline)) void fpu_live_round(
    const uint64_t in_regs[32],
    uint64_t out_after_mig[32],
    uint64_t out_after_op[32],
    uint32_t frm_mode,
    uint32_t *fcsr_after_mig,
    uint32_t *fcsr_after_op,
    const cpu_set_t *target_mask,
    size_t mask_bytes)
{
    uint64_t fcsr_init = ((uint64_t)(frm_mode & 7u)) << 5;
    uint64_t fcsr1 = 0;
    uint64_t fcsr2 = 0;
    long aff_rc = 0;

    register uint64_t a0_r __asm__("a0");
    register uint64_t a1_r __asm__("a1");
    register uint64_t a2_r __asm__("a2");
    register uint64_t a7_r __asm__("a7");

    /* Load all 32 FP registers + fcsr, then invoke SYS_sched_setaffinity & SYS_sched_yield
     * directly via ecall while f0..f31 & fcsr are live in hardware registers. */
    __asm__ volatile(
        "fld f0,    0(%[in])\n"
        "fld f1,    8(%[in])\n"
        "fld f2,   16(%[in])\n"
        "fld f3,   24(%[in])\n"
        "fld f4,   32(%[in])\n"
        "fld f5,   40(%[in])\n"
        "fld f6,   48(%[in])\n"
        "fld f7,   56(%[in])\n"
        "fld f8,   64(%[in])\n"
        "fld f9,   72(%[in])\n"
        "fld f10,  80(%[in])\n"
        "fld f11,  88(%[in])\n"
        "fld f12,  96(%[in])\n"
        "fld f13, 104(%[in])\n"
        "fld f14, 112(%[in])\n"
        "fld f15, 120(%[in])\n"
        "fld f16, 128(%[in])\n"
        "fld f17, 136(%[in])\n"
        "fld f18, 144(%[in])\n"
        "fld f19, 152(%[in])\n"
        "fld f20, 160(%[in])\n"
        "fld f21, 168(%[in])\n"
        "fld f22, 176(%[in])\n"
        "fld f23, 184(%[in])\n"
        "fld f24, 192(%[in])\n"
        "fld f25, 200(%[in])\n"
        "fld f26, 208(%[in])\n"
        "fld f27, 216(%[in])\n"
        "fld f28, 224(%[in])\n"
        "fld f29, 232(%[in])\n"
        "fld f30, 240(%[in])\n"
        "fld f31, 248(%[in])\n"
        "fscsr zero, %[finit]\n"
        :
        : [in] "r"(in_regs), [finit] "r"(fcsr_init)
        : "memory"
    );

    /* Syscall 1: sched_setaffinity(0, mask_bytes, target_mask) */
    a0_r = 0;
    a1_r = (uint64_t)mask_bytes;
    a2_r = (uint64_t)(uintptr_t)target_mask;
    a7_r = (uint64_t)SYS_sched_setaffinity;
    __asm__ volatile("ecall" : "+r"(a0_r) : "r"(a1_r), "r"(a2_r), "r"(a7_r) : "memory");
    aff_rc = (long)a0_r;

    /* Syscall 2: sched_yield() to force context switch across oversubscribed threads */
    a7_r = (uint64_t)SYS_sched_yield;
    __asm__ volatile("ecall" : "+r"(a0_r) : "r"(a7_r) : "memory");

    /* Snapshot fcsr & all 32 FP regs after migration/preemption, then execute real
     * dynamic-rounded fmadd.d / fdiv.d / fsqrt.d and yield again while dirty. */
    __asm__ volatile(
        "frcsr %[f1]\n"
        "fsd f0,    0(%[o1])\n"
        "fsd f1,    8(%[o1])\n"
        "fsd f2,   16(%[o1])\n"
        "fsd f3,   24(%[o1])\n"
        "fsd f4,   32(%[o1])\n"
        "fsd f5,   40(%[o1])\n"
        "fsd f6,   48(%[o1])\n"
        "fsd f7,   56(%[o1])\n"
        "fsd f8,   64(%[o1])\n"
        "fsd f9,   72(%[o1])\n"
        "fsd f10,  80(%[o1])\n"
        "fsd f11,  88(%[o1])\n"
        "fsd f12,  96(%[o1])\n"
        "fsd f13, 104(%[o1])\n"
        "fsd f14, 112(%[o1])\n"
        "fsd f15, 120(%[o1])\n"
        "fsd f16, 128(%[o1])\n"
        "fsd f17, 136(%[o1])\n"
        "fsd f18, 144(%[o1])\n"
        "fsd f19, 152(%[o1])\n"
        "fsd f20, 160(%[o1])\n"
        "fsd f21, 168(%[o1])\n"
        "fsd f22, 176(%[o1])\n"
        "fsd f23, 184(%[o1])\n"
        "fsd f24, 192(%[o1])\n"
        "fsd f25, 200(%[o1])\n"
        "fsd f26, 208(%[o1])\n"
        "fsd f27, 216(%[o1])\n"
        "fsd f28, 224(%[o1])\n"
        "fsd f29, 232(%[o1])\n"
        "fsd f30, 240(%[o1])\n"
        "fsd f31, 248(%[o1])\n"
        "fmadd.d f0, f1, f2, f3, dyn\n"
        "fdiv.d  f4, f0, f5, dyn\n"
        "fsqrt.d f6, f4, dyn\n"
        : [f1] "=r"(fcsr1)
        : [o1] "r"(out_after_mig)
        : "memory"
    );

    /* Syscall 3: second sched_yield() while computed f0/f4/f6 + fflags + frm are dirty */
    a7_r = (uint64_t)SYS_sched_yield;
    __asm__ volatile("ecall" : "+r"(a0_r) : "r"(a7_r) : "memory");

    __asm__ volatile(
        "frcsr %[f2]\n"
        "fsd f0,    0(%[o2])\n"
        "fsd f1,    8(%[o2])\n"
        "fsd f2,   16(%[o2])\n"
        "fsd f3,   24(%[o2])\n"
        "fsd f4,   32(%[o2])\n"
        "fsd f5,   40(%[o2])\n"
        "fsd f6,   48(%[o2])\n"
        "fsd f7,   56(%[o2])\n"
        "fsd f8,   64(%[o2])\n"
        "fsd f9,   72(%[o2])\n"
        "fsd f10,  80(%[o2])\n"
        "fsd f11,  88(%[o2])\n"
        "fsd f12,  96(%[o2])\n"
        "fsd f13, 104(%[o2])\n"
        "fsd f14, 112(%[o2])\n"
        "fsd f15, 120(%[o2])\n"
        "fsd f16, 128(%[o2])\n"
        "fsd f17, 136(%[o2])\n"
        "fsd f18, 144(%[o2])\n"
        "fsd f19, 152(%[o2])\n"
        "fsd f20, 160(%[o2])\n"
        "fsd f21, 168(%[o2])\n"
        "fsd f22, 176(%[o2])\n"
        "fsd f23, 184(%[o2])\n"
        "fsd f24, 192(%[o2])\n"
        "fsd f25, 200(%[o2])\n"
        "fsd f26, 208(%[o2])\n"
        "fsd f27, 216(%[o2])\n"
        "fsd f28, 224(%[o2])\n"
        "fsd f29, 232(%[o2])\n"
        "fsd f30, 240(%[o2])\n"
        "fsd f31, 248(%[o2])\n"
        : [f2] "=r"(fcsr2)
        : [o2] "r"(out_after_op)
        : "memory"
    );

    if (aff_rc != 0) {
        fprintf(stderr, "[SMP_TEST_FAIL] raw SYS_sched_setaffinity returned %ld\n", aff_rc);
        exit(1);
    }
    *fcsr_after_mig = (uint32_t)fcsr1;
    *fcsr_after_op  = (uint32_t)fcsr2;
}

static __attribute__((noinline)) void fpu_compute_ref(
    const uint64_t in_regs[32],
    uint32_t frm_mode,
    uint64_t *exp_f0,
    uint64_t *exp_f4,
    uint64_t *exp_f6,
    uint32_t *exp_fcsr)
{
    uint64_t fcsr_init = ((uint64_t)(frm_mode & 7u)) << 5;
    uint64_t r0 = 0, r4 = 0, r6 = 0, fc = 0;
    __asm__ volatile(
        "fscsr zero, %[finit]\n"
        "fld f1,  8(%[in])\n"
        "fld f2, 16(%[in])\n"
        "fld f3, 24(%[in])\n"
        "fld f5, 40(%[in])\n"
        "fmadd.d f0, f1, f2, f3, dyn\n"
        "fdiv.d  f4, f0, f5, dyn\n"
        "fsqrt.d f6, f4, dyn\n"
        "fmv.x.d %[r0], f0\n"
        "fmv.x.d %[r4], f4\n"
        "fmv.x.d %[r6], f6\n"
        "frcsr   %[fc]\n"
        : [r0] "=r"(r0), [r4] "=r"(r4), [r6] "=r"(r6), [fc] "=r"(fc)
        : [in] "r"(in_regs), [finit] "r"(fcsr_init)
        : "memory"
    );
    *exp_f0 = r0;
    *exp_f4 = r4;
    *exp_f6 = r6;
    *exp_fcsr = (uint32_t)fc;
}

typedef struct {
    int tid;
    int ncpus;
    int migrations;
    uint64_t regs_checked;
} fpu_arg_t;

static pthread_barrier_t g_fpu_barrier;

static void *fpu_worker_fn(void *arg_ptr) {
    fpu_arg_t *arg = (fpu_arg_t *)arg_ptr;
    int tid = arg->tid;
    int ncpus = arg->ncpus;

    int cur_cpu = tid % ncpus;
    if (pin_to_cpu(cur_cpu) != 0) {
        fail("fpu_worker initial pin failed");
    }

    int brc = pthread_barrier_wait(&g_fpu_barrier);
    if (brc != 0 && brc != PTHREAD_BARRIER_SERIAL_THREAD) {
        fail("fpu_worker barrier failed");
    }

    uint64_t in_regs[32];
    uint64_t out_mig[32];
    uint64_t out_op[32];

    for (int rnd = 0; rnd < FPU_ROUNDS; rnd++) {
        uint32_t my_frm = (uint32_t)((tid + rnd) % 5);
        for (int r = 0; r < 32; r++) {
            in_regs[r] = make_fp64_bits(tid, rnd, r);
            out_mig[r] = 0;
            out_op[r]  = 0;
        }

        int next_cpu = (cur_cpu + 1 + (tid & 1)) % ncpus;
        if (next_cpu == cur_cpu) next_cpu = (cur_cpu + 1) % ncpus;
        cpu_set_t mask;
        CPU_ZERO(&mask);
        CPU_SET(next_cpu, &mask);

        uint32_t fcsr_mig = 0, fcsr_op = 0;
        fpu_live_round(in_regs, out_mig, out_op, my_frm,
                       &fcsr_mig, &fcsr_op, &mask, sizeof(mask));

        int landed = sched_getcpu();
        if (landed != next_cpu) {
            fprintf(stderr, "[SMP_TEST_FAIL] fpu tid=%d rnd=%d expected cpu=%d got cpu=%d\n",
                    tid, rnd, next_cpu, landed);
            exit(1);
        }
        if (landed != cur_cpu) {
            arg->migrations++;
        }
        cur_cpu = landed;

        /* 1. Verify fcsr and all 32 FP registers survived migration + preemption intact */
        if (((fcsr_mig >> 5) & 7u) != my_frm || (fcsr_mig & 0x1Fu) != 0u) {
            fprintf(stderr, "[SMP_TEST_FAIL] fpu tid=%d rnd=%d fcsr_mig=0x%x exp_frm=%u\n",
                    tid, rnd, fcsr_mig, my_frm);
            exit(1);
        }
        for (int r = 0; r < 32; r++) {
            if (out_mig[r] != in_regs[r]) {
                fprintf(stderr, "[SMP_TEST_FAIL] fpu tid=%d rnd=%d mig reg f%d got=0x%llx exp=0x%llx\n",
                        tid, rnd, r, (unsigned long long)out_mig[r], (unsigned long long)in_regs[r]);
                exit(1);
            }
            arg->regs_checked++;
        }

        /* 2. Verify computed f0/f4/f6, unmodified 29 regs, frm, and fflags survived 2nd yield */
        uint64_t exp_f0 = 0, exp_f4 = 0, exp_f6 = 0;
        uint32_t exp_fcsr = 0;
        fpu_compute_ref(in_regs, my_frm, &exp_f0, &exp_f4, &exp_f6, &exp_fcsr);

        if (fcsr_op != exp_fcsr || (((fcsr_op >> 5) & 7u) != my_frm)) {
            fprintf(stderr, "[SMP_TEST_FAIL] fpu tid=%d rnd=%d fcsr_op=0x%x exp=0x%x\n",
                    tid, rnd, fcsr_op, exp_fcsr);
            exit(1);
        }
        for (int r = 0; r < 32; r++) {
            uint64_t exp = (r == 0) ? exp_f0 : (r == 4) ? exp_f4 : (r == 6) ? exp_f6 : in_regs[r];
            if (out_op[r] != exp) {
                fprintf(stderr, "[SMP_TEST_FAIL] fpu tid=%d rnd=%d post-op reg f%d got=0x%llx exp=0x%llx\n",
                        tid, rnd, r, (unsigned long long)out_op[r], (unsigned long long)exp);
                exit(1);
            }
            arg->regs_checked++;
        }
    }
    return NULL;
}

static void run_fpu_preempt_stress(int ncpus) {
    int nthreads = ncpus * 2;
    if (nthreads > MAX_FPU_THREADS) nthreads = MAX_FPU_THREADS;

    printf("[SMP_TEST] Running oversubscribed FPU preemption stress (%d threads across %d CPUs, %d rounds, f0..f31 + 5 frm modes)...\n",
           nthreads, ncpus, FPU_ROUNDS);
    fflush(stdout);

    if (pthread_barrier_init(&g_fpu_barrier, NULL, (unsigned)nthreads) != 0) {
        fail("fpu pthread_barrier_init failed");
    }

    pthread_t th[MAX_FPU_THREADS];
    fpu_arg_t args[MAX_FPU_THREADS];
    memset(args, 0, sizeof(args));

    for (int t = 0; t < nthreads; t++) {
        args[t].tid = t;
        args[t].ncpus = ncpus;
        if (pthread_create(&th[t], NULL, fpu_worker_fn, &args[t]) != 0) {
            fail("fpu pthread_create failed");
        }
    }

    int total_migs = 0;
    uint64_t total_regs = 0;
    for (int t = 0; t < nthreads; t++) {
        if (pthread_join(th[t], NULL) != 0) {
            fail("fpu pthread_join failed");
        }
        total_migs += args[t].migrations;
        total_regs += args[t].regs_checked;
    }
    pthread_barrier_destroy(&g_fpu_barrier);

    int expected_migs = nthreads * FPU_ROUNDS;
    uint64_t expected_regs = (uint64_t)nthreads * (uint64_t)FPU_ROUNDS * 64ULL;
    if (total_migs != expected_migs || total_regs != expected_regs) {
        fprintf(stderr, "[SMP_TEST_FAIL] fpu summary mismatch: migs=%d/%d regs=%llu/%llu\n",
                total_migs, expected_migs,
                (unsigned long long)total_regs, (unsigned long long)expected_regs);
        exit(1);
    }

    printf("[SMP_FPU_PREEMPT_PASS] threads=%d cpus=%d rounds=%d migrations=%d regs_checked=%llu frm_modes=5\n",
           nthreads, ncpus, FPU_ROUNDS, total_migs, (unsigned long long)total_regs);
    fflush(stdout);
}

int main(void) {
    long n_onln = sysconf(_SC_NPROCESSORS_ONLN);
    if (n_onln < 2 || n_onln > MAX_CPUS) {
        fprintf(stderr, "[SMP_TEST_FAIL] unexpected online CPUs: %ld\n", n_onln);
        return 1;
    }
    int ncpus = (int)n_onln;
    printf("[SMP_TEST] Detected %d online CPUs\n", ncpus);
    fflush(stdout);

    verify_affinity_migration(ncpus);

    if (pthread_barrier_init(&g_barrier, NULL, (unsigned)ncpus) != 0) {
        fail("pthread_barrier_init failed");
    }

    pthread_t threads[MAX_CPUS];
    worker_arg_t args[MAX_CPUS];
    memset(args, 0, sizeof(args));

    for (int t = 0; t < ncpus; t++) {
        args[t].tid = t;
        args[t].ncpus = ncpus;
        args[t].observed_cpu = -1;
        if (pthread_create(&threads[t], NULL, worker_fn, &args[t]) != 0) {
            fail("pthread_create failed");
        }
    }

    for (int t = 0; t < ncpus; t++) {
        if (pthread_join(threads[t], NULL) != 0) {
            fail("pthread_join failed");
        }
        if (args[t].observed_cpu != t) {
            fail("worker observed_cpu mismatch after join");
        }
    }

    pthread_barrier_destroy(&g_barrier);

    uint64_t sum_ids = (uint64_t)ncpus * (uint64_t)(ncpus + 1) / 2ULL;
    uint64_t exp_atomic = (uint64_t)ncpus * (uint64_t)ITERS_PER_THREAD;
    uint64_t exp_cas    = sum_ids * (uint64_t)ITERS_PER_THREAD;
    uint64_t exp_mutex  = sum_ids * 200ULL;

    uint64_t got_atomic = atomic_load(&g_atomic_counter);
    uint64_t got_cas    = atomic_load(&g_cas_counter);
    uint64_t got_mutex  = g_mutex_counter;

    if (got_atomic != exp_atomic || got_cas != exp_cas || got_mutex != exp_mutex) {
        fprintf(stderr, "[SMP_TEST_FAIL] counter mismatch: atomic=%llu/%llu cas=%llu/%llu mutex=%llu/%llu\n",
                (unsigned long long)got_atomic, (unsigned long long)exp_atomic,
                (unsigned long long)got_cas, (unsigned long long)exp_cas,
                (unsigned long long)got_mutex, (unsigned long long)exp_mutex);
        return 1;
    }

    printf("[SMP_PTHREADS_PASS] cpus=%d atomic=%llu cas=%llu mutex=%llu\n",
           ncpus, (unsigned long long)got_atomic, (unsigned long long)got_cas,
           (unsigned long long)got_mutex);
    fflush(stdout);

    run_fpu_preempt_stress(ncpus);
    return 0;
}
