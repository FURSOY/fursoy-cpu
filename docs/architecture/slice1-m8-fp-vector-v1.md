# Fursoy Slice-1 Milestone 8 — Standard Floating-Point (RV64FD) & Vector Execution (RVV 1.0) Architecture Specification

**Document ID:** `docs/architecture/slice1-m8-fp-vector-v1.md`  
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.0 (Ready for Independent Architecture Review)  
**Target Core:** Fursoy Slice-1 (Single-Hart 2-Wide OoO RV64IMAFD_Zba_Zbb_Zicsr_Zifencei_Sv39 + RVV 1.0 Vector Subsystem)  
**Predecessor Substrates (Frozen):**
- **Milestone 1** (Verified & Frozen): PRF80, ROB48, FreeList48, SRAT/ARAT, 8 Checkpoints, Recovery Substrate.
- **Milestone 2** (Verified & Frozen): PRF Data Storage 64b, IntIQ16, Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV, Lossless WB.
- **Milestone 3** (Verified & Frozen): MemIQ12, LQ16, SQ16, Port 2 AGU, L1D 16 KiB 4W, 4 MSHR, 2 WBB, TRT4, PRF 6R3W.
- **Milestone 4** (Verified & Frozen): Decoupled Frontend (F0–D0), FQ12, BTB512 2W, Gshare4096 12b GHR, RAS16, L1I 16 KiB 4W, 2 I-MSHR, ITLB64 4W + 8-entry Superpage CAM, Shared Sv39 PTW, Privileged CSR/System Execution (`satp`, `SFENCE.VMA`, MRET/SRET), `FENCE.I` Clean/Invalidate.
- **Milestone 5** (Verified & Frozen): Integrated Performance, Telemetry & Throughput Optimization (Phase A HPM 48 event sources, up to 29 programmable 64-bit counters, 8-category single-owner CPI decomposition engine; Phase B1 speculative load issue past unresolved stores with LQ CAM snooping & ROB sticky mem_violation & one-shot replay-safe token; Phase B2 FQ16 expansion; Phase B3 MemIQ16 expansion; Phase B4 Oldest-Ready Matrix Scheduling).
- **Milestone 6** (Verified & Frozen): Advanced Branch Prediction & Instruction Stream Optimization (Phase A TAGE-Lite 5-table predictor ~3.7 KiB; Phase B Hardened RAS with RISC-V §2.5 coroutine-swap classification; Phase C Conservative L1I Next-Line Prefetcher with 4 KiB page abort; Phase D HPM Telemetry & CPI Conservation Closeout).
- **Milestone 7** (Verified & Frozen): Multi-Banked L1D, Dual AGU & Coherent Interconnect Integration (Phase A Port 2 AGU0 / Port 3 AGU1 load-dedicated issue & MemIQ16 dual-issue scheduler; Phase B 4-banked synonym-safe 16 KiB L1D datapath with same-bank collision arbitration & doubleword broadcast; Phase C dual-ported LQ16/SQ16 multi-lane store-to-load forwarding; Phase D protocol-neutral coherent snoop query/invalidation boundary & HPM expansion to 56 events).

**Predecessor Freeze Baseline:**
- Milestone 7 Freeze Commit: `8b288b4839d1ea347f451f6c0117f5e445160e83`
- Combined Frozen M1–M7 Production RTL Manifest SHA-256 (31 files):  
  `30e5f88882c78c413eee9aaa88527b42df402a3fc0ac682a74786d8d5fbf6003`
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m3-memory-v1.md`, `docs/architecture/slice1-m5-performance-v1.md`, `docs/architecture/slice1-m6-frontend-opt-v1.md`, `docs/architecture/slice1-m7-multibank-l1d-v1.md`.

> **Post-Phase-3 RTL Note (`bab4ceb`):** Phase 2–3 RTL (`docs/architecture/slice1-core-v1.md`) upgraded scalar FP and RVV 1.0 execution beyond this initial M8 draft: `fursoy_s1_fconv.sv` is 2-stage pipelined (`500 MHz` STA met at `+0.009 ns` WNS) with `IntIQ` `int2fp` backpressure via `fconv_fprf_busy`, SP subnormal `fcvt.d.s` fix, and dynamic `rm==7 && frm>=5` illegal-op trapping; the vector subsystem expanded `VRF_NUM_PREGS` from `48` to `64` with a 4th read port (`old_vd`), replaced `vecq_q[8]` and `test_viq_*` with **`fursoy_s1_vrat.sv`** (`p32..p63` bitmap freelist, 16 checkpoints, non-contiguous group map tables) + **`fursoy_s1_vec_iq.sv` (`VIQ8`)** OoO vector ALU + ROB-head vector memory, 128-bit dual-lane SIMD beats, indexed `vluxei`/`vsoxei` support, `calc_vec_emul_info` legality traps, and age-qualified non-zero `vstart` serialization, verified against `sail-riscv v0.16` across 8 suites (`0` mismatches).

---

## 1. Milestone Objective, Phased Charter & Scope Boundaries

### 1.1 Context & Objective
Milestones 1 through 7 established, verified, and froze an out-of-order, superscalar RISC-V processor core with robust branch prediction, non-blocking multi-banked caching, and dual-AGU memory execution:
- **Milestones 1–3** delivered the fundamental integer out-of-order execution substrate, 2-wide rename, 64-bit integer PRF, lossless integer completion buffers, and out-of-order memory execution.
- **Milestones 4–6** provided an autonomous decoupled frontend with a 5-table TAGE-Lite predictor, hardened coroutine-aware RAS, L1I prefetching, speculative load disambiguation past unresolved stores, and an 8-category single-owner CPI cycle conservation engine.
- **Milestone 7** eliminated the memory execution bottleneck by deploying dual AGUs (Port 2 AGU0 for loads/stores/AMOs/fences, Port 3 AGU1 for loads), a 4-banked synonym-safe 16 KiB L1 data cache with dynamic conflict arbitration and DW broadcast, multi-lane LSQ store-to-load forwarding, and a protocol-neutral coherent caching-agent boundary.

Despite these advanced microarchitectural capabilities, the processor is currently constrained to the **integer-only computational profile** (`RV64IMAZbaZbb`). In scientific computing, numerical linear algebra, machine learning inference, multimedia signal processing, and enterprise server workloads (such as analytical databases and modern runtime engines), the absence of standard hardware floating-point and vector execution forces either expensive software emulation traps or complete binary incompatibility.

The objective of **Milestone 8 (M8)** is to deliver the complete computational profile for Fursoy Slice-1 by implementing:
1. **Standard Floating-Point Execution (RV64F, RV64D)**: Full IEEE 754-2008 compliant single-precision (FP32) and double-precision (FP64) arithmetic, fused multiply-add (FMA), iterative division/square-root, conversions, sign injection, and comparisons.
2. **Dedicated Floating-Point Substrate**: A dedicated 64-bit Floating-Point Physical Register File (FPRF), independent Floating-Point Register Alias Tables (FRAT: speculative SRAT_FP and committed ARAT_FP), and seamless integration with the branch checkpoint recovery engine.
3. **Privileged Context & Status Tracking**: Hardware tracking of dynamic rounding modes (`frm`), accrued exception flags (`fflags`), and supervisor context status (`mstatus.FS`, `sstatus.FS`) with mandatory illegal instruction trap protection when disabled.
4. **Seamless Dual-AGU & L1D Integration**: Routing floating-point memory accesses (`FLW`, `FLD`, `FSW`, `FSD`) directly through Port 2 AGU0 and Port 3 AGU1, reading store data from and writing load data directly to the FPRF without crossing into the integer PRF.
5. **Vector Execution Subsystem (RVV 1.0) Architecture**: An auditable architectural blueprint for a decoupled Vector Processing Unit (VPU) featuring `VLEN = 256`, `ELEN = 64`, independent banked Vector Register File (VRF), vector length (`vl`) and type (`vtype`) control, and unit-stride, strided, and indexed memory interfacing.

```
+===================================================================================================+
|                                  MILESTONE 8 ARCHITECTURAL CHARTER                                |
+===================================================================================================+

  1. Scalar Floating-Point Register File & Renaming Substrate (Phase A):
     Implement a dedicated 64-entry 64-bit FPRF, separate from the integer PRF. Provide independent
     speculative (SRAT_FP) and committed (ARAT_FP) renaming tables, Free List (FL_FP), and 8 branch
     checkpoint snapshots. Manage fcsr (fflags, frm) and mstatus.FS context switching.

  2. Pipelined FMA & Iterative FDIV/FSQRT Execution Pipeline (Phase B):
     Add Port 4 with a 16-entry Floating-Point Issue Queue (FPIQ16). Implement an IEEE 754-2008
     compliant pipelined FMA unit (4-cycle FP64, 3-cycle FP32) and an out-of-order, non-blocking
     iterative Radix-4 FDIV/FSQRT unit. Enforce standard NaN boxing for 32-bit floats.

  3. Floating-Point Memory Operations & RAW Forwarding (Phase C):
     Integrate FLW, FLD, FSW, FSD into the Port 2 / Port 3 Dual-AGU pipeline. FP stores read store
     data from FPRF; FP loads bypass and writeback directly to FPRF. Maintain multi-lane store-to-load
     forwarding and speculative load order disambiguation across mixed int/FP memory operations.

  4. Vector Execution Subsystem (RVV 1.0) Architecture Contract (Phase D):
     Establish the architectural contract for RVV 1.0 with VLEN=256, ELEN=64, 32 architectural vector
     registers, banked VRF storage, decoupled vector issue queue, vector memory unit (unit-stride,
     strided, indexed, fault-only-first), and vector integer/FP SIMD execution pipelines.

  5. Telemetry Extension, Verification Matrix & Milestone 8 Closeout (Phase E):
     Expand HPM event bus to 64 events (Events 0x39..0x40 for FP/Vector telemetry). Verify zero-leakage
     CPI cycle conservation. Prove 40 directed/adversarial properties (PROP_M8_01..PROP_M8_40).
```

### 1.2 Strict Scope Boundaries

To maintain high PPA quality, prevent unverified timing regressions, and adhere to sound engineering principles, the following boundaries are strictly enforced:

#### In-Scope:
- Full RV64F and RV64D instruction set architecture support complying with unprivileged RISC-V ISA specification v20191213.
- IEEE 754-2008 compliance: all five standard rounding modes (RNE, RTZ, RDN, RUP, RMM), dynamic rounding mode (DYN via `fcsr.frm`), exact accrued exception flags (NV, DZ, OF, UF, NX), subnormal numbers, and canonical NaN generation.
- Dedicated 64-entry 64-bit Floating-Point Physical Register File (FPRF) with 4 Read Ports and 3 Writeback Ports.
- 32-entry speculative (SRAT_FP) and committed (ARAT_FP) rename tables with 8 branch checkpoints.
- Port 4 execution lane with 16-entry Floating-Point Issue Queue (`FPIQ16`).
- Fully pipelined FMA unit (FP64/FP32 multiply-add, add, sub, mul) with 4-cycle FP64 / 3-cycle FP32 latency.
- Non-blocking iterative Radix-4 SRT FP Divider & Square-Root unit (`fdiv_buf`).
- Cross-domain float-to-integer (`FCVT.W.D`, `FMV.X.D`, `FEQ`, `FLT`, etc.) and integer-to-float (`FCVT.D.W`, `FMV.D.X`) transfers.
- Full integration of `FLW`, `FLD`, `FSW`, `FSD` into Port 2 (AGU0) and Port 3 (AGU1) with 4-banked L1D and LSQ.
- Architectural contract and interface specification for RVV 1.0 Vector Subsystem (`VLEN=256`, `ELEN=64`).
- Telemetry expansion (Events 0x39..0x40) and preservation of single-owner 8-category CPI cycle conservation.

#### Strictly Out-of-Scope:
- **Core Dispatch / Retirement Width Expansion**: The core frontend and retirement remain strictly **2-wide**. No 3-wide or 4-wide dispatch/commit logic is introduced.
- **Unified Int/FP Physical Register File**: Merging integer and floating-point registers into a single monolithic PRF is **strictly rejected** due to port multiplication and wire routing congestion.
- **Unpipelined FMA**: Multi-cycle iterative FMA is prohibited; the high-performance design requires fully pipelined 1-result/cycle FMA throughput.
- **Flushing Subnormals to Zero (FTZ / DAZ)**: Non-compliant FTZ/DAZ modes are prohibited for standard RV64FD compliance. Full IEEE subnormal support is mandatory.
- **Full RVV 1.0 RTL Implementation in M8 Phase A–C**: Phase A–C deliver production scalar RV64FD RTL. Phase D establishes the formal architectural and interface contract for RVV 1.0; vector physical execution RTL is staged following scalar freeze.
- **Quarter-Precision or Bfloat16 Vector Arithmetic**: Only standard RVV 1.0 element widths (SEW = 8, 16, 32, 64) are covered.

---

## 2. Frozen Predecessor Baseline Assumptions & Exact Interfaces

Milestone 8 directly interfaces with the frozen Milestone 1 through 7 production RTL components:

```
+---------------------------------------------------------------------------------------------------+
|                                  FROZEN MILESTONE 1-7 BASELINE                                    |
+---------------------------------------------------------------------------------------------------+
|  Frontend: Decoupled F0-D0, 2-wide Decode, 5-table TAGE-Lite, 16-entry Hardened RAS, L1I NLP      |
|  Rename Substrate: 2-wide Integer SRAT/ARAT, 48-entry Free List, 8 Checkpoints, Epoch-tagged ROB48|
|  Integer PRF: 80 entries x 64-bit, 7 Read Ports (r0..r6), 4 Writeback Ports (w0..w3)             |
|  Integer Issue: 16-entry IntIQ (Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV)                             |
|  Memory Subsystem: MemIQ16 (Dual-issue), Port 2 AGU0, Port 3 AGU1, 16-entry LQ, 16-entry SQ       |
|  L1 Data Cache: 16 KiB 4-way VIPT, 4 independent 64-bit Banks, 4 MSHRs, 2 WBBs, Coherent Snoop    |
|  Instrumentation: 56 HPM events, 29 programmable counters, 8-category CPI cycle conservation     |
+---------------------------------------------------------------------------------------------------+
```

### 2.1 Preserved Core Interconnects & Signal Contracts
1. **Substrate Allocation & Retirement Interface**:
   - `alloc_valid_i[1:0]`: Up to 2 instructions allocated per cycle at ROB tail.
   - `retire_valid_i[1:0]`: Up to 2 instructions retired in-order per cycle at ROB head.
   - `comp_valid_i[3:0]`: Up to 4 writeback completions arbitrated into ROB (`comp_rob_idx_i`, `comp_epoch_i`). M8 Phase B expands this interface to accommodate Port 4 FP completion (`comp_valid_i[4:0]`).
2. **Integer PRF Interface**:
   - Preserves 7 read ports: `r0`, `r1` (Port 0), `r2`, `r3` (Port 1), `r4` (Port 2 base), `r5` (Port 2 store data), `r6` (Port 3 base).
   - Preserves 4 writeback ports: `w0` (Port 0 ALU0/BR), `w1` (Port 1 ALU1/MUL/DIV), `w2` (Port 2 AGU0 load), `w3` (Port 3 AGU1 load).
3. **Dual-AGU Memory Interface**:
   - Port 2 (AGU0): Generates physical address `p2_req_pa_o[55:0]`, access size `p2_req_size_o[1:0]`, command `p2_req_cmd_o` (Load, Store, AMO, Fence).
   - Port 3 (AGU1): Generates physical address `p3_req_pa_o[55:0]`, access size `p3_req_size_o[1:0]`, command strictly `UOP_LOAD`.
   - L1D 4-Banked Datapath: Addressed by `Bank_ID = PA[4:3]`. Concurrent load/store accesses to distinct banks complete with zero conflict stalls. Same-bank collisions resolve by ROB age with 1-cycle anti-starvation.

---

## 3. Computational Workload & Floating-Point Bottleneck Audit

Processor floating-point and vector performance is evaluated across numerical, scientific, and mixed-compute workloads:

| Workload Domain | Canonical Examples | Key Bottlenecks in M7 Baseline | M8 Architectural Remedy |
|---|---|---|---|
| **Linear Algebra & BLAS** | SGEMM, DGEMM, Linpack | Traps to soft-float; 100x+ cycle penalty | Pipelined FP64/FP32 FMA (1 result/cycle) |
| **Numerical Integration** | SciMark2, Whetstone | Emulated FP division/sqrt stalls pipeline | Out-of-order non-blocking Radix-4 FDIV/FSQRT |
| **Signal Processing & FFT** | 1D/2D FFT, Convolutions | Single-element memory & register pressure | Dual FP loads via Dual AGU; RVV 1.0 SIMD |
| **Machine Learning / AI** | Tensor inference, Quantization | Inefficient scalar loops, conversions | Vector unit-stride memory, FP/Int conversions |
| **Server Database / Analytics**| Columnar aggregation, geospatial | Mixed integer/float comparisons & moves | Single-cycle `FMV`, fast FP compare `FEQ/FLT` |

---

## 4. Phased Implementation Structure & Rejected/Deferred Design Alternatives

To ensure auditable, step-by-step progress, Milestone 8 is divided into five sequential phases:

```
+---------------------------------------------------------------------------------------------------+
|                                  MILESTONE 8 PHASED ROADMAP                                       |
+---------------------------------------------------------------------------------------------------+
|  Phase A: Floating-Point Register File (FPRF), Rename Substrate & CSRs (fcsr, mstatus.FS)         |
|  Phase B: Scalar FP Execution Pipeline (Pipelined FMA, Iterative FDIV/FSQRT, Conversions)         |
|  Phase C: Floating-Point Memory Operations (FLW, FLD, FSW, FSD, LSQ Forwarding)                   |
|  Phase D: Vector Execution Subsystem (RVV 1.0) Architecture Contract (VLEN=256, VRF, VMU)        |
|  Phase E: Telemetry Extension (Events 0x39..0x40), CPI Conservation & Milestone 8 Closeout         |
+---------------------------------------------------------------------------------------------------+
```

### 4.1 Rejected and Deferred Design Alternatives

```
+===================================================================================================+
| ARCHITECTURAL DECISION: SEPARATE FP REGISTER FILE VS. UNIFIED INT/FP PRF                          |
+===================================================================================================+
| Decision: Implement a dedicated 64-entry x 64-bit Floating-Point Physical Register File (FPRF),    |
| completely distinct from the 80-entry Integer PRF.                                                |
|                                                                                                   |
| Rationale & Trade-Off Analysis:                                                                   |
| 1. Unified PRF Port Explosion: A unified register file would require supporting 7 Integer read    |
|    ports + 3 FP read ports = 10 Read Ports, and 4 Integer write ports + 1 FP write port = 5 Write |
|    Ports (10R5W total). In modern silicon standard cells, register file area scales roughly with  |
|    (R + W)^2, increasing PRF area by >2.3x and imposing prohibitive wire congestion.              |
| 2. Bypass Network Delay: Interleaving integer and FP bypass networks would force long wires       |
|    between the ALU execution lanes and FMA units, directly threatening the 1-cycle integer ALU    |
|    bypass timing loop.                                                                            |
| 3. Independent Lifetime Management: FP register pressure does not artificially exhaust integer    |
|    free physical registers, preventing integer rename stalls during FP-heavy loop execution.      |
|                                                                                                   |
| Cost: Cross-domain moves (FMV.X.D, FMV.D.X) require a 1-cycle synchronization handoff between     |
| separate register files. Benchmark analysis shows move frequency is <1.5% of total FP uops.       |
+===================================================================================================+
```

```
+===================================================================================================+
| ARCHITECTURAL DECISION: FULLY PIPELINED FMA VS. MULTI-CYCLE ITERATIVE MULTIPLY-ADD                |
+===================================================================================================+
| Decision: Implement a fully pipelined 4-cycle FP64 / 3-cycle FP32 FMA unit capable of initiating  |
| and completing one operation every cycle.                                                         |
|                                                                                                   |
| Rationale:                                                                                        |
| Iterative or multi-cycle unpipelined FMA creates severe structural hazards in linear algebra and   |
| scientific code, dropping sustained compute throughput to <0.25 FLOP/cycle. Fully pipelined FMA   |
| achieves 1.0 result/cycle sustained throughput, unlocking high-performance vector and scalar math.|
+===================================================================================================+
```

---

## 5. Scalar Floating-Point Register File (FPRF), Renaming & Context Control Contract (Phase A)

### 5.1 Floating-Point Physical Register File (FPRF) Geometry

The scalar floating-point subsystem features a dedicated register file:
- **Capacity**: 64 physical floating-point registers (`FPRF_SIZE = 64`), indexed by a 6-bit physical register address (`fpreg_t = logic [5:0]`).
- **Architectural Registers**: 32 architectural floating-point registers (`f0`..`f31`), indexed by `fareg_t = logic [4:0]`.
- **Free List Depth**: 32 entries (`FL_FP_DEPTH = FPRF_SIZE - FAREG_COUNT = 32`).
- **Data Width**: 64 bits per entry, storing IEEE 754 double-precision floats or NaN-boxed single-precision floats.
- **Unlike Integer Register `x0`**: Floating-point register `f0` is **NOT hardwired to zero**. `f0` is a general-purpose floating-point register that holds arbitrary values. Writes to `f0` allocate physical registers normally.

```
       +--------------------------------------------------------------+
       |   FPRF Physical Register Array: 64 Entries x 64 Bits Wide    |
       +--------------------------------------------------------------+
         Read Ports (4 Total):
           - Port 4 FMA Operand 1 (rs1) -> 64-bit
           - Port 4 FMA Operand 2 (rs2) / FDIV rs1 -> 64-bit
           - Port 4 FMA Operand 3 (rs3) / FDIV rs2 -> 64-bit
           - Port 2 Store Data (FSW / FSD) / Cross-domain Move -> 64-bit
         Write Ports (3 Total):
           - w0_fp: Port 4 FMA / FDIV / FCONV Result Writeback
           - w1_fp: Port 2 AGU0 / L1D Load Data Writeback (FLW / FLD)
           - w2_fp: Port 3 AGU1 / L1D Load Data Writeback (FLW / FLD)
```

### 5.2 Floating-Point Register Alias Table (FRAT) & Checkpointing
The core maintains separate architectural and speculative register mapping tables for floating-point registers:
1. **Committed Architectural RAT (`ARAT_FP`)**: 32 entries mapping `f0`..`f31` to their committed physical registers. Updated strictly in program order as FP uops retire at the ROB head.
2. **Speculative Working RAT (`SRAT_FP`)**: 32 entries tracking in-flight renames during 2-wide dispatch.
3. **2-Wide Rename Rules**:
   - Intra-group RAW: If `uop1` reads `fs1`/`fs2`/`fs3` matching `uop0.fd`, `uop1` receives `uop0.Pnew_fp` directly.
   - Intra-group WAW: If `uop0` and `uop1` write the same `fd`, `uop1.Pold_fp` becomes `uop0.Pnew_fp`, and `uop1.Pnew_fp` is written to `SRAT_FP`.
4. **Branch Checkpointing**:
   - The 8 branch checkpoints snapshot both the integer `SRAT` and `SRAT_FP` simultaneously.
   - On a branch misprediction, the snapshot `SRAT_FP` is restored in a single cycle.

### 5.3 Privileged Context & CSR Control (`fcsr`, `mstatus.FS`)
1. **Floating-Point Control & Status Register (`fcsr`, CSR 0x003)**:
   - `fflags` (`fcsr[4:0]`, CSR 0x001): Accrued exception flags:
     * `fflags[4]` = `NV` (Invalid Operation)
     * `fflags[3]` = `DZ` (Divide by Zero)
     * `fflags[2]` = `OF` (Overflow)
     * `fflags[1]` = `UF` (Underflow)
     * `fflags[0]` = `NX` (Inexact)
   - **In-Order Exception Flag Retirement Invariant**:
     * Accrued arithmetic exception flags generated during execution (`comp_fflags[4:0]`) do **NOT** update `fcsr.fflags` speculatively during the writeback stage.
     * Instead, `comp_fflags[4:0]` are transmitted alongside `comp_valid` into the ROB completion bus and captured into the corresponding ROB entry payload (`rob_entry_t.fflags[4:0]`).
     * Only when an FP instruction reaches the ROB head and commits in-order are its accrued exception flags logically ORed into the architectural register: `fcsr.fflags <= fcsr.fflags | rob_retire_fflags`.
     * Speculative FP instructions squashed due to branch misprediction, memory violation replay, or traps never update `fcsr.fflags`, preventing any architectural flag contamination from mispredicted paths.
   - `frm` (`fcsr[7:5]`, CSR 0x002): Dynamic rounding mode:
     * `3'b000` = `RNE` (Round to Nearest, ties to Even)
     * `3'b001` = `RTZ` (Round Towards Zero)
     * `3'b010` = `RDN` (Round Down, towards -infinity)
     * `3'b011` = `RUP` (Round Up, towards +infinity)
     * `3'b100` = `RMM` (Round to Nearest, ties to Max Magnitude)
     * `3'b101`..`3'b110` = Reserved (Raises illegal instruction trap if selected)
     * `3'b111` = `DYN` (Instruction specifies dynamic rounding via `fcsr.frm`)
2. **Privileged Status Control (`mstatus.FS` and `sstatus.FS`)**:
   - Bits [14:13] of `mstatus` and `sstatus`:
     * `2'b00` = **Off**: Any floating-point instruction (`FLW`, `FLD`, `FSW`, `FSD`, FP arithmetic, or CSR access to `fcsr`/`frm`/`fflags`) raises an **Illegal Instruction Exception** (`mcause = 2`).
     * `2'b01` = **Initial**: Floating-point unit is enabled in clean initial state.
     * `2'b10` = **Clean**: State is clean and identical to context-saved state.
     * `2'b11` = **Dirty**: State has been modified since last save.
   - **Dirty Transition**: Any retired floating-point instruction that writes an architectural register `f0`..`f31` or modifies `fcsr` flags automatically sets `mstatus.FS = 2'b11` and `mstatus.SD = 1'b1`.

---

## 6. Pipelined FMA, Iterative FDIV/FSQRT & Conversion Pipeline Contract (Phase B)

### 6.1 Port 4 Allocation & Floating-Point Issue Queue (`FPIQ16`)
To maintain integer ALU throughput and avoid scheduling cross-interference, a dedicated **Port 4** execution pipeline is introduced:
- **Queue**: 16-entry dedicated Floating-Point Issue Queue (`FPIQ16`).
- **Wakeup & Arbitration**: Evaluates source readiness across FPRF physical registers (`prs1_fp`, `prs2_fp`, `prs3_fp`). Issues 1 ready floating-point uop per cycle enforcing oldest-ready circular ROB age priority.
- **Completion Interface**: Port 4 drives ROB completion port 4 (`comp_valid[4]`, `comp_rob_idx[4]`, `comp_epoch[4]`, `comp_fflags[4]`). Accrued IEEE flags are buffered into the ROB entry and commit strictly in program order at the ROB head.

```
+---------------------------------------------------------------------------------------------------+
|                                  PORT 4 FP EXECUTION PIPELINE                                     |
+---------------------------------------------------------------------------------------------------+
|  Stage IS: Issue selection from FPIQ16 (Oldest-Ready circular ROB age priority)                   |
|  Stage RF: Read operands from FPRF (up to 3 operands: rs1, rs2, rs3)                              |
|  Stage EX1-EX4: Pipelined FMA Unit (FP64 4-cycle, FP32 3-cycle, fully pipelined)                  |
|  Stage EX-DIV: Iterative Radix-4 SRT FDIV/FSQRT (12-28 cycles, non-blocking to FMA)              |
|  Stage EX-CVT: Conversions, Comparisons, and Sign Injection (1-2 cycles)                          |
|  Stage WB: Validated writeback to FPRF port w0_fp and ROB completion port 4 with comp_fflags       |
+---------------------------------------------------------------------------------------------------+
```

### 6.2 Pipelined FMA Unit Contract
- **Supported Instructions**:
  * Multiply-Add: `FMADD.S`, `FMADD.D`, `FMSUB.S`, `FMSUB.D`, `FNMSUB.S`, `FNMSUB.D`, `FNMADD.S`, `FNMADD.D`
  * Arithmetic: `FADD.S`, `FADD.D`, `FSUB.S`, `FSUB.D`, `FMUL.S`, `FMUL.D`
  * Min/Max: `FMIN.S`, `FMIN.D`, `FMAX.S`, `FMAX.D`
- **Latency & Throughput**:
  * FP64 FMA / Add / Sub / Mul: 4 cycles execution latency, 1.0 result/cycle sustained throughput.
  * FP32 FMA / Add / Sub / Mul: 3 cycles execution latency, 1.0 result/cycle sustained throughput.
  * Min / Max: 1 cycle latency.
- **NaN Boxing Rules for Single-Precision Floats**:
  * In RV64FD, 32-bit single-precision values are stored in 64-bit floating-point registers using **NaN boxing**.
  * The upper 32 bits `[63:32]` must be all 1s (`32'hFFFFFFFF`).
  * When reading a 32-bit float from a 64-bit register, the hardware verifies that bits `[63:32] == 32'hFFFFFFFF`. If not properly boxed, the value is treated as the **canonical quiet NaN** (`32'h7FC00000`).

### 6.3 Iterative FDIV / FSQRT Unit Contract
- **Algorithm**: Non-blocking Radix-4 SRT iterative divider and square-root engine.
- **Latency**:
  * `FDIV.S`: 12 cycles
  * `FDIV.D`: 21 cycles
  * `FSQRT.S`: 15 cycles
  * `FSQRT.D`: 28 cycles
- **Non-Blocking Operation**: The FDIV/FSQRT unit operates out-of-order in parallel with FMA. While FDIV is computing, independent FMA instructions continue to issue and execute on Port 4.
- **Completion Buffer (`fdiv_buf`)**: A single-entry completion buffer catches the FDIV result and waits for arbitration onto writeback port `w0_fp`. FMA writebacks take priority over FDIV writebacks on conflict cycles.

### 6.4 Conversion, Move & Comparison Unit Contract

#### Cross-Domain Issue Queue Allocation & Tracking
Cross-domain instructions span the boundary between the Integer PRF and the Floating-Point PRF. To ensure exact dependency tracking without deadlocks:
1. **Integer-to-Float Operations (`FMV.D.X`, `FMV.W.X`, `FCVT.S.W`, `FCVT.D.W`, `FCVT.S.WU`, `FCVT.D.WU`, `FCVT.S.L`, `FCVT.D.L`, `FCVT.S.LU`, `FCVT.D.LU`)**:
   - Allocate into **`IntIQ16`** (Port 0 or Port 1) at dispatch because their source operand resides in the Integer PRF (`prs1`).
   - Track operand readiness via the integer readiness table (`prs1_ready_i`).
   - When issued, read the integer PRF, perform conversion/move in Stage EX (1 cycle latency), and drive the result onto FPRF writeback port `w0_fp`.
2. **Float-to-Integer Operations (`FMV.X.D`, `FMV.X.W`, `FCVT.W.S`, `FCVT.W.D`, `FCVT.WU.S`, `FCVT.WU.D`, `FCVT.L.S`, `FCVT.L.D`, `FCVT.LU.S`, `FCVT.LU.D`, `FEQ.S/D`, `FLT.S/D`, `FLE.S/D`, `FCLASS.S/D`)**:
   - Allocate into **`FPIQ16`** (Port 4) at dispatch because their source operands reside in the FPRF (`prs1_fp`, `prs2_fp`).
   - Track operand readiness via the floating-point readiness table.
   - When issued, read the FPRF, execute in Stage EX (1 cycle for moves/comparisons/classifications; 2 cycles for conversions), and drive results to the Integer PRF writeback bus.

#### Writeback Bus Arbitration & Zero-Loss Holding Buffer
Float-to-Integer operations compete for Integer PRF writeback ports (`w0`/`w1`):
- **Arbitration Priority**: Integer ALU0/ALU1 writebacks take strict priority over cross-domain Float-to-Integer writebacks (`ALU0/ALU1 > F2I_Move/Conv`).
- **Holding Buffer (`f2i_wb_buf`)**: If a Port 0 or Port 1 ALU writeback coincides with a Float-to-Integer completion in the same cycle, the Float-to-Integer result is captured in a dedicated 1-entry holding buffer (`f2i_wb_buf`) and drains into the Integer PRF on the immediate next available cycle, guaranteeing zero dropped writes and zero data loss.

#### Operation Specifications & Formatting
- **Float-to-Integer Conversions**: `FCVT.W.S`, `FCVT.W.D`, `FCVT.WU.S`, `FCVT.WU.D`, `FCVT.L.S`, `FCVT.L.D`, `FCVT.LU.S`, `FCVT.LU.D`. Operands read from FPRF; results writeback to Integer PRF; accrued flags update `rob_entry_t.fflags`.
- **Integer-to-Float Conversions**: `FCVT.S.W`, `FCVT.D.W`, `FCVT.S.WU`, `FCVT.D.WU`, `FCVT.S.L`, `FCVT.D.L`, `FCVT.S.LU`, `FCVT.D.LU`. Operands read from Integer PRF; results writeback to FPRF via `w0_fp`.
- **Float-to-Float Conversions**:
  * `FCVT.S.D`: Double-to-single narrowing. Converts 64-bit float to 32-bit float with IEEE 754 rounding, accumulates flags into `fflags`, and writes the 32-bit result strictly NaN-boxed into FPRF (`w0_fp`) with bits `[63:32] = 32'hFFFFFFFF`.
  * `FCVT.D.S`: Single-to-double widening. Verifies NaN-boxing of the 32-bit source float (treating unboxed inputs as canonical quiet NaNs), converts to an exact 64-bit float without loss of precision, and writes to FPRF (`w0_fp`).
- **Bitwise Moves & Sign Extension**:
  * `FMV.X.W`: 1-cycle latency bitwise transfer from FPRF to Integer PRF without numeric conversion or flag modification. Per RISC-V Unprivileged ISA §11.6, the lower 32-bit float payload is **sign-extended to 64 bits** in the integer destination register: `rd_val = {{32{fpreg_val[31]}}, fpreg_val[31:0]}`.
  * `FMV.X.D`: 1-cycle latency bitwise transfer of full 64-bit double-precision payload from FPRF directly to Integer PRF: `rd_val = fpreg_val[63:0]`.
  * `FMV.W.X`: 1-cycle latency bitwise transfer from Integer PRF bits `[31:0]` into FPRF bits `[31:0]`, with upper bits `[63:32]` strictly NaN-boxed to `32'hFFFFFFFF`.
  * `FMV.D.X`: 1-cycle latency bitwise transfer of full 64 bits from Integer PRF directly into FPRF.
- **Comparisons & Classification**:
  * `FEQ.S/D`, `FLT.S/D`, `FLE.S/D`: 1-cycle latency. Result boolean flag (0 or 1) written to Integer PRF; exception flags updated in `fcsr.fflags`.
  * `FCLASS.S/D`: 1-cycle latency 10-bit classification mask written to Integer PRF.

---

## 7. Floating-Point Memory Execution Contract (Phase C)

### 7.1 Integration with Dual-AGU & 4-Banked L1D
Floating-point load and store instructions (`FLW`, `FLD`, `FSW`, `FSD`) seamlessly integrate into the frozen Milestone 7 memory execution pipeline:

```
+---------------------------------------------------------------------------------------------------+
|                                  FP MEMORY ISSUE & EXECUTION FLOW                                 |
+---------------------------------------------------------------------------------------------------+
|  1. Address Generation (Port 2 AGU0 or Port 3 AGU1):                                              |
|     Base register rs1 is read from the INTEGER PRF. Displacement is sign-extended.                |
|     AGU computes virtual address; DTLB performs translation to Physical Address (PA).             |
|                                                                                                   |
|  2. Load Execution (FLW / FLD):                                                                   |
|     Can issue on Port 2 (AGU0) or Port 3 (AGU1).                                                  |
|     Accesses 4-banked L1D via Bank_ID = PA[4:3].                                                  |
|     On cache hit: 64b/32b data bypasses and writes directly to FPRF (w1_fp or w2_fp).             |
|     FLW automatically NaN-boxes bits [63:32] with 32'hFFFFFFFF.                                   |
|                                                                                                   |
|  3. Store Execution (FSW / FSD):                                                                  |
|     Issues strictly on Port 2 (AGU0) and allocates entry in SQ16.                                 |
|     Store data fs2 is read from the FLOATING-POINT PRF (via dedicated Read Port 3).               |
|     Committed store drains into 4-banked L1D in program order without cache bank stalls.          |
+---------------------------------------------------------------------------------------------------+
```

### 7.2 Store-to-Load Forwarding & Memory Disambiguation
1. **Int-to-FP & FP-to-Int Store Forwarding**:
   - The Store Queue (SQ16) stores 64-bit raw payload data.
   - An `FLD` following an older `FSD` or integer `SD` to the identical physical address forwards 64-bit data directly via SQ CAM search (`PROP_M8_21`).
   - An `FLW` following an older `FSW` or integer `SW` forwards 32-bit data and automatically applies NaN-boxing (`PROP_M8_22`).
2. **Speculative Load Replay Invariants**:
   - Speculative `FLD`/`FLW` issued past unresolved stores maintain entries in LQ16 until older stores resolve.
   - Older store resolution CAM snooping asserts `lsu_violation_valid_o` on physical address match, setting sticky `mem_violation` in ROB and triggering pipeline recovery with one-shot `replay_safe` protection.

---

## 8. Vector Processing Subsystem (RVV 1.0) Architecture Contract (Phase D)

The Fursoy Slice-1 Vector Processing Subsystem implements the official **RISC-V Vector Extension (RVV 1.0)** architecture:

```
+===================================================================================================+
|                                    RVV 1.0 ARCHITECTURAL PARAMETERS                               |
+===================================================================================================+
| Parameter                        | Value      | Description                                       |
+----------------------------------+------------+---------------------------------------------------+
| VLEN (Vector Register Length)    | 256 bits   | Length of each vector register v0..v31 in bits    |
| ELEN (Maximum Element Width)     | 64 bits    | Maximum supported element width in bits           |
| Minimum Element Width (SEW_min)  | 8 bits     | Byte-level vector element operations              |
| SLEN (Striping Distance)         | 256 bits   | Equal to VLEN (no striping)                       |
| Supported SEW                    | 8,16,32,64 | 8-bit, 16-bit, 32-bit, 64-bit element widths     |
| Supported LMUL                   | 1/8..8     | Fractional (1/8, 1/4, 1/2) and Multi-register (1..8)|
| Physical Vector Datapath Width   | 128 bits   | Dual 64-bit SIMD execution slices (2 beats/VLEN)  |
| Architectural Vector Registers   | 32 (v0..31)| Standard RVV 1.0 register file                    |
| Physical Vector Registers (VRF)  | 48 entries | 48 x 256-bit banked SRAM array (1.5 KiB total)    |
+===================================================================================================+
```

### 8.1 Vector Register File (VRF) Multi-Banking & Organization
- To support high-throughput SIMD execution without routing gridlock, the 48-entry 256-bit VRF is organized into **4 independent 64-bit banks** per physical register:
  * `Bank 0`: Elements [63:0]
  * `Bank 1`: Elements [127:64]
  * `Bank 2`: Elements [191:128]
  * `Bank 3`: Elements [255:192]
- Each bank is single-ported, enabling concurrent reads and writes across different 64-bit element slices.

### 8.2 Decoupled Vector Issue Queue (`VIQ8`)
- **Capacity**: 8-entry decoupled vector command queue.
- **Micro-op Beat Expansion**: Vector instructions with `LMUL > 1` or operations requiring multiple 128-bit SIMD cycles expand into deterministic multi-beat micro-ops within the vector scheduler.
- **State Machine Registers**:
  * `vtype`: Selected element width (`vsew`), grouping multiplier (`vlmul`), tail agnostic/undisturbed (`vta`), mask agnostic/undisturbed (`vma`).
  * `vl`: Active vector length register (0 to `VLMAX`).
  * `vstart`: Starting element index for interrupt/exception resumption.

### 8.3 Vector Memory Unit (VMU) Contract
1. **Unit-Stride Operations (`VLE8.V`..`VLE64.V`, `VSE8.V`..`VSE64.V`)**:
   - Accesses contiguous memory addresses.
   - Streams 64-byte cache lines directly into the VRF, achieving full L1D line-fill bandwidth.
2. **Strided Operations (`VLSE*.V`, `VSSE*.V`)**:
   - Stride read from scalar integer PRF. Generates individual element addresses dispatched across Dual AGUs.
3. **Indexed (Scatter/Gather) Operations (`VLUXEI*.V`, `VSOXEI*.V`)**:
   - Vector index register supplies address offsets for non-contiguous element gathering and scattering.
4. **Fault-Only-First Loads (`VLE8FF.V`..`VLE64FF.V`)**:
   - Crucial for vector string search and zero-terminated string processing.
   - If an exception occurs on element 0, the CPU takes a precise page/access fault.
   - If an exception occurs on element `i > 0`, the fault is suppressed, active vector length is truncated to `vl = i`, and execution continues cleanly.

---

## 9. Coherence, Privilege Architecture & Context Switching

### 9.1 Context Save / Restore & Status Bits
1. **`mstatus.VS` and `sstatus.VS` (Bits [10:9])**:
   - `2'b00` = **Off**: Any RVV instruction or access to vector CSRs (`vtype`, `vl`, `vstart`, `vxrm`, `vxsat`) raises an **Illegal Instruction Exception** (`mcause = 2`).
   - `2'b01` = **Initial**: Reset clean state.
   - `2'b10` = **Clean**: Context saved and unmodified.
   - `2'b11` = **Dirty**: Modified by active execution.
2. **Lazy Context Switching**:
   - Operating systems utilize `mstatus.FS` and `mstatus.VS` to lazily save and restore floating-point (FPRF + `fcsr`) and vector (VRF + vector CSRs) state only when threads actively utilize the units, avoiding hundreds of save/restore cycles during pure integer execution.

### 9.2 Precise Exceptions & Interrupt Boundaries
- Floating-point arithmetic exceptions (Inexact, Overflow, Underflow, Divide-by-Zero, Invalid) do **NOT** trap by default in RISC-V; they accumulate sticky status flags into `fcsr.fflags`.
- Memory faults (Instruction/Load/Store Page Faults or Access Faults) on FP and Vector memory operations trap with exact program counter `mepc = faulting_instruction_pc`. In-flight speculative FPRF/VRF writebacks are cleanly squashed.

---

## 10. Physical Design, Timing Discipline & Storage Budgets

```
+===================================================================================================+
|                                  PHYSICAL STORAGE BUDGET FOR MILESTONE 8                          |
+===================================================================================================+
| Component                | Organization                          | Total Bits  | Area Equivalent  |
+--------------------------+---------------------------------------+-------------+------------------+
| FPRF Array               | 64 entries x 64 bits (4R3W FF/SRAM)   | 4,096 bits  | ~0.008 mm² (28nm)|
| FRAT (SRAT_FP + ARAT_FP) | 64 entries x 6 bits + 8 Checkpoints   | 768 bits    | ~0.002 mm²       |
| FPIQ16 Issue Queue       | 16 entries x 96-bit payload + CAM     | 1,536 bits  | ~0.004 mm²       |
| Pipelined FMA Unit       | 64-bit IEEE 754 Wallace Tree / Adder  | N/A (Logic) | ~0.035 mm²       |
| Iterative Radix-4 FDIV   | 64-bit SRT Divider/Square-Root Engine | N/A (Logic) | ~0.012 mm²       |
| VRF Banked Storage       | 48 entries x 256 bits (4 banks x 64b) | 12,288 bits | ~0.024 mm²       |
| VIQ8 Vector Queue        | 8 entries x 128-bit command payload   | 1,024 bits  | ~0.003 mm²       |
+--------------------------+---------------------------------------+-------------+------------------+
| TOTAL MILESTONE 8 STORAGE & COMPUTATIONAL ADDITION               | 20,712 bits | ~0.088 mm² (28nm)|
+===================================================================================================+
```

### 10.1 Timing Discipline & Critical Path Isolation
- **No Direct FPRF-to-Integer PRF Combinational Paths**: Move operations between domains (`FMV.X.D`, `FMV.D.X`) buffer through a 1-cycle pipeline register.
- **FMA Pipelining**: Stage boundaries strictly isolate exponent addition/multiplication, significand tree compression, carry-propagate addition, and normalization/rounding to guarantee high frequency closure.

### 10.2 Hardware Performance Telemetry Expansion & CPI Conservation

#### 8-Entry Telemetry Event Specification (0x39 .. 0x40)
Milestone 8 expands the hardware performance monitoring (HPM) subsystem by defining eight dedicated telemetry event sources:

| Event ID | Selector Mnemonic | Description & Trigger Invariant | Pulse Width / Semantics |
|---|---|---|---|
| `0x39` | `EV_FP_ISSUE` | Valid floating-point uop issued from FPIQ16 to Port 4 execution pipelines (FMA, FDIV, FCVT). | 1-cycle pulse per issued uop |
| `0x3A` | `EV_FP_FMA_BUSY` | Active execution cycle where pipelined FMA unit is actively processing in-flight operations. | Level asserted during active FMA compute |
| `0x3B` | `EV_FP_FDIV_STALL` | Stall cycle where FPIQ16 or Port 4 issue stalls due to FDIV/FSQRT unit busy or writeback collision. | Level asserted during FDIV structural stall |
| `0x3C` | `EV_FP_RENAME_STALL` | Backend dispatch stall cycle where rename stalls due to FPRF free list exhaustion or FPIQ16 full. | Level asserted during FP rename stall |
| `0x3D` | `EV_VEC_UOP_COMMIT` | Architectural vector micro-op successfully committed and retired at the ROB head. | Pulse per retired vector micro-op |
| `0x3E` | `EV_VEC_MEM_TRAFFIC` | Vector memory 64-byte line transaction dispatched across the L1D datapath or external MSHRs. | Pulse per 64-byte line request |
| `0x3F` | `EV_VEC_VIQ_FULL` | Frontend dispatch stall cycle where instruction dispatch stalls due to VIQ8 capacity saturation. | Level asserted during VIQ8 backpressure |
| `0x40` | `EV_VEC_FOF_TRUNC` | Vector fault-only-first (`VLEFF`) operation successfully truncating `vl` upon non-zero element fault. | Pulse per fault-only-first truncation |

#### Core Telemetry Event Pulse Bus Widening
To accommodate the expanded event suite:
- The top-level core diagnostic bus `raw_event_pulse_o` is formally widened from `[56:1]` to **`[64:1]`**.
- Bits `raw_event_pulse_o[64:57]` map directly to events `0x40` down to `0x39` in descending numerical order.
- Up to 29 programmable performance counters (`mhpmcounter3`..`31`) configure any event `0x01`..`0x40` via their respective `mhpmevent3`..`31` selector registers.

#### Deterministic Single-Owner CPI Classification Mapping
To maintain the mathematical conservation law without unclassified cycle leakage, all floating-point and vector execution stall states map deterministically into the master 8-category CPI accounting engine:
1. `C_serialize` (Priority 1): Vector CSR serialization (`vsetvli`, `vsetivli`, `vsetvl`), `fcsr` writes, and context sync flushes.
2. `C_br_recover` (Priority 2): Active branch recovery walk (`recovering_o == 1`).
3. `C_productive` (Priority 3): Active architectural commit (`retire_count > 0` covering integer, FP, and vector uops).
4. `C_mem_stall` (Priority 4): ROB head blocked waiting for unresolved scalar FP load (`FLD`/`FLW`) or in-flight vector memory transaction.
5. `C_be_rename` (Priority 5): Rename stalled due to `FL_FP` empty (`FPRF` full), `FPIQ16` full, or `VIQ8` full while instructions wait in FQ16.
6. `C_be_sched` (Priority 6): Ready FP/vector uops stalled waiting for Port 4 availability, FDIV/FSQRT iterative busy, or cross-domain writeback buffer.
7. `C_fe_starve` (Priority 7): FQ16 empty while core is active.
8. `C_idle_other` (Priority 8): Quiescent or unclassified idle cycles.

By construction, these 8 master categories remain strictly mutually exclusive and exhaustive:
`sum_k=0^7 C_k == Δmcycle`
Zero cycle leakage is guaranteed across every simulation cycle.

---

## 11. Verification & Validation Architecture

Milestone 8 verification employs a dual-pillar strategy: formal property verification and differential reference modeling against TestFloat-3 and Spike.

### 11.1 Section 11.1 Properties Traceability Matrix (`PROP_M8_01` .. `PROP_M8_40`)

| Property ID | Subsystem | Formal Verification Scenario & Invariant Description | Phase |
|---|---|---|---|
| `PROP_M8_01` | FPRF Rename | 2-wide FP rename: concurrent allocation of distinct `Pnew_fp` without aliasing. | Phase A |
| `PROP_M8_02` | FRAT RAW | Intra-group FP RAW: `uop1` source receives `uop0.Pnew_fp` in same cycle. | Phase A |
| `PROP_M8_03` | FRAT WAW | Intra-group FP WAW: `uop0` and `uop1` write same `fd`; `uop1` wins in `SRAT_FP`. | Phase A |
| `PROP_M8_04` | Checkpoint | Branch checkpoint snapshots integer SRAT and FRAT simultaneously; restores clean. | Phase A |
| `PROP_M8_05` | FreeList FP | Free List FL_FP empty backpressures dispatch; pops and pushes correctly. | Phase A |
| `PROP_M8_06` | f0 Writeable | `f0` is not hardwired to zero; stores and retrieves arbitrary floating-point values. | Phase A |
| `PROP_M8_07` | mstatus.FS Off | `mstatus.FS == 2'b00`: Any FP uop raises Illegal Instruction trap (`mcause = 2`). | Phase A |
| `PROP_M8_08` | mstatus.FS Dirty| Retirement of FP uop writing FPRF or `fcsr` automatically asserts Dirty state. | Phase A |
| `PROP_M8_09` | fcsr Access | CSR read/write of `fcsr`, `frm`, `fflags` updates flags and respects privilege. | Phase A |
| `PROP_M8_10` | Dynamic frm | Instruction specifying `frm = 3'b111` correctly executes using `fcsr.frm`. | Phase A |
| `PROP_M8_11` | FMA Pipelined | FP64 FMA sustains 1.0 result/cycle throughput across consecutive cycles. | Phase B |
| `PROP_M8_12` | FP32 Latency | FP32 FMA completes in exactly 3 cycles; FP64 FMA completes in exactly 4 cycles. | Phase B |
| `PROP_M8_13` | NaN Boxing | 32-bit FP operation writes result with bits [63:32] set strictly to `32'hFFFFFFFF`. | Phase B |
| `PROP_M8_14` | Unboxed NaN | Reading improperly NaN-boxed register produces canonical quiet NaN. | Phase B |
| `PROP_M8_15` | IEEE Rounding | All 5 rounding modes (RNE, RTZ, RDN, RUP, RMM) match IEEE 754-2008 exactly. | Phase B |
| `PROP_M8_16` | Subnormals | Full subnormal precision arithmetic evaluated without flushing to zero. | Phase B |
| `PROP_M8_17` | FDIV Non-Block | FMA operations execute and complete concurrently while FDIV is computing. | Phase B |
| `PROP_M8_18` | FDIV Exactness | Radix-4 FDIV and FSQRT match TestFloat-3 golden bit-for-bit with exact flags. | Phase B |
| `PROP_M8_19` | Cross FMV | `FMV.X.D` and `FMV.D.X` transfer bits between PRF and FPRF with 0 bit drift. | Phase B |
| `PROP_M8_20` | FP Compare | `FEQ`, `FLT`, `FLE` evaluate comparisons and write 1/0 to integer PRF cleanly. | Phase B |
| `PROP_M8_21` | FP Fwd Exact | SQ forwards 64-bit store data directly to matching `FLD` via CAM search. | Phase C |
| `PROP_M8_22` | FP Fwd Subword| SQ forwards 32-bit store data to `FLW` with exact NaN-boxing application. | Phase C |
| `PROP_M8_23` | Dual FP Load | Concurrent `FLD`/`FLW` on Port 2 and Port 3 write distinct FPRF writeback ports. | Phase C |
| `PROP_M8_24` | FP Spec Replay| Speculative `FLD` matching snooped older store violation triggers ROB replay. | Phase C |
| `PROP_M8_25` | FP Bank Hit | Concurrent FP load and FP store drain hitting different L1D banks hit in 1 cyc. | Phase C |
| `PROP_M8_26` | FP Page Fault | Page fault on `FLD`/`FSD` suppresses FPRF modification and writes precise mepc. | Phase C |
| `PROP_M8_27` | RVV vtype | `vsetvli` instruction updates `vtype` (SEW, LMUL, vta, vma) and `vl` cleanly. | Phase D |
| `PROP_M8_28` | RVV Unit-Stride| `VLE8.V`..`VLE64.V` transfers contiguous memory bytes into VRF without loss. | Phase D |
| `PROP_M8_29` | RVV Strided | `VLSE*.V` computes element addresses using scalar stride register correctly. | Phase D |
| `PROP_M8_30` | RVV Indexed | `VLUXEI*.V` gathers non-contiguous elements using vector index register. | Phase D |
| `PROP_M8_31` | RVV FOF Load | `VLEFF` faulting on element 0 traps; faulting on element >0 sets `vl` without trap.| Phase D |
| `PROP_M8_32` | RVV Masking | Vector arithmetic under mask `v0` updates only active elements per `vma`/`vta`.| Phase D |
| `PROP_M8_33` | RVV Reduction | `VREDSUM` computes tree reduction of vector elements into scalar element. | Phase D |
| `PROP_M8_34` | RVV Permute | `VSLIDEUP`/`VSLIDEDOWN` shifts vector elements across lanes without corruption. | Phase D |
| `PROP_M8_35` | mstatus.VS Off | `mstatus.VS == 2'b00`: Any vector instruction raises Illegal Instruction trap. | Phase D |
| `PROP_M8_36` | mstatus.VS Dirt| Retirement of vector instruction automatically asserts `mstatus.VS = 2'b11`. | Phase D |
| `PROP_M8_37` | HPM FP Events | Events 0x39..0x3C correctly count FP FMA, FDIV, and divider stalls. | Phase E |
| `PROP_M8_38` | HPM Vec Events | Events 0x3D..0x40 correctly monitor vector instructions and memory traffic. | Phase E |
| `PROP_M8_39` | CPI Invariant | Single-owner CPI conservation law holds: sum(C_0..7) == delta(mcycle) exactly. | Phase E |
| `PROP_M8_40` | Bench Clean | Whetstone, SciMark2, and Linpack execute to completion matching Spike output. | Phase E |

---

## 12. Milestone 8 Freeze Gates & Acceptance Criteria

Milestone 8 shall be declared formally **FROZEN** only when all of the following gates are satisfied:

1. **Independent Architecture Review Gate**:
   - Adversarial review returns **P0 = 0, P1 = 0, P2 = 0, P3 = 0** on `slice1-m8-fp-vector-v1.md`.
2. **Production RTL Manifest Gate**:
   - Manifest SHA-256 strictly verified with zero unauthorized file creep.
3. **Predecessor Regression Gate**:
   - 100% clean pass across all predecessor testbenches (Lint, M1 Substrate, M5 B4, M6 Closeout, M7 Closeout, Slice-0 contract).
4. **Section 11.1 Mandatory Properties Gate**:
   - All 40 properties (`PROP_M8_01` through `PROP_M8_40`) pass cleanly in Verilator.
5. **IEEE 754-2008 Compliance Gate**:
   - 1,000,000+ vectors from TestFloat-3 pass with zero bit mismatches across all rounding modes and corner cases (subnormals, NaNs, infinities).
6. **Randomized Stress Torture Gate**:
   - Multi-seed randomized stress testing: `≥ 150,000` operations across canonical seeds (42, 20260920, 20261009) with 0 mismatches against golden C++ reference model and 0 watchdog timeouts.
7. **Telemetry & CPI Conservation Gate**:
   - Zero-leakage verification: `sum_k=0^7 C_k == Δmcycle` verified over every simulation run.
8. **Empirical Benchmarking Gate**:
   - Canonical numerical kernels (Linpack, SciMark2, Whetstone) run to clean completion with measured speedup documented in `results/s1-m8-closeout.json`.
