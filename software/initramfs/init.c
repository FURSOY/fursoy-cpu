#define __NR_write 64
#define __NR_nanosleep 101

struct timespec {
    long tv_sec;
    long tv_nsec;
};

static long syscall3(long num, long a0, long a1, long a2) {
    register long a7 asm("a7") = num;
    register long a0_reg asm("a0") = a0;
    register long a1_reg asm("a1") = a1;
    register long a2_reg asm("a2") = a2;
    asm volatile("ecall" : "+r"(a0_reg) : "r"(a7), "r"(a1_reg), "r"(a2_reg) : "memory");
    return a0_reg;
}

#define PRINT_LITERAL(s) syscall3(__NR_write, 1, (long)(s), sizeof(s) - 1)

// Global sinks to prevent optimization
static volatile unsigned long cpu_sink = 0;
static volatile unsigned long mem_buf[128];

// 1. CPU-heavy workload: pure integer ALU / bitwise computation loop
static void run_cpu_workload(void) {
    unsigned long a = 0x12345678ULL;
    unsigned long b = 0x9abcdef0ULL;
    for (int i = 0; i < 1000; i++) {
        a = (a * 6364136223846793005ULL + 1442695040888963407ULL) ^ (b >> 3);
        b = (b * 1103515245ULL + 12345ULL) ^ (a << 5);
    }
    cpu_sink = a + b;
}

// 2. Memory-heavy workload: sequential & strided read-modify-write across buffer
static void run_mem_workload(void) {
    for (int i = 0; i < 128; i++) {
        mem_buf[i] = (unsigned long)i * 0x0101010101010101ULL;
    }
    unsigned long sum = 0;
    for (int round = 0; round < 4; round++) {
        for (int i = 0; i < 128; i++) {
            int idx = (i * 17) & 127;
            mem_buf[idx] ^= (sum + idx);
            sum += mem_buf[idx];
        }
    }
    cpu_sink = sum;
}

void _start(void) {
    PRINT_LITERAL("\n====================================================\n"
                  "[INIT] Fursoy Slice-0 Linux Userspace active! PID 1\n"
                  "[INIT] Execution reached /init in initramfs.\n"
                  "====================================================\n");

    PRINT_LITERAL("[PERF] CPU_WORKLOAD_START\n");
    run_cpu_workload();
    PRINT_LITERAL("[PERF] CPU_WORKLOAD_END\n");

    PRINT_LITERAL("[PERF] MEM_WORKLOAD_START\n");
    run_mem_workload();
    PRINT_LITERAL("[PERF] MEM_WORKLOAD_END\n");

    PRINT_LITERAL("[PERF] ALL_BENCHMARKS_COMPLETE\n");

    struct timespec ts = { 10, 0 };
    while (1) {
        syscall3(__NR_nanosleep, (long)&ts, 0, 0);
    }
}
