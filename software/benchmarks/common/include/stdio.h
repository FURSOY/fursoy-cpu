#ifndef _BENCH_STDIO_H
#define _BENCH_STDIO_H
#include <stdarg.h>
#include <stddef.h>
typedef struct { int unused; } FILE;
extern FILE *stdout;
extern FILE *stderr;
#define EOF (-1)
int printf(const char *fmt, ...);
int vprintf(const char *fmt, va_list ap);
int sprintf(char *buf, const char *fmt, ...);
int snprintf(char *buf, size_t cap, const char *fmt, ...);
int vsnprintf(char *buf, size_t cap, const char *fmt, va_list ap);
int scanf(const char *fmt, ...);
int putchar(int c);
int puts(const char *s);
static inline int fprintf(FILE *f, const char *fmt, ...) {
    (void)f;
    va_list ap;
    va_start(ap, fmt);
    int r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}
static inline int fflush(FILE *f) { (void)f; return 0; }
#endif
