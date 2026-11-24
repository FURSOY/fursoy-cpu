#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include "bench_libc.h"
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef HAS_FLOAT
#define HAS_FLOAT 1
#endif
#ifndef HAS_TIME_H
#define HAS_TIME_H 0
#endif
#ifndef USE_CLOCK
#define USE_CLOCK 0
#endif
#ifndef HAS_STDIO
#define HAS_STDIO 1
#endif
#ifndef HAS_PRINTF
#define HAS_PRINTF 1
#endif

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

#ifndef MULTITHREAD
#define MULTITHREAD 1
#endif

#ifndef MEM_METHOD
#if (MULTITHREAD > 1)
#define MEM_METHOD MEM_MALLOC
#else
#define MEM_METHOD MEM_STACK
#endif
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC 13.3.0 (riscv64-linux-gnu-gcc)"
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-march=rv64imafd_zba_zbb -mabi=lp64d -mstrict-align -O3"
#endif
#ifndef MEM_LOCATION
#if (MEM_METHOD == MEM_MALLOC)
#define MEM_LOCATION "HEAP"
#else
#define MEM_LOCATION "STACK"
#endif
#endif

typedef int16_t  ee_s16;
typedef uint16_t ee_u16;
typedef int32_t  ee_s32;
typedef double   ee_f32;
typedef uint8_t  ee_u8;
typedef uint32_t ee_u32;
typedef uintptr_t ee_ptr_int;
typedef size_t   ee_size_t;
typedef uint64_t CORE_TICKS;

#define align_mem(x) (void *)(8 + (((ee_ptr_int)(x) - 1) & ~7))

#define CORETIMETYPE uint64_t
#define EE_TICKS_PER_SEC 500000000ULL
#define GETMYTIME(_t) (*(_t) = bench_rdcycle())
#define MYTIMEDIFF(fin, ini) ((fin) - (ini))
#define TIMER_RES_DIVIDER 1
#define SAMPLE_TIME_IMPLEMENTATION 1

#define ee_printf printf

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

extern ee_u32 default_num_contexts;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);
void *portable_malloc(ee_size_t size);
void portable_free(void *p);

#if (MULTITHREAD > 1)
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#define PARALLEL_METHOD "Fursoy Bare-Metal SMP Harts"
#endif

#endif /* CORE_PORTME_H */
