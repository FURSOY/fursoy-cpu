/* Fursoy Slice-2 Milestone S2-M4 Full 8-Test RVWMO SMP Litmus Suite
 * Compiled with -DNUM_HARTS=2 or -DNUM_HARTS=4 (-march=rv64ima_zicsr_zifencei).
 *
 * Executes >= 128 iterations per pattern with rotating hart role assignments,
 * per-hart LFSR jitter delays, and cycle-by-cycle SWMR scoreboard checking:
 *   1. MP       (Message Passing, ordered fence rw,w + fence r,rw -> 0 forbidden)
 *      MP_CTRL  (Unordered control without fences for sensitivity visibility)
 *   2. SB       (Store Buffering, ordered fence rw,rw -> 0 forbidden)
 *   3. LB       (Load Buffering, ordered fence r,rw -> 0 forbidden)
 *   4. IRIW     (Multi-Copy Atomicity: 4-hart IRIW on N=4, 2W+2R cross-read on N=2)
 *   5. CoRR     (Read-Read Coherence: 128x16 monotonic per-address read pairs)
 *   6. CoWR     (Write-Read Coherence: 128x8 fenced local/remote write-read checks)
 *   7. CoRW     (Read-Write Coherence: ordered R->W vs W->R total order)
 *   8. CoWW     (Write-Write Coherence: multi-hart convergence + 2W vs 2R order)
 */
    .option norvc
    .option norelax

#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

#ifndef LITMUS_ITERS
#define LITMUS_ITERS 128
#endif

#define LITMUS_STR_INNER(x) #x
#define LITMUS_STR(x) LITMUS_STR_INNER(x)

.equ UART_THR,        0x10000000
.equ PRIV_RAM_BASE,   0x80400000

/* Disjoint 64 B cache-line shared addresses */
.equ SHM_INIT_DONE,   0x80500000
.equ SHM_BAR_CNT,     0x80500040
.equ SHM_X,           0x80500080
.equ SHM_Y,           0x805000C0
.equ SHM_R0,          0x80500100
.equ SHM_R1,          0x80500140
.equ SHM_R2,          0x80500180
.equ SHM_R3,          0x805001C0
.equ SHM_R4,          0x80500200
.equ SHM_R5,          0x80500240
.equ SHM_PER_HART,    0x80500400  /* + 64 * hartid */
.equ SHM_STATS,       0x80500800  /* forbid & obs counters */

    .section .text.init,"ax",@progbits
    .globl _start
_start:
    csrr s0, mhartid
    li   t0, NUM_HARTS
    bgeu s0, t0, litmus_fail

    /* Per-hart private 16 KiB stack in [0x8040_0000 .. ) */
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

    /* Seed per-hart xorshift64 jitter generator in s9 */
    li   s9, 0x9E3779B97F4A7C15
    addi t0, s0, 1
    xor  s9, s9, t0
    slli t1, t0, 17
    add  s9, s9, t1

    li   s7, 0                  /* epoch barrier counter */
    li   s8, SHM_BAR_CNT
    li   s11, LITMUS_ITERS

    bnez s0, .Lwait_init

    /* Hart 0 clears shared communication region */
    li   t0, SHM_INIT_DONE
    li   t1, 0x80500A00
1:  sd   zero, 0(t0)
    addi t0, t0, 8
    bltu t0, t1, 1b

    fence rw, rw
    li   t0, SHM_INIT_DONE
    li   t1, 1
    sd   t1, 0(t0)
    j    .Linit_done

.Lwait_init:
    li   t0, SHM_INIT_DONE
1:  ld   t1, 0(t0)
    beqz t1, 1b
    fence r, r

.Linit_done:
    call litmus_barrier

    /* =========================================================================
     * TEST 1A: Ordered MP (Message Passing)
     *   Writer: sd tag, (X); fence rw, w; sd tag, (Y)
     *   Reader: ld r1, (Y); fence r, rw; ld r0, (X)
     *   Forbidden: r1 == tag && r0 != tag
     * ========================================================================= */
    li   s10, 1                 /* round 1..LITMUS_ITERS */
    li   s2, 0                  /* forbid_mp */
    li   s3, 0                  /* obs_mp_11 */
.Lmp_loop:
    bgtu s10, s11, .Lmp_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_Y
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    /* Rotating writer = round % NUM_HARTS, reader = (round + 1) % NUM_HARTS */
    li   t4, NUM_HARTS
    remu t5, s10, t4
    addi t6, t5, 1
    remu t6, t6, t4

    beq  s0, t5, .Lmp_writer
    beq  s0, t6, .Lmp_reader
    j    .Lmp_next

.Lmp_writer:
    li   t0, SHM_X
    li   t1, SHM_Y
    sd   s10, 0(t0)
    fence rw, w
    sd   s10, 0(t1)
    j    .Lmp_next

.Lmp_reader:
    li   t0, SHM_X
    li   t1, SHM_Y
    ld   a1, 0(t1)              /* r1 = flag */
    fence r, rw
    ld   a0, 0(t0)              /* r0 = data */
    bne  a1, s10, .Lmp_next
    bne  a0, s10, 2f
    addi s3, s3, 1              /* observed (1,1) */
    j    .Lmp_next
2:  addi s2, s2, 1              /* FORBIDDEN (1,0) */

.Lmp_next:
    call litmus_barrier
    addi s10, s10, 1
    j    .Lmp_loop

.Lmp_done:
    /* Gather reader counters to SHM_PER_HART[s0] and sum on Hart 0 */
    slli t0, s0, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    sd   s2, 0(t1)
    sd   s3, 8(t1)
    call litmus_barrier
    bnez s0, .Lmp_ctrl_start

    li   t2, 0                  /* total forbid */
    li   t3, 0                  /* total obs_11 */
    li   t4, 0
    li   t5, NUM_HARTS
1:  slli t0, t4, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    ld   a4, 0(t1)
    ld   a5, 8(t1)
    add  t2, t2, a4
    add  t3, t3, a5
    addi t4, t4, 1
    bltu t4, t5, 1b

    bnez t2, litmus_fail
    la   a0, msg_mp_prefix
    mv   a1, t2
    mv   a2, t3
    call print_litmus_line

    /* =========================================================================
     * TEST 1B: Unordered MP Control (no fences, warm reader copy of X)
     * ========================================================================= */
.Lmp_ctrl_start:
    li   s10, 1
    li   s2, 0                  /* ctrl_reordered */
    li   s3, 0                  /* ctrl_11 */
.Lmp_ctrl_loop:
    bgtu s10, s11, .Lmp_ctrl_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_Y
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    /* Pre-warm X in reader's L1D before second barrier while writer keeps Y cold */
    li   t4, NUM_HARTS
    addi t6, s10, 1
    remu t6, t6, t4
    bne  s0, t6, 2f
    li   t0, SHM_X
    ld   zero, 0(t0)
2:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    addi t6, t5, 1
    remu t6, t6, t4
    beq  s0, t5, .Lmpc_writer
    beq  s0, t6, .Lmpc_reader
    j    .Lmpc_next

.Lmpc_writer:
    li   t0, SHM_X
    li   t1, SHM_Y
    sd   s10, 0(t0)
    sd   s10, 0(t1)
    j    .Lmpc_next

.Lmpc_reader:
    li   t0, SHM_X
    li   t1, SHM_Y
    ld   a1, 0(t1)
    ld   a0, 0(t0)
    bne  a1, s10, .Lmpc_next
    bne  a0, s10, 3f
    addi s3, s3, 1
    j    .Lmpc_next
3:  addi s2, s2, 1

.Lmpc_next:
    call litmus_barrier
    addi s10, s10, 1
    j    .Lmp_ctrl_loop

.Lmp_ctrl_done:
    slli t0, s0, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    sd   s2, 0(t1)
    sd   s3, 8(t1)
    call litmus_barrier
    bnez s0, .Lsb_start

    li   t2, 0
    li   t3, 0
    li   t4, 0
    li   t5, NUM_HARTS
1:  slli t0, t4, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    ld   a4, 0(t1)
    ld   a5, 8(t1)
    add  t2, t2, a4
    add  t3, t3, a5
    addi t4, t4, 1
    bltu t4, t5, 1b
    la   a0, msg_mp_ctrl_prefix
    mv   a1, t2
    mv   a2, t3
    call print_litmus_line

    /* =========================================================================
     * TEST 2: SB (Store Buffering, fence rw, rw)
     *   A: sd 1, (X); fence rw, rw; ld r0, (Y)
     *   B: sd 1, (Y); fence rw, rw; ld r1, (X)
     *   Forbidden: r0 == 0 && r1 == 0
     * ========================================================================= */
.Lsb_start:
    li   s10, 1
    li   s2, 0                  /* forbid_sb */
    li   s3, 0                  /* obs_sb_asym (0,1 or 1,0) */
.Lsb_loop:
    bgtu s10, s11, .Lsb_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_Y
    sd   zero, 0(t0)
    li   t0, SHM_R0
    sd   zero, 0(t0)
    li   t0, SHM_R1
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    addi t6, t5, 1
    remu t6, t6, t4
    beq  s0, t5, .Lsb_h0
    beq  s0, t6, .Lsb_h1
    j    .Lsb_chk

.Lsb_h0:
    li   t0, SHM_X
    li   t1, SHM_Y
    li   t2, 1
    sd   t2, 0(t0)
    fence rw, rw
    ld   t3, 0(t1)
    li   t0, SHM_R0
    sd   t3, 0(t0)
    j    .Lsb_chk

.Lsb_h1:
    li   t1, SHM_Y
    li   t0, SHM_X
    li   t2, 1
    sd   t2, 0(t1)
    fence rw, rw
    ld   t3, 0(t0)
    li   t0, SHM_R1
    sd   t3, 0(t0)

.Lsb_chk:
    call litmus_barrier
    bnez s0, .Lsb_next
    li   t0, SHM_R0
    ld   a4, 0(t0)
    li   t0, SHM_R1
    ld   a5, 0(t0)
    or   t1, a4, a5
    bnez t1, 2f
    addi s2, s2, 1              /* FORBIDDEN (0,0) */
    j    .Lsb_next
2:  xor  t1, a4, a5
    beqz t1, .Lsb_next
    addi s3, s3, 1              /* observed tight race (0,1)/(1,0) */

.Lsb_next:
    addi s10, s10, 1
    j    .Lsb_loop

.Lsb_done:
    bnez s0, .Llb_start
    bnez s2, litmus_fail
    la   a0, msg_sb_prefix
    mv   a1, s2
    mv   a2, s3
    call print_litmus_line

    /* =========================================================================
     * TEST 3: LB (Load Buffering, fence r, rw)
     *   A: ld r0, (X); fence r, rw; sd 1, (Y)
     *   B: ld r1, (Y); fence r, rw; sd 1, (X)
     *   Forbidden: r0 == 1 && r1 == 1
     * ========================================================================= */
.Llb_start:
    li   s10, 1
    li   s2, 0                  /* forbid_lb */
    li   s3, 0                  /* obs_lb_nonzero */
.Llb_loop:
    bgtu s10, s11, .Llb_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_Y
    sd   zero, 0(t0)
    li   t0, SHM_R0
    sd   zero, 0(t0)
    li   t0, SHM_R1
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    addi t6, t5, 1
    remu t6, t6, t4
    beq  s0, t5, .Llb_h0
    beq  s0, t6, .Llb_h1
    j    .Llb_chk

.Llb_h0:
    li   t0, SHM_X
    li   t1, SHM_Y
    ld   t3, 0(t0)
    fence r, rw
    li   t2, 1
    sd   t2, 0(t1)
    li   t0, SHM_R0
    sd   t3, 0(t0)
    j    .Llb_chk

.Llb_h1:
    li   t1, SHM_Y
    li   t0, SHM_X
    ld   t3, 0(t1)
    fence r, rw
    li   t2, 1
    sd   t2, 0(t0)
    li   t0, SHM_R1
    sd   t3, 0(t0)

.Llb_chk:
    call litmus_barrier
    bnez s0, .Llb_next
    li   t0, SHM_R0
    ld   a4, 0(t0)
    li   t0, SHM_R1
    ld   a5, 0(t0)
    and  t1, a4, a5
    beqz t1, 2f
    addi s2, s2, 1              /* FORBIDDEN (1,1) */
    j    .Llb_next
2:  or   t1, a4, a5
    beqz t1, .Llb_next
    addi s3, s3, 1              /* observed (0,1)/(1,0) */

.Llb_next:
    addi s10, s10, 1
    j    .Llb_loop

.Llb_done:
    bnez s0, .Liriw_start
    bnez s2, litmus_fail
    la   a0, msg_lb_prefix
    mv   a1, s2
    mv   a2, s3
    call print_litmus_line

    /* =========================================================================
     * TEST 4: IRIW (Multi-Copy Atomicity)
     *   N == 4: 4 rotating harts: w0(X=1), w1(Y=1), r0(X; fence r,r; Y), r1(Y; fence r,r; X)
     *           Forbidden: r0=(1,0) && r1=(1,0)
     *   N == 2: 2-writer/2-reader variant: H_A(sd X=1; fence rw,rw; ld Y; fence r,r; ld X),
     *           H_B(sd Y=1; fence rw,rw; ld X; fence r,r; ld Y)
     *           Forbidden: H_A sees Y==0 && H_B sees X==0 (or self-read == 0)
     * ========================================================================= */
.Liriw_start:
    li   s10, 1
    li   s2, 0                  /* forbid_iriw */
    li   s3, 0                  /* obs_iriw_both1 */
.Liriw_loop:
    bgtu s10, s11, .Liriw_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_Y
    sd   zero, 0(t0)
    li   t0, SHM_R0
    sd   zero, 0(t0)
    li   t0, SHM_R1
    sd   zero, 0(t0)
    li   t0, SHM_R2
    sd   zero, 0(t0)
    li   t0, SHM_R3
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

#if NUM_HARTS >= 4
    li   t4, NUM_HARTS
    remu t5, s10, t4            /* w0 */
    addi t6, t5, 1
    remu t6, t6, t4             /* w1 */
    addi a4, t5, 2
    remu a4, a4, t4             /* r0 */
    addi a5, t5, 3
    remu a5, a5, t4             /* r1 */

    beq  s0, t5, .Lir4_w0
    beq  s0, t6, .Lir4_w1
    beq  s0, a4, .Lir4_r0
    beq  s0, a5, .Lir4_r1
    j    .Lir_chk

.Lir4_w0:
    li   t0, SHM_X
    li   t1, 1
    sd   t1, 0(t0)
    j    .Lir_chk

.Lir4_w1:
    li   t0, SHM_Y
    li   t1, 1
    sd   t1, 0(t0)
    j    .Lir_chk

.Lir4_r0:
    li   t0, SHM_X
    li   t1, SHM_Y
    ld   a0, 0(t0)
    fence r, r
    ld   a1, 0(t1)
    li   t2, SHM_R0
    sd   a0, 0(t2)
    li   t2, SHM_R1
    sd   a1, 0(t2)
    j    .Lir_chk

.Lir4_r1:
    li   t0, SHM_X
    li   t1, SHM_Y
    ld   a0, 0(t1)
    fence r, r
    ld   a1, 0(t0)
    li   t2, SHM_R2
    sd   a0, 0(t2)
    li   t2, SHM_R3
    sd   a1, 0(t2)

.Lir_chk:
    call litmus_barrier
    bnez s0, .Liriw_next
    li   t0, SHM_R0
    ld   a0, 0(t0)              /* r0.X */
    li   t0, SHM_R1
    ld   a1, 0(t0)              /* r0.Y */
    li   t0, SHM_R2
    ld   a2, 0(t0)              /* r1.Y */
    li   t0, SHM_R3
    ld   a3, 0(t0)              /* r1.X */
    /* Forbidden: a0==1 && a1==0 && a2==1 && a3==0 */
    beqz a0, 3f
    bnez a1, 3f
    beqz a2, 3f
    bnez a3, 3f
    addi s2, s2, 1              /* FORBIDDEN non-MCA IRIW! */
    j    .Liriw_next
3:  and  t0, a0, a1
    and  t1, a2, a3
    or   t0, t0, t1
    beqz t0, .Liriw_next
    addi s3, s3, 1
#else
    /* N == 2: 2-writer/2-reader multi-copy causality & cross-read check */
    andi t5, s10, 1             /* w0 */
    xori t6, t5, 1              /* w1 */
    beq  s0, t5, .Lir2_h0
    j    .Lir2_h1

.Lir2_h0:
    li   t0, SHM_X
    li   t1, SHM_Y
    li   t2, 1
    sd   t2, 0(t0)
    fence rw, rw
    ld   a0, 0(t1)              /* r0.Y */
    fence r, r
    ld   a1, 0(t0)              /* r0.X (must be 1) */
    li   t2, SHM_R0
    sd   a0, 0(t2)
    li   t2, SHM_R1
    sd   a1, 0(t2)
    j    .Lir_chk2

.Lir2_h1:
    li   t0, SHM_X
    li   t1, SHM_Y
    li   t2, 1
    sd   t2, 0(t1)
    fence rw, rw
    ld   a2, 0(t0)              /* r1.X */
    fence r, r
    ld   a3, 0(t1)              /* r1.Y (must be 1) */
    li   t2, SHM_R2
    sd   a2, 0(t2)
    li   t2, SHM_R3
    sd   a3, 0(t2)

.Lir_chk2:
    call litmus_barrier
    bnez s0, .Liriw_next
    li   t0, SHM_R0
    ld   a0, 0(t0)
    li   t0, SHM_R1
    ld   a1, 0(t0)
    li   t0, SHM_R2
    ld   a2, 0(t0)
    li   t0, SHM_R3
    ld   a3, 0(t0)
    beqz a1, 4f
    beqz a3, 4f
    or   t0, a0, a2
    beqz t0, 4f                 /* Both saw 0 */
    and  t0, a0, a2
    beqz t0, .Liriw_next
    addi s3, s3, 1
    j    .Liriw_next
4:  addi s2, s2, 1
#endif

.Liriw_next:
    addi s10, s10, 1
    j    .Liriw_loop

.Liriw_done:
    bnez s0, .Lcorr_start
    bnez s2, litmus_fail
    la   a0, msg_iriw_prefix
    mv   a1, s2
    mv   a2, s3
    call print_litmus_line

    /* =========================================================================
     * TEST 5: CoRR (Read-Read Coherence, 256 rounds x 8 monotonic steps)
     *   Writer writes 1..8 monotonically; readers check r2 >= r1 on back-to-back reads
     * ========================================================================= */
.Lcorr_start:
    li   s10, 1
    li   s2, 0                  /* forbid_corr */
    li   s3, 0                  /* obs_corr_nonzero */
.Lcorr_loop:
    bgtu s10, s11, .Lcorr_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    li   t0, SHM_X
    beq  s0, t5, .Lcorr_writer

    /* Reader: 16 back-to-back ordered load pairs; r_new >= r_prev must hold */
    li   t1, 16
    li   t2, 0                  /* prev */
2:  ld   t3, 0(t0)
    bltu t3, t2, 3f
    mv   t2, t3
    fence r, r
    addi t1, t1, -1
    bnez t1, 2b
    beqz t2, .Lcorr_join
    addi s3, s3, 1
    j    .Lcorr_join
3:  addi s2, s2, 1              /* FORBIDDEN non-monotonic read */
    j    .Lcorr_join

.Lcorr_writer:
    li   t1, 1
    li   t2, 9
4:  sd   t1, 0(t0)
    fence w, w
    addi t1, t1, 1
    bltu t1, t2, 4b

.Lcorr_join:
    call litmus_barrier
    addi s10, s10, 1
    j    .Lcorr_loop

.Lcorr_done:
    slli t0, s0, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    sd   s2, 0(t1)
    sd   s3, 8(t1)
    call litmus_barrier
    bnez s0, .Lcowr_start

    li   t2, 0
    li   t3, 0
    li   t4, 0
    li   t5, NUM_HARTS
1:  slli t0, t4, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    ld   a4, 0(t1)
    ld   a5, 8(t1)
    add  t2, t2, a4
    add  t3, t3, a5
    addi t4, t4, 1
    bltu t4, t5, 1b
    bnez t2, litmus_fail
    la   a0, msg_corr_prefix
    mv   a1, t2
    mv   a2, t3
    call print_litmus_line

    /* =========================================================================
     * TEST 6: CoWR (Write-Read Coherence, 256 rounds x 8 writes)
     *   Writer: sd k, (X); fence w, r; ld r0, (X) -> r0 >= k (same value here)
     *   Readers: verify monotonic reads across k = 1..8
     * ========================================================================= */
.Lcowr_start:
    li   s10, 1
    li   s2, 0                  /* forbid_cowr */
    li   s3, 0                  /* obs_cowr_checks */
.Lcowr_loop:
    bgtu s10, s11, .Lcowr_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    li   t0, SHM_X
    bne  s0, t5, .Lcowr_reader

    li   t1, 1
    li   t2, 9
2:  sd   t1, 0(t0)
    fence w, r
    ld   t3, 0(t0)
    bne  t3, t1, 3f             /* CoWR violation: failed to read own coherent store */
    addi s3, s3, 1
    addi t1, t1, 1
    bltu t1, t2, 2b
    j    .Lcowr_join
3:  addi s2, s2, 1
    j    .Lcowr_join

.Lcowr_reader:
    li   t1, 16
    li   t2, 0
4:  ld   t3, 0(t0)
    bltu t3, t2, 5f
    mv   t2, t3
    fence r, r
    addi t1, t1, -1
    bnez t1, 4b
    j    .Lcowr_join
5:  addi s2, s2, 1

.Lcowr_join:
    call litmus_barrier
    addi s10, s10, 1
    j    .Lcowr_loop

.Lcowr_done:
    slli t0, s0, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    sd   s2, 0(t1)
    sd   s3, 8(t1)
    call litmus_barrier
    bnez s0, .Lcorw_start

    li   t2, 0
    li   t3, 0
    li   t4, 0
    li   t5, NUM_HARTS
1:  slli t0, t4, 6
    li   t1, SHM_PER_HART
    add  t1, t1, t0
    ld   a4, 0(t1)
    ld   a5, 8(t1)
    add  t2, t2, a4
    add  t3, t3, a5
    addi t4, t4, 1
    bltu t4, t5, 1b
    bnez t2, litmus_fail
    la   a0, msg_cowr_prefix
    mv   a1, t2
    mv   a2, t3
    call print_litmus_line

    /* =========================================================================
     * TEST 7: CoRW (Read-Write Coherence)
     *   A: ld r0, (X); fence r, w; sd 2, (X)
     *   B: sd 1, (X); fence rw, r; ld r1, (X)
     *   Forbidden: r0 == 1 && final(X) != 2
     * ========================================================================= */
.Lcorw_start:
    li   s10, 1
    li   s2, 0                  /* forbid_corw */
    li   s3, 0                  /* obs_corw_r0_1 */
.Lcorw_loop:
    bgtu s10, s11, .Lcorw_done
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_R0
    sd   zero, 0(t0)
    li   t0, SHM_R1
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    addi t6, t5, 1
    remu t6, t6, t4
    beq  s0, t5, .Lcorw_h0
    beq  s0, t6, .Lcorw_h1
    j    .Lcorw_chk

.Lcorw_h0:
    li   t0, SHM_X
    ld   t1, 0(t0)
    fence r, w
    li   t2, 2
    sd   t2, 0(t0)
    li   t3, SHM_R0
    sd   t1, 0(t3)
    j    .Lcorw_chk

.Lcorw_h1:
    li   t0, SHM_X
    li   t2, 1
    sd   t2, 0(t0)
    fence rw, r
    ld   t1, 0(t0)
    li   t3, SHM_R1
    sd   t1, 0(t3)

.Lcorw_chk:
    call litmus_barrier
    bnez s0, .Lcorw_next
    li   t0, SHM_R0
    ld   a4, 0(t0)
    li   t0, SHM_X
    ld   a5, 0(t0)
    li   t1, 1
    bne  a4, t1, .Lcorw_next
    addi s3, s3, 1
    li   t2, 2
    beq  a5, t2, .Lcorw_next
    addi s2, s2, 1              /* FORBIDDEN: A read 1 before writing 2, yet final != 2 */

.Lcorw_next:
    addi s10, s10, 1
    j    .Lcorw_loop

.Lcorw_done:
    bnez s0, .Lcoww_start
    bnez s2, litmus_fail
    la   a0, msg_corw_prefix
    mv   a1, s2
    mv   a2, s3
    call print_litmus_line

    /* =========================================================================
     * TEST 8: CoWW (Write-Write Coherence: Convergence + 2W vs 2R Ordering)
     * ========================================================================= */
.Lcoww_start:
    li   s10, 1
    li   s2, 0                  /* forbid_coww */
    li   s3, 0                  /* obs_coww_rounds */
.Lcoww_loop:
    bgtu s10, s11, .Lcoww_done
    /* Part A: Multi-hart concurrent stores to SHM_X -> all harts must converge on same value */
    bnez s0, 1f
    li   t0, SHM_X
    sd   zero, 0(t0)
    fence rw, rw
1:  call litmus_barrier
    call jitter_delay

    addi t0, s0, 1
    slli t0, t0, 16
    or   t0, t0, s10
    li   t1, SHM_X
    sd   t0, 0(t1)
    fence w, w
    addi t0, t0, 0x100
    sd   t0, 0(t1)
    fence rw, rw
    call litmus_barrier

    li   t1, SHM_X
    ld   t2, 0(t1)
    slli t3, s0, 6
    li   t4, SHM_PER_HART
    add  t4, t4, t3
    sd   t2, 0(t4)
    call litmus_barrier

    bnez s0, .Lcoww_partb
    li   t4, SHM_PER_HART
    ld   a4, 0(t4)
    beqz a4, 2f
    li   t5, 1
    li   t6, NUM_HARTS
3:  slli t3, t5, 6
    add  t0, t4, t3
    ld   a5, 0(t0)
    bne  a5, a4, 2f             /* split view across harts -> FORBIDDEN */
    addi t5, t5, 1
    bltu t5, t6, 3b
    j    .Lcoww_partb
2:  addi s2, s2, 1

.Lcoww_partb:
    /* Part B: Writer writes 1 then 2 (fence w,w); Reader reads a then b (fence r,r) -> !(a==2 && b==1) */
    bnez s0, 4f
    li   t0, SHM_X
    sd   zero, 0(t0)
    li   t0, SHM_R0
    sd   zero, 0(t0)
    li   t0, SHM_R1
    sd   zero, 0(t0)
    fence rw, rw
4:  call litmus_barrier
    call jitter_delay

    li   t4, NUM_HARTS
    remu t5, s10, t4
    addi t6, t5, 1
    remu t6, t6, t4
    beq  s0, t5, .Lcoww_wr
    beq  s0, t6, .Lcoww_rd
    j    .Lcoww_bchk

.Lcoww_wr:
    li   t0, SHM_X
    li   t1, 1
    sd   t1, 0(t0)
    fence w, w
    li   t1, 2
    sd   t1, 0(t0)
    j    .Lcoww_bchk

.Lcoww_rd:
    li   t0, SHM_X
    ld   a4, 0(t0)
    fence r, r
    ld   a5, 0(t0)
    li   t1, SHM_R0
    sd   a4, 0(t1)
    li   t1, SHM_R1
    sd   a5, 0(t1)

.Lcoww_bchk:
    call litmus_barrier
    bnez s0, .Lcoww_next
    li   t0, SHM_R0
    ld   a4, 0(t0)
    li   t0, SHM_R1
    ld   a5, 0(t0)
    li   t1, 2
    bne  a4, t1, 5f
    li   t1, 1
    bne  a5, t1, 5f
    addi s2, s2, 1              /* FORBIDDEN a==2 && b==1 */
    j    .Lcoww_next
5:  addi s3, s3, 1

.Lcoww_next:
    addi s10, s10, 1
    j    .Lcoww_loop

.Lcoww_done:
    bnez s0, .Lfinal_sync
    bnez s2, litmus_fail
    la   a0, msg_coww_prefix
    mv   a1, s2
    mv   a2, s3
    call print_litmus_line

    la   a0, msg_all_pass
    call uart_puts

.Lfinal_sync:
    call litmus_barrier
.Lhalt_wfi:
    wfi
    j    .Lhalt_wfi

litmus_fail:
    la   a0, msg_fail
    call uart_puts
    j    .Lhalt_wfi

/* Sense-free monotonic atomic barrier using s7 (epoch) and s8 (SHM_BAR_CNT) */
litmus_barrier:
    addi s7, s7, 1
    li   t0, NUM_HARTS
    mul  t0, s7, t0
    li   t1, 1
    amoadd.d.aqrl zero, t1, 0(s8)
1:  ld   t2, 0(s8)
    bltu t2, t0, 1b
    fence r, rw
    ret

/* Xorshift64 PRNG jitter (0..15 cycles) in s9 */
jitter_delay:
    slli t0, s9, 13
    xor  s9, s9, t0
    srli t0, s9, 7
    xor  s9, s9, t0
    slli t0, s9, 17
    xor  s9, s9, t0
    andi t0, s9, 0xF
    beqz t0, 2f
1:  addi t0, t0, -1
    bnez t0, 1b
2:  ret

/* print_litmus_line(a0=prefix_str, a1=forbid_cnt, a2=obs_cnt) */
print_litmus_line:
    addi sp, sp, -32
    sd   ra, 0(sp)
    sd   s1, 8(sp)
    sd   s2, 16(sp)
    mv   s1, a1
    mv   s2, a2
    call uart_puts
    mv   a0, s1
    call uart_putdec
    la   a0, msg_obs_mid
    call uart_puts
    mv   a0, s2
    call uart_putdec
    la   a0, msg_nl
    call uart_puts
    ld   ra, 0(sp)
    ld   s1, 8(sp)
    ld   s2, 16(sp)
    addi sp, sp, 32
    ret

uart_puts:
    li   t1, UART_THR
1:  lbu  t0, 0(a0)
    beqz t0, 2f
    sb   t0, 0(t1)
    addi a0, a0, 1
    j    1b
2:  ret

/* Prints unsigned 64-bit decimal in a0 */
uart_putdec:
    addi sp, sp, -32
    li   t0, 0                  /* digit count */
    li   t1, 10
    li   t2, UART_THR
    bnez a0, 1f
    li   t3, '0'
    sb   t3, 0(t2)
    addi sp, sp, 32
    ret
1:  remu t3, a0, t1
    divu a0, a0, t1
    addi t3, t3, '0'
    add  t4, sp, t0
    sb   t3, 0(t4)
    addi t0, t0, 1
    bnez a0, 1b
2:  addi t0, t0, -1
    add  t4, sp, t0
    lbu  t3, 0(t4)
    sb   t3, 0(t2)
    bnez t0, 2b
    addi sp, sp, 32
    ret

    .align 4
m_trap_entry:
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

    .section .rodata
msg_mp_prefix:      .asciz "[LITMUS] MP iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_mp_ctrl_prefix: .asciz "[LITMUS] MP_CTRL iters=" LITMUS_STR(LITMUS_ITERS) " reordered="
msg_sb_prefix:      .asciz "[LITMUS] SB iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_lb_prefix:      .asciz "[LITMUS] LB iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_iriw_prefix:    .asciz "[LITMUS] IRIW iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_corr_prefix:    .asciz "[LITMUS] CoRR iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_cowr_prefix:    .asciz "[LITMUS] CoWR iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_corw_prefix:    .asciz "[LITMUS] CoRW iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_coww_prefix:    .asciz "[LITMUS] CoWW iters=" LITMUS_STR(LITMUS_ITERS) " forbidden="
msg_obs_mid:        .asciz " observed="
msg_nl:             .asciz "\n"
msg_all_pass:       .asciz "[LITMUS_ALL_PASS]\n"
msg_fail:           .asciz "[LITMUS_FAIL]\n"
