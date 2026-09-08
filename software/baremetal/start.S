    .option norvc
    .option norelax
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la sp, __stack_top
    csrw mie, zero
    csrci mstatus, 8
    la t0, trap_handler
    csrw mtvec, t0
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:  fence.i
    .globl ecall_probe
ecall_probe:
    ecall
    call smoke_main
    la t0, signature
    sd a0, 24(t0)
    bnez a0, fail
    li t1, 1
    sd t1, 16(t0)
    fence rw, rw
    la t0, tohost
    sd t1, 0(t0)
park:
    j park

    .balign 4
trap_handler:
    la t0, signature
    csrr t1, mcause
    sd t1, 32(t0)
    csrr t2, mepc
    sd t2, 40(t0)
    csrr t3, mtval
    sd t3, 48(t0)
    li t3, 11
    bne t1, t3, trap_fail
    la t3, ecall_probe
    bne t2, t3, trap_fail
    ld t3, 56(t0)
    bnez t3, trap_fail
    li t3, 1
    sd t3, 56(t0)
    addi t2, t2, 4
    csrw mepc, t2
    mret
trap_fail:
    li t1, 100
    sd t1, 24(t0)
fail:
    li t1, 2
    sd t1, 16(t0)
    fence rw, rw
    li t1, 3
    la t0, tohost
    sd t1, 0(t0)
    j park

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
