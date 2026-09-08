/* Fursoy Slice-0 Minimal SBI M-Mode Trap Handler.
 * Handles Supervisor ECALL (mcause 9) and Machine Timer Interrupt (mcause 7).
 * Preserves all unaffected architectural registers across SBI ECALLs.
 */
    .option norvc
    .option norelax
    .section .text,"ax",@progbits
    .globl sbi_trap_entry
    .balign 4
sbi_trap_entry:
    # Swap S-mode sp with mscratch (which holds M-mode stack top)
    csrrw sp, mscratch, sp

    # Allocate frame on M-mode stack (256 bytes)
    addi sp, sp, -256

    # Save general-purpose registers
    sd ra,   0(sp)
    # offset 8 will store original S-mode sp
    sd gp,  16(sp)
    sd tp,  24(sp)
    sd t0,  32(sp)
    sd t1,  40(sp)
    sd t2,  48(sp)
    sd s0,  56(sp)
    sd s1,  64(sp)
    sd a0,  72(sp)
    sd a1,  80(sp)
    sd a2,  88(sp)
    sd a3,  96(sp)
    sd a4, 104(sp)
    sd a5, 112(sp)
    sd a6, 120(sp)
    sd a7, 128(sp)
    sd s2, 136(sp)
    sd s3, 144(sp)
    sd s4, 152(sp)
    sd s5, 160(sp)
    sd s6, 168(sp)
    sd s7, 176(sp)
    sd s8, 184(sp)
    sd s9, 192(sp)
    sd s10, 200(sp)
    sd s11, 208(sp)
    sd t3, 216(sp)
    sd t4, 224(sp)
    sd t5, 232(sp)
    sd t6, 240(sp)

    # Save original S-mode sp from mscratch
    csrr t0, mscratch
    sd t0, 8(sp)

    # Inspect mcause
    csrr t0, mcause

    # Check for S-mode ECALL (mcause == 9)
    li t1, 9
    beq t0, t1, handle_sbi_ecall

    # Check for Machine Timer Interrupt (mcause == 0x8000_0000_0000_0007)
    li t1, 0x8000000000000007
    beq t0, t1, handle_timer_irq

    # Unexpected M-mode trap: call sbi_panic(cause, mepc, mtval)
    mv a0, t0
    csrr a1, mepc
    csrr a2, mtval
    call sbi_panic

handle_sbi_ecall:
    # Arguments to sbi_ecall_dispatch:
    # a0 = eid (from saved a7)
    # a1 = fid (from saved a6)
    # a2 = arg0 (from saved a0)
    # a3 = arg1 (from saved a1)
    # a4 = arg2 (from saved a2)
    # a5 = arg3 (from saved a3)
    ld a0, 128(sp) # saved a7
    ld a1, 120(sp) # saved a6
    ld a2,  72(sp) # saved a0
    ld a3,  80(sp) # saved a1
    ld a4,  88(sp) # saved a2
    ld a5,  96(sp) # saved a3

    call sbi_ecall_dispatch

    # Store sbiret return values: a0 = error, a1 = value
    sd a0, 72(sp)
    sd a1, 80(sp)

    # Advance mepc by exactly 4 bytes
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0

    j trap_return

handle_timer_irq:
    call sbi_timer_trap_handler
    # For interrupts, mepc already points to interrupted PC; do not advance mepc
    j trap_return

trap_return:
    # Restore general-purpose registers
    ld ra,   0(sp)
    ld gp,  16(sp)
    ld tp,  24(sp)
    ld t1,  40(sp)
    ld t2,  48(sp)
    ld s0,  56(sp)
    ld s1,  64(sp)
    ld a0,  72(sp) # sbiret.error
    ld a1,  80(sp) # sbiret.value
    ld a2,  88(sp)
    ld a3,  96(sp)
    ld a4, 104(sp)
    ld a5, 112(sp)
    ld a6, 120(sp)
    ld a7, 128(sp)
    ld s2, 136(sp)
    ld s3, 144(sp)
    ld s4, 152(sp)
    ld s5, 160(sp)
    ld s6, 168(sp)
    ld s7, 176(sp)
    ld s8, 184(sp)
    ld s9, 192(sp)
    ld s10, 200(sp)
    ld s11, 208(sp)
    ld t3, 216(sp)
    ld t4, 224(sp)
    ld t5, 232(sp)
    ld t6, 240(sp)

    # Load S-mode sp from frame into mscratch
    ld t0, 8(sp)
    csrw mscratch, t0

    # Restore S-mode t0
    ld t0, 32(sp)

    # Deallocate frame: sp returns to M-mode stack top
    addi sp, sp, 256

    # Atomic swap: sp becomes S-mode sp, mscratch becomes M-mode stack top
    csrrw sp, mscratch, sp

    # Return to S-mode
    mret
