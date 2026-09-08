#define __NR_write 64
#define __NR_reboot 142
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

void _start(void) {
    const char msg[] = "\n====================================================\n"
                       "[INIT] Fursoy Slice-0 Linux Userspace active! PID 1\n"
                       "[INIT] Execution reached /init in initramfs.\n"
                       "====================================================\n";
    syscall3(__NR_write, 1, (long)msg, sizeof(msg) - 1);

    struct timespec ts = { 10, 0 };
    // Sleep loop
    while (1) {
        syscall3(__NR_nanosleep, (long)&ts, 0, 0);
    }
}
