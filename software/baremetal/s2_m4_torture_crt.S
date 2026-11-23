    .option norvc
    .option norelax

#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

.equ PRIV_STACK_BASE, 0x80400000

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    csrr s0, mhartid
    li   t0, NUM_HARTS
    bgeu s0, t0, _halt_loop

    /* Per-hart private 16 KiB stack starting at 0x8040_4000 + hartid*16K */
    slli t1, s0, 14
    li   t2, PRIV_STACK_BASE + 0x4000
    add  sp, t2, t1

    csrw mie, zero
    csrci mstatus, 8
    la   t0, _m_trap_nop
    csrw mtvec, t0
    li   t0, 7
    csrw mcounteren, t0
    csrw scounteren, t0

    mv   a0, s0
    call torture_main

_halt_loop:
    wfi
    j    _halt_loop

    .align 4
_m_trap_nop:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
