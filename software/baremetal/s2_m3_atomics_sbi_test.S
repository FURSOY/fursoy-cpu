#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

#define SBI_EXT_BASE      0x10
#define SBI_EXT_TIME      0x54494D45
#define SBI_EXT_IPI       0x00735049
#define SBI_EXT_RFENCE    0x52464E43
#define SBI_EXT_HSM       0x0048534D
#define SBI_EXT_SRST      0x53525354
#define SBI_EXT_DBCN      0x4442434E

    .section .text.init
    .globl _start
    .globl _secondary_smode_entry

/* Hart 0 S-mode entry from SBI (a0=0, a1=dtb) */
_start:
    mv      s0, a0              /* s0 = hartid (0) */
    mv      s1, a1              /* s1 = dtb */
    li      s2, (1 << NUM_HARTS) - 1

    /* Clear BSS on Hart 0 before starting secondaries */
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:  fence   rw, rw

    /* Set Hart 0 stack & S-mode trap vector */
    la      sp, smode_stacks
    li      t0, 4096
    add     sp, sp, t0
    la      t0, _smode_trap_entry
    csrw    stvec, t0

    /* ----- TEST 1: SBI BASE Probe & HSM Bring-Up ----- */
    /* Probe BASE_GET_SPEC_VERSION */
    li      a7, SBI_EXT_BASE
    li      a6, 0
    ecall
    bnez    a0, .Lfail
    li      t0, 0x02000000
    bne     a1, t0, .Lfail

    /* Probe extensions: TIME, IPI, RFENCE, HSM, SRST, DBCN */
    li      t1, SBI_EXT_TIME
    jal     ra, .Lprobe_ext
    li      t1, SBI_EXT_IPI
    jal     ra, .Lprobe_ext
    li      t1, SBI_EXT_RFENCE
    jal     ra, .Lprobe_ext
    li      t1, SBI_EXT_HSM
    jal     ra, .Lprobe_ext
    li      t1, SBI_EXT_SRST
    jal     ra, .Lprobe_ext
    li      t1, SBI_EXT_DBCN
    jal     ra, .Lprobe_ext

    /* Verify Hart 0 is STARTED (0) and Hart 1 is STOPPED (1) */
    li      a7, SBI_EXT_HSM
    li      a6, 2
    li      a0, 0
    ecall
    bnez    a0, .Lfail
    bnez    a1, .Lfail

    li      a7, SBI_EXT_HSM
    li      a6, 2
    li      a0, 1
    ecall
    bnez    a0, .Lfail
    li      t0, 1
    bne     a1, t0, .Lfail

    /* Start secondary harts 1..NUM_HARTS-1 */
    li      s3, 1
    li      s4, NUM_HARTS
.Lstart_sec_loop:
    bge     s3, s4, .Lcommon_entry
    li      a7, SBI_EXT_HSM
    li      a6, 0               /* HART_START */
    mv      a0, s3
    la      a1, _secondary_smode_entry
    li      t0, 0xCAFE0000
    add     a2, t0, s3
    ecall
    bnez    a0, .Lfail
    addi    s3, s3, 1
    j       .Lstart_sec_loop

.Lprobe_ext:
    li      a7, SBI_EXT_BASE
    li      a6, 3
    mv      a0, t1
    ecall
    bnez    a0, .Lfail
    li      t0, 1
    bne     a1, t0, .Lfail
    ret

/* Secondary S-mode entry (a0=hartid, a1=opaque) */
_secondary_smode_entry:
    mv      s0, a0
    mv      s1, a1
    li      s2, (1 << NUM_HARTS) - 1

    li      t0, 0xCAFE0000
    add     t0, t0, s0
    bne     s1, t0, .Lfail

    /* Per-hart S-mode stack: smode_stacks + (hartid + 1) * 4096 */
    la      sp, smode_stacks
    addi    t0, s0, 1
    slli    t0, t0, 12
    add     sp, sp, t0
    la      t0, _smode_trap_entry
    csrw    stvec, t0

.Lcommon_entry:
    li      a0, 0
    call    s_barrier
    bnez    s0, .Lt2_begin
    la      a0, msg_t1
    li      a1, 10
    call    sbi_puts

    /* ----- TEST 2: Remote Reservation Inval + Contended LR/SC Spinlock & Counters ----- */
.Lt2_begin:
    li      a0, 1
    call    s_barrier

    /* 2A. Cross-hart remote snoop reservation invalidation check */
    beqz    s0, .Lt2_neg_h0
    li      t0, 1
    beq     s0, t0, .Lt2_neg_h1
    j       .Lt2_neg_done

.Lt2_neg_h0:
    la      t1, neg_sc_line
    lr.d    t2, 0(t1)
    la      t3, neg_flag_ready
    li      t4, 1
    fence   rw, w
    sd      t4, 0(t3)
    la      t5, neg_flag_done
1:  ld      t6, 0(t5)
    beqz    t6, 1b
    fence   r, rw
    li      t4, 0x55AA
    sc.d    t0, t4, 0(t1)
    beqz    t0, .Lfail          /* SC MUST fail because Hart 1 snooped line */
    j       .Lt2_neg_done

.Lt2_neg_h1:
    la      t3, neg_flag_ready
1:  ld      t6, 0(t3)
    beqz    t6, 1b
    la      t1, neg_sc_line
    li      t4, 0x1122
    amoswap.d zero, t4, 0(t1)   /* Invalidates Hart 0's reservation */
    fence   rw, w
    la      t5, neg_flag_done
    li      t4, 1
    sd      t4, 0(t5)

.Lt2_neg_done:
    li      a0, 2
    call    s_barrier

    /* 2B. Contended LR.D/SC.D mutex + protected counter (50 iters/hart) */
    li      s3, 50
    la      s4, lrsc_lock
    la      s5, lrsc_cnt_d
.Lt2_lock_loop:
    beqz    s3, .Lt2_w_begin
.Lt2_acq:
    lr.d    t0, 0(s4)
    bnez    t0, .Lt2_acq
    li      t1, 1
    sc.d    t2, t1, 0(s4)
    bnez    t2, .Lt2_acq
    fence   r, rw
    ld      t3, 0(s5)
    addi    t3, t3, 1
    sd      t3, 0(s5)
    fence   rw, w
    sd      zero, 0(s4)
    addi    s3, s3, -1
    j       .Lt2_lock_loop

    /* 2C. Direct contended LR.W/SC.W atomic counter (50 iters/hart) */
.Lt2_w_begin:
    li      s3, 50
    la      s5, lrsc_cnt_w
.Lt2_w_loop:
    beqz    s3, .Lt2_backoff_stress
.Lt2_w_try:
    lr.w    t0, 0(s5)
    addi    t1, t0, 1
    sc.w    t2, t1, 0(s5)
    bnez    t2, .Lt2_w_try
    addi    s3, s3, -1
    j       .Lt2_w_loop

    /* 2D. Deterministic 5x consecutive SC failures (triggering LFSR backoff) + hot tight contention */
.Lt2_backoff_stress:
    li      a0, 200
    call    s_barrier

    li      s3, 1
    li      s4, 6               /* 5 forced SC-fail rounds (streak 1..5 -> hits >= 3 LFSR backoff) */
    beqz    s0, .Lt2d_h0_loop
    li      t0, 1
    beq     s0, t0, .Lt2d_h1_loop
    j       .Lt2d_hot_join

.Lt2d_h0_loop:
    bge     s3, s4, .Lt2d_h0_post
    la      t1, backoff_sc_line
    lr.d    t2, 0(t1)
    la      t3, backoff_flag_ready
    fence   rw, w
    sd      s3, 0(t3)
    la      t5, backoff_flag_done
1:  ld      t6, 0(t5)
    bne     t6, s3, 1b
    fence   r, rw
    li      t4, 0xBEEF
    sc.d    t0, t4, 0(t1)
    beqz    t0, .Lfail          /* Must fail due to Hart 1 invalidation */
    addi    s3, s3, 1
    j       .Lt2d_h0_loop

.Lt2d_h0_post:
    /* Uncontested LR/SC after backoff streak must succeed cleanly without livelock */
    la      t1, backoff_sc_line
.Lt2d_post_try:
    lr.d    t2, 0(t1)
    li      t4, 0xCAFE
    sc.d    t0, t4, 0(t1)
    bnez    t0, .Lt2d_post_try
    j       .Lt2d_hot_join

.Lt2d_h1_loop:
    bge     s3, s4, .Lt2d_hot_join
    la      t3, backoff_flag_ready
1:  ld      t6, 0(t3)
    bne     t6, s3, 1b
    la      t1, backoff_sc_line
    addi    t4, s3, 0x100
    amoswap.d zero, t4, 0(t1)   /* Invalidates Hart 0 reservation each round */
    fence   rw, w
    la      t5, backoff_flag_done
    sd      s3, 0(t5)
    addi    s3, s3, 1
    j       .Lt2d_h1_loop

.Lt2d_hot_join:
    li      a0, 201
    call    s_barrier

    li      s3, 64
    la      s5, lrsc_hot_cnt
.Lt2d_hot_loop:
    beqz    s3, .Lt2_check
.Lt2d_hot_try:
    lr.d    t0, 0(s5)
    addi    t1, t0, 1
    sc.d    t2, t1, 0(s5)
    bnez    t2, .Lt2d_hot_try
    addi    s3, s3, -1
    j       .Lt2d_hot_loop

.Lt2_check:
    li      a0, 3
    call    s_barrier
    bnez    s0, .Lt3_begin
    li      t0, 50 * NUM_HARTS
    la      t1, lrsc_cnt_d
    ld      t2, 0(t1)
    bne     t2, t0, .Lfail
    la      t1, lrsc_cnt_w
    lw      t2, 0(t1)
    bne     t2, t0, .Lfail
    li      t0, 64 * NUM_HARTS
    la      t1, lrsc_hot_cnt
    ld      t2, 0(t1)
    bne     t2, t0, .Lfail
    la      a0, msg_t2
    li      a1, 11
    call    sbi_puts

    /* ----- TEST 3: Contended Mixed RV64A AMO Suite ----- */
.Lt3_begin:
    bnez    s0, .Lt3_wait_init
    la      t0, amo_and_w
    li      t1, 0xFF
    sw      t1, 0(t0)
    la      t0, amo_minu_w
    li      t1, 1000
    sw      t1, 0(t0)
    fence   rw, rw
.Lt3_wait_init:
    li      a0, 4
    call    s_barrier

    li      s3, 50
    li      s4, 50 * NUM_HARTS
    la      s5, amo_sum_d
    la      s6, amo_sum_w
.Lt3_amo_loop:
    beqz    s3, .Lt3_bitwise
    li      t0, 1
    amoadd.d t1, t0, 0(s5)
    bgeu    t1, s4, .Lfail
    amoadd.w t2, t0, 0(s6)
    bgeu    t2, s4, .Lfail
    addi    s3, s3, -1
    j       .Lt3_amo_loop

.Lt3_bitwise:
    /* amoor.d: set unique byte (0xA0 + hartid + 1) shifted by hartid*8 */
    li      t0, 0xA1
    add     t0, t0, s0
    slli    t1, s0, 3
    sll     t0, t0, t1
    la      t2, amo_or_d
    amoor.d zero, t0, 0(t2)

    /* amoand.w: clear bit s0 from 0xFF */
    li      t0, 1
    sll     t0, t0, s0
    not     t0, t0
    la      t2, amo_and_w
    amoand.w zero, t0, 0(t2)

    /* amomax.d: (hartid + 1) * 100 -> max == NUM_HARTS * 100 */
    addi    t0, s0, 1
    li      t1, 100
    mul     t0, t0, t1
    la      t2, amo_max_d
    amomax.d zero, t0, 0(t2)

    /* amominu.w: 1000 - hartid * 10 -> min == 1000 - (NUM_HARTS-1)*10 */
    li      t0, 10
    mul     t0, t0, s0
    li      t1, 1000
    sub     t0, t1, t0
    la      t2, amo_minu_w
    amominu.w zero, t0, 0(t2)

    li      a0, 5
    call    s_barrier
    bnez    s0, .Lt4_begin

    li      t0, 50 * NUM_HARTS
    la      t1, amo_sum_d
    ld      t2, 0(t1)
    bne     t2, t0, .Lfail
    la      t1, amo_sum_w
    lw      t2, 0(t1)
    bne     t2, t0, .Lfail

    /* Expected amo_or_d: byte i = 0xA1 + i for i=0..NUM_HARTS-1 */
    li      t3, 0
    li      t4, 0
.Lt3_exp_or:
    bge     t4, s4, .Lt3_chk_or
    j       .Lt3_or_ok
.Lt3_chk_or:
.Lt3_or_ok:
    li      t5, NUM_HARTS
    li      t4, 0
    li      t3, 0
1:  bge     t4, t5, 2f
    li      t0, 0xA1
    add     t0, t0, t4
    slli    t1, t4, 3
    sll     t0, t0, t1
    or      t3, t3, t0
    addi    t4, t4, 1
    j       1b
2:  la      t1, amo_or_d
    ld      t2, 0(t1)
    bne     t2, t3, .Lfail

    /* Expected amo_and_w = 0xFF & ~((1<<NUM_HARTS)-1) */
    not     t3, s2
    andi    t3, t3, 0xFF
    la      t1, amo_and_w
    lwu     t2, 0(t1)
    bne     t2, t3, .Lfail

    /* Expected amo_max_d = NUM_HARTS * 100 */
    li      t0, 100 * NUM_HARTS
    la      t1, amo_max_d
    ld      t2, 0(t1)
    bne     t2, t0, .Lfail

    /* Expected amo_minu_w = 1000 - (NUM_HARTS-1)*10 */
    li      t0, 1000 - ((NUM_HARTS - 1) * 10)
    la      t1, amo_minu_w
    lwu     t2, 0(t1)
    bne     t2, t0, .Lfail

    la      a0, msg_t3
    li      a1, 10
    call    sbi_puts

    /* ----- TEST 4: Cross-Hart MP and SB Litmus Tests with FENCE ----- */
.Lt4_begin:
    /* 4A. 40 rounds MP (Hart 0 -> Hart NUM_HARTS-1) */
    li      s3, 1
    li      s4, 41
    li      s5, 10              /* barrier slots 10..89 used for MP/SB? Better: reuse per-iter slots 10+i */
.Lmp_loop:
    bge     s3, s4, .Lsb_begin
    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    beqz    s0, .Lmp_prod
    li      t0, NUM_HARTS - 1
    beq     s0, t0, .Lmp_cons
    j       .Lmp_next

.Lmp_prod:
    la      t0, mp_payload
    li      t1, 0x12340000
    add     t1, t1, s3
    sd      t1, 0(t0)
    fence   rw, rw
    la      t2, mp_flag
    sd      s3, 0(t2)
    j       .Lmp_next

.Lmp_cons:
    la      t2, mp_flag
1:  ld      t3, 0(t2)
    bne     t3, s3, 1b
    fence   rw, rw
    la      t0, mp_payload
    ld      t4, 0(t0)
    li      t1, 0x12340000
    add     t1, t1, s3
    bne     t4, t1, .Lfail

.Lmp_next:
    addi    s3, s3, 1
    j       .Lmp_loop

    /* 4B. 40 rounds Store-Buffering SB (Hart 0 vs Hart 1) */
.Lsb_begin:
    li      s3, 1
    li      s4, 41
.Lsb_loop:
    bge     s3, s4, .Lt4_done
    bnez    s0, .Lsb_b1
    la      t0, sb_x
    sd      zero, 0(t0)
    la      t1, sb_y
    sd      zero, 0(t1)
    fence   rw, rw
.Lsb_b1:
    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    beqz    s0, .Lsb_h0
    li      t0, 1
    beq     s0, t0, .Lsb_h1
    j       .Lsb_b2

.Lsb_h0:
    la      t0, sb_x
    li      t2, 1
    sd      t2, 0(t0)
    fence   iorw, iorw
    la      t1, sb_y
    ld      t3, 0(t1)
    la      t4, sb_r0
    sd      t3, 0(t4)
    j       .Lsb_b2

.Lsb_h1:
    la      t1, sb_y
    li      t2, 1
    sd      t2, 0(t1)
    fence   iorw, iorw
    la      t0, sb_x
    ld      t3, 0(t0)
    la      t4, sb_r1
    sd      t3, 0(t4)

.Lsb_b2:
    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1
    bnez    s0, .Lsb_next
    la      t0, sb_r0
    ld      t1, 0(t0)
    la      t2, sb_r1
    ld      t3, 0(t2)
    or      t4, t1, t3
    beqz    t4, .Lfail          /* Forbidden: r0==0 && r1==0 */
.Lsb_next:
    addi    s3, s3, 1
    j       .Lsb_loop

.Lt4_done:
    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1
    bnez    s0, .Lt5_begin
    la      a0, msg_t4
    li      a1, 12
    call    sbi_puts

    /* ----- TEST 5: SBI sPI Ring, Simultaneous RFENCE, SBI TIME, HSM HART_STOP ----- */
.Lt5_begin:
    /* Enable S-mode software & timer interrupts */
    li      t0, (1 << 1) | (1 << 5)
    csrw    sie, t0
    csrsi   sstatus, 0x2        /* sstatus.SIE = 1 */

    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    /* Ring IPI: Hart 0 kicks Hart 1; each h kicks (h+1)%NUM_HARTS */
    bnez    s0, .Lipi_wait
    li      a7, SBI_EXT_IPI
    li      a6, 0
    li      a0, 2               /* mask bit 1 */
    li      a1, 0
    ecall
    bnez    a0, .Lfail

.Lipi_wait:
    la      t0, ipi_seen
    slli    t1, s0, 3
    add     t0, t0, t1
1:  ld      t2, 0(t0)
    beqz    t2, 1b

    beqz    s0, .Lipi_done      /* Hart 0 got the final return hop from N-1 */
    addi    t3, s0, 1
    li      t4, NUM_HARTS
    blt     t3, t4, 2f
    li      t3, 0
2:  li      t5, 1
    sll     a0, t5, t3
    li      a7, SBI_EXT_IPI
    li      a6, 0
    li      a1, 0
    ecall
    bnez    a0, .Lfail

.Lipi_done:
    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    /* Simultaneous RFENCE across ALL harts concurrently (3 rounds FENCE.I + SFENCE.VMA) */
    li      s3, 3
.Lrfence_loop:
    beqz    s3, .Lrfence_done
    li      a7, SBI_EXT_RFENCE
    li      a6, 0               /* REMOTE_FENCE_I */
    mv      a0, s2
    li      a1, 0
    ecall
    bnez    a0, .Lfail

    li      a7, SBI_EXT_RFENCE
    li      a6, 1               /* REMOTE_SFENCE_VMA */
    mv      a0, s2
    li      a1, 0
    li      a2, 0
    li      a3, -1
    ecall
    bnez    a0, .Lfail
    addi    s3, s3, -1
    j       .Lrfence_loop

.Lrfence_done:
    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    /* Hart 0 tests SBI_EXT_TIME */
    bnez    s0, .Lper_hart_pass
    csrr    a0, cycle
    addi    a0, a0, 300
    li      a7, SBI_EXT_TIME
    li      a6, 0
    ecall
    bnez    a0, .Lfail
    la      t0, timer_seen
1:  ld      t1, 0(t0)
    beqz    t1, 1b

.Lper_hart_pass:
    /* SSIP + STIP arrival during active LR/SC and AMO contention window */
    li      a0, 202
    call    s_barrier

    la      t0, ipi_seen
    slli    t1, s0, 3
    add     t0, t0, t1
    sd      zero, 0(t0)
    bnez    s0, 1f
    la      t0, timer_seen
    sd      zero, 0(t0)
1:  li      t0, (1 << 1) | (1 << 5)
    csrw    sie, t0
    fence   rw, rw

    li      a0, 203
    call    s_barrier

    bnez    s0, .Lirq_atomic_bar
    csrr    a0, cycle
    addi    a0, a0, 60
    li      a7, SBI_EXT_TIME
    li      a6, 0
    ecall
    bnez    a0, .Lfail

.Lirq_atomic_bar:
    li      a0, 204
    call    s_barrier

    li      s3, 80
    la      s4, irq_amo_sum
    la      s6, irq_lrsc_sum
.Lirq_atomic_loop:
    beqz    s3, .Lirq_atomic_wait
    li      t0, 1
    amoadd.d zero, t0, 0(s4)
1:  lr.d    t1, 0(s6)
    addi    t2, t1, 1
    sc.d    t3, t2, 0(s6)
    bnez    t3, 1b

    bnez    s0, .Lirq_atomic_next
    andi    t0, s3, 15
    bnez    t0, .Lirq_atomic_next
    li      a7, SBI_EXT_IPI
    li      a6, 0
    mv      a0, s2
    li      a1, 0
    ecall
    bnez    a0, .Lfail

.Lirq_atomic_next:
    addi    s3, s3, -1
    j       .Lirq_atomic_loop

.Lirq_atomic_wait:
    la      t0, ipi_seen
    slli    t1, s0, 3
    add     t0, t0, t1
1:  ld      t2, 0(t0)
    beqz    t2, 1b

    bnez    s0, .Lirq_atomic_done
    la      t0, timer_seen
2:  ld      t2, 0(t0)
    beqz    t2, 2b

.Lirq_atomic_done:
    li      a0, 205
    call    s_barrier
    bnez    s0, .Lirq_atomic_finish
    li      t0, 80 * NUM_HARTS
    la      t1, irq_amo_sum
    ld      t2, 0(t1)
    bne     t2, t0, .Lfail
    la      t1, irq_lrsc_sum
    ld      t2, 0(t1)
    bne     t2, t0, .Lfail

.Lirq_atomic_finish:
    li      a0, 206
    call    s_barrier

    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    /* Disable SIE cleanly before exit/HART_STOP */
    csrci   sstatus, 0x2

    /* Print per-hart pass marker H<hartid>_PASS\n */
    la      t0, h_pass_msgs
    slli    t1, s0, 3           /* 8 bytes stride per string */
    add     a0, t0, t1
    li      a1, 8
    call    sbi_puts

    mv      a0, s5
    call    s_barrier
    addi    s5, s5, 1

    beqz    s0, .Lh0_wait_stops

    /* Secondary hart stops via SBI HSM HART_STOP */
    li      a7, SBI_EXT_HSM
    li      a6, 1
    ecall
    j       .Lfail              /* Must never return from HART_STOP */

.Lh0_wait_stops:
    li      s3, 1
    li      s4, NUM_HARTS
.Lchk_stop_loop:
    bge     s3, s4, .Lall_done
1:  li      a7, SBI_EXT_HSM
    li      a6, 2
    mv      a0, s3
    ecall
    bnez    a0, .Lfail
    li      t0, 1               /* SBI_HSM_STATE_STOPPED */
    bne     a1, t0, 1b
    addi    s3, s3, 1
    j       .Lchk_stop_loop

.Lall_done:
    la      a0, msg_t5
    li      a1, 10
    call    sbi_puts

    /* Re-start secondary harts so SBI_EXT_SRST runs while all harts are actively online */
    la      t0, srst_online_mask
    sd      zero, 0(t0)
    fence   rw, rw

    li      s3, 1
    li      s4, NUM_HARTS
.Lrestart_sec_loop:
    bge     s3, s4, .Lwait_sec_online
    li      a7, SBI_EXT_HSM
    li      a6, 0               /* HART_START */
    mv      a0, s3
    la      a1, _secondary_srst_online
    li      a2, 0
    ecall
    bnez    a0, .Lfail
    addi    s3, s3, 1
    j       .Lrestart_sec_loop

.Lwait_sec_online:
    li      t0, ((1 << NUM_HARTS) - 1) & ~1
    la      t1, srst_online_mask
1:  ld      t2, 0(t1)
    bne     t2, t0, 1b
    fence   r, rw

    la      a0, msg_all_pass
    li      a1, 15
    call    sbi_puts

    li      a7, SBI_EXT_SRST
    li      a6, 0
    li      a0, 0
    li      a1, 0
    ecall
    j       .Lidle_forever

_secondary_srst_online:
    li      t0, 1
    sll     t0, t0, a0
    la      t1, srst_online_mask
    amoor.d zero, t0, 0(t1)
.Lsrst_spin_forever:
    nop
    j       .Lsrst_spin_forever

.Lfail:
    la      a0, msg_fail
    li      a1, 10
    call    sbi_puts
.Lidle_forever:
    wfi
    j       .Lidle_forever

/* Blocking unique-slot barrier(a0 = slot_idx) */
s_barrier:
    la      t0, barrier_arr
    slli    t1, a0, 3
    add     t0, t0, t1
    li      t2, 1
    amoadd.d.aqrl zero, t2, 0(t0)
    li      t3, NUM_HARTS
1:  ld      t4, 0(t0)
    bltu    t4, t3, 1b
    fence   r, rw
    ret

/* Print string via SBI_EXT_DBCN FID=0 (a0=paddr, a1=len) */
sbi_puts:
    mv      t0, a0
    mv      a0, a1
    mv      a1, t0
    li      a2, 0
    li      a7, SBI_EXT_DBCN
    li      a6, 0
    ecall
    ret

/* S-mode Trap Handler for IPI (scause=0x800...0001) & Timer (scause=0x800...0005) */
    .align 4
_smode_trap_entry:
    addi    sp, sp, -64
    sd      t0,  0*8(sp)
    sd      t1,  1*8(sp)
    sd      t2,  2*8(sp)
    sd      t3,  3*8(sp)
    sd      t4,  4*8(sp)
    sd      a0,  5*8(sp)

    csrr    t0, scause
    bgez    t0, .Lstrap_unexpected
    li      t1, 0xFF
    and     t0, t0, t1
    li      t2, 1
    beq     t0, t2, .Lstrap_ssip
    li      t2, 5
    beq     t0, t2, .Lstrap_stip
    j       .Lstrap_unexpected

.Lstrap_ssip:
    li      t1, 2
    csrc    sip, t1             /* Clear SSIP */
    la      t2, ipi_seen
    slli    t3, s0, 3
    add     t2, t2, t3
    li      t4, 1
    sd      t4, 0(t2)
    fence   rw, w
    j       .Lstrap_ret

.Lstrap_stip:
    li      t1, (1 << 5)
    csrc    sie, t1             /* Mask STIE after timer interrupt fires */
    la      t2, timer_seen
    li      t4, 1
    sd      t4, 0(t2)
    fence   rw, w
    j       .Lstrap_ret

.Lstrap_unexpected:
    csrr    t0, sepc
    addi    t0, t0, 4
    csrw    sepc, t0

.Lstrap_ret:
    ld      t0,  0*8(sp)
    ld      t1,  1*8(sp)
    ld      t2,  2*8(sp)
    ld      t3,  3*8(sp)
    ld      t4,  4*8(sp)
    ld      a0,  5*8(sp)
    addi    sp, sp, 64
    sret

    .section .rodata
msg_t1:       .ascii "T1_HSM_OK\n"
msg_t2:       .ascii "T2_LRSC_OK\n"
msg_t3:       .ascii "T3_AMO_OK\n"
msg_t4:       .ascii "T4_FENCE_OK\n"
msg_t5:       .ascii "T5_SBI_OK\n"
msg_all_pass: .ascii "S2_M3_ALL_PASS\n"
msg_fail:     .ascii "S2_M3FAIL\n"

    .align 3
h_pass_msgs:
    .ascii "H0_PASS\n"
    .ascii "H1_PASS\n"
    .ascii "H2_PASS\n"
    .ascii "H3_PASS\n"

    .section .bss
    .align 6
neg_sc_line:    .space 64
neg_flag_ready: .space 64
neg_flag_done:  .space 64
backoff_sc_line:    .space 64
backoff_flag_ready: .space 64
backoff_flag_done:  .space 64
lrsc_lock:      .space 64
lrsc_cnt_d:     .space 64
lrsc_cnt_w:     .space 64
lrsc_hot_cnt:   .space 64
amo_sum_d:      .space 64
amo_sum_w:      .space 64
amo_or_d:       .space 64
amo_and_w:      .space 64
amo_max_d:      .space 64
amo_minu_w:     .space 64
mp_payload:     .space 64
mp_flag:        .space 64
sb_x:           .space 64
sb_y:           .space 64
sb_r0:          .space 64
sb_r1:          .space 64
ipi_seen:       .space 64
timer_seen:     .space 64
irq_amo_sum:    .space 64
irq_lrsc_sum:   .space 64
srst_online_mask: .space 64
barrier_arr:    .space 2048
    .align 12
smode_stacks:   .space (NUM_HARTS * 4096)
