# Slice-0 Zicsr contract

The first CSR block implements CSRRW/CSRRS/CSRRC and immediate variants for
`mstatus`, `mie`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`, and read-only
`cycle`. Zero source suppression applies to CSRRS/CSRRC; CSRRW still writes a
zero source. Writes to `cycle` and accesses to unknown CSRs are illegal.

The core applies WARL masks when committing writes: only MIE/MPIE/MPP in
`mstatus`, MSIE/MTIE/MEIE in `mie`, supported direct/vectored modes in `mtvec`,
and four-byte alignment in `mepc`. This is the Slice-0 machine-mode subset, not
the complete RVA23 CSR surface.

Because Slice-0 implements M-mode only, `mstatus.MPP` has the sole WARL value M:
all CSR writes coerce it to `2'b11`, trap entry writes M, and `mret` leaves it M
while applying `MIE <- MPIE` and `MPIE <- 1`. No transition to U-mode occurs.
`mip` and `cycle` are read-only; write intent to either is illegal, while
CSRRS/CSRRC and their immediate forms with a zero source remain legal reads.
For register CSRRS/CSRRC, "zero source" means the encoded register is `x0`;
an encoded nonzero `rs1` has write intent even when that register currently
contains zero. Immediate CSRRSI/CSRRCI suppression analogously depends on
encoded `zimm=0`.
Reserved SYSTEM/CSR function encodings are illegal and cannot write `rd` or CSR
state. `mscratch`, `mcause`, and `mtval` retain all written bits; `mie` retains
only `0x888`, `mepc` clears bits 1:0, and `mtvec` retains an aligned base plus
Direct/Vectored mode, coercing reserved modes to Direct.
