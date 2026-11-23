# FURSOY CPU

**An open-source 64-bit, 2-wide Out-of-Order Superscalar RISC-V Processor (`RV64IMAFD + Zba + Zbb + Zicsr + Zifencei` + `RVV 1.0 integer subset (prototype)` + Sv39) and 1→4-Hart Directory-MESI SMP SoC in SystemVerilog, booting mainline Linux 6.6.50 (`CONFIG_SMP=y`, `RV64IMA` kernel build) and BusyBox userspace.**

**Canonical Architecture & Telemetry Site:** [fursoy.com/cpu](https://fursoy.com/cpu)

---

## Status & Verification Snapshot

- **Frozen Milestones:**
  - **Slice-1 (`fursoy_s1_core` / `fursoy_s1_soc`, `SMP_COHERENCE_EN = 0`):** Single-core 2-wide OoO `RV64IMAFD + Zba + Zbb` + `RVV 1.0 integer subset (prototype)` + `Sv39` Linux 6.6.50 + BusyBox processor, 8/8 `sail-riscv v0.16` directed lockstep suites (`1,177` steps), 0 CPI conservation errors.
  - **Slice-2 (`fursoy_s2_soc`, `SMP_COHERENCE_EN = 1`, `NUM_HARTS = 2` default, `4`-hart verified):** Directory-tracked MESI multicore cluster + shared 256 KiB 8-way inclusive L2, RV64A multi-hart `LR`/`SC` & locked `AMO`, global `FENCE` quiescence, custom SMP SBI v2.0, RVWMO litmus (`128` iters/test) + coherence torture, directed MMIO-vs-MSIP IRQ stress, **14/14 isolated blocks closing 500 MHz Nangate 45nm pre-P&R OpenSTA**, and mainline **Linux 6.6.50 SMP (`N=2` & `N=4`, `RV64IMA` kernel config)** closeout on canonical RTL SHA-256 `bc0502b97739fd8f4556f533618a90b4f2d2cf3a44781c67ea2961298adf1f05`.
- **Design Stage, Scope & Benchmark Honesty:**
  - **Pre-tapeout RTL stage:** Pre-P&R, no physical SRAM compiler integration yet. 500 MHz OpenSTA covers **14 isolated blocks** (`6` Slice-2 + `8` Slice-1) with synthetic combinational-read `.lib` SRAM stubs (`fursoy_sram_macros.lib`); full-core and remaining OoO blocks (`rob`, `prf`, `int_iq`, `lsu_queues`, `bpu`, `mul`, `fma`, `fdiv`, `l1i`) are scheduled for **Slice-2.5**.
  - **ISA & Linux Scope:** Scalar `RV64IMAFD + Zba + Zbb + Zicsr + Zifencei` is implemented; vector execution is an **`RVV 1.0 integer subset (prototype)`** (~30 integer/mask/memory opcodes — no vector FP `OPFVV`/`OPFVF`, no whole-register `vl<nr>r`/`vs<nr>r`, no segmented `nf!=0`). `software/linux/fursoy_s2_defconfig` currently builds Linux 6.6.50 as `RV64IMA` (`CONFIG_FPU`, `CONFIG_RISCV_ISA_V`, `CONFIG_RISCV_ISA_C` disabled; `CONFIG_FPU=y` + FP context-switch stress scheduled for **Slice-2.5**).
  - **Compliance & Benchmarks:** `RISCOF` (`riscv-arch-test`), `10,000`-iter RVWMO litmus scaling, and synthetic benchmarks (`CoreMark`, `Dhrystone`, `Embench-IoT`, `STREAM`) are scheduled for **Slice-2.5** — all performance numbers reported below come directly from cycle-accurate Verilator RTL runs executing Linux 6.6.50, BusyBox, POSIX `pthreads`/`<stdatomic.h>`, and `mem_stress`.

---

## Core Microarchitecture & Pipeline (`fursoy_s1_core`)

The core implements a **12-stage decoupled pipeline** (`F0` GenPC → `F1` ITLB/BPU → `F2` L1I/TAGE/IBP/RAS → `F3` Align/JAL → `F4` FetchQ16 → `D0` 2W Decode → `RN` 2W Rename → `DS` 2W Dispatch → `IS` OoO Issue → `RF` RegRead → `EX` Execute → `WB` / `CMT` 2W In-Order Retire) with `M/S/U` privilege modes, `medeleg`/`mideleg`, `WFI` (`mstatus.TW`), `MRET`/`SRET`, and a fixed M-mode SBI L1I aperture guard in SoC (programmable 16-entry PMP CSRs & non-zero `misa` are deferred to **Slice-3+**; the Slice-0 reference PMP lives in `rtl/core/fursoy_s0_pmp.sv`):

| Subsystem | Verified RTL Parameters | Primary Module(s) |
| :--- | :--- | :--- |
| **ISA & Privilege** | `RV64IMAFD + Zba + Zbb + Zicsr + Zifencei` + `RVV 1.0 integer subset (prototype)` · M/S/U · Sv39 (16-bit ASIDs, 4 KiB / 2 MiB / 1 GiB) · `mhartid_i` · fixed SBI L1I guard (programmable PMP CSRs & `misa` deferred to Slice-3+) | `fursoy_s1_decode.sv`, `fursoy_s1_csr.sv` |
| **Frontend & BPU** | 2-wide fetch/decode (`FETCH_QUEUE_DEPTH = 16`) · **512-entry 2-way BTB** (`256×2`, 53b tag) · **30,208-bit TAGE-Lite** (`T0`: 2048×2b + `T1..T4`: 512 sets, 108-bit GHR) · **64-entry tagged IBP** (`IBP_ENTRIES = 64`) · **16-entry RAS** (`INDEXED_RAS_CHKPT = 32` slots) | `fursoy_s1_frontend.sv`, `fursoy_s1_bpu.sv`, `fursoy_s1_fetch_queue.sv` |
| **ROB, PRFs & Recovery** | **`ROB_DEPTH = 128`** (2W alloc / 2W retire, 4-bit epochs) · **`NUM_CHECKPOINTS = 16`** (expanded 8→16; 1-cycle SRAT/FRAT/VRAT/GHR/RAS rollback) · **`PRF_SIZE = 160`** (`128` FL) · **`FPRF_SIZE = 64`** (`32` FL) | `fursoy_s1_pkg.sv`, `fursoy_s1_rob.sv`, `fursoy_s1_substrate.sv`, `fursoy_s1_rat.sv`, `fursoy_s1_frat.sv` |
| **Issue Queues & Scalar Ports** | **`INT_IQ_DEPTH = 32`** (2W → **P0**: ALU0 KS / BRU KS / CSR / I2F; **P1**: ALU1 + `alu1_fifo` / 3c-latency MUL [1-stage comb product + 2 delay regs; true pipelined MUL in S2.5] / ~34c iterative Radix-4 DIV) · **`MEM_IQ_DEPTH = 32`** (2W → **P2/AGU0**: all mem; **P3/AGU1**: loads only) · **`FPIQ_DEPTH = 16`** (1W → **P4**: 3c/4c FMA / 12–28c behavioral latency-counted FDIV-FSQRT [true iterative Radix-4 SRT in S2.5] / 2-stage FCONV) | `fursoy_s1_int_iq.sv`, `fursoy_s1_mem_iq.sv`, `fursoy_s1_fp_iq.sv`, `fursoy_s1_ks_adder.sv` |
| **RVV 1.0 Integer Subset (Prototype)** | **`VLEN = 256`**, **`ELEN = 64`**, **`VLENB = 32`** · **`VRF_NUM_PREGS = 64`** (`64 × 256b`, 4 banks × 64b, 4R+1W; `p0..p31` arch, `p32..p63` bitmap-renamed via `fursoy_s1_vrat`) · **`VIQ_DEPTH = 8`** · `LMUL = 1..8`, `vstart` resumption, 128-bit dual-lane SIMD beats, ~30 integer/mask/memory opcodes (`vle`/`vleff`/`vlse`/`vluxei`/`vsoxei`, `nf=0`; no vector FP `OPFVV`/`OPFVF`, no whole-reg `vl<nr>r`/`vs<nr>r`; behavioral `VEC_VDIV` replaced in S2.5) | `fursoy_s1_vrat.sv`, `fursoy_s1_vrf.sv`, `fursoy_s1_vec_iq.sv`, `fursoy_s1_core.sv` |
| **LSU & Disambiguation** | **`LQ_DEPTH = 16`**, **`SQ_DEPTH = 16`** store-to-load forwarding, speculative `S0`/`S1` snoop replay, coherence-point `sc_acquire_req` + LFSR ping-pong backoff, 2-cycle L1D `amo_line_lock_q`, atomic **MMIO-vs-IRQ preemption interlock** | `fursoy_s1_lsu.sv`, `fursoy_s1_lsu_queues.sv`, `fursoy_s1_trt.sv` |

---

## Memory Hierarchy & Multicore SMP Architecture (`fursoy_s2_soc`)

```text
  +----------------------+         +----------------------+
  |  fursoy_s1_core #0   |   ...   | fursoy_s1_core #N-1  |  N = 2 (default) or 4
  |  SMP_COHERENCE_EN=1  |         |  SMP_COHERENCE_EN=1  |  2W OoO RV64IMAFD+RVV(int) + Sv39
  |  L1I 16K · L1D 16K8B |         |  L1I 16K · L1D 16K8B |  ITLB/DTLB 64+8 · PTW
  +----+------+------+---+         +----+------+------+---+
       |      |      |                  |      |      |
     MMIO    PTW   L1I / L1D (4-VC)   MMIO    PTW   L1I / L1D (4-VC)
       |      |  VC0_RD / VC0_WR / VC1 / VC2   |      |
       |      +------+------------------+------+------+
       |             v
       |   +--------------------------------------------+
       |   |  fursoy_s2_coherence_mgr + fursoy_s2_l2    |  3-stage C0/C1/C2 Hub
       |   |  256 KiB 8-Way Inclusive L2 (512 sets)     |  8 DIR_MSHRs · MESI Directory
       |   +---------------------+----------------------+
       |                         | 512-bit DRAM Port
       v                         v
  +------------------------+   256 MiB Main DRAM (0x8000_0000..0x8FFF_FFFF)
  |  fursoy_s2_mmio_xbar   |   (Lower 2 MiB reserved: M-mode SBI v2.0 0xF00501)
  +----+-------+-------+---+
       |       |       |
       v       v       v
  fursoy_s2_clint  fursoy_s2_plic  fursoy_s0_uart
  (0x0200_0000)    (0x0C00_0000)   (0x1000_0000)
```

- **Sv39 MMU (`fursoy_s1_itlb`, `fursoy_s1_dtlb`, `fursoy_s1_ptw`):** Dual-port DTLB (`p0`+`p1`) and ITLB each pair a `64`-entry 4-way Tree-PLRU base TLB (`16` sets) with an `8`-entry 2 MiB / 1 GiB superpage CAM, `16`-bit ASIDs, `32`-entry `TRT` / `2`-entry `ITRT`. Shared PTW probes local dirty L1D lines in 1 cycle with zero eviction and routes local misses through `fursoy_s2_coherence_mgr` (`COH_GETS_NC`) to observe remote dirty PTEs.
- **L1I (`fursoy_s1_l1i`):** `16 KiB`, 4-way VIPT (`64` sets × `64 B`), page-bounded conservative next-line prefetcher, `2` I-MSHRs with stale-response discard tracking across `FENCE.I`, coherent `COH_GETS_NC` L2 refill.
- **L1D (`fursoy_s1_l1d`):** `16 KiB`, 4-way VIPT (`64` sets × `64 B`), **8-bank (`PA[5:3]`) non-blocking** write-back cache, 3-bit Tree-PLRU, `4` MSHRs (`COH_GETS`/`COH_GETM`/`COH_UPGRADE`), `2` WBBs (`PutM`), **2-stage registered snoop pipeline (`S0`/`S1`)**, and `SMP_COHERENCE_EN` toggle preserving bit-identical Slice-1 single-core behavior (`0`).
- **Shared L2 & Directory MESI Hub (`fursoy_s2_l2`, `fursoy_s2_coherence_mgr`):** **`256 KiB` 8-way inclusive L2** (`512` sets × `8` ways × `64 B`) tracking per-line `L2_I`/`L2_S`/`L2_M`, `sharer_vec[N-1:0]`, and `owner_id` behind **`8` `DIR_MSHR`s** (`line_addr` + `victim_addr` hazard tracking). Four deadlock-free virtual channels (`VC0_RD`, `VC0_WR`, `VC1`, non-blocking `VC2`) across 3 pipeline stages (`C0`/`C1`/`C2`) with cache-to-cache `M→I`/`M→S` dirty forwarding.
- **SMP Platform & Custom SBI v2.0:** Registered round-robin `fursoy_s2_mmio_xbar`, parameterized `fursoy_s2_clint` (`msip[h]`, `mtimecmp[h]`, `mtime`), `2*N`-context binary-tree `fursoy_s2_plic` (`31` sources), shared `16550 UART` (`fursoy_s0_uart`), and custom M-mode **SBI v2.0** (`software/firmware/fursoy_s2_sbi_*`, `IMPL_ID = 0xF00501`: `BASE`, `TIME`, `sPI`, re-entrant `RFENCE`, `HSM`, `SRST`, `DBCN`).

---

## Verified Silicon & Software Proof

All metrics below were measured on final canonical RTL (`bc0502b9...`).

### 1. Mainline Linux 6.6.50 + BusyBox Boot Closeout (Single-Core & SMP)

> **Kernel ISA Scope:** `software/linux/fursoy_s2_defconfig` (and `fursoy_s0_defconfig`) build Linux 6.6.50 as `RV64IMA` (`CONFIG_FPU`, `CONFIG_RISCV_ISA_V`, `CONFIG_RISCV_ISA_C`, `CONFIG_RISCV_ISA_ZBB` disabled); Linux `CONFIG_FPU=y` + FP context-switch validation is scheduled for **Slice-2.5**.

| Configuration | Artifact | Cycles | Retired Insts | Aggregate IPC | Verified Userspace & Correctness |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`S2-M5` · `N=2` SMP** | [`results/s2-m5-closeout.json`](results/s2-m5-closeout.json) | 41,096,621 | 43,732,996 | **1.0642** | `CONFIG_SMP=y` (`RV64IMA`), 2 online harts (`U`-commits `1.66M / 0.81M`), `pthreads` + `<stdatomic.h>` (`atomic=4000, cas=6000, mutex=600`) + `mem_stress` + BusyBox PASS, 0 panics/traps |
| **`S2-M5` · `N=4` SMP** | [`results/s2-m5-closeout.json`](results/s2-m5-closeout.json) | 48,380,518 | 60,175,709 | **1.2438** | `CONFIG_SMP=y` (`RV64IMA`), 4 online harts (`U`-commits `0.71M / 1.79M / 0.23M / 0.60M`), `pthreads` + `<stdatomic.h>` (`atomic=8000, cas=20000, mutex=2000`) + `mem_stress` + BusyBox PASS, 0 panics/traps |
| **`S1-M9` · Single-Core Baseline** | [`results/s1-m9-closeout.json`](results/s1-m9-closeout.json) (frozen Slice-1 Gate G5) | 90,304,592 | 76,281,757 | **0.8447** | 20 BusyBox shell tests + `mem_stress`, `2,233,243` U-commits, `2,253` page faults (`1,027` U-mode), **0 CPI conservation errors** across all 90,304,592 cycles |
| **`S1-M9` · Post-Slice-2 Non-Reg** | Uncommitted local re-run (`SMP_COHERENCE_EN=0`, RTL `bc0502b9`) | 90,325,303 | 76,299,307 | **0.8447** | 20 BusyBox shell tests + `mem_stress`, `2,232,455` U-commits, `2,255` page faults (`1,026` U-mode), **0 CPI conservation errors** across all 90,325,303 cycles |

<details>
<summary><strong>Single-Owner 8-Bucket CPI Conservation Breakdown (Uncommitted Local Post-Slice-2 S1-M9 Non-Regression: 90,325,303 Cycles, 0 Errors; Frozen Baseline in <code>results/s1-m9-closeout.json</code>: 90,304,592 Cycles)</strong></summary>

| CPI Category | Cycles | Share | Architectural Cause |
| :--- | ---: | ---: | :--- |
| `C_productive` | 42,643,226 | 47.21% | Active useful graduation / commit cycles |
| `C_br_recover` | 16,565,588 | 18.34% | Branch misprediction & exception flush recovery |
| `C_idle_other` | 15,477,240 | 17.14% | `WFI` idle, non-stalled pipeline drain & bubbles |
| `C_mem_stall` | 5,419,980 | 6.00% | L1D miss / bank conflict / DTLB-PTW memory stalls |
| `C_be_rename` | 4,295,243 | 4.76% | Rename stalls (ROB / Free List / 16-checkpoint capacity) |
| `C_be_sched` | 3,035,353 | 3.36% | Issue queue scheduling / operand stalls |
| `C_serialize` | 2,437,534 | 2.70% | CSR / `SFENCE.VMA` / `FENCE.I` / trap serialization |
| `C_fe_starve` | 451,139 | 0.50% | Frontend fetch queue empty (L1I / ITLB miss) |
| **Total (`mcycle`)** | **90,325,303** | **100.00%** | **76,299,307 commits (`IPC = 0.8447`, 0 conservation errors)** |

</details>

### 2. Formal Reference Parity, RVWMO Litmus, Coherence Torture & Directed Stress

| Verification Suite | Artifact / Runner | Result | Key Metrics |
| :--- | :--- | :---: | :--- |
| **Sail-RISC-V `v0.16` Co-Sim** | [`results/s1-sail-cosim.json`](results/s1-sail-cosim.json) | **PASS** | `8/8` suites (`1,177` Sail steps: `826` GPR, `37` FPR, `55` VRF group, `24` trap checks) — **0 mismatches** |
| **`S2-M1` Multi-Hart Bring-Up** | [`results/s2-m1-closeout.json`](results/s2-m1-closeout.json) | **PASS** | `N=2` (`11,451` cyc) & `N=4` (`19,940` cyc): per-hart `mhartid`, CLINT MSIP/MTIP, PLIC multi-context |
| **`S2-M2` MESI Coherence + SWMR** | [`results/s2-m2-closeout.json`](results/s2-m2-closeout.json) | **PASS** | `N=2` (`14,551` cyc) & `N=4` (`18,468` cyc): `M→S`/`M→I` forwarding, WBB races, coherent L1I/PTW — **0 SWMR violations** |
| **`S2-M3` RV64A Atomics & SBI** | [`results/s2-m3-closeout.json`](results/s2-m3-closeout.json) | **PASS** | `N=2` (`53,048` cyc) & `N=4` (`85,366` cyc): contended `LR`/`SC`, `AMO`, global `FENCE`, simultaneous `SBI RFENCE` — **0 SWMR violations** |
| **`S2-M4` RVWMO Litmus Suite** | [`results/s2-m4-closeout.json`](results/s2-m4-closeout.json) | **PASS** | `MP`, `SB`, `LB`, `IRIW`, `CoRR`, `CoWR`, `CoRW`, `CoWW` (`128` iters/test; `10,000` iters/test in Slice-2.5) on `N=2` (`495,111` cyc) & `N=4` (`581,323` cyc) — **0 forbidden**, **0 SWMR violations** |
| **`S2-M4` Coherence Torture** | [`results/s2-m4-closeout.json`](results/s2-m4-closeout.json) | **PASS** | `N=2` (`166,762` commits) & `N=4` (`344,879` commits) exercising MESI `S`/`E`/`M` & dirty WBBs — **0 SWMR/data/inclusion violations** |
| **MMIO-vs-MSIP IRQ Stress** | `tools/run_s2_mmio_irq_stress.py` | **PASS** | `84,854` cyc, `952` M-mode MSIP preemptions, `128/128` exact UART bytes (`0` dups/drops), `128/128` exact PLIC Claims (`0` bad claims, `0` leaked `in_service`), **0 SWMR violations** |

### 3. Physical Synthesis & 500 MHz Nangate 45nm OpenSTA (`14 / 14 Isolated Blocks MET`)

Synthesized via `sv2v v0.0.13` → `Yosys 0.33` → `OpenSTA 3.1.0` on **NangateOpenCellLibrary 45nm Typical (1.10V, 25C)** (`NAND2_X1 = 0.798 um²`) targeting **500 MHz (`2.000 ns`)**, pre-P&R (`tools/run_s2_synth.py`, recorded in [`results/s2-m4-closeout.json`](results/s2-m4-closeout.json); `all_logs_fresh = true`, `0` OpenSTA Warning 1216/441, **`TNS = 0.000 ns`** across **14 isolated blocks** — `6` Slice-2 + `8` Slice-1):

| Module | Scope | Cells | DFFs | Area (kGE) | Max Delay | WNS @ 500 MHz |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: |
| `fursoy_s2_mmio_xbar` (`N=4`) | Slice-2 SMP | 2,059 | 213 | 3.59 | 1.181 ns | **+0.735 ns (MET)** |
| `fursoy_s2_plic` (`N=4`, 8-ctx) | Slice-2 SMP | 10,715 | 561 | 17.66 | 1.407 ns | **+0.505 ns (MET)** |
| `fursoy_s2_l2` (`N=4`, 512 sets, SRAM `.lib`) | Slice-2 SMP | 1,558,821 | 212,480 | 3,269.96 | 1.436 ns | **+0.314 ns (MET)** |
| `fursoy_s2_clint` (`N=4`) | Slice-2 SMP | 2,979 | 394 | 5.77 | 1.559 ns | **+0.357 ns (MET)** |
| `fursoy_s1_l1d` (`SMP=1`, 64 sets, SRAM `.lib`) | Slice-2 SMP | 216,202 | 20,942 | 468.32 | 1.723 ns | **+0.027 ns (MET)** |
| `fursoy_s2_coherence_mgr` (`N=4`, 512 sets, **includes `fursoy_s2_l2`**) | Slice-2 SMP | 1,857,576 | 224,327 | 3,831.60 | 1.902 ns | **+0.008 ns (MET)** |
| `fursoy_s1_agu` | Slice-1 Core | 817 | 0 | 1.07 | 0.510 ns | **+1.490 ns (MET)** |
| `fursoy_s1_branch_unit` | Slice-1 Core | 4,086 | 0 | 5.45 | 0.601 ns | **+1.399 ns (MET)** |
| `fursoy_s1_ptw` | Slice-1 Core | 1,797 | 329 | 3.81 | 0.892 ns | **+1.069 ns (MET)** |
| `fursoy_s1_decode` | Slice-1 Core | 2,777 | 0 | 3.70 | 0.979 ns | **+1.021 ns (MET)** |
| `fursoy_s1_alu` | Slice-1 Core | 4,326 | 0 | 6.34 | 1.153 ns | **+0.847 ns (MET)** |
| `fursoy_s1_itlb` (flop array) | Slice-1 Core | 36,755 | 6,304 | 77.52 | 1.214 ns | **+0.586 ns (MET)** |
| `fursoy_s1_dtlb` (flop array) | Slice-1 Core | 50,517 | 6,515 | 99.87 | 1.253 ns | **+0.547 ns (MET)** |
| `fursoy_s1_csr` | Slice-1 Core | 14,491 | 1,872 | 27.89 | 1.342 ns | **+0.623 ns (MET)** |

> **STA Scope, Hierarchy & Macro Note:**
> - **Hierarchy containment:** `fursoy_s2_coherence_mgr` **instantiates `fursoy_s2_l2`** — its `3,831.60 kGE` / `224,327 DFFs` total includes the embedded `fursoy_s2_l2` instance (`3,269.96 kGE` / `212,480 DFFs`); standalone coherence manager logic is `~561.6 kGE` / `~11.8k DFFs`.
> - **Isolated-block boundary:** Slice-1's 8 gated blocks total `115,566` cells / `15,020` DFFs / `225.65 kGE` (`180,058.86 um²`). Full-core top-level and remaining OoO blocks (`rob`, `prf`, `int_iq`, `lsu_queues`, `bpu`, `mul`, `fma`, `fdiv`, `l1i`) are **not yet 500 MHz STA-closed** and are scheduled for **Slice-2.5**.
> - **Synthetic SRAM `.lib` stubs:** `fursoy_s2_l2`, `fursoy_s2_coherence_mgr`, and `fursoy_s1_l1d` abstract cache data arrays with deterministic combinational-read Liberty timing stubs (`fursoy_sram_macros.lib`, `0.350 ns` L1D / `0.400 ns` L2, generated by `tools/run_s2_synth.py`), while tag/directory/TLB arrays remain standard-cell flip-flop synthesized (pre-SRAM-compiler / pre-P&R).

---

## Reproducibility & Open-Source EDA Toolchain

### Verified Environment (Ubuntu 24.04 Linux / WSL2)

- **Simulation & Compilers:** `Verilator 5.020`, `g++`, `Python 3`, `device-tree-compiler`, `RISC-V GCC 13.2.0` (`gcc-riscv64-unknown-elf`, `gcc-riscv64-linux-gnu`)
- **Golden Model:** `sail-riscv 0.16` (`tools/sail/bin/bin/sail_riscv_sim`, config at [`tools/sail/fursoy_s1_sail_config.json`](tools/sail/fursoy_s1_sail_config.json))
- **Synthesis & STA:** `sv2v v0.0.13`, `Yosys 0.33`, `OpenSTA 3.1.0`, Nangate 45nm Typical `.lib` (`FURSOY_LIBERTY` or `tools/synth/lib/NangateOpenCellLibrary_typical.lib`)

```bash
sudo apt-get update && sudo apt-get install -y \
  verilator g++ python3 device-tree-compiler \
  gcc-riscv64-unknown-elf gcc-riscv64-linux-gnu
```

### Clean-Clone Verification Commands

```bash
# 1. Production RTL lint (Verilator --lint-only -Wall, expects 0 warnings/errors)
python3 tools/run_s1_lint.py

# 2. Sail-RISC-V v0.16 8-suite lockstep differential co-simulation
python3 tools/run_s1_sail_cosim.py

# 3. Slice-2 SMP verification suite (N=2 & N=4)
python3 tools/run_s2_m1.py              # Multi-hart mhartid, CLINT MSIP/MTIP, PLIC contexts
python3 tools/run_s2_m2.py              # Directory MESI coherence, 2-stage snoop, SWMR monitor
python3 tools/run_s2_m3.py              # RV64A LR/SC & AMO, global FENCE, SMP SBI v2.0
python3 tools/run_s2_mmio_irq_stress.py # Directed atomic MMIO-vs-MSIP IRQ preemption stress
python3 tools/run_s2_m4.py              # RVWMO Litmus + randomized multi-hart torture + 500 MHz STA

# 4. Standalone 14-block 500 MHz Nangate 45nm synthesis & OpenSTA check
python3 tools/run_s2_synth.py

# 5. Full mainline Linux 6.6.50 + BusyBox boot closeouts
#    (Kernel defconfigs in software/linux/fursoy_s0_defconfig & fursoy_s2_defconfig;
#     initramfs builder in tools/build_initramfs.py; parameterized DTB in tools/gen_s2_dts.py)
python3 tools/run_s2_m5.py              # Linux 6.6.50 CONFIG_SMP=y (N=2 & N=4) + pthreads/atomics
python3 tools/run_s1_m9_closeout.py     # Slice-1 single-core (SMP_COHERENCE_EN=0) non-regression
```

---

## Repository & RTL Module Hierarchy

| Directory | Key Modules & Artifacts |
| :--- | :--- |
| [`rtl/core/`](rtl/core/) | `fursoy_s1_core.sv` (`fursoy_s1_pkg.sv`, `frontend`, `bpu`, `fetch_queue`, `decode`, `substrate`, `rat`/`frat`/`vrat`, `rob`, `prf`/`fprf`/`vrf`, `int_iq`/`mem_iq`/`fp_iq`/`vec_iq`, `ks_adder`, `alu`/`branch_unit`/`multiplier`/`divider`/`fma`/`fdiv`/`fconv`, `agu`/`lsu`/`lsu_queues`/`trt`, `itlb`/`dtlb`/`ptw`, `l1i`/`l1d`, `csr`, `hpm`) + Slice-0 reference modules |
| [`rtl/platform/`](rtl/platform/) | **Slice-2 SMP:** `fursoy_s2_soc.sv`, `fursoy_s2_coherence_mgr.sv`, `fursoy_s2_l2.sv`, `fursoy_s2_mmio_xbar.sv`, `fursoy_s2_clint.sv`, `fursoy_s2_plic.sv` · **Slice-1/0:** `fursoy_s1_soc.sv`, `fursoy_s0_uart.sv`, `fursoy_s0_clint.sv`, `fursoy_s0_plic.sv` |
| [`software/`](software/) | Custom M-mode SBI v2.0 (`fursoy_s1_sbi_*`, `fursoy_s2_sbi_*`), Linux 6.6.50 defconfigs (`fursoy_s0_defconfig`, `fursoy_s2_defconfig`), BusyBox `/init` + `s2_smp_test.c`, and bare-metal SMP/litmus/torture/IRQ-stress tests |
| [`verification/`](verification/) | Verilator C++ testbenches (`s2_swmr_scoreboard.h`, `s2_m1..m5*_tb.cpp`, `s2_mmio_irq_stress_tb.cpp`, `s1_sail_cosim_tb.cpp`, `s1_m9_closeout_tb.cpp`) |
| [`tools/`](tools/) | Python runners (`run_s1_lint.py`, `run_s1_sail_cosim.py`, `run_s1_m9_closeout.py`, `run_s2_m1..m5.py`, `run_s2_mmio_irq_stress.py`, `run_s2_synth.py`, `gen_s2_dts.py`, `build_initramfs.py`) |
| [`docs/architecture/`](docs/architecture/) | Frozen architecture contracts (`slice2-smp-v1.md`, `slice1-core-v1.md`, `slice1-m7-multibank-l1d-v1.md`, `slice1-m9-soc-linux-v1.md`, `sv39-mmu-v1.md`, `pmp-v1.md`, `plic-v1.md`, `rv64a-v1.md`) |
| [`results/`](results/) | Verified milestone JSON evidence (`s1-lint.json`, `s1-sail-cosim.json`, `s1-m9-closeout.json`, `s2-m1..m5-closeout.json`) |

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
