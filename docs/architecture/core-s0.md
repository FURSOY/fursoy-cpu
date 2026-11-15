# Initial End-to-End Slice-0 Core Contract

`fursoy_s0_core` is an in-order DUT slice that fetches, executes, and commits one instruction at a time. The fetch response is consumed for instructions recognized by the RV64I `OP-IMM`/`OP` ALU or control-flow decoder. ALU instructions advance the PC by four bytes; branches/JAL/JALR select the computed target, and JAL/JALR write the link value to the register file.

The commit trace consists of `commit_valid`, PC, instruction word, destination register write intent, and write data. For `x0`, a valid ALU instruction commits with register write intent disabled; entry `x0` in the register file remains zero.

An unrecognized encoding, M-mode `ECALL`, or `EBREAK` asserts `trap_valid`, and the fetch response is consumed on the same clock edge. Trap entry sets `mepc = PC`, sets `mcause = 2` with zero-extended instruction in `mtval` for illegal instructions, `mcause = 11` for `ECALL`, and `mcause = 3` for `EBREAK` (with `mtval = 0` for both). It applies `MPIE <- MIE`, `MIE <- 0`, `MPP <- M`, and redirects PC to `mtvec`.
`MRET` commits in M-mode, returns PC to `mepc`, applies `MIE <- MPIE`, `MPIE <- 1`, and preserves `MPP <- M` per M-only WARL rules; there is no transition to U-mode. Normal Slice-0 reset initializes `mstatus = 0x1800` and `mie = mtvec = mepc = mcause = mtval = 0`. `RESET_MTVEC` is parameterized strictly for verification and does not alter the production reset contract.

The load/store decoder and a single-outstanding LSU port are connected to the core. Fetch stalls while an LSU transaction is in flight; stores commit on request acceptance, and loads commit on response acceptance. Data memory responses are right-aligned according to the requested width. This version does not yet include data caches or multiple outstanding memory operations.

A successful store request handshake commits at request time; a store error on that same handshake terminates the instruction with a `mcause = 7` trap. Loads always complete on response (whether success or error); an error response raises `mcause = 5`. For both access faults, `mepc` points to the faulting instruction and `mtval` holds the effective address; the destination register and commit trace are not updated. Detailed handshake and reset rules are documented in `lsu-s0.md`.

In the ordered, single-outstanding LSU, `FENCE` commits after any prior memory transaction completes. `FENCE.I` additionally generates a `fence_i_valid_o` event. Slice-0 has no I-cache; a future I-cache will turn this event into a handshake that stalls until invalidation completes.

The Zicsr path handles `mstatus`, `mie`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`, and the read-only `cycle` CSR. On CSR writes, the core applies Slice-0 WARL masks; accesses to read-only or undefined CSRs take an illegal-instruction trap.

An instruction-memory error response is neither decoded nor committed. For the PC held with the request, the core sets `mcause = 1`, `mepc = PC`, and `mtval = PC`, and jumps directly to `mtvec`. Thus, even if the error response data bits happen to encode a valid instruction, no architectural side effects can occur.
