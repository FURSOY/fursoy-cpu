# =============================================================================
# Fursoy Slice-2 Directed P0-1 Stress Test: Uncached MMIO vs High-Freq MSIP IRQ
# =============================================================================
# Hart 0 (S-mode, sstatus.SIE=0):
#   Phase 1: Transmits 128 deterministic bytes to UART THR (0x1000_0000) under
#            relentless M-mode MSIP bombardment from Hart 1 (varying spacing).
#   Phase 2: Executes 128 PLIC Claim/Complete cycles on Context 1 (0x0C20_1004)
#            for level-high Source 2 under relentless M-mode MSIP bombardment.
#            Verifies every Claim == 2, then signals TB via 0x04 (EOT) to drop
#            Source 2, verifies 128th Complete cleared in_service[2] (drain==2)
#            and PLIC returns idle (idle==0) with zero leaked in_service bits.
# Hart 1 (M-mode):
#   Relentlessly asserts CLINT msip[0] (0x0200_0000) with LFSR-varied spacing
#   (5..20 loops) so M-mode MSIPs sweep across every cycle of Hart 0's MMIO
#   IDLE -> REQ -> WAIT_RSP -> COMP -> RETIRE pipeline.
# =============================================================================

.section .text.init
.globl _start

.equ CLINT_BASE,      0x02000000
.equ PLIC_PRIO2,      0x0C000008
.equ PLIC_EN_CTX1,    0x0C002080
.equ PLIC_THR_CTX1,   0x0C201000
.equ PLIC_CLAIM_CTX1, 0x0C201004
.equ UART_THR,        0x10000000

.equ MBOX_BASE,       0x80280000
.equ OFF_START,       0x000
.equ OFF_H0_DONE,     0x040
.equ OFF_H1_DONE,     0x080
.equ OFF_IPI_CNT,     0x0C0
.equ OFF_BAD_TRAP,    0x100
.equ OFF_CLAIM_CNT,   0x140
.equ OFF_BAD_CLAIM,   0x180
.equ OFF_DRAIN_ID,    0x1C0
.equ OFF_IDLE_ID,     0x200

.equ MSTACK_H0,       0x80090000
.equ SSTACK_H0,       0x80294000
.equ MSTACK_H1,       0x80098000

_start:
    csrr    t0, mhartid
    bnez    t0, hart1_entry

# =============================================================================
# Hart 0 M-mode Initialization
# =============================================================================
hart0_init:
    li      sp, MSTACK_H0
    csrw    mscratch, sp

    # Zero shared mailbox lines
    li      t0, MBOX_BASE
    li      t1, 16
1:
    sd      zero, 0(t0)
    addi    t0, t0, 64
    addi    t1, t1, -1
    bnez    t1, 1b
    fence   rw, rw

    # Install M-mode trap handler (Direct mode)
    la      t0, h0_m_trap_handler
    csrw    mtvec, t0

    # Delegate nothing so MSIP always traps to M-mode regardless of sstatus.SIE
    csrw    medeleg, zero
    csrw    mideleg, zero

    # Configure PLIC Source 2 -> Context 1 (Hart 0 S-mode), initially disabled during Phase 1
    li      t0, PLIC_PRIO2
    li      t1, 7
    sw      t1, 0(t0)
    li      t0, PLIC_EN_CTX1
    sw      zero, 0(t0)
    li      t0, PLIC_THR_CTX1
    sw      zero, 0(t0)

    # Clear any pending MSIP[0] and enable M-mode MSIE (bit 3)
    li      t0, CLINT_BASE
    sw      zero, 0(t0)
    li      t0, (1 << 3)
    csrw    mie, t0

    # Prepare S-mode return: MPP=01 (S-mode), MPIE=1, SIE=0
    li      t0, (1 << 11) | (1 << 7)
    csrw    mstatus, t0
    csrw    satp, zero
    csrw    sie, zero
    la      t0, h0_s_worker
    csrw    mepc, t0
    fence   rw, rw

    # Release Hart 1 bombardier
    li      t0, MBOX_BASE
    li      t1, 1
    sd      t1, OFF_START(t0)
    fence   rw, rw

    li      sp, SSTACK_H0
    mret

# =============================================================================
# Hart 0 M-mode Trap Handler (Preserves ALL S-mode Registers!)
# =============================================================================
.align 4
h0_m_trap_handler:
    csrrw   sp, mscratch, sp
    addi    sp, sp, -48
    sd      t0,  0(sp)
    sd      t1,  8(sp)
    sd      t2, 16(sp)
    sd      t3, 24(sp)

    csrr    t0, mcause
    li      t1, 0x8000000000000003   # Machine Software Interrupt (MSIP)
    bne     t0, t1, h0_unexpected_trap

    # Clear CLINT msip[0]
    li      t0, CLINT_BASE
    sw      zero, 0(t0)

    # Increment ipi_count
    li      t0, MBOX_BASE
    ld      t1, OFF_IPI_CNT(t0)
    addi    t1, t1, 1
    sd      t1, OFF_IPI_CNT(t0)

    ld      t0,  0(sp)
    ld      t1,  8(sp)
    ld      t2, 16(sp)
    ld      t3, 24(sp)
    addi    sp, sp, 48
    csrrw   sp, mscratch, sp
    mret

h0_unexpected_trap:
    li      t2, MBOX_BASE
    sd      t0, OFF_BAD_TRAP(t2)
    fence   rw, rw
1:  j       1b

# =============================================================================
# Hart 0 S-mode Stress Worker (placed at 0x8020_0000 outside M-only SBI RAM)
# =============================================================================
.section .smode, "ax"
.align 4
h0_s_worker:
    # -------------------------------------------------------------------------
    # Phase 1: 128 deterministic UART THR stores under relentless MSIP IRQ
    # -------------------------------------------------------------------------
    li      s0, UART_THR
    li      s1, 0            # i = 0..127
    li      s2, 128
p1_loop:
    andi    t0, s1, 63
    addi    t0, t0, 0x30     # deterministic printable ASCII 0x30..0x6F
    sw      t0, 0(s0)        # UNCACHED MMIO STORE -> UART THR
    # Vary spacing (0..3 iterations) to hit back-to-back & spaced MMIO windows
    andi    t1, s1, 3
p1_pad:
    beqz    t1, p1_next
    addi    t1, t1, -1
    j       p1_pad
p1_next:
    addi    s1, s1, 1
    blt     s1, s2, p1_loop

    # -------------------------------------------------------------------------
    # Phase 2: 128 PLIC Claim/Complete cycles under relentless MSIP IRQ
    # -------------------------------------------------------------------------
    li      s0, PLIC_EN_CTX1
    li      t0, (1 << 2)
    sw      t0, 0(s0)        # Enable Source 2 on Context 1 (Hart 0 S-mode)

    li      s0, PLIC_CLAIM_CTX1
    li      s1, 0            # claim_count
    li      s2, 128
    li      s3, 0            # bad_claim_count
    li      s4, 2            # expected PLIC source ID = 2
p2_loop:
    lw      t0, 0(s0)        # UNCACHED MMIO LOAD -> PLIC Claim (side-effect!)
    beq     t0, s4, p2_ok
    addi    s3, s3, 1
    beqz    t0, p2_next      # Do not complete ID 0
p2_ok:
    sw      t0, 0(s0)        # UNCACHED MMIO STORE -> PLIC Complete
p2_next:
    addi    s1, s1, 1
    blt     s1, s2, p2_loop

    # Signal TB via 0x04 (EOT) on UART to deassert irq_sources_i[2]
    li      t0, UART_THR
    li      t1, 0x04
    sw      t1, 0(t0)

    # Wait 128 iterations for TB to drop irq_sources_i[2]
    li      t1, 128
p2_wait_drop:
    addi    t1, t1, -1
    bnez    t1, p2_wait_drop

    # Drain the single re-pended Source 2 from the 128th Complete:
    # MUST return 2 (proves 128th Complete cleared in_service[2] cleanly!).
    lw      s5, 0(s0)        # s5 = drain_id (must be 2)
    beqz    s5, p2_skip_drain_complete
    sw      s5, 0(s0)        # Complete with irq_sources_i == 0 -> must go IDLE
p2_skip_drain_complete:
    # Final idle check: MUST return 0 (proves zero leaked pending/in_service)
    lw      s6, 0(s0)        # s6 = idle_id (must be 0)

    # Record Phase 2 stats in mailbox and stop Hart 1 bombardier
    li      t0, MBOX_BASE
    sd      s1, OFF_CLAIM_CNT(t0)
    sd      s3, OFF_BAD_CLAIM(t0)
    sd      s5, OFF_DRAIN_ID(t0)
    sd      s6, OFF_IDLE_ID(t0)
    li      t1, 1
    sd      t1, OFF_H0_DONE(t0)
    fence   rw, rw

    # Wait for Hart 1 to stop bombarding so final summary line prints cleanly
wait_h1_stop:
    ld      t1, OFF_H1_DONE(t0)
    beqz    t1, wait_h1_stop
    fence   rw, rw

    # Emit 0x06 (ACK) then structured summary line
    li      a0, 0x06
    jal     ra, uart_putc
    la      a0, msg_hdr
    jal     ra, uart_puts
    li      t0, MBOX_BASE
    ld      a0, OFF_IPI_CNT(t0)
    jal     ra, uart_puthex
    la      a0, msg_claims
    jal     ra, uart_puts
    li      t0, MBOX_BASE
    ld      a0, OFF_CLAIM_CNT(t0)
    jal     ra, uart_puthex
    la      a0, msg_bad
    jal     ra, uart_puts
    li      t0, MBOX_BASE
    ld      a0, OFF_BAD_CLAIM(t0)
    jal     ra, uart_puthex
    la      a0, msg_drain
    jal     ra, uart_puts
    li      t0, MBOX_BASE
    ld      a0, OFF_DRAIN_ID(t0)
    jal     ra, uart_puthex
    la      a0, msg_idle
    jal     ra, uart_puts
    li      t0, MBOX_BASE
    ld      a0, OFF_IDLE_ID(t0)
    jal     ra, uart_puthex
    la      a0, msg_badtrap
    jal     ra, uart_puts
    li      t0, MBOX_BASE
    ld      a0, OFF_BAD_TRAP(t0)
    jal     ra, uart_puthex
    li      a0, 0x0A
    jal     ra, uart_putc

h0_park:
    j       h0_park

# =============================================================================
# Hart 1 M-mode High-Frequency MSIP Bombardier
# =============================================================================
.section .text.init
.align 4
hart1_entry:
    li      sp, MSTACK_H1
    li      s0, MBOX_BASE
    li      s1, CLINT_BASE
    li      s2, 0x5A          # 8-bit Galois LFSR seed for varying IRQ spacing

h1_wait_start:
    ld      t0, OFF_START(s0)
    beqz    t0, h1_wait_start

h1_bombard:
    ld      t0, OFF_H0_DONE(s0)
    bnez    t0, h1_finish

    # Assert CLINT msip[0] = 1
    li      t1, 1
    sw      t1, 0(s1)

    # Advance 8-bit LFSR (poly x^8 + x^6 + x^5 + x^4 + 1) -> delay 4..19 iters
    andi    t2, s2, 1
    srli    s2, s2, 1
    beqz    t2, 1f
    xori    s2, s2, 0xB8
1:
    andi    t3, s2, 15
    addi    t3, t3, 4
h1_delay:
    addi    t3, t3, -1
    bnez    t3, h1_delay
    j       h1_bombard

h1_finish:
    li      t1, 1
    sd      t1, OFF_H1_DONE(s0)
    fence   rw, rw
h1_park:
    j       h1_park

# =============================================================================
# Minimal UART Helpers (S-mode, in .smode @ 0x8020_0000+)
# =============================================================================
.section .smode, "ax"
uart_putc:
    li      t0, UART_THR
    sw      a0, 0(t0)
    ret

uart_puts:
    mv      t2, a0
1:
    lbu     a0, 0(t2)
    beqz    a0, 2f
    li      t0, UART_THR
    sw      a0, 0(t0)
    addi    t2, t2, 1
    j       1b
2:
    ret

uart_puthex:
    mv      t2, a0
    li      t3, 60
1:
    srl     t4, t2, t3
    andi    t4, t4, 0xF
    li      t5, 10
    blt     t4, t5, 2f
    addi    t4, t4, ('a' - 10)
    j       3f
2:
    addi    t4, t4, '0'
3:
    li      t0, UART_THR
    sw      t4, 0(t0)
    addi    t3, t3, -4
    bgez    t3, 1b
    ret

.section .smode, "ax"
.align 3
msg_hdr:     .asciz "[MMIO_IRQ_STRESS] ipi="
msg_claims:  .asciz " claims="
msg_bad:     .asciz " bad="
msg_drain:   .asciz " drain="
msg_idle:    .asciz " idle="
msg_badtrap: .asciz " badtrap="
