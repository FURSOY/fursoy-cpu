/* Fursoy Slice-0 Minimal SBI Firmware Entry & Initialization.
 * Reset PC: 0x8000_0000 (M-mode, Hart 0).
 */
    .option norvc
    .option norelax
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # 1. Establish valid firmware stack inside firmware RAM
    la sp, __stack_top

    # Store M-mode stack pointer in mscratch for trap handling
    csrw mscratch, sp

    # 2. Disable machine interrupts
    csrw mie, zero
    csrci mstatus, 8       # Clear MIE

    # 3. Install M-mode trap vector (Direct mode)
    la t0, sbi_trap_entry
    csrw mtvec, t0

    # 4. Clear BSS
    la t0, __bss_start
    la t1, __bss_end
1:  bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:

    # 5. Program Delegation
    # medeleg: bitmask 0xB1FF (causes 0..8, 12, 13, 15; cause 9 S-ECALL undelegated)
    li t0, 0xB1FF
    csrw medeleg, t0

    # mideleg: bitmask 0x0222 (SSIP bit 1, STIP bit 5, SEIP bit 9; MSIP, MTIP, MEIP M-owned)
    li t0, 0x0222
    csrw mideleg, t0

    # 6. Program PMP (Frozen Platform v1 NAPOT layout)
    # Entry 0: 0x8000_0000, 2 MiB (NAPOT) -> pmpaddr0 = 0x2003_FFFF
    li t0, 0x2003FFFF
    csrw pmpaddr0, t0

    # Entry 1: 0x8000_0000, 256 MiB (NAPOT) -> pmpaddr1 = 0x21FF_FFFF
    li t0, 0x21FFFFFF
    csrw pmpaddr1, t0

    # Entry 2: 0x0C00_0000, 4 MiB (NAPOT) -> pmpaddr2 = 0x0307_FFFF
    li t0, 0x0307FFFF
    csrw pmpaddr2, t0

    # Entry 3: 0x1000_0000, 4 KiB (NAPOT) -> pmpaddr3 = 0x0400_01FF
    li t0, 0x040001FF
    csrw pmpaddr3, t0

    # Entries 4..15: OFF
    csrw pmpaddr4, zero
    csrw pmpaddr5, zero
    csrw pmpaddr6, zero
    csrw pmpaddr7, zero
    csrw pmpaddr8, zero
    csrw pmpaddr9, zero
    csrw pmpaddr10, zero
    csrw pmpaddr11, zero
    csrw pmpaddr12, zero
    csrw pmpaddr13, zero
    csrw pmpaddr14, zero
    csrw pmpaddr15, zero

    # pmpcfg0: Entry 0=0x18, Entry 1=0x1F, Entry 2=0x1B, Entry 3=0x1B, Entries 4..7=0x00
    # packed value = 0x1B1B1F18
    li t0, 0x1B1B1F18
    csrw pmpcfg0, t0
    csrw pmpcfg2, zero

    # 7. Initialize Timer State
    # Write -1 to CLINT mtimecmp at 0x0200_4000
    li t0, 0x02004000
    li t1, -1
    sd t1, 0(t0)
    # Clear virtual STIP in mip (bit 5 = 0x20)
    li t0, (1 << 5)
    csrc mip, t0

    # 8. S-mode CSR Hygiene & Counter Enable (cycle, time, instret = 0x7)
    li t0, 7
    csrw mcounteren, t0
    csrw scounteren, t0
    csrw satp, zero
    csrw sie, zero
    csrw sstatus, zero

    # 9. Linux Handoff Preparation
    # mepc = 0x8020_0000
    li t0, 0x80200000
    csrw mepc, t0

    # Set mstatus.MPP = 2'b01 (S-mode)
    # Clear MPP bits [12:11], then set bit 11
    li t0, (3 << 11)
    csrc mstatus, t0
    li t0, (1 << 11)
    csrs mstatus, t0

    # Fences before handoff
    fence rw, rw
    fence.i

    # Canonical Linux boot arguments:
    # a0 = 0 (Hart 0)
    # a1 = 0x8200_0000 (DTB pointer)
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

    # 10. Execute mret into S-mode
    mret
