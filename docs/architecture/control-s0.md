# Slice-0 control-flow decode contract

`fursoy_s0_control` decodes RV64I conditional branches, `JAL` and `JALR`.
Branches yield `PC+4` when not taken; JAL/JALR return `PC+4` through `rd`.
JALR clears target bit zero as the ISA requires. Since this slice has no RVC,
any selected target not aligned to four bytes is reported separately instead
of being retired. The surrounding core must turn that condition into the
instruction-address-misaligned trap (`mcause=0`, `mtval=target`).
