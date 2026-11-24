#ifndef _BENCH_TIME_H
#define _BENCH_TIME_H
typedef long clock_t;
typedef long time_t;
#define CLOCKS_PER_SEC 500000000L
#define CLK_TCK        500000000L
clock_t clock(void);
#endif
