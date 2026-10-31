/* Fursoy Slice-1 Minimal SBI M-Mode Trap Handler.
 * Handles Supervisor ECALL (mcause 9) and Machine Timer Interrupt (mcause 7).
 * Implements register-direct SBI v2.0 dispatch with zero stack memory traffic.
 * Preserves all callee-saved registers (s0-s11, sp, gp, tp, ra) across SBI ECALLs.
 */
    .option norvc
    .option norelax
    .section .text,"ax",@progbits
    .globl fursoy_s1_sbi_trap_entry
    .balign 4
fursoy_s1_sbi_trap_entry:
    # 1. Immediately preserve S-mode t0 into mscratch before touching ANY registers
    csrw mscratch, t0

    # 2. Inspect mcause in t0
    csrr t0, mcause

    # 3. Check if this is an asynchronous interrupt (MSB == 1)
    bltz t0, .Lhandle_interrupt

    # 4. Synchronous Exception: check for Supervisor ECALL (mcause == 9)
    li t1, 9
    bne t0, t1, .Lunexpected_m_trap

    # =========================================================================
    # Supervisor ECALL Dispatch (mcause 9)
    # Register ABI:
    #   a7 = EID (Extension ID)
    #   a6 = FID (Function ID)
    #   a0..a5 = Arguments
    # Returns:
    #   a0 = sbiret.error
    #   a1 = sbiret.value
    # =========================================================================

    # 1. Check SBI Base Extension (EID 0x10)
    li t0, 0x10
    beq a7, t0, .Lsbi_base

    # 2. Check SBI DBCN Extension (EID 0x4442434E)
    li t0, 0x4442434E
    beq a7, t0, .Lsbi_dbcn

    # 3. Check SBI TIME Extension (EID 0x54494D45)
    li t0, 0x54494D45
    beq a7, t0, .Lsbi_time

    # 4. Check SBI SRST Extension (EID 0x53525354)
    li t0, 0x53525354
    beq a7, t0, .Lsbi_srst

    # Unsupported Extension ID
    j .Lsbi_notsup

    # =========================================================================
    # SBI Base Extension (EID 0x10)
    # =========================================================================
.Lsbi_base:
    beqz a6, .Lbase_spec_ver
    li t0, 1
    beq a6, t0, .Lbase_impl_id
    li t0, 2
    beq a6, t0, .Lbase_impl_ver
    li t0, 3
    beq a6, t0, .Lbase_probe
    li t0, 4
    beq a6, t0, .Lbase_mvendorid
    li t0, 5
    beq a6, t0, .Lbase_marchid
    li t0, 6
    beq a6, t0, .Lbase_mimpid
    j .Lsbi_notsup

.Lbase_spec_ver:
    li a0, 0
    li a1, 0x02000000       # SBI v2.0
    j .Lsbi_exit

.Lbase_impl_id:
    li a0, 0
    li a1, 0xF00501         # Fursoy Implementation ID
    j .Lsbi_exit

.Lbase_impl_ver:
    li a0, 0
    li a1, 1                # Version 1
    j .Lsbi_exit

.Lbase_probe:
    li t0, 0x10             # Base
    beq a0, t0, 1f
    li t0, 0x54494D45       # TIME
    beq a0, t0, 1f
    li t0, 0x4442434E       # DBCN
    beq a0, t0, 1f
    li t0, 0x53525354       # SRST
    beq a0, t0, 1f
    li a0, 0
    li a1, 0                # Extension unavailable
    j .Lsbi_exit
1:
    li a0, 0
    li a1, 1                # Extension available
    j .Lsbi_exit

.Lbase_mvendorid:
.Lbase_marchid:
.Lbase_mimpid:
    li a0, 0
    li a1, 0
    j .Lsbi_exit

    # =========================================================================
    # SBI DBCN Extension (EID 0x4442434E)
    # =========================================================================
.Lsbi_dbcn:
    li t0, 2
    beq a6, t0, .Ldbcn_write_byte
    beqz a6, .Ldbcn_write_buffer
    li t0, 1
    beq a6, t0, .Ldbcn_read_buffer
    j .Lsbi_notsup

.Ldbcn_write_byte:
    li t0, 0x10000000
    andi a0, a0, 0xff
    sw a0, 0(t0)
    li a0, 0
    li a1, 0
    j .Lsbi_exit

.Ldbcn_write_buffer:
    # a0 = num_bytes, a1 = base_addr_lo, a2 = base_addr_hi
    beqz a0, .Ldbcn_write_zero
    beqz a2, 1f
    slli a2, a2, 32
    slli a1, a1, 32
    srli a1, a1, 32
    or   a1, a2, a1
1:
    # Validate buffer range 0x8020_0000 .. 0x9000_0000
    li t0, 0x80200000
    bltu a1, t0, .Lsbi_inval
    li t0, 0x90000000
    bgeu a1, t0, .Lsbi_inval
    add t1, a1, a0
    bltu t1, a1, .Lsbi_inval
    bgtu t1, t0, .Lsbi_inval

    # Stream bytes to UART at 0x1000_0000
    li t0, 0x10000000
    mv t1, a1
    mv t2, a0
2:  lbu t3, 0(t1)
    addi t1, t1, 1
    addi t2, t2, -1
    sw  t3, 0(t0)
    bnez t2, 2b

    mv a1, a0               # value = bytes written
    li a0, 0                # error = SBI_SUCCESS
    j .Lsbi_exit

.Ldbcn_write_zero:
    li a0, 0
    li a1, 0
    j .Lsbi_exit

.Ldbcn_read_buffer:
    li a0, 0
    li a1, 0
    j .Lsbi_exit

    # =========================================================================
    # SBI TIME Extension (EID 0x54494D45)
    # =========================================================================
.Lsbi_time:
    bnez a6, .Lsbi_notsup
    # Clear virtual STIP in mip (bit 5)
    li t0, (1 << 5)
    csrc mip, t0

    # If deadline >= 0x7FFFFFFFFFFFFFFF, disable timer interrupt
    li t0, 0x7FFFFFFFFFFFFFFF
    bgeu a0, t0, 2f
    # Set CLINT mtimecmp (0x02004000)
    li t1, 0x02004000
    sd a0, 0(t1)
    # Enable MTIE in mie (bit 7)
    li t0, (1 << 7)
    csrs mie, t0
    li a0, 0
    li a1, 0
    j .Lsbi_exit

2:  # Disable timer
    li t0, (1 << 7)
    csrc mie, t0
    li t1, 0x02004000
    li t0, -1
    sd t0, 0(t1)
    li a0, 0
    li a1, 0
    j .Lsbi_exit

    # =========================================================================
    # SBI SRST Extension (EID 0x53525354)
    # =========================================================================
.Lsbi_srst:
    bnez a6, .Lsbi_notsup
    beqz a0, .Lsrst_shutdown
    j .Lsbi_notsup

.Lsrst_shutdown:
    j halt_loop

    # =========================================================================
    # Error Returns & Exit Path
    # =========================================================================
.Lsbi_notsup:
    li a0, -2               # SBI_ERR_NOT_SUPPORTED
    li a1, 0
    j .Lsbi_exit

.Lsbi_inval:
    li a0, -3               # SBI_ERR_INVALID_PARAM
    li a1, 0
    j .Lsbi_exit

.Lsbi_exit:
    # Advance mepc past ecall instruction (+4)
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0

    # Enforce mstatus.MPP = 2'b01 (S-mode) and mstatus.MPIE = 1 cleanly
    csrr t0, mstatus
    li t1, ~(3 << 11)
    and t0, t0, t1
    li t1, (1 << 11) | (1 << 7)
    or t0, t0, t1
    csrw mstatus, t0

    # Return to S-mode immediately
    mret
    .rept 16
    nop
    .endr

    # =========================================================================
    # Interrupt and Non-ECALL Trap Handlers
    # =========================================================================
.Lhandle_interrupt:
    # t0 holds mcause. Check if it is Machine Timer Interrupt (mcause 0x8000_0000_0000_0007).
    # Since bit 63 is set, shifting left by 1 clears bit 63 and leaves cause * 2:
    slli t0, t0, 1
    addi t0, t0, -14        # 7 << 1 = 14
    bnez t0, .Lunexpected_m_trap

handle_timer_irq:
    # 1. Mask MTIE in mie (bit 7) to clear pending machine timer interrupt
    li t0, (1 << 7)
    csrc mie, t0
    # 2. Assert virtual STIP in mip (bit 5) so S-mode receives delegated timer interrupt
    li t0, (1 << 5)
    csrs mip, t0
    csrr t0, mscratch       # Restore original S-mode t0 cleanly from mscratch
    # Return to S-mode immediately (zero registers clobbered, zero memory traffic)
    mret
    .rept 16
    nop
    .endr

.Lunexpected_m_trap:
    la sp, __stack_top
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call sbi_panic
