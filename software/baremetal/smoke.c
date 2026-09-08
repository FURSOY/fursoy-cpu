/* No libc, multiplication, compressed, floating-point or atomic extension required. */
static volatile unsigned long values[100];
extern volatile unsigned long signature[];

unsigned long smoke_main(void) {
    unsigned long total = 0;
    for (unsigned long i = 0; i < 100; ++i) {
        if (values[i] != 0) return 1;
        values[i] = i + 1;
    }
    for (unsigned long i = 0; i < 100; ++i) total += values[i];
    if (total != 5050) return 2;
    if (signature[7] != 1) return 3;
    return 0;
}
