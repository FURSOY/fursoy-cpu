#ifndef FURSOY_BENCH_LIBC_H
#define FURSOY_BENCH_LIBC_H

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

#define FURSOY_UART_THR  ((volatile uint8_t *)0x10000000ULL)
#define FURSOY_CPU_HZ    500000000ULL

static inline uint64_t bench_rdcycle(void) {
    uint64_t v;
    __asm__ volatile("rdcycle %0" : "=r"(v));
    return v;
}

static inline uint64_t bench_rdinstret(void) {
    uint64_t v;
    __asm__ volatile("rdinstret %0" : "=r"(v));
    return v;
}

static inline uint64_t bench_mhartid(void) {
    uint64_t v;
    __asm__ volatile("csrr %0, mhartid" : "=r"(v));
    return v;
}

static inline void bench_uart_putc(char c) {
    *FURSOY_UART_THR = (uint8_t)c;
}

static inline void bench_cpi_start(void) {
    __asm__ volatile("fence rw, rw" ::: "memory");
    bench_uart_putc('\x01');
}

static inline void bench_cpi_stop(void) {
    __asm__ volatile("fence rw, rw" ::: "memory");
    bench_uart_putc('\x02');
}

void bench_finish(int rc);
void bench_trap_handler(uint64_t hartid, uint64_t mcause, uint64_t mepc, uint64_t mtval);
void bench_secondary_main(uint64_t hartid);

#endif /* FURSOY_BENCH_LIBC_H */
