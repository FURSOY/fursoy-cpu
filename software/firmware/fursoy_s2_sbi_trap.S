#include "fursoy_s2_sbi.h"

    .section .text
    .align 4
    .globl _sbi_mtrap_entry

_sbi_mtrap_entry:
    /* Swap sp <-> mscratch so sp points to per-hart M-mode stack top */
    csrrw   sp, mscratch, sp
    addi    sp, sp, -288        /* 35 * 8 = 280B regs + 8B pad (16B aligned) */

    sd      ra,   0*8(sp)
    /* slot 1*8(sp) reserved for original sp (from mscratch) */
    sd      gp,   2*8(sp)
    sd      tp,   3*8(sp)
    sd      t0,   4*8(sp)
    sd      t1,   5*8(sp)
    sd      t2,   6*8(sp)
    sd      s0,   7*8(sp)
    sd      s1,   8*8(sp)
    sd      a0,   9*8(sp)
    sd      a1,  10*8(sp)
    sd      a2,  11*8(sp)
    sd      a3,  12*8(sp)
    sd      a4,  13*8(sp)
    sd      a5,  14*8(sp)
    sd      a6,  15*8(sp)
    sd      a7,  16*8(sp)
    sd      s2,  17*8(sp)
    sd      s3,  18*8(sp)
    sd      s4,  19*8(sp)
    sd      s5,  20*8(sp)
    sd      s6,  21*8(sp)
    sd      s7,  22*8(sp)
    sd      s8,  23*8(sp)
    sd      s9,  24*8(sp)
    sd      s10, 25*8(sp)
    sd      s11, 26*8(sp)
    sd      t3,  27*8(sp)
    sd      t4,  28*8(sp)
    sd      t5,  29*8(sp)
    sd      t6,  30*8(sp)

    csrr    t0, mscratch
    sd      t0,   1*8(sp)       /* regs->sp */
    addi    t0, sp, 288
    csrw    mscratch, t0        /* restore M-mode stack top into mscratch */

    csrr    t0, mepc
    sd      t0,  31*8(sp)
    csrr    t1, mstatus
    sd      t1,  32*8(sp)
    csrr    t2, mcause
    sd      t2,  33*8(sp)
    csrr    t3, mtval
    sd      t3,  34*8(sp)

    mv      a0, sp
    call    sbi_handle_trap

    ld      t0,  31*8(sp)
    csrw    mepc, t0
    ld      t1,  32*8(sp)
    csrw    mstatus, t1

    ld      ra,   0*8(sp)
    ld      gp,   2*8(sp)
    ld      tp,   3*8(sp)
    ld      t0,   4*8(sp)
    ld      t1,   5*8(sp)
    ld      t2,   6*8(sp)
    ld      s0,   7*8(sp)
    ld      s1,   8*8(sp)
    ld      a0,   9*8(sp)
    ld      a1,  10*8(sp)
    ld      a2,  11*8(sp)
    ld      a3,  12*8(sp)
    ld      a4,  13*8(sp)
    ld      a5,  14*8(sp)
    ld      a6,  15*8(sp)
    ld      a7,  16*8(sp)
    ld      s2,  17*8(sp)
    ld      s3,  18*8(sp)
    ld      s4,  19*8(sp)
    ld      s5,  20*8(sp)
    ld      s6,  21*8(sp)
    ld      s7,  22*8(sp)
    ld      s8,  23*8(sp)
    ld      s9,  24*8(sp)
    ld      s10, 25*8(sp)
    ld      s11, 26*8(sp)
    ld      t3,  27*8(sp)
    ld      t4,  28*8(sp)
    ld      t5,  29*8(sp)
    ld      t6,  30*8(sp)

    ld      sp,   1*8(sp)       /* restore trapped sp last */
    mret
