# Fursoy CPU

Original CPU project targeting a single-socket, 4→8 core Linux server.
Architectural goals and transition gates: [master plan](CPU_MASTER_PLAN.md).
Server decision and ECC/RAS priorities: [ADR-001](docs/decisions/001-server-target.md).

## Current Status

The project is at the functional and verified in-order **Slice-0** core stage:

- **Core architecture:** In-order `fursoy_s0_core` providing RV64I integer instruction set, Zicsr, and FENCE.I support.
- **Privilege and CSR:** Reviewed and frozen M-mode substrate; explicit M/S/U privilege state machine, CSR address privilege check (`csr_addr[9:8] <= priv_mode`), read-only CSR protection, WARL fields, and side-effect suppression on trap/fault.
- **Initial S-mode Bare RTL package:** Passed independent review and frozen (ACCEPT AND FREEZE). Includes S-mode trap register bank (`stvec`, `sscratch`, `sepc`, `scause`, `stval`), `sstatus` masked alias, synchronous exception delegation via `medeleg`, `mret`/`sret` rules, `wfi`, Bare `sfence.vma`, and counter access control (`mcounteren`/`scounteren`).
- **Interrupts and SoC integration:** Single-hart CLINT (MTIP/MSIP) and external interrupt (MEIP) support; SoC memory map and MMIO bus integration (`fursoy_s0_soc`).
- **Verification and reference:** 11 bare-metal ELF tests execute on both the Spike reference simulator and Verilator DUT simulation, passing signature comparisons (`tools/run_core_baremetal_s0.py`). S-mode trap and privilege scenarios are verified with focused integration tests (57 CSR unit checks, 9 end-to-end scenarios).

Key components not yet implemented and missing:
- Supervisor interrupt delegation (`mideleg`, `sie`, `sip`, SSIP/STIP/SEIP).
- Sv39 paging / MMU / PTW / TLB.
- PMP (Physical Memory Protection).
- PLIC (Platform-Level Interrupt Controller).
- Caches (L1I/L1D and L2/L3 cache structures).
- Multi-core / multi-hart support.
- Linux boot.
- Physical PPA (area, frequency, power) results.

## Environment Check

Inside Ubuntu WSL, from the repository root:

```bash
python3 tools/check_environment.py --require bootstrap --output results/environment-wsl.json
python3 -m unittest discover -s verification -v
```

The script does not install tools. It executes version/help commands for discovered tools.
A profile showing `ready` indicates only that these invocations succeeded;
it does not indicate interoperability, hardware simulation viability, or production readiness.
The JSON is an observational record, not a locked toolchain.

For example, `--require rtl` returns a non-zero exit code if hardware simulation tools are missing or broken. Multiple `--require` flags can be specified.
Without `--require`, it only collects inventory; missing items still appear in the report.

## Real RTL Simulation

Inside Ubuntu from the repository root:

```bash
python3 tools/run_fifo.py
```

Requires Verilator and G++. The script compiles four FIFO configurations and one mutated/broken RTL copy; build parallelism is limited to 2. Source RTL is not modified.
The first failure produces a non-zero exit code. Results and source SHA-256 hashes are stored in `results/fifo.json`; build/run logs are kept under `build/fifo/`.
This is an RTL toolchain and FIFO functional check; it is not formal or PPA verification.

Interface and scope: [FIFO contract](docs/architecture/fifo.md).
Evidence and limits: [RTL pilot report](docs/progress/002-rtl-pilot.md).

## Next Steps

1. Supervisor interrupt delegation package (`mideleg`, `sie`, `sip`, SSIP/STIP/SEIP).
2. Sv39 / MMU architectural contract and hardware design.
3. PMP, PLIC, and cache integration.

Existing hardware, gaps, and verification evidence:
[initial environment record](docs/progress/001-environment.md).

ISA/platform scope: [contract](docs/requirements/isa-platform.md),
[requirements table](docs/requirements/isa-platform.csv).
Table verification: `python3 tools/check_requirements.py`.

## Bare-Metal Compilation and DUT Execution

Inside Ubuntu, run `python3 tools/build_baremetal.py`. Requires RISC-V GCC/binutils.
ELFs and detailed logs are generated under `build/baremetal/`; persistent summaries and source hashes are recorded under `results/baremetal-build.json`.
Compiled ELFs are executed on Spike via `python3 tools/run_spike.py` and on the Verilator DUT via `python3 tools/run_core_baremetal_s0.py` to verify signatures.
Test contract: [bare-metal v1](docs/architecture/baremetal-v1.md).
Instruction, CSR, and trap sub-contract: [slice-0](docs/requirements/slice-0.md).

## Spike Reference Preparation

The official source commit is pinned in `tools/spike-lock.json`. Source and build
artifacts reside under `build/` inside the project; the system PATH is not modified.
Ubuntu dependencies: `device-tree-compiler libboost-regex-dev libboost-system-dev`.
Once installed, execute sequentially in Ubuntu:

```bash
python3 tools/setup_spike.py
python3 tools/build_baremetal.py
python3 tools/run_spike.py
```

Setup compilation logs are maintained under `build/spike-build/`; uses 4 build jobs.
In addition to genuine success, the runner checks unexpected trap, corrupted signature, and timeout
scenarios. Spike reference execution and golden signature generation infrastructure
are verified and used in regressions (`results/spike.json`).
