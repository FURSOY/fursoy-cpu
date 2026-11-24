    .section .text.init
    .globl _start
    .align 4
_start:
    /* Enable FPU (mstatus.FS = Initial, 0x2000) and clear fcsr */
    li      t0, 0x2000
    csrs    mstatus, t0
    fscsr   zero

    /* Install M-mode trap handler */
    la      t0, bench_trap_entry
    csrw    mtvec, t0

    /* Disable interrupts */
    csrw    mie, zero
    csrci   mstatus, 0x8

    /* Per-hart 1 MiB stack: sp = __stack_top - mhartid * 0x100000 */
    csrr    s0, mhartid
    la      sp, __stack_top
    slli    t0, s0, 20
    sub     sp, sp, t0
    andi    sp, sp, -16

    /* Hart 0 zeroes .bss and releases secondary harts */
    bnez    s0, .Lsecondary_wait

    la      t0, __bss_start
    la      t1, __bss_end
.Lbss_loop:
    bgeu    t0, t1, .Lbss_done
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       .Lbss_loop
.Lbss_done:
    fence   w, w
    la      t0, bench_bss_ready
    li      t1, 1
    sw      t1, 0(t0)
    fence   rw, rw

    /* Call main(0, NULL) */
    li      a0, 0
    li      a1, 0
    call    main

    /* Report exit code and signal completion */
    call    bench_finish

.Lhalt:
    wfi
    j       .Lhalt

.Lsecondary_wait:
    la      t0, bench_bss_ready
1:  lw      t1, 0(t0)
    beqz    t1, 1b
    fence   r, rw

    mv      a0, s0
    call    bench_secondary_main
    j       .Lhalt

    .align 4
bench_trap_entry:
    /* Pass (hartid, mcause, mepc, mtval) to C diagnostic handler */
    csrr    a0, mhartid
    csrr    a1, mcause
    csrr    a2, mepc
    csrr    a3, mtval
    call    bench_trap_handler
2:  wfi
    j       2b

    .section .data
    .align 4
    .globl bench_bss_ready
bench_bss_ready:
    .word   0
