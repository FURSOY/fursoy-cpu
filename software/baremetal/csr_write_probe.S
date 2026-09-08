    .option norvc
    .section .text,"ax",@progbits
    .globl smoke_main, csr_write_probe
smoke_main:
csr_write_probe:
    csrrw zero, cycle, zero
    li a0, 4
    ret
