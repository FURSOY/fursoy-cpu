    .option norvc
    .option norelax
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la      t0, signature
    csrr    t1, mstatus
    sd      t1, 24(t0)
    csrr    t1, mie
    sd      t1, 32(t0)
    csrr    t1, mtvec
    sd      t1, 40(t0)
    csrr    t1, mcause
    sd      t1, 48(t0)
    csrr    t1, mepc
    sd      t1, 56(t0)
    li      t1, 1
    sd      t1, 16(t0)
    fence   rw, rw
    la      t0, tohost
    sd      t1, 0(t0)
1:  j       1b

    .section .host,"aw",@progbits
    .balign 8
    .globl tohost, fromhost, signature, begin_signature, end_signature
tohost: .dword 0
fromhost: .dword 0
begin_signature:
signature:
    .dword 0x465552534f593031
    .dword 1
    .dword 0, 0, 0, 0, 0, 0
end_signature:
