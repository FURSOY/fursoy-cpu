    .option norvc
    .section .text,"ax",@progbits
    .globl smoke_main, csr_suppress_probe
smoke_main:
csr_suppress_probe:
    csrrwi zero, mscratch, 31
    csrrs  t0, mscratch, zero
    li     t1, 31
    bne    t0, t1, 1f

    csrrsi zero, mscratch, 0
    csrrs  t0, mscratch, zero
    bne    t0, t1, 1f

    csrrci zero, mscratch, 0
    csrrs  t0, mscratch, zero
    bne    t0, t1, 1f

    csrrsi zero, mscratch, 1
    csrrs  t0, mscratch, zero
    li     t1, 31
    bne    t0, t1, 1f

    csrrci zero, mscratch, 1
    csrrs  t0, mscratch, zero
    li     t1, 30
    bne    t0, t1, 1f

    csrrw  zero, mscratch, zero
    csrrs  t0, mscratch, zero
    bnez   t0, 1f
    li     a0, 0
    ret
1:  li     a0, 6
    ret
