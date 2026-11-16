# Fursoy Slice-1 Milestone 5 — Integrated Performance, Profiling & Throughput Optimization Architecture Specification

**Document ID:** `docs/architecture/slice1-m5-performance-v1.md`
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.2 — FROZEN
**Target Core:** Fursoy Slice-1 (Single-Hart 2-Wide OoO RV64IMAZbaZbb + Sv39)
**Predecessor Substrates (Frozen):**
- **Milestone 1** (Verified & Frozen): PRF80, ROB48, FreeList48, SRAT/ARAT, 8 Checkpoints, Recovery Substrate.
- **Milestone 2** (Verified & Frozen): PRF Data Storage 64b, IntIQ 16, Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV, Lossless WB.
- **Milestone 3** (Verified & Frozen): MemIQ 12, LQ16, SQ16, Port 2 AGU, L1D 16 KiB 4W, 4 MSHR, 2 WBB, TRT4, PRF 6R3W.
- **Milestone 4** (Verified & Frozen): Decoupled Frontend (F0–D0), FQ12, BTB512 2W, Gshare4096 12b GHR, RAS16, L1I 16 KiB 4W, 2 I-MSHR, ITLB64 4W + 8-entry Superpage CAM, Shared Sv39 PTW, Privileged CSR/System Execution (`satp`, `SFENCE.VMA`, MRET/SRET), `FENCE.I` Clean/Invalidate.
**Frozen Baseline Commits:**
- M4 RTL Freeze Commit: `6755e713a197d205eac6ffc2af369f9932e35a02`
- Documentation Normalization Commit: `3bb17d2ffda8910a2c7748cdfa3af8a6e27b7abd`
- M1+M2+M3+M4 Combined RTL Manifest SHA-256: `a8dedc02b7138aedd32fbe0f67eb6d4513140a345b229ccf9a630acb3a42b554`
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m2-backend-v1.md`, `docs/architecture/slice1-m3-memory-v1.md`, `docs/architecture/slice1-m4-frontend-v1.md`

> **Post-Phase-3 RTL Note (`bab4ceb`):** Post-M5 production RTL expanded checkpoints (`8 → 16`), `ROB` (`48 → 128`), `PRF` (`80 → 160`), `IntIQ`/`MemIQ` (`16 → 32`), and extended the HPM bus across `64+` events while preserving the frozen 8-category single-owner CPI conservation law (`sum(C_k) == Δmcycle`) verified across the 90.30M-cycle Linux 6.6.50 boot (`results/s1-m9-closeout.json`).

---

## 1. Milestone Objective & Phased Architecture Charter

### 1.1 Context & Purpose
Milestones 1 through 4 delivered, verified, and froze the functional building blocks of the Fursoy Slice-1 core:
- M1 established register renaming, allocation, dependency tracking, circular reorder buffering, and checkpoint recovery.
- M2 delivered integer out-of-order scheduling, dual arithmetic execution pipelines, pipelined multiplication, iterative division, and lossless writeback arbitration.
- M3 integrated the out-of-order memory execution subsystem, supporting dynamic address generation, disambiguated load execution, store buffering, non-blocking L1 data caching, atomics, and coherent bus tracking.
- M4 completed the instruction supply engine, introducing decoupled 64-bit instruction fetch, dynamic branch prediction, return address caching, non-blocking L1 instruction caching, virtual memory translation (Sv39 ITLB/PTW), and privileged system control.

With functional correctness and ISA compliance solidly frozen across Milestones 1–4, **Milestone 5 (M5)** transitions the core from component correctness to **integrated sustained performance and throughput optimization**.

### 1.2 Core Architectural Charter
The formal charter of Milestone 5 is:
> **Establish an architecturally defined profiling and instrumentation infrastructure, remove avoidable frontend, backend, and memory throughput bubbles, and deliver an empirically characterized, performance-capable Slice-1 baseline suitable for downstream Linux workload profiling, without widening the core pipeline beyond the 2-wide frontend / rename / commit limit.**

M5 is **NOT** a miscellaneous feature bucket, nor does it prematurely expand core width. M5 systematically diagnoses structural stalls, queue imbalances, and conservative memory ordering barriers, implementing targeted microarchitectural optimizations while preserving 100% of frozen M1–M4 architectural semantics.

### 1.3 Phased Execution Structure: Phase A and Phase B
Milestone 5 is formally partitioned into two sequential phases to ensure evidence-driven performance engineering:

```
+===================================================================================================+
|                                    MILESTONE 5 PHASED STRUCTURE                                   |
+===================================================================================================+

  PHASE A: Instrumentation & Baseline Profiling (Mandatory Internal Checkpoint)
  -------------------------------------------------------------------------------------------------
  [x] 48 Hardware Performance Event Sources (Events 0x01 .. 0x30).
  [x] 29 Programmable Performance Counters (CSR hpmcounter3..31, mhpmevent3..31).
  [x] Single-Owner, Non-Overlapping CPI Cycle Classification Engine (8 Master Categories).
  [x] Queue Occupancy, Capacity Stall & Resource Contention Profilers.
  [x] Standard Microarchitectural Profiling Workload Harness.
  ===> GATE: Collect empirical baseline profiling data BEFORE activating Phase B optimizations.

  PHASE B: Throughput Optimizations (Evaluated Against Phase A Baseline)
  -------------------------------------------------------------------------------------------------
  [x] Speculative Load Issue past Unresolved Stores with Precise RAW Violation Rollback.
  [x] Load Queue Lifetime Extension & Disambiguation Resolution Snooping.
  [x] One-Shot Replay-Safe Forward Progress / Livelock Prevention with Stage D0 Consumption.
  [x] Decoupled Fetch Queue Capacity Expansion (FQ12 -> FQ16).
  [x] Memory Issue Queue Capacity Expansion (MemIQ12 -> MemIQ16).
  [x] Oldest-Ready-First Priority Issue Scheduling (IntIQ & MemIQ).
  ===> GATE: Quantify exact delta-CPI and IPC gains across benchmark suite.
```

### 1.4 Architectural Boundaries (What M5 Changes vs. Preserves)
To maintain absolute discipline, the boundaries of Milestone 5 are strictly defined:
- **Strictly In-Scope**:
  1. Complete Phase A performance counter and CPI classification subsystem;
  2. Phase B speculative load issue past older unresolved stores with Load Queue RAW hazard detection and architectural rollback at ROB head;
  3. Load Queue entry lifetime extension preserving entries until all relevant older-store disambiguation checks complete (`older_store_checks_complete(load)`);
  4. One-shot replay-safe forward progress token to prevent memory violation livelock with atomic consumption at Stage D0;
  5. Decoupled Fetch Queue capacity expansion to 16 entries (FQ16);
  6. Memory Issue Queue capacity expansion to 16 entries (MemIQ16);
  7. Strict oldest-ready issue priority arbitration based on wrap-safe circular ROB age;
  8. Comprehensive verification matrix covering all speculative memory edge cases;
  9. Structured benchmark profiling methodology.
- **Strictly Out-of-Scope (Preserved / Deferred to M6+)**:
  1. *NO Core Widening*: Decode, Rename, Dispatch, and Commit remain strictly 2-wide.
  2. *NO Second AGU*: Core retains single AGU on Port 2 (multi-bank L1D deferred to Family C).
  3. *NO Complex TAGE Predictor*: Preserves verified Gshare4096 + BTB512 + RAS16 substrate.
  4. *NO Dynamic Selective Replay*: Preserves simple, robust full-flush rollback on violation.
  5. *NO Floating-Point or Vector Units*: Dedicated milestones (M8+).
  6. *NO Multi-Core Directory Engine*: Interconnect remains protocol-neutral caching-agent.

---

## 2. Frozen Predecessor Baseline Assumptions

Milestone 5 operates on top of an immutable, verified baseline. All specifications in M5 assume the following invariants:

1. **Width Contracts**:
   - Instruction Fetch: 64 bits / cycle (delivers up to two 32-bit instructions).
   - Instruction Decode: 2 instructions / cycle into canonical micro-ops (`uop_rename_in_t`).
   - Register Rename & Allocation: 2 uops / cycle.
   - Dispatch: 2 uops / cycle into ROB48 and Issue Queues.
   - Execution Issue: Maximum 3 uops / cycle across Port 0, Port 1, and Port 2.
   - Retirement / Commit: Up to 2 uops / cycle in strict program order from ROB head.
2. **Execution Port Mapping**:
   - **Port 0**: Integer ALU0 + Conditional Branch & Speculative JALR Resolution Unit.
   - **Port 1**: Integer ALU1 + Pipelined Multiplier (3 cycles) + Iterative Divider (8–34 cycles).
   - **Port 2**: Address Generation Unit (AGU) for Loads, Stores, and Atomics.
3. **Register Storage & Namespace**:
   - Unified 80-entry Physical Register File (`p0`..`p79`), 64 bits per entry.
   - 6 read operand ports, 3 writeback result ports.
   - `p0` permanently tied to `64'h0`, zero Free List allocation.
4. **Memory Hierarchy**:
   - Non-blocking L1I: 16 KiB, 4-way set-associative, 64-byte line, 2 I-MSHRs.
   - Non-blocking L1D: 16 KiB, 4-way set-associative, 64-byte line, 4 MSHRs, 2 WBBs.
   - Translation: Split 64-entry base-page + 8-entry superpage ITLB and DTLB; shared 3-level Sv39 PTW with 4:1 bounded fairness.
5. **Architectural Semantics**:
   - Precise exceptions and interrupts committed only at ROB head.
   - `FENCE.I` strictly cleans dirty L1D lines through WBB before invalidating L1I.
   - Atomics (AMO and `SC`) execute non-speculatively at ROB head with empty SQ.

---

## 3. Bottleneck Architecture Audit & Evidence Classification

To maintain scientific integrity, every quantitative statement in this audit is explicitly tagged with its conceptual evidence class:
- `[MEASURED FURSOY RTL RESULT]`: Verified empirical data from frozen testbench execution.
- `[ANALYTICAL STRUCTURAL BOUND]`: Derived directly from hardware queue/bandwidth invariants.
- `[DESIGN HYPOTHESIS]`: Theoretical engineering hypothesis to be tested in Phase A/B.
- `[EXTERNAL WORKLOAD EXPECTATION]`: Typical characteristic reported in published literature for integer code.
- `[EXPLORATORY TARGET]`: Project aspirational goal.

```
+===================================================================================================+
|                                  THEORETICAL MAXIMUM vs. REALIZABLE IPC                           |
+===================================================================================================+

   Theoretical Upper Bound (2-Wide Machine):
   IPC_max = 2.00 uops / cycle (CPI_min = 0.500 cycles / uop) [ANALYTICAL STRUCTURAL BOUND]

   Target Operating Points:
   - Baseline Target:  IPC >= 1.20 (CPI <= 0.833) --> Machine Utilization >= 60.0% [EXPLORATORY TARGET]
   - Stretch Target:   IPC >= 1.50 (CPI <= 0.667) --> Machine Utilization >= 75.0% [EXPLORATORY TARGET]
```

### 3.1 Subsystem-by-Subsystem Bottleneck Analysis

#### A. Frontend & Fetch Engine Bottlenecks
1. **Unaligned Target Slot Wasting (`PC[2] == 1`)**:
   - *Mechanism*: Fetch is 64-bit aligned. When a taken branch, call, or return targets an odd 32-bit slot (`PC[2] == 1`), Slot 0 is masked out, and only 1 instruction is delivered in that cycle.
   - *Analysis*: In server integer code where branch/call frequency is 15–20% `[EXTERNAL WORKLOAD EXPECTATION]`, approximately 10% of fetch cycles deliver only 1 instruction instead of 2, imposing an analytical ~5% frontend bandwidth deficit `[ANALYTICAL STRUCTURAL BOUND]`.
2. **BTB & BPU Evaluation Latency**:
   - *Mechanism*: BTB and Gshare predict in Stage F2. A predicted-taken branch redirects Stage F0 for cycle F3, introducing a 1-cycle pipeline bubble unless buffered by the Fetch Queue.
   - *Analysis*: Without sufficient Fetch Queue buffering, tight loops and frequent branches inject periodic 1-cycle fetch starvation bubbles `[DESIGN HYPOTHESIS]`.
3. **Fetch Queue Depth (FQ12) vs. L1I Miss Latency**:
   - *Mechanism*: FQ holds 12 instructions (6 cycles of 2-wide decode).
   - *Analysis*: On an L1I cache hit, FQ12 provides adequate decoupling. However, on an L1I miss (30–60 cycles DRAM latency), FQ12 drains in 6 cycles, starving the backend for the remaining cycles `[ANALYTICAL STRUCTURAL BOUND]`. FQ12 is also vulnerable to brief TLB page-walk stalls (15–25 cycles) and branch resolution bursts `[DESIGN HYPOTHESIS]`.
4. **Branch Misprediction Recovery Latency**:
   - *Mechanism*: Port 0 resolves branches in Stage EX. The frontend-to-execute depth is 9 cycles. At an assumed 12 MPKI `[EXTERNAL WORKLOAD EXPECTATION]`, branch misprediction penalty would contribute ~0.108 CPI `[DESIGN HYPOTHESIS]`.
   - *Recovery Walk*: During `RECOVER`, the backwards ROB walk restores `P_new` registers at 2 registers/cycle `[ANALYTICAL STRUCTURAL BOUND]`. If 16 younger uops are squashed, recovery takes 8 additional cycles during which Rename is stalled.

#### B. Rename, Allocation & Reorder Buffer Bottlenecks
1. **Branch Checkpoint Capacity (8 Checkpoints)**:
   - *Mechanism*: M1 provides 8 speculative checkpoints. Each conditional branch and speculative JALR allocates one checkpoint.
   - *Analysis*: When an older instruction stalls at ROB head, up to 48 instructions can accumulate in ROB. In branch-dense code (1 branch per 5–6 instructions `[EXTERNAL WORKLOAD EXPECTATION]`), 8 checkpoints can be exhausted within 40–48 instructions, stalling Rename on subsequent branches `[ANALYTICAL STRUCTURAL BOUND]`.
2. **Physical Register Budget (PRF80)**:
   - *Mechanism*: PRF80 mathematically guarantees that Free List cannot exhaust before ROB48 fills (`32 committed + 48 speculative = 80`) `[ANALYTICAL STRUCTURAL BOUND]`.
   - *Analysis*: PRF capacity is balanced with ROB48 and does not constitute an independent bottleneck.

#### C. Integer Scheduling & Execution Port Bottlenecks
1. **Integer Issue Queue Capacity (IntIQ 16)**:
   - *Mechanism*: 16-entry unified queue feeding Port 0 (ALU0/BR) and Port 1 (ALU1/MUL/DIV).
   - *Analysis*: IntIQ16 accommodates up to 8 cycles of 2-wide integer dispatch `[ANALYTICAL STRUCTURAL BOUND]`. If dependent chains stall issue, 16 entries can fill, asserting backpressure to Dispatch.
2. **Port 1 Arithmetic Resource Sharing**:
   - *Mechanism*: Port 1 hosts ALU1 (1 cycle), Multiplier (3 cycles pipelined), and Iterative Divider (8–34 cycles unpipelined). Writeback priority is `Divider > Multiplier > ALU1`.
   - *Analysis*: In standard integer/server workloads, division accounts for `< 0.5%` and multiplication for `2–4%` `[EXTERNAL WORKLOAD EXPECTATION]`. With dual ALU0/ALU1 available, peak integer throughput is 2 ops/cycle, matching 2-wide dispatch `[ANALYTICAL STRUCTURAL BOUND]`. Structural conflict on Port 1 is hypothesized to be a minor contributor (`< 0.02` CPI) `[DESIGN HYPOTHESIS]`.

#### D. Memory Execution Subsystem Bottlenecks (THE CRITICAL LIMITER)
1. **M3 Conservative Load Issue Constraint**:
   - *Mechanism*: In M3, a load uop (`uop_load`) is permitted to issue from MemIQ to Port 2 AGU if and only if **all older stores in the Store Queue have their physical addresses resolved**.
   - *Analysis*: In compiler-generated code, stores and loads are frequently interspersed. Stalling loads until all prior store addresses resolve introduces substantial queuing delays `[DESIGN HYPOTHESIS]`. Stalled loads delay dependent ALU operations, holding ROB entries and stalling Rename. Removing this constraint via speculative load issue is hypothesized to be the highest-return single optimization for the core `[DESIGN HYPOTHESIS]`.
2. **Single AGU (Port 2) Throughput**:
   - *Mechanism*: All loads and stores share a single AGU on Port 2 (maximum 1 memory access / cycle).
   - *Analysis*: Assuming ~33% memory instruction frequency in integer code `[EXTERNAL WORKLOAD EXPECTATION]`, memory demand at 1.2 IPC is ~0.40 uops/cycle `[ANALYTICAL STRUCTURAL BOUND]`. A single AGU provides 1.0 uop/cycle capacity (`2.5×` margin), proving that a single AGU is not the primary throughput bottleneck below 1.5 IPC `[DESIGN HYPOTHESIS]`.
3. **MemIQ Capacity (12 entries)**:
   - *Mechanism*: MemIQ holds 12 memory uops.
   - *Analysis*: When loads stall due to cache misses or older stores, 12 entries fill within 6–8 memory instructions, asserting backpressure to Dispatch `[ANALYTICAL STRUCTURAL BOUND]`.

---

## 4. Phase A vs. Phase B Architecture Scope

To guarantee evidence-driven engineering, M5 defines strict boundaries between baseline profiling and microarchitectural optimizations:

```
+===================================================================================================+
|                                    PHASE A vs. PHASE B DELIVERABLES                               |
+===================================================================================================+

 Phase A: Instrumentation & Baseline Profiling Engine
 ---------------------------------------------------------------------------------------------------
 1. 48 Hardware Performance Event Sources (EV_0x01 .. EV_0x30) mapped to core activity.
 2. 29 Programmable 64-bit Performance Event Counters (hpmcounter3..31 / mhpmevent3..31).
 3. Deterministic Single-Owner CPI Cycle Classification Engine (7 Mutually Exclusive Categories).
 4. Microarchitectural Profiling Workload Suite (Branch Torture, Pointer Chase, Stream, RAW Stress).
 5. Zero-Leakage Cycle Invariant Check: sum(C_category) == mcycle_delta.

 Phase B: Targeted Throughput Optimizations (Evaluated against Phase A Baseline)
 ---------------------------------------------------------------------------------------------------
 1. Speculative Load Issue past Unresolved Older Stores with LQ RAW Hazard CAM Detection.
 2. Load Queue Entry Lifetime Extension: Entry preserved until older_store_checks_complete(load) and load reaches retirement.
 3. Registered Stage-M2 Violation Detection: Pipelined store-to-load conflict evaluation with structural retirement interlock.
 4. One-Shot Replay-Safe Forward Progress Token (force_conservative_replay) with localized Stage D0 consumption.
 5. Fetch Queue Expansion: FQ16 (16 entries, 5-bit counts, dual-push admission).
 6. Memory Issue Queue Expansion: MemIQ12 -> MemIQ16.
 7. Strict Oldest-Ready-First Priority Issue Scheduling across IntIQ and MemIQ.
```

---

## 5. Rejected and Deferred Mechanisms

The following candidate mechanisms were evaluated and **explicitly rejected or deferred** for Milestone 5:

1. **Expanding Core Width to 3-Wide or 4-Wide (REJECTED)**:
   - *Technical Rationale*: Widening decode/rename/commit from 2 to 3 or 4 quadruples rename dependency comparator logic (`O(W^2)`), requires 8 to 12 PRF read ports, expands ROB allocation/retirement logic, and significantly increases silicon area `[DESIGN HYPOTHESIS]`. The 2-wide machine has a theoretical peak of 2.0 IPC `[ANALYTICAL STRUCTURAL BOUND]`, providing substantial headroom to reach 1.2–1.5 IPC once memory bubbles are removed.
2. **Adding a Second AGU on a New Execution Port (REJECTED)**:
   - *Technical Rationale*: Memory demand is ~0.40 uops/cycle at 1.2 IPC `[ANALYTICAL STRUCTURAL BOUND]`. A single AGU provides 1.0 uop/cycle capacity. Adding a second AGU requires either dual-porting L1D SRAM arrays or implementing multi-bank crossbars with complex conflict logic.
3. **Complex Multi-Table TAGE-SC-L Branch Predictor (DEFERRED to Family C)**:
   - *Technical Rationale*: TAGE requires `> 16 KiB` multi-table SRAM storage and complex hysteresis state machines. M4's Gshare4096 + BTB512 + RAS16 requires only ~1.5 KiB storage. Replacing the predictor in M5 would destabilize the frozen M4 frontend substrate.
4. **Dynamic Selective Load Replay Network (REJECTED)**:
   - *Technical Rationale*: Selective replay requires associative dependency broadcast trees, scoreboard tagging, and dual-cycle replay pipelines. Reusing the verified M1 architectural full-flush recovery mechanism achieves the required correctness with vastly lower area and verification risk `[DESIGN HYPOTHESIS]`.
5. **Store-Set Memory Dependence Predictor (DEFERRED to Family C)**:
   - *Technical Rationale*: A full store-set predictor requires Store Set ID (SSID) tables and associative mapping structures. M5 instead adopts a lightweight **one-shot replay-safe token**, which guarantees forward progress with zero table overhead.

---

## 6. Speculative Memory Execution & Precise Violation Recovery Contract (Phase B)

### 6.1 Speculative Load Eligibility & Strict Exclusions
A load instruction in MemIQ is eligible to issue speculatively past older stores with unresolved addresses **if and only if all of the following conditions are met**:
1. **Normal Cacheable & Idempotent Access**:
   - The access must target normal, cacheable, idempotent main memory (PMA/PMP memory type confirmed).
   - *Timing Constraint*: If physical memory attributes (PMA/PMP) cannot be established before address translation completes, speculative execution must pause before initiating irreversible bus transactions.
2. **Strict MMIO / Device Exclusion (NON-SPECULATIVE)**:
   - Memory-mapped I/O (MMIO), device regions, and non-cacheable access **MUST REMAIN STRICTLY NON-SPECULATIVE**.
   - MMIO loads execute strictly at the ROB head when all older stores have drained and the SQ is completely empty, preserving the frozen M3 contract. No replay mechanism may be relied upon to undo speculative MMIO reads.
3. **Atomic Operations Excluded**:
   - `AMO<op>.W/D` instructions are strictly non-speculative and execute only at ROB head.
   - `SC.W/D` instructions are strictly non-speculative and execute only at ROB head.
4. **Load-Reserved (`LR.W/D`) Excluded**:
   - `LR.W/D` instructions are strictly non-speculative with respect to older unresolved stores. LR establishes an architectural reservation and must not issue speculatively past unresolved stores.
5. **No Serializing Attribute**: The load must not carry any system or synchronization serialization flag.
6. **No Known Store Conflict**: The load physical address must not conflict with any older store whose address is already resolved.
7. **Replay-Safe Token Inactive**: The load must not have its `replay_safe` flag set by the forward-progress controller at Stage D0 (Decode/Dispatch).

### 6.2 Load Queue Lifetime Extension Contract
In the frozen M3 baseline, a load deallocates its Load Queue entry upon completion/writeback. Under M5 speculative load execution, this is forbidden:

> **Authoritative LQ Lifetime Contract**: An executed load entry MUST remain allocated and valid in the Load Queue after writeback until **BOTH** of the following conditions are met:
> 1. All older stores that existed when the load was allocated have resolved enough information to prove that no later RAW violation can occur (`older_store_checks_complete(load)`); **AND**
> 2. The load reaches normal architectural retirement at the ROB head.

```
+===================================================================================================+
|                                  LOAD QUEUE ENTRY LIFETIME FSM                                    |
+===================================================================================================+

    [ ALLOCATED ]  -- (Dispatched from Rename; captures sq_older_mask[15:0])
          |
          v
    [ ISSUED ]     -- (Dispatched to Port 2 AGU; calculates PA; accesses L1D)
          |
          v
    [ EXECUTED ]   -- (L1D data returned; writes to PRF; entry REMAINS VALID in LQ!)
          |           Can be snooped by older stores; checks RAW overlap in Stage M2.
          |
          +---> [ VIOLATED ]  -- (Store PA matches; asserts lsu_violation; latches sticky in ROB)
          |
          v
    [ RETIRABLE ]  -- (older_store_checks_complete(load); no unresolved older store hazards remain)
          |
          v
    [ DEALLOCATED] -- (Load commits at ROB head; entry returned to LQ free list)
```

#### Definition of `older_store_checks_complete(load)`:
This condition is true if and only if, for every store that was older than the load at allocation:
1. The store has been squashed or deallocated before becoming relevant; **OR**
2. The store physical address and byte mask are known; **AND**
3. The required LQ violation comparison has completed in Stage M2; **AND**
4. No in-flight Stage M1/M2/M3 violation notification for that store/load relationship remains.

#### Fundamental Architectural Distinction (Separation of SQ Lifetime from Ambiguity):
In frozen M3 (`rtl/core/fursoy_s1_lsu_queues.sv`), `sq_older_mask` tracks older SQ entry ownership and lifetime. Bits clear when older SQ entries deallocate and drain to L1D according to canonical M3 rules. It does **NOT** indicate whether a store physical address is unresolved.
Equating `sq_older_mask == 16'd0` with "all older store addresses have resolved" is false and would force a speculative load to stall retirement until all older stores completely drain into L1D.
Under M5, **a load MUST NOT wait for older stores to drain from the Store Queue before it may retire**. Once an older store's physical address is resolved and its violation CAM check against this load completes with no violation found, that older store's RAW ambiguity is completely resolved.

#### Exact LQ Deallocation Contract:
A load entry in the Load Queue:
- Remains valid after execution and writeback;
- Remains valid while any relevant older-store violation check is unresolved;
- May retire once all relevant older-store checks are complete (`older_store_checks_complete(load)`) and no violation is pending;
- Deallocates at architectural retirement;
- Deallocates immediately on squash/recovery/full flush if the load is killed.
- **No Zombie LQ Entries**: A load must **NEVER** remain as a zombie LQ entry after normal retirement waiting for older stores to drain.

#### Same-Cycle Precedence Invariant:
Same-cycle ordering must strictly guarantee:
1. Older-store address resolution and violation check result;
2. Violation sticky-set acceptance in ROB;
3. Retirement eligibility decision;
4. LQ entry deallocation.
A load must never deallocate before the final applicable violation result can be observed.

### 6.3 Preservation of Canonical `sq_older_mask` Semantics & Check Representation
M5 strictly preserves M3's verified circular `sq_older_mask[15:0]`:
- At dispatch, load `L` captures a snapshot of live, uncommitted older stores in the Store Queue:
  `L.sq_older_mask[s] = 1 <=> Store s is older than L and currently allocated in SQ`
- **Explicit Unresolved-Older-Store Check Representation**:
  To track whether all relevant older-store checks are complete without complex multi-ported tables:
  1. The allocation-time `sq_older_mask` identifies the exact set of stores that were older than the load at dispatch.
  2. For each still-live older SQ entry, `pa_valid` (from frozen M3) determines physical address resolution.
  3. An M5 violation-check-pending bit / pipeline stage tracker determines whether the store's Stage M2 CAM comparison and Stage M3 ROB notification are still in flight.
  4. The structural retirement predicate for a load at the ROB head conceptually requires:
     `all_older_addresses_resolved && no_violation_check_inflight && !mem_violation`
     (and NOT `sq_older_mask == 16'd0`).
- **Preservation of Committed-Store Visibility**:
  Once an older store has resolved its address, completed its violation CAM check, and committed into frozen M3 committed-SQ ownership, it no longer creates unresolved-disambiguation ambiguity for younger loads.
  However, if a replayed load aliases that committed store, the replayed load must still obtain the correct value via:
  - Canonical committed-SQ forwarding (frozen M3);
  - L1D cache visibility (if already drained);
  - Or conservative stall until the store value is observable.
  The architecture strictly distinguishes `disambiguation complete` (no possibility of unobserved RAW violation) from `store value globally visible` (data observable in L1D or forwarded from committed SQ).

### 6.4 Wrap-Safe Circular ROB Age Comparison
To prevent false violation signaling across circular pointer wrapping, raw ROB indices are never compared directly. M5 mandates canonical wrap-safe circular ROB distance logic:

```verilog
function automatic logic rob_is_older(
    input rob_idx_t older_cand,
    input rob_idx_t younger_cand,
    input rob_idx_t head_ptr
);
    logic [5:0] dist_older;
    logic [5:0] dist_younger;
begin
    dist_older   = (older_cand   >= head_ptr) ? (older_cand   - head_ptr) : (ROB_DEPTH + older_cand   - head_ptr);
    dist_younger = (younger_cand >= head_ptr) ? (younger_cand - head_ptr) : (ROB_DEPTH + younger_cand - head_ptr);
    rob_is_older = (dist_older < dist_younger);
end
endfunction
```

A RAW violation is flagged if and only if `rob_is_older(store_rob_idx, load_rob_idx, head_o)` is strictly true.

### 6.5 Persistent Violation Identity & ROB Extension
To prevent stale violation notifications from corrupting a reused ROB slot after branch mispredictions or flushes, M5 introduces a narrow, lifetime-qualified ROB extension:
- **Violation Bus Interface**:
  - `lsu_violation_valid_o`: 1 bit.
  - `lsu_violation_rob_idx_o`: `rob_idx_t` (6 bits).
  - `lsu_violation_rob_epoch_o`: `rob_epoch_t` (ROB generation epoch tag).
- **ROB Acceptance Rule & Epoch Qualification (P0-2 Resolution)**:
  In `fursoy_s1_rob.sv`, each entry maintains a sticky `mem_violation` bit. The live entry's epoch is tracked in `entries_q[idx].epoch` (or `rob_entry_epoch[violation_rob_idx]`):
  ```systemverilog
  if (lsu_violation_valid_i &&
      rob_entry_valid[lsu_violation_rob_idx_i] &&
      (rob_entry_epoch[lsu_violation_rob_idx_i] == lsu_violation_rob_epoch_i)) begin
      mem_violation[lsu_violation_rob_idx_i] <= 1'b1;
  end
  ```
  *Canonical Epoch Qualification Invariant*:
  In the frozen M1 ROB architecture, `slot_epoch_q` tracks the allocation-generation state for the **next** occupant of that slot and **MUST NOT** be used to qualify the currently live ROB entry.
  Stale violation notifications arriving after slot reuse are rejected by matching against the live entry's stored epoch (`entries_q[idx].epoch`).

### 6.6 Pipelined Stage-M2 Violation Detection & Structural Retirement Interlock
To avoid a timing-critical path combining store address generation, TLB translation, and a 16-entry PA CAM lookup in a single cycle:
1. **Stage M1 (Store AGU)**: Store generates virtual address, performs DTLB lookup, and determines 56-bit PA.
2. **Stage M2 (Registered Violation Check)**: The physical address `store_paddr[55:0]`, size, and byte mask are latched into a registered comparison stage. M2 performs the 16-entry CAM query against all executed younger loads in LQ.
3. **Stage M3 (Sticky ROB Set)**: If a violation is detected, `lsu_violation_valid_o` asserts, latching `mem_violation` into the live ROB entry.
4. **Structural Retirement Interlock (P1-1 Resolution)**:
   Correctness must **NEVER** depend on a fixed timer or cycle count. The previous concept of "holding retirement for up to 2 cycles" is completely removed.
   Instead, a speculative load at the ROB head may retire only when its **structural retirement predicate** evaluates to true:
   - Every relevant older store has resolved its address/mask or has been squashed (`older_store_checks_complete(load)`);
   - Every associated violation comparison has completed;
   - No Stage M1/M2/M3 violation result is still in flight;
   - The load's sticky `mem_violation` bit is clear;
   - Normal exception/retirement conditions permit retirement.
   Retirement remains held (`retire_ready_i = 1'b0`) for as many cycles as required, dynamically absorbing DTLB/PTW translation delay, backpressure, consecutive older stores, Stage M2 CAM pipeline stalls, and Stage M3 violation notification latency.
5. **Violation versus Retirement Priority**:
   If a violation indication for the load at ROB head becomes valid in the same cycle that retirement would otherwise fire:
   **VIOLATION WINS**.
   The load **MUST NOT** retire. It enters replay recovery immediately.

### 6.7 Precise Store/Load Byte Overlap Semantics
A RAW violation occurs if and only if physical addresses match at line granularity and physical byte enables overlap:

`AddrMatch = (L.paddr[55:3] == S.paddr[55:3])`
`ByteOverlap = (L.byte_mask[7:0] & S.byte_mask[7:0]) ≠ 8'b0000_0000`
`RAW_Violation = L.executed && rob_is_older(S, L) && L.sq_older_mask[S.sq_idx] && AddrMatch && ByteOverlap`

#### Explicit Overlap Classifications:
1. **Exact Overlap**: Load and store access identical addresses and identical widths (e.g. aligned 8-byte load at `paddr[2:0] == 3'b000`, aligned 8-byte store at `paddr[2:0] == 3'b000`) → **Violation**.
2. **Store Contained in Load**: Store writes 4 bytes `[5:2]` inside an aligned 8-byte load window `[7:0]` → **Violation**.
3. **Load Contained in Store**: Load reads 2 bytes `[3:2]` inside an aligned 8-byte store window `[7:0]` → **Violation**.
4. **Partial Overlap (P3-1 Resolution)**: Aligned 8-byte load covering bytes `[7:0]` (`addr[2:0] == 3'b000`, mask `8'b1111_1111`) and aligned 4-byte store covering bytes `[3:0]` (`mask 8'b0000_1111`), where a strict sub-range overlaps and canonical forwarding cannot supply the unwritten bytes → **Violation**. (Note: Frozen M3 traps natural misalignment before L1D access; all memory accesses in L1D/LQ are naturally aligned within their operand size).
5. **Same Line, No Overlap**: Store writes bytes `[3:0]`; load reads bytes `[7:4]` of the same aligned 64-bit word → **NO Violation** (zero replay).
6. **Adjacent Bytes**: Store writes byte 3; load reads byte 4 → **NO Violation** (zero replay).
7. **Different Lines**: Different 64-byte cache lines → **NO Violation** (zero replay).

### 6.8 Integration with Frozen M3 Forwarding
M5 integrates speculative execution into a single, unified memory issue decision tree:

```
+===================================================================================================+
|                               UNIFIED MEMORY ISSUE & FORWARDING TREE                              |
+===================================================================================================+

 1. Older Store Address UNRESOLVED:
    - Normal Cacheable Load: Issue speculatively to Port 2 AGU; register in LQ.
    - MMIO / AMO / SC / LR:  STALL in MemIQ until ROB head and older stores drain.

 2. Older Store Address RESOLVED, NO Byte Overlap:
    - Load issues directly to L1D; zero stall.

 3. Older Store Address RESOLVED, Supported Exact/Contained Overlap, Data READY:
    - Forward store data directly to load via canonical M3 forwarding path; zero stall.

 4. Older Store Address RESOLVED, Byte Overlap, Data NOT READY:
    - Load MUST STALL in MemIQ until store data becomes ready. Speculating stale data is prohibited.

 5. Older Store Address RESOLVED, Partial Overlap (Not Supported by Forwarding):
    - Load MUST STALL in MemIQ until store commits and drains to L1D (canonical M3 contract).
```

### 6.9 Replay Visibility Guarantee & Store Drain Invariant
When a violated load reaches the ROB head:
1. **Non-Retirement**: The load does **NOT** retire.
2. **Microarchitectural Recovery**: The ROB asserts an architectural flush (`flush_valid_o = 1'b1`). No architectural trap or exception cause is generated.
3. **Frontend Redirect**: Frontend redirects to the load's own PC (`redirect_pc = load_uop.pc`).
4. **Store Visibility Guarantee**: Before the replayed load is permitted to execute again, the conflicting older store must be guaranteed observable. In M5, because the flush occurs at the ROB head, the conflicting store is older than the load and has either:
   - Already committed and drained into L1D; or
   - Reached the head of the Store Queue where its data is immediately available for canonical forwarding.
   *Invariant*: Replay never executes against an unobservable store.

### 6.10 Forward-Progress / Livelock Prevention (One-Shot Replay-Safe Token)
To prevent pathologically repeated RAW violations from creating an infinite replay loop:
1. **Token Allocation on Replay**:
   When a memory violation triggers a recovery flush at ROB head, the controller latches:
   - `replay_safe_pc <= load_uop.pc`
   - `replay_safe_active <= 1'b1`
2. **Localized Token Consumption at Stage D0 (P1-2 Resolution)**:
   When the frontend refetches the instruction stream and decodes uops at Stage D0:
   - If `replay_safe_active && (decoded_load_pc == replay_safe_pc)`:
     - The decoder stamps that specific dynamic load uop with `uop.replay_safe = 1'b1`;
     - Atomically clears `replay_safe_active <= 1'b0` in the same cycle.
   - The `replay_safe` attribute travels with that specific uop through Rename, Dispatch, MemIQ, and LSU.
   - **No Issue-Time Feedback**: There is no backend-to-frontend "clear token on issue" feedback path.
3. **Replay Token Flush Semantics**:
   - **Architectural Trap / Full Flush**: An architectural trap or system flush occurring before token consumption clears the global token (`replay_safe_active <= 1'b0`).
   - **Branch Misprediction Flush**: A branch recovery flush that kills a pre-dispatch instruction instance clears the token deterministically if the matching uop was killed before dispatch.
   - **Post-Consumption Flush**: Once the token is consumed and attached to a dynamic load uop, subsequent flush events handle that uop according to standard pipeline squash rules.
   - **Repeated Violation**: If the replayed load violates again due to a distinct hazard, the new memory-violation recovery re-arms a fresh token.
   - **Atomic Consumption**: PC-only matching is restricted to the first matching dispatched load uop, preventing subsequent loop iterations at the same PC from spuriously receiving the token.
4. **Replay-Safe Load Issue Rule**:
   A dynamic load uop carrying `replay_safe == 1'b1` **MUST USE CONSERVATIVE DISAMBIGUATION**:
   - It may issue only when all older store addresses and byte masks relevant to it have resolved (`older_store_checks_complete(load)`) and all required ordering/forwarding conditions are established.
   - It does **NOT** need to wait for unrelated older stores to drain from the Store Queue if disambiguation is complete.
5. **Livelock Termination Guarantee**:
   Every replayed load is guaranteed to execute its subsequent instance conservatively without possibility of a second speculative RAW violation against unresolved stores, mathematically terminating any potential livelock loop.

### 6.11 Precise Exception vs. Memory Violation Precedence
If an instruction instance experiences both an exception and a memory order violation:
1. **Rule**: A speculative memory exception (e.g. Load Access Fault [Cause 5] or Load Page Fault [Cause 13]) must never become architecturally visible if the load was executed out-of-order past an older store that subsequently violated it.
2. **Precedence**: Memory-order violation **strictly suppresses** the speculative exception for that execution instance.
3. **Mechanism**: When the load reaches the ROB head with both `exception == 1` and `mem_violation == 1`, the ROB treats the event as a **memory order replay**, squashes pipeline state, and redirects to the load PC.
4. **Conservative Re-execution**: Upon conservative re-execution, if the exception persists (e.g. genuine unmapped page), the non-violated architectural instance raises the precise trap at the ROB head.

### 6.12 Safe Wakeup of Dependent Younger Instructions
- Speculative loads may wake dependent instructions in IntIQ and MemIQ immediately upon writeback.
- This is completely safe because no younger instruction can commit or modify architectural register state before reaching the ROB head.
- Upon a violation recovery flush, all speculative physical register allocations, dependent results, younger branch checkpoints, and uncommitted Store Queue entries are cleanly discarded by the verified M1 full-flush engine.
- Zero speculative state escapes to architectural register or memory storage.

### 6.13 RVWMO Compliance Statement
Milestone 5 microarchitectural optimizations alter internal execution timing only. All committed instruction outcomes, memory visibility orders, and store-to-load dependencies remain in strict compliance with the **RISC-V Weak Memory Ordering (RVWMO)** specification. Speculative execution past unresolved stores never exposes a value or memory ordering disallowed by canonical sequential retirement.

---

## 7. Buffer Sizing & Oldest-Ready Scheduling Contracts (Phase B)

### 7.1 Rebalanced Queue Capacities

| Queue / Buffer | M4 Baseline | M5 Optimized | Classification | Operational Rationale |
|---|---|---|---|---|
| **Fetch Queue (FQ)** | 12 entries | **16 entries** | **PROVISIONAL IMPLEMENTATION PARAMETER** | Buffers 8 cycles of 2W decode; cushions L1I hit-under-miss latency |
| **Memory Issue Queue (MemIQ)** | 12 entries | **16 entries** | **PROVISIONAL IMPLEMENTATION PARAMETER** | Accommodates speculative loads and delayed store address uops |
| **Integer Issue Queue (IntIQ)** | 16 entries | **16 entries** | **FROZEN NUMERIC PARAMETER** | Verified adequate; oldest-ready priority scheduling added |
| **Load Queue (LQ)** | 16 entries | **16 entries** | **FROZEN NUMERIC PARAMETER** | Extended lifetime contract; accommodates 16 in-flight loads |
| **Store Queue (SQ)** | 16 entries | **16 entries** | **FROZEN NUMERIC PARAMETER** | Preserved from M3; balanced with commit drain bandwidth |
| **Reorder Buffer (ROB)** | 48 entries | **48 entries** | **FROZEN NUMERIC PARAMETER** | Preserved from M1; strictly balanced with PRF80 (`32 + 48 = 80`) |
| **Physical Register File** | 80 registers | **80 registers** | **FROZEN NUMERIC PARAMETER** | Invariant with ROB48; Free List cannot starve |
| **Branch Checkpoints** | 8 checkpoints | **8 checkpoints** | **FROZEN NUMERIC PARAMETER** | Preserved from M1; accommodates in-flight speculative branches |

### 7.2 Fetch Queue Expansion Contract (FQ16)
- **Parameters**: `DEPTH = 16`, read pointer width = 4 bits, write pointer width = 4 bits, occupancy count = 5 bits (representing 0..16).
- **Interface Signals**:
  - `count_o`: 5-bit current occupancy count (0..16).
  - `free_count_o`: 5-bit available capacity count (`16 - count`).
  - `full`: Asserted when `count == 16`.
  - `empty`: Asserted when `count == 0`.
- **Push / Pop Interfaces**: 2-instruction push from F3, 2-instruction pop to D0.
- **Dual-Push Admission Policy (P2-1 Resolution)**:
  - 2 valid pushes require at least 2 free slots (`free_count_o >= 2`, accounting for simultaneous pops);
  - 1 valid push requires at least 1 free slot (`free_count_o >= 1`, accounting for simultaneous pops);
  - An occupancy of `count == 15` is **NOT** full; it can accept 1 push unconditionally, or 2 pushes if at least 1 pop occurs simultaneously.
- **Simultaneous Operation**: Supports concurrent 2-push and 2-pop in the same cycle when capacity allows.
- **Flush**: Synchronous single-cycle reset to `head = 0, tail = 0, count = 0` on pipeline redirect or trap.

### 7.3 Memory Issue Queue Expansion Contract (MemIQ16)
- **Parameters**: `DEPTH = 16`, pointer width = 4 bits, count range 0..16.
- **Issue Policy**: Single-issue to Port 2 AGU per cycle.
- **Eligibility**: Evaluates operand readiness, L1D availability, and speculative load eligibility.
- **Backpressure**: Asserts `mem_iq_ready_o[1:0]` to Dispatch; stalls rename when `free_slots < 2`.

### 7.4 Strict Oldest-Ready-First Issue Selection Policy
In M1–M4, issue queue selection utilized unweighted ready-grant matrices. M5 mandates **Strict Oldest-Ready-First Priority**:
1. **Primary Selection Rule**: Among all ready candidate uops eligible for an execution port, the scheduler **MUST select the oldest uop** according to wrap-safe circular ROB age (`rob_is_older`).
2. **Tie-Break**: If two uops have identical age (e.g. dispatched in the same cycle as Slot 0 and Slot 1), Slot 0 takes precedence.
3. **No Cross-Queue Producer Boosting**: Port 0 and Port 1 schedulers do not monitor MemIQ status; selection is strictly intra-queue oldest-ready.
4. **No Age Inversion**: A younger branch uop is **NEVER** permitted to bypass an older ready ALU uop. Branch priority is respected only as a tie-breaker between equal-age instructions.

---

## 8. Hardware Performance Instrumentation Architecture (Phase A)

Milestone 5 defines **48 hardware event sources** (Event IDs `0x01` through `0x30`) driving up to **29 programmable 64-bit counters** accessible via standard RISC-V Privileged Specification CSRs:
- Base Architected Counters: `mcycle` (`0xB00`), `minstret` (`0xB02`).
- Event Selectors: `mhpmevent3` (`0x323`) through `mhpmevent31` (`0x33F`).
- Programmable Counters: `hpmcounter3` (`0xC03`) through `hpmcounter31` (`0xC1F`).
- Counter Privilege Read Control: `mcounteren` (`0x306`), `scounteren` (`0x106`).
- **Explicit HPM Privilege Policy (P1-3 Resolution)**:
  - *Increment Scope*: Hardware event sources monitor core activity across all operating modes (`M, S, U (All Modes)`).
  - *Selector Role*: `mhpmeventN` registers select the active event ID (`0x01`..`0x30`) mapped to `hpmcounterN`. M5 defines no selector-level M/S/U filtering bits.
  - *Access Control*: `mcounteren` and `scounteren` control read access to counters from S-mode and U-mode. Attempting to read an unpermitted counter traps with an illegal instruction exception. Counter incrementing itself is not gated by `mcounteren`/`scounteren`.
  - *Inhibit Scope*: `mcountinhibit` is **NOT implemented** in Milestone 5; counters run continuously once reset is deasserted. No counter overflow interrupts are supported in M5.

### 8.1 Complete 48 Hardware Performance Event Table

| Event ID | Symbolic Name | Increment Timing / Qualification Point | Increment Condition | Privilege Mode Qualification |
|---|---|---|---|---|
| `0x01` | `EV_FETCH_CYCLES` | Microarchitectural (Cycle) | Frontend Stage F0 actively attempting fetch | All Modes |
| `0x02` | `EV_FETCH_BLOCKS` | Microarchitectural (Response) | Valid 64-bit fetch block delivered from L1I | All Modes |
| `0x03` | `EV_FETCH_UOPS` | Microarchitectural (Enqueue) | Valid instruction micro-ops pushed to Fetch Queue | All Modes |
| `0x04` | `EV_FETCH_FQ_STARVED`| Microarchitectural (Cycle) | Cycle where Fetch Queue is empty and backend is ready | All Modes |
| `0x05` | `EV_FETCH_FQ_FULL` | Microarchitectural (Cycle) | Cycle where Fetch Queue is full and asserts backpressure | All Modes |
| `0x06` | `EV_FETCH_ODD_SLOT` | Microarchitectural (Fetch) | Fetch cycle starting at odd word (`PC[2]==1`, Slot 0 masked)| All Modes |
| `0x07` | `EV_L1I_HITS` | Microarchitectural (Access) | L1I tag hit on demand fetch request | All Modes |
| `0x08` | `EV_L1I_MISSES` | Microarchitectural (Access) | L1I tag miss allocating an Instruction MSHR | All Modes |
| `0x09` | `EV_L1I_IMSHR_OCC` | Microarchitectural (Cycle) | Sum of active I-MSHR entries (0..2) during cycle | All Modes |
| `0x0A` | `EV_ITLB_MISSES` | Microarchitectural (Access) | ITLB lookup miss triggering shared PTW translation walk | All Modes |
| `0x0B` | `EV_BTB_QUERIES` | Microarchitectural (Stage F2) | Control-flow instruction queried against BTB in F2 | All Modes |
| `0x0C` | `EV_BTB_HITS` | Microarchitectural (Stage F2) | Branch finding matching tag and target in BTB | All Modes |
| `0x0D` | `EV_BPU_COND_PRED` | Microarchitectural (Stage F2) | Conditional branch direction evaluated by Gshare | All Modes |
| `0x0E` | `EV_BPU_DIR_MISPRED` | Precise at Instruction Retirement | Conditional branch direction mispredicted on Port 0 | All Modes |
| `0x0F` | `EV_BPU_TGT_MISPRED` | Precise at Instruction Retirement | Indirect jump / JALR target mispredicted on Port 0 | All Modes |
| `0x10` | `EV_RAS_CALL_PUSH` | Microarchitectural (Stage D0) | Architectural return address pushed to RAS on CALL | All Modes |
| `0x11` | `EV_RAS_RET_POP` | Microarchitectural (Stage F2) | Speculative target address popped from RAS on RET | All Modes |
| `0x12` | `EV_RAS_RET_MISPRED` | Precise at Instruction Retirement | Return instruction whose RAS target mismatched Port 0 | All Modes |
| `0x13` | `EV_RENAME_UOPS` | Microarchitectural (Stage RN) | Micro-ops successfully allocated in Rename/Dispatch | All Modes |
| `0x14` | `EV_STALL_ROB_FULL` | Microarchitectural (Cycle) | Cycle where Rename stalled due to ROB48 full | All Modes |
| `0x15` | `EV_STALL_INTIQ_FULL`| Microarchitectural (Cycle) | Cycle where Rename stalled due to IntIQ full | All Modes |
| `0x16` | `EV_STALL_MEMIQ_FULL`| Microarchitectural (Cycle) | Cycle where Rename stalled due to MemIQ full | All Modes |
| `0x17` | `EV_STALL_LQ_FULL` | Microarchitectural (Cycle) | Cycle where Rename stalled due to Load Queue full | All Modes |
| `0x18` | `EV_STALL_SQ_FULL` | Microarchitectural (Cycle) | Cycle where Rename stalled due to Store Queue full | All Modes |
| `0x19` | `EV_STALL_CHKPT_FULL`| Microarchitectural (Cycle) | Cycle where Rename stalled due to 8 checkpoints full | All Modes |
| `0x1A` | `EV_STALL_RECOVERY` | Microarchitectural (Cycle) | Cycle where Rename stalled due to active `recovering_o` | All Modes |
| `0x1B` | `EV_ISSUE_PORT0` | Microarchitectural (Issue) | Valid uop issued to Port 0 (ALU0 / Branch) | All Modes |
| `0x1C` | `EV_ISSUE_PORT1_ALU` | Microarchitectural (Issue) | Simple integer ALU uop issued to Port 1 | All Modes |
| `0x1D` | `EV_ISSUE_PORT1_MUL` | Microarchitectural (Issue) | Multiplier uop issued to Port 1 | All Modes |
| `0x1E` | `EV_ISSUE_PORT1_DIV` | Microarchitectural (Issue) | Iterative divider uop issued to Port 1 | All Modes |
| `0x1F` | `EV_ISSUE_PORT2_AGU` | Microarchitectural (Issue) | Memory uop issued to Port 2 AGU | All Modes |
| `0x20` | `EV_PORT1_WB_STALL` | Microarchitectural (Cycle) | Cycle where ALU1 writeback held due to Divider/Multiplier | All Modes |
| `0x21` | `EV_INTIQ_EMPTY` | Microarchitectural (Cycle) | Cycle where IntIQ has 0 ready uops while ROB is non-empty| All Modes |
| `0x22` | `EV_MEMIQ_EMPTY` | Microarchitectural (Cycle) | Cycle where MemIQ has 0 ready uops while ROB is non-empty| All Modes |
| `0x23` | `EV_LOAD_ISSUED` | Microarchitectural (Issue) | Total load uops issued to Port 2 AGU | All Modes |
| `0x24` | `EV_LOAD_SPECULATIVE`| Microarchitectural (Issue) | Loads issued past older stores with unresolved addresses | All Modes |
| `0x25` | `EV_LOAD_FWD_EXACT` | Microarchitectural (Execute) | Loads receiving forwarded data from older matching store | All Modes |
| `0x26` | `EV_LOAD_FWD_PARTIAL`| Microarchitectural (Issue) | Loads stalled due to partial-overlap store conflict | All Modes |
| `0x27` | `EV_LOAD_RAW_VIOLAT` | Precise at ROB-head Replay | Speculative load RAW violation triggering replay flush (once per event)| All Modes |
| `0x28` | `EV_L1D_HITS` | Microarchitectural (Access) | L1D cache read hits | All Modes |
| `0x29` | `EV_L1D_MISSES` | Microarchitectural (Access) | L1D cache read misses allocating an MSHR | All Modes |
| `0x2A` | `EV_L1D_MSHR_OCC` | Microarchitectural (Cycle) | Sum of active L1D MSHR entries (0..4) during cycle | All Modes |
| `0x2B` | `EV_L1D_WBB_FULL` | Microarchitectural (Cycle) | Cycle where L1D refill stalled due to WBB full | All Modes |
| `0x2C` | `EV_DTLB_MISSES` | Microarchitectural (Access) | DTLB translation miss triggering PTW walk | All Modes |
| `0x2D` | `EV_RETIRE_CYCLES_0` | Precise at Instruction Retirement | Cycle where ROB head was valid but 0 uops retired | All Modes |
| `0x2E` | `EV_RETIRE_CYCLES_1` | Precise at Instruction Retirement | Cycle where exactly 1 uop retired from ROB head | All Modes |
| `0x2F` | `EV_RETIRE_CYCLES_2` | Precise at Instruction Retirement | Cycle where exactly 2 uops retired from ROB head | All Modes |
| `0x30` | `EV_SERIALIZE_CYCLES`| Precise at Instruction Retirement | Cycle consumed by system serialization (`FENCE.I`, CSRs) | All Modes |

---

## 9. Authoritative CPI Decomposition Framework (Phase A)

To eliminate ambiguous performance accounting, M5 mandates a **deterministic single-owner cycle classification engine**. Every elapsed core cycle is assigned to exactly one mutually exclusive master category.

### 9.1 Deterministic Single-Owner Priority Hierarchy
In any given clock cycle, the cycle is classified by evaluating the following conditions in strict priority order (Priority 1 through Priority 8).

*Productive Cycle Masking Invariant (P2-2 Resolution)*: If at least one instruction retires in a cycle (`retire_count > 0`), the cycle is classified as `C_productive` unless a higher-priority architectural recovery or system serialization event intentionally owns the cycle. A cycle with valid instruction commits is never misclassified as `C_be_rename` merely because Rename experienced transient backpressure in the same cycle.

```
+===================================================================================================+
|                              CPI SINGLE-OWNER DETERMINISTIC CLASSIFIER                            |
+===================================================================================================+

 Priority  Category        Condition / Predicate
 --------  --------------  --------------------------------------------------------------------------
    1      C_serialize     retire_ready_i == 0 due to FENCE.I clean, SFENCE.VMA, or CSR serialization.
    2      C_br_recover    recovering_o == 1 (active backward walk) or memory violation replay flush.
    3      C_productive    retire_count > 0 (at least one instruction retired; useful commit progress).
    4      C_mem_stall     ROB head is load/store waiting on uncompleted cache refill, PTW, or hold.
    5      C_be_rename     Fetch Queue non-empty, but Rename stalled (!alloc_ready_o: ROB/IQ/Chkpt full).
    6      C_be_sched      ROB non-empty, but zero uops ready (DIV head wait, MUL dep, RAW dep chain).
    7      C_fe_starve     Fetch Queue empty while core is active and ready to consume instructions.
    8      C_idle_other    Pipeline startup fill / WFI / quiescent core (0 in-flight uops, no stalls).
```

### 9.2 Exact Mathematical Invariants
`Total Elapsed Cycles = ΔCSR_MCYCLE = C_serialize + C_br_recover + C_productive + C_mem_stall + C_be_rename + C_be_sched + C_fe_starve + C_idle_other`

`CPI = (ΔCSR_MCYCLE) / (ΔCSR_MINSTRET) = sum_k=1^8 ΔCPI_k`

- **Zero-Leakage Assertion**: The testbench continuously asserts that the sum of the 8 hardware category counters equals `mcycle_delta` over every measured execution interval:
  ```systemverilog
  assert property (@(posedge clk_i) (
      C_serialize + C_br_recover + C_productive + C_mem_stall +
      C_be_rename + C_be_sched + C_fe_starve + C_idle_other == csr_mcycle_q
  ));
  ```
- **Separation of Utilization**: Superscalar commit distribution (`EV_RETIRE_CYCLES_0`, `_1`, `_2`) is tracked independently as an execution density metric and is not conflated with stall attribution.

---

## 10. Benchmark Suite & Workload Profiling Contract

Milestone 5 establishes an explicit distinction between **microarchitectural profiling kernels** (used to diagnose specific pipeline structures) and **general performance benchmarks**:

```
+===================================================================================================+
|                                    INTEGRATED BENCHMARK SUITE                                     |
+===================================================================================================+

 Benchmark Suite     Target Characteristic                       Primary Stress Metric
 ------------------  ------------------------------------------  -----------------------------------
 1. RAW Stress       Interleaved dependent load-after-store      Speculative load issue & bypass
 2. Branch Torture   Dense alternating high-entropy branches     Gshare recovery & checkpoint stress
 3. Pointer-Chasing  Deep serialized dependent memory access     L1D hit latency & MSHR concurrency
 4. Stream Memcpy    Dense consecutive load/store loop           Port 2 AGU & WBB drain throughput
 5. Queue Pressure   Tight dependency chains & bursts            FQ16, MemIQ16, IntIQ16 backpressure
 6. CoreMark 1.0     Standard embedded integer compute           Matrix, CRC, State Machine, Lists
 7. Dhrystone 2.1    Legacy reference (string/int loops)         Secondary historical reference only
 8. Linux Userspace  Context switch, system call, and page walk  Downstream platform readiness target
```

### 10.1 Empirical Measurement Rules
1. **No Simulated Projections as Fact**: IPC figures derived from analytical models or Spike simulations are classified as projections, never as CPU RTL evidence.
2. **Deterministic Cycle Counting**: Workload results must report exact hardware cycle counts (`CSR_MCYCLE`), instructions retired (`CSR_MINSTRET`), and the full 48-event counter log.
3. **Warm vs. Cold Reporting**: Benchmarks must explicitly distinguish cold-cache runs from steady-state iteration loops.
4. **Linux Profiling Status**: Linux userspace profiling is defined as a downstream platform readiness target; no claim of active Linux execution is made prior to FPGA/SoC integration.

---

## 11. Physical Design, Timing & Area Considerations

Milestone 5 microarchitectural structures are strictly designed to preserve high operating frequency and synthesizability:
1. **Qualitative Timing Goals**:
   - Preserve single-cycle issue and wakeup selection in IntIQ16 and MemIQ16 where feasible;
   - Avoid long combinational ripple paths across issue queue selection matrices by using hierarchical tree reduction;
   - Avoid cross-queue combinational dependency checks between MemIQ and IntIQ;
   - Permit registered violation detection (Stage M2) for Store AGU CAM queries to isolate physical memory address comparisons from critical execution paths.
2. **No Premature Technology Claims**:
   - All references to specific clock frequencies (e.g. 1.0 GHz) or process nodes (e.g. 28nm, Artix-7) are removed as binding architectural constraints. Frequency characterization is deferred to post-synthesis STA.
3. **PRF Port Invariant**:
   - Unified PRF80 maintains exactly 6 read ports and 3 write ports. No additional ports are introduced by M5.
4. **VIPT Cache Geometry Preserved**:
   - Both L1I and L1D remain strictly 16 KiB, 4-way set-associative with 64-byte lines. Way size is exactly `4096 bytes ≤ 4 KiB`, maintaining absolute VIPT synonym safety.

---

## 12. Verification & Validation Architecture

Milestone 5 verification establishes independent validation of performance features and guarantees zero regression of frozen functional correctness.

### 12.1 Mandatory Directed & Adversarial Properties Matrix
The verification testbench must formally prove compliance across the following mandatory properties:

1. `PROP_SPEC_LOAD_SUCCESS`: Load issues speculatively past non-aliasing unresolved store; executes without stall or replay.
2. `PROP_EXACT_RAW_VIOLATION`: Load issues past older unresolved store; store later resolves to identical address and width; violation detected.
3. `PROP_CONTAINED_OVERLAP`: Store writes sub-word inside speculative load's address window; violation detected.
4. `PROP_LOAD_IN_STORE_OVERLAP`: Load reads sub-word inside speculative store's address window; violation detected.
5. `PROP_PARTIAL_OVERLAP`: Aligned 8-byte load vs aligned 4-byte store sub-range overlap unsupported by canonical forwarding; violation detected.
6. `PROP_SAME_LINE_NO_OVERLAP`: Load and store access different words within the same 64-byte line; zero violation triggered.
7. `PROP_ADJACENT_BYTE_NO_OVERLAP`: Store writes byte `N`; load reads byte `N+1`; zero violation triggered.
8. `PROP_DIFF_LINE_NO_OVERLAP`: Disjoint cache lines; zero violation triggered.
9. `PROP_MULT_UNRESOLVED_STORES`: Load issues past 4 older unresolved stores; correctly tracks dependency against all 4.
10. `PROP_MULT_SPEC_LOADS`: 3 consecutive loads issue past unresolved store; one conflicts; precise rollback restores only the conflicting load.
11. `PROP_ROB_WRAP_SAFETY`: Store-load age comparison remains strictly correct across circular ROB pointer wrapping.
12. `PROP_LQ_WRAP_SAFETY`: Load Queue entry allocation and deallocation remain correct across circular pointer wrapping.
13. `PROP_STALE_VIOLATION_REJECT`: Stale violation `{rob_idx, rob_epoch}` arriving after ROB slot reuse is silently ignored.
14. `PROP_LOAD_WB_BEFORE_STORE`: Load completes and writes PRF before older store resolves; entry remains in LQ until `older_store_checks_complete(load)`.
15. `PROP_HEAD_HOLD_STRUCTURAL`: Load at ROB head holds retirement structurally while any relevant older-store violation check is in-flight (no fixed cycle timer).
16. `PROP_LQ_DEALLOC_ON_RETIRE`: Load deallocates at retirement once `older_store_checks_complete(load)` without waiting for older stores to drain from SQ.
17. `PROP_DEPENDENT_ALU_CHAIN`: Speculative load wakes dependent ALU chain; violation squashes entire dependent chain without PRF corruption.
18. `PROP_DEPENDENT_BRANCH`: Speculative load feeds conditional branch; violation squashes branch and restores checkpoint cleanly.
19. `PROP_YOUNGER_STORE_SAFE`: Speculative load followed by younger store; violation squashes younger store before it drains to memory.
20. `PROP_FAULTING_SPEC_LOAD`: Load raises Load Page Fault (Cause 13) speculatively; violation occurs; violation suppresses fault; re-executes conservatively.
21. `PROP_EXCEPTION_VIOLATION_SAME`: Load has both exception and violation; memory violation takes strict precedence.
22. `PROP_MMIO_EXCLUSION`: MMIO load never issues speculatively past unresolved store; executes strictly at ROB head with empty SQ.
23. `PROP_LR_EXCLUSION`: `LR.W/D` never issues speculatively past unresolved store; executes non-speculatively.
24. `PROP_SC_AMO_EXCLUSION`: `SC` and `AMO` execute non-speculatively at ROB head with empty SQ.
25. `PROP_REPLAY_SAFE_D0_CONSUME`: One-shot `replay_safe` token consumed atomically at Stage D0 for matching PC; travels with dynamic uop; forward progress guaranteed.
26. `PROP_REPEATED_ALIAS_LOOP`: Livelock test verifies zero infinite replay loops under continuous adversarial aliasing.
27. `PROP_BRANCH_RECOVER_VIOLAT`: Concurrent branch recovery and memory violation notification arbitrated cleanly.
28. `PROP_FULL_FLUSH_CONCURRENT`: Full architectural flush concurrent with violation set clears violation bit safely.
29. `PROP_FQ16_WRAP_FULL_FLUSH`: FQ16 verifies 16-entry fill, empty, wrap, and single-cycle flush without pointer corruption.
30. `PROP_MEMIQ16_FULL_DRAIN`: MemIQ16 verifies 16-entry fill, backpressure, and drain without deadlock.
31. `PROP_OLDEST_READY_WRAP`: Oldest-ready selection verifies correct age priority across circular ROB wrapping.
32. `PROP_HPM_SELECTOR_MAPPING`: All 48 event sources verifiable across all 29 programmable `mhpmeventN` selectors; privilege mode checks verified.
33. `PROP_CPI_CONSERVATION`: Master 8-category cycle conservation identity `sum_k=1^8 C_k == Δmcycle` verified over every interval.

### 12.2 Truly Independent Random Memory Reference Model
Randomized verification must utilize an independently maintained reference model that:
1. Maintains separate architectural register and memory state arrays;
2. Tracks program-order store addresses and data independently of DUT execution;
3. Predicts expected load values, canonical store forwarding, and speculative load eligibility;
4. Independently models Load Queue entries, expected RAW violations, and replay redirects;
5. Validates that the final architectural state of the DUT matches the reference model bit-for-bit after 100,000 randomized operations.

---

## 13. Milestone 5 Freeze Gates & Acceptance Criteria

Milestone 5 shall be declared **FROZEN** only when all of the following criteria are satisfied:

### 13.1 Architecture Freeze Gates
- [x] **Review Disposition**: Independent adversarial review returns **P0 = 0, P1 = 0, P2 = 0, P3 = 0** (`SLICE-1 M5 FINAL FOCUSED ARCHITECTURE RE-REVIEW COMPLETE — READY TO FREEZE`). M5 architecture is declared **FROZEN**.

### 13.2 Functional Correctness Implementation Gates
- [ ] **Full Predecessor Regression Clean**: All M1, M2, M3, and M4 directed tests (170+ tests) pass 100%.
- [ ] **M5 Mandatory Properties Clean**: All 33 mandatory properties in Section 12.1 pass 100%.
- [ ] **Randomized Torture**: 100,000 randomized operations across multiple seeds pass with 0 assertion failures, 0 memory mismatches, and 0 watchdog timeouts.
- [ ] **Verilator Lint**: Zero warnings, zero errors under strict lint rules (`tools/run_s1_lint.py`).

### 13.3 Instrumentation & Profiling Gates
- [ ] **Counter Integrity**: All 48 hardware performance event sources validated against cycle traces.
- [ ] **Zero Cycle Leakage**: Formal assertion confirms `sum_k=1^8 C_category == Δmcycle` across all benchmark runs.

### 13.4 Performance Characterization Gates
- [ ] **Benchmark Execution**: Standard microarchitectural kernels and CoreMark run reproducibly on DUT in Verilator.
- [ ] **Empirical Profiling Report**: Formal bottleneck characterization report generated documenting measured IPC and CPI decomposition. *(Note: Achieving `≥ 1.2` IPC is an empirical evaluation goal, not an unconditional correctness freeze gate).*

---

## 14. Future Architectural Evolution Path (Milestone 6 and Beyond)

Following the stabilization of Milestone 5, the Fursoy core roadmap projects the following milestone phases:
- **Milestone 6 (Advanced Branch Prediction & Instruction Stream Optimization)**:
  - Evaluation of TAGE-family branch predictors under equal area budgets.
  - Next-line branch prefetching and predecode bit caching.
  - Return Address Stack depth expansion and speculative call-stack hardening.
- **Milestone 7 (Multi-Banked L1D, Dual AGU & Coherent Interconnect Boundary)**:
  - Transition to dual AGU on Port 2 and Port 3 with multi-banked synonym-safe L1D.
  - Integration of a protocol-neutral coherent caching-agent boundary.
- **Milestone 8 (Standard Floating-Point & Vector Execution Extensions)**:
  - RV64F/D pipelined FMA units and dedicated Floating-Point Register File (FPRF).
  - RVV 1.0 vector processing unit (VPU) with decoupled vector issue queues.

---

## 15. Conclusion & Architecture Definition Sign-Off
Milestone 5 architectural specification v1.2 has successfully passed independent adversarial re-review (P0=0, P1=0, P2=0, P3=0; marker `SLICE-1 M5 FINAL FOCUSED ARCHITECTURE RE-REVIEW COMPLETE — READY TO FREEZE`) and is formally **FROZEN**. It strictly separates older-store SQ lifetime from RAW disambiguation via the `older_store_checks_complete(load)` predicate, establishes the live-epoch ROB violation qualification contract, introduces a structural retirement interlock in place of arbitrary cycle timers, localizes one-shot replay-safe token consumption to Stage D0, refines FQ16 dual-push admission, clarifies HPM privilege policy and 48-event table columns, and establishes an 8-category single-owner CPI decomposition engine that prevents productive commit masking. The specification is frozen as the authoritative, binding implementation blueprint for Milestone 5 Phase A and Phase B.
