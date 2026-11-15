# Fursoy Slice-1

**A 64-bit Out-of-Order Superscalar RISC-V Processor (`RV64IMAFDV + Zba + Zbb + Zicsr + Zifencei`) booting mainline Linux 6.6.50 and BusyBox userspace under Sv39 virtual memory.**

Fursoy Slice-1 (`fursoy_s1_core` / `fursoy_s1_soc`) is a clean-slate 64-bit out-of-order superscalar RISC-V processor implemented in SystemVerilog, featuring Sv39 demand paging, machine/supervisor/user privilege separation, cycle-exact hardware performance telemetry, and 500 MHz Nangate 45nm standard-cell synthesis closure across 8 core functional blocks.

---

## Microarchitecture Highlights

- **2-Wide Superscalar OoO Core (`fursoy_s1_core`)**:
  - 2-wide fetch, decode, register rename, and in-order retirement (`M/S/U` privilege modes, `medeleg`/`mideleg`, `WFI`, `MRET`/`SRET`).
  - **128-entry Reorder Buffer** (`ROB_DEPTH = 128`) with 4-bit wrap-safe epoch tags and precise exception/interrupt flush recovery.
  - **160-entry Physical Integer Register File** (`PRF_SIZE = 160`, `128` speculative free-list entries) plus **8 branch checkpoints** (`NUM_CHECKPOINTS = 8`) for single-cycle speculative RAT rollback.
  - Dedicated issue queues: **32-entry Integer IQ** (`INT_IQ_DEPTH = 32`), **32-entry Memory IQ** (`MEM_IQ_DEPTH = 32`), **16-entry FP IQ** (`FPIQ_DEPTH = 16`, `FPRF_SIZE = 64`), plus an **8-entry fetched RVV execution queue** (`vecq_q[8]` over a `48 × 256-bit` 4-banked VRF, alongside a standalone **8-entry `VIQ8`** vector issue queue module).
  - Parallel-prefix **64-bit Kogge-Stone `fursoy_s1_alu`** and `fursoy_s1_branch_unit` (single-cycle execution + carry-free target equality), 3-stage pipelined multiplier, and hardware divider.
- **Sv39 Virtual Memory & Non-Blocking Caches**:
  - **Dual-port Sv39 DTLB**: `64`-entry 4-way set-associative base TLB (`16` sets, Tree-PLRU) + `8`-entry 2 MiB / 1 GiB superpage CAM with `32`-entry Translation Request Table (`TRT_DEPTH = 32`).
  - **Sv39 ITLB**: `64`-entry 4-way set-associative base TLB + `8`-entry superpage CAM.
  - **Shared Hardware PTW (`fursoy_s1_ptw`)**: Walks Sv39 page tables with **non-destructive L1D dirty snoop coherency** so page-table writes sitting dirty in L1D are observed directly without eviction, paired with `SFENCE.VMA` store-queue drain and D-cache clean synchronization.
  - **L1I Cache (`fursoy_s1_l1i`)**: `16 KiB`, 4-way set-associative (`64` sets × `64 B`), VIPT-safe with conservative next-line prefetcher and `2` I-MSHRs.
  - **L1D Cache (`fursoy_s1_l1d`)**: `16 KiB`, 4-way set-associative (`64` sets × `64 B`), **8-bank** (`PA[5:3]`) non-blocking data cache with `16`-entry Load Queue, `16`-entry Store Queue, `4` MSHRs, and `2`-entry Writeback Buffer.
- **SoC & Peripherals (`fursoy_s1_soc`)**:
  - **5-to-1 Priority Crossbar**: Core MMIO > PTW walks > L1I refills > L1D refills > L1D dirty writebacks, with anti-starvation fairness and unmapped-aperture bus error trapping.
  - **Platform Devices**: `256 MiB` DRAM interface (`0x8000_0000`), `CLINT` (`0x0200_0000`), `PLIC` (`0x0C00_0000`, `31` external sources), `16550 UART` (`0x1000_0000`), and custom minimal **SBI v2.0** M-mode firmware (`Base`, `TIME`, `SRST`, `DBCN`).

---

## Execution Engine & Pipeline Architecture

```text
+---------------------------------------------------------------------------------------------------+
|                                   FRONTEND (2-Wide In-Order Fetch & Decode)                       |
|                                                                                                   |
|  [F0 GenPC + BPU]                  [F1/F2 ITLB + L1I]                 [F3/F4 Fetch Queue -> D0]   |
|   - 512-entry BTB (256x2-way)       - ITLB: 64-ent 4-way + 8-ent CAM   - 16-entry Fetch Queue     |
|   - TAGE-Lite (30.2 kb, 108b GHR)   - L1I:  16 KiB 4-way VIPT (64x64B) - 2W Decode (RV64IMAFDV)   |
|   - 16-entry RAS, 8 Checkpoints     - Next-Line Prefetcher (2 I-MSHR)  - + Zba/Zbb/Zicsr/Zifencei |
+-------------------------------------------------+-------------------------------------------------+
                                                  | 2 uops / cycle
                                                  v
+---------------------------------------------------------------------------------------------------+
|                             RENAME, DISPATCH & IN-ORDER RETIREMENT                                |
|                                                                                                   |
|  [2-Wide Rename / SRAT / ARAT] <====== 8 Branch Checkpoints (Single-Cycle Speculative Rollback)   |
|  [128-Entry ROB (2W Alloc / 2W Retire, 4-bit Epoch Tags)]                                         |
|  Register Files:  Int PRF: 160 x 64b (32 arch + 128 spec) | FP PRF: 64 x 64b | VRF: 48 x 256b     |
+--------+-------------------------+-------------------------+------------------------+-------------+
         |                         |                         |                        |
         v                         v                         v                        v
+------------------+     +-------------------+     +-------------------+    +-----------------------+
| IntIQ (32 ent)   |     | MemIQ (32 ent)    |     | FPIQ (16 ent)     |    | Fetched RVV Engine    |
| 2W Dispatch      |     | 2W Dispatch       |     | 2W Dispatch       |    | vecq_q[8] (core FSM)  |
+----+--------+----+     +----+---------+----+     +---------+---------+    +-----------+-----------+
     |        |               |         |                    |                          |
     v        v               v         v                    v                          v
  [Port 0] [Port 1]       [Port 2]  [Port 3]             [Port 4]                 [Vector FSM]
  - ALU0   - ALU1         - AGU0    - AGU1               - FMA (3c/4c)            - Element-by-element
    (1c)     (1c FIFO)      (Ld/St/   (Loads             - FDIV/FSQRT               scalar ALU/mem ops
  - BR     - MUL (3c)        AMO/      only)               (12/21/15/28c)           over 4-banked VRF
    (1c)   - DIV (~34c)      FENCE)                      - FCONV/FCMP             - (Standalone VIQ8
  - CSR/                   - 16 LQ / 16 SQ                                          in testbench harness)
    I2F                    - 32 TRT
     |        |               |         |                    |                          |
     +---+----+---------------+---------+--------------------+--------------------------+
         |                    |         |                                               |
         v                    v         v                                               v
+---------------------------------------------------------------------------------------------------+
|                                  MEMORY & COHERENT SUBSYSTEM                                      |
|                                                                                                   |
|  [Dual-Port Sv39 DTLB]  <--------->  [Hardware PTW] (Non-destructive L1D dirty snoop coherency)   |
|   (64-ent 4-way + 8-ent CAM)                                                                      |
|  [16 KiB 4-Way 8-Bank L1D (PA[5:3])] --- 4 MSHRs, 2 WBBs, Snoop Coherent (no victim cache)        |
+-------------------------------------------------+-------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
|                                   SoC INTERCONNECT & PERIPHERALS (fursoy_s1_soc)                  |
|                                                                                                   |
|  [5-to-1 Priority Crossbar]:  Core MMIO > PTW Walks > L1I Refills > L1D Refills > L1D Writebacks  |
|   -> DRAM (256 MiB @ 0x8000_0000) | CLINT | PLIC (31 sources) | 16550 UART | Unmapped Fault Trap  |
+---------------------------------------------------------------------------------------------------+
```

The backend issues out of **five scalar execution ports** across three out-of-order issue queues (plus the sequential fetched-RVV path) — up to **5 scalar operations/cycle** peak (2 Int + 2 Mem + 1 FP):

| Issue Queue | Capacity | Dispatch | Issue Port(s) | Functional Units & Exact Latency | Constraints & Arbitration |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`IntIQ`** (`fursoy_s1_int_iq`) | 32 entries | 2-wide | **Port 0** (`P0`), **Port 1** (`P1`) | **P0**: `ALU0` (`1c`, Kogge-Stone), `Branch` (`1c`), `System/CSR`, `int2fp` dispatch<br>**P1**: `ALU1` (`1c` via `alu1_fifo`), `MUL` (`3c` pipelined), `DIV` (`~34c` Radix-4 iterative; `1c` corner bypass) | Max **1 branch/cycle** (`P0` only); `DIV` is single-occupancy; `ALU0` has PRF writeback priority over `F2I` |
| **`MemIQ`** (`fursoy_s1_mem_iq`) | 32 entries | 2-wide | **Port 2** (`P2/AGU0`), **Port 3** (`P3/AGU1`) | **P2**: `AGU0` (`1c` EA) for Loads, Stores, AMOs, `FENCE`/`FENCE.I`<br>**P3**: `AGU1` (`1c` EA) for Loads only | Max **2 loads/cycle** or **1 load + 1 store AGU/cycle** across **8 L1D banks** (`PA[5:3]`); same-DW dual loads broadcast with zero stall; backed by `16 LQ / 16 SQ / 32 TRT / 4 MSHRs / 2 WBBs` |
| **`FPIQ`** (`fursoy_s1_fp_iq`) | 16 entries | 2-wide | **Port 4** (`P4`) | **P4**: `FMA` (`3c` FP32 / `4c` FP64, `1/cyc` throughput), `FDIV/FSQRT` (`12c` FDIV.S / `21c` FDIV.D / `15c` FSQRT.S / `28c` FSQRT.D, non-blocking Radix-4), `FCONV/FCMP/FSGNJ/FMINMAX` (`1c` eval + `8`-entry `f2i_fifo`) | Single FP issue port; `FMA` holds strict writeback priority over `FDIV`; `frm`/`fcsr` CSR writes serialize pipeline flush |
| **Vector (`vecq_q` / `VIQ8`)** | 8 entries | In-order fetched FIFO | Sequential core FSM | Fetched `RVV 1.0` instructions execute sequentially in `vecq_q[8]` inside `fursoy_s1_core` element-by-element via scalar ALU/mem paths over `48 × 256-bit` 4-banked `VRF` | Standalone dual-lane `VIQ8` (`fursoy_s1_vec_iq`, 128-bit SIMD beats) is instantiated in RTL and verified via dedicated testbench harness ports (`test_viq_*`) |

---

## Physical Synthesis & STA (Nangate 45nm @ 500 MHz)

Evaluated standalone across 8 core functional blocks using **Yosys 0.33** + **sv2v v0.0.13** + **OpenSTA 3.1.0** on **NangateOpenCellLibrary (45nm Typical, 1.10V, 25C)** targeting **500 MHz (`2.000 ns` clock period)** (`tools/run_s1_synth.py --run-synth`, full report in `build/synth/s1_synth_report.json`):

| Module | Type | Cells | DFFs | Area (kGE) | Baseline Arrival / WNS | Optimized Arrival | Opt WNS @ 500 MHz |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fursoy_s1_branch_unit` | Comb | 3,285 | 0 | 4.49 | 3.712 ns (`-1.712 ns`) | **0.629 ns** | **+1.371 ns (MET)** |
| `fursoy_s1_csr` | Seq | 13,957 | 1,790 | 26.75 | 22.776 ns (`-21.120 ns`) | **1.663 ns** | **+0.298 ns (MET)** |
| `fursoy_s1_dtlb` | Seq | 50,417 | 6,515 | 99.83 | 11.011 ns (`-9.211 ns`) | **1.249 ns** | **+0.551 ns (MET)** |
| `fursoy_s1_itlb` | Seq | 36,238 | 6,304 | 77.12 | 4.057 ns (`-2.102 ns`) | **1.198 ns** | **+0.602 ns (MET)** |
| `fursoy_s1_agu` | Comb | 321 | 0 | 0.66 | 2.301 ns (`-0.301 ns`) | **1.901 ns** | **+0.099 ns (MET)** |
| `fursoy_s1_ptw` | Seq | 1,765 | 329 | 3.67 | 1.956 ns (`+0.005 ns`) | **0.948 ns** | **+1.013 ns (MET)** |
| `fursoy_s1_decode` | Comb | 2,459 | 0 | 3.21 | 0.875 ns (`+1.125 ns`) | **0.783 ns** | **+1.217 ns (MET)** |
| `fursoy_s1_alu` | Comb | 4,309 | 0 | 6.27 | 3.823 ns (`-1.823 ns`) | **1.133 ns** | **+0.867 ns (MET)** |
| **Total (8 Core Blocks)** | — | **112,751** | **14,938** | **222.00** | — | **8 / 8 MET** | **TNS = 0.00 ns** |

> *Note: Total standard-cell area across these 8 standalone blocks is `177,155.73 um^2` (`NAND2_X1 = 0.798 um^2`). Full-SoC place-and-route and SRAM macro compilation are not yet executed.*

---

## Linux 6.6.50 Boot & Single-Owner CPI Telemetry

The Milestone 9 closeout (`tools/run_s1_m9_closeout.py`, saved in [`results/s1-m9-closeout.json`](results/s1-m9-closeout.json)) boots mainline **Linux 6.6.50** in Verilator with zero kernel panics, zero oopses, zero access faults, and **0** CPI conservation errors across **89,861,075** simulated cycles (`76,236,390` retired instructions, `2,227,761` U-mode commits, `2,255` demand page faults / `1,027` U-mode, `IPC = 0.84838`):

```text
[    0.000000] Linux version 6.6.50 ... (riscv64-linux-gnu-gcc 13.3.0)
[    0.000000] SBI specification v2.0 detected
[    0.000000] SBI implementation ID=0xf00501 Version=0x1
[    0.000000] earlycon: uart8250 at MMIO32 0x0000000010000000 (options '')
...
[    6.809584] Run /init as init process
[INIT] Fursoy Slice-0 Linux BusyBox Userspace active!
FURSOY_USERSPACE_BEGIN
[TEST 01] uname ... Linux (none) 6.6.50 riscv64 GNU/Linux
...
[TEST 20] repeated process creation/exit
[TEST 21] userspace memory stress
[MEM_STRESS_START] Running stack and heap multi-width memory validation...
[MEM_STRESS_PASS] All stack, heap, multi-width, and strided tests passed.
FURSOY_USERSPACE_PASS
```

### Cycle-Exact 8-Category CPI Conservation Breakdown

Every cycle is mutually exclusively owned by one architectural bucket asserted continuously in hardware (`sum(C_k) == mcycle = 89,861,075`, `cpi_conservation_errors = 0`):

| CPI Category | Cycles | Share | Description |
| :--- | ---: | ---: | :--- |
| `C_productive` | 43,079,458 | 47.94% | Active useful graduation / commit cycles |
| `C_br_recover` | 15,024,530 | 16.72% | Branch misprediction & exception flush recovery |
| `C_idle_other` | 14,806,625 | 16.48% | WFI idle, non-stalled pipeline drain & other bubbles |
| `C_be_rename` | 5,709,439 | 6.35% | Rename stalls (ROB / Free List / checkpoint capacity) |
| `C_mem_stall` | 5,549,273 | 6.18% | L1D miss / bank conflict / DTLB-PTW memory stalls |
| `C_be_sched` | 2,736,785 | 3.05% | Issue queue scheduling / execution operand stalls |
| `C_serialize` | 2,450,147 | 2.73% | CSR / `SFENCE.VMA` / `FENCE.I` / trap serialization |
| `C_fe_starve` | 504,818 | 0.56% | Frontend fetch queue empty (L1I miss / ITLB miss) |
| **Total (`mcycle`)** | **89,861,075** | **100.00%** | **76,236,390 commits (IPC = 0.84838)** |

---

## Quickstart (Prerequisites & Verification)

### Prerequisites (Ubuntu 24.04 / WSL2)

```bash
sudo apt-get update
sudo apt-get install -y \
  verilator g++ python3 device-tree-compiler \
  gcc-riscv64-unknown-elf gcc-riscv64-linux-gnu
```

*(Optional, for physical synthesis & STA: `yosys`, `sv2v`, OpenSTA `sta`, and Nangate45 `.lib` via `FURSOY_LIBERTY` or `tools/synth/lib/NangateOpenCellLibrary_typical.lib`. For `sail-riscv` golden-model differential co-simulation: extract the official `sail-riscv` Linux x86_64 release tarball so `tools/sail/bin/bin/sail_riscv_sim` exists; the Fursoy-matched machine configuration is checked in at [`tools/sail/fursoy_s1_sail_config.json`](tools/sail/fursoy_s1_sail_config.json).)*

### Running Verification

From the repository root:

```bash
# 1. Production RTL lint (Verilator --lint-only, expects 0 warnings/errors)
python3 tools/run_s1_lint.py

# 2. Fast Slice-1 verification regressions (runtime ~3-6 min total)
python3 tools/run_s1_m9_phase_a.py   # Interrupts, mideleg, WFI, precise trap boundaries
python3 tools/run_s1_m9_phase_b.py   # CLINT, PLIC, UART 16550 platform peripherals
python3 tools/run_s1_m9_phase_c.py   # 5-master crossbar, DTB, unmapped faults
python3 tools/run_s1_m9_phase_d.py   # SBI v2.0 firmware + mixed-privilege stress
python3 tools/run_s1_m8_closeout.py  # RV64FD + RVV 1.0 FP/Vector backend
python3 tools/run_s1_m7_closeout.py  # Multi-bank non-blocking L1D + coherency
python3 tools/run_s1_m6_closeout.py  # Frontend BPU / ITLB / L1I NLP

# 3. Sail-RISC-V golden-model differential co-simulation (RV64IMAFDV + Zba + Zbb + Sv39 + traps)
python3 tools/run_s1_sail_cosim.py

# 4. Nangate 45nm @ 500 MHz synthesis & OpenSTA check
python3 tools/run_s1_synth.py --run-synth

# 5. Full Linux 6.6.50 + BusyBox boot closeout (~1.5-2 hours wall time)
# Requires a built RISC-V Image at build/linux-6.6.50/arch/riscv/boot/Image
# (kernel config/patches in software/linux/, initramfs helper in tools/build_initramfs.py).
python3 tools/run_s1_m9_closeout.py
```

---

## Repository Layout

| Directory | Contents |
| :--- | :--- |
| [`rtl/core/`](rtl/core/) | Slice-1 64-bit OoO core SystemVerilog modules (`fursoy_s1_core`, ROB, rename, IQs, ALU/Branch/Mul/Div, FP/Vec, DTLB/ITLB/PTW, L1I/L1D) |
| [`rtl/platform/`](rtl/platform/) | Slice-1/Slice-0 SoC integration (`fursoy_s1_soc`), 5-master crossbar, CLINT, PLIC, 16550 UART |
| [`software/`](software/) | Minimal SBI v2.0 M-mode firmware, Fursoy Slice-1 Device Tree (`fursoy_s1.dts`), Linux 6.6.50 defconfig/patches, BusyBox `/init` & `mem_stress` |
| [`verification/`](verification/) | Verilator C++ self-checking testbenches (`s1_m9_closeout_tb.cpp`, `s1_sail_cosim_tb.cpp`, M5–M9 phase/closeout benches, unit checks) |
| [`tools/`](tools/) | Python lint, regression, Sail cosim (`run_s1_sail_cosim.py`), Linux closeout, synthesis (`run_s1_synth.py`), and analysis runners |
| [`docs/architecture/`](docs/architecture/) | Normative microarchitecture, MMU, cache, and SoC specification documents |
| [`results/`](results/) | Verified milestone JSON evidence reports (including `results/s1-m9-closeout.json`) |

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
