# Slice-0 RV64I integer ALU contract

`fursoy_s0_int_alu` is combinational decode/execute logic for the RV64I
`LUI`, `AUIPC`, `OP-IMM` and `OP` encodings. It accepts supplied register values and emits
the data needed by a later in-order retirement stage: valid, PC, instruction,
destination-register write intent and result.

It supports ADD/SUB, signed and unsigned comparisons, logical operations and
all 64-bit variable/immediate shifts. Shift amounts use six bits as RV64I
requires. `rd=x0` produces an otherwise valid retirement but suppresses the
physical register-file write.

RV64I word operations ADDIW/SLLIW/SRLIW/SRAIW and
ADDW/SUBW/SLLW/SRLW/SRAW operate on 32-bit values and sign-extend every result
to XLEN. Their shift amount is restricted to five bits.

Unsupported opcodes or funct combinations assert `illegal_o` when the input is
valid and do not retire. The surrounding core will turn this indication into
the Slice-0 illegal-instruction trap; this block does not own trap CSRs.
