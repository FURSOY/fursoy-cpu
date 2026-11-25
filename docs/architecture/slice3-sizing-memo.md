# Fursoy CPU — Slice-2.5 Physical Characterization & Slice-3 Sizing Memo

- **Document ID:** `docs/architecture/slice3-sizing-memo.md`
- **Status:** Slice-2.5 Closeout Analysis (`S2.5-M4`) — Grounded strictly in verified Nangate45 OpenSTA, Verilator RTL, and Sail-RISCV artifacts (zero unmeasured projections, zero RTL edits in `S2.5-M4`).
- **Canonical RTL SHA-256:** `3da97dcef426ef3d3bfebd6c21399df21ba24ea9fce2ce4fd5503e1b408da7dc` (`44` `CORE_RTL` + `4` `PLATFORM_RTL` manifest files; `71` total `.sv` files under `rtl/` hashed by `compute_rtl_sha256()`).
- **Authoritative Evidence Inputs:**
  - `results/s25-core-sta.json` (SHA-256 `7d72170b43c7...`) — Core-wide Nangate45 OpenSTA & Synchronous SRAM Sensitivity
  - `results/s25-m1b-arith.json` (SHA-256 `49688e1e9690...`) — Synthesizable Radix-4 FDIV/VDIV & Booth/Wallace Multiplier
  - `results/s25-riscof.json` (SHA-256 `cece63347e3f...`) — Official `RISCOF` (`riscv-arch-test`) vs `sail-riscv v0.16`
  - `results/s25-sail-fuzz.json` (SHA-256 `a33500350d07...`) — 20-Seed Constrained-Random Lockstep Fuzzer
  - `results/s25-litmus-10k.json` (SHA-256 `fddd7ea91f3e...`) — Contract-Scale `LITMUS_ITERS=10,000` RVWMO (`N=2, 4`)
  - `results/s25-benchmarks.json` (SHA-256 `630d2aefb85f...`) — Bare-Metal CoreMark, Embench-IoT v2.0, STREAM FP64, Dhrystone 2.1
  - `results/s25-linux-fpu-smp.json` (SHA-256 `43ef44bc750a...`) — Mainline Linux 6.6.50 `CONFIG_SMP=y` + `CONFIG_FPU=y` (`N=2, 4`)

---

## 1. Executive Summary & Verified Slice-2.5 Baseline

Slice-2.5 established an honest, industry-auditable baseline across functional compliance, SMP Linux + FPU execution, steady-state benchmarks, and **whole-core** Nangate45 gate-level timing/area:

| Evidence Pillar | Verified Slice-2.5 Measurement | Artifact |
|---|---|---|
| **ISA Compliance (`RISCOF`)** | **245 / 245 (100.0%)** pass against `sail-riscv v0.16` (`RV64IMAFD_Zba_Zbb_Zicsr_Zifencei`) | `results/s25-riscof.json` |
| **Random Lockstep Fuzzing** | **20 / 20 seeds**, **157,972** retired insts, **113,142** GPR / **19,781** FPR / **480** trap checks, **0 mismatches** | `results/s25-sail-fuzz.json` |
| **SMP RVWMO Memory Model** | **8 / 8 patterns × 10,000 iters/test** on `N=2` (`37.83M` cyc) & `N=4` (`44.27M` cyc): **0 forbidden**, **0 SWMR violations** | `results/s25-litmus-10k.json` |
| **Mainline Linux 6.6.50 SMP+FPU** | S-mode FPU Sail pre-check `209/209` (`0` mismatches); `N=2` (`45.28M` cyc, 24 migrations / 1,536 reg checks) & `N=4` (`52.73M` cyc, 48 migrations / 3,072 reg checks), `10/10` markers, `0` fatals | `results/s25-linux-fpu-smp.json` |
| **Steady-State Benchmarks** | CoreMark `3.7748 CM/MHz` (S1) / `15.2235 CM/MHz` (`N=4`, `4.0329×`); Embench-IoT v2.0 `19/19` geomean `IPC=1.2874` (`1.9445×` Cortex-M4); STREAM FP64 Triad `10,699.8 MB/s` (`N=4`, `3.592×`); Dhrystone 2.1 `1.7127 DMIPS/MHz` | `results/s25-benchmarks.json` |
| **Synthesizable Arithmetic** | `fdiv` (`22.89 kGE`, `657.9 MHz`), `vec_div` (`13.63 kGE`, `898.5 MHz`), `multiplier` (`41.24 kGE`, `817.0 MHz`); `0` `$div`/`$mod` cells | `results/s25-m1b-arith.json` |
| **Gated 14-Block Baseline (`run_s2_synth.py`)** | **14 / 14 PASS** at `500 MHz` (`2.000 ns`), `0` Warning 1216 / `0` Warning 441 | `build/synth_s2/s2_synth_report.json` |
| **Whole-Core OpenSTA (`S2.5-M4`)** | **35 / 37** core leaf blocks synthesized (`23/25` newly characterized + `8` S1 gated + `1` L1D + `3` M1b); **27 meet `500 MHz`**, **8 violate `500 MHz`**, **2 hit Yosys 16 GiB flop-array synthesis walls** (`lsu_queues`, `bpu`); **true unoptimized worst-case core `Fmax` = `45.7 MHz`** (`fursoy_s1_int_iq`) | `results/s25-core-sta.json` |

### Critical Honesty Headline for Slice-3 Planning

1. **The prior 14-block `500 MHz` gate did not cover the OoO issue queues, FMA, or vector rename/queue blocks.** Full core-wide OpenSTA (`0` false/multicycle paths, `0` Warning 1216/441) proves that while 27/35 characterized core leaf blocks already clear `500 MHz` (including `rob` at `570.1 MHz`, `prf` at `861.3 MHz`, `l1i` at `668.0 MHz`, `vrf` at `961.5 MHz`, `rat`/`frat`/`freelist` at `581.7–637.8 MHz`), **8 blocks violate `500 MHz`**, led by serial `for`-loop age-comparison chains in `fursoy_s1_int_iq` (`45.7 MHz`) and `fursoy_s1_mem_iq` (`47.2 MHz`), and serial LZC loops in `fursoy_s1_fma` (`187.4 MHz`).
2. **Flop-based storage arrays dominate both silicon area and synthesis runtime.** Bottom-up across the 35 characterized core leaf blocks (still excluding `lsu_queues`, `bpu`, and wrapper glue), a single core consumes **`5,373.87 kGE` and `316,450 DFFs`**—of which `fursoy_s1_l1i` alone (`16 KiB` flop-based cache) consumes **`1,805.03 kGE` (`143,354 DFFs`, 33.6% of characterized core area)**, while `fursoy_s1_bpu` exceeded `14.8 GiB` RAM in Yosys flop synthesis.
3. **Coherence Manager vs. L2 Area Decomposition (No Double-Counting):** `fursoy_s2_coherence_mgr` instantiates `fursoy_s2_l2` internally. Its reported `3,831.60 kGE` (`224,327 DFFs`) is **inclusive of L2** (`3,269.96 kGE`, `212,480 DFFs`, itself dominated by flop-based L2 tag/directory/MOESI arrays with only data lines blackboxed); **standalone coherence controller logic is `561.64 kGE` (`11,847 DFFs`)**.

---

## 2. Whole-Core Nangate45 OpenSTA Characterization & True Hardware `Fmax` Walls

All 25 previously uncharacterized core leaf modules were evaluated sequentially via `tools/run_s25_core_sta.py` (`sv2v v0.0.13` -> `Yosys 0.33` Nangate45 -> `OpenSTA 3.1.0`, `T = 2.000 ns` / `500 MHz`, `0.05 ns` clock uncertainty, `0.20 ns` input/output delay, `[all_inputs -no_clocks]`, `0` `set_false_path`, `0` `set_multicycle_path`, `0` Warning 1216, `0` Warning 441).

### 2.1 The 8 Core `Fmax` Walls Violating `500 MHz` (Ranked Worst-First)

| Rank | Module | Mapping Mode | Area (kGE) | DFFs | Arrival (ns) | WNS @ 500 MHz (ns) | Est. `Fmax` (MHz) | OpenSTA Critical Path (`Startpoint -> Endpoint`) | Verified RTL Root Cause (`file:line`) |
|---:|---|---|---:|---:|---:|---:|---:|---|---|
| 1 | `fursoy_s1_int_iq` | `abc_d1000` | 203.08 | 12,160 | 21.633 | **-19.883** | **45.7** | `rob_head_i[3]` -> `issue0_uop_o[23]` | `rtl/core/fursoy_s1_int_iq.sv:374-441` — Two back-to-back serial 32-entry `for`-loop `rob_dist` oldest-first age-comparison chains (u0 scan -> u1/bipartite scan = 64 serial compare-mux levels in 1 cycle) |
| 2 | `fursoy_s1_mem_iq` | `abc_d1000` | 94.70 | 6,080 | 20.915 | **-19.165** | **47.2** | `rob_head_i[1]` -> `free_count_o[4]` | `rtl/core/fursoy_s1_mem_iq.sv:157-178` — Two consecutive serial 32-entry `for`-loop `rob_dist` oldest-first age-selection chains feeding dual-port select and occupancy count |
| 3 | `fursoy_s1_fma` | `abc_d1000` | 68.11 | 1,239 | 5.087 | **-3.337** | **187.4** | `_88926_` -> `wb_data_o[12]` | `rtl/core/fursoy_s1_fma.sv:734-742,845-853,1042` — Serial `for (int k = 78/162; k >= 0; k--)` 79-bit SP / 163-bit DP LZC + wide barrel left-shift + SP rounding + `wb_data_o` output mux in Stage 3 |
| 4 | `fursoy_s1_fp_iq` | `abc_d1000` | 29.63 | 2,096 | 4.886 | **-3.136** | **194.7** | `rob_head_i[1]` -> `issue_uop_o[10]` | `rtl/core/fursoy_s1_fp_iq.sv` — Single 16-entry serial `for`-loop `rob_dist` age-comparison chain (`16` serial levels vs `64` in `int_iq`) |
| 5 | `fursoy_s1_vec_iq` | `mem2reg_abc_d1000` | 79.36 | 3,108 | 2.946 | **-1.037** | **329.3** | `rob_head_i[6]` -> `_87452_` | `rtl/core/fursoy_s1_vec_iq.sv` — 8-entry serial `rob_dist` age-ordered selection + vector operand readiness check |
| 6 | `fursoy_s1_vrat` | `mem2reg_abc_d1000` | 268.98 | 17,120 | 2.459 | **-0.552** | **391.8** | `_228092_` -> `_229080_` | `rtl/core/fursoy_s1_vrat.sv:107-192` — Single-cycle 32-bit popcount bitmap rank allocator (`LMUL` up to 8 regs) + SRAT/16-checkpoint update + 128-entry ROB metadata walk |
| 7 | `fursoy_s1_hpm` | `abc_d1000` | 62.25 | 4,162 | 2.401 | **-0.485** | **402.4** | `retire_rob_idx_i[1]` -> `_65344_` | `rtl/core/fursoy_s1_hpm.sv:190-215` — Combinational `retire_rob_idx_i == pending_mispred_rob_idx_q` feeding directly into 64-bit HPM/CPI counter increments |
| 8 | `fursoy_s1_fconv` | `abc_d1000` | 46.91 | 3,219 | 1.947 | **-0.031** | **492.4** | `_45650_` -> `_43111_` | `rtl/core/fursoy_s1_fconv.sv` — Marginal `31 ps` shortfall on FP-to-Int/Int-to-FP conversion & rounding datapath |

### 2.2 Newly Characterized Core Blocks Meeting `500 MHz` (`15 / 23` Passing)

| Module | Group | Mapping Mode | Area (kGE) | Cells | DFFs | Arrival (ns) | WNS (ns) | Est. `Fmax` (MHz) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| `fursoy_s1_rob` | Primary OoO | `abc_d1000` | 572.08 | 328,755 | 29,470 | 1.504 | +0.246 | 570.1 |
| `fursoy_s1_prf` | Primary OoO | `abc_d1000` | 618.67 | 303,237 | 16,384 | 0.911 | +0.839 | 861.3 |
| `fursoy_s1_fprf` | Primary OoO | `abc_d1000` | 102.71 | 48,981 | 4,096 | 0.811 | +0.939 | 942.5 |
| `fursoy_s1_divider` | Primary OoO | `abc_d1000` | 1.43 | 801 | 91 | 1.099 | +0.817 | 845.3 |
| `fursoy_s1_l1i` | Primary OoO | `abc_fast_nomem2reg` | **1,805.03** | **1,021,062** | **143,354** | 1.247 | +0.503 | 668.0 |
| `fursoy_s1_vrf` | Primary OoO | `abc_d1000` | 332.37 | 162,739 | 16,384 | 0.790 | +0.960 | 961.5 |
| `fursoy_s1_freelist` | Leaf Support | `abc_d1000` | 32.57 | 18,338 | 1,059 | 1.469 | +0.432 | 637.8 |
| `fursoy_s1_rat` | Leaf Support | `abc_d1000` | 73.63 | 38,719 | 4,728 | 1.573 | +0.332 | 599.5 |
| `fursoy_s1_prf_status` | Leaf Support | `abc_d1000` | 6.56 | 3,962 | 159 | 0.947 | +0.960 | 961.5 |
| `fursoy_s1_frat` | Leaf Support | `abc_d1000` | 64.89 | 32,326 | 3,674 | 1.628 | +0.281 | 581.7 |
| `fursoy_s1_fprf_status` | Leaf Support | `abc_d1000` | 2.80 | 1,692 | 64 | 0.798 | +1.108 | 1,121.1 |
| `fursoy_s1_port1_buffers` | Leaf Support | `abc_d1000` | 10.01 | 5,426 | 588 | 0.879 | +1.037 | 1,038.4 |
| `fursoy_s1_trt` | Leaf Support | `abc_d1000` | 20.16 | 10,260 | 1,568 | 1.366 | +0.540 | 684.9 |
| `fursoy_s1_fetch_queue` | Leaf Support | `abc_d1000` | 104.30 | 54,636 | 7,329 | 0.879 | +1.027 | 1,027.7 |
| `fursoy_s1_serialization` | Leaf Support | `abc_d1000` | 2.04 | 918 | 146 | 1.304 | +0.612 | 720.5 |

### 2.3 Synthesis-Intractable Flop-Array / CAM Blocks (`2 / 25` Timeouts)

Two primary OoO leaf blocks exceeded the `600s` per-attempt Yosys 0.33 synthesis budget on the `16 GiB` host—providing direct physical evidence of RTL structures that must be refactored before Slice-3 tapeout/PnR:

1. **`fursoy_s1_lsu_queues`** (`status = timeout`, `2,675 MiB` RSS, `>600s` before reaching ABC in both canonical `PROC_MUX` and `mem2reg` flows): Unpacked struct arrays `lq_q` (`16 × 403b`) and `sq_q` (`16 × 326b`) with multi-port store-to-load forwarding, snoop invalidation, and MMIO ordering inside a monolithic `always_ff` lower to `12,314` `$memwr`/`$mem2bits` nodes in `sv2v` -> Yosys. **Slice-3 remedy:** Separate narrow CAM address/status tags from banked data payload arrays and split LQ/SQ into independent sub-modules.
2. **`fursoy_s1_bpu`** (`status = timeout`, **`15,147 MiB` RSS**, `>600s` across `abc_d1000`, `mem2reg_abc_d1000`, and `mem2reg_abc_fast`): The `512`-entry BTB (`256 × 2`), bimodal table, `108`-bit GHR TAGE-Lite tagged tables, and `16`-entry / `32`-checkpoint RAS are written as pure flip-flop arrays with no SRAM macros, exhausting `15+ GiB` RAM during standard-cell flattening/mapping. **Slice-3 remedy:** Move BTB and TAGE predictor tables into single-port/banked synchronous SRAM macros (matching industrial frontends).

### 2.4 Synchronous SRAM Macro Sensitivity Sweep (`tCQ = 0.60, 0.80, 1.00 ns`, `tSetup = 0.20 ns`)

To bound the realism of Slice-2's combinational SRAM blackbox Liberty (`tools/synth/lib/fursoy_sram_macros.lib`, `tAA = 0.40 ns`), `tools/run_s25_core_sta.py` evaluated the existing synthesized Slice-2 netlists (`s2_l1d_netlist.v`, `s2_l2_netlist.v`, `s2_coherence_mgr_netlist.v`) against realistic **registered synchronous SRAM Liberty models** (`timing_type : rising_edge` `clk_i -> Q` at `tCQ = 0.60, 0.80, 1.00 ns`; `setup_rising = 0.20 ns`; `hold_rising = 0.05 ns`; `0` Warning 1216/441):

| Module | Baseline Comb SRAM (`0.40 ns`) WNS | Sync Block WNS (`0.60/0.80/1.00 ns`) | Sync Block `Fmax` | SRAM-Launch Slack (`clk_i -> Q -> end`) @ `0.60 / 0.80 / 1.00 ns` | SRAM-Capture Slack (`in/ff -> D`, `tSetup=0.20 ns`) | Max `tCQ` Before Breaking `500 MHz` |
|---|---:|---:|---:|---:|---:|---:|
| `fursoy_s1_l1d` (`u_bank_sram`) | `+0.027 ns` | `+0.108 ns` | `528.5 MHz` | `+0.807 / +0.607 / +0.407 ns` | `+0.327 ns` | `1.407 ns` |
| `fursoy_s2_l2` (`u_data_sram`) | `+0.314 ns` | `+0.314 ns` | `593.1 MHz` | `+1.000 / +0.800 / +0.600 ns` | `+1.521 ns` | `1.600 ns` |
| `fursoy_s2_coherence_mgr` (`u_l2/u_data_sram`) | `+0.008 ns` | `+0.008 ns` | `502.0 MHz` | `+1.119 / +0.919 / +0.719 ns` | `+0.743 ns` | `1.719 ns` |

**Key Takeaways & Architectural Caveat:**
- **Timing margin is solid for `tCQ <= 1.00 ns`:** In all three cache/coherence blocks, the post-SRAM combinational fanout is shallow (`0.343 ns` byte/way rotate in `l1d`, `0.150 ns` one-hot 8-way mux in `l2`, `0.191 ns` in `coherence_mgr`), and pre-SRAM setup margin is `>= +0.327 ns`. In `fursoy_s1_l1d`, replacing the combinational read arc with a synchronous clock-to-Q arc actually *improves* block WNS from `+0.027 ns` to `+0.108 ns` because it breaks the full-cycle `load1_req_pa_i -> SRAM -> load1_rsp_data_o` combinational path.
- **Structural RTL pipeline stage still required in Slice-3:** Slice-2's cache RTL currently expects **0-cycle combinational SRAM read data** in the same cycle the address is presented. Adopting physical 1-cycle synchronous SRAM macros in Slice-3 requires adding an explicit **1-cycle synchronous read pipeline stage** (parallel tag+data lookup in Stage 0 -> way-select/alignment in Stage 1 for `L1I`, `L1D`, and `L2`) and verifying IPC impact under Verilator.

---

## 3. Empirical Steady-State IPC & SMP Memory Scaling Bottlenecks

From `results/s25-benchmarks.json` (canonical RTL `3da97dce...`, `0` CPI conservation errors across every suite):

### 3.1 Single-Core IPC & 8-Bucket CPI Bottlenecks

| Benchmark Suite | Verified Result | IPC | Dominant CPI Stall Buckets & Architectural Signal |
|---|---|---:|---|
| **CoreMark** (`1f483d5b`, `-O3 -funroll-loops`, 10 iters) | `3.7748 CM/MHz` (`1,887.42 @ 500 MHz`) | `1.1409` | `C_productive=65.3%`, **`C_be_sched=12.0%`**, **`C_be_rename=9.4%`**, `C_idle_other=7.8%`, `C_mem_stall=4.4%`, `C_br_recover=1.1%` -> Backend issue-port / scheduler width (`2` ALU + `1` MUL/DIV) and rename/dispatch width (`2`-wide) account for **21.4%** of cycles. |
| **Dhrystone 2.1** (`66bb9df1`, strict `-O2 -fno-inline-functions`, 2,000 runs) | `1.7127 DMIPS/MHz` (`856.36 @ 500 MHz`) | `1.4836` | High productive utilization (`78.0%`), `C_mem_stall=8.4%`, low branch recovery (`0.04%`) -> approaching the 2-wide commit ceiling (`2.0 IPC`). |
| **Embench-IoT v2.0** (`09c2ed8c`, `19/19`, `0` exclusions) | Geomean **`1.9445×`** Cortex-M4/MHz | **`1.2874`** | Splits cleanly into three workload regimes (see below). |

**Embench-IoT v2.0 Regime Breakdown (Driving Slice-3 Priorities):**
1. **Branch-Misprediction-Dominated Tail (Highest Single-Core IPC Upside):**
   - `xgboost`: `IPC = 0.6599` (**`C_br_recover = 31.9%`**) — deep irregular decision-tree branches overwhelm the 512-entry BTB + TAGE-Lite predictor.
   - `qrduino`: `IPC = 0.8167` (**`C_br_recover = 27.7%`**)
   - `huffbench`: `IPC = 1.0120` (**`C_br_recover = 20.0%`**)
   - `sglib-combined`: `IPC = 0.9351` (**`C_br_recover = 18.9%`**)
   - `nsichneu` (`C_br_recover = 13.7%`) and `aha-mont64` (`12.8%`).
2. **Rename / ROB / Dispatch Backpressure Tail:**
   - `tarfind`: `IPC = 0.7160` (**`C_be_rename = 50.4%`**) — tight loop with long-latency memory/serialization or freelist/LQ/SQ exhaustion stalls rename for half of all cycles.
   - `ud`: `IPC = 1.1461` (**`C_be_rename = 30.3%`**) — inner loops constrained by 2-wide dispatch/rename + FP/INT queue pressure.
3. **2-Wide Pipeline Saturation Ceiling:**
   - Compute-bound kernels (`nettle-sha256` `IPC=1.8584`, `depthconv` `1.8378`, `matmult-int` `1.8235`, `nettle-aes` `1.8188`, `statemate` `1.8111`, `edn` `1.7955`) hit **90–93% of the theoretical `2.0` IPC ceiling**. Further speedup on server crypto/matrix/DSP workloads mathematically requires widening fetch/decode/rename/commit from **2-wide -> 3-wide or 4-wide**.

### 3.2 Multi-Core SMP & Memory Bandwidth Scaling (`N = 1, 2, 4`)

- **CoreMark SMP (`N = 1 -> 2 -> 4`):** `3.7748 -> 7.6152 (2.0174×) -> 15.2235 (4.0329×)` CM/MHz; aggregate IPC `1.1409 -> 2.3032 -> 4.6129`; clean **`1.9991×`** linear scaling from `N=2 -> N=4` (same `MEM_MALLOC` allocator).
- **STREAM FP64 (`N = 1 -> 2 -> 4`, `STREAM_ARRAY_SIZE=65536`, `1.5 MiB = 6× L2`):**
  - 2-stream kernels scale almost linearly: `Copy` `2,001.1 -> 3,987.0 -> 7,943.8 MB/s` (`3.970×`); `Scale` `1,997.3 -> 3,987.0 -> 7,884.0 MB/s` (`3.947×`).
  - 3-stream kernels show the first **shared L2 / single-coherence-manager arbitration knee at `N=4`**: `Add` `2,995.9 -> 5,980.5 -> 10,627.5 MB/s` (`3.547×`); `Triad` `2,978.9 -> 5,980.5 -> 10,699.8 MB/s` (`3.592×`, **`21.40 B/cyc`** @ 500 MHz, aggregate IPC `1.4819 -> 2.9777 -> 5.8732`).
  - Extrapolating from `N=4` to **`N=8` server cores**, a single-banked L2 + single serialized coherence manager (`fursoy_s2_coherence_mgr`) will severely bottleneck memory-intensive workloads unless L2 is **multi-banked (4–8 independent banks + parallel coherence slices / NoC)** with per-bank MSHRs.

---

## 4. Explicit Caveats, Known Limitations & Deferred Technical Debt

To maintain strict truthfulness across Slice-2.5 closeout and Slice-3 scoping, the following documented caveats and deferred items MUST remain explicit:

1. **CoreMark SMP `N=1` vs `N=2/4` Allocator Disclosure (`S2.5-M3a P2-1`):** `CoreMark` `N=1` used `MEM_STACK` (`3.7748 CM/MHz`), while `N=2` (`7.6152`) and `N=4` (`15.2235`) used `MEM_MALLOC`, introducing a `+0.86%` memory-layout delta (`2.0174×` apparent `N=1->2` vs `1.9991×` exact `N=2->4` scaling).
2. **STREAM DRAM Stub & Timer Quantization Disclosure (`S2.5-M3a P2-2`):** `STREAM FP64` (`512 KiB/array = 2× L2` per array, `1.5 MiB = 6× L2` total) ran against the same **2-cycle behavioral DRAM read stub** used by the Slice-2 Linux TB (not a DDR4/DDR5 latency/refresh/bank-conflict controller). At `N=4`, the `131 us` kernel duration has `±0.76%` `1 us` `gettimeofday` quantization. Peak bandwidth (`10.7 GB/s @ 500 MHz`) therefore measures **on-chip L1D -> coherence -> L2 -> memory-bus throughput**, not off-chip DDR bandwidth.
3. **Inline Vector Multiply Behavioral Operators (`S2.5-M1b P2-3`):** Two non-pipelined behavioral `*` expressions remain in `rtl/core/fursoy_s1_core.sv:1858` (`VEC_VMUL` 64-bit element multiply) and `rtl/core/fursoy_s1_core.sv:2538` (`vstart * init_stride` vector strided address offset); deferred to Slice-3 pipelined vector execution unit refactoring.
4. **Deferred RVA23 / Server Platform Features (Slice-3+):**
   - **`RVC` (`C` compressed 16-bit instructions):** Required for RVA23 compliance and I-cache footprint reduction (`~25–30%` smaller code -> fewer `L1I` misses); requires unaligned 16-bit fetch/decode co-design.
   - **Programmable 16-entry `PMP` CSRs + non-zero `misa` + upstream OpenSBI:** Required to replace the custom M-mode SBI shim (`software/baremetal/s2_opensbi_shim.S`) with unmodified mainline OpenSBI.
   - **`Zicclsm` (hardware misaligned load/store support), `Sstc` (`stimecmp`), `CMO` (`Zicbom`/`Zicboz`/`Zicbop`), and full `RVV 1.0` (vector FP + whole-register/indexed ops):** All cleanly marked `partial`/`deferred` in `docs/requirements/isa-platform.csv`.
   - **Formal RVWMO / Coherence Proof & Server RAS:** `S2.5-M2b` verified `10,000` iters/pattern dynamically (`0` forbidden, `0` SWMR violations), but bounded model checking / formal coherence proof and cache/SRAM ECC remain Slice-3+ items.

---

## 5. Prioritized `Slice-3` Architectural Sizing & Physical Targets

Based directly on the empirical Nangate45 OpenSTA, CPI, and SMP scaling data above, Slice-3 should execute in four disciplined tiers rather than blindly widening structures on top of `45.7 MHz` issue queues and `1,805 kGE` flop caches:

### Tier 0 (Mandatory Prerequisite): True Whole-Core `>= 1.0 GHz` Timing Closure & SRAM Macro Conversion

| Target Block | Slice-2.5 Measured Wall | Concrete Slice-3 Hardware Microarchitecture Change | Expected Impact |
|---|---|---|---|
| `int_iq`, `mem_iq`, `fp_iq`, `vec_iq` | `45.7 – 329.3 MHz` (`21.63 ns` max) | Replace serial `for`-loop `rob_dist` scans with **age-matrix (`N×N` one-hot) or binary tournament tree (`log2 N` = 5 levels)** + banked/port-partitioned select | Drops IQ delay `~21 ns -> <1.2 ns` (`>800 MHz` Nangate45; `>=1.5 GHz` advanced node) |
| `fursoy_s1_fma` | `187.4 MHz` (`5.09 ns`) | Replace serial 79b/163b LZC `for`-loops (`L734,845`) with **parallel-prefix LZC / Leading-Zero Anticipator (LZA)** and register SP rounding output cleanly (`EX3 -> EX4` or split norm/round) | `187 MHz -> >650 MHz` Nangate45 |
| `fursoy_s1_vrat`, `hpm`, `fconv` | `391.8 / 402.4 / 492.4 MHz` | Pipeline `vrat` bitmap allocation (2-stage rename or split freelist/SRAT), register `hpm` event trigger by 1 cycle (`fursoy_s1_hpm.sv:199`), rebalance `fconv` rounding mux (`31 ps`) | All 3 clear `>600 MHz` Nangate45 |
| `l1i`, `bpu`, `l2` tags/dir, `vrf` | `l1i = 1,805 kGE` (`143k DFFs`); `bpu` `>15 GiB` Yosys OOM; `l2` tags/dir `3,270 kGE` | Convert **`L1I` data+tag**, **`L1D` tag**, **`BTB`+`TAGE`**, **`L2` tag+directory**, and **`VRF`** to **1-cycle synchronous SRAM macros** with proper 1-cycle read pipeline stages | Reclaims **`>2,500 kGE`/core** + **`>2,500 kGE` uncore**, unlocks full-core synthesis/PnR under `<8 GiB` RAM |
| `fursoy_s1_lsu_queues` | Yosys `PROC_MUX` timeout | Split monolithic unpacked `lq_q`/`sq_q` struct arrays into narrow CAM address/age tag arrays + indexed data payload regfiles/SRAMs | Restores tractable synthesis + `<1.5 ns` forwarding timing |
| `fursoy_s1_core` inline RVV `*` | Behavioral `*` at `L1858,2538` | Replace inline `VEC_VMUL` and `vstart * init_stride` with pipelined Booth/Wallace vector multiplier unit | 100% synthesizable core arithmetic |

### Tier 1 (Single-Core IPC Scaling: Target `>= 5.5–6.5 CoreMark/MHz`, `>= 1.8–2.1` Embench Geomean IPC)

| Subsystem | Slice-2.5 Size (Verified `fursoy_s1_pkg.sv`) | Recommended Slice-3 Sizing | Empirical Justification (`results/s25-benchmarks.json`) |
|---|---|---|---|
| **Pipeline Width** | 2-wide Fetch / Decode / Rename / Commit | **4-wide Fetch / Decode / Rename / Commit** (co-designed with `RVC` 16-bit fetch buffer) | Compute kernels already hit `1.80–1.86 IPC` (90–93% of 2-wide ceiling); `CoreMark` loses `21.4%` cycles to `C_be_sched` + `C_be_rename`. |
| **Branch Predictor (`BPU`)** | 512-entry BTB (2-way), TAGE-Lite (`108b` GHR), 16-entry RAS | **2K–4K-entry SRAM BTB (4-way)** + **SRAM-backed 6–8 table TAGE-SC-L** + **32-entry RAS** + loop/indirect predictor | Directly attacks the #1 Embench IPC drag (`xgboost 31.9%`, `qrduino 27.7%`, `huffbench 20.0%`, `sglib-combined 18.9%` `C_br_recover`). |
| **OoO Window (`ROB` / `PRF` / `IQ`)** | `ROB=128`, `PRF=160`, `FPRF=64`, `INT_IQ=32`, `MEM_IQ=32`, `FP_IQ=16`, `LQ=16`, `SQ=16` | **`ROB=192–256`**, **`PRF=224–256`**, **`FPRF=128`**, **`INT_IQ=48–64`** (age-matrix/banked, **3–4 ALU ports**), **`MEM_IQ=48`**, **`LQ=48` / `SQ=32`** | Attacks `tarfind` (`50.4%` `C_be_rename`), `ud` (`30.3%` `C_be_rename`), `CoreMark` (`12.0%` `C_be_sched`), and hides real DDR latency once the 2-cycle DRAM stub is replaced. |
| **L1 Caches & TLBs** | `16 KiB` L1I, `16 KiB` L1D, `32`-entry ITLB/DTLB | **`32–64 KiB` 4/8-way SRAM L1I & L1D** (1-cycle pipelined SRAM read, dual load + 1 store port, stride prefetcher) + **`64`-entry L1 TLB + `512`-entry L2 STLB** | Supports 4-wide fetch, Linux kernel/userspace working sets, and hides real DRAM miss penalty. |

### Tier 2 (RVA23 & Mainline Server Linux Platform Closure)

1. **`RVC` (`C` Extension):** Mandatory for RVA23 and mainline Linux distro binaries (`Debian`/`Fedora` RISC-V userland).
2. **Programmable 16-entry `PMP` CSRs + Non-zero `misa` + Upstream OpenSBI:** Retire `s2_opensbi_shim.S` and boot unmodified mainline OpenSBI + Linux 6.x.
3. **`Zicclsm` + `Sstc` (`stimecmp`) + `Zicbom`/`Zicboz` (`CMO`) + `Svpbmt` + Full `RVV 1.0` (Vector FP):** Close remaining `partial`/`deferred` rows in `docs/requirements/isa-platform.csv`.

### Tier 3 (4 -> 8 Core Server Uncore & Memory Subsystem)

1. **Multi-Banked L2 / L3 & Parallel Coherence:** Replace the single serialized `fursoy_s2_coherence_mgr` + `256 KiB` monolithic L2 with **private `256–512 KiB` per-core L2 + 4–8 banked shared L3 / distributed directory slices** connected over a ring/mesh NoC—eliminating the `N=4` 3-stream `STREAM Add/Triad` (`3.55–3.59×`) arbitration knee and scaling cleanly to `N=8` cores.
2. **Cycle-Accurate DRAM Controller Model (DDR4/DDR5 Timing + Bank/Refresh Queue):** Replace the 2-cycle behavioral DRAM stub in Verilator benchmarking so Slice-3 `STREAM` and Linux workloads reflect true main-memory latency (`40–80 ns`), validating the expanded `LQ`/`SQ`/MSHR and hardware prefetcher sizing.
3. **Formal Coherence & RAS:** Add bounded model checking on the directory protocol and SECDED ECC on L1/L2/L3 SRAM macros.

---

## 6. Bottom-Up Area Budget Sanity Check (Slice-2.5 Actual vs. Slice-3 SRAM-Backed Target)

| Component | Slice-2.5 Nangate45 Measured (`results/s25-core-sta.json`) | Key Driver | Slice-3 SRAM-Backed Architecture Target |
|---|---:|---|---|
| **35 Characterized Core Leaf Blocks** | `5,373.87 kGE` (`316,450 DFFs`) | `l1i` (`1,805 kGE`), `prf` (`619 kGE`), `rob` (`572 kGE`), `l1d` logic (`468 kGE`), `vrf` (`332 kGE`), `vrat` (`269 kGE`), `int_iq` (`203 kGE`) | Convert `l1i`, `bpu`, `vrf`, `l1d` tags to SRAM macros; standard-cell core logic targets `~1,800–2,600 kGE` even at 4-wide OoO |
| **`lsu_queues` + `bpu` (Timeout)** | Unmeasured (exceeded `600s` / `15.1 GiB` flop synth) | Flop-based BTB/TAGE & wide unpacked LQ/SQ structs | SRAM-backed BTB/TAGE + split LQ/SQ CAM/data -> tractable `<400 kGE` logic |
| **Shared L2 (`256 KiB` data BB) + Coherence** | `3,831.60 kGE` inclusive (`3,269.96 kGE` L2 tags/dir + `561.64 kGE` standalone coherence) | Flop-based L2 tag/directory/MOESI arrays (`212,480 DFFs`) | Move L2/L3 tags + snoop filter directory into SRAM macros -> eliminates `~3,000 kGE` of flop bloat |
| **Platform Peripherals (`CLINT` + `PLIC` + `MMIO Xbar`)** | `27.02 kGE` (`1,168 DFFs`) | Already compact and `>600 MHz` | Extend cleanly to `NUM_HARTS = 8` (`<60 kGE`) |
