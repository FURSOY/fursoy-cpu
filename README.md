# FURSOY CPU

**An open-source 64-bit, 2-wide Out-of-Order Superscalar RISC-V Processor (`RV64IMAFD + Zba + Zbb + Zicsr + Zifencei` + `RVV 1.0 integer subset (prototype)` + Sv39) and 1→4-Hart Directory-MESI SMP SoC in SystemVerilog, verified with official `RISCOF` (`245/245`), `157,972`-instruction Sail lockstep fuzzing, `10,000`-iteration RVWMO litmus, standard benchmarks (`CoreMark`, `Embench-IoT`, `STREAM`, `Dhrystone`), and mainline Linux 6.6.50 (`CONFIG_SMP=y` + `CONFIG_FPU=y`).**

**Canonical Architecture & Telemetry Site:** [fursoy.com/cpu](https://fursoy.com/cpu)

---

## Status & Verification Snapshot

- **Frozen Milestones (Canonical Slice-2.5 RTL SHA-256: `3da97dcef426ef3d3bfebd6c21399df21ba24ea9fce2ce4fd5503e1b408da7dc`):**
  - **Slice-1 (`fursoy_s1_core` / `fursoy_s1_soc`, `SMP_COHERENCE_EN = 0`):** Single-core 2-wide OoO `RV64IMAFD + Zba + Zbb` + `RVV 1.0 integer subset (prototype)` + `Sv39` Linux 6.6.50 + BusyBox processor, 8/8 `sail-riscv v0.16` directed lockstep suites (`1,177` steps), 0 CPI conservation errors.
  - **Slice-2 (`fursoy_s2_soc`, `SMP_COHERENCE_EN = 1`, `NUM_HARTS = 2` default, `4`-hart verified):** Directory-tracked MESI multicore cluster + shared 256 KiB 8-way inclusive L2, RV64A multi-hart `LR`/`SC` & locked `AMO`, global `FENCE` quiescence, custom SMP SBI v2.0, coherence torture, directed MMIO-vs-MSIP IRQ stress, and mainline Linux 6.6.50 SMP boot (`N=2` & `N=4`).
  - **Slice-2.5 (`S2.5-M1`..`S2.5-M4` — Hardening, Compliance, Benchmarks & Whole-Core STA):**
    - **`S2.5-M1b` Synthesizable Arithmetic:** Replaced behavioral FDIV/VDIV and single-stage combinational MUL with iterative Parallel Radix-4 restoring `fursoy_s1_fdiv` (SP `17c` / DP `31c`, `+0.480 ns` / `657.9 MHz`, `22.89 kGE`), iterative Parallel Radix-4 `fursoy_s1_vec_div` (`+0.887 ns` / `898.5 MHz`, `13.63 kGE`), and 3-stage pipelined `65×65` Booth + Wallace CSA + Kogge-Stone `fursoy_s1_multiplier` (`+0.776 ns` / `817.0 MHz`, `41.24 kGE`), `0` `$div`/`$mod` Yosys cells, `4,908` Sail steps (`0` mismatches).
    - **`S2.5-M2` Compliance, Fuzzing & Contract-Scale Coherence:** Official `RISCOF` (`1.25.3`, `riscv-arch-test`) **`245 / 245` (100%) PASS** across 10 suites against `sail-riscv v0.16`; 20-seed constrained-random Sail lockstep fuzzer retiring **`157,972` instructions** (`0` mismatches); contract-scale **`10,000`-iter/test** RVWMO litmus on `N=2` (`37.83M` cyc) & `N=4` (`44.27M` cyc) with **`0` forbidden** and **`0` SWMR violations**.
    - **`S2.5-M3` Industry Benchmarks & Linux SMP + FPU:** `CoreMark` `3.7748 CM/MHz` (`15.2235 CM/MHz` @ `N=4`), `Embench-IoT v2.0` **`19/19`** (geomean `IPC = 1.2874`, `1.9445×` Cortex-M4/MHz), `STREAM FP64` Triad `10,699.8 MB/s` (`N=4`, `3.592×`), `Dhrystone 2.1` `1.7127 DMIPS/MHz`; mainline **Linux 6.6.50 `CONFIG_SMP=y` + `CONFIG_FPU=y`** (`N=2` & `N=4`, `0` RVC, `10/10` markers including `[SMP_FPU_PREEMPT_PASS]` across `f0..f31` & 5 `frm` modes).
    - **`S2.5-M4` Whole-Core OpenSTA, Synchronous SRAM Sensitivity & Slice-3 Sizing Memo:** Characterized **`35 / 37` core leaf blocks** + `5` SMP platform blocks on Nangate 45nm (`500 MHz` / `2.000 ns`, `0` false/multicycle paths, `0` Warning 1216/441): **`32` meet `500 MHz`**, **`8` core blocks violate `500 MHz`** (true unoptimized core `Fmax` wall = **`45.7 MHz`** in `fursoy_s1_int_iq`), and **`2` hit Yosys 0.33 / 16 GiB flop-array timeouts** (`fursoy_s1_lsu_queues`, `fursoy_s1_bpu`). Full analysis and 4-tier Slice-3 roadmap in [`docs/architecture/slice3-sizing-memo.md`](docs/architecture/slice3-sizing-memo.md).
- **Design Stage, Scope & Honesty Boundaries:**
  - **Pre-tapeout RTL stage:** Pre-P&R, no physical SRAM compiler `.lef`/`.lib` integration yet. Core-wide OpenSTA honestly documents both the `32` blocks closing `500 MHz` and the `8` violating OoO blocks (`int_iq 45.7 MHz`, `mem_iq 47.2 MHz`, `fma 187.4 MHz`, `fp_iq 194.7 MHz`, `vec_iq 329.3 MHz`, `vrat 391.8 MHz`, `hpm 402.4 MHz`, `fconv 492.4 MHz`) plus `2` flop-array timeouts (`lsu_queues`, `bpu`) scheduled for Slice-3 retiming and SRAM macro conversion.
  - **ISA & Platform Scope:** Scalar `RV64IMAFD + Zba + Zbb + Zicsr + Zifencei` is verified by `RISCOF` (`245/245`) and Linux `CONFIG_SMP=y` + `CONFIG_FPU=y`. Vector execution remains an **`RVV 1.0 integer subset (prototype)`** (~30 integer/mask/memory opcodes — no vector FP `OPFVV`/`OPFVF`, no whole-register `vl<nr>r`/`vs<nr>r`, no segmented `nf!=0`; inline behavioral `*` in `fursoy_s1_core.sv:1858,2538` for `VEC_VMUL` / `vstart * init_stride` deferred to Slice-3). `RVC` (`C`), programmable 16-entry `PMP` CSRs + non-zero `misa` + upstream OpenSBI, `Zicclsm`, `Sstc`, `CMO`, and full `RVV 1.0` FP are deferred to **Slice-3+**.
  - **SPEC CPU:** Unmeasured (requires FPGA prototyping or SimPoint infrastructure beyond RTL Verilator speed).

---

## Core Microarchitecture & Pipeline (`fursoy_s1_core`)

The core implements a **12-stage decoupled pipeline** (`F0` GenPC → `F1` ITLB/BPU → `F2` L1I/TAGE/IBP/RAS → `F3` Align/JAL → `F4` FetchQ16 → `D0` 2W Decode → `RN` 2W Rename → `DS` 2W Dispatch → `IS` OoO Issue → `RF` RegRead → `EX` Execute → `WB` / `CMT` 2W In-Order Retire) with `M/S/U` privilege modes, `medeleg`/`mideleg`, `WFI` (`mstatus.TW`), `MRET`/`SRET`, and a fixed M-mode SBI L1I aperture guard in SoC (programmable 16-entry PMP CSRs & non-zero `misa` are deferred to **Slice-3+**; the Slice-0 reference PMP lives in `rtl/core/fursoy_s0_pmp.sv`):

| Subsystem | Verified RTL Parameters | Primary Module(s) |
| :--- | :--- | :--- |
| **ISA & Privilege** | `RV64IMAFD + Zba + Zbb + Zicsr + Zifencei` + `RVV 1.0 integer subset (prototype)` · M/S/U · Sv39 (16-bit ASIDs, 4 KiB / 2 MiB / 1 GiB) · `mhartid_i` · fixed SBI L1I guard (programmable PMP CSRs & `misa` deferred to Slice-3+) | `fursoy_s1_decode.sv`, `fursoy_s1_csr.sv` |
| **Frontend & BPU** | 2-wide fetch/decode (`FETCH_QUEUE_DEPTH = 16`) · **512-entry 2-way BTB** (`256×2`, 53b tag) · **30,208-bit TAGE-Lite** (`T0`: 2048×2b + `T1..T4`: 512 sets, 108-bit GHR) · **64-entry tagged IBP** (`IBP_ENTRIES = 64`) · **16-entry RAS** (`INDEXED_RAS_CHKPT = 32` slots) | `fursoy_s1_frontend.sv`, `fursoy_s1_bpu.sv`, `fursoy_s1_fetch_queue.sv` |
| **ROB, PRFs & Recovery** | **`ROB_DEPTH = 128`** (2W alloc / 2W retire, 4-bit epochs) · **`NUM_CHECKPOINTS = 16`** (1-cycle SRAT/FRAT/VRAT/GHR/RAS rollback) · **`PRF_SIZE = 160`** (`128` FL) · **`FPRF_SIZE = 64`** (`32` FL) | `fursoy_s1_pkg.sv`, `fursoy_s1_rob.sv`, `fursoy_s1_substrate.sv`, `fursoy_s1_rat.sv`, `fursoy_s1_frat.sv` |
| **Issue Queues & Scalar Ports** | **`INT_IQ_DEPTH = 32`** (2W → **P0**: ALU0 KS / BRU KS / CSR / I2F; **P1**: ALU1 + `alu1_fifo` / 3-stage pipelined `65×65` Booth+Wallace+KS MUL [3c lat, 1/cyc tput, `817.0 MHz`] / ~34c iterative Radix-4 DIV [`845.3 MHz`]) · **`MEM_IQ_DEPTH = 32`** (2W → **P2/AGU0**: all mem; **P3/AGU1**: loads only) · **`FPIQ_DEPTH = 16`** (1W → **P4**: 3c/4c FMA / iterative Parallel Radix-4 restoring FDIV-FSQRT [SP `17c`, DP `31c`, `657.9 MHz`, `0` `$div`/`$mod`] / 2-stage FCONV) | `fursoy_s1_int_iq.sv`, `fursoy_s1_mem_iq.sv`, `fursoy_s1_fp_iq.sv`, `fursoy_s1_multiplier.sv`, `fursoy_s1_fdiv.sv`, `fursoy_s1_ks_adder.sv` |
| **RVV 1.0 Integer Subset (Prototype)** | **`VLEN = 256`**, **`ELEN = 64`**, **`VLENB = 32`** · **`VRF_NUM_PREGS = 64`** (`64 × 256b`, 4 banks × 64b, 4R+1W; `p0..p31` arch, `p32..p63` bitmap-renamed via `fursoy_s1_vrat`) · **`VIQ_DEPTH = 8`** · `LMUL = 1..8`, `vstart` resumption, 128-bit dual-lane SIMD beats, ~30 integer/mask/memory opcodes (`vle`/`vleff`/`vlse`/`vluxei`/`vsoxei`, `nf=0`; iterative Parallel Radix-4 restoring `VEC_VDIV`/`VEC_VDIVU` across `SEW=8/16/32/64` [`898.5 MHz`]; no vector FP `OPFVV`/`OPFVF`, no whole-reg `vl<nr>r`/`vs<nr>r`; inline RVV `*` deferred to Slice-3) | `fursoy_s1_vrat.sv`, `fursoy_s1_vrf.sv`, `fursoy_s1_vec_iq.sv`, `fursoy_s1_vec_div.sv`, `fursoy_s1_core.sv` |
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

## Verified Silicon & Software Proof (Slice-2.5 Canonical RTL `3da97dce...`)

All Slice-2.5 compliance (`S2.5-M2`), benchmark (`S2.5-M3a`), Linux `SMP+FPU` (`S2.5-M3b`), and whole-core OpenSTA (`S2.5-M4`) results below were measured on unified frozen RTL SHA-256 `3da97dcef426ef3d3bfebd6c21399df21ba24ea9fce2ce4fd5503e1b408da7dc` (with `S2.5-M1b` arithmetic STA & Sail co-sim on `167fa9fb...` and historical Slice-1/2 baselines retained intact in `results/s1-*` and `results/s2-m*`).

### 1. Mainline Linux 6.6.50 `CONFIG_SMP=y` + `CONFIG_FPU=y` Boot & Preemption Validation

> **Kernel ISA Scope (`S2.5-M3b`):** `software/linux/fursoy_s2_defconfig` builds Linux 6.6.50 with **`CONFIG_SMP=y` + `CONFIG_FPU=y`** (`CONFIG_RISCV_ISA_C` and `CONFIG_RISCV_ISA_V` disabled; `0` RVC instructions verified in `vmlinux` and `s2_smp_test`), with DTB `riscv,isa` aligned strictly to `rv64imafd_zba_zbb_zicsr_zifencei`. Prior to boot, S-mode `sstatus.FS`/`SD` dirty-tracking and `FS==00` trap invariants passed Sail lockstep (`209/209` steps, `9` traps, `0` mismatches).

| Configuration | Artifact | Cycles | Retired Insts | Aggregate IPC | Verified Userspace & Correctness |
| :--- | :--- | ---: | ---: | ---: | :--- |
| **`S2.5-M3b` · `N=2` SMP + FPU** | [`results/s25-linux-fpu-smp.json`](results/s25-linux-fpu-smp.json) | 45,279,778 | 48,158,534 | **1.0636** | `CONFIG_SMP=y` + `CONFIG_FPU=y`, `10/10` pass markers incl. `[SMP_FPU_PREEMPT_PASS]` (`4` threads × `6` rounds = `24` hart migrations, `1,536` `f0..f31` reg checks, `5` `frm` modes), `pthreads`/atomics/`mem_stress`/BusyBox PASS, `0` panics/traps/signals |
| **`S2.5-M3b` · `N=4` SMP + FPU** | [`results/s25-linux-fpu-smp.json`](results/s25-linux-fpu-smp.json) | 52,731,214 | 63,776,215 | **1.2095** | `CONFIG_SMP=y` + `CONFIG_FPU=y`, `10/10` pass markers incl. `[SMP_FPU_PREEMPT_PASS]` (`8` threads × `6` rounds = `48` hart migrations, `3,072` `f0..f31` reg checks, `5` `frm` modes), `pthreads`/atomics/`mem_stress`/BusyBox PASS, `0` panics/traps/signals |
| **`S2-M5` · `N=2` / `N=4` Baseline (`RV64IMA`)** | [`results/s2-m5-closeout.json`](results/s2-m5-closeout.json) | 41,096,621 / 48,380,518 | 43,732,996 / 60,175,709 | **1.0642 / 1.2438** | Frozen Slice-2 `CONFIG_SMP=y` (`RV64IMA`) closeout on RTL `bc0502b9...`, `pthreads` + `<stdatomic.h>` + `mem_stress` + BusyBox PASS, `0` panics |
| **`S1-M9` · Single-Core Baseline** | [`results/s1-m9-closeout.json`](results/s1-m9-closeout.json) | 90,304,592 | 76,281,757 | **0.8447** | Frozen Slice-1 Gate G5 (`SMP_COHERENCE_EN=0`), 20 BusyBox shell tests + `mem_stress`, `2,233,243` U-commits, **0 CPI conservation errors** (post-Slice-2 non-reg: `90,325,303` cyc, `76,299,307` commits, `IPC = 0.8447`, `0` CPI errs) |

<details>
<summary><strong>Single-Owner 8-Bucket CPI Conservation Breakdown (Post-Slice-2 S1-M9 Non-Regression: 90,325,303 Cycles, 0 Errors; Frozen Baseline in <code>results/s1-m9-closeout.json</code>: 90,304,592 Cycles)</strong></summary>

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

### 2. Official Compliance (`RISCOF`), Lockstep Fuzzing, Contract-Scale RVWMO Litmus & Stress

| Verification Suite | Artifact / Runner | Result | Key Metrics |
| :--- | :--- | :---: | :--- |
| **Official `RISCOF` (`1.25.3`, `riscv-arch-test`)** | [`results/s25-riscof.json`](results/s25-riscof.json) | **PASS** | **`245 / 245` (100%)** against `sail-riscv v0.16` across 10 suites (`I`: 50, `M`: 13, `A`: 18, `F`: 18, `D`: 27, `B[Zba+Zbb]`: 32, `Zifencei`: 1, `hints`: 31, `privilege`: 19, `vm_sv39`: 36). Unimplemented extensions (`C`, `PMP`, `Zicclsm`, `Zbs`/`Zbc`, `V`, `CMO`, `Sv48`/`Sv57`, etc.) explicitly excluded. |
| **20-Seed Sail Lockstep Fuzzer** | [`results/s25-sail-fuzz.json`](results/s25-sail-fuzz.json) | **PASS** | **`157,972` retired insts** (`20/20` seeds, `RV64IMAFD + Zba + Zbb`): `113,142` GPR, `19,781` FPR (with SP NaN-box checks), `480` trap checks — **`0` mismatches** |
| **Contract-Scale `10,000`-Iter RVWMO Litmus** | [`results/s25-litmus-10k.json`](results/s25-litmus-10k.json) | **PASS** | All 8 RVWMO patterns (`MP`, `SB`, `LB`, `IRIW`, `CoRR`, `CoWR`, `CoRW`, `CoWW`) × **`10,000` iters/test** on `N=2` (`37.83M` cyc, `IPC = 1.5126`) & `N=4` (`44.27M` cyc, `IPC = 1.7775`) — **`0` forbidden**, **`100%` SWMR coverage**, **`0` violations** |
| **`S2.5-M1b` Arithmetic Sail Co-Sim** | [`results/s25-m1b-arith.json`](results/s25-m1b-arith.json) | **PASS** | `4/4` suites (`4,908` Sail steps: `3,327` GPR, `1,058` FPR, `62` VRF group; directed + randomized IEEE-754 `FDIV`/`FSQRT` + `MUL*` + `VDIV*`) — **`0` mismatches** |
| **Directed Sail-RISC-V `v0.16` Co-Sim** | [`results/s1-sail-cosim.json`](results/s1-sail-cosim.json) | **PASS** | `8/8` suites (`1,177` Sail steps: `826` GPR, `37` FPR, `55` VRF group, `24` trap checks) — **`0` mismatches** |
| **`S2-M1..M4` SMP Bring-Up & Coherence Torture** | [`results/s2-m1-closeout.json`](results/s2-m1-closeout.json) .. [`s2-m4-closeout.json`](results/s2-m4-closeout.json) | **PASS** | Multi-hart `mhartid`/CLINT/PLIC, MESI `M→S`/`M→I` forwarding, contended `LR`/`SC` & `AMO`, simultaneous `SBI RFENCE`, `511,641` torture commits (`N=2, 4`) — **`0` SWMR/data/inclusion violations** |
| **MMIO-vs-MSIP IRQ Stress** | `tools/run_s2_mmio_irq_stress.py` | **PASS** | `84,854` cyc, `952` M-mode MSIP preemptions, `128/128` exact UART bytes (`0` dups/drops), `128/128` exact PLIC Claims (`0` bad claims, `0` leaked `in_service`), **`0` SWMR violations** |

### 3. Standard Industry Benchmarks (`S2.5-M3a`, [`results/s25-benchmarks.json`](results/s25-benchmarks.json))

All benchmarks ran unmodified upstream C sources compiled with `riscv64-linux-gnu-gcc 13.3.0` (`-march=rv64imafd_zba_zbb -mabi=lp64d -mstrict-align`) directly on cycle-accurate Verilator RTL (`3da97dce...`, `500 MHz` reference clock, **`0` CPI conservation errors**):

| Benchmark Suite | Scope & Configuration | Verified Result | IPC | Bottlenecks & Mandatory Methodology Disclosures |
| :--- | :--- | :--- | ---: | :--- |
| **EEMBC CoreMark** (`1f483d5b`) | Single-core `S1` (`-O3 -funroll-loops`, `10` iters, official 2K CRCs `0xe9f5`/`0xe714`/`0x1fd7`/`0x8e3a`) & SMP `S2` (`N=1, 2, 4`) | **`3.7748 CM/MHz`** (`1,887 @ 500 MHz`); SMP `N=2`: **`7.6152`**, `N=4`: **`15.2235 CM/MHz`** | `1.1409` (`S1`) · `2.3032` (`N=2`) · `4.6129` (`N=4`) | `S1` CPI: `C_productive=65.3%`, `C_be_sched=12.0%`, `C_be_rename=9.4%`. **Caveat:** `N=1` used `MEM_STACK` (`3.7748`) vs `N=2/4` `MEM_MALLOC` (`+0.86%` layout shift; apples-to-apples **`N=2→4` scaling = `1.9991×`**). |
| **Embench-IoT v2.0** (`09c2ed8c`) | **`19 / 19` PASS** (`0` exclusions, `0` CPI errs) | Geomean **`1.9445×`** Speed/MHz vs ARM Cortex-M4 | **`1.2874`** (geomean) | Compute kernels saturate 2-wide (`nettle-sha256` `1.8584`, `depthconv` `1.8378`); tail bottlenecks: branch recovery (`xgboost` `0.6599` / `C_br_recover=31.9%`, `qrduino` `0.8167` / `27.7%`) and rename backpressure (`tarfind` `0.7160` / `C_be_rename=50.4%`, `ud` `1.1461` / `30.3%`). |
| **McCalpin FP64 STREAM** (`6703f750`) | `-fopenmp`, `STREAM_ARRAY_SIZE=65536`, `512 KiB/array` (`2×` L2/array, **`1.5 MiB = 6× L2`** total), `Solution Validates` (`<1e-13`), `N=1, 2, 4` | `Copy`: **`2,001 → 3,987 → 7,944 MB/s`** (`3.97×`); `Triad`: **`2,979 → 5,981 → 10,700 MB/s`** (`3.59×`, `21.40 B/cyc`) @ `500 MHz` | `1.4819` → `2.9777` → `5.8732` | **Caveats:** Uses the SoC's **512-bit 2-cycle behavioral DRAM read stub** (`32 GB/s` bus cap, not a physical DDR4/DDR5 latency/refresh controller) and `1 us` `gettimeofday` timer (**`±0.76%`** quantization at `N=4`, `131 us`). Measures on-chip L1D→coherence→L2→bus throughput. |
| **Dhrystone 2.1** (`66bb9df1`) | Strict separate-TU (`-O2 -fno-inline-functions`), `2,000` runs, `14/14` output checks | **`1.7127 DMIPS/MHz`** (`856.36 DMIPS @ 500 MHz`) | `1.4836` | `C_productive=78.0%`, `C_mem_stall=8.4%`, `C_br_recover=0.04%`, `0` CPI conservation errors. |
| **SPEC CPU** | — | **Unmeasured** | — | Requires FPGA prototyping or SimPoint infrastructure (deferred beyond RTL simulation). |

### 4. Honest Core-Wide Nangate 45nm OpenSTA & Synchronous SRAM Sensitivity (`S2.5-M4`)

Synthesized via `sv2v v0.0.13` → `Yosys 0.33` → `OpenSTA 3.1.0` on **NangateOpenCellLibrary 45nm Typical (1.10V, 25C)** (`NAND2_X1 = 0.798 um²`) at **`500 MHz` (`2.000 ns`)**, `0.05 ns` uncertainty, `0.20 ns` I/O delay, **`0` `set_false_path` / `set_multicycle_path`**, **`0` Warning 1216 / `0` Warning 441** ([`results/s25-core-sta.json`](results/s25-core-sta.json), [`docs/architecture/slice3-sizing-memo.md`](docs/architecture/slice3-sizing-memo.md)):

- **Whole-Core Coverage (`35 / 37` core leaf blocks + `5` SMP platform blocks characterized = `40` blocks):**
  - **`32 / 40` blocks meet `500 MHz` (`TNS = 0.000 ns`):** All `14/14` baseline gated blocks (`tools/run_s2_synth.py`), all `3/3` `S2.5-M1b` arithmetic blocks (`fdiv`, `vec_div`, `multiplier`), and `15/23` newly characterized core leaf blocks (`rob`, `prf`, `fprf`, `l1i`, `vrf`, `divider`, `freelist`, `rat`, `prf_status`, `frat`, `fprf_status`, `port1_buffers`, `trt`, `fetch_queue`, `serialization`).
  - **`8 / 35` core leaf blocks violate `500 MHz` (True Unoptimized Core `Fmax` Walls — Ranked Worst-First):**

| Module | Mode | Cells | DFFs | Area (kGE) | Max Delay | WNS @ 500 MHz | Est. `Fmax` | Verified RTL Root Cause |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| `fursoy_s1_int_iq` | `abc_d1000` | 102,681 | 12,160 | 203.08 | 21.633 ns | **-19.883 ns** | **45.7 MHz** | Dual serial 32-entry `rob_dist` `for`-loop scans (`fursoy_s1_int_iq.sv:374-441`) |
| `fursoy_s1_mem_iq` | `abc_d1000` | 50,317 | 6,080 | 94.70 | 20.915 ns | **-19.165 ns** | **47.2 MHz** | Dual serial 32-entry `rob_dist` `for`-loop scans (`fursoy_s1_mem_iq.sv:157-178`) |
| `fursoy_s1_fma` | `abc_d1000` | 44,808 | 1,239 | 68.11 | 5.087 ns | **-3.337 ns** | **187.4 MHz** | Serial 79b/163b LZC `for`-loops + barrel shift + round (`fursoy_s1_fma.sv:734-742,845-853`) |
| `fursoy_s1_fp_iq` | `abc_d1000` | 15,119 | 2,096 | 29.63 | 4.886 ns | **-3.136 ns** | **194.7 MHz** | 16-entry serial `rob_dist` age-selection loop |
| `fursoy_s1_vec_iq` | `mem2reg_abc_d1000` | 47,007 | 3,108 | 79.36 | 2.946 ns | **-1.037 ns** | **329.3 MHz** | 8-entry serial `rob_dist` age scan + group readiness |
| `fursoy_s1_vrat` | `mem2reg_abc_d1000` | 130,652 | 17,120 | 268.98 | 2.459 ns | **-0.552 ns** | **391.8 MHz** | 1-cycle 32b popcount bitmap allocator (`LMUL<=8`) + SRAT/16-chkpt update |
| `fursoy_s1_hpm` | `abc_d1000` | 33,922 | 4,162 | 62.25 | 2.401 ns | **-0.485 ns** | **402.4 MHz** | Comb `retire_rob_idx_i` match into 64-bit counter increment (`fursoy_s1_hpm.sv:190-215`) |
| `fursoy_s1_fconv` | `abc_d1000` | 23,957 | 3,219 | 46.91 | 1.947 ns | **-0.031 ns** | **492.4 MHz** | 31 ps shortfall on FP↔Int conversion/rounding mux |

  - **`2 / 25` Honest Yosys 0.33 / 16 GiB Flop-Array Timeouts:** `fursoy_s1_lsu_queues` (wide `16×403b` LQ + `16×326b` SQ unpacked struct arrays timing out in Yosys `PROC_MUX`/`proc_prune`) and `fursoy_s1_bpu` (flop-based 512-entry BTB + 108b-GHR TAGE-Lite tables exceeding `15,147 MiB` RAM / `600s`).

<details>
<summary><strong>All 32 Blocks Meeting 500 MHz Nangate 45nm OpenSTA (`TNS = 0.000 ns`, `0` Warning 1216/441)</strong></summary>

| Module | Scope | Cells | DFFs | Area (kGE) | Max Delay | WNS @ 500 MHz | Est. `Fmax` |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `fursoy_s2_mmio_xbar` (`N=4`) | Slice-2 SMP | 2,059 | 213 | 3.59 | 1.181 ns | **+0.735 ns** | 790.5 MHz |
| `fursoy_s2_plic` (`N=4`, 8-ctx) | Slice-2 SMP | 10,715 | 561 | 17.66 | 1.407 ns | **+0.505 ns** | 668.9 MHz |
| `fursoy_s2_l2` (`N=4`, 512 sets, SRAM `.lib`) | Slice-2 SMP | 1,558,821 | 212,480 | 3,269.96 | 1.436 ns | **+0.314 ns** | 593.1 MHz |
| `fursoy_s2_clint` (`N=4`) | Slice-2 SMP | 2,979 | 394 | 5.77 | 1.559 ns | **+0.357 ns** | 608.6 MHz |
| `fursoy_s1_l1d` (`SMP=1`, 64 sets, SRAM `.lib`) | Slice-2 SMP | 216,202 | 20,942 | 468.32 | 1.723 ns | **+0.027 ns** | 506.8 MHz |
| `fursoy_s2_coherence_mgr` (`N=4`, **incl. `l2`**) | Slice-2 SMP | 1,857,576 | 224,327 | 3,831.60 | 1.902 ns | **+0.008 ns** | 502.0 MHz |
| `fursoy_s1_agu` | Slice-1 Gated | 817 | 0 | 1.07 | 0.510 ns | **+1.490 ns** | 1,960.8 MHz |
| `fursoy_s1_branch_unit` | Slice-1 Gated | 4,086 | 0 | 5.45 | 0.601 ns | **+1.399 ns** | 1,663.9 MHz |
| `fursoy_s1_ptw` | Slice-1 Gated | 1,797 | 329 | 3.81 | 0.892 ns | **+1.069 ns** | 1,074.1 MHz |
| `fursoy_s1_decode` | Slice-1 Gated | 2,777 | 0 | 3.70 | 0.979 ns | **+1.021 ns** | 1,021.5 MHz |
| `fursoy_s1_alu` | Slice-1 Gated | 4,326 | 0 | 6.34 | 1.153 ns | **+0.847 ns** | 867.3 MHz |
| `fursoy_s1_itlb` (refreshed `S2.5-M2a`, flop array) | Slice-1 Gated | 37,063 | 6,304 | 77.31 | 1.210 ns | **+0.590 ns** | 709.2 MHz |
| `fursoy_s1_dtlb` (refreshed `S2.5-M2a`, flop array) | Slice-1 Gated | 50,439 | 6,515 | 99.95 | 1.275 ns | **+0.525 ns** | 678.0 MHz |
| `fursoy_s1_csr` | Slice-1 Gated | 14,491 | 1,872 | 27.89 | 1.342 ns | **+0.623 ns** | 726.2 MHz |
| `fursoy_s1_vec_div` (Radix-4 restoring RVV) | `S2.5-M1b` Arith | 8,666 | 334 | 13.63 | 1.023 ns | **+0.887 ns** | 898.5 MHz |
| `fursoy_s1_multiplier` (3-stage `65×65` Booth+Wallace) | `S2.5-M1b` Arith | 23,551 | 1,026 | 41.24 | 1.139 ns | **+0.776 ns** | 817.0 MHz |
| `fursoy_s1_fdiv` (Radix-4 restoring IEEE-754) | `S2.5-M1b` Arith | 12,564 | 850 | 22.89 | 1.431 ns | **+0.480 ns** | 657.9 MHz |
| `fursoy_s1_rob` (`128`-entry, `16`-chkpt) | `S2.5-M4` Core | 328,755 | 29,470 | 572.08 | 1.504 ns | **+0.246 ns** | 570.1 MHz |
| `fursoy_s1_prf` (`160×64b` flop array) | `S2.5-M4` Core | 303,237 | 16,384 | 618.67 | 0.911 ns | **+0.839 ns** | 861.3 MHz |
| `fursoy_s1_fprf` (`64×64b` flop array) | `S2.5-M4` Core | 48,981 | 4,096 | 102.71 | 0.811 ns | **+0.939 ns** | 942.5 MHz |
| `fursoy_s1_l1i` (`16 KiB` 4-way flop array, `abc_fast`) | `S2.5-M4` Core | 1,021,062 | 143,354 | 1,805.03 | 1.247 ns | **+0.503 ns** | 668.0 MHz |
| `fursoy_s1_vrf` (`64×256b` 4-bank flop array) | `S2.5-M4` Core | 162,739 | 16,384 | 332.37 | 0.790 ns | **+0.960 ns** | 961.5 MHz |
| `fursoy_s1_divider` (iterative Radix-4 RV64M) | `S2.5-M4` Core | 801 | 91 | 1.43 | 1.099 ns | **+0.817 ns** | 845.3 MHz |
| `fursoy_s1_freelist` (`128`-entry, `16`-chkpt) | `S2.5-M4` Support | 18,338 | 1,059 | 32.57 | 1.469 ns | **+0.432 ns** | 637.8 MHz |
| `fursoy_s1_rat` (Int SRAT/ARAT + `16`-chkpt) | `S2.5-M4` Support | 38,719 | 4,728 | 73.63 | 1.573 ns | **+0.332 ns** | 599.5 MHz |
| `fursoy_s1_prf_status` (`160`-entry scoreboard) | `S2.5-M4` Support | 3,962 | 159 | 6.56 | 0.947 ns | **+0.960 ns** | 961.5 MHz |
| `fursoy_s1_frat` (FP FRAT + `32` FL + `16`-chkpt) | `S2.5-M4` Support | 32,326 | 3,674 | 64.89 | 1.628 ns | **+0.281 ns** | 581.7 MHz |
| `fursoy_s1_fprf_status` (`64`-entry scoreboard) | `S2.5-M4` Support | 1,692 | 64 | 2.80 | 0.798 ns | **+1.108 ns** | 1,121.1 MHz |
| `fursoy_s1_port1_buffers` | `S2.5-M4` Support | 5,426 | 588 | 10.01 | 0.879 ns | **+1.037 ns** | 1,038.4 MHz |
| `fursoy_s1_trt` (`32`-entry translation tracker) | `S2.5-M4` Support | 10,260 | 1,568 | 20.16 | 1.366 ns | **+0.540 ns** | 684.9 MHz |
| `fursoy_s1_fetch_queue` (`16`-entry fetch queue) | `S2.5-M4` Support | 54,636 | 7,329 | 104.30 | 0.879 ns | **+1.027 ns** | 1,027.7 MHz |
| `fursoy_s1_serialization` | `S2.5-M4` Support | 918 | 146 | 2.04 | 1.304 ns | **+0.612 ns** | 720.5 MHz |

</details>

- **Area Accounting & Synchronous SRAM Sensitivity (`tCQ = 0.60, 0.80, 1.00 ns`, `tSetup = 0.20 ns`):**
  - **Bottom-up 35-leaf core area:** **`5,373.87 kGE` / `316,450 DFFs`** (excluding `lsu_queues`, `bpu`, and wrapper glue), dominated by flop-array **`fursoy_s1_l1i` (`1,805.03 kGE` / `143,354 DFFs`, 33.6% of characterized core area)**, `prf` (`618.67 kGE`), `rob` (`572.08 kGE`), `l1d` logic (`468.32 kGE`), and `vrf` (`332.37 kGE`).
  - **Coherence Manager vs. L2 Decomposition (No Double-Counting):** `fursoy_s2_coherence_mgr` instantiates `fursoy_s2_l2` internally (`3,831.60 kGE` / `224,327 DFFs` inclusive = **`3,269.96 kGE` / `212,480 DFFs` L2** + **`561.64 kGE` / `11,847 DFFs` standalone coherence hub**).
  - **Synchronous SRAM Macro Sensitivity (`tCQ = 0.60 / 0.80 / 1.00 ns`, `tSetup = 0.20 ns`, `0` W1216/W441):** `fursoy_s1_l1d` block WNS = **`+0.108 ns`** (`528.5 MHz`, SRAM-launch `+0.807 / +0.607 / +0.407 ns`, capture `+0.327 ns`); `fursoy_s2_l2` block WNS = **`+0.314 ns`** (`593.1 MHz`, launch `+1.000 / +0.800 / +0.600 ns`, capture `+1.521 ns`); `fursoy_s2_coherence_mgr` block WNS = **`+0.008 ns`** (`502.0 MHz`, launch `+1.119 / +0.919 / +0.719 ns`, capture `+0.743 ns`). **Architectural Caveat:** Real physical synchronous SRAM macros require adding a **1-cycle synchronous read pipeline stage** in Slice-3 cache RTL (`l1d`/`l2`/`l1i`), since current Slice-2 cache RTL expects same-cycle combinational read data.

---

## Reproducibility & Open-Source EDA Toolchain

### Verified Environment (Ubuntu 24.04 Linux / WSL2)

- **Simulation & Compilers:** `Verilator 5.020`, `g++`, `Python 3`, `device-tree-compiler`, `RISC-V GCC 13.2.0` (`gcc-riscv64-unknown-elf`, `gcc-riscv64-linux-gnu`)
- **Golden Model & Compliance:** `sail-riscv 0.16` (`tools/sail/bin/bin/sail_riscv_sim`, config at [`tools/sail/fursoy_s1_sail_config.json`](tools/sail/fursoy_s1_sail_config.json)), `RISCOF 1.25.3` + `riscv-arch-test`
- **Synthesis & STA:** `sv2v v0.0.13`, `Yosys 0.33`, `OpenSTA 3.1.0`, Nangate 45nm Typical `.lib` (`FURSOY_LIBERTY` or `tools/synth/lib/NangateOpenCellLibrary_typical.lib`)

```bash
sudo apt-get update && sudo apt-get install -y \
  verilator g++ python3 device-tree-compiler \
  gcc-riscv64-unknown-elf gcc-riscv64-linux-gnu
```

### Clean-Clone Verification Commands

```bash
# 1. Production RTL lint & Sail-RISC-V v0.16 directed lockstep co-simulation
python3 tools/run_s1_lint.py
python3 tools/run_s1_sail_cosim.py

# 2. Slice-2.5 Arithmetic, Official RISCOF (245/245), 20-Seed Sail Fuzzer & 10k-Iter RVWMO Litmus
python3 tools/run_s25_m1b_arith.py
python3 tools/run_s25_riscof.py
python3 tools/run_s25_sail_fuzz.py
python3 tools/run_s25_litmus_10k.py

# 3. Slice-2.5 Standard Industry Benchmarks (CoreMark, Embench-IoT v2.0, STREAM FP64, Dhrystone 2.1)
python3 tools/run_s25_benchmarks.py

# 4. Mainline Linux 6.6.50 CONFIG_SMP=y + CONFIG_FPU=y Boot & Preemption Validation (N=2 & N=4)
python3 tools/run_s25_linux_fpu_smp.py

# 5. Physical Synthesis & OpenSTA: 14-Block Baseline Gate + Full Core-Wide Characterization & Sync SRAM Sweep
python3 tools/run_s2_synth.py
python3 tools/run_s25_core_sta.py
```

---

## Repository & RTL Module Hierarchy

| Directory | Key Modules & Artifacts |
| :--- | :--- |
| [`rtl/core/`](rtl/core/) | `fursoy_s1_core.sv` (`fursoy_s1_pkg.sv`, `frontend`, `bpu`, `fetch_queue`, `decode`, `substrate`, `rat`/`frat`/`vrat`, `rob`, `prf`/`fprf`/`vrf`, `int_iq`/`mem_iq`/`fp_iq`/`vec_iq`, `ks_adder`, `alu`/`branch_unit`/`multiplier`/`divider`/`fma`/`fdiv`/`fconv`/`vec_div`, `agu`/`lsu`/`lsu_queues`/`trt`, `itlb`/`dtlb`/`ptw`, `l1i`/`l1d`, `csr`, `hpm`) + Slice-0 reference modules |
| [`rtl/platform/`](rtl/platform/) | **Slice-2 SMP:** `fursoy_s2_soc.sv`, `fursoy_s2_coherence_mgr.sv`, `fursoy_s2_l2.sv`, `fursoy_s2_mmio_xbar.sv`, `fursoy_s2_clint.sv`, `fursoy_s2_plic.sv` · **Slice-1/0:** `fursoy_s1_soc.sv`, `fursoy_s0_uart.sv`, `fursoy_s0_clint.sv`, `fursoy_s0_plic.sv` |
| [`software/`](software/) | Custom M-mode SBI v2.0 (`fursoy_s1_sbi_*`, `fursoy_s2_sbi_*`), Linux 6.6.50 defconfigs (`fursoy_s0_defconfig`, `fursoy_s2_defconfig`), BusyBox `/init` + `s2_smp_test.c` (SMP + FPU preemption), and bare-metal benchmarks / SMP / litmus / torture / IRQ-stress tests |
| [`verification/`](verification/) | Verilator C++ testbenches (`s2_swmr_scoreboard.h`, `s2_m1..m5*_tb.cpp`, `s2_mmio_irq_stress_tb.cpp`, `s1_sail_cosim_tb.cpp`, `s1_m9_closeout_tb.cpp`, `s25_*_tb.cpp`) |
| [`tools/`](tools/) | Python runners (`run_s1_lint.py`, `run_s1_sail_cosim.py`, `run_s2_m1..m5.py`, `run_s2_synth.py`, `run_s25_m1b_arith.py`, `run_s25_riscof.py`, `run_s25_sail_fuzz.py`, `run_s25_litmus_10k.py`, `run_s25_benchmarks.py`, `run_s25_linux_fpu_smp.py`, `run_s25_core_sta.py`) |
| [`docs/architecture/`](docs/architecture/) | Frozen architecture contracts & sizing memo ([`slice3-sizing-memo.md`](docs/architecture/slice3-sizing-memo.md), `slice2-smp-v1.md`, `slice1-core-v1.md`, `slice1-m7-multibank-l1d-v1.md`, `slice1-m8-fp-vector-v1.md`, `slice1-m9-soc-linux-v1.md`, `sv39-mmu-v1.md`, `pmp-v1.md`, `plic-v1.md`, `rv64a-v1.md`) |
| [`results/`](results/) | Frozen JSON evidence (`s1-*.json`, `s2-m1..m5-closeout.json`, `s25-m1b-arith.json`, `s25-riscof.json`, `s25-sail-fuzz.json`, `s25-litmus-10k.json`, `s25-benchmarks.json`, `s25-linux-fpu-smp.json`, `s25-core-sta.json`) |

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
