# ISA/Platform Contract — Draft 0.2

Date: September 6, 2026. Initial traceable requirements breakdown based on W02 scope.
This document is not a compliance statement or a claim of implemented features.

ECC/RAS, DMA isolation, and sustained load targets are tracked under platform rows (`SRV-001…005`).

## Target and Source Priority

The working ISA is RISC-V; the long-term profile target is RVA23U64 + RVA23S64 v1.0 (2024-10-17).
The user, supervisor, and Sha components of the profile are listed in the machine-readable inventory. The normative source for the profile is [RVA23 v1.0](https://docs.riscv.org/reference/rva23/v1.0/_attachments/rva23-profile.pdf), specifically printed pages 4–9. Technical extension names are preserved verbatim.

For instruction/CSR details, [ISA Volume I](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html) and [Volume II](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html) (20260120 collection) serve as references. The collection date is not the extension version. RVA23's Ss1p13 baseline is preserved; additional features in newer collections are not automatically mandatory. As each instruction/CSR sub-spec is authored, the corresponding extension version is locked; any discrepancies trigger a decision record.

## Initial Agreed Verification Slice

`slice-0`: Bare-metal test environment for RV64I + Zicsr + Zifencei; little-endian, XLEN=64, single hart, M-mode, unpaged test RAM. Target compile flags: `-march=rv64i_zicsr_zifencei -mabi=lp64`; libc is not required initially.
The first ELF was compiled and layout-checked with these flags. See [Test Memory Map](../architecture/baremetal-v1.md) v1. Program completion does not pass by timeout; an explicit result signature and expected trap metadata are verified.

This slice is not a Linux-capable or RVA23-compliant product. The initial test harness exists to validate the architectural result/commit checker reused by later out-of-order core stages. It does not restrict the final ISA or in-order/OoO microarchitecture decisions.

Initial breakdown order: integer registers/PC and RV64I instructions; illegal opcodes and `ECALL`/`EBREAK`; CSR access permissions and trap/return; RAM/fence; then M/A/C extensions and supervisor memory management. Each group is decomposed into opcode/CSR sub-items prior to RTL.

## Long-Term Platform Decisions

| Topic | Working Decision | Open Details |
|---|---|---|
| Modes | M, S, U; planned H/HS/VS/VU support | CSR WARL and delegation tables |
| Addressing | Svbare/Sv39 mandatory target; Sv48 candidate for evaluation | Physical address width, ASID/VMID bits |
| Memory Ordering | RVWMO and atomic forward-progress guarantees | Litmus runner, multi-hart model |
| Data Endianness | Little-endian, XLEN=64 | Memory map and reset address |
| Vector | VLEN=256 candidate, physical lane width separate | ELEN/SEW, physical RF, verification tool alignment |
| RAM/MMIO | Separate PMA/permission policy | RAM ranges, device access widths |
| Interrupts | Software/timer/external paths, planned Sstc | AIA/controller choice, address map |
| Protection | PMP and translation permission checks | PMP entry count/granularity/lock behavior |
| Boot/Debug | Boot ROM, SBI path, debug access | SBI/debug version and test platform |
| Optional Extensions | None committed as production targets yet | Sv48/Svadu/crypto/BF16 etc. decided separately |

If Sv48 is selected, guest translation impact will also be evaluated. Misaligned access support does not imply that every misaligned access is atomic. Data-independent timing rules do not turn into an assumption that all instructions are fixed-latency. Execution latencies are not locked until Zkt/Zvkt instruction-level scope is finalized.

## Traceability and Statuses

`isa-platform.csv` columns: stable requirement ID, covered feature names, source, target gate, owning design section, and planned verification method.
The CSV operates at the feature-group level rather than an exhaustive opcode/CSR/PMA sub-rule catalog. `rva23-inventory.json` separately tracks directly mandatory profile names and Sha sub-components. Full transitive expansion of dependent extensions is not included yet.

All baseline rows start as `planned`; `verification` represents a test plan rather than test results, and `evidence` begins empty.
Statuses: `planned` -> `implemented` -> `verified`. `verified` requires evidence; the mere existence of an evidence file does not guarantee technical sufficiency.

Check commands:

```bash
python3 tools/check_requirements.py
python3 -m unittest discover -s verification -v
```

The checker rejects missing inventory items in the table, duplicate IDs, invalid sources/targets, and `verified` entries without evidence. Accuracy of the inventory against official specs requires manual review; validating an internal JSON list is not formal certification.

## Open Items for W02 Closeout

1. Opcode and CSR access/trap tables, WARL behavior, and reset values for the initial slice.
2. Dependency/version expansion for B/A/C/V and profile-defined extensions; reference tool coverage.
3. Memory map, reset vector, and test termination/commit trace contract.
4. Optional feature decisions and interrupt/debug/SBI platform spec versions.

This deliverable is the first sub-step of W02; neither W02 nor G0 is closed solely by this document.
