    .option norvc
    .section .text,"ax",@progbits
    .globl smoke_main, illegal_probe
smoke_main:
illegal_probe:
    .word 0xffffffff
    li a0, 5
    ret
