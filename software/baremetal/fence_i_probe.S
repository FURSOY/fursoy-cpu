.option norvc
.option norelax

.section .text,"ax",@progbits
.globl smoke_main, fence_i_probe

smoke_main:
fence_i_probe:
    mv s0, ra
    la t0, patch_site
    li t1, 0x00700513          # addi a0, zero, 7
    sw t1, 0(t0)
    fence.i
    jalr ra, t0, 0

after_patch:
    li t1, 7
    bne a0, t1, fail
    li a0, 0
    mv ra, s0
    ret

fail:
    li a0, 7
    mv ra, s0
    ret

.balign 4
patch_site:
    .word 0x00000013           # nop; replaced before execution
    ret
