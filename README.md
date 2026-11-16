# Fursoy Slice-1

**A 64-bit Out-of-Order Superscalar RISC-V Processor (`RV64IMAFDV + Zba + Zbb + Zicsr + Zifencei`) booting mainline Linux 6.6.50 and BusyBox userspace under Sv39 virtual memory.**

Fursoy Slice-1 (`fursoy_s1_core` / `fursoy_s1_soc`) is a 64-bit 2-wide out-of-order superscalar RISC-V processor in SystemVerilog, implementing Sv39 demand paging with 16-bit ASIDs, M/S/U privilege separation, cycle-exact hardware performance telemetry, 8-suite `sail-riscv` lockstep differential verification, and 500 MHz Nangate 45nm standard-cell synthesis closure across all 8 gated core blocks plus `fursoy_s1_fconv`.

**Interactive Architecture & Telemetry Explorer:** [cpu.fursoy.com](https://cpu.fursoy.com) — inspect the full `F0`–`CMT` pipeline diagram, execution port matrix, 500 MHz Nangate 45nm STA breakdown, 8-suite Sail cosim metrics, and single-owner Linux 6.6.50 boot CPI conservation breakdown.

---

## Microarchitecture Highlights

- **2-Wide Superscalar OoO Core (`fursoy_s1_core`)**:
  - Multi-stage frontend and OoO backend (`F0` GenPC → `F1` ReqMem → `F2` RspMem → `F3` Align/JAL → `F4` FetchQueue → `D0` Decode → `RN` Rename → `DS` Dispatch → `IS` Issue → `RF` RegRead → `EX` Execute → `WB` → `CMT` Retire) with `M/S/U` privilege modes, `medeleg`/`mideleg`, `WFI` (`mstatus.TW`), and `MRET`/`SRET`.
  - **128-entry Reorder Buffer** (`ROB_DEPTH = 128`) with 4-bit wrap-safe epoch tags, instruction payload capture for `cause 2` `mtval`/`stval`, and precise exception/interrupt flush recovery.
  - **16-checkpoint Speculative Recovery** (`NUM_CHECKPOINTS = 16`, `4-bit` checkpoint IDs) across integer `SRAT`, floating-point `FRAT`, vector `VRAT`, and BPU state for single-cycle branch rollback.
  - **Physical Register Files**: `160 × 64b` Integer PRF (`p0..p159`, `32` arch + `128` speculative Free List), `64 × 64b` FP PRF (`fp0..fp63`), and **`64 × 256b` 4-banked 4R+1W Vector RF** (`VRF_NUM_PREGS = 64`, `p0..p31` arch + `p32..p63` bitmap freelist via `fursoy_s1_vrat`).
  - **Decoupled Issue Queues**: `32`-entry `IntIQ`, `32`-entry `MemIQ`, `16`-entry `FPIQ`, and **`8`-entry OoO `VIQ8` (`fursoy_s1_vec_iq`)** with multi-reg vector/scalar wakeup, ROB-head vector memory serialization, dual-lane 128-bit SIMD beats, indexed RVV loads/stores, and non-zero `vstart` resumption.
  - **Shared Prefix Datapath**: Shared 64-bit parallel-prefix Kogge-Stone adder (`fursoy_s1_ks_adder`) used across `fursoy_s1_alu`, `fursoy_s1_branch_unit`, `fursoy_s1_agu`, `fursoy_s1_csr`, and the 2-stage pipelined `fursoy_s1_fconv`.
- **Branch Prediction & Architectural Recovery (`fursoy_s1_bpu`)**:
  - `512`-entry 2-way BTB + **`30,208`-bit TAGE-Lite** (`T0` 2048×2b + `T1..T4` 512 entries, `108`-bit GHR) + **`64`-entry tagged Indirect Branch Predictor (`IBP`)** + `16`-entry RAS with **`INDEXED_RAS_CHKPT = 32`** checkpoint table (`slots 1..31`).
  - Commit-time TAGE/BTB/IBP training FIFO with periodic 256K u-bit aging, plus full architectural GHR, folded CSR, and 16-entry `arch_ras_array_q` preservation across non-branch traps and pipeline flushes.
- **Sv39 Virtual Memory & Non-Blocking Caches**:
  - **Standalone Dual-Port Sv39 DTLB (`fursoy_s1_dtlb`)**: `64`-entry 4-way Tree-PLRU base TLB (`16` sets) + `8`-entry 2 MiB / 1 GiB superpage CAM + `32`-entry `TRT` with 16-bit ASIDs and `G == 1` `SFENCE.VMA` preservation.
  - **Sv39 ITLB (`fursoy_s1_itlb`)**: `64`-entry 4-way base TLB + `8`-entry superpage CAM + `2`-entry `ITRT`.
  - **Shared Hardware PTW (`fursoy_s1_ptw`)**: Reserved PTE `[63:54]` and non-leaf `U/A/D` fault checks, `priv == M && mstatus.MPRV` walk privilege, and **non-destructive L1D dirty snoop coherency** paired with `SFENCE.VMA` SQ drain + D-cache clean.
  - **L1I (`fursoy_s1_l1i`) & L1D (`fursoy_s1_l1d`)**: `16 KiB`, 4-way VIPT (`64` sets × `64 B`), true 3-bit Tree-PLRU per L1D set, **8-bank** (`PA[5:3]`) non-blocking L1D with `16` LQ / `16` SQ / `4` MSHRs / `2` WBBs, and ROB-head `LR` serialization (`fursoy_s1_lsu_queues`).
- **SoC & Peripherals (`fursoy_s1_soc`)**:
  - **5-to-1 Priority Crossbar**: Core MMIO > PTW walks > L1I refills > L1D refills > L1D dirty writebacks, with anti-starvation fairness and unmapped-aperture Access Fault trapping.
  - **Platform Devices**: `256 MiB` DRAM (`0x8000_0000`), unified load/store `CLINT` (`0x0200_0000`), preemptible `PLIC` (`0x0C00_0000`, `31` sources), `16550 UART` (`0x1000_0000`, 1B/2B/4B MMIO), and custom **SBI v2.0** M-mode firmware (`Base`, `TIME`, `SRST`, `DBCN`).

---

## Execution Engine & Pipeline Architecture

```text
+---------------------------------------------------------------------------------------------------+
|                             FRONTEND (2-Wide In-Order Fetch & Decode)                             |
|                                                                                                   |
|  [F0 GenPC] -> [F1 ITLB/BPU] -> [F2 L1I/TAGE/IBP/RAS/Skid] -> [F3 Align/JAL] -> [F4 FetchQ16 -> D0]|
|   - 512-entry BTB (256x2-way)       - 64-entry tagged IBP           - 16-entry Fetch Queue        |
|   - TAGE-Lite (30.2 kb, 108b GHR)   - ITLB: 64-ent 4W + 8-ent CAM   - 2W Decode (RV64IMAFDV +     |
|   - 16-RAS (32-slot indexed chkpt)  - L1I:  16 KiB 4W VIPT, 2 IMSHR   Zba/Zbb/Zicsr/Zifencei)     |
+-------------------------------------------------+-------------------------------------------------+
                                                  | 2 uops / cycle
                                                  v
+---------------------------------------------------------------------------------------------------+
|                           RENAME, DISPATCH & IN-ORDER RETIREMENT                                  |
|                                                                                                   |
|  [2-Wide Rename: Int SRAT/ARAT | FP FRAT/ARAT | VRAT Bitmap] <==== 16 Branch Checkpoints          |
|  [128-Entry ROB (2W Alloc / 2W Retire, 4-bit Epoch Tags)]                                         |
|  PRFs:  Int PRF 160 x 64b (32 arch + 128 FL) | FP PRF 64 x 64b | Vector RF 64 x 256b (4-bank 4R1W)|
+-----------+-------------------------+--------------------------+--------------------+-------------+
            |                         |                          |                    |
            v                         v                          v                    v
+-----------------------+ +-----------------------+ +--------------------+ +------------------------+
| IntIQ (32 entries)    | | MemIQ (32 entries)    | | FPIQ (16 entries)  | | VIQ8 (fursoy_s1_vec_iq)|
| 2W Issue (P0 + P1)    | | 2W Issue (P2 + P3)    | | 1W Issue (P4)      | | OoO ALU + Head-Mem     |
+-----+-----------+-----+ +------+----------+-----+ +---------+----------+ +-----------+------------+
      |           |              |          |                 |                        |
      v           v              v          v                 v                        v
+-----------+ +----------+ +-------------+ +-----------+ +----------------+ +-----------------------+
| [Port 0]  | | [Port 1] | | [Port 2]    | | [Port 3]  | | [Port 4 (FP)]  | | [Dual-Lane Vector]    |
| ALU0 (KS) | | ALU1(1c*)| | AGU0 (KS)   | | AGU1 (1c) | | FMA (3c / 4c)  | | 128b SIMD Beats +     |
| BR (KS)   | | MUL (3c) | | Ld/St/AMO   | | Loads     | | FDIV (12..28c) | | Elem ALU/Red/Indexed  |
| CSR / I2F | | DIV(~34c)| | FENCE/LR-SC | | (-> 8-bk) | | FCONV (2-stg)  | | Mem over 4R+1W VRF    |
+-----+-----+ +----+-----+ +------+------+ +-----+-----+ +-------+--------+ +----------+------------+
      |            |              |              |               |                     |
      +------------+--------------+--------------+---------------+---------------------+
                                                 |
                                                 v
+---------------------------------------------------------------------------------------------------+
|                                  MEMORY & COHERENT SUBSYSTEM                                      |
|                                                                                                   |
|  [Standalone Dual-Port Sv39 DTLB] <---> [Hardware PTW] (Non-destructive L1D dirty snoop, MPRV)    |
|   (64-ent 4-way Tree-PLRU + 8-ent CAM)                                                            |
|  [16 KiB 4-Way 8-Bank L1D (PA[5:3])] --- 3-bit Tree-PLRU, 4 MSHRs, 2 WBBs, Snoop Coherent         |
+-------------------------------------------------+-------------------------------------------------+
                                                  |
                                                  v
+---------------------------------------------------------------------------------------------------+
|                             SoC INTERCONNECT & PERIPHERALS (fursoy_s1_soc)                        |
|                                                                                                   |
|  [5-to-1 Priority Crossbar]:  Core MMIO > PTW Walks > L1I Refills > L1D Refills > L1D Writebacks  |
|   -> DRAM (256 MiB @ 0x8000_0000) | CLINT (Unif.) | PLIC (31 src) | UART (1/2/4B) | Fault Trap    |
+---------------------------------------------------------------------------------------------------+
```

The backend issues across **five decoupled scalar execution ports** plus an **out-of-order vector execution pipe**:

| Issue Queue | Capacity | Dispatch | Issue Port(s) | Functional Units & Latency | Constraints & Arbitration |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`IntIQ`** (`fursoy_s1_int_iq`) | 32 entries | 2-wide | **Port 0** (`P0`), **Port 1** (`P1`) | **P0**: `ALU0` (`1c`, `fursoy_s1_ks_adder`), `Branch` (`1c`), `System/CSR`, `int2fp`<br>**P1**: `ALU1` (`1c` via `alu1_fifo`), `MUL` (`3c` pipelined), `DIV` (`~34c` Radix-4 iterative; `1c` corner bypass) | Max **1 branch/cycle** (`P0` only); `DIV` single-occupancy; `int2fp` gated by `fconv_fprf_busy`; `ALU0` has PRF WB priority over `F2I` |
| **`MemIQ`** (`fursoy_s1_mem_iq`) | 32 entries | 2-wide | **Port 2** (`P2/AGU0`), **Port 3** (`P3/AGU1`) | **P2**: `AGU0` (`1c` KS EA) for Loads, Stores, AMOs, `FENCE`/`FENCE.I`<br>**P3**: `AGU1` (`1c` EA) for Loads only | Max **2 loads/cycle** or **1 load + 1 store AGU/cycle** across **8 L1D banks** (`PA[5:3]`); `is_lr` serialized to `rob_head_i`; backed by `16 LQ / 16 SQ / 32 TRT / 4 MSHRs / 2 WBBs` |
| **`FPIQ`** (`fursoy_s1_fp_iq`) | 16 entries | 2-wide | **Port 4** (`P4`) | **P4**: `FMA` (`3c` FP32 / `4c` FP64, `1/cyc`), `FDIV/FSQRT` (`12c` FDIV.S / `21c` FDIV.D / `15c` FSQRT.S / `28c` FSQRT.D), `FCONV` (`2`-stage pipelined + `16`-entry `f2i_fifo`/`fprf_fifo`) | Single FP issue port; `FMA` holds strict writeback priority over `FDIV` and `FCONV`; `frm`/`fcsr` CSR writes serialize pipeline flush |
| **`VIQ8`** (`fursoy_s1_vec_iq`) | 8 entries | Serialized vec dispatch | **Vector Engine** (`u_vrat` + `u_vrf`) | OoO `RVV 1.0` ALU/mask/reduction/slide execution (`128b` dual-lane SIMD beats + elem path) and ROB-head serialized unit/strided/indexed memory (`vluxei`/`vsoxei`) over `64 × 256b` 4R+1W `VRF` | `fursoy_s1_vrat` bitmap freelist (`p32..p63`, 16 checkpoints); `vec_vstart_block` enforces ordered `vstart != 0` dispatch with age-qualified recovery |

---

## Physical Synthesis & STA (Nangate 45nm @ 500 MHz)

Evaluated standalone using **Yosys 0.33** + **sv2v v0.0.13** + **OpenSTA 3.1.0** on **NangateOpenCellLibrary (45nm Typical, 1.10V, 25C)** targeting **500 MHz (`2.000 ns` clock period)** (`tools/run_s1_synth.py --run-synth`, full report in [`build/synth/s1_synth_report.json`](build/synth/s1_synth_report.json)):

| Module | Type | Gate | Cells | DFFs | Area (kGE) | Baseline Arrival / WNS | Opt Arrival | Opt WNS @ 500 MHz |
| :--- | :--- | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `fursoy_s1_agu` | Comb | Yes | 817 | 0 | 1.07 | 2.301 ns (`-0.301 ns`) | **0.510 ns** | **+1.490 ns (MET)** |
| `fursoy_s1_branch_unit` | Comb | Yes | 4,086 | 0 | 5.45 | 3.712 ns (`-1.712 ns`) | **0.601 ns** | **+1.399 ns (MET)** |
| `fursoy_s1_ptw` | Seq | Yes | 1,843 | 329 | 3.83 | 1.956 ns (`+0.005 ns`) | **0.931 ns** | **+1.031 ns (MET)** |
| `fursoy_s1_decode` | Comb | Yes | 2,777 | 0 | 3.70 | 0.875 ns (`+1.125 ns`) | **0.979 ns** | **+1.021 ns (MET)** |
| `fursoy_s1_alu` | Comb | Yes | 4,326 | 0 | 6.34 | 3.823 ns (`-1.823 ns`) | **1.153 ns** | **+0.847 ns (MET)** |
| `fursoy_s1_csr` | Seq | Yes | 14,699 | 1,872 | 28.00 | 22.776 ns (`-21.120 ns`) | **1.179 ns** | **+0.621 ns (MET)** |
| `fursoy_s1_itlb` | Seq | Yes | 36,755 | 6,304 | 77.52 | 4.057 ns (`-2.102 ns`) | **1.214 ns** | **+0.586 ns (MET)** |
| `fursoy_s1_dtlb` | Seq | Yes | 50,517 | 6,515 | 99.87 | 11.011 ns (`-9.211 ns`) | **1.253 ns** | **+0.547 ns (MET)** |
| **Total (8 Gated Blocks)** | — | **8/8** | **115,820** | **15,020** | **225.77** | — | **8 / 8 MET** | **TNS = 0.00 ns** |
| `fursoy_s1_fconv` *(visibility)* | Seq | No | 23,907 | 3,218 | 46.83 | — | **1.949 ns** | **+0.009 ns (MET)** |

> **Synthesis Scope & Macro Boundary:** `GATE` closure (`8 / 8 MET`, `180,161.53 um^2` at `NAND2_X1 = 0.798 um^2`) targets combinational datapath and register-bounded control blocks (plus 2-stage `fursoy_s1_fconv` visibility, yielding `9 / 16` closed blocks). SRAM-macro-dependent caches (`l1i`, `l1d`), large associative/age-matrix queues/predictors (`int_iq`, `lsu_queues`, `vrat`, `vec_iq`, `bpu`), and 110b combinational/multi-cycle FP arrays (`fma`, `fdiv`) either hit ABC/Yosys flattening timeouts (`bpu`, `l1d`, `int_iq`, `vrat`, `vec_iq`, `fma`, `fdiv`) or are excluded (`l1i`, `lsu_queues`) from macro-area comparisons; in particular, `fursoy_s1_dtlb` (`99.87 kGE`) and `fursoy_s1_itlb` (`77.52 kGE`) currently synthesize as standard-cell flip-flop arrays until compiled SRAM macros are integrated in a physical backend flow.

---

## Sail-RISC-V Differential Co-Simulation

Lockstep comparison (`tools/run_s1_sail_cosim.py`, saved in [`results/s1-sail-cosim.json`](results/s1-sail-cosim.json)) against official **`sail-riscv v0.16`** passes all **8 workloads** (`1,177` Sail steps: `826` GPR, `37` FPR, `55` VRF group, and `24` trap checks) with **0 mismatches**, including `mstatus`, `frm`, `vstart`, `mtval`/`stval` (`causes 2, 4, 6, 13, 15`), and multi-register `LMUL = 2, 4, 8` vector groups:

| Workload | Sail Steps | GPR Checks | FPR Checks | VRF Checks | Trap Checks | Mismatches |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `01_rv64im_zba_zbb` | 155 | 130 | 0 | 0 | 0 | 0 |
| `02_rv64fd_fp` | 89 | 38 | 32 | 0 | 2 | 0 |
| `03_rvv_vector` | 83 | 46 | 0 | 21 | 1 | 0 |
| `04_sv39_mmu_traps` | 304 | 234 | 0 | 0 | 4 | 0 |
| `05_rv64a_atomics` | 52 | 45 | 0 | 0 | 0 | 0 |
| `06_priv_traps_mprv_tbit` | 356 | 261 | 0 | 0 | 9 | 0 |
| `07_fp_edge_cases` | 62 | 30 | 5 | 0 | 4 | 0 |
| `08_rvv_lmul_vstart_traps` | 76 | 42 | 0 | 34 | 4 | 0 |
| **Total (8 Suites)** | **1,177** | **826** | **37** | **55** | **24** | **0** |

---

## Linux 6.6.50 Boot & Single-Owner CPI Telemetry

The Milestone 9 closeout (`tools/run_s1_m9_closeout.py`, saved in [`results/s1-m9-closeout.json`](results/s1-m9-closeout.json)) boots mainline **Linux 6.6.50** in Verilator with zero kernel panics, zero oopses, zero access faults, active 16-bit Sv39 ASIDs, and **0** CPI conservation errors across **90,304,592** simulated cycles (`76,281,757` retired instructions, `2,233,243` U-mode commits, `2,253` demand page faults / `1,027` U-mode, `1,732` U-ecalls, `1,758` S-ecalls, `28,555` UART bytes, `IPC = 0.8447`):

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

Every cycle is mutually exclusively owned by one hardware-asserted bucket (`sum(C_k) == mcycle = 90,304,592`, `cpi_conservation_errors = 0`). Expanding branch checkpoints from 8 to 16 cut `C_be_rename` stalls by **-24.82%** (`5,709,439` → `4,292,514` cycles):

| CPI Category | Cycles | Share | Description |
| :--- | ---: | ---: | :--- |
| `C_productive` | 42,627,877 | 47.20% | Active useful graduation / commit cycles |
| `C_br_recover` | 16,573,571 | 18.35% | Branch misprediction & exception flush recovery |
| `C_idle_other` | 15,481,507 | 17.14% | WFI idle, non-stalled pipeline drain & other bubbles |
| `C_mem_stall` | 5,417,240 | 6.00% | L1D miss / bank conflict / DTLB-PTW memory stalls |
| `C_be_rename` | 4,292,514 | 4.75% | Rename stalls (ROB / Free List / checkpoint capacity) |
| `C_be_sched` | 3,033,600 | 3.36% | Issue queue scheduling / execution operand stalls |
| `C_serialize` | 2,428,266 | 2.69% | CSR / `SFENCE.VMA` / `FENCE.I` / trap serialization |
| `C_fe_starve` | 450,017 | 0.50% | Frontend fetch queue empty (L1I miss / ITLB miss) |
| **Total (`mcycle`)** | **90,304,592** | **100.00%** | **76,281,757 commits (`IPC = 0.8447`)** |

---

## Quickstart (Prerequisites & Verification)

### Prerequisites (Ubuntu 24.04 / WSL2)

```bash
sudo apt-get update
sudo apt-get install -y \
  verilator g++ python3 device-tree-compiler \
  gcc-riscv64-unknown-elf gcc-riscv64-linux-gnu
```

*(Optional, for physical synthesis & STA: `yosys`, `sv2v`, OpenSTA `sta`, and Nangate45 `.lib` via `FURSOY_LIBERTY` or `tools/synth/lib/NangateOpenCellLibrary_typical.lib`. For `sail-riscv` golden-model differential co-simulation: extract the official `sail-riscv v0.16` Linux x86_64 release tarball so `tools/sail/bin/bin/sail_riscv_sim` exists; the Fursoy-matched machine configuration is checked in at [`tools/sail/fursoy_s1_sail_config.json`](tools/sail/fursoy_s1_sail_config.json).)*

### Running Verification

From the repository root:

```bash
# 1. Production RTL lint (Verilator --lint-only, expects 0 warnings/errors)
python3 tools/run_s1_lint.py

# 2. Fast Slice-1 verification regressions
python3 tools/run_s1_m9_phase_a.py   # Interrupts, mideleg, WFI, precise trap boundaries
python3 tools/run_s1_m9_phase_b.py   # CLINT, PLIC, UART 16550 platform peripherals
python3 tools/run_s1_m9_phase_c.py   # 5-master crossbar, DTB, unmapped faults
python3 tools/run_s1_m9_phase_d.py   # SBI v2.0 firmware + mixed-privilege stress
python3 tools/run_s1_m8_closeout.py  # RV64FD + RVV 1.0 FP/Vector backend
python3 tools/run_s1_m7_closeout.py  # Multi-bank non-blocking L1D + coherency
python3 tools/run_s1_m6_closeout.py  # Frontend BPU / IBP / RAS / ITLB / L1I NLP

# 3. Sail-RISC-V golden-model differential co-simulation (8 suites, RV64IMAFDV + Zba + Zbb + Sv39 + traps)
python3 tools/run_s1_sail_cosim.py

# 4. Nangate 45nm @ 500 MHz synthesis & OpenSTA check
python3 tools/run_s1_synth.py --run-synth

# 5. Full Linux 6.6.50 + BusyBox boot closeout (~2.5-3 hours wall time)
# Requires a built RISC-V Image at build/linux-6.6.50/arch/riscv/boot/Image
# (kernel config/patches in software/linux/, initramfs helper in tools/build_initramfs.py).
python3 tools/run_s1_m9_closeout.py
```

---

## Repository Layout

| Directory | Contents |
| :--- | :--- |
| [`rtl/core/`](rtl/core/) | Slice-1 64-bit OoO core SystemVerilog modules (`fursoy_s1_core`, ROB, IntRAT/FRAT/VRAT, IQs, `ks_adder`, ALU/Branch/Mul/Div, FP/Vec, DTLB/ITLB/PTW, L1I/L1D) |
| [`rtl/platform/`](rtl/platform/) | Slice-1/Slice-0 SoC integration (`fursoy_s1_soc`), 5-master crossbar, CLINT, PLIC, 16550 UART |
| [`software/`](software/) | Minimal SBI v2.0 M-mode firmware, Fursoy Slice-1 Device Tree (`fursoy_s1.dts`), Linux 6.6.50 defconfig/patches, BusyBox `/init` & `mem_stress` |
| [`verification/`](verification/) | Verilator C++ self-checking testbenches (`s1_m9_closeout_tb.cpp`, `s1_sail_cosim_tb.cpp`, M5–M9 phase/closeout benches, unit checks) |
| [`tools/`](tools/) | Python lint, regression, Sail cosim (`run_s1_sail_cosim.py`), Linux closeout, synthesis (`run_s1_synth.py`), and analysis runners |
| [`docs/architecture/`](docs/architecture/) | Normative microarchitecture, MMU, cache, and SoC specification documents |
| [`results/`](results/) | Verified milestone JSON evidence reports (`s1-lint.json`, `s1-sail-cosim.json`, `s1-m9-closeout.json`) |

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
