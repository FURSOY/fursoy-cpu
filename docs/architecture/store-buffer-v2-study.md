# Fursoy Slice-0 Store Buffer v2 — Depth Scaling Architecture and Performance Study

Status: **FROZEN — ARCHITECTURE & RTL IMPLEMENTATION ACCEPTED**  
Normative Baselines:
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 (RV64I base, "Zifencei", "A" v2.1)
- RISC-V Memory Consistency Model (RVWMO)
- `docs/architecture/store-buffer-v1.md` (Frozen Store Buffer v1 architectural contract)
- `docs/architecture/l1d-cache-v1.md` (Frozen L1 Data Cache v1 contract)
- `docs/architecture/l1d-srb-v1.md` (Frozen L1D Store Refill Buffer v1 contract)
- `docs/architecture/l1d-refill-opt-v1.md` (Frozen L1D Early Restart v1 contract)
- `docs/architecture/pipeline-s0-v1.md` (Frozen Slice-0 2-stage F | E in-order pipeline contract)
- `results/perf-l1d-er-s0.json` (Authoritative post-L1D-ER performance profile)
- `rtl/core/fursoy_s0_sb.sv` (Frozen Store Buffer v1 production RTL)

---

## 1. Scope, Authority, and Objectives

### 1.1 Study Purpose
This study provides an exhaustive architectural, performance, PPA, timing, correctness, and verification evaluation of **Store Buffer Depth Scaling** for the single-hart Fursoy Slice-0 processor.

Following the freeze of L1D Load Critical-Word Early Restart (L1D-ER v1), the authoritative mutually exclusive cycle partition (`results/perf-l1d-er-s0.json`, 24,227,980 cycles total) established that **Store Buffer Full Backpressure is the single largest remaining pipeline stall bottleneck**:
- **Store Buffer Full Stalls**: **2,681,368 cycles** (**11.0672% of total execution time**; **28.758% of all non-retirement stall cycles**).
- **Secondary Bottleneck**: L1I demand refill (2,335,757 cycles, 9.6407%).
- **Third Bottleneck**: SRB RAW load stalls (1,158,598 cycles, 4.7821%).

### 1.2 Mandatory Architectural Guardrails
1. **Single Optimization Variable**: The only optimization parameter investigated in this study is **Store Buffer entry depth** (`N ∈ {4, 8, 12}`).
2. **Zero Production RTL Modification**: This is strictly an architectural and performance evaluation. Production RTL remains bit-for-bit identical to the frozen L1D-ER v1 baseline.
3. **Drop-In Semantic Replacement**: The candidate architecture must preserve 100% of frozen Store Buffer v1 architectural contracts, memory visibility boundaries, and precise exception rules without requiring functional interface redesign of L1D, SRB, or SoC.
4. **Historical Correctness Lesson**: Architectural side effects (CSR, MRET, SRET, PMP, reservation invalidation) must remain strictly coupled to the authoritative `commit_fire` event, eliminating multi-cycle stall leakage.

---

## 2. Reconstructed SB-v1 Semantics and Frozen Invariants

From the repository architecture documents (`docs/architecture/store-buffer-v1.md`, `docs/architecture/l1d-srb-v1.md`) and verified production RTL (`rtl/core/fursoy_s0_sb.sv`, `rtl/core/fursoy_s0_core.sv`), the exact frozen semantics are reconstructed:

### 2.1 Enqueue Eligibility, `commit_fire`, and Full-Buffer Release Timing
- **Eligibility Predicate**:
  An instruction in Stage E is an ordinary DRAM store if and only if:
  `is_ordinary_dram_store = fe_q.valid && !fe_q.fetch_error && lsu_valid && lsu_store && !lsu_sc && !lsu_amo && !lsu_misaligned && !insn_illegal && dtrans_valid && !dtrans_busy && !dtrans_page_fault && dtrans_pmp_allow && is_dram`
  All synchronous exceptions (misaligned address, illegal instruction, page fault, PMP fault) and all MMIO transactions are evaluated in Stage E *before* enqueue eligibility. Faulting instructions never enter the Store Buffer.
- **Enqueue & Commit Handshake**:
  - `enqueue_stall_o` is asserted when `count_q == SB_DEPTH` and tail merging is not possible.
  - Stage E stall incorporates `store_sb_stall = is_ordinary_dram_store && sb_enqueue_stall`.
  - When `stall_e` is 0, `commit_fire` pulses for exactly 1 cycle.
  - On this exact cycle, the store enqueues into `valid_q[tail_q]` (or merges into `tail_prev_idx`), and Stage E pipeline register `fe_q` advances.
  - If `enqueue_stall_o` is 1, `stall_e` is asserted, holding `fe_q` frozen, inhibiting `commit_fire`, and suppressing all architectural side effects.
- **Full Buffer Release Timing (P1-1 Frozen Semantics)**:
  `enqueue_stall_o = (count_q == SB_DEPTH) && !can_merge_tail`.
  Crucially, `enqueue_stall_o` does **not** combinationally evaluate `l1d_store_ack_i`. When the buffer is full (`count_q == SB_DEPTH`), tail merge is not possible, and `l1d_store_ack_i` arrives in the same cycle:
  - **Cycle N (Full Buffer Stall & Deallocation)**:
    - SB is full (`count_q == SB_DEPTH`).
    - `enqueue_stall_o = 1`.
    - Stage E stalls (`stall_e = 1`, `commit_fire = 0`).
    - The incoming store is held in Stage E; it **must not** enqueue.
    - All architectural side effects and reservation invalidation remain suppressed.
    - `l1d_store_ack_i == 1` authoritatively pops the current head on the clock edge.
    - `count_q` transitions `SB_DEPTH → SB_DEPTH - 1` (e.g. `8 → 7`).
  - **Cycle N+1 (Stall-Release Enqueue)**:
    - SB is no longer full (`count_q < SB_DEPTH`).
    - `enqueue_stall_o = 0` (assuming no other stall condition).
    - Stage E commits and enqueues the held store exactly once.
    - `count_q` transitions back `SB_DEPTH - 1 → SB_DEPTH` (e.g. `7 → 8`).
  - **Prohibition of Combinational Pop Shortcut**:
    Optimizing `enqueue_stall_o` to include `!l1d_store_ack_i` is strictly forbidden. Such a term would inject a critical combinational path from L1D memory response through SB stall logic directly into `stall_e` and `commit_fire`, violating the frozen SB-v1 timing contract. The intentional 1-cycle full-buffer release bubble is a preserved, frozen architectural invariant.

### 2.2 Strict Tail-Only Merging Rule (P0-1)
- Merging is permitted **strictly into the youngest unissued tail entry** (`tail_prev_idx = tail_q - 1`):
  `can_merge_tail = (count_q > 0) && valid_q[T] && !issued_q[T] && !(grant_sb_drain_o && (T == head_q)) && (paddr_q[T] == enqueue_pa_i[55:3])`
- Merging into older entries, middle entries, or the active/draining head is strictly forbidden.
- On merge, byte-mask accumulation and younger-byte overwrite precedence occur combinationally:
  `data_q[T][8b+7:8b] ← in_byte_mask[b] ? in_fmt_data[8b+7:8b] : data_q[T][8b+7:8b]`
  `byte_mask_q[T] ← byte_mask_q[T] || in_byte_mask`
- `tail_q` does not advance; `count_q` does not increment.

### 2.3 Immediate Reservation Invalidation (P0-2)
- Ordinary stores invalidate the LR/SC reservation (`res_invalidate_o`) on the **exact cycle of accepted enqueue/retirement**:
  `res_invalidate_o = enqueue_valid_i && !enqueue_stall_o && res_valid_i && (enqueue_pa_i[55:6] == res_granule_pa_i)`
- It is never deferred to drain time, and never asserted during stall cycles.

### 2.4 Ghost Window Elimination (P0-3)
- `valid_q[head_q]` remains asserted and actively participates in load RAW hazard checking across all phases of drain, L1D lookup, DRAM victim writeback, line refill, and array installation.
- Deallocation occurs **strictly upon positive acknowledgement** from L1D: `l1d_store_ack_i == 1`. Request acceptance (`sb_req_ready_i`) never deallocates an entry.

### 2.5 Conservative Stall-on-RAW
- Stage-E loads compare 53-bit physical doubleword address `load_check_pa_i[55:3]` against all valid entries in the Store Buffer:
  `sb_raw_hazard_comb = load_check_valid_i && OR_i=0^SB_DEPTH-1 (valid_q[i] && (paddr_q[i] == load_check_pa_i[55:3]))`
- In parallel, loads check coarse 64-byte line hazard against SRB:
  `srb_raw_hazard_comb = load_check_valid_i && srb_busy_i && (load_check_pa_i[55:6] == srb_line_pa_i)`
- If either hazard is active, the load stalls Stage E until all matching entries have drained and acknowledged.

### 2.6 Deterministic Single-Port Arbitration (P1-1)
- Single physical access port to L1D array shared between Stage-E loads and SB drain.
- Stage-E load has priority if `count_q < SB_DEPTH` and `starve_count_q < 4`.
- SB drain has absolute priority if: (1) Stage E has no load, (2) buffer is full (`count_q == SB_DEPTH`), (3) starvation threshold reached (`starve_count_q >= 4`), or (4) load is RAW-conflicted.
- Starvation counter increments when an eligible SB drain is deferred for a Stage-E load; resets to 0 upon drain grant or empty buffer.

### 2.7 System Serialization Integration
- Non-buffered transactions: `SC.W`, `SC.D`, `LR.W`, `LR.D`, AMOs, MMIO stores, and MMIO loads stall Stage E until `memory_drained` (`sb_empty && !l1d_srb_busy && l1d_idle`).
- Fences and Maintenance: `FENCE`, `FENCE.I`, `SFENCE.VMA`, PMP CSR writes, `MRET`, `SRET`, and traps stall until `memory_drained` before performing array flush or vectoring.

---

## 3. Root-Cause Analysis of the 2.681M SB-Full Stall Cycles

### 3.1 Mutual-Exclusive vs Diagnostic Causal Accounting
The 2,681,368 SB-full cycles represent an exact, non-overlapping partition of total execution time (11.0672%).

Diagnostic breakdown of the blocker state during these 2,681,368 full cycles:
| Blocker Cause | Cycles | Share of SB-Full Pool | Primary Microarchitectural Mechanism |
| :--- | ---: | ---: | :--- |
| **SRB Busy (`srb_busy_q`)** | **2,527,770** | **94.2717%** | L1D store miss captured in SRB; background DRAM victim writeback + line refill locks SB drain arbiter |
| **Drain Active / Granted** | 122,950 | 4.5853% | SB drain granted to L1D; store completing array write |
| **L1D FSM Busy (Non-SRB)** | 2,682 | 0.1000% | L1D busy servicing clean miss or maintenance |
| **DRAM Bus Contention** | 0 | 0.0000% | Handled via SRB/L1D protocol |
| **Residual / Unclassified** | 27,966 | 1.0430% | Transitory handshake and handoff edges |

### 3.2 The SRB Busy Lockup Mechanism
The overwhelming root cause (94.27%) of Store Buffer full stalls is **downstream backpressure from the single-entry Store Refill Buffer (SRB)**:
1. When a drained store misses in L1D, it is captured into the SRB.
2. The SRB asserts `srb_busy_q = 1` for the duration of:
   - 64-byte dirty victim writeback to DRAM (8 beats `≈ 8 ... 14` cycles).
   - 64-byte line refill from DRAM (8 beats `≈ 16 ... 20` cycles).
   - Total SRB lockup duration: **25 to 35 cycles**.
3. Under the frozen contract (`docs/architecture/l1d-srb-v1.md` §3.3), Store Buffer draining is **strictly suspended** while `srb_busy_q == 1`:
   `sb_drain_eligible = (count_q > 0) && l1d_idle_i && !srb_busy_i`
4. While SRB is busy, the Store Buffer cannot drain a single store—even stores that would result in L1D cache hits!
5. In SB4, after 4 stores are retired in Stage E, the 5th store encounters `sb_enqueue_stall = 1`.
6. Stage E stalls for the remainder of the ~25-cycle SRB refill duration.

### 3.3 Burst Absorption vs Drain Postponement
A critical distinction must be established:
- **Genuine Burst Absorption**: If a code sequence executes a cluster of 5–8 stores followed by substantial independent ALU/branch computation, a deeper buffer (SB8/SB12) absorbs all stores without stalling Stage E. The subsequent ALU instructions execute concurrently while SRB finishes its background refill.
- **Unavoidable Postponement**: If a code sequence is store-dense (e.g., `memset`, block copies, page zeroing) where stores arrive every 1–2 cycles, expanding depth from 4 to 8 merely delays the pipeline stall by 4 cycles. Once the 8th entry is allocated, the core stalls for the remaining `25 - 4 = 21` cycles. Furthermore, once SRB finishes, 8 dirty stores must drain sequentially, increasing subsequent drain tail latency and the probability of a secondary store miss.

---

## 4. Empirical Occupancy and Episode Analysis

### 4.1 Measured SB4 Occupancy Distribution
From the frozen post-L1D-ER Linux 6.6.50 benchmark run (`results/perf-l1d-er-s0.json`):
- Total Runtime: 24,227,980 cycles.
- Total Committed Instructions: 14,904,330.
- Total Ordinary DRAM Stores: 2,540,553.
- Enqueues into SB: 2,538,881 (99.934%).
- Tail Merges: 1,672 (0.066%).

| Occupancy State | Measured Cycles | Share of Execution | Physical Interpretation |
| :---: | ---: | ---: | :--- |
| **0 entries** | 17,537,992 | 72.3873% | Core is non-store intensive; SB is completely empty |
| **1 entry** | 2,315,995 | 9.5592% | Steady-state streaming store drain |
| **2 entries** | 679,672 | 2.8053% | Minor store cluster, quickly absorbed |
| **3 entries** | 996,922 | 4.1148% | Pre-full accumulation during L1D busy |
| **4 entries (Full)** | **2,697,399** | **11.1334%** | Saturated buffer (2.681M cycles stall Stage E) |
| **Sum (Disjoint Exact)**| **24,227,980** | **100.0000%** | Exact match with total runtime |

### 4.2 Full Episode Duration Histogram
- Total Full Episodes: 150,920 episodes.
- Mean Episode Duration: 17.7668 cycles.
- Min Duration: 1 cycle; Max Duration: 25 cycles.

| Episode Duration Range | Episode Count | Share of Episodes | Characterization |
| :---: | ---: | ---: | :--- |
| **1 to 4 cycles** | 28,774 | 19.066% | Transient bursts during short L1D arbitration or hit latency |
| **5 to 10 cycles** | 1,488 | 0.986% | Intermediate transitions |
| **11 to 20 cycles** | 12,327 | 8.168% | Clean L1D store misses (~18-cycle refill) |
| **21 to 50 cycles** | **108,331** | **71.780%** | **Dirty L1D store misses (victim eviction + refill = ~25 cycles)** |
| **> 50 cycles** | 0 | 0.000% | Bounded forward progress confirmed |

Over 71.7% of full episodes last between 21 and 25 cycles, perfectly coinciding with dirty store miss servicing in SRB.

### 4.3 Coalescing and Merging Headroom
- Same-doubleword matches while full: **78 cycles** (**0.002909%** of full stall cycles).
- Exact-address matches while full: **18 cycles** (**0.000671%** of full stall cycles).
- Conclusion: Same-doubleword write coalescing opportunity is virtually nonexistent in Linux user-space execution. Deeper associative merging would provide zero measurable cycle reduction.

---

## 5. Critical Validation of the Shadow SB Model

### 5.1 Derivation of the Reported ~518k and ~1.006M Estimates
In the baseline testbench (`verification/perf_baseline_s0_tb.cpp` lines 2157–2162), the shadow model was implemented as:
```cpp
if (curr_sb_full_len > 0) {
    cur.sample_sb_full_episode(curr_sb_full_len);
    cur.shadow_sb_full_stall_cycles_d6  += (curr_sb_full_len > 2 ? curr_sb_full_len - 2 : 0);
    cur.shadow_sb_full_stall_cycles_d8  += (curr_sb_full_len > 4 ? curr_sb_full_len - 4 : 0);
    cur.shadow_sb_full_stall_cycles_d12 += (curr_sb_full_len > 8 ? curr_sb_full_len - 8 : 0);
    curr_sb_full_len = 0;
}
```
This closed-form calculation produces:
- Depth 6 avoided: 273,668 cycles (10.21%).
- Depth 8 avoided: 518,474 cycles (19.34%).
- Depth 12 avoided: 1,005,609 cycles (37.50%).

### 5.2 Architectural Evaluation of the Heuristic Shadow Model
These numbers must be understood strictly as **isolated full-episode heuristic estimates**, not physical opportunity ceilings or cycle-accurate predicted speedups. The formula assumes an infinite burst density (1 store arriving every cycle during full episodes):
1. **Underestimation on Sparse Bursts**: If a program has exactly 5 stores followed by 20 ALU instructions, SB4 stalls for ~21 cycles. An 8-entry buffer absorbs store 5 immediately, allowing all 20 ALU instructions to execute concurrently with the SRB refill. In this scenario, SB8 saves **21 cycles**, whereas the heuristic only credited **4 cycles** (`min(L, 4)`).
2. **Overestimation on Sustained Loops**: In block stores (`memset`), stores arrive continuously. Adding 4 entries only delays the stall by 4 cycles, saving exactly 4 cycles.
3. **Drain Congestion and Secondary Miss Cascades**:
   - Draining 8 entries requires 8 cycles minimum.
   - At a 7.04% store miss rate, the probability that at least one of 8 queued stores misses upon draining is:
     `P(≥ 1 miss) = 1 - (1 - 0.0704)^8 = 1 - 0.556 = 44.4%`
   - In 44.4% of deep queues, draining triggers another immediate SRB lockup, completely negating part of the absorbed benefit.
4. **Increased Load RAW Stalls**: With 8 or 12 entries, subsequent loads collide with queued stores more frequently, converting SB-full stalls into SB-RAW stalls.
5. **Measured Post-SB8 Empirical Ground Truth**:
   The old SB4 heuristic (~518,474 cycles) did not model subsequent instruction concurrency, changed queue residency, changed store clustering, emergent tail merging, or downstream timing changes. During authoritative full-workload execution (`results/perf-sb8-s0.json`), actual measured SB8 cycle savings reached **1,213,488 cycles** (a **5.0086% runtime reduction**; IPC 0.615170 `→` 0.647560), confirming that the old heuristic was an isolated under-estimate, not an upper ceiling.

---

## 6. Architecture Candidate A: SB8 (8-Entry FIFO)

### 6.1 Microarchitectural Specification
- **Storage**: 8 entries `×` 231 bits = 1,848 payload flip-flops (+924 FFs vs SB4). Including control pointers and occupancy counter (+2 FFs), total incremental storage is **~926 FFs** (934 `→` 1,860 FFs total). This is strictly an analytical structural RTL bit-count estimate; no physical synthesis evidence exists yet.
  - `valid_q[7:0]`, `issued_q[7:0]`, `paddr_q[7:0][52:0]`, `data_q[7:0][63:0]`, `byte_mask_q[7:0][7:0]`, `size_q[7:0][2:0]`, `rd_q[7:0][4:0]`, `pc_q[7:0][63:0]`, `insn_q[7:0][31:0]`.
- **Pointers & Counters**:
  - `head_q[2:0]`: 3-bit read pointer. Increments modulo 8 (`7 → 0` naturally).
  - `tail_q[2:0]`: 3-bit write pointer. Increments modulo 8 (`7 → 0` naturally).
  - `tail_prev_idx`: `tail_q - 3'd1` (natural 3-bit unsigned underflow: `0 - 1 = 7`).
  - `count_q[3:0]`: 4-bit occupancy counter (`0 ... 8`).
  - `sb_full_o`: `count_q == 4'd8`.
  - `sb_empty_o`: `count_q == 4'd0`.
- **Full-Buffer Release Bubble**: Preserves the frozen SB-v1 1-cycle stall-release bubble. When `count_q == 8`, `enqueue_stall_o` asserts unconditionally; an acknowledgement pulse `l1d_store_ack_i` on Cycle N pops the head and decrements `count_q` to 7 on the clock edge, permitting the held Stage-E store to commit and enqueue on Cycle N+1.
- **Merge Logic**: Strict tail-only unissued merge into `tail_prev_idx`. Exactly ONE 53-bit comparator.
- **RAW Detection**: 8 parallel 53-bit comparators against `load_check_pa_i[55:3]`, reduced via an 8-input OR tree (2 logic levels).
- **Arbitration**: 4-cycle starvation bound preserved identically (`starve_count_q < 3'd4`). Force drain if `count_q == 4'd8` or `starve_count_q >= 4` or RAW match.
- **Interface**: 100% plug-compatible drop-in. Core internal `sb_count` telemetry expands from `[2:0]` to `[3:0]`.

---

## 7. Architecture Candidate B: SB12 (12-Entry FIFO)

### 7.1 Microarchitectural Specification
- **Storage**: 12 entries `×` 231 bits = 2,772 flip-flops (+1,848 FFs vs SB4).
- **Pointers & Modulo Wrap**:
  - Requires 4-bit pointers `head_q[3:0]` and `tail_q[3:0]`.
  - Valid range: `0 ... 11`.
  - Explicit modulo wrap logic:
    `head_next = (head_q == 4'd11) ? 4'd0 : (head_q + 4'd1)`
    `tail_next = (tail_q == 4'd11) ? 4'd0 : (tail_q + 4'd1)`
    `tail_prev_idx = (tail_q == 4'd0) ? 4'd11 : (tail_q - 4'd1)`
  - While explicit 11 `→` 0 wrap is conventional synchronous RTL and fully verifiable, states `12 ... 15` represent an unused state space in 4-bit registers, requiring explicit verification coverage and defensive handling compared to natural power-of-two rollover.
- **Counter**: `count_q[3:0]` (`0 ... 12`). `sb_full_o = (count_q == 4'd12)`.
- **RAW Detection**: 12 parallel 53-bit comparators (636 comparator bits), reduced via an irregular 12-input OR tree (3–4 logic levels).
- **Drain Muxing**: Irregular 12-to-1 230-bit multiplexer, adding 2–3 LUT levels in FPGA.

---

## 8. Associative Merge Search Analysis

| Parameter | 4 Entries (SB4) | 8 Entries (SB8) | 12 Entries (SB12) | Full Associative CAM (8 entries) |
| :--- | :---: | :---: | :---: | :---: |
| **Merge Policy** | Tail-only | Tail-only | Tail-only | Full 8-entry parallel search |
| **PA Comparators** | 1 `×` 53-bit | 1 `×` 53-bit | 1 `×` 53-bit | 8 `×` 53-bit (424 bits) |
| **Priority Logic** | None | None | None | 8-to-3 priority encoder |
| **Write Muxing** | Tail slot only | Tail slot only | Tail slot only | 8-way byte-enable write bus |
| **Critical Path Impact**| 0 ns | 0 ns | 0 ns | Adds structural stall delay |
| **Measured Benefit** | Baseline | 0 cycles | 0 cycles | **< 78 cycles (0.0029%)** |

**Architectural Verdict**: Fully associative CAM merging is definitively rejected. Maintaining the frozen **strict tail-only merging rule** eliminates all CAM complexity while preserving 99.997% of available coalescing headroom.

---

## 9. Load RAW Search and Critical Path Timing Analysis

### 9.1 Stage-E Combinational Timing Path
In Fursoy Slice-0's 2-stage organization, the load RAW hazard check lies on one of the most critical combinational paths in the core:
```
[clk] -> fe_q.insn -> RF read (rs1) -> ALU adder (rs1 + imm) -> DTLB tag match ->
         dtrans_pa[55:3] -> SB 53-bit PA comparators -> OR reduction tree ->
         load_raw_hazard_comb -> lsu_load_stall -> stall_e -> commit_fire -> [clk]
```

### 9.2 Scaling Across Depth Options (Pre-Synthesis Structural Projections)
- **SB4**: 4 comparators (212 XORs), 4-bit OR (1 LUT level). Analytical pre-synthesis delay projection `≈ 0.45` ns.
- **SB8**: 8 comparators (424 XORs), 8-bit OR (2 LUT levels). Analytical pre-synthesis delay projection `≈ 0.68` ns (+0.23 ns structural adder). Fits cleanly within standard cycle time margins without degrading core clock target.
- **SB12**: 12 comparators (636 XORs), 12-bit OR (3 LUT levels). High fanout of `dtrans_pa` across 12 distributed register slices. Analytical pre-synthesis delay projection `≈ 0.98` ns (+0.53 ns structural adder). Directly increases timing risk on FPGA routing and tight ASIC corners.

*(Note: All timing values are analytical pre-synthesis structural projections; they do not represent physical post-synthesis/STA evidence).*

---

## 10. Implementation Structure Options

- **Option A (Fully Parallel Register Array)**:
  - RTL Complexity: Low. Standard SystemVerilog register arrays.
  - Behavior: 100% identical to frozen SB-v1 semantics.
  - Feasibility: Excellent for SB8. Clean synthesis in both ASIC and FPGA.
- **Option B (Segmented / Tree Comparison)**:
  - Breaks comparison into set-index pre-match then tag compare.
  - Adds serial clock phases; incompatible with single-cycle Stage-E execution. Rejected.
- **Option C (RAM / Distributed LUTRAM Alternative)**:
  - **Architecturally Infeasible**: RAM arrays provide at most 1 or 2 read ports. The Store Buffer contract strictly requires simultaneous parallel RAW checking across ALL entries on every load. Storing addresses in RAM is mathematically impossible without multi-cycle serialization.

---

## 11. Realistic Performance Model

Accounting for secondary effects (burst continuation, drain congestion, secondary miss probability, load RAW collision, and serialization drain tails). 

> [!NOTE]
> The performance numbers below represent **analytical engineering projections and sensitivity bands**, not cycle-accurate predicted speedups. The baseline depth-8 (~518k cycles) and depth-12 (~1.006M cycles) figures are heuristic opportunity ceilings from testbench sampling; actual wall-clock speedups will be bounded by secondary physical effects.

| Metric | Baseline SB4 (Measured) | SB8 Conservative | SB8 Expected | SB8 Optimistic | SB12 Conservative | SB12 Expected | SB12 Optimistic |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Sensitivity Band** | Measured Fact | Lower Bound | Most Plausible | Best Feasible | Lower Bound | Most Plausible | Best Feasible |
| **Net Cycles Saved** | 0 | ~250,000 | **~340,000** | ~425,000 | ~350,000 | **~550,000** | ~724,000 |
| **Total Cycles** | 24,227,980 | ~23,978,000 | **~23,888,000** | ~23,803,000 | ~23,878,000 | **~23,678,000** | ~23,504,000 |
| **Projected IPC** | 0.61517 | ~0.6216 | **~0.6240** | ~0.6262 | ~0.6242 | **~0.6295** | ~0.6341 |
| **Net Runtime Delta** | Baseline | ~-1.0% | **~-1.4%** | ~-1.75% | ~-1.4% | **~-2.3%** | ~-3.0% |
| **Projection Basis** | Empirical Profile | Sensitivity Band | Sensitivity Band | Sensitivity Band | Sensitivity Band | Sensitivity Band | Sensitivity Band |

---

## 12. Structural PPA and Timing Risk Analysis

| Component / Metric | SB4 (Frozen Baseline) | SB8 (Candidate A) | SB12 (Candidate B) |
| :--- | :---: | :---: | :---: |
| **Payload Storage (FFs)** | 924 FFs (4 `×` 231) | 1,848 FFs (+100%) | 2,772 FFs (+200%) |
| **Pointers & Counters (FFs)** | 10 FFs | 12 FFs (+2 FFs) | 14 FFs (+4 FFs) |
| **Total Flip-Flops** | 934 FFs | **1,860 FFs (+99.1%)** | **2,786 FFs (+198.3%)** |
| **Merge Comparators** | 1 `×` 53-bit | 1 `×` 53-bit (0 growth) | 1 `×` 53-bit (0 growth) |
| **RAW Comparators** | 4 `×` 53-bit (212 bits) | 8 `×` 53-bit (424 bits) | 12 `×` 53-bit (636 bits) |
| **Drain Multiplexer** | 4:1 (230 bits) | 8:1 (230 bits, power-of-2) | 12:1 (230 bits, irregular) |
| **FPGA Resource Projection** | ~135 LUTs, 934 FFs | ~310 LUTs, 1,860 FFs | ~550 LUTs, 2,786 FFs |
| **FPGA Timing Projection** | Pre-synthesis: Clean | Pre-synthesis: Safe (~130–140 MHz est.) | Pre-synthesis: Constrained (~105–115 MHz est.) |
| **ASIC Area Impact** | Baseline | Low | Moderate |
| **Wiring & Fanout Congestion**| Negligible | Low | High |

*(Note: Resource and timing numbers are analytical pre-synthesis structural projections. They do not constitute post-synthesis/STA physical evidence).*

---

## 13. Correctness Risk Analysis and Historical Safeguards

1. **The Historical `commit_fire` Hazard**:
   - In earlier Slice-0 development, transient Stage-E stalls allowed CSR, MRET, SRET, and PMP side effects to leak across stall cycles.
   - SB8 preserves strict gating: every architectural update requires `commit_fire == 1`.
   - In SB8, even if Stage E stalls for 25+ cycles during an SB-full episode, no architectural state change can occur.
2. **Pointer Wrap Verification**:
   - SB8 utilizes 3-bit pointers `head_q[2:0]` and `tail_q[2:0]`. Binary addition naturally wraps `7 → 0` without comparators. The state space is mathematically closed.
   - SB12 utilizes 4-bit pointers with modulo 12 wrap (`11 → 0`). While standard synchronous logic, states `12 ... 15` require explicit verification and assertion coverage to prove no illegal states can be entered.
3. **Simultaneous Enqueue and Dequeue at Non-Full vs Full**:
   - For `count_q < SB_DEPTH`: Simultaneous enqueue and dequeue is supported, advancing both pointers and holding `count_q` constant.
   - For `count_q == SB_DEPTH` (Full Buffer): In accordance with frozen SB-v1 timing, `enqueue_stall_o` asserts combinationally without observing `l1d_store_ack_i`. If an acknowledgement arrives on Cycle N, the head pops, decrementing `count_q` to `SB_DEPTH - 1` on the clock edge while Stage E stalls. The held store commits and enqueues on Cycle N+1. This 1-cycle release bubble guarantees exactly-once commitment and preserves timing boundaries.
4. **Reservation Invalidation (`LR/SC`)**:
   - Evaluated on exact enqueue cycle (`!enqueue_stall_o`). Preserved bit-for-bit.

---

## 14. Verification Architecture Matrix (SB-v2)

### 14.1 Directed Adversarial Suite Specification (38 Scenarios)
The prospective RTL implementation of SB-v2 must pass an expanded 38-scenario adversarial test suite:
- **Baseline Invariants (Scenarios 1–33)**: All 33 existing scenarios from `verification/sb_s0_tb.cpp` executed with `N=8`, verifying FIFO ordering, tail merging, RAW stalls, ghost window elimination, arbitration bounds, LR/SC invalidation, CSR/MRET/SRET isolation, and reset.
- **SB8-Specific Scenarios (Scenarios 34–38)**:
  - `SB-CAP-01`: Consecutive store burst filling all 8 entries without pipeline stall; 9th store triggers backpressure stall.
  - `SB-CAP-02` (Full-Buffer 1-Cycle Release Bubble):
    1. SB8 begins at `count == 8`.
    2. Tail merge is not possible.
    3. A new store is held in Stage E (`enqueue_valid_i == 1`).
    4. `enqueue_stall_o == 1`, `stall_e == 1`, `commit_fire == 0`.
    5. `res_invalidate_o` does NOT pulse for the held store during the full stall.
    6. The already-issued head receives `l1d_store_ack_i == 1`.
    7. Exactly one head entry pops on the clock edge; `count_q` transitions 8 `→` 7.
    8. The held Stage-E store remains intact without corruption.
    9. On Cycle N+1, `enqueue_stall_o == 0`; store commits/enqueues exactly once (`count_q` transitions 7 `→` 8).
    10. Reservation invalidation occurs exactly once on the accepted enqueue (Cycle N+1) if its granule matches.
    11. Zero RF/CSR/PMP/MRET/SRET or architectural side effects duplicate across the stall.
  - `SB-CAP-03`: Continuous circular pointer wrap across 10,000+ random store transactions.
  - `SB-CAP-04`: RAW hazard detection against entries at slots 4, 5, 6, 7 while older entries drain.
  - `SB-CAP-05`: Full 8-entry serialization drain before `SFENCE.VMA` and `PMP CSR` modification.
  - `SB-CAP-06` (Tail Merge Across Pointer Wrap):
    - Initial state: `tail_q == 3'd0`, youngest valid unissued entry is slot 7 (`tail_prev_idx == 7`).
    - Incoming store matches slot 7 `PA[55:3]`.
    - Verify: `tail_prev_idx` correctly resolves to 7 across the wrap boundary; legal merge occurs exactly once; no new entry is allocated; `tail_q` remains 0; `count_q` is unchanged; byte masks and data merge with younger-byte precedence.
  - `SB-CAP-07` (Tail Merge While Full):
    - Initial state: `count_q == 4'd8` (buffer full).
    - Incoming store matches legal youngest unissued tail entry (`tail_prev_idx`).
    - Verify: `can_merge_tail == 1`; full condition does NOT assert `enqueue_stall_o`; store commits without backpressure in Stage E; merge occurs exactly once; `count_q` remains 8; no overwrite of unrelated entries; reservation invalidation occurs correctly.
  - `SB-CAP-08` (Reservation Invalidation After Full Backpressure):
    - Initial state: SB full (`count_q == 8`).
    - Incoming store in Stage E matches active LR reservation granule (`res_valid_i == 1`, `enqueue_pa_i[55:6] == res_granule_pa_i`).
    - Verify: `res_invalidate_o` remains 0 during full stall (Cycle N); `l1d_store_ack_i` pops head; store commits/enqueues on Cycle N+1; `res_invalidate_o` pulses exactly once on Cycle N+1; reservation is cleared before subsequent SC.
- **System Regressions**:
  - Full canonical regression suite (ALU, BPU, L1I, L1D, TLB, MMU, PMP, CSR, RV64A).
  - Linux 6.6.50 cold boot to PID 1 `/init`.
  - Exact controlled A/B performance profiling against frozen post-L1D-ER baseline.

### 14.2 Mandatory Implementation-Time Testbench & Profiling Adaptations (P1-2, P2-2)
An audit of the testbenches identified hardcoded depth-4 assumptions that were mechanically adapted for SB8:
1. **Performance Testbench (`verification/perf_baseline_s0_tb.cpp`)**:
   - Widened entry loops from `i < 4` to `i < 8` for coalescing and RAW diagnostic checks.
   - Updated full-buffer detection from `count_q == 4` to `count_q == 8`.
   - Extended occupancy distribution telemetry and arrays from 5 bins (`0..4`) to 9 bins (`0..8`, `occ_0`..`occ_8`).
   - Re-anchored shadow FIFO models to real SB8 baseline (`d10`, `d12`, `d16` representing `+2, +4, +8`).
2. **Core, L1D, and SRB Testbenches (`verification/pipeline_s0_tb.cpp`, `verification/l1d_s0_tb.cpp`, `verification/srb_s0_tb.cpp`)**:
   - Mechanically adapted Store Buffer memory-helper/internal mirror loops from inspecting `i < 4` to `i < 8` so stores resident in slots 4..7 are visible to existing testbench helper logic.
   - These changes did NOT weaken tests, did NOT alter pass criteria, and did NOT change stimulus semantics.
3. **Directed SB Testbench (`verification/sb_s0_tb.cpp`)**:
   - Updated capacity checks to 8 entries; retained all canonical tests 1..33; added directed scenarios `SB-CAP-01` through `SB-CAP-08`.
4. **Strict Timing Invariance**: These instrumentation updates are strictly observational testbench adaptations; they do not alter architectural signals or core execution timing.

---

## 15. Alternatives Evaluation

1. **Store-to-Load Forwarding (STLF)**:
   - Measured target pool: Total SB RAW stall cycles are only **17,984 cycles** (**0.0742% of execution**).
   - SRB RAW stalls (1.16M cycles) are 99.1% coarse 64-byte line misses waiting on DRAM beats for other words, not store payload matches.
   - Removable cycles: <17,000 cycles (0.066% runtime).
   - STLF adds massive bypass muxing into the critical load path for negligible return. Rejected.
2. **Multi-Entry SRB / Non-Blocking L1D / Hit-Under-Miss**:
   - The root cause of 94.27% of SB-full stalls is the single-entry SRB.
   - However, redesigning SRB to support multiple MSHRs, non-blocking L1D arrays, and out-of-order writeback violates the Slice-0 in-order contract and carries massive correctness and PPA risk. This is an OoO/Slice-1 feature.
3. **L1D Dual-Porting / Drain Port Duplication**:
   - True structural load/store arbitration is only **11,326 cycles** (**0.0467% of runtime**). Dual-porting has virtually zero headroom.
4. **Conclusion**: Store Buffer depth scaling is the **only remaining low-risk, high-ROI optimization** within the architectural boundaries of Slice-0.

---

## 16. Decision Matrix and Final Recommendation

### 16.1 Direct Candidate Comparison

| Dimension | SB4 (Frozen Baseline) | SB8 (Candidate A) | SB12 (Candidate B) |
| :--- | :---: | :---: | :---: |
| **Queue Depth** | 4 entries | 8 entries | 12 entries |
| **Measured / Shadow Full Cycles** | 2,681,368 (11.07%) | 2,162,894 (avoided: 518k) | 1,675,759 (avoided: 1,006k) |
| **Expected Realistic Cycles Saved**| 0 | **~340,000 cycles** | ~550,000 cycles |
| **Expected Runtime Reduction** | Baseline | **~1.4% net reduction** | ~2.3% net reduction |
| **Expected Total Execution Cycles**| 24,227,980 | **~23,888,000 cycles** | ~23,678,000 cycles |
| **Expected IPC** | 0.61517 | **~0.6240 IPC** | ~0.6295 IPC |
| **Storage Flip-Flops** | 934 FFs | **1,860 FFs (+926 FFs)** | 2,786 FFs (+1,852 FFs) |
| **Merge Comparators** | 1 `×` 53-bit | 1 `×` 53-bit (0 growth) | 1 `×` 53-bit (0 growth) |
| **RAW Comparators** | 4 `×` 53-bit (212 bits) | 8 `×` 53-bit (424 bits) | 12 `×` 53-bit (636 bits) |
| **Drain Multiplexer** | 4:1 (230 bits) | 8:1 (clean power-of-2) | 12:1 (irregular muxing) |
| **Pointer Management** | 2-bit natural binary wrap| 3-bit natural binary wrap| 4-bit non-power-of-2 modulo |
| **Illegal Pointer States** | 0 | **0 (mathematically closed)**| 4 states (`12 ... 15`) |
| **Timing Criticality (`F_max`)**| Baseline | **Pre-synthesis: Safe margin** | Pre-synthesis: Moderate-to-High risk |
| **FPGA LUT / FF Overhead** | ~135 LUTs / 934 FFs (pre-syn)| ~310 LUTs / 1,860 FFs (pre-syn)| ~550 LUTs / 2,786 FFs (pre-syn)|
| **Correctness & Modulo Risk** | Zero (Proven) | **Very Low (natural wrap)** | Low-Moderate (11 `→` 0 wrap verifiable)|
| **Verification Burden** | 33 passed tests | **Low-Moderate (clean wrap)**| High (non-power-of-2 state coverage)|
| **Interface Compatibility** | Baseline | **100% drop-in plug-compatible**| **100% drop-in plug-compatible**|
| **Confidence in Realization** | High | **HIGH** | Medium |

### 16.2 Architectural Selection
The architecture study concludes with a single, unambiguous recommendation:

`RECOMMEND SB8`

**Architectural Justification**:
1. **Optimal ROI Balance**: SB8 captures the steep, high-return portion of the burst absorption curve (~340k realistic cycles saved, ~1.4% wall-clock reduction) for a modest investment of 926 flip-flops.
2. **Binary Mathematical Elegance**: 3-bit pointers wrap naturally (`7 → 0`), eliminating all non-power-of-two modulo comparators and illegal pointer states.
3. **Timing Safety**: 8 parallel 53-bit comparators and an 8-bit OR reduction tree fit cleanly within the critical Stage-E DTLB-to-commit timing budget without compromising core clock frequency. SB12 adds 50% more comparator fanout and irregular 12-to-1 multiplexing, creating substantial `F_max` risk.
4. **Diminishing Returns of SB12**: Beyond depth 8, the marginal gain drops significantly because 94.27% of stalls remain fundamentally bounded by the single-entry SRB refill latency.

---

## 17. Slice-0 Stopping Criterion

### 17.1 Definitive Milestone Assessment
Following the implementation and verification of SB8, **Fursoy Slice-0 should cease major microarchitectural performance optimizations**.

### 17.2 Architectural Rationale
1. **Core In-Order Limits Reached**: Slice-0 is a simple 2-stage in-order processor. With BPU, L1I-ER, L1I-NLP, L1D, SRB, L1D-ER, and SB8, the design will achieve **~0.624 IPC** on a complete full-boot Linux 6.6.50 server workload—an exceptional result for a 2-stage scalar core.
2. **Exhaustion of Low-Risk Headroom**:
   - Useful instructions: ~62.4% of cycles.
   - Remaining stalls are dominated by fundamental physics:
     - L1I misses on cold/unpredictable code (~9.6%).
     - L1D DRAM load miss latency (~8.9%).
     - SRB RAW stalls (~4.8%).
     - Branch mispredictions on unpredictable jumps (~1.4%).
3. **The Slice-1 Mandate**:
   Attempting to squeeze further performance out of Slice-0 by introducing multi-issue, out-of-order execution, non-blocking caches, multiple MSHRs, or store-to-load forwarding would destroy the simplicity, verification cleanliness, and timing closure of Slice-0. Such mechanisms belong fundamentally in **Fursoy Slice-1**.
4. **Immediate Post-SB8 Roadmap**:
   Following SB8 freeze, engineering focus should pivot entirely to:
   - Exhaustive adversarial and randomized verification hardening.
   - Comprehensive multi-AI bug hunting from clean slate.
   - Interactive Linux userspace validation (BusyBox shell via UART).
   - FPGA synthesis, timing closure, and physical board deployment.
