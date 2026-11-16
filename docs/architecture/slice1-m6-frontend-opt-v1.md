# Fursoy Slice-1 Milestone 6 — Advanced Branch Prediction & Instruction Stream Optimization Architecture Specification

**Document ID:** `docs/architecture/slice1-m6-frontend-opt-v1.md`  
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.1 (Incorporating Independent Architecture Review Remediations — Ready for Freeze)  
**Target Core:** Fursoy Slice-1 (Single-Hart 2-Wide OoO RV64IMAZbaZbb + Sv39)  
**Predecessor Substrates (Frozen):**
- **Milestone 1** (Verified & Frozen): PRF80, ROB48, FreeList48, SRAT/ARAT, 8 Checkpoints, Recovery Substrate.
- **Milestone 2** (Verified & Frozen): PRF Data Storage 64b, IntIQ 16, Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV, Lossless WB.
- **Milestone 3** (Verified & Frozen): MemIQ 12, LQ16, SQ16, Port 2 AGU, L1D 16 KiB 4W, 4 MSHR, 2 WBB, TRT4, PRF 6R3W.
- **Milestone 4** (Verified & Frozen): Decoupled Frontend (F0–D0), FQ12, BTB512 2W, Gshare4096 12b GHR, RAS16, L1I 16 KiB 4W, 2 I-MSHR, ITLB64 4W + 8-entry Superpage CAM, Shared Sv39 PTW, Privileged CSR/System Execution (`satp`, `SFENCE.VMA`, MRET/SRET), `FENCE.I` Clean/Invalidate.
- **Milestone 5** (Verified & Frozen): Integrated Performance, Telemetry & Throughput Optimization (Phase A HPM 48 event sources, up to 29 programmable 64-bit counters, 8-category single-owner CPI decomposition engine; Phase B1 speculative load issue past unresolved stores with LQ CAM snooping & ROB sticky mem_violation & one-shot replay-safe token; Phase B2 FQ16 expansion; Phase B3 MemIQ16 expansion; Phase B4 Oldest-Ready Matrix Scheduling).
**Predecessor Freeze Baseline:**
- Milestone 5 Freeze Commit: `b07e71ec168fb9073c1dff039578ae6ebcecf263`
- Combined Frozen M1+M2+M3+M4+M5 Production RTL Manifest SHA-256 (31 files):  
  `e298467c8eb6476270a21dc2414c7b1afa87697036c37e99ca1c90f7372926fb`
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m4-frontend-v1.md`, `docs/architecture/slice1-m5-performance-v1.md`.

> **Post-Phase-3 RTL Note (`bab4ceb`):** Building on this frozen M6 TAGE-Lite/RAS/NLP contract, production `fursoy_s1_bpu.sv` adds `16` branch checkpoints (`CHKPT_IDX_W = 4`), `INDEXED_RAS_CHKPT = 32` (`slots 1..31`), a `64`-entry tagged Indirect Branch Predictor (`IBP`), commit-time BTB/TAGE/IBP training with periodic 256K u-bit reset, and preservation of `arch_ghr_q`, `arch_csr_q`, and `arch_ras_array_q[16]` across traps and non-branch flushes. See `docs/architecture/slice1-core-v1.md`.

---

## 1. Milestone Objective, Phased Charter & Scope Boundaries

### 1.1 Context & Objective
Milestones 1 through 5 established, verified, and froze a complete, high-performance, 2-wide out-of-order execution core:
- **Milestones 1–3** established the out-of-order substrate, lossless dual-issue integer execution, and out-of-order memory execution with non-blocking caching.
- **Milestone 4** delivered the decoupled instruction supply engine: Stage F0 generation, 64-bit fetch, BTB512, Gshare4096, RAS16, non-blocking 16 KiB L1I with dual I-MSHRs, Sv39 ITLB/PTW, and privileged control.
- **Milestone 5** unlocked sustained microarchitectural throughput by removing backend and memory serialization bottlenecks: speculative load issue past unresolved stores with precise Load Queue CAM hazard detection, FQ16 expansion, MemIQ16 expansion, oldest-ready matrix scheduling, 48 hardware performance event sources, and a single-owner 8-category CPI decomposition engine.

With backend and memory scheduling bottlenecks systematically relieved, empirical baseline characterization under Milestone 5 reveals that **branch mispredictions and instruction stream discontinuities represent the dominant remaining performance barrier** across the core.

As empirically measured in the frozen M5 closeout results (`results/s1-m5-closeout.json`), in the synthetic `branch_torture` profiling workload, the core spends:
- **683 cycles** out of 1,715 total cycles in active branch recovery (`C_br_recover`, 39.8% of runtime) `[MEASURED FURSOY RTL RESULT]`;
- **640 cycles** in post-redirect frontend refill and pipeline fill (`C_idle_other`, 37.3% of runtime) `[MEASURED FURSOY RTL RESULT]`;
- Achieving an IPC of only **0.2624** `[MEASURED FURSOY RTL RESULT]` due to 127 branch direction mispredictions out of 282 dynamic conditional branches (a **45.0% misprediction rate** under 12-bit Gshare4096) `[MEASURED FURSOY RTL RESULT]`.

Across `pointer_chasing`, `stream_memcpy`, and `raw_stress`, branch recovery and frontend refill account for **52.9% to 64.3% of all non-productive cycles** `[MEASURED FURSOY RTL RESULT]`.

Therefore, the objective of **Milestone 6 (M6)** is to deliver an **Advanced Branch Prediction & Instruction Stream Optimization Subsystem** that dramatically cuts branch misprediction frequency, eliminates return address stack corruption, cushions fetch latency via safe next-line prefetching, and maximizes 2-wide decode utilization without expanding core width or destabilizing frozen backend/LSU semantics.

```
+===================================================================================================+
|                                  MILESTONE 6 ARCHITECTURAL CHARTER                                |
+===================================================================================================+

  1. Direction Predictor Evolution:
     Transition from single-table Gshare4096 (12-bit history) to a compact, multi-table Tagged
     Geometric History Length (TAGE-Lite) branch predictor (~3.7 KiB direction state) capturing
     ultra-short (4-bit), medium (12-bit, 36-bit), and long (108-bit) correlation contexts.

  2. RAS Coroutine-Swap & Call-Stack Hardening:
     Upgrade the 16-entry Return Address Stack to support full RISC-V calling convention coroutine
     swap classification (handling x1/x5 linkage register swaps) with non-corrupting checkpointed
     depth and pointer tracking across all 8 M1 branch checkpoints.

  3. Safe Next-Line Instruction Prefetching (NLP):
     Introduce a conservative, VIPT/ITLB/PMP-safe next-line prefetcher utilizing the existing
     secondary I-MSHR slot (MSHR1), strictly bounded to the current 4 KiB virtual page to eliminate
     spurious page faults, and designed with zero-leakage cancellation on FENCE.I / SFENCE.VMA / satp.

  4. Polymorphic Indirect Target Hardening:
     Enhance indirect branch target handling with dedicated polymorphic target classification,
     mitigating indirect jump mispredictions for non-return JALR dispatch.

  5. Telemetry & Single-Owner CPI Decomposition Continuity:
     Map all upgraded frontend events into the 48-event HPM infrastructure while strictly preserving
     the frozen 8-category single-owner CPI conservation law: sum(C_k) == mcycle_delta.
```

### 1.2 In-Scope Architectural Additions
The following microarchitectural features are **explicitly in-scope** for Milestone 6:
1. **TAGE-Lite Direction Predictor**: A 5-table predictor consisting of one bimodal base table (`T_0`) and four tagged geometric history tables (`T_1, T_2, T_3, T_4`) with geometric history lengths `L ∈ {4, 12, 36, 108}`, 3-bit saturating signed counters, 1-bit useful flags, and circular folded history registers (CSRs).
2. **Dual-Branch Fetch Block Evaluation**: Parallel single-cycle evaluation of Slot 0 and Slot 1 conditional branches within each 64-bit fetch block in Stage F2.
3. **Speculative Folded History Checkpointing**: Checkpoint storage and restoration of live GHR and folded history vectors across all 8 M1 speculative branch checkpoints.
4. **Complete RAS Coroutine-Swap Logic**: Hardware decoding of `rd`/`rs1` linkage register permutations (`x1`, `x5`) according to the RISC-V specification, enabling precise coroutine call-stack manipulation without RAS pointer drift.
5. **VIPT-Safe L1I Next-Line Prefetcher (NLP)**: Sequential next-line prefetch request generator utilizing I-MSHR1 during idle periods, enforced by a strict same-page boundary check.
6. **Dead Refill & Abort Pipeline Invariants**: Formalized invalidation of prefetch and demand miss requests upon pipeline flushes, redirects, `FENCE.I`, `SFENCE.VMA`, and `satp` writes, guaranteeing zero pipeline pollution.
7. **HPM Frontend Telemetry Probes**: Integration of TAGE table provider hit tracking, allocation failure tracking, and prefetch efficiency telemetry into the M5 HPM framework.

### 1.3 Strict Out-of-Scope Boundaries (Preserved Baselines)
To maintain project discipline and prevent architectural scope creep, the following are **strictly out-of-scope** for Milestone 6:
- **NO Core Widening**: Decode, Rename, Dispatch, and Commit remain strictly 2-wide.
- **NO Op-Cache / Decoded Stream Buffer**: Decoded instruction caching is deferred to Family C; M6 optimizes L1I instruction stream delivery directly.
- **NO Second AGU / Multi-Port L1D**: AGU remains single-issue on Port 2; L1D remains single-port 16 KiB 4-way (deferred to Milestone 7).
- **NO Backend or LSU Redesign**: Frozen M1 PRF/ROB/FreeList, M2 ALU/MUL/DIV, M3 LSU/LQ/SQ, and M5 B1 speculative load disambiguation contracts are preserved 100% unmodified.
- **NO Compressed Instructions (RVC)**: All instructions remain 32-bit aligned within 64-bit fetch blocks.
- **NO Speculative ITLB Translation for Prefetches**: Prefetches that cross a 4 KiB virtual page boundary are strictly dropped; the hardware page table walker (PTW) is never triggered for speculative prefetches.

---

## 2. Frozen Predecessor Baseline Assumptions & Exact Interface Contracts

Milestone 6 operates as an in-place microarchitectural upgrade to the instruction supply engine. It preserves all architectural contracts, pipeline register mappings, and interface boundaries frozen in Milestones 1 through 5.

### 2.1 Pipeline Stages and Stage Boundaries
The instruction pipeline stages remain strictly organized as follows:

```
+===================================================================================================+
|                                    SLICED FRONTEND PIPELINE STAGES                                 |
+===================================================================================================+

  Stage F0 (GenPC)  : Next-PC generation, deterministic redirect arbitration, PC register update.
  Stage F1 (ReqMem) : Virtual address issue, Sv39 ITLB translation, parallel BPU query dispatch.
  Stage F2 (RspMem) : L1I SRAM tag/data access, BPU TAGE/BTB/RAS evaluation, F2 skid buffer.
  Stage F3 (Align)  : 64-bit fetch block extraction, Slot 0/1 instruction parsing, early JAL check.
  Stage F4 (Queue)  : 16-entry decoupled Fetch Queue FIFO (FQ16, frozen in M5 Phase B2).
  Stage D0 (Decode) : 2-wide parallel instruction decoder, decode exception bypass, replay-safe stamp.
```

### 2.2 Unmodified Predecessor Subsystem Invariants
The following subsystem parameters are frozen and must not be altered by Milestone 6:
1. **Fetch Bandwidth**: Up to 64 bits (two 32-bit instructions) delivered per cycle from L1I / F3 to FQ16.
2. **Fetch Queue Depth**: Exactly 16 entries (`DEPTH = 16`, 4-bit read/write pointers, 5-bit occupancy counters, dual-push admission per M5 Phase B2).
3. **Execution Width**: 2-wide Rename / Dispatch / Commit; 3 Execution Ports:
   - **Port 0**: Integer ALU0 + Branch / Jump Resolution Unit.
   - **Port 1**: Integer ALU1 + Multiplier (3-cycle) + Divider (8–34 cycles).
   - **Port 2**: Address Generation Unit (AGU) for Loads, Stores, and Atomics.
4. **Physical Register File (PRF)**: 80 physical registers (6 read ports, 3 write ports).
5. **Reorder Buffer (ROB)**: 48 entries, circular pointer management, wrap-safe age tracking.
6. **Speculative Branch Checkpoints**: Exactly 8 hardware checkpoints allocated at Rename and reclaimed/restored by Port 0.
7. **Memory Subsystem**: 16-entry MemIQ, 16-entry LQ (retained lifetime), 16-entry SQ, non-blocking 16 KiB 4-way L1D with 4 MSHRs and 2 WBBs.
8. **Translation Architecture**: 64-entry base page + 8-entry superpage ITLB, 32-entry DTLB, shared 3-level Sv39 hardware Page Table Walker (PTW) with 4:1 fairness arbitration.

### 2.3 Authoritative Cross-Subsystem Interfaces
The BPU and Frontend interact with the frozen execution backend via the following authoritative signals (defined in `rtl/core/fursoy_s1_pkg.sv` and `rtl/core/fursoy_s1_frontend.sv`):

```
+===================================================================================================+
|                                AUTHORITATIVE FRONTEND INTERFACES                                  |
+===================================================================================================+

  Backend Resolution & Training (Port 0 EX/WB -> BPU):
    input  logic              recover_valid_i         // Branch misprediction detected at Port 0
    input  chkpt_idx_t        recover_chkpt_id_i      // Allocated checkpoint ID (0..7) to restore
    input  logic              recover_actual_taken_i  // Authoritative branch direction from ALU0
    input  logic [63:0]       recover_target_i        // Computed branch target PC
    input  logic              train_valid_i           // Authoritative branch retirement/commit pulse
    input  logic [63:0]       train_pc_i              // Branch PC
    input  logic              train_actual_taken_i    // Resolved taken direction
    input  logic [63:0]       train_actual_target_i   // Resolved target PC
    input  branch_type_t      train_br_type_i         // COND, JAL, JALR, CALL, RET, IND
    input  ghr_t              train_ghr_i             // Snapshot GHR captured at prediction time

  Checkpoint Allocation (Rename Stage -> BPU):
    input  logic              chkpt_alloc_valid0_i    // Checkpoint allocated for Slot 0 branch
    input  chkpt_idx_t        chkpt_alloc_id0_i       // Checkpoint ID (0..7)
    input  ghr_t              chkpt_alloc_ghr0_i      // Pre-branch GHR snapshot to store in checkpoint
    input  ras_chkpt_t        chkpt_alloc_ras0_i      // RAS logical state snapshot
    input  tage_csr_bundle_t  chkpt_alloc_csr0_i      // Pre-branch folded CSR registers snapshot
    input  logic              chkpt_alloc_valid1_i    // Checkpoint allocated for Slot 1 branch
    input  chkpt_idx_t        chkpt_alloc_id1_i       // Checkpoint ID (0..7)
    input  ghr_t              chkpt_alloc_ghr1_i      // Pre-branch GHR snapshot
    input  ras_chkpt_t        chkpt_alloc_ras1_i      // RAS logical state snapshot
    input  tage_csr_bundle_t  chkpt_alloc_csr1_i      // Pre-branch folded CSR registers snapshot

  Stage F3 Early JAL Correction (Align Stage -> F0/BPU):
    logic                     early_jal_redirect      // Unpredicted direct JAL discovered in F3
    logic [63:0]              early_jal_target        // Target PC (PC + imm)
    ghr_t                     early_jal_restore_ghr   // Clean pre-branch GHR restored to BPU
    ras_chkpt_t               early_jal_restore_ras   // Clean pre-branch RAS restored to BPU
    tage_csr_bundle_t         early_jal_restore_csr   // Clean folded history registers (Index, TagA, TagB for T1..T4)

  Dispatch Handoff (D0 -> Rename):
    output logic              uop0_valid_o
    output uop_decoded_t      uop0_o                  // Includes br_type, pred_taken, pred_target
    output ghr_t              uop0_pre_ghr_o          // Passed to Rename for checkpoint capture
    output ras_chkpt_t        uop0_ras_chkpt_o        // Passed to Rename for checkpoint capture
    output tage_csr_bundle_t  uop0_csr_chkpt_o        // Passed to Rename for checkpoint capture
    output logic              uop1_valid_o
    output uop_decoded_t      uop1_o
    output ghr_t              uop1_pre_ghr_o
    output ras_chkpt_t        uop1_ras_chkpt_o
    output tage_csr_bundle_t  uop1_csr_chkpt_o
```

---

## 3. Empirical Frontend & Branch Bottleneck Audit

### 3.1 Empirical Evidence from Milestone 5 Profiling Baseline
Under Milestone 5, the core's microarchitectural behavior was empirically profiled across five canonical microarchitectural workloads (`results/s1-m5-closeout.json` and `results/s1-m5-b4.json`). The cycle breakdown across the 8 single-owner CPI categories provides rigorous empirical evidence of frontend and branch bottlenecks:

| Profiling Workload | Total Cycles | Retired Inst | IPC | `C_serialize` | `C_br_recover` | `C_productive` | `C_mem_stall` | `C_be_rename` | `C_be_sched` | `C_fe_starve` | `C_idle_other` |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Branch Torture** | **1,715** | 450 | **0.2624** | 0 | **683** (39.8%) | 258 (15.0%) | 0 | 127 (7.4%) | 0 | 4 (0.2%) | **643** (37.5%) |
| **Pointer Chasing**| **789** | 193 | **0.2446** | 0 | **318** (40.3%) | 66 (8.4%) | 133 (16.9%) | 79 (10.0%) | 1 (0.1%) | 3 (0.4%) | **189** (24.0%) |
| **Stream Memcpy**  | **467** | 194 | **0.4154** | 0 | **157** (33.6%) | 98 (21.0%) | 75 (16.1%) | 44 (9.4%) | 0 | 3 (0.6%) | **90** (19.3%) |
| **Int Dependency** | **1,753** | 257 | **0.1466** | 0 | 70 (4.0%) | 196 (11.2%) | 0 | 1,171 (66.8%) | 239 (13.6%)| 3 (0.2%) | 74 (4.2%) |
| **RAW Stress**     | **434** | 162 | **0.3733** | 0 | **156** (35.9%) | 98 (22.6%) | 31 (7.1%) | 48 (11.1%) | 0 | 3 (0.7%) | **98** (22.6%) |

*All metrics tagged as `[MEASURED FURSOY RTL RESULT]` from `results/s1-m5-closeout.json`.*

### 3.2 Root-Cause Diagnosis of Frontend Stall Modes
Analysis of the hardware performance telemetry reveals four critical structural root causes:

1. **Catastrophic Branch Recovery Penalty (`C_br_recover`)**:
   - In `branch_torture`, `C_br_recover` consumes **683 cycles** `[MEASURED FURSOY RTL RESULT]`.
   - Event `0x0E` (`EV_BPU_DIR_MISPRED`) records **127 mispredictions** out of 282 branches `[MEASURED FURSOY RTL RESULT]`.
   - Each misprediction requires an average of `683 / 127 = 5.38` cycles of active backward ROB register reclamation `[MEASURED FURSOY RTL RESULT]`.
   - Gshare4096 is fundamentally limited: its 12-bit global history register (`2^12 = 4096` entries) cannot differentiate complex alternating patterns, loops with variable exit conditions, or nested calling contexts `[DESIGN HYPOTHESIS]`. Severe destructive aliasing in the 4096-entry PHT prevents learning distinct branch behaviors `[DESIGN HYPOTHESIS]`.

2. **Severe Post-Redirect Pipeline Refill Overhead (`C_idle_other`)**:
   - Following each branch recovery redirect, the pipeline is completely flushed. The core spends **640 to 643 cycles** in `C_idle_other` during `branch_torture` `[MEASURED FURSOY RTL RESULT]`.
   - The minimum redirect penalty from Stage F0 generation through L1I access, alignment, FQ16 enqueue, 2-wide decode, rename, issue, and execution is **9 cycles** `[ANALYTICAL STRUCTURAL BOUND]`.
   - When combined, branch misprediction recovery (`C_br_recover` = 683) and recovery-induced frontend refill bubbles (`C_idle_other` = 643) account for **1,326 cycles out of 1,715 total execution cycles (77.3% of runtime)** `[MEASURED FURSOY RTL RESULT]`. Eliminating branch mispredictions is mathematically the single highest-leverage optimization available for Fursoy Slice-1 `[DESIGN HYPOTHESIS]`.

3. **Return Address Stack Pointer Drift on Coroutine Swaps**:
   - In M4, the RAS decoder classified `JALR` with `rd ∈ {x1, x5}` as a CALL and `rd = x0 && rs1 ∈ {x1, x5}` as a RET `[ANALYTICAL STRUCTURAL BOUND]`.
   - However, compiler-generated coroutine context switching (e.g., in user-level thread libraries or runtime schedulers) executes `jalr x1, 0(x5)` where both `rd` and `rs1` are link registers. In M4, this popped the RAS or pushed without popping, causing the RAS top-of-stack pointer to drift `[ANALYTICAL STRUCTURAL BOUND]`. Subsequent returns experienced 100% mispredictions `[DESIGN HYPOTHESIS]`.

4. **Sequential Instruction Stream Bubbles & Straight-Line L1I Latency**:
   - In `stream_memcpy` and `pointer_chasing`, straight-line instruction fetch regularly encounters cold or capacity cache line transitions. While the core has dual I-MSHRs, MSHR1 remains completely idle during sequential execution `[MEASURED FURSOY RTL RESULT]`.
   - Introducing conservative, non-blocking next-line prefetching cushions cache-line transition latency and ensures the 16-entry Fetch Queue (FQ16) remains populated with instructions `[DESIGN HYPOTHESIS]`.

---

## 4. Phased Implementation Structure & Rejected/Deferred Mechanisms

Milestone 6 is formally organized into four sequential, auditable implementation phases:

```
+===================================================================================================+
|                                   MILESTONE 6 PHASED STRUCTURE                                    |
+===================================================================================================+

  PHASE A: Tagged Geometric History Length (TAGE-Lite) Direction Predictor
  -------------------------------------------------------------------------------------------------
  - Replace Gshare4096 PHT with 5-table TAGE-Lite architecture (T0 bimodal base + T1..T4 tagged).
  - Geometrically spaced global history lengths: L in {4, 12, 36, 108}.
  - Folded history registers (CSRs) for tag and index generation.
  - Dual-slot parallel prediction in Stage F2.
  - Checkpoint storage and restoration of live GHR and folded history vectors.

  PHASE B: Return Address Stack (RAS) Hardening & Indirect Target Handling
  -------------------------------------------------------------------------------------------------
  - Full RISC-V linkage convention coroutine-swap classification (x1/x5 permutations).
  - Checkpointed RAS top-of-stack pointer and depth tracking across all 8 M1 branch checkpoints.
  - Polymorphic indirect target classification and indirect jump misprediction mitigation.

  PHASE C: Instruction Stream & Fetch Continuity (Next-Line Prefetching & L1I)
  -------------------------------------------------------------------------------------------------
  - Safe Next-Line Prefetcher (NLP) utilizing idle I-MSHR1 slot for sequential line prefetching.
  - Strict 4 KiB virtual page boundary check (prefetches never cross page boundaries).
  - Silent abort on page boundary; zero speculative page faults or PMP access faults.
  - Dead refill suppression and flash cancellation on FENCE.I / SFENCE.VMA / satp writes.

  PHASE D: Telemetry, Verification & Empirical Bottleneck Characterization
  -------------------------------------------------------------------------------------------------
  - HPM telemetry integration for TAGE provider hit distribution and prefetch efficiency.
  - Strict validation of 8-category single-owner CPI conservation law: sum(C_k) == mcycle_delta.
  - Full regression across all predecessor milestone testbenches (M1..M5).
```

### 4.1 Explicitly Rejected and Deferred Mechanisms
The following candidate mechanisms were rigorously evaluated and **rejected or deferred**:
1. **Multi-Megabyte Neural / Perceptron Predictors (REJECTED)**:
   - *Technical Rationale*: Perceptron predictors require wide dot-product arithmetic (MAC units), multi-bit weight tables (`> 32 KiB`), and high power consumption `[DESIGN HYPOTHESIS]`. TAGE achieves equal or superior accuracy under strict area budgets (`< 4 KiB`) using simple integer addition and XOR hashing `[ANALYTICAL STRUCTURAL BOUND]`.
2. **Aggressive Multi-Path / Next-Page Prefetching (REJECTED)**:
   - *Technical Rationale*: Prefetching beyond the current 4 KiB page requires speculative hardware page table walks (PTW). In a shared PTW architecture (where DTLB and ITLB share walker resources), speculative prefetch page walks would contend with demand D-cache misses, degrading memory throughput `[DESIGN HYPOTHESIS]`. Speculative page faults could also violate architectural isolation `[ANALYTICAL STRUCTURAL BOUND]`.
3. **Decoded Op-Cache / Loop Stream Buffer (DEFERRED to Family C)**:
   - *Technical Rationale*: An Op-Cache requires complex multi-ported SRAM arrays, instruction boundary tagging, and dual-source rename multiplexing. M5 Phase B2 already expanded the Fetch Queue to 16 entries (FQ16), which provides up to 8 cycles of 2-wide decode buffering `[ANALYTICAL STRUCTURAL BOUND]`. An Op-Cache would destabilize the frozen frontend/rename interface.
4. **Wider Frontend (3-Wide or 4-Wide Decode) (REJECTED)**:
   - *Technical Rationale*: Core width is frozen at 2-wide decode / rename / dispatch / commit. Core widening causes an `O(W^2)` explosion in rename dependency comparators and PRF read ports `[ANALYTICAL STRUCTURAL BOUND]`.

---

## 5. Tagged Geometric History Predictor (TAGE-Lite) Microarchitecture Contract (Phase A)

### 5.1 Architectural Principle
The Tagged Geometric History Length (TAGE) predictor is the industry standard for high-accuracy branch direction prediction. It operates on the principle that branch predictability is distributed across different history lengths:
- **Short histories** capture local loop iterations and adjacent branch correlations;
- **Medium histories** capture function call arguments and structured if-then-else nesting;
- **Long histories** capture path-dependent context and phase-dependent execution states.

TAGE employs a **bimodal base predictor** (`T_0`) to provide default predictions for branches with low history dependence, complemented by multiple **tagged tables** (`T_1, T_2, T_3, T_4`) indexed by geometrically increasing global history lengths.

```
+===================================================================================================+
|                                  TAGE-LITE PREDICTOR ARCHITECTURE                                 |
+===================================================================================================+

                      Fetch PC [63:3]  +  Live GHR [107:0]
                            |                      |
                            +-----------+----------+
                                        |
       +-----------------+--------------+--------------+-----------------+
       |                 |              |              |                 |
       v                 v              v              v                 v
   +-------+         +-------+      +-------+      +-------+         +-------+
   |  T0   |         |  T1   |      |  T2   |      |  T3   |         |  T4   |
   | Base  |         | Tagged|      | Tagged|      | Tagged|         | Tagged|
   | Table |         | L1=4b |      | L2=12b|      | L3=36b|         | L4=108|
   +-------+         +-------+      +-------+      +-------+         +-------+
   2048x2b           512x12b        512x12b        512x13b           512x14b
       |                 |              |              |                 |
     (pred)           (match?)       (match?)       (match?)          (match?)
       |                 |              |              |                 |
       +-----------------+--------------+--------------+-----------------+
                                        |
                                        v
                       [ Provider Selection & Altpred Logic ]
                                        |
                                        v
                              Final Direction Prediction
```

### 5.2 Geometric History Spacing & Table Geometry
Milestone 6 defines a **5-table TAGE-Lite configuration** optimized for high accuracy under an ultra-compact storage budget:

`α = 3.0, L_1 = 4, L_2 = 12, L_3 = 36, L_4 = 108`

| Predictor Table | History Length (`L_i`) | Number of Entries | Index Width | Tag Width | Counter Width (`ctr`) | Useful Width (`u`) | Entry Width | Total Storage |
|---|---|---|---|---|---|---|---|---|
| **`T_0` (Base)** | 0 bits | 2,048 | 11 bits | None | 2 bits (bimodal) | None | 2 bits | 4,096 bits (512 B) |
| **`T_1` (Tagged)**| 4 bits | 512 | 9 bits | 8 bits | 3 bits (signed) | 1 bit | 12 bits | 6,144 bits (768 B) |
| **`T_2` (Tagged)**| 12 bits | 512 | 9 bits | 8 bits | 3 bits (signed) | 1 bit | 12 bits | 6,144 bits (768 B) |
| **`T_3` (Tagged)**| 36 bits | 512 | 9 bits | 9 bits | 3 bits (signed) | 1 bit | 13 bits | 6,656 bits (832 B) |
| **`T_4` (Tagged)**| 108 bits| 512 | 9 bits | 10 bits | 3 bits (signed) | 1 bit | 14 bits | 7,168 bits (896 B) |
| **TOTALS** | — | **4,096 entries** | — | — | — | — | — | **30,208 bits (3.69 KiB)** |

*All parameters tagged as `[ANALYTICAL STRUCTURAL BOUND]`.*

### 5.3 Folded History (CSR) Circular Hashing
Directly computing an XOR reduction over 108 bits of history on every cycle would create an intolerable combinational delay in Stage F2. Milestone 6 mandates the use of **Circular Shift Registers (CSRs)** for folded history tracking:

A folded history of length `L` compressed into `k` bits satisfies:

`CSR[k-1:0] = XOR_i=0^ceil( L / k ) - 1 GHR[i · k +: k]`

On each conditional branch with outcome `b ∈ {0, 1}`, the CSR updates incrementally in a single clock cycle with zero ripple delay using circular 1-bit left-rotation (`ROL_1`):

`CSR_next = ROL_1(CSR_curr, k) ^ b ^ (GHR[L] << (L mod k))`

In synthesizable SystemVerilog, the circular rotation is expressed by rotating bit `k-1` into bit 0, guaranteeing that no historical correlation entropy is dropped:

```systemverilog
// Exact 1-cycle circular bit-rotation update for folded history register of width k:
CSR_next = {CSR_curr[k-2:0], CSR_curr[k-1]} ^ {{(k-1){1'b0}}, b} ^ (GHR[L] << (L % k));
```

#### Exact Parametrization of Folded Registers Across Tables `T_1..T_4`
To ensure 100% bit-exact equivalence between the synthesizable RTL and the independent C++ verification reference model, each tagged table `T_i` maintains three dedicated circular folded history registers:
1. **`CSR_Index_i`**: Compresses full table history `L_i` into index width `k_idx = 9` bits.
2. **`CSR_TagA_i`**: Compresses full table history `L_TagA = L_i` into tag width `k_tag ∈ {8, 8, 9, 10}` bits.
3. **`CSR_TagB_i`**: Compresses secondary/geometric half-length history `L_TagB = floor( L_i / 2 )` into tag width `k_tag ∈ {8, 8, 9, 10}` bits.

The exact geometric history lengths, bit widths, and folding parameters are formalized below:

| Table | History Length (`L_i`) | Index Width (`k_idx`) | Tag Width (`k_tag`) | TagA History (`L_TagA`) | TagB History (`L_TagB`) | Tag Hash Equation |
|---|---|---|---|---|---|---|
| **`T_1`** | 4 bits | 9 bits | 8 bits | 4 bits | 2 bits | `PC[19:12] ^ CSR_TagA_1 ^ (CSR_TagB_1 << 1)` |
| **`T_2`** | 12 bits | 9 bits | 8 bits | 12 bits | 6 bits | `PC[19:12] ^ CSR_TagA_2 ^ (CSR_TagB_2 << 1)` |
| **`T_3`** | 36 bits | 9 bits | 9 bits | 36 bits | 18 bits | `PC[20:12] ^ CSR_TagA_3 ^ (CSR_TagB_3 << 1)` |
| **`T_4`** | 108 bits | 9 bits | 10 bits | 108 bits | 54 bits | `PC[21:12] ^ CSR_TagA_4 ^ (CSR_TagB_4 << 1)` |

*Note on Index Hashing*: For all tagged tables `T_1..T_4`, the 9-bit index is computed as:
`Index_i = PC[11:3] ^ CSR_Index_i ^ (CSR_Index_i >> 5)`

### 5.4 Dual-Slot Prediction Arbitration in Stage F2
Because Fursoy fetches 64-bit blocks containing up to two instructions (Slot 0 at `PC[2]=0` and Slot 1 at `PC[2]=1`), Stage F2 performs parallel lookup:
1. **Slot 0 Prediction**: Evaluates `T_0..T_4` using the block base PC (`fetch_pc[63:3]`) and the live GHR (`GHR[107:0]`).
2. **Slot 1 Prediction**: Evaluates `T_0..T_4` using Slot 1 PC (`fetch_pc[63:3] | 3'b100`) subject to Slot 0 control-flow classification:
   - **Slot 0 is NOT a conditional branch** (e.g. integer ALU, load, store, CSR, JAL): Slot 1 MUST evaluate using the **unmodified live GHR** (`GHR[107:0]`). Non-branch instructions do NOT mutate or shift GHR under any circumstances.
   - **Slot 0 is a conditional branch predicted NOT taken**: Slot 1 evaluates using the speculative carry outcome `{GHR[106:0], 1'b0}` and correspondingly carried folded CSRs.
   - **Slot 0 is a conditional branch predicted taken**: Slot 1 evaluation is suppressed and ignored, as the Slot 0 redirect takes immediate priority in Stage F0.

### 5.5 Provider Selection and Alternate Prediction (`altpred`)
For a given branch query:
1. **Tag Match**: Each tagged table `T_1..T_4` compares its stored tag against `Tag_i`.
2. **Provider Table (`T_prov`)**: The matching tagged table with the **longest history length** is designated the **provider**.
3. **Alternate Predictor (`T_alt`)**: The matching table with the next-longest history length (or `T_0` if no other tagged table matches) is designated the **alternate predictor**.
4. **Final Prediction Decision**:
   - If no tagged table matches, the prediction is provided by `T_0` (Base table: 2-bit counter `≥ 2` means Taken).
   - If a tagged table matches, the provider's 3-bit counter (`ctr ∈ [-4, +3]` or `[0, 7]`) determines the prediction:
     - If `ctr ≥ 4`, predict **Taken**; if `ctr ≤ 3`, predict **Not Taken**.
     - *Weak Provider Exception*: If the provider counter is newly allocated and weak (`ctr ∈ {3, 4}`) and the useful bit is zero (`u = 0`), the selector falls back to `T_alt` to prevent nascent mispredictions.

### 5.6 Predictor Training, Allocation & Useful-Bit Aging
When a conditional branch resolves at Port 0 execution/writeback (`train_valid_i` asserted):
1. **Provider Update**:
   - The provider counter `T_prov.ctr` increments on taken, decrements on not taken (saturating at 0 and 7).
   - If the provider prediction differed from the alternate prediction (`pred_prov ≠ pred_alt`), the useful bit is updated:
     - Set `T_prov.u ← 1` if provider was correct;
     - Set `T_prov.u ← 0` if provider was incorrect.
2. **Deterministic Single-Table Allocation on Misprediction**:
   - If the final branch prediction was incorrect, the hardware attempts to allocate into **at most ONE** eligible table with `u == 0`.
   - Hardware enforces strict deterministic priority by selecting the **smallest eligible history table** (`T_j` with minimal `L_j > L_prov`) whose entry at index `Index_j` currently has `u == 0`.
   - If an eligible table is found: exactly that single entry is initialized (`Tag ← Tag_j`, `ctr ← weak` [3 for not taken, 4 for taken], `u ← 0`). No subsequent or longer history tables are allocated.
   - If **all** eligible tables with `L_j > L_prov` have `u == 1`: no new entry is allocated anywhere, and the useful bits of the indexed entries in all eligible tables (`L_j > L_prov`) are decremented (`u ← 0`) to age out established entries and prevent allocation deadlocks.
3. **Graceful Useful-Bit Decay / Reset State Machine**:
   - A 19-bit global counter tracks branch retirements. Every 256K retired branches, all useful bits across `T_1..T_4` are cleared to zero (`u ← 0`), allowing stale patterns to be reclaimed gracefully.

---

## 6. Speculative History, RAS Coroutine-Swap & Checkpoint Recovery Contract (Phase B)

### 6.1 Speculative History & Checkpoint Recovery Invariant
Fursoy Slice-1 uses an 8-entry hardware checkpoint array (`NUM_CHECKPOINTS = 8`) allocated at Rename for in-flight speculative branches.

> **Speculative History Invariant**: Every conditional branch allocated at Rename captures an exact snapshot of:
> 1. The 108-bit live Global History Register (`ghr_t`);
> 2. The complete folded history circular shift register bundle (`CSR_Index_1..4`, `CSR_TagA_1..4`, `CSR_TagB_1..4`);
> 3. The 16-entry Return Address Stack logical state (`ras_chkpt_t`).

When Port 0 detects a branch misprediction (`recover_valid_i` asserted):
1. The BPU restores the exact pre-branch GHR from `chkpt_ghr_table[recover_chkpt_id_i]`;
2. The GHR shifts in the **actual resolved branch direction** (`recover_actual_taken_i`):
   `GHR_restored = {chkpt_ghr[106:0], recover_actual_taken_i}`
3. All folded history registers (`CSR_Index_i`, `CSR_TagA_i`, `CSR_TagB_i` for tables `T_1..T_4`) are **restored directly from checkpoint storage** (`chkpt_csr_table[recover_chkpt_id_i]`) in a single cycle and updated with the resolved branch direction (`recover_actual_taken_i`) via the single-cycle circular rotation formula. This completely eliminates combinational XOR reconstruction trees from the 108-bit GHR on the critical mispredict redirect path;
4. The RAS array, top-of-stack pointer, and depth counter are restored from `chkpt_ras_table[recover_chkpt_id_i]`.

This guarantees **zero history drift or corrupt state** across arbitrary sequences of speculative branch mispredictions.

### 6.2 Frontend-Local Unrenamed Branch Squashes
The frontend contains four internal redirect paths for instructions that have not yet reached Rename (and therefore possess no M1 checkpoint ID):
1. **Stage F3 Early JAL Correction**: An unpredicted direct `JAL` is decoded in F3. F3 asserts `early_jal_redirect` to F0 and provides `early_jal_restore_ghr`, `early_jal_restore_ras`, and `early_jal_restore_csr[4:1]` (the complete set of folded history registers captured prior to the F3 JAL block). This restores GHR, RAS, and all folded CSR registers in Stage F2 in a single clock cycle, completely preventing folded history drift on direct jump early corrections.
2. **Stage F2 BTB Target Redirect**: A branch predicted taken redirects F0 immediately.
3. **Stage D0 Invalid Opcode Squash**: If D0 encounters a fetch exception or invalid instruction, downstream dispatch is suppressed.
4. **Skid Buffer Purge**: On any upstream redirect, in-flight skid buffers are invalidated without modifying persistent predictor counters.

### 6.3 Complete RISC-V Return Address Stack (RAS) Coroutine-Swap Contract
Milestone 6 formally addresses the deferred P2 coroutine-swap classification. Under the RISC-V calling convention (Section 2.5 of the RISC-V Unprivileged Specification), the architectural registers `x1` and `x5` are designated as link registers. A `JALR` instruction manipulates the RAS according to the following strict 5-case decode matrix:

| Case | Instruction Pattern | Link Register Condition | RAS Action | Operational Rationale |
|---|---|---|---|---|
| **1** | `JALR rd, rs1, imm` | `rd ∉ {x1, x5} && rs1 ∉ {x1, x5}` | **None** | Standard indirect jump (function pointer, switch table). |
| **2** | `JALR rd, rs1, imm` | `rd ∈ {x1, x5} && rs1 ∉ {x1, x5}` | **PUSH (`PC+4`)** | Indirect function call (`CALL`). Return address saved. |
| **3** | `JALR rd, rs1, imm` | `rd ∉ {x1, x5} && rs1 ∈ {x1, x5}` | **POP** | Standard function return (`RET`) or stack unwind. Restores return target. |
| **4** | `JALR rd, rs1, imm` | `rd ∈ {x1, x5} && rs1 ∈ {x1, x5} && rd ≠ rs1` | **POP then PUSH (`PC+4`)** | **Coroutine Swap**: Pops caller return address and pushes new return address. |
| **5** | `JALR rd, rs1, imm` | `rd ∈ {x1, x5} && rs1 ∈ {x1, x5} && rd = rs1` | **PUSH (`PC+4`)** | Coroutine link re-use; push return address only (no pop). |

*All conditions tagged as `[ANALYTICAL STRUCTURAL BOUND]`.*

```
+===================================================================================================+
|                                    RAS COROUTINE SWAP DATAPATH                                    |
+===================================================================================================+

    TOS Pointer (4-bit) --------------------+
                                            |
    Case 3 (POP)           :  TOS <= TOS - 1;  Depth <= max(0, Depth - 1);
    Case 2/5 (PUSH)        :  TOS <= TOS + 1;  Array[TOS + 1] <= PC + 4; Depth <= min(16, Depth + 1);
    Case 4 (COROUTINE SWAP):  Array[TOS]     <= PC + 4;  // Overwrites TOS in-place!
                              TOS <= TOS;      Depth <= Depth; // Zero pointer drift!
```

By performing an **in-place overwrite of the top-of-stack entry on Coroutine Swaps (Case 4)**, the TOS pointer and stack depth experience zero drift, completely preventing stack exhaustion or corruption during coroutine execution.

### 6.4 Polymorphic Indirect Target Hardening
For indirect non-return jumps (`JALR` with `rd = x0 && rs1 ∉ {x1, x5}`):
- Milestone 6 retains the 512-entry 2-way BTB for primary indirect target caching.
- To prevent polymorphic indirect call-sites (e.g., C++ virtual table dispatches) from thrashing BTB entries, the BTB update policy is augmented: if an indirect jump updates a matching set with a new target, the entry is updated only if the target differs from the current prediction, preserving stable direct jump entries.

---

## 7. Instruction Stream Prefetch & L1I Continuity Contract (Phase C)

### 7.1 Objective & Latency Cushioning
In sequential integer code, instruction streams frequently transition across 64-byte cache lines. Under Milestone 4, every cache line miss incurs an external memory refill latency, idling the pipeline for multiple cycles. Milestone 6 introduces a **conservative, VIPT-safe Level-1 Instruction Cache Next-Line Prefetcher (NLP)** to pre-warm cache lines during sequential execution.

### 7.2 Safe Next-Line Prefetcher (NLP) Architecture & Dual-MSHR Arbitration
Milestone 4 provided dual Instruction MSHRs (`IMSHR_DEPTH = 2`: MSHR0 and MSHR1). In Milestone 6, these MSHR slots are arbitrated with strict demand prioritization:
1. **MSHR0 Priority**: MSHR0 is strictly dedicated to **demand fetch misses** from Stage F1/F2.
2. **MSHR1 Conditional Prefetch Allocation**: MSHR1 is permitted to issue an external memory prefetch for the next sequential cache line (`LineAddr + 1`) if and only if **ALL** of the following conditions hold combinationally:
   - MSHR1 is currently idle (`!imshr_q[1].valid`);
   - MSHR0 is either idle or its demand bus request has already been granted;
   - The downstream Fetch Queue is not backpressured (`fq_free_count >= 2`);
   - The prefetch address is confirmed to **reside within the same 4 KiB virtual page**;
   - The prefetch address is not already present in L1I (tag probe indicates cache miss);
   - No pipeline flush, redirect, or system serialization is pending.
3. **Demand Miss Collision with In-Flight Prefetch (MSHR Merge & Promotion)**:
   - If a demand instruction fetch miss from Stage F1/F2 targets a cache line currently being fetched by an in-flight MSHR1 prefetch (`demand_line_addr == imshr_q[1].line_addr && imshr_q[1].valid`):
     * Hardware **MUST NOT** allocate a redundant external bus transaction or stall the core awaiting an independent request.
     * The demand fetch **merges into MSHR1**: MSHR1 is immediately promoted from a speculative prefetch to an authoritative demand miss.
     * The prefetch pipeline-suppression flag (`suppress_pipeline_push`) is cleared to zero (`suppress_pipeline_push <= 1'b0`).
     * MSHR1 sets its waiter valid bit (`waiter_valid <= 1'b1`) and captures the demand request metadata (target Fetch Queue entry / skid buffer ID).
     * Upon external bus data arrival, the cache line is installed into the L1I cache array and simultaneously bypassed directly to Stage F3 / Fetch Queue without pipeline bubble or redundant memory bus traffic.

```
+===================================================================================================+
|                                  SAFE NEXT-LINE PREFETCHER FLOW                                   |
+===================================================================================================+

    Demand Access at Line N (PA[55:6])
               |
               v
    [ Page Boundary Check: PA[11:6] == 6'b111111 ? ]
               |
        +------+------+
        |             |
     (YES)           (NO)
        |             |
        v             v
    [ DROP ]    [ Check MSHR1 Idle & L1I Tag Miss ]
    Silent            |
    Abort       +-----+-----+
                |           |
             (FAIL)      (PASS)
                |           |
                v           v
             [ DROP ]   [ Allocate MSHR1 & Issue Bus Read (Line N+1) ]
                            |
                            v
                        [ Line Returns from Interconnect ]
                            |
                        [ Install into L1I Cache Array ]
                        (Suppress Pipeline Push; Zero Bubble)
```

### 7.3 Page-Boundary Crossing Invariant & VIPT/ITLB/PMP Safety
> **Page-Boundary Crossing Invariant**: The Next-Line Prefetcher **MUST NEVER** issue a prefetch request across a 4 KiB virtual page boundary:
> `Prefetch_Allowed <=> Demand_PA[11:6] ≠ 6'b111111`

- **Technical Rationale**: In an Sv39 virtual memory system, the next sequential 4 KiB page may be unmapped, execute-protected, or mapped to a disparate physical page. A prefetch crossing the page boundary would require an ITLB lookup and could trigger an unauthorized page fault or PMP access violation.
- **Silent Abort**: When a demand fetch accesses line 63 of a 4 KiB page (`PA[11:6] == 6'b111111`), the prefetcher silently aborts with zero side effects. No ITLB query, PTW translation, or bus request is initiated.
- **Zero Fault Rule**: Prefetches never generate synchronous CPU exceptions (Cause 1, Cause 12). If an external memory read error occurs on a prefetch, MSHR1 deallocates silently without raising a trap.

### 7.4 Cancellation, Invalidation & Serialization Contracts
The prefetcher is strictly integrated into Fursoy's coherence and serialization protocols:
1. **Pipeline Flush / Branch Mispredict**: When `redirect_flush_i` asserts, MSHR1 clears its `waiter_valid` flag. When the bus response returns, data installs into the L1I array to warm the cache, but is **suppressed from delivery to Stage F3** (dead refill suppression).
2. **`FENCE.I` System Serialization**: When `l1i_inval_all_i` asserts, both I-MSHRs are immediately purged, and all L1I tags are flash-invalidated. Any in-flight prefetch bus response returning after `FENCE.I` is discarded.
3. **`SFENCE.VMA` and `satp` Writes**: An address translation flush purges prefetch tracking immediately, ensuring stale virtual-to-physical mappings never populate the cache.

---

## 8. HPM Telemetry, Predictor Accuracy Metrics & CPI Decomposition Continuity (Phase D)

Milestone 6 preserves 100% of the 48 hardware performance event sources (`0x01`..`0x30`) frozen in Milestone 5. Upgraded frontend mechanisms are directly mapped into the existing telemetry matrix:

### 8.1 Upgraded Mapping of Milestone 5 Events

| Event ID | Symbolic Name | Architectural Meaning in Milestone 6 | Qualification / Timing Point |
|---|---|---|---|
| `0x0B` | `EV_BTB_QUERIES` | Total control-flow instructions queried against BPU (BTB + TAGE) | Stage F2 Query |
| `0x0C` | `EV_BTB_HITS` | Control-flow instructions matching valid BTB entry | Stage F2 Match |
| `0x0D` | `EV_BPU_COND_PRED`| Conditional branches evaluated by TAGE-Lite predictor | Stage F2 Evaluation |
| `0x0E` | `EV_BPU_DIR_MISPRED`| Conditional branch direction mispredictions resolved at Port 0 | Precise at Port 0 EX/WB |
| `0x0F` | `EV_BPU_TGT_MISPRED`| Indirect jump / JALR target mispredictions resolved at Port 0 | Precise at Port 0 EX/WB |
| `0x10` | `EV_RAS_CALL_PUSH` | Return addresses pushed to RAS (including Coroutine Swap Case 4) | Stage D0 / Stage F2 |
| `0x11` | `EV_RAS_RET_POP` | Return addresses popped from RAS (including Coroutine Swap Case 4) | Stage F2 Evaluation |
| `0x12` | `EV_RAS_RET_MISPRED`| Return instructions whose RAS predicted target mismatched Port 0 | Precise at Port 0 EX/WB |

### 8.2 Milestone 6 Diagnostic Telemetry Probes
To facilitate independent verification and bottleneck diagnosis, the following non-architectural internal probe signals are exported to the verification testbench:
- `diag_m6_tage_hit_base_o`: Asserted when prediction is provided by Base Table `T_0`.
- `diag_m6_tage_hit_tagged_o`: Asserted when prediction is provided by Tagged Tables `T_1..T_4`.
- `diag_m6_tage_alloc_fail_o`: Asserted when a mispredicted branch fails to allocate due to all `u = 1`.
- `diag_m6_nlp_req_issued_o`: Asserted when MSHR1 successfully issues a next-line prefetch request.
- `diag_m6_nlp_hit_o`: Asserted when a demand fetch hits a cache line previously installed by NLP.
- `diag_m6_nlp_drop_page_bound_o`: Asserted when a prefetch is safely aborted at a 4 KiB page boundary.

### 8.3 Preservation of Single-Owner CPI Conservation
Milestone 6 strictly preserves the single-owner CPI cycle accounting framework established in M5 Section 9:

`ΔCSR_MCYCLE = C_serialize + C_br_recover + C_productive + C_mem_stall + C_be_rename + C_be_sched + C_fe_starve + C_idle_other`

`CPI = (ΔCSR_MCYCLE) / (ΔCSR_MINSTRET) = sum_k=1^8 ΔCPI_k`

> **Zero-Leakage Invariant**: The formal property `sum_k=1^8 C_k == Δmcycle` must hold continuously over every clock cycle and across all verification workloads without exception.

---

## 9. Physical Design, SRAM/FF Storage Budget & Critical-Path Timing Discipline

### 9.1 Complete Milestone 6 Frontend Storage Budget
Milestone 6 structures are carefully budgeted to guarantee compact implementation on modern FPGA (e.g. AMD Xilinx UltraScale+ / Artix-7) and standard-cell ASIC technologies:

| Subsystem Component | Structure / Organization | Entry Count | Bit Budget | Byte Budget | Physical Implementation |
|---|---|---|---|---|---|
| **TAGE Base Table (`T_0`)** | Direct Mapped, 2-bit bimodal | 2,048 | 4,096 bits | 512 Bytes | Distributed RAM / Dual-Port BRAM |
| **TAGE Tagged Table (`T_1`)**| 512 entries, 8b tag + 3b ctr + 1b u | 512 | 6,144 bits | 768 Bytes | Distributed RAM / BRAM |
| **TAGE Tagged Table (`T_2`)**| 512 entries, 8b tag + 3b ctr + 1b u | 512 | 6,144 bits | 768 Bytes | Distributed RAM / BRAM |
| **TAGE Tagged Table (`T_3`)**| 512 entries, 9b tag + 3b ctr + 1b u | 512 | 6,656 bits | 832 Bytes | Distributed RAM / BRAM |
| **TAGE Tagged Table (`T_4`)**| 512 entries, 10b tag + 3b ctr + 1b u| 512 | 7,168 bits | 896 Bytes | Distributed RAM / BRAM |
| **Folded History Registers**| Live (2 sets) + 8 Checkpoints (106b each) | 2 live + 8 ckpts | 1,060 bits | 133 Bytes | Flip-Flops |
| **Global History Register (GHR)** | Live (108b) + 8 Checkpoints (108b each) | 1 live + 8 ckpts | 972 bits | 122 Bytes | Flip-Flops |
| **Branch Target Buffer (BTB)**| 2-Way Set-Associative (256 sets) | 512 | 61,440 bits | 7,680 Bytes | Block RAM / SRAM |
| **Return Address Stack (RAS)**| 16-entry circular array + checkpts | 16 (+8 ckpts) | 9,216 bits | 1,152 Bytes | Flip-Flops / Distributed RAM |
| **L1 Instruction Cache (L1I)**| 16 KiB 4-Way Set-Associative | 64 lines/way| 147,456 bits| 18,432 Bytes| Block RAM / Synchronous SRAM |
| **Instruction TLB (ITLB)** | 64-entry base + 8-entry superpage | 72 | 4,608 bits | 576 Bytes | Register Array + CAM |
| **TOTAL M6 FRONTEND STATE** | — | — | **254,960 bits** | **31.87 KiB** | **Fits in single FPGA BRAM tile** |

*All storage numbers tagged as `[ANALYTICAL STRUCTURAL BOUND]`.*

### 9.2 Critical-Path Timing Discipline
To preserve high operating frequency and prevent critical path degradation:
1. **Decoupled Stage F1/F2 Hashing**: Folded history CSR updates occur synchronously at cycle boundaries. In Stage F2, table indices and tags are formed using shallow 2-level XOR gates in parallel with the L1I tag SRAM read.
2. **Parallel Provider Selection**: Tag match comparisons across `T_1..T_4` execute concurrently using priority multiplexers, ensuring provider selection delay is `< 0.4 ns` in typical 28nm/16nm ASIC technology `[DESIGN HYPOTHESIS]`.
3. **No GH/Index Crossbar**: GHR is strictly organized as a shift register; tagged tables do not dynamically reconfigure history lengths.
4. **No GHz / Process Claims**: Explicit clock frequency targets (e.g. 1.0 GHz) are removed as binding requirements; timing is evaluated via post-synthesis static timing analysis (STA).

---

## 10. Verification & Validation Architecture

Milestone 6 verification requires a comprehensive suite of directed unit tests, multi-seed randomized control-flow torture tests, and full predecessor regressions.

### 10.1 Mandatory Directed & Adversarial Properties Matrix
The verification testbench must formally prove compliance across the following **36 mandatory properties**:

| Property ID | Target Mechanism | Validation Criterion |
|---|---|---|
| `PROP_M6_01` | TAGE Base Hit | Un-correlated branch hits `T_0`; prediction matches bimodal 2-bit counter. |
| `PROP_M6_02` | TAGE Tagged Hit (`T_1`) | 4-bit correlated branch hits `T_1`; overrides `T_0` prediction correctly. |
| `PROP_M6_03` | TAGE Tagged Hit (`T_2`) | 12-bit correlated branch hits `T_2`; overrides `T_1` and `T_0`. |
| `PROP_M6_04` | TAGE Tagged Hit (`T_3`) | 36-bit correlated branch hits `T_3`; overrides shorter history tables. |
| `PROP_M6_05` | TAGE Longest Match (`T_4`)| 108-bit correlated branch hits `T_4`; selects `T_4` as provider. |
| `PROP_M6_06` | Altpred Fallback | Weak provider counter (`ctr ∈ 3,4, u=0`) gracefully falls back to `T_alt`. |
| `PROP_M6_07` | Dual-Slot Prediction | Block containing two branches predicts both in parallel; Slot 0 taken suppresses Slot 1. |
| `PROP_M6_08` | Carried GHR Update | Slot 0 conditional untaken carries {GHR[106:0], 1'b0} into Slot 1; non-branch in Slot 0 leaves GHR[107:0] completely unmodified for Slot 1. |
| `PROP_M6_09` | Checkpoint Allocation | Live GHR and all folded history CSRs captured cleanly into checkpoint `ID ∈ [0,7]`. |
| `PROP_M6_10` | Port 0 Recovery | Port 0 mispredict restores checkpointed GHR and updates with actual resolved direction. |
| `PROP_M6_11` | Folded CSR Checkpoint Restoration | Folded CSR registers restored directly from checkpoint storage in 1 cycle, matching bit-for-bit with golden folded state. |
| `PROP_M6_12` | Useful Bit Increment | Provider correct while altpred incorrect increments useful bit (`u ← 1`). |
| `PROP_M6_13` | Useful Bit Decrement | Provider incorrect while altpred correct decrements useful bit (`u ← 0`). |
| `PROP_M6_14` | Table Allocation Success | Mispredicted branch allocates entry in at most one table (smallest eligible history table with `u = 0`). |
| `PROP_M6_15` | Table Allocation Failure | Allocation failure when all `u = 1` safely decays useful bits without corruption. |
| `PROP_M6_16` | Useful Bit Periodic Reset | 19-bit retirement counter triggers periodic flash reset of all `u` bits to zero. |
| `PROP_M6_17` | RAS Standard Call/Ret | Function call pushes `PC+4`; matching return pops correct target with 0 mispredicts. |
| `PROP_M6_18` | RAS Coroutine Swap Case 4 | `JALR x1, 0(x5)` performs in-place TOS overwrite; pointer depth remains invariant. |
| `PROP_M6_19` | RAS Coroutine Swap Case 5 | `JALR x1, 0(x1)` performs push only; depth increments cleanly. |
| `PROP_M6_20` | RAS Stack Wrap | 16 nested calls wrap circular array without assertion failure; depth saturates at 16. |
| `PROP_M6_21` | RAS Checkpoint Rollback | Mispredicted branch restores exact 16-entry RAS array, TOS pointer, and depth. |
| `PROP_M6_22` | F3 Early JAL Correction | Unpredicted direct JAL in F3 redirects F0 and restores clean GHR, RAS, and folded CSRs in single cycle without history drift. |
| `PROP_M6_23` | NLP Idle Allocation & Merge | Sequential prefetch allocated into MSHR1 when idle; demand miss collision merges into MSHR1 without duplicate bus read. |
| `PROP_M6_24` | NLP Page Boundary Abort | Demand access at line 63 of 4 KiB page silently aborts prefetch; zero bus request. |
| `PROP_M6_25` | NLP Cache Hit Bypass | Prefetch dropped combinationally if target line is already present in L1I data array. |
| `PROP_M6_26` | NLP Dead Refill Purge | Pipeline flush while prefetch is in-flight marks dead refill; suppresses pipeline push. |
| `PROP_M6_27` | NLP Bus Error Tolerance | Bus read error on prefetch deallocates MSHR1 silently; zero CPU trap raised. |
| `PROP_M6_28` | FENCE.I Flash Purge | `FENCE.I` purges all I-MSHRs, invalidates L1I tags, and resets prefetch engine. |
| `PROP_M6_29` | SFENCE.VMA Translation Purge| `SFENCE.VMA` purges in-flight prefetch requests; zero stale PA accesses. |
| `PROP_M6_30` | PTW Memory Priority | Shared PTW walk requests strictly take priority over prefetch bus requests. |
| `PROP_M6_31` | Odd-Word Fetch Alignment | Fetch starting at `PC[2]=1` masks Slot 0 and delivers Slot 1 correctly to FQ16. |
| `PROP_M6_32` | HPM Counter Mapping | Events `0x0B`..`0x12` verified incrementing precisely under TAGE/RAS stimulation. |
| `PROP_M6_33` | CPI Conservation Law | `sum_k=1^8 C_k == Δmcycle` continuously holds across all testbench runs. |
| `PROP_M6_34` | Multi-Checkpoint Drain | 8 consecutive checkpoints allocated and retired in program order without leak. |
| `PROP_M6_35` | Nested Mispredict Cascade | Branch mispredicts while older recovery is active; older recovery dominates. |
| `PROP_M6_36` | Full Random Torture | 100,000 randomized operations pass across canonical seeds with 0 mismatches. |

### 10.2 Independent Control-Flow Torture Reference Model
Randomized verification must utilize an independently maintained software reference model that:
1. Simulates a golden TAGE-Lite predictor in C++ with identical geometric lengths and folding functions;
2. Tracks speculative and committed GHR vectors independently of the RTL implementation;
3. Validates that every prediction, provider selection, alternate prediction, and allocation decision matches the RTL bit-for-bit;
4. Simulates full RISC-V calling convention linkage register rules and asserts zero RAS divergence;
5. Validates that the final architectural state of the core matches the Spike reference model.

---

## 11. Milestone 6 Freeze Gates & Acceptance Criteria

Milestone 6 shall be declared **FROZEN** only when all of the following criteria are satisfied:

### 11.1 Architecture Freeze Gates
- [ ] **Independent Architecture Review**: Independent adversarial review returns **P0 = 0, P1 = 0**. Any remaining P2/P3 items must have documented non-blocking dispositions with zero correctness ambiguity.

### 11.2 Implementation & Correctness Gates
- [ ] **Full Predecessor Regression Clean**: 100% pass rate across all M1, M2, M3, M4, and M5 regression suites (200+ directed tests).
- [ ] **M6 Mandatory Properties Clean**: All 36 mandatory properties in Section 10.1 pass 100%.
- [ ] **Randomized Control-Flow Torture**: `≥ 100,000` accepted operations across canonical seeds (42, 20260920, 20261009) with 0 assertion failures, 0 mismatches, and 0 watchdog timeouts.
- [ ] **Verilator Lint Clean**: Zero warnings, zero errors under strict lint rules (`tools/run_s1_lint.py`).

### 11.3 Telemetry & Cycle Conservation Gates
- [ ] **HPM Telemetry Validation**: All 48 hardware performance events and new diagnostic probes verified against cycle-accurate traces.
- [ ] **Zero Cycle Leakage**: Formal assertion confirms `sum_k=1^8 C_category == Δmcycle` across all benchmark runs.

### 11.4 Performance Evaluation Gates
- [ ] **Benchmark Characterization Report**: Formal benchmark report generated comparing M6 performance directly against the frozen M5 B4 baseline (`results/s1-m5-b4.json`).
- [ ] **Branch Recovery Reduction**: Empirical verification that `branch_torture` misprediction rate drops significantly below the M5 baseline of 45.0% and `C_br_recover` cycles are substantively reduced. *(Note: Specific IPC targets are empirical evaluation targets, not correctness freeze blockers).*

---

## 12. Roadmap to Milestones 7 & 8

Following the stabilization and freeze of Milestone 6, the Fursoy core roadmap projects the following major architectural milestones:
- **Milestone 7 (Multi-Banked L1D, Dual AGU & Coherent Interconnect Boundary)**:
  - Transition to dual AGU on Port 2 and Port 3 with multi-banked synonym-safe L1D.
  - Integration of a protocol-neutral coherent caching-agent boundary.
- **Milestone 8 (Standard Floating-Point & Vector Execution Extensions)**:
  - RV64F/D pipelined FMA units and dedicated Floating-Point Register File (FPRF).
  - RVV 1.0 vector processing unit (VPU) with decoupled vector issue queues.

---

## 13. Conclusion & Architecture Definition Sign-Off

Milestone 6 architectural specification v1.0 delivers a comprehensive, mathematically rigorous blueprint for branch prediction and instruction stream optimization in the Fursoy Slice-1 core. By combining a 5-table TAGE-Lite direction predictor (~3.7 KiB storage), full RISC-V linkage convention coroutine-swap classification, and a conservative same-page next-line instruction prefetcher, Milestone 6 directly attacks the dominant remaining microarchitectural bottleneck identified in Milestone 5 profiling. The specification preserves 100% of frozen predecessor semantics, enforces strict physical design and timing discipline, provides an exhaustive 36-property verification matrix, and establishes clear freeze criteria for implementation.
