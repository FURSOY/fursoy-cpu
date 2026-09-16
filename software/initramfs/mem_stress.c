// Memory Stress Test for Fursoy Slice-0 Linux Userspace Validation
// Exercises stack, heap, byte, halfword, word, doubleword accesses,
// memcpy/memset-like behavior, and nontrivial strided address permutations.

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#define STACK_BUF_WORDS 128
#define HEAP_BUF_WORDS  1024

static void fail(const char* msg) {
    printf("[MEM_STRESS_FAIL] %s\n", msg);
    exit(1);
}

// 1. Stack memory access with multiple widths
static void test_stack_access(void) {
    volatile uint64_t stack_buf[STACK_BUF_WORDS];
    uint8_t* byte_ptr = (uint8_t*)stack_buf;
    uint16_t* hword_ptr = (uint16_t*)stack_buf;
    uint32_t* word_ptr = (uint32_t*)stack_buf;
    uint64_t* dword_ptr = (uint64_t*)stack_buf;

    // Byte write & readback
    for (int i = 0; i < STACK_BUF_WORDS * 8; i++) {
        byte_ptr[i] = (uint8_t)(i * 13 + 7);
    }
    for (int i = 0; i < STACK_BUF_WORDS * 8; i++) {
        if (byte_ptr[i] != (uint8_t)(i * 13 + 7)) {
            fail("Stack byte readback mismatch");
        }
    }

    // Halfword write & readback
    for (int i = 0; i < STACK_BUF_WORDS * 4; i++) {
        hword_ptr[i] = (uint16_t)(i * 31 + 0x1234);
    }
    for (int i = 0; i < STACK_BUF_WORDS * 4; i++) {
        if (hword_ptr[i] != (uint16_t)(i * 31 + 0x1234)) {
            fail("Stack halfword readback mismatch");
        }
    }

    // Word write & readback
    for (int i = 0; i < STACK_BUF_WORDS * 2; i++) {
        word_ptr[i] = (uint32_t)(i * 10007 + 0x89abcdef);
    }
    for (int i = 0; i < STACK_BUF_WORDS * 2; i++) {
        if (word_ptr[i] != (uint32_t)(i * 10007 + 0x89abcdef)) {
            fail("Stack word readback mismatch");
        }
    }

    // Doubleword write & readback
    for (int i = 0; i < STACK_BUF_WORDS; i++) {
        dword_ptr[i] = ((uint64_t)i << 32) ^ (0xdeadbeefcafebabeULL + i * 0x100000001ULL);
    }
    for (int i = 0; i < STACK_BUF_WORDS; i++) {
        uint64_t expected = ((uint64_t)i << 32) ^ (0xdeadbeefcafebabeULL + i * 0x100000001ULL);
        if (dword_ptr[i] != expected) {
            fail("Stack doubleword readback mismatch");
        }
    }
}

// 2. Heap memory allocation, memset, memcpy, and strided patterns
static void test_heap_access(void) {
    uint64_t* src = (uint64_t*)malloc(HEAP_BUF_WORDS * sizeof(uint64_t));
    uint64_t* dst = (uint64_t*)malloc(HEAP_BUF_WORDS * sizeof(uint64_t));

    if (!src || !dst) {
        fail("Heap allocation failed");
    }

    // Memset pattern
    memset(src, 0x5a, HEAP_BUF_WORDS * sizeof(uint64_t));
    uint8_t* src_b = (uint8_t*)src;
    for (size_t i = 0; i < HEAP_BUF_WORDS * sizeof(uint64_t); i++) {
        if (src_b[i] != 0x5a) fail("Memset verification failed");
    }

    // Deterministic pseudo-random generation
    uint64_t lfsr = 0xabcdef0123456789ULL;
    for (int i = 0; i < HEAP_BUF_WORDS; i++) {
        lfsr = (lfsr >> 1) ^ (-(lfsr & 1ULL) & 0xd800000000000000ULL);
        src[i] = lfsr ^ ((uint64_t)i * 0x0101010101010101ULL);
    }

    // Memcpy
    memcpy(dst, src, HEAP_BUF_WORDS * sizeof(uint64_t));

    // Verify copy
    for (int i = 0; i < HEAP_BUF_WORDS; i++) {
        if (dst[i] != src[i]) fail("Memcpy verification failed");
    }

    // Nontrivial strided access pattern (stride = 17, prime relative to 1024)
    uint64_t accum = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < HEAP_BUF_WORDS; i++) {
            int idx = (i * 17) & (HEAP_BUF_WORDS - 1);
            dst[idx] ^= (accum + idx);
            accum += dst[idx];
        }
    }

    // Verify checksum non-zero
    if (accum == 0) fail("Strided computation degenerate");

    free(src);
    free(dst);
}

int main(int argc, char** argv) {
    printf("[MEM_STRESS_START] Running stack and heap multi-width memory validation...\n");
    test_stack_access();
    test_heap_access();
    printf("[MEM_STRESS_PASS] All stack, heap, multi-width, and strided tests passed.\n");
    return 0;
}
