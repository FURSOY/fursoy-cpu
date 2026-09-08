    .option norvc
    .option norelax
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la sp, __stack_top
    la t0, trap_handler
    csrw mtvec, t0
    csrw mie, zero
    csrci mstatus, 8
    li s0, 0x02000000
    li s1, 0
    li s2, 0
    li s3, 0
    li s4, 0
    li s5, 0
    li s6, 0
    li s7, 0
    li s8, 0
    sw zero, 0(s0)

    // Alternate external RAM and CLINT reads before interrupt testing.
    la t0, signature
    ld t1, 0(t0)
    bnez t1, fail
    lw t2, 0(s0)
    bnez t2, fail
    ld t3, 8(t0)
    bnez t3, fail
    li t4, 0x0200bff8
    ld t5, 0(t4)

    li t0, 8
    csrw mie, t0
    csrsi mstatus, 8
    li t1, 1
    sw t1, 0(s0)
software_return:
    csrci mstatus, 8
    li t0, 1
    bne s1, t0, fail
    lw t1, 0(s0)
    bnez t1, fail

    li t0, 0x02004000
    li t1, -1
    sd t1, 0(t0)
    li t2, 0x0200bff8
    ld t3, 0(t2)
    addi t3, t3, 32
    sd t3, 0(t0)
    li t0, 0x80
    csrw mie, t0
    csrsi mstatus, 8
timer_wait:
    beqz s2, timer_wait
    csrci mstatus, 8
    li t0, 1
    bne s2, t0, fail

    // Invalid CLINT widths must become precise architectural access faults.
bad_store:
    sd zero, 0(s0)
bad_load:
    li t0, 0x0200bff8
    li a4, 0x55
fault_width_load:
    lw a4, 0(t0)
    li t0, 0x55
    bne a4, t0, fail
bad_align:
    li a5, 0x66
fault_align_load:
    lw a5, 2(s0)
    li t0, 0x66
    bne a5, t0, fail
bad_access:
    // The testbench raises external IRQ only after this load is in the LSU, so
    // a globally enabled interrupt and its synchronous fault coincide.
    li t0, 0x800
    csrw mie, t0
    csrsi mstatus, 8
    li a6, 0x77
fault_with_pending_irq:
    ld a6, 8(s0)
    li t0, 0x77
    bne a6, t0, fail
    la t0, signature
    li a7, 0x44
ram_error_load:
    ld a7, 56(t0)
    li t0, 0x44
    bne a7, t0, fail
after_faults:
    li t0, 1
    bne s3, t0, fail
    bne s4, t0, fail
    bne s5, t0, fail
    bne s6, t0, fail
    bne s7, t0, fail
    bne s8, t0, fail

    la t0, signature
    sd s1, 0(t0)
    sd s2, 8(t0)
    sd s3, 16(t0)
    sd s4, 24(t0)
    sd s5, 32(t0)
    sd s6, 40(t0)
    sd s7, 48(t0)
    sd s8, 56(t0)
    li t1, 1
    la t0, tohost
    sd t1, 0(t0)
park:
    j park

    .balign 4
trap_handler:
    csrr t0, mcause
    bltz t0, interrupt_trap
    li t1, 7
    beq t0, t1, store_fault
    li t1, 5
    beq t0, t1, load_fault
    li t1, 4
    beq t0, t1, align_fault
    j fail
interrupt_trap:
    andi t0, t0, 0xff
    li t1, 3
    beq t0, t1, software_irq
    li t1, 7
    beq t0, t1, timer_irq
    j fail
software_irq:
    sw zero, 0(s0)
    addi s1, s1, 1
    mret
timer_irq:
    li t0, 0x02004000
    li t1, -1
    sd t1, 0(t0)
    addi s2, s2, 1
    mret
store_fault:
    csrr t0, mtval
    bne t0, s0, fail
    csrr t0, mepc
    la t1, bad_store
    bne t0, t1, fail
    addi s3, s3, 1
    j skip_faulting_insn
load_fault:
    csrr t0, mtval
    la t1, signature
    addi t1, t1, 56
    beq t0, t1, ram_load_fault
    li t1, 0x0200bff8
    beq t0, t1, width_load_fault
    addi t1, s0, 8
    bne t0, t1, fail
    csrr t0, mepc
    la t1, fault_with_pending_irq
    bne t0, t1, fail
    addi s5, s5, 1
    addi s7, s7, 1
    j skip_faulting_insn
width_load_fault:
    csrr t0, mepc
    la t1, fault_width_load
    bne t0, t1, fail
    addi s4, s4, 1
    j skip_faulting_insn
ram_load_fault:
    csrr t0, mepc
    la t1, ram_error_load
    bne t0, t1, fail
    addi s8, s8, 1
    j skip_faulting_insn
align_fault:
    csrr t0, mtval
    addi t1, s0, 2
    bne t0, t1, fail
    csrr t0, mepc
    la t1, fault_align_load
    bne t0, t1, fail
    addi s6, s6, 1
skip_faulting_insn:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret
fail:
    li t1, 3
    la t0, tohost
    sd t1, 0(t0)
    j park

    .section .host,"aw",@progbits
    .balign 8
    .globl tohost, fromhost, signature
tohost: .dword 0
fromhost: .dword 0
signature:
    .dword 0, 0, 0, 0, 0, 0, 0, 0
