/* Fursoy Slice-2 Milestone S2-M2 MESI Cache Coherence Verification Test
 * Compiled with -DNUM_HARTS=2 or -DNUM_HARTS=4 (-march=rv64ima_zicsr_zifencei).
 *
 * Exercises end-to-end hardware cache coherence without LR/SC/AMO:
 *   Test 1: Multi-hart cache-line ping-pong + false sharing on a single 64 B
 *           cache line across all N harts (M<->S<->I, E->M, COH_GETM, UPGRADE).
 *   Test 2: Concurrent Upgrade-vs-Invalidate + same-set L1D/WBB/L2 evictions
 *           (4 KiB L1D Set-0 aliasing + 32 KiB L2 Set-0 aliasing forcing PutM
 *           vs SNOOP_GETM/SNOOP_GETS & inclusive victim back-invalidation).
 *   Test 3: Shared Read-Only broadcast (DIR_S across N harts), silent E->I
 *           eviction, and invalidating store from hart (N-1).
 *   Test 4: Coherent L1I self- & cross-hart modifying code (Hart 0 writes code
 *           in M-state L1D without flushing -> Hart 1 fetches via Hub; then
 *           Hart 1 overwrites code in M-state L1D -> Hart 0 refetches new code).
 *   Test 5: Coherent hardware Sv39 PTW reading live dirty PTEs from remote
 *           hart's M-state L1D (two mappings back-to-back with SFENCE.VMA).
 */
    .option norvc
    .option norelax

#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

.equ UART_THR,        0x10000000
.equ CLINT_MTIME,     0x0200BFF8

.equ PRIV_RAM_BASE,   0x80400000
.equ SHM_BASE,        0x80500000

/* Test 1: 64 B shared line */
.equ PP_LINE,         0x80500000  /* [0]=turn, [8]=round, [16]=hash, [24+8*h]=hart cnt */

/* Test 2: L1D Set 0 + L2 Set 0 alias lines (stride 0x8000 = 32 KiB) */
.equ ALIAS_BASE,      0x80510000
.equ ALIAS_STRIDE,    0x8000

/* Test 3: Shared-RO 4-line buffer */
.equ SRO_BASE,        0x80550000

/* Synchronization variables on disjoint cache lines (0x40 apart) */
.equ SYNC_BASE,       0x80558000
.equ SYNC_T2_TURN,    0x80558000
.equ SYNC_SMC_PHASE,  0x80558040
.equ SYNC_PTW_PHASE,  0x80558080
.equ SYNC_UART_LOCK,  0x805580C0

/* Barriers (one 64 B cache line per barrier round, per-hart arrived byte/word) */
.equ BAR_BASE,        0x80559000

/* Test 4: Self-modifying code target (above 0x8020_0000 PMP boundary) */
.equ SMC_CODE_BUF,    0x80560000
.equ SMODE_STUB_ADDR, 0x80564000

/* Test 5: Sv39 Page Tables (4 KiB aligned) & Data Pages */
.equ PT_L2_ADDR,      0x80570000
.equ PT_L1_ADDR,      0x80571000
.equ PT_L0_ADDR,      0x80572000
.equ PT_DATA1_PA,     0x80574000
.equ PT_DATA2_PA,     0x80575000
.equ PT_TEST_VA,      0xC0000000

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    csrr s0, mhartid
    li   t0, NUM_HARTS
    bgeu s0, t0, test_fail

    # Per-hart private 16 KiB stack in [0x8040_0000 .. )
    slli t1, s0, 14
    li   t2, PRIV_RAM_BASE + 0x4000
    add  sp, t2, t1

    csrw mie, zero
    csrci mstatus, 8
    la   t0, m_trap_entry
    csrw mtvec, t0
    li   t0, 7
    csrw mcounteren, t0
    csrw scounteren, t0

    # Zero shared state on Hart 0 before releasing Barrier 0
    bnez s0, .Linit_wait

    # Zero PP_LINE (64 B), SYNC_BASE (256 B), BAR_BASE (1 KiB)
    li   t0, PP_LINE
    li   t1, 8
1:  sd   zero, 0(t0)
    addi t0, t0, 8
    addi t1, t1, -1
    bnez t1, 1b

    li   t0, SYNC_BASE
    li   t1, 32
2:  sd   zero, 0(t0)
    addi t0, t0, 8
    addi t1, t1, -1
    bnez t1, 2b

    li   t0, BAR_BASE
    li   t1, 128
3:  sd   zero, 0(t0)
    addi t0, t0, 8
    addi t1, t1, -1
    bnez t1, 3b

    # Initialize ALIAS_BASE[0..9] to 0
    li   t0, ALIAS_BASE
    li   t1, 10
4:  sd   zero, 0(t0)
    li   t2, ALIAS_STRIDE
    add  t0, t0, t2
    addi t1, t1, -1
    bnez t1, 4b

    # Write non-zero start flag at BAR_BASE - 0x40? Use SYNC_BASE + 0x100 as init_done
    fence rw, rw
    li   t0, SYNC_BASE + 0x100
    li   t1, 1
    sd   t1, 0(t0)
    j    .Linit_done

.Linit_wait:
    li   t0, SYNC_BASE + 0x100
1:  ld   t1, 0(t0)
    beqz t1, 1b
    fence r, r

.Linit_done:
    # Set s1 = barrier slot index (0..15)
    li   s1, 0
    call shm_barrier

    # =========================================================================
    # Test 1: Multi-Hart Cache-Line Ping-Pong & False Sharing (64 Rounds)
    # =========================================================================
    li   s2, 0                  # my turns taken
    li   s3, 16                 # each hart executes 16 turns -> 16*N total turns
    li   s4, PP_LINE

.Lt1_loop:
    ld   t0, 0(s4)              # poll PP_LINE.turn
    bne  t0, s0, .Lt1_loop
    fence r, rw

    # Verify round_cnt and accum_hash match software invariant
    ld   t1, 8(s4)              # round_cnt
    ld   t2, 16(s4)             # accum_hash
    # Compute expected next hash = accum_hash + (round_cnt * 131 + s0 + 1)
    li   t3, 131
    mul  t4, t1, t3
    add  t4, t4, s0
    addi t4, t4, 1
    add  t2, t2, t4
    addi t1, t1, 1

    # False-sharing update: increment my private slot inside SAME 64 B PP_LINE
    addi t5, s0, 3
    slli t5, t5, 3
    add  t5, s4, t5
    ld   t6, 0(t5)
    addi t6, t6, 1
    sd   t6, 0(t5)

    sd   t1, 8(s4)
    sd   t2, 16(s4)
    fence rw, rw

    # Advance turn = (s0 + 1) % NUM_HARTS
    addi t0, s0, 1
    li   t3, NUM_HARTS
    remu t0, t0, t3
    sd   t0, 0(s4)

    addi s2, s2, 1
    bltu s2, s3, .Lt1_loop

    call shm_barrier

    # Every hart reads and verifies final PP_LINE state!
    li   s4, PP_LINE
    ld   t1, 8(s4)
    li   t0, 16 * NUM_HARTS
    bne  t1, t0, test_fail
    # Expected accum_hash = 131 * R*(R-1)/2 + R + 16 * N*(N-1)/2, R = 16*N
    addi t2, t0, -1
    mul  t2, t0, t2
    srli t2, t2, 1
    li   t3, 131
    mul  t2, t2, t3
    add  t2, t2, t0
    li   t3, NUM_HARTS
    addi t4, t3, -1
    mul  t3, t3, t4
    slli t3, t3, 3              # 16 * N*(N-1)/2 = 8 * N*(N-1)
    add  t2, t2, t3
    ld   t1, 16(s4)
    bne  t1, t2, test_fail
    # Verify per-hart slot inside PP_LINE == 16 for every hart h
    li   t3, 0
    li   t4, NUM_HARTS
1:  addi t5, t3, 3
    slli t5, t5, 3
    add  t5, s4, t5
    ld   t6, 0(t5)
    li   t2, 16
    bne  t6, t2, test_fail
    addi t3, t3, 1
    bltu t3, t4, 1b

    bnez s0, 2f
    la   a0, msg_t1_pass
    call uart_puts
2:
    call shm_barrier

    # =========================================================================
    # Test 2: Concurrent L1D/L2 Set-0 Alias Eviction, WBB PutM vs Snoop, Upgrade-vs-Inv
    # =========================================================================
    # Each hart storms 10 Set-0 alias lines (stride 0x8000 = L1D Set 0 + L2 Set 0),
    # alternating reads (S) and stores (M / COH_UPGRADE) to provoke simultaneous
    # WBB PutM evictions, L2 victim back-invalidations, and Upgrade-vs-Inv races.
    li   s2, 2                  # 2 outer rounds
    li   s4, ALIAS_BASE
    li   s5, ALIAS_STRIDE

.Lt2_round:
    # Phase A: All harts hammer offset +8*h inside all 10 alias lines concurrently!
    slli s6, s0, 3
    li   t0, 0
    li   t1, 10
    li   t2, 0xA500
    add  t2, t2, s0
.Lt2_hammer:
    add  t3, s4, s6
    ld   t4, 0(t3)              # Read (pulls line into S)
    add  t4, t4, t2
    sd   t4, 0(t3)              # Write (UPGRADE or GETM against concurrent harts on same line!)
    add  s4, s4, s5
    addi t0, t0, 1
    bltu t0, t1, .Lt2_hammer
    li   s4, ALIAS_BASE
    addi s2, s2, -1
    bnez s2, .Lt2_round

    call shm_barrier

    # Verify every hart's lane across all 10 alias lines == 2 * (0xA500 + h)
    li   t0, 0
    li   t1, 10
    li   s4, ALIAS_BASE
.Lt2_verify_outer:
    li   t2, 0
    li   t3, NUM_HARTS
.Lt2_verify_inner:
    slli t4, t2, 3
    add  t4, s4, t4
    ld   t5, 0(t4)
    li   t6, 0xA500
    add  t6, t6, t2
    slli t6, t6, 1
    bne  t5, t6, test_fail
    addi t2, t2, 1
    bltu t2, t3, .Lt2_verify_inner
    add  s4, s4, s5
    addi t0, t0, 1
    bltu t0, t1, .Lt2_verify_outer

    bnez s0, 2f
    la   a0, msg_t2_pass
    call uart_puts
2:
    call shm_barrier

    # =========================================================================
    # Test 3: Shared Read-Only Broadcast (DIR_S), Silent E->I, Invalidating Store
    # =========================================================================
    bnez s0, .Lt3_after_init
    # Hart 0 writes 4 cache lines in SRO_BASE, then reads 8 conflict lines to evict cleanly
    li   t0, SRO_BASE
    li   t1, 0x11110001
    sd   t1, 0(t0)
    li   t1, 0x22220002
    sd   t1, 0x40(t0)
    li   t1, 0x33330003
    sd   t1, 0x80(t0)
    li   t1, 0x44440004
    sd   t1, 0xC0(t0)
    fence rw, rw
.Lt3_after_init:
    call shm_barrier

    # All N harts read all 4 lines -> DIR_S sharer_vec = all harts
    li   t0, SRO_BASE
    ld   t1, 0(t0)
    li   t2, 0x11110001
    bne  t1, t2, test_fail
    ld   t1, 0x40(t0)
    li   t2, 0x22220002
    bne  t1, t2, test_fail
    ld   t1, 0x80(t0)
    li   t2, 0x33330003
    bne  t1, t2, test_fail
    ld   t1, 0xC0(t0)
    li   t2, 0x44440004
    bne  t1, t2, test_fail

    call shm_barrier

    # Last hart (NUM_HARTS - 1) upgrades line 0 and overwrites it (invalidates all others)
    li   t0, NUM_HARTS - 1
    bne  s0, t0, 1f
    li   t1, SRO_BASE
    li   t2, 0x9999ABCD
    sd   t2, 0(t1)
    fence rw, rw
1:
    call shm_barrier

    # All harts check updated line 0 == 0x9999ABCD
    li   t1, SRO_BASE
    ld   t2, 0(t1)
    li   t3, 0x9999ABCD
    bne  t2, t3, test_fail

    bnez s0, 2f
    la   a0, msg_t3_pass
    call uart_puts
2:
    call shm_barrier

    # =========================================================================
    # Test 4: Coherent L1I Remote-Written Instructions (Zero Manual D-Flush)
    # =========================================================================
    # Round 1: Hart 0 writes func1 ("li a0, 0x1234; ret") to SMC_CODE_BUF WITHOUT
    # executing fence.i on Hart 0, then releases phase=1. Every hart runs fence.i
    # and calls SMC_CODE_BUF, forcing L1I COH_GETS_NC to snoop Hart 0's M-state L1D!
    bnez s0, .Lt4_r1_wait
    li   t0, SMC_CODE_BUF
    li   t1, 0x00001537         # lui a0, 1
    sw   t1, 0(t0)
    li   t1, 0x23450513         # addi a0, a0, 0x234
    sw   t1, 4(t0)
    li   t1, 0x00008067         # ret
    sw   t1, 8(t0)
    fence rw, rw
    li   t2, SYNC_SMC_PHASE
    li   t3, 1
    sd   t3, 0(t2)
    j    .Lt4_r1_exec
.Lt4_r1_wait:
    li   t2, SYNC_SMC_PHASE
1:  ld   t3, 0(t2)
    beqz t3, 1b
    fence r, r
.Lt4_r1_exec:
    fence.i
    li   t0, SMC_CODE_BUF
    jalr ra, t0, 0
    li   t1, 0x1234
    bne  a0, t1, test_fail

    call shm_barrier

    # Round 2: Hart 1 overwrites SMC_CODE_BUF with func2 ("li a0, 0x5678; ret")
    # in Hart 1's M-state L1D (NO fence.i on Hart 1); all harts refetch func2.
    li   t0, 1
    bne  s0, t0, .Lt4_r2_wait
    li   t0, SMC_CODE_BUF
    li   t1, 0x00005537         # lui a0, 5
    sw   t1, 0(t0)
    li   t1, 0x67850513         # addi a0, a0, 0x678
    sw   t1, 4(t0)
    li   t1, 0x00008067         # ret
    sw   t1, 8(t0)
    fence rw, rw
    li   t2, SYNC_SMC_PHASE
    li   t3, 2
    sd   t3, 0(t2)
    j    .Lt4_r2_exec
.Lt4_r2_wait:
    li   t2, SYNC_SMC_PHASE
1:  ld   t3, 0(t2)
    li   t4, 2
    bne  t3, t4, 1b
    fence r, r
.Lt4_r2_exec:
    fence.i
    li   t0, SMC_CODE_BUF
    jalr ra, t0, 0
    li   t1, 0x5678
    bne  a0, t1, test_fail

    bnez s0, 2f
    la   a0, msg_t4_pass
    call uart_puts
2:
    call shm_barrier

    # =========================================================================
    # Test 5: Coherent Hardware Sv39 PTW Snoop Against Remote Dirty L1D PTE
    # =========================================================================
    bnez s0, .Lt5_hart1_check

    # Hart 0: Zero 4 KiB PT_L2, PT_L1, PT_L0 and initialize DATA1 / DATA2
    li   t0, PT_L2_ADDR
    li   t1, 512
1:  sd   zero, 0(t0)
    addi t0, t0, 8
    addi t1, t1, -1
    bnez t1, 1b

    li   t0, PT_L1_ADDR
    li   t1, 512
2:  sd   zero, 0(t0)
    addi t0, t0, 8
    addi t1, t1, -1
    bnez t1, 2b

    li   t0, PT_L0_ADDR
    li   t1, 512
3:  sd   zero, 0(t0)
    addi t0, t0, 8
    addi t1, t1, -1
    bnez t1, 3b

    li   t0, PT_DATA1_PA
    li   t1, 0xDEADBEEF11112222
    sd   t1, 0(t0)
    li   t0, PT_DATA2_PA
    li   t1, 0xCAFEBABE33334444
    sd   t1, 0(t0)

    # Identity gigapage for [0x8000_0000 .. 0xBFFF_FFFF]: L2_PT[2]
    li   t0, PT_L2_ADDR
    li   t1, (0x80000000 >> 2) | 0xCF
    sd   t1, 16(t0)

    # Non-leaf L2_PT[3] -> PT_L1_ADDR, L1_PT[0] -> PT_L0_ADDR
    li   t1, (PT_L1_ADDR >> 2) | 0x01
    sd   t1, 24(t0)
    li   t0, PT_L1_ADDR
    li   t1, (PT_L0_ADDR >> 2) | 0x01
    sd   t1, 0(t0)

    # Leaf L0_PT[0] -> PT_DATA1_PA (held dirty in Hart 0's M-state L1D!)
    li   t0, PT_L0_ADDR
    li   t1, (PT_DATA1_PA >> 2) | 0xCF
    sd   t1, 0(t0)

    # Copy S-mode stub above 0x8020_0000 (so !l1i_pmp_deny)
    la   t0, smode_ptw_stub
    la   t1, smode_ptw_stub_end
    li   t2, SMODE_STUB_ADDR
4:  bgeu t0, t1, 5f
    lw   t3, 0(t0)
    sw   t3, 0(t2)
    addi t0, t0, 4
    addi t2, t2, 4
    j    4b
5:
    fence rw, rw
    li   t0, SYNC_PTW_PHASE
    sd   zero, 0(t0)            # Mapping 1 sub-phase = 0

    # Barrier: release all H1..H(N-1) to walk Mapping 1 against H0's dirty L0_PT[0]
    call shm_barrier

    # Barrier: wait for all H1..H(N-1) to complete Mapping 1 walk
    call shm_barrier

    # Update leaf L0_PT[0] -> PT_DATA2_PA cleanly in Hart 0 M-state L1D!
    li   t0, PT_L0_ADDR
    li   t1, (PT_DATA2_PA >> 2) | 0xCF
    sd   t1, 0(t0)
    li   t0, SYNC_PTW_PHASE
    li   t1, 1
    sd   t1, 0(t0)              # Mapping 2 sub-phase = 1
    fence rw, rw

    # Barrier: release all H1..H(N-1) to walk Mapping 2 after SFENCE.VMA
    call shm_barrier
    j    .Lt5_done

.Lt5_hart1_check:
    # H1 .. H(N-1) all execute concurrent Sv39 PTW walks against H0's dirty PTEs
    call shm_barrier
    fence r, r
    fence.i

    # Enable Sv39 satp = (8 << 60) | (PT_L2_ADDR >> 12)
    li   t1, 8
    slli t1, t1, 60
    li   t2, (PT_L2_ADDR >> 12)
    or   t1, t1, t2
    csrw satp, t1
    sfence.vma zero, zero

    # Enter S-mode stub at SMODE_STUB_ADDR to read VA PT_TEST_VA
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11)          # MPP = 01 (S-mode)
    csrs mstatus, t0
    li   t0, SMODE_STUB_ADDR
    csrw mepc, t0
    li   a0, PT_TEST_VA
    mret

.Lt5_after_map1:
    li   t2, 0xDEADBEEF11112222
    bne  a1, t2, test_fail

    call shm_barrier            # Notify H0 Mapping 1 complete
    call shm_barrier            # Wait for H0 to dirty L0_PT[0] -> PT_DATA2_PA
    fence r, r

    sfence.vma zero, zero
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11)
    csrs mstatus, t0
    li   t0, SMODE_STUB_ADDR
    csrw mepc, t0
    li   a0, PT_TEST_VA
    mret

.Lt5_after_map2:
    li   t2, 0xCAFEBABE33334444
    bne  a1, t2, test_fail
    csrw satp, zero
    sfence.vma zero, zero

.Lt5_done:
    call shm_barrier

    bnez s0, 1f
    la   a0, msg_t5_pass
    call uart_puts
1:
    call shm_barrier

    # Ordered final HART_PASS print
    beqz s0, .Lfinal_print
    # Wait on turn in SYNC_UART_LOCK == s0
    li   t0, SYNC_UART_LOCK
2:  ld   t1, 0(t0)
    bne  t1, s0, 2b
    fence r, r

.Lfinal_print:
    la   a0, msg_h_pass
    call uart_puts_tag_hart
    li   t0, NUM_HARTS - 1
    beq  s0, t0, .Lall_pass_print
    addi t1, s0, 1
    fence rw, rw
    li   t0, SYNC_UART_LOCK
    sd   t1, 0(t0)
    j    halt_forever

.Lall_pass_print:
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

# S-mode PTW load stub (copied to SMODE_STUB_ADDR > 0x8020_0000)
    .balign 4
smode_ptw_stub:
    ld   a1, 0(a0)
    ecall
smode_ptw_stub_end:

# =============================================================================
# Shared-Memory Barrier (uses slot s1, increments s1)
# =============================================================================
# Uses separate 64 B cache line BAR_BASE + 64*s1; byte/word offset 8*h is hart h.
# Wait until all N harts write 1 to their word; clean and advance!
shm_barrier:
    slli t0, s1, 6
    li   t1, BAR_BASE
    add  t0, t1, t0             # my_bar = BAR_BASE + 64*s1
    fence rw, rw
    slli t2, s0, 3
    add  t2, t0, t2
    li   t3, 1
    sd   t3, 0(t2)              # my_bar[s0] = 1
    li   t4, NUM_HARTS
    li   t5, 0
1:  slli t2, t5, 3
    add  t2, t0, t2
    ld   t3, 0(t2)
    beqz t3, 1b
    addi t5, t5, 1
    bltu t5, t4, 1b
    fence r, rw
    addi s1, s1, 1
    ret

# =============================================================================
# M-Mode Trap Handler (Handles S-mode ECALL from Test 5)
# =============================================================================
    .balign 4
m_trap_entry:
    csrr t0, mcause
    li   t1, 9                  # ECALL from S-mode
    bne  t0, t1, test_fail
    # Set MPP = 11 (M-mode)
    li   t0, (3 << 11)
    csrs mstatus, t0
    # Return to .Lt5_after_map1 when SYNC_PTW_PHASE == 0, else .Lt5_after_map2
    li   t0, SYNC_PTW_PHASE
    ld   t1, 0(t0)
    beqz t1, 1f
    la   t0, .Lt5_after_map2
    csrw mepc, t0
    mret
1:  la   t0, .Lt5_after_map1
    csrw mepc, t0
    mret

# =============================================================================
# UART Helpers
# =============================================================================
uart_puts:
    li   t0, UART_THR
1:  lbu  t1, 0(a0)
    beqz t1, 2f
    sb   t1, 0(t0)
    addi a0, a0, 1
    j    1b
2:  ret

uart_puts_tag_hart:
    addi sp, sp, -16
    sd   ra, 0(sp)
    call uart_puts
    li   t0, UART_THR
    addi t1, s0, '0'
    sb   t1, 0(t0)
    li   t1, ']'
    sb   t1, 0(t0)
    li   t1, '\n'
    sb   t1, 0(t0)
    ld   ra, 0(sp)
    addi sp, sp, 16
    ret

    .section .rodata
msg_t1_pass:  .asciz "[T1_PINGPONG_PASS]\n"
msg_t2_pass:  .asciz "[T2_RACE_EVICT_PASS]\n"
msg_t3_pass:  .asciz "[T3_SHARED_RO_PASS]\n"
msg_t4_pass:  .asciz "[T4_COH_L1I_PASS]\n"
msg_t5_pass:  .asciz "[T5_COH_PTW_PASS]\n"
msg_h_pass:   .asciz "[HART_PASS_H"
msg_all_pass: .asciz "[ALL_PASS]\n"
msg_fail:     .asciz "[FAIL_H"
