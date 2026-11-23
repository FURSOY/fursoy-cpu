/* Fursoy Slice-2 Milestone S2-M1 Non-Coherent Multi-Hart Bring-Up Test
 * Compiled with -DNUM_HARTS=2 or -DNUM_HARTS=4.
 *
 * Exercises without requiring L1D cache coherence:
 *   1. Unique mhartid readback (0 .. NUM_HARTS-1) + private per-hart DRAM line.
 *   2. Cross-hart CLINT msip[h] IPI ring (explicitly odd harts h=1, 3 addr[2]==1).
 *   3. Staggered per-hart CLINT mtimecmp[h] timer interrupts.
 *   4. fursoy_s2_plic multi-context (2*h M-mode, 2*h+1 S-mode) enable, threshold,
 *      priority preemption, threshold-independent claim, and 8-round concurrent
 *      single-claim race exclusivity.
 */
    .option norvc
    .option norelax

#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

.equ CLINT_BASE,      0x02000000
.equ CLINT_MSIP_BASE, 0x02000000
.equ CLINT_CMP_BASE,  0x02004000
.equ CLINT_MTIME,     0x0200BFF8

.equ PLIC_BASE,       0x0C000000
.equ PLIC_PRIO_BASE,  0x0C000000
.equ PLIC_EN_BASE,    0x0C002000
.equ PLIC_CTX_BASE,   0x0C200000

.equ UART_THR,        0x10000000
.equ PRIV_RAM_BASE,   0x80400000

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    # s0 = mhartid (0 .. NUM_HARTS-1)
    csrr s0, mhartid
    li   t0, NUM_HARTS
    bgeu s0, t0, test_fail

    # Per-hart private stack (disjoint 16 KiB per hart in 0x8040_0000+)
    slli t1, s0, 14
    li   t2, PRIV_RAM_BASE + 0x4000
    add  sp, t2, t1

    # Initialize CSRs and install M-mode trap handler
    csrw mie, zero
    csrci mstatus, 8            # Clear mstatus.MIE
    la   t0, m_trap_entry
    csrw mtvec, t0
    li   t0, 7
    csrw mcounteren, t0
    csrw scounteren, t0

    # -------------------------------------------------------------------------
    # Test 1: Private per-hart DRAM store/load verification (non-shared line)
    # -------------------------------------------------------------------------
    li   t0, 0xCAFE0000
    or   t0, t0, s0
    sd   t0, -8(sp)
    ld   t1, -8(sp)
    bne  t0, t1, test_fail

    # Register flags across tests:
    #   s11 = MSIP IPI count received
    #   s10 = MTIP flag (1 when timer fired)
    #   s9  = S-mode PLIC nesting / status
    #   s8  = Phase 4A pass mask
    #   s7  = Phase 4B fail flag (0 = ok)
    li   s11, 0
    li   s10, 0
    li   s9,  0
    li   s8,  0
    li   s7,  0

    # Enable M-mode Software Interrupts (MSIE = bit 3) + mstatus.MIE
    li   t0, (1 << 3)
    csrs mie, t0
    csrsi mstatus, 8

    # Brief settle loop so all harts finish mtvec/mie setup before Hart 0 kicks ring
    li   t0, 64
1:  addi t0, t0, -1
    bnez t0, 1b

    # -------------------------------------------------------------------------
    # Test 2: 2-Round CLINT msip[h] IPI Ring (exercises h=0,1,2,3 incl. addr[2]==1)
    # -------------------------------------------------------------------------
    # Round 1 & Round 2:
    #   Hart 0 kicks Hart 1; each hart waits in WFI for MSIP, then kicks (h+1)%N.
    li   s1, 2                  # total rounds
    bnez s0, .Lring_wait

.Lring_kick_next:
    # Hart 0 sends MSIP to next hart (h+1)%N
    addi t0, s0, 1
    li   t1, NUM_HARTS
    remu t0, t0, t1
    slli t0, t0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    li   t2, 1
    sw   t2, 0(t1)

.Lring_wait:
    # Wait until s11 increments to current expected count
    # Expected count for hart h in iteration (2 - s1 + 1):
    # Simpler: wait in WFI while s11 < target
    li   t3, 2
    sub  t3, t3, s1
    addi t3, t3, 1              # target = 1 then 2
2:  bgeu s11, t3, 3f
    wfi
    j    2b
3:
    # Secondary harts kick (h+1)%N upon receiving MSIP
    beqz s0, 4f
    addi t0, s0, 1
    li   t1, NUM_HARTS
    remu t0, t0, t1
    slli t0, t0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    li   t2, 1
    sw   t2, 0(t1)
4:
    addi s1, s1, -1
    bnez s1, .Lring_wait_next
    j    .Lring_done
.Lring_wait_next:
    beqz s0, .Lring_kick_next
    j    .Lring_wait

.Lring_done:
    li   t0, 2
    bne  s11, t0, test_fail
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8

    # -------------------------------------------------------------------------
    # Test 3: Staggered Per-Hart CLINT mtimecmp[h] Timer Interrupts
    # -------------------------------------------------------------------------
    li   t0, CLINT_MTIME
    ld   t1, 0(t0)
    li   t2, 180
    slli t3, s0, 6              # + 64 * mhartid
    add  t2, t2, t3
    add  s2, t1, t2             # s2 = deadline

    slli t3, s0, 3
    li   t0, CLINT_CMP_BASE
    add  t0, t0, t3
    sd   s2, 0(t0)              # mtimecmp[h] = deadline

    li   s10, 0
    li   t0, (1 << 7)           # MTIE = bit 7
    csrs mie, t0

1:  bnez s10, 2f
    wfi
    j    1b
2:
    # Disable MTIE after timer fired
    li   t0, (1 << 7)
    csrc mie, t0

    # Sync barrier via daisy-chain before Test 4A
    call sync_barrier

    # -------------------------------------------------------------------------
    # Test 4A: PLIC Multi-Context (2*h M-mode & 2*h+1 S-mode), Preemption & Threshold
    # -------------------------------------------------------------------------
    # Execute sequentially per hart via token pass so UART markers & irq_sources_i
    # drive deterministic preemption per hart.
    beqz s0, .L4a_start
    # Wait for MSIP token from previous hart (MIE already enabled, s11 reset cleanly in sync_barrier)
1:  bnez s11, .L4a_start
    wfi
    j    1b

.L4a_start:
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
    # Context indices: s3 = c_m (2*h), s4 = c_s (2*h + 1)
    slli s3, s0, 1
    addi s4, s3, 1

    # Source IDs for hart h:
    #   src_lo = 2 + h  (prio 3, S-mode level 1)
    #   src_hi = 6 + h  (prio 6, S-mode preempt)
    #   src_m  = 10 + h (prio 4, M-mode threshold-independent claim)
    addi t0, s0, 2
    slli t0, t0, 2
    li   t1, PLIC_PRIO_BASE
    add  t1, t1, t0
    li   t2, 3
    sw   t2, 0(t1)              # prio[2+h] = 3

    addi t0, s0, 6
    slli t0, t0, 2
    li   t1, PLIC_PRIO_BASE
    add  t1, t1, t0
    li   t2, 6
    sw   t2, 0(t1)              # prio[6+h] = 6

    addi t0, s0, 10
    slli t0, t0, 2
    li   t1, PLIC_PRIO_BASE
    add  t1, t1, t0
    li   t2, 4
    sw   t2, 0(t1)              # prio[10+h] = 4

    # Enable (2+h) and (6+h) on S-mode context c_s = 2*h + 1
    li   t0, 1
    addi t1, s0, 2
    sll  t2, t0, t1
    addi t1, s0, 6
    sll  t3, t0, t1
    or   t2, t2, t3
    li   t0, 0x80
    mul  t1, s4, t0
    li   t0, PLIC_EN_BASE
    add  t0, t0, t1
    sw   t2, 0(t0)

    # Set S-mode context threshold = 1 (3 > 1 and 6 > 1)
    slli t1, s4, 12
    li   t0, PLIC_CTX_BASE
    add  t0, t0, t1
    li   t2, 1
    sw   t2, 0(t0)              # threshold[c_s] = 1

    # Delegate S-mode interrupts (SEIP bit 9, STIP bit 5, SSIP bit 1)
    li   t0, 0x0222
    csrw mideleg, t0
    la   t0, s_trap_entry
    csrw stvec, t0
    li   t0, (1 << 9)           # sie.SEIE = bit 9
    csrs sie, t0

    # Print "[4A_S<h>]\n" so TB asserts Source (2+h)
    la   a0, msg_4a_s
    call uart_puts_tag_hart

    # Enter S-mode via mret (MPP = 01, MPIE = 1)
    li   s9, 0
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11) | (1 << 7)
    csrs mstatus, t0
    la   t0, .L4a_smode_entry
    csrw mepc, t0
    mret

.L4a_smode_entry:
    # Wait for both Level-1 (2+h) and Level-2 preempt (6+h) to complete (s9 == 2)
    csrsi sstatus, 2            # Enable sstatus.SIE
1:  li   t0, 2
    beq  s9, t0, 2f
    wfi
    j    1b
2:
    # Return to M-mode via S-ECALL
    ecall

.L4a_back_in_mmode:
    # Clean up S-mode context enable
    li   t0, 0x80
    mul  t1, s4, t0
    li   t0, PLIC_EN_BASE
    add  t0, t0, t1
    sw   zero, 0(t0)
    csrw sie, zero

    # Print "[4A_D<h>]\n" so TB clears S-mode sources (2+h, 6+h)
    la   a0, msg_4a_d
    call uart_puts_tag_hart

    # M-mode context c_m = 2*h: threshold-independent claim test
    li   t0, 1
    addi t1, s0, 10
    sll  t2, t0, t1
    li   t0, 0x80
    mul  t1, s3, t0
    li   t0, PLIC_EN_BASE
    add  t0, t0, t1
    sw   t2, 0(t0)              # enable[c_m] = 1 << (10+h)

    slli t1, s3, 12
    li   t0, PLIC_CTX_BASE
    add  t5, t0, t1             # t5 = ctx base for c_m
    li   t2, 4
    sw   t2, 0(t5)              # threshold[c_m] = 4 (masks prio 4!)

    # Print "[4A_M<h>]\n" so TB asserts Source (10+h)
    la   a0, msg_4a_m
    call uart_puts_tag_hart

    # Poll until PLIC pending bit (10+h) becomes visible, then verify MEIP masked
    li   t0, PLIC_BASE + 0x1000
    li   t1, 1
    addi t2, s0, 10
    sll  t1, t1, t2
1:  lw   t3, 0(t0)
    and  t3, t3, t1
    beqz t3, 1b

    # Verify mip.MEIP (bit 11) == 0 because threshold == 4 == priority
    csrr t3, mip
    li   t4, (1 << 11)
    and  t3, t3, t4
    bnez t3, test_fail

    # Claim[c_m] MUST STILL return (10+h) despite threshold == 4
    lw   t3, 4(t5)
    addi t4, s0, 10
    bne  t3, t4, test_fail

    # Complete (10+h), clear enable & threshold
    sw   t3, 4(t5)
    sw   zero, 0(t5)
    li   t0, 0x80
    mul  t1, s3, t0
    li   t0, PLIC_EN_BASE
    add  t0, t0, t1
    sw   zero, 0(t0)

    # Print "[4A_OK<h>]\n" so TB clears Source (10+h)
    la   a0, msg_4a_ok
    call uart_puts_tag_hart

    # Pass token to next hart (h+1)%N (prepare Hart 0 s11=0 with MIE=0 before kicking!)
    csrci mstatus, 8
    li   s11, 0
    addi t0, s0, 1
    li   t1, NUM_HARTS
    remu t0, t0, t1
    slli t0, t0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    li   t2, 1
    sw   t2, 0(t1)
    csrsi mstatus, 8

    # Hart 0 waits for token back from Hart N-1
    bnez s0, .L4b_setup
1:  bnez s11, .L4b_setup
    wfi
    j    1b

    # -------------------------------------------------------------------------
    # Test 4B: Concurrent Hart Race Single-Claim Exclusivity (8 rounds on Src 14)
    # -------------------------------------------------------------------------
.L4b_setup:
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
    bnez s0, .L4b_loop_entry
    # Hart 0 sets Source 14 prio = 5 and enables Source 14 on all M-mode contexts
    li   t0, PLIC_PRIO_BASE + (14 * 4)
    li   t1, 5
    sw   t1, 0(t0)
    li   t2, (1 << 14)
    li   t3, 0
1:  li   t4, NUM_HARTS
    bgeu t3, t4, 2f
    slli t5, t3, 1              # c_m = 2*t3
    li   t6, 0x80
    mul  t6, t5, t6
    li   t0, PLIC_EN_BASE
    add  t0, t0, t6
    sw   t2, 0(t0)
    slli t6, t5, 12
    li   t0, PLIC_CTX_BASE
    add  t0, t0, t6
    sw   zero, 0(t0)            # threshold = 0
    addi t3, t3, 1
    j    1b
2:

.L4b_loop_entry:
    li   s5, 0                  # round r = 0..7
.L4b_round:
    li   t0, 8
    bgeu s5, t0, .L4b_done

    # Barrier so all harts enter round r together; Hart 0 prints [4B_R<r>] and kicks all
    bnez s0, .L4b_wait_start
    la   a0, msg_4b_r
    mv   a1, s5
    call uart_puts_tag_val

    # Give TB a moment to raise irq_sources_i[14] after observing [4B_R<r>]
    # Poll PLIC pending[14] before broadcasting start!
    li   t0, PLIC_BASE + 0x1000
    li   t1, (1 << 14)
1:  lw   t2, 0(t0)
    and  t2, t2, t1
    beqz t2, 1b

    # Broadcast MSIP to all secondary harts simultaneously
    li   t3, 1
2:  li   t4, NUM_HARTS
    bgeu t3, t4, .L4b_race
    slli t5, t3, 2
    li   t0, CLINT_MSIP_BASE
    add  t0, t0, t5
    li   t6, 1
    sw   t6, 0(t0)
    addi t3, t3, 1
    j    2b

.L4b_wait_start:
1:  bnez s11, .L4b_race
    wfi
    j    1b

.L4b_race:
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
    # All N harts race to read claim[2*h]
    slli t0, s0, 1              # c_m = 2*h
    slli t0, t0, 12
    li   t1, PLIC_CTX_BASE
    add  t1, t1, t0
    lw   s6, 4(t1)              # s6 = claimed ID (must be 14 or 0)

    beqz s6, .L4b_check_done
    li   t2, 14
    bne  s6, t2, .L4b_bad_claim
    # Winner completes Source 14
    sw   s6, 4(t1)
    j    .L4b_check_done
.L4b_bad_claim:
    li   s7, 1
.L4b_check_done:
    # Sequentially print "[4B_C<h>=<id>]\n" via daisy chain so TB verifies exactly 1 winner
    beqz s0, .L4b_print_claim
1:  bnez s11, .L4b_print_claim
    wfi
    j    1b

.L4b_print_claim:
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
    la   a0, msg_4b_c
    call uart_puts
    addi a0, s0, '0'
    call uart_putc
    li   a0, '='
    call uart_putc
    li   t0, 14
    beq  s6, t0, 1f
    li   a0, '0'
    call uart_putc
    j    2f
1:  li   a0, '1'
    call uart_putc
    li   a0, '4'
    call uart_putc
2:  li   a0, ']'
    call uart_putc
    li   a0, '\n'
    call uart_putc

    # Pass token around ring to synchronize next round (s11 already 0; keep MIE=0 until kicked? MIE=1 is safe since s11 is already 0!)
    addi t0, s0, 1
    li   t1, NUM_HARTS
    remu t0, t0, t1
    slli t0, t0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    li   t2, 1
    sw   t2, 0(t1)

    bnez s0, .L4b_sec_next
1:  bnez s11, .L4b_prim_next
    wfi
    j    1b

.L4b_prim_next:
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
.L4b_sec_next:
    addi s5, s5, 1
    j    .L4b_round

.L4b_done:
    bnez s7, test_fail

    # -------------------------------------------------------------------------
    # Final Ordered Pass Report
    # -------------------------------------------------------------------------
    beqz s0, .Lfinal_print
1:  bnez s11, .Lfinal_print
    wfi
    j    1b

.Lfinal_print:
    la   a0, msg_h_pass
    call uart_puts_tag_hart

    li   t0, NUM_HARTS - 1
    beq  s0, t0, .Llast_hart_done

    addi t0, s0, 1
    slli t0, t0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    li   t2, 1
    sw   t2, 0(t1)
    j    halt_forever

.Llast_hart_done:
    la   a0, msg_all_pass
    call uart_puts
    j    halt_forever

test_fail:
    la   a0, msg_fail
    call uart_puts_tag_hart
halt_forever:
    csrw mie, zero
1:  wfi
    j    1b

# =============================================================================
# Daisy-Chain Barrier (all N harts synchronize via CLINT msip)
# =============================================================================
sync_barrier:
    addi sp, sp, -16
    sd   ra, 0(sp)
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
    # Wait if secondary hart, then pass token; Wait - Hart 0 must clear s11 before sending!
    beqz s0, 2f
    # Wait for msip from previous hart; note if it arrived during ring, use dedicated s11=0 above?
    # Wait: Hart 0 might have finished Test 3 before Hart 1 cleared s11!
    # So secondary harts use MIE=1 here only after clearing s11? Better: Hart 0 delays 64 cycles or secondary harts clear s11 BEFORE starting Test 3?
    # Actually: in Test 3, Hart 0 had shortest deadline (180) and Hart h had (180 + 64*h), so Hart 0 always finishes Test 3 first,
    # Wait: what if Hart 1 finishes Test 3 and enters sync_barrier BEFORE Hart 0 sends? Yes, Hart 0 sends msip[1] at step 2!
    # What if Hart 0 finishes Test 3 AFTER Hart 1? Hart 1 sets s11=0 BEFORE Hart 0 ever reaches step 2, so Hart 0's msip[1] cannot be lost!
1:  bnez s11, 2f
    wfi
    j    1b
2:
    csrci mstatus, 8
    li   s11, 0
    addi t0, s0, 1
    li   t1, NUM_HARTS
    remu t0, t0, t1
    slli t0, t0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    li   t2, 1
    sw   t2, 0(t1)
    csrsi mstatus, 8
    bnez s0, 4f
3:  bnez s11, 4f
    wfi
    j    3b
4:
    csrci mstatus, 8
    li   s11, 0
    csrsi mstatus, 8
    ld   ra, 0(sp)
    addi sp, sp, 16
    ret

# =============================================================================
# M-Mode Trap Handler (MSIP, MTIP, S-mode ECALL)
# =============================================================================
    .balign 4
m_trap_entry:
    addi sp, sp, -64
    sd   t0, 0(sp)
    sd   t1, 8(sp)
    sd   t2, 16(sp)
    sd   t3, 24(sp)

    csrr t0, mcause
    bgez t0, .Lm_sync_exc

    slli t1, t0, 1
    srli t1, t1, 1              # interrupt code
    li   t2, 3
    beq  t1, t2, .Lm_msip
    li   t2, 7
    beq  t1, t2, .Lm_mtip
    j    test_fail

.Lm_msip:
    # Read msip[mhartid] (explicitly verifies addr[2]==1 lane steering on odd harts)
    slli t0, s0, 2
    li   t1, CLINT_MSIP_BASE
    add  t1, t1, t0
    lw   t2, 0(t1)
    beqz t2, 1f
    sw   zero, 0(t1)            # clear msip[mhartid]
    addi s11, s11, 1
1:  j    .Lm_exit

.Lm_mtip:
    # Clear mtimecmp[mhartid] = -1 and verify mtime >= deadline (s2)
    slli t0, s0, 3
    li   t1, CLINT_CMP_BASE
    add  t1, t1, t0
    li   t2, -1
    sd   t2, 0(t1)
    li   t0, CLINT_MTIME
    ld   t1, 0(t0)
    bltu t1, s2, test_fail
    li   s10, 1
    j    .Lm_exit

.Lm_sync_exc:
    li   t1, 9                  # S-mode ECALL -> return to M-mode at .L4a_back_in_mmode
    bne  t0, t1, test_fail
    li   t0, (3 << 11)
    csrs mstatus, t0            # MPP = 11 (M-mode)
    la   t0, .L4a_back_in_mmode
    csrw mepc, t0

.Lm_exit:
    ld   t0, 0(sp)
    ld   t1, 8(sp)
    ld   t2, 16(sp)
    ld   t3, 24(sp)
    addi sp, sp, 64
    mret

# =============================================================================
# S-Mode Trap Handler (SEIP Level 1 + Nested Preemption Level 2)
# =============================================================================
    .balign 4
s_trap_entry:
    addi sp, sp, -64
    sd   ra, 0(sp)
    sd   t0, 8(sp)
    sd   t1, 16(sp)
    sd   t2, 24(sp)
    sd   t3, 32(sp)
    sd   a0, 40(sp)
    sd   s1, 48(sp)

    csrr t0, scause
    bgez t0, test_fail
    slli t1, t0, 1
    srli t1, t1, 1
    li   t2, 9                  # SEIP
    bne  t1, t2, test_fail

    # Read claim[c_s] where s4 = 2*h + 1
    slli t0, s4, 12
    li   t1, PLIC_CTX_BASE
    add  t1, t1, t0
    lw   s1, 4(t1)              # s1 = claimed ID

    bnez s9, .Ls_nested

    # Level 1: expect Source (2 + h)
    addi t2, s0, 2
    bne  s1, t2, test_fail
    li   s9, 1

    # Save sepc and sstatus before enabling nested interrupts
    csrr t2, sepc
    csrr t3, sstatus
    sd   t2, 56(sp)
    addi sp, sp, -16
    sd   t3, 0(sp)

    # Trigger TB to assert higher-priority Source (6 + h) while (2+h) is IN_SERVICE
    la   a0, msg_4a_p
    call uart_puts_tag_hart

    # Re-enable S-mode interrupts so Source (6+h) preempts Level 1 handler
    csrsi sstatus, 2
1:  li   t0, 2
    bne  s9, t0, 1b
    csrci sstatus, 2

    ld   t3, 0(sp)
    addi sp, sp, 16
    ld   t2, 56(sp)
    csrw sstatus, t3
    csrw sepc, t2

    # Complete Level 1 Source (2 + h)
    slli t0, s4, 12
    li   t1, PLIC_CTX_BASE
    add  t1, t1, t0
    sw   s1, 4(t1)
    j    .Ls_exit

.Ls_nested:
    # Level 2 preemption: expect Source (6 + h)
    li   t0, 1
    bne  s9, t0, test_fail
    addi t2, s0, 6
    bne  s1, t2, test_fail
    # Complete Level 2 Source (6 + h)
    slli t0, s4, 12
    li   t1, PLIC_CTX_BASE
    add  t1, t1, t0
    sw   s1, 4(t1)
    li   s9, 2

.Ls_exit:
    ld   ra, 0(sp)
    ld   t0, 8(sp)
    ld   t1, 16(sp)
    ld   t2, 24(sp)
    ld   t3, 32(sp)
    ld   a0, 40(sp)
    ld   s1, 48(sp)
    addi sp, sp, 64
    sret

# =============================================================================
# UART Helpers (Uncached MMIO)
# =============================================================================
uart_putc:
    li   t0, UART_THR
    sw   a0, 0(t0)
    ret

uart_puts:
    mv   t2, a0
1:  lbu  a0, 0(t2)
    beqz a0, 2f
    li   t0, UART_THR
    sw   a0, 0(t0)
    addi t2, t2, 1
    j    1b
2:  ret

# Prints string at a0, then decimal digit (s0), then "]\n"
uart_puts_tag_hart:
    mv   a1, s0
uart_puts_tag_val:
    addi sp, sp, -16
    sd   ra, 0(sp)
    call uart_puts
    addi a0, a1, '0'
    call uart_putc
    li   a0, ']'
    call uart_putc
    li   a0, '\n'
    call uart_putc
    ld   ra, 0(sp)
    addi sp, sp, 16
    ret

    .section .rodata
msg_4a_s:     .asciz "[4A_S"
msg_4a_p:     .asciz "[4A_P"
msg_4a_d:     .asciz "[4A_D"
msg_4a_m:     .asciz "[4A_M"
msg_4a_ok:    .asciz "[4A_OK"
msg_4b_r:     .asciz "[4B_R"
msg_4b_c:     .asciz "[4B_C"
msg_h_pass:   .asciz "[H_PASS_"
msg_all_pass: .asciz "[S2_M1_ALL_PASS]\n"
msg_fail:     .asciz "[FAIL_H"
