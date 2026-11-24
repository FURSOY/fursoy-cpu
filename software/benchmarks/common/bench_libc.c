#include "bench_libc.h"
#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static FILE g_stdout_obj;
static FILE g_stderr_obj;
FILE *stdout = &g_stdout_obj;
FILE *stderr = &g_stderr_obj;

extern char __heap_start[];
extern char __heap_end[];

static uintptr_t g_heap_ptr = 0;
static volatile uint32_t g_alloc_lock = 0;

static inline void spin_lock(volatile uint32_t *lk) {
    uint32_t one = 1, prev;
    do {
        __asm__ volatile("amoswap.w.aq %0, %2, (%1)"
                         : "=r"(prev)
                         : "r"(lk), "r"(one)
                         : "memory");
    } while (prev != 0);
}

static inline void spin_unlock(volatile uint32_t *lk) {
    __asm__ volatile("amoswap.w.rl zero, zero, (%0)" :: "r"(lk) : "memory");
}

volatile int g_bench_all_done = 0;

__attribute__((weak)) void bench_secondary_main(uint64_t hartid) {
    (void)hartid;
    while (!g_bench_all_done) {
        __asm__ volatile("wfi");
    }
}

void bench_finish(int rc) {
    g_bench_all_done = 1;
    __asm__ volatile("fence rw, rw" ::: "memory");
    printf("[BENCH_EXIT] rc=%d\n", rc);
    for (;;) {
        __asm__ volatile("wfi");
    }
}

void bench_trap_handler(uint64_t hartid, uint64_t mcause, uint64_t mepc, uint64_t mtval) {
    printf("[BENCH_TRAP] hart=%llu mcause=0x%llx mepc=0x%llx mtval=0x%llx\n",
           (unsigned long long)hartid,
           (unsigned long long)mcause,
           (unsigned long long)mepc,
           (unsigned long long)mtval);
    printf("[BENCH_FAIL]\n");
    for (;;) {
        __asm__ volatile("wfi");
    }
}

/* ============================================================================
 * Memory & String Functions (strictly-aligned, Zicclsm-free)
 * ============================================================================ */

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    if ((((uintptr_t)d | (uintptr_t)s) & 7u) == 0u) {
        while (n >= 8) {
            *(uint64_t *)d = *(const uint64_t *)s;
            d += 8;
            s += 8;
            n -= 8;
        }
    }
    while (n--) *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    if (d == s || n == 0) return dst;
    if (d < s) {
        return memcpy(dst, src, n);
    }
    d += n;
    s += n;
    while (n--) *--d = *--s;
    return dst;
}

void *memset(void *dst, int c, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    uint8_t b = (uint8_t)c;
    while (n > 0 && (((uintptr_t)d) & 7u) != 0u) {
        *d++ = b;
        n--;
    }
    if (n >= 8) {
        uint64_t w = b;
        w |= w << 8;
        w |= w << 16;
        w |= w << 32;
        while (n >= 8) {
            *(uint64_t *)d = w;
            d += 8;
            n -= 8;
        }
    }
    while (n--) *d++ = b;
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const uint8_t *p = (const uint8_t *)a;
    const uint8_t *q = (const uint8_t *)b;
    while (n--) {
        if (*p != *q) return (int)*p - (int)*q;
        p++;
        q++;
    }
    return 0;
}

void *memchr(const void *s, int c, size_t n) {
    const uint8_t *p = (const uint8_t *)s;
    uint8_t ch = (uint8_t)c;
    while (n--) {
        if (*p == ch) return (void *)p;
        p++;
    }
    return NULL;
}

size_t strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int strcmp(const char *a, const char *b) {
    while (*a && (*a == *b)) {
        a++;
        b++;
    }
    return (int)(uint8_t)*a - (int)(uint8_t)*b;
}

int strncmp(const char *a, const char *b, size_t n) {
    while (n-- > 0) {
        if (*a != *b || *a == '\0') return (int)(uint8_t)*a - (int)(uint8_t)*b;
        a++;
        b++;
    }
    return 0;
}

char *strcpy(char *dst, const char *src) {
    char *r = dst;
    while ((*dst++ = *src++) != '\0') {}
    return r;
}

char *strncpy(char *dst, const char *src, size_t n) {
    char *r = dst;
    while (n > 0 && *src) {
        *dst++ = *src++;
        n--;
    }
    while (n-- > 0) *dst++ = '\0';
    return r;
}

char *strcat(char *dst, const char *src) {
    char *r = dst;
    while (*dst) dst++;
    while ((*dst++ = *src++) != '\0') {}
    return r;
}

char *strncat(char *dst, const char *src, size_t n) {
    char *r = dst;
    while (*dst) dst++;
    while (n-- > 0 && *src) *dst++ = *src++;
    *dst = '\0';
    return r;
}

char *strchr(const char *s, int c) {
    char ch = (char)c;
    for (;;) {
        if (*s == ch) return (char *)s;
        if (*s == '\0') return NULL;
        s++;
    }
}

char *strrchr(const char *s, int c) {
    char ch = (char)c;
    const char *last = NULL;
    for (;;) {
        if (*s == ch) last = s;
        if (*s == '\0') return (char *)last;
        s++;
    }
}

char *strstr(const char *haystack, const char *needle) {
    if (!*needle) return (char *)haystack;
    size_t nlen = strlen(needle);
    for (; *haystack; haystack++) {
        if (*haystack == *needle && strncmp(haystack, needle, nlen) == 0) {
            return (char *)haystack;
        }
    }
    return NULL;
}

/* ============================================================================
 * Allocator (16-byte aligned static DRAM bump allocator)
 * ============================================================================ */

void *malloc(size_t size) {
    if (size == 0) size = 16;
    size = (size + 15u) & ~(size_t)15u;
    spin_lock(&g_alloc_lock);
    if (g_heap_ptr == 0) g_heap_ptr = ((uintptr_t)__heap_start + 15u) & ~(uintptr_t)15u;
    uintptr_t p = g_heap_ptr;
    if (p + size > (uintptr_t)__heap_end) {
        spin_unlock(&g_alloc_lock);
        return NULL;
    }
    g_heap_ptr = p + size;
    spin_unlock(&g_alloc_lock);
    return (void *)p;
}

void *calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void free(void *ptr) {
    (void)ptr;
}

void *realloc(void *ptr, size_t size) {
    void *n = malloc(size);
    if (n && ptr) memcpy(n, ptr, size);
    return n;
}

void abort(void) {
    printf("[BENCH_ABORT]\n[BENCH_FAIL]\n");
    for (;;) __asm__ volatile("wfi");
}

void exit(int status) {
    bench_finish(status);
    for (;;) {}
}

int abs(int x) { return x < 0 ? -x : x; }
long labs(long x) { return x < 0 ? -x : x; }

static uint32_t g_rand_state = 1;
void srand(unsigned int seed) { g_rand_state = seed ? seed : 1; }
int rand(void) {
    g_rand_state = g_rand_state * 1103515245u + 12345u;
    return (int)((g_rand_state >> 16) & 0x7fffu);
}

int atoi(const char *s) {
    int neg = 0, val = 0;
    while (isspace((unsigned char)*s)) s++;
    if (*s == '-') { neg = 1; s++; }
    else if (*s == '+') s++;
    while (isdigit((unsigned char)*s)) {
        val = val * 10 + (*s - '0');
        s++;
    }
    return neg ? -val : val;
}

long strtol(const char *nptr, char **endptr, int base) {
    const char *s = nptr;
    int neg = 0;
    long val = 0;
    while (isspace((unsigned char)*s)) s++;
    if (*s == '-') { neg = 1; s++; }
    else if (*s == '+') s++;
    if (base == 0) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (s[0] == '0') { base = 8; s++; }
        else base = 10;
    } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }
    while (*s) {
        int d;
        if (*s >= '0' && *s <= '9') d = *s - '0';
        else if (*s >= 'a' && *s <= 'z') d = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'Z') d = *s - 'A' + 10;
        else break;
        if (d >= base) break;
        val = val * base + d;
        s++;
    }
    if (endptr) *endptr = (char *)s;
    return neg ? -val : val;
}

/* ============================================================================
 * Hardware IEEE-754 Math Helpers
 * ============================================================================ */

double sqrt(double x) {
    double r;
    __asm__("fsqrt.d %0, %1" : "=f"(r) : "f"(x));
    return r;
}

float sqrtf(float x) {
    float r;
    __asm__("fsqrt.s %0, %1" : "=f"(r) : "f"(x));
    return r;
}

double fabs(double x) {
    double r;
    __asm__("fabs.d %0, %1" : "=f"(r) : "f"(x));
    return r;
}

float fabsf(float x) {
    float r;
    __asm__("fabs.s %0, %1" : "=f"(r) : "f"(x));
    return r;
}

double floor(double x) {
    int64_t i = (int64_t)x;
    double d = (double)i;
    return (d > x) ? (d - 1.0) : d;
}

double ceil(double x) {
    int64_t i = (int64_t)x;
    double d = (double)i;
    return (d < x) ? (d + 1.0) : d;
}

/* ============================================================================
 * Timing & Dhrystone Hooks
 * ============================================================================ */

int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    uint64_t cyc = bench_rdcycle();
    /* 500 MHz => 500 cycles per microsecond */
    uint64_t us = cyc / (FURSOY_CPU_HZ / 1000000ULL);
    if (tv) {
        tv->tv_sec = (long)(us / 1000000ULL);
        tv->tv_usec = (long)(us % 1000000ULL);
    }
    return 0;
}

#ifndef DHRY_RUNS
#define DHRY_RUNS 2000
#endif

static int g_clock_calls = 0;
static uint64_t g_clock_c0 = 0;
static uint64_t g_clock_i0 = 0;

clock_t clock(void) {
    if (g_clock_calls == 0) {
        g_clock_calls = 1;
        bench_cpi_start();
        g_clock_c0 = bench_rdcycle();
        g_clock_i0 = bench_rdinstret();
        return (clock_t)g_clock_c0;
    } else if (g_clock_calls == 1) {
        uint64_t c1 = bench_rdcycle();
        uint64_t i1 = bench_rdinstret();
        bench_cpi_stop();
        g_clock_calls = 2;
        printf("[DHRY_RESULT] runs=%d cycles=%llu instret=%llu\n",
               (int)DHRY_RUNS,
               (unsigned long long)(c1 - g_clock_c0),
               (unsigned long long)(i1 - g_clock_i0));
        return (clock_t)c1;
    }
    return (clock_t)bench_rdcycle();
}

int scanf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (fmt && strstr(fmt, "%d")) {
        int *out = va_arg(ap, int *);
        if (out) *out = DHRY_RUNS;
        va_end(ap);
        return 1;
    }
    va_end(ap);
    return 0;
}

/* ============================================================================
 * Minimal Formatting (printf / snprintf / sprintf / putchar / puts)
 * ============================================================================ */

typedef struct {
    char *buf;
    size_t cap;
    size_t pos;
    int to_uart;
} fmt_out_t;

static void fmt_emit(fmt_out_t *o, char c) {
    if (o->to_uart) {
        bench_uart_putc(c);
    } else if (o->buf && o->pos + 1 < o->cap) {
        o->buf[o->pos] = c;
    }
    o->pos++;
}

static void fmt_emit_n(fmt_out_t *o, const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) fmt_emit(o, s[i]);
}

static void fmt_pad(fmt_out_t *o, char ch, int count) {
    while (count-- > 0) fmt_emit(o, ch);
}

static void fmt_uint(fmt_out_t *o, unsigned long long v, int base, int upper,
                     int width, int left, int zero_pad, char sign_ch) {
    char tmp[32];
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;
    if (v == 0) {
        tmp[n++] = '0';
    } else {
        while (v > 0) {
            tmp[n++] = digits[v % (unsigned)base];
            v /= (unsigned)base;
        }
    }
    int total = n + (sign_ch ? 1 : 0);
    int pad = width > total ? width - total : 0;
    if (!left && !zero_pad) fmt_pad(o, ' ', pad);
    if (sign_ch) fmt_emit(o, sign_ch);
    if (!left && zero_pad) fmt_pad(o, '0', pad);
    while (n > 0) fmt_emit(o, tmp[--n]);
    if (left) fmt_pad(o, ' ', pad);
}

static void fmt_double(fmt_out_t *o, double val, char spec, int width, int prec, int left, int zero_pad) {
    if (prec < 0) prec = 6;
    if (prec > 12) prec = 12;
    char buf[96];
    int len = 0;
    if (val != val) {
        strcpy(buf, "nan");
        len = 3;
    } else {
        int neg = 0;
        if (val < 0.0) {
            neg = 1;
            val = -val;
        }
        int sci = (spec == 'e' || spec == 'E');
        int exp10 = 0;
        if (spec == 'g' || spec == 'G') {
            if (val != 0.0 && (val < 1e-4 || val >= 1e6)) sci = 1;
        }
        if (sci && val != 0.0) {
            while (val >= 10.0) { val *= 0.1; exp10++; }
            while (val < 1.0) { val *= 10.0; exp10--; }
        }
        double round_add = 0.5;
        for (int i = 0; i < prec; i++) round_add *= 0.1;
        val += round_add;
        if (sci && val >= 10.0) {
            val *= 0.1;
            exp10++;
        }
        unsigned long long ipart = (unsigned long long)val;
        double frac = val - (double)ipart;
        if (neg) buf[len++] = '-';
        char ibuf[24];
        int ilen = 0;
        if (ipart == 0) ibuf[ilen++] = '0';
        else {
            while (ipart > 0) {
                ibuf[ilen++] = (char)('0' + (ipart % 10ULL));
                ipart /= 10ULL;
            }
        }
        while (ilen > 0) buf[len++] = ibuf[--ilen];
        if (prec > 0) {
            buf[len++] = '.';
            for (int i = 0; i < prec; i++) {
                frac *= 10.0;
                int d = (int)frac;
                if (d < 0) d = 0;
                if (d > 9) d = 9;
                buf[len++] = (char)('0' + d);
                frac -= (double)d;
            }
        }
        if (sci) {
            buf[len++] = (spec == 'E' || spec == 'G') ? 'E' : 'e';
            buf[len++] = (exp10 < 0) ? '-' : '+';
            int ae = exp10 < 0 ? -exp10 : exp10;
            if (ae >= 100) buf[len++] = (char)('0' + (ae / 100) % 10);
            buf[len++] = (char)('0' + (ae / 10) % 10);
            buf[len++] = (char)('0' + (ae % 10));
        }
    }
    int pad = width > len ? width - len : 0;
    if (!left) fmt_pad(o, zero_pad ? '0' : ' ', pad);
    fmt_emit_n(o, buf, (size_t)len);
    if (left) fmt_pad(o, ' ', pad);
}

static int fmt_vcore(fmt_out_t *o, const char *fmt, va_list ap) {
    while (*fmt) {
        if (*fmt != '%') {
            fmt_emit(o, *fmt++);
            continue;
        }
        fmt++;
        int left = 0, zero_pad = 0, plus = 0;
        for (;;) {
            if (*fmt == '-') { left = 1; fmt++; }
            else if (*fmt == '0') { zero_pad = 1; fmt++; }
            else if (*fmt == '+') { plus = 1; fmt++; }
            else if (*fmt == ' ' || *fmt == '#') { fmt++; }
            else break;
        }
        int width = 0;
        while (*fmt >= '0' && *fmt <= '9') {
            width = width * 10 + (*fmt - '0');
            fmt++;
        }
        int prec = -1;
        if (*fmt == '.') {
            fmt++;
            prec = 0;
            while (*fmt >= '0' && *fmt <= '9') {
                prec = prec * 10 + (*fmt - '0');
                fmt++;
            }
        }
        int lmod = 0;
        while (*fmt == 'l' || *fmt == 'h' || *fmt == 'z') {
            if (*fmt == 'l') lmod++;
            else if (*fmt == 'z') lmod = 1;
            fmt++;
        }
        char sp = *fmt ? *fmt++ : '\0';
        switch (sp) {
            case '%':
                fmt_emit(o, '%');
                break;
            case 'c': {
                char c = (char)va_arg(ap, int);
                fmt_emit(o, c);
                break;
            }
            case 's': {
                const char *s = va_arg(ap, const char *);
                if (!s) s = "(null)";
                size_t slen = strlen(s);
                if (prec >= 0 && (size_t)prec < slen) slen = (size_t)prec;
                int pad = width > (int)slen ? width - (int)slen : 0;
                if (!left) fmt_pad(o, ' ', pad);
                fmt_emit_n(o, s, slen);
                if (left) fmt_pad(o, ' ', pad);
                break;
            }
            case 'd':
            case 'i': {
                long long v = (lmod >= 2) ? va_arg(ap, long long)
                            : (lmod == 1) ? (long long)va_arg(ap, long)
                                          : (long long)va_arg(ap, int);
                char sign = 0;
                unsigned long long uv;
                if (v < 0) { sign = '-'; uv = (unsigned long long)(-(v + 1)) + 1ULL; }
                else { if (plus) sign = '+'; uv = (unsigned long long)v; }
                fmt_uint(o, uv, 10, 0, width, left, zero_pad, sign);
                break;
            }
            case 'u':
            case 'x':
            case 'X': {
                unsigned long long v = (lmod >= 2) ? va_arg(ap, unsigned long long)
                                     : (lmod == 1) ? (unsigned long long)va_arg(ap, unsigned long)
                                                   : (unsigned long long)va_arg(ap, unsigned int);
                int base = (sp == 'u') ? 10 : 16;
                fmt_uint(o, v, base, sp == 'X', width, left, zero_pad, 0);
                break;
            }
            case 'p': {
                uintptr_t p = (uintptr_t)va_arg(ap, void *);
                fmt_emit_n(o, "0x", 2);
                fmt_uint(o, (unsigned long long)p, 16, 0, 0, 0, 0, 0);
                break;
            }
            case 'f':
            case 'F':
            case 'e':
            case 'E':
            case 'g':
            case 'G': {
                double v = va_arg(ap, double);
                fmt_double(o, v, sp, width, prec, left, zero_pad);
                break;
            }
            default:
                fmt_emit(o, '%');
                if (sp) fmt_emit(o, sp);
                break;
        }
    }
    if (!o->to_uart && o->buf && o->cap > 0) {
        size_t idx = o->pos < o->cap ? o->pos : (o->cap - 1);
        o->buf[idx] = '\0';
    }
    return (int)o->pos;
}

int vprintf(const char *fmt, va_list ap) {
    fmt_out_t o = {NULL, 0, 0, 1};
    return fmt_vcore(&o, fmt, ap);
}

int printf(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}

int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap) {
    fmt_out_t o = {buf, cap, 0, 0};
    return fmt_vcore(&o, fmt, ap);
}

int snprintf(char *buf, size_t cap, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, cap, fmt, ap);
    va_end(ap);
    return r;
}

int sprintf(char *buf, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vsnprintf(buf, (size_t)1 << 20, fmt, ap);
    va_end(ap);
    return r;
}

int putchar(int c) {
    bench_uart_putc((char)c);
    return (unsigned char)c;
}

int puts(const char *s) {
    while (*s) bench_uart_putc(*s++);
    bench_uart_putc('\n');
    return 0;
}
