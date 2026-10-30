/* Fursoy Slice-1 Minimal SBI Firmware Entry & Platform Initialization.
 * Reset PC: 0x8000_0000 (M-mode, Hart 0).
 * Specification authority: docs/architecture/slice1-m9-soc-linux-v1.md v1.1 §6.2
 */
    .option norvc
    .option norelax
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # 1. Establish valid M-mode stack inside firmware RAM
    la sp, __stack_top

    # Store M-mode stack pointer in mscratch for trap handling
    csrw mscratch, sp

    # 2. Disable machine interrupts during boot
    csrw mie, zero
    csrci mstatus, 8       # Clear MIE

    # 3. Install M-mode trap vector (Direct mode)
    la t0, fursoy_s1_sbi_trap_entry
    csrw mtvec, t0

    # 4. Clear BSS
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:

    # 5. Enable Floating-Point (FS=Initial) and Vector (VS=Initial) in mstatus
    # FS: bits [14:13] = 2'b01 -> 1 << 13 = 0x2000
    # VS: bits [10:9]  = 2'b01 -> 1 << 9  = 0x0200
    li t0, (1 << 13) | (1 << 9)
    csrs mstatus, t0

    # 6. Program Exception & Interrupt Delegation
    # medeleg: bitmask 0xB1FF (causes 0..8, 12, 13, 15; cause 9 S-ECALL undelegated)
    li t0, 0xB1FF
    csrw medeleg, t0

    # mideleg: bitmask 0x0222 (SSIP bit 1, STIP bit 5, SEIP bit 9; MSIP, MTIP, MEIP M-owned)
    li t0, 0x0222
    csrw mideleg, t0

    # 7. Physical Memory Protection (PMP): Slice-1 core hardwires pmp_allow_i=1'b1,
    # granting full S/U access to platform DRAM and peripherals without PMP CSR traps.

    # 8. Initialize Timer State
    # CLINT mtimecmp resets to all-ones in hardware (fursoy_s0_clint.sv).
    # Clear virtual STIP in mip (bit 5 = 0x20)
    li t0, (1 << 5)
    csrc mip, t0

    # 9. S-mode CSR Hygiene & Counter Enable (cycle, time, instret = 0x7)
    li t0, 7
    csrw mcounteren, t0
    csrw scounteren, t0
    csrw satp, zero
    csrw sie, zero
    csrw sstatus, zero

    # 10. Linux Kernel Handoff Preparation (§6.2, PROP_M9_22)
    # mepc = 0x8020_0000
    li t0, 0x80200000
    csrw mepc, t0

    # Set mstatus.MPP = 2'b01 (S-mode, bit 11) and mstatus.MPIE = 1 (bit 7)
    li t0, (3 << 11)
    csrc mstatus, t0
    li t0, (1 << 11) | (1 << 7)
    csrs mstatus, t0

    # Canonical Linux boot arguments:
    # a0 = 0 (Hart 0)
    # a1 = 0x8200_0000 (Physical address of DTB)
    li a0, 0
    li a1, 0x82000000

    # GPR Hygiene: zero all other general purpose registers
    li ra, 0
    li sp, 0
    li gp, 0
    li tp, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li s0, 0
    li s1, 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    li s2, 0
    li s3, 0
    li s4, 0
    li s5, 0
    li s6, 0
    li s7, 0
    li s8, 0
    li s9, 0
    li s10, 0
    li s11, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0

    # 11. Execute mret into S-mode kernel entry point
    mret
    .rept 16
    nop
    .endr
