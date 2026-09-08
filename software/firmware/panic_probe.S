/* Probe to verify deterministic handling of unexpected M-mode traps (Scenario 39).
 * Sets mtvec to sbi_trap_entry, then executes unimp in M-mode.
 */
    .option norvc
    .option norelax
    .section .text.init,"ax",@progbits
    .globl _start
_start:
    la sp, __stack_top
    csrw mscratch, sp
    la t0, sbi_trap_entry
    csrw mtvec, t0

    # Execute undefined instruction to trigger illegal instruction exception (mcause 2) in M-mode
    .word 0x00000000

    # Unreachable
1:  wfi
    j 1b
