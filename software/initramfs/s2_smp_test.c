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
#include <unistd.h>

#define MAX_CPUS 8
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
    return 0;
}
