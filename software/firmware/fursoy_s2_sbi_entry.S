#include "fursoy_s2_sbi.h"

    .section .text.init
    .globl _start
    .globl _sbi_secondary_park

_start:
    /* Preserve boot args in callee-saved regs: s0=hartid, s1=dtb_addr */
    csrr    s0, mhartid
    mv      s1, a1

    /* Disable interrupts and configure per-hart M-mode stack */
    csrci   mstatus, 0x8        /* Clear mstatus.MIE */
    csrw    mie, zero
    csrw    mip, zero

    /* sp_h = _sbi_stack_base + (hartid + 1) * 4096 */
    la      sp, _sbi_stack_base
    addi    t0, s0, 1
    slli    t0, t0, 12
    add     sp, sp, t0
    csrw    mscratch, sp        /* Keep per-hart M-mode stack top in mscratch */

    /* Clear FPU/VPU clean initial state: FS=01 (bit 13), VS=01 (bit 9) */
    li      t0, (1 << 13) | (1 << 9)
    csrs    mstatus, t0

    /* Install per-hart trap handler */
    la      t0, _sbi_mtrap_entry
    csrw    mtvec, t0

    /* Delegate standard synchronous traps & S-mode IRQs */
    li      t0, 0xB1FF          /* inst_misaligned..store/amo/ecall-u/pagefaults */
    csrw    medeleg, t0
    li      t0, 0x0222          /* SSIP (1<<1), STIP (1<<5), SEIP (1<<9) */
    csrw    mideleg, t0

    /* Allow S-mode and U-mode counters (CY, TM, IR) on all harts (0..N-1) */
    li      t0, 0x7
    csrw    mcounteren, t0
    csrw    scounteren, t0

    /* Enable M-mode software interrupt (MSIE, bit 3) */
    li      t0, (1 << 3)
    csrw    mie, t0

    /* BSP (hart 0) zeroes BSS and initializes SBI state; secondaries wait on boot flag */
    bnez    s0, .Lsecondary_wait_bss

    la      t0, __bss_start
    la      t1, __bss_end
.Lbss_loop:
    bgeu    t0, t1, .Lbss_done
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       .Lbss_loop
.Lbss_done:
    fence   rw, rw

    li      a0, FURSOY_NUM_HARTS
    bnez    s1, 1f
    li      s1, DTB_DEFAULT_ADDR
1:
    mv      a1, s1
    call    sbi_init_bsp

    fence   rw, rw
    la      t0, _sbi_boot_ready
    li      t1, 1
    sd      t1, 0(t0)
    fence   w, rw

    /* Enter S-mode payload at SMODE_ENTRY_ADDR (0x80200000): a0 = 0, a1 = dtb */
    li      t0, (1 << 11) | (1 << 13) | (1 << 9) /* MPP=01 (S), FS=01, VS=01, MIE=0 */
    li      t1, (3 << 11) | (1 << 3)             /* Clear MPP & MIE */
    csrc    mstatus, t1
    csrs    mstatus, t0

    li      t0, SMODE_ENTRY_ADDR
    csrw    mepc, t0
    mv      a0, s0
    mv      a1, s1
    mret

.Lsecondary_wait_bss:
    la      t0, _sbi_boot_ready
.Lwait_ready_loop:
    ld      t1, 0(t0)
    fence   r, r
    bnez    t1, _sbi_secondary_park
    j       .Lwait_ready_loop

_sbi_secondary_park:
    /* Re-arm per-hart M-mode stack and wait in WFI until SBI_HSM_HART_START */
    csrr    s0, mhartid
    csrr    sp, mscratch
    csrci   mstatus, 0x8        /* mstatus.MIE = 0 so WFI resumes inline on MSIP */
    li      t0, (1 << 3)
    csrw    mie, t0

.Lhsm_park_loop:
    mv      a0, s0
    addi    a1, sp, -16         /* &out_start_addr */
    addi    a2, sp, -8          /* &out_opaque */
    addi    sp, sp, -16
    call    sbi_secondary_wait_start
    mv      t2, a0              /* 1 = ready to boot, 0 = still STOPPED */
    ld      t3, 0(sp)           /* out_start_addr */
    ld      t4, 8(sp)           /* out_opaque */
    addi    sp, sp, 16
    bnez    t2, .Lsecondary_launch
    wfi
    j       .Lhsm_park_loop

.Lsecondary_launch:
    /* Synchronize instruction & page-table caches and ensure U/S counters enabled */
    fence.i
    sfence.vma zero, zero
    li      t0, 0x7
    csrw    mcounteren, t0
    csrw    scounteren, t0

    /* Switch to S-mode at t3 (start_addr) with a0=hartid, a1=opaque */
    li      t0, (3 << 11) | (1 << 3)
    csrc    mstatus, t0
    li      t0, (1 << 11) | (1 << 13) | (1 << 9)
    csrs    mstatus, t0
    csrw    mepc, t3
    mv      a0, s0
    mv      a1, t4
    mret

    .section .data
    .align 6
_sbi_boot_ready:
    .dword  0
