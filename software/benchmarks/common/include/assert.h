#ifndef _BENCH_ASSERT_H
#define _BENCH_ASSERT_H
#include <stdlib.h>
#include <stdio.h>
#ifdef NDEBUG
#define assert(expr) ((void)0)
#else
#define assert(expr) do { if (!(expr)) { printf("[ASSERT_FAIL] %s:%d: %s\n", __FILE__, __LINE__, #expr); abort(); } } while (0)
#endif
#endif
