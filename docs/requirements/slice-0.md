# Slice-0 Architectural Contract

Status: Draft 0.1. This is the contract for the initial bare-metal test platform; it is not the final SoC reset behavior or an RVA23 compliance claim.

## Initial Reset State

| Field | Slice-0 Value | Description |
|---|---|---|
| Hart | `0` | Single hart |
| PC | `0x8000_0000` | `_start` address |
| Privilege | M-mode | S/U/H disabled |
| `mstatus` | `MIE=0`, `MPIE=0`, `MPP=3` | Resets into M-mode; MXL and other fields covered in sub-table |
| `mie` | `0x0` | Interrupt sources disabled |
| `mtvec` | `0x0` | Written first by startup code |
| `mepc`, `mcause`, `mtval` | `0x0` | Platform reset value prior to first trap |
| RAM | `0x8000_0000`–`0x8001_ffff` | Readable/writable/executable per test memory map |
| Interrupts | None | No external/software/timer interrupts injected during Slice-0 tests |

`mhartid = 0` is assumed. Identity CSRs (`mvendorid`, `marchid`, `mimpid`) are not tested in this slice and production IDs are not assigned yet. `misa` and PMP definitions belong to subsequent slices. Unimplemented standard CSRs or opcodes must raise an illegal-instruction trap; this behavior is recommended in the target profile as well.

## Instructions Used and Exact Behavior

| Group | Encoding Family | Slice-0 Rule | Initial Test |
|---|---|---|---|
| Integer | `LUI`, `AUIPC`, `ADDI`, `ADD`, `SUB`, `BGEU`, `BNE`, `JAL`, `JALR` | XLEN=64; result mod 2^64; taken branch jumps to target PC, untaken advances to PC+4 | ALU/branch boundaries, `ra` and PC traces |
| Load/Store | `LD`, `SD` | 8-byte aligned RAM access; `LD` loads 64 bits, `SD` writes 64 bits | BSS zeroing, array read/write |
| CSR | `CSRRW`, `CSRRS`, `CSRRC`, `CSRWI`/`CSRRSI`/`CSRRCI` | `rd=x0` suppresses read side effects; `rs1=x0` or `zimm=0` suppresses write side effects | Every suppression combination and permission rejection |
| System | `ECALL`, `MRET` | M-mode `ECALL`: `mcause=11`, `mepc=faulting PC`, `mtval=0`; `MRET` returns per prior `MIE`/`MPIE`/`MPP` rules | Single `ECALL` -> handler -> `mepc+4` -> `MRET` |
| Fences | `FENCE`, `FENCE.I` | In single-hart RAM, `FENCE` does not alter architectural state; `FENCE.I` makes prior instruction writes visible to subsequent fetch | Self-modifying code test |
| Faults | Illegal opcode / invalid CSR | `mcause=2`; `mepc=faulting PC`; `mtval=faulting instruction`; no younger architectural write becomes visible | Known illegal 32-bit encoding |

M-only `MRET` applies `MIE <- MPIE`, `MPIE <- 1`, and leaves `MPP = M` as the only supported WARL value. This contract does not include S/U returns; lower privilege modes are introduced in a later architectural milestone.

## Trap Priority and Visibility

If an instruction triggers an access fault, neither its destination register, store, CSR write, nor sequential next-PC update becomes visible. Upon trap entry, `mepc` holds the faulting instruction address. Slice-0 has no concurrent interrupts; exception and interrupt priority arbitration is specified in subsequent platform contracts. RTL emits an architectural commit-order trace, which the verifier cross-checks against the Spike reference.

## Test Bindings

| ID | Precondition | Expected Outcome | Evidence Status |
|---|---|---|---|
| `S0-BOOT` | Reset state | `_start` reached in M-mode with expected PC and CSR reset state | Passed on Spike; DUT planned |
| `S0-ECALL` | `mtvec=trap_handler` | `mcause=11`, `mepc=ecall_probe`, `mtval=0`, handler counter=1 | Passed on Spike; DUT planned |
| `S0-MEM` | BSS and RAM | 100 words summed from `1…100`, total `5050` | Passed on Spike; DUT planned |
| `S0-CSR` | M-mode | CSR read/write suppression and illegal CSR trap behavior | Write to `cycle` and `mscratch` suppression passed on Spike; DUT planned |
| `S0-ILL` | Illegal 32-bit instruction | `cause=2`, exact `mepc`/`mtval`, no visible younger writes | Passed on Spike; DUT planned |
| `S0-FI` | Code modification in RAM | New instruction fetched after `FENCE.I` | Passed on Spike; DUT planned |

Spike results validate architectural `FENCE.I` ordering for self-modifying code. They do not validate Fursoy's future I-cache invalidation implementation, which is verified separately on the I-cache-equipped DUT.

References: [RISC-V Unprivileged ISA](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html), [Privileged ISA](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html).
Spike reference flags for test tooling: `--isa=RV64I_Zicsr_Zifencei --priv=m`, single 128 KiB RAM region. Spike passes are not proof of Fursoy RTL conformance.
