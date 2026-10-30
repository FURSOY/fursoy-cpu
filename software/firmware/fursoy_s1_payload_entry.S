/* Fursoy Slice-1 S-Mode Verification Payload Entry and Trap Vector.
 * Executed at 0x8020_0000 via mret from M-mode firmware.
 * Specification authority: docs/architecture/slice1-m9-soc-linux-v1.md v1.1 §6.2, §6.3
 */
    .option norvc
    .option norelax
    .section .text.entry,"ax",@progbits
    .globl payload_start
payload_start:
    # Immediately record handoff state before clobbering registers
    # We use temporary scratch memory inside payload data section
    la s0, handoff_capture

    # Record a0, a1
    sd a0, 0(s0)
    sd a1, 8(s0)

    # Record satp, sstatus, sie
    csrr s1, satp
    sd s1, 16(s0)
    csrr s1, sstatus
    sd s1, 24(s0)
    csrr s1, sie
    sd s1, 32(s0)

    # Check GPR hygiene: check if ra, sp, gp, tp, t0-t6, s1-s11, a2-a7 are all 0
    # Note: s0 was used for la, but we check if other registers are 0
    or s1, ra, sp
    or s1, s1, gp
    or s1, s1, tp
    or s1, s1, t0
    or s1, s1, t1
    or s1, s1, t2
    or s1, s1, a2
    or s1, s1, a3
    or s1, s1, a4
    or s1, s1, a5
    or s1, s1, a6
    or s1, s1, a7
    or s1, s1, s2
    or s1, s1, s3
    or s1, s1, s4
    or s1, s1, s5
    or s1, s1, s6
    or s1, s1, s7
    or s1, s1, s8
    or s1, s1, s9
    or s1, s1, s10
    or s1, s1, s11
    or s1, s1, t3
    or s1, s1, t4
    or s1, s1, t5
    or s1, s1, t6
    sd s1, 40(s0) # 0 means hygiene passed

    # Set up S-mode stack
    la sp, __payload_stack_top

    # Set up S-mode trap vector (Direct mode)
    la t0, s_trap_entry
    csrw stvec, t0

    # Call main C payload routine
    call payload_main

    # If payload_main returns, park
1:  wfi
    j 1b

    .section .text,"ax",@progbits
    .globl s_trap_entry
    .balign 4
s_trap_entry:
    # Save S-mode registers
    addi sp, sp, -256
    sd ra,   0(sp)
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

    # Call C trap handler: s_trap_handler(scause, sepc, stval)
    csrr a0, scause
    csrr a1, sepc
    csrr a2, stval
    call s_trap_handler

    # Enforce SPP = 1 (Supervisor mode) so sret returns to S-mode
    li t0, (1 << 8)
    csrs sstatus, t0

    # Restore registers
    ld ra,   0(sp)
    ld gp,  16(sp)
    ld tp,  24(sp)
    ld t0,  32(sp)
    ld t1,  40(sp)
    ld t2,  48(sp)
    ld s0,  56(sp)
    ld s1,  64(sp)
    ld a0,  72(sp)
    ld a1,  80(sp)
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
    addi sp, sp, 256

    sret
    .rept 16
    nop
    .endr

    # Helper: raw SBI call from assembly
    .balign 8
    .globl sbi_ecall_raw
sbi_ecall_raw:
    # a0 = eid, a1 = fid, a2 = arg0, a3 = arg1, a4 = arg2, a5 = arg3
    mv a7, a0
    mv a6, a1
    mv a0, a2
    mv a1, a3
    mv a2, a4
    mv a3, a5
    .balign 8
    ecall
    .rept 64
    nop
    .endr
    # returns with a0 = error, a1 = value
    ret
    .rept 64
    nop
    .endr

    # Helper: verify register preservation across SBI call
    .globl check_sbi_reg_preservation
check_sbi_reg_preservation:
    addi sp, sp, -104
    sd ra,  0(sp)
    sd s0,  8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd s6, 56(sp)
    sd s7, 64(sp)
    sd s8, 72(sp)
    sd s9, 80(sp)
    sd s10, 88(sp)
    sd s11, 96(sp)

    # Set distinctive canary values into s0..s11
    li s0, 0x1111111111111111
    li s1, 0x2222222222222222
    li s2, 0x3333333333333333
    li s3, 0x4444444444444444
    li s4, 0x5555555555555555
    li s5, 0x6666666666666666
    li s6, 0x7777777777777777
    li s7, 0x8888888888888888
    li s8, 0x9999999999999999
    li s9, 0xAAAAAAAAAAAAAAAA
    li s10, 0xBBBBBBBBBBBBBBBB
    li s11, 0xCCCCCCCCCCCCCCCC

    # Call Base spec version (EID 0x10, FID 0)
    li a7, 0x10
    li a6, 0
    li a0, 0
    li a1, 0
    .balign 8
    ecall
    nop

    # Now verify all s0..s11 are unchanged
    li t0, 1
    li t1, 0x1111111111111111
    bne s0, t1, 1f
    li t1, 0x2222222222222222
    bne s1, t1, 1f
    li t1, 0x3333333333333333
    bne s2, t1, 1f
    li t1, 0x4444444444444444
    bne s3, t1, 1f
    li t1, 0x5555555555555555
    bne s4, t1, 1f
    li t1, 0x6666666666666666
    bne s5, t1, 1f
    li t1, 0x7777777777777777
    bne s6, t1, 1f
    li t1, 0x8888888888888888
    bne s7, t1, 1f
    li t1, 0x9999999999999999
    bne s8, t1, 1f
    li t1, 0xAAAAAAAAAAAAAAAA
    bne s9, t1, 1f
    li t1, 0xBBBBBBBBBBBBBBBB
    bne s10, t1, 1f
    li t1, 0xCCCCCCCCCCCCCCCC
    bne s11, t1, 1f
    j 2f
1:  li t0, 0
2:  mv a0, t0

    ld ra,  0(sp)
    ld s0,  8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    ld s5, 48(sp)
    ld s6, 56(sp)
    ld s7, 64(sp)
    ld s8, 72(sp)
    ld s9, 80(sp)
    ld s10, 88(sp)
    ld s11, 96(sp)
    addi sp, sp, 104
    ret

    .section .data,"aw",@progbits
    .globl handoff_capture
    .balign 8
handoff_capture:
    .quad 0 # 0: a0
    .quad 0 # 8: a1
    .quad 0 # 16: satp
    .quad 0 # 24: sstatus
    .quad 0 # 32: sie
    .quad 0 # 40: gpr_hygiene_or
