#ifndef _BENCH_STDLIB_H
#define _BENCH_STDLIB_H
#include <stddef.h>
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 32767
void *malloc(size_t size);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);
void abort(void);
void exit(int status);
int abs(int x);
long labs(long x);
int atoi(const char *s);
long strtol(const char *nptr, char **endptr, int base);
int rand(void);
void srand(unsigned int seed);
#endif
