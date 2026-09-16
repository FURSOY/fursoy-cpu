# Fursoy Slice-0 L1D Load Critical-Word Early Restart (L1D-ER v1) Architectural Contract

**Status:** ACCEPTED AND RE-FROZEN — RTL AUTHORIZED FOR IMPLEMENTATION; INDEPENDENT RTL REVIEW REQUIRED AFTER IMPLEMENTATION  
**Milestone:** L1D Load Critical-Word Early Restart v1 (L1D-ER v1) — Architecture Specification  
**Target:** Fursoy Slice-0 (In-Order 2-Stage [F | E] Core)  
**Normative Baselines:**
- `docs/architecture/l1d-cache-v1.md` (Frozen L1 Data Cache v1 Contract)
- `docs/architecture/store-buffer-v1.md` (Frozen Store Buffer v1 Contract)
- `docs/architecture/l1d-srb-v1.md` (Frozen Store Refill Buffer v1 Contract)
- `docs/architecture/pipeline-s0-v1.md` (Frozen Slice-0 2-Stage Pipeline Contract)
- `docs/architecture/branch-prediction-v1.md` (Frozen Branch Prediction Unit v1 Contract)
- `docs/architecture/l1i-cache-v1.md` (Frozen L1 Instruction Cache v1 Contract)
- `docs/architecture/l1i-refill-opt-v1.md` (Frozen L1I-ER v1 Contract)
- `docs/architecture/l1i-nlp-v1.md` (Frozen L1I-NLP v1 Contract)
- `docs/architecture/sv39-tlb-v1.md` (Frozen Sv39 TLB v1 Contract)
- `docs/architecture/sv39-mmu-v1.md` (Frozen Sv39 MMU & PTW Contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection Contract)
- `docs/architecture/rv64a-v1.md` (Frozen RV64A Atomic Extension Contract)
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 (RV64I base, Zicsr, Zifencei, RV64A)
- RISC-V Memory Consistency Model (RVWMO)

**Performance Baseline:** Frozen Post-L1I-NLP Ground Truth (`results/perf-nlp-s0.json`):
- Total Cycles: **24,810,759**
- Total Commits: **14,902,391**
- IPC: **0.600642** | CPI: **1.664884**
- Residual Unclassified Cycles: **0 (0.0000%)**
- Dominant Stall Pools:
  1. L1D Load Miss DRAM Latency: **2,782,023 cycles** (11.21% of execution: 1,608,270 dirty refill + 857,809 dirty eviction + 315,944 clean refill)
  2. Store Buffer Full Backpressure: **2,676,422 cycles** (10.79% of execution; 94.40% locked by `srb_busy`)
  3. L1I Demand Miss / Refill Latency: **2,337,828 cycles** (9.42% of execution)
  4. SRB RAW Load Stalls: **1,158,409 cycles** (4.67% of execution)

---

## 1. Scope, Milestone Separation, and Architectural Authority

### 1.1 Architectural Scope and Objective
This document specifies the authoritative hardware architecture contract for **L1 Data Cache Load Critical-Word Early Restart v1 (L1D-ER v1)** for the Fursoy Slice-0 processor.

The sole optimization objective in v1 is:
$$\textbf{Early completion and retirement of the original ordinary demand load instruction only}$$

Under the baseline architecture, an ordinary demand load instruction that misses in L1D stalls Stage E across the entire miss lifecycle:
1. Dirty victim eviction burst (8 beats, if victim line is valid and dirty),
2. Demand line refill burst (8 beats from DRAM in fixed sequential $0 \to 7$ order),
3. Final 1-cycle cache line installation into SRAM arrays (`INSTALL`).

Under L1D-ER v1, as soon as the specific requested 64-bit critical doubleword arrives from the memory interconnect and is captured into registered refill storage, the ordinary load receives its formatted data via a persistent handshake and retires to the architectural register file, allowing Stage E to resume execution of independent non-memory instructions while the remaining trailing beats of the 64-byte line refill continue in the background.

### 1.2 Conservative v1 Interface Boundary (P0-2 Resolution)
To preserve the frozen Store Buffer, Core pipeline, and single-port SRAM array contracts without introducing unverified structural interfaces:
1. **No Hit-Under-Refill:** Resident cache hits under active trailing refill are **strictly prohibited** in v1. `l1d_idle_o = 1'b0` remains asserted throughout the entire active and trailing refill lifecycle until the line finishes `INSTALL`.
2. **Subsequent Loads Stall:** Any subsequent load instruction that enters Stage E during trailing refill observes `l1d_idle_o == 0` and **stalls Stage E** until `INSTALL` completes.
3. **Store Buffer Drains Stall:** All Store Buffer drains to L1D are **suspended** while a trailing refill is active (`grant_sb_drain_o = 1'b0` / `l1d_issue_ready_o = 1'b0`). Selective SB draining based on address comparison is excluded from v1.
4. **Independent Instruction Overlap Only:** During trailing refill, Stage E may only execute independent non-memory instructions (ALU operations, integer branches, CSR operations, shifts) that do not require access to L1D.
5. **Single Miss Concurrency:** L1D handles strictly at most one outstanding memory transaction at any time.

### 1.3 Out-of-Scope and Explicitly Deferred Features
- **No Functional RTL Implementation in this Milestone:** Architecture specification only. Functional RTL modifications are strictly unauthorized.
- **No Stage-F BTB/BPU Changes:** Branch Prediction Architecture & RTL is frozen and verified. The ~348k branch redirect bubbles represent fundamental post-BPU residual behavior, not an unaddressed core deficiency.
- **No L1D Dual-Porting:** Directory and data SRAM arrays remain strictly single-ported (1 Read/Write port).
- **No Store-to-Load Forwarding (STLF):** STLF CAM comparators and byte-forwarding muxes remain deferred.
- **No Store Buffer (SB) Depth Expansion:** SB depth remains 4 entries in this milestone.
- **No Critical-Word-First (CWF) Bus Protocol Changes:** The memory bus protocol remains fixed ascending sequential ($0 \to 7$).
- **No Asynchronous Dirty Eviction Buffer:** Dirty victim writeback remains strictly synchronous prior to demand refill issue.

### 1.4 Strict Architectural Invariants
1. **Registered Staging Invariant (P1-4):** Load data presented to Stage E is sourced exclusively from registered refill storage, never from combinational/transient external `dmem_rsp_data_i` lines.
2. **Persistent Handshake Invariant (P0-1):** Load retirement is governed by a persistent `er_retire_valid_q` handshake that holds stably across any number of Stage-E stall cycles and marks consumption only upon the authoritative architectural transfer event (`commit_fire`).
3. **Atomic Main Directory Publication Invariant:** The main L1D directory valid bit (`valid_q[set][way]`) and Tree-PLRU state update if and only if all 8 beats of the line have arrived without error and install at `INSTALL`. Partially refilled lines are never marked valid in the directory.
4. **Strict Single-Port Datapath Adherence:** The L1D SRAM array is accessed by at most one operation per cycle. Directory installation of a refilled line executes as an authoritative 1-cycle write with unconditional local priority.
5. **No Retroactive Synchronous Exceptions (P1-1):** Once an early-restarted load commits to the architectural register file, subsequent errors on trailing beats cannot forge a retroactive synchronous trap. Trailing errors trigger fatal platform errors.
6. **Ordinary Load Qualification (P0-3):** Early restart is restricted exclusively to ordinary loads (`!req_store_i && !req_lr_i && !req_sc_i && !req_amo_i`). LR, SC, AMO, and stores are strictly excluded.

---

## 2. Current Frozen L1D Transaction Audit

### 2.1 Baseline Pipeline Interface & Signals
In Fursoy Slice-0 (`rtl/core/fursoy_s0_core.sv` and `rtl/core/fursoy_s0_l1d.sv`), Stage E interacts with L1D via the following signals:

```systemverilog
// From Core Stage E to L1D:
input  logic        req_valid_i;
input  logic        req_store_i;
input  logic        req_lr_i;
input  logic        req_sc_i;
input  logic        req_amo_i;
input  logic [4:0]  req_amo_op_i;
input  logic [63:0] req_addr_i;
input  logic [2:0]  req_size_i;
input  logic        req_unsigned_i;
input  logic [63:0] req_store_data_i;
input  logic [4:0]  req_rd_i;
input  logic [63:0] req_pc_i;
input  logic [31:0] req_insn_i;
input  logic [7:0]  req_byte_mask_i;
input  logic        req_is_sb_drain_i;
input  logic        res_invalidate_i;

// From L1D to Core Stage E:
output logic        issue_ready_o;
output logic        l1d_idle_o;
output logic        stall_e_o;
output logic        retire_valid_o;
output logic        retire_rd_write_o;
output logic [4:0]  retire_rd_o;
output logic [63:0] retire_rd_data_o;
output logic [63:0] retire_pc_o;
output logic [31:0] retire_insn_o;
```

In `fursoy_s0_core.sv`, the Stage E load stall condition is defined as:
```systemverilog
wire lsu_load_stall = is_stage_e_load && !l1d_retire_valid &&
                      (sb_load_raw_hazard || !sb_grant_stage_e_load || l1d_stall_e) && !l1d_fault_valid;
```
When `l1d_retire_valid` asserts, `!l1d_retire_valid` deasserts, clearing `lsu_load_stall` and allowing `commit_fire` to evaluate.

### 2.2 Clean Load Miss Sequence in Baseline
1. **Cycle 0 (`IDLE`):** Load miss detected in `IDLE`. Victim way selected by Tree-PLRU is clean. Coordinates latched; `beat_cnt_q <= 0`; transitions to `REFILL_REQ`.
2. **Cycle 1 (`REFILL_REQ`, Beat 0):** Issues bus read request for Beat 0. Accepted by interconnect. Transitions to `REFILL_RSP`.
3. **Cycle 2 (`REFILL_RSP`, Beat 0):** Memory responds; latches `refill_buf_q[0] <= dmem_rsp_data_i`. Issues request for Beat 1; transitions to `REFILL_REQ`.
4. **Cycles 3–16 (Beats 1–7):** Alternates request/response across remaining 7 beats. Beat 7 arrives at Cycle 16.
5. **Cycle 17 (`INSTALL`):** All 8 doublewords written into cache array. Tag and valid bit updated. Requested doubleword formatted and presented on `retire_rd_data_o`. `reg_retire_valid <= 1'b1`. Transitions to `IDLE`.
6. **Cycle 18 (`IDLE`):** Load commits to register file. Next instruction executes.

**Total Baseline Clean Miss Duration:** 18 nominal cycles (17 stall cycles before retirement).

### 2.3 Dirty-Victim Load Miss Sequence in Baseline
1. **Cycle 0 (`IDLE`):** Load miss detected; Tree-PLRU victim way is dirty. Line captured to Eviction Buffer (`eb_data_q`). Transitions to `EVICT_REQ`.
2. **Cycles 1–8 (`EVICT_REQ` / `EVICT_BURST`):** 8-beat writeback burst to DRAM. Dirty bit cleared at Cycle 8; transitions to `REFILL_REQ`.
3. **Cycles 9–24 (Demand Refill):** 8-beat demand refill burst identical to clean refill (16 cycles nominal).
4. **Cycle 25 (`INSTALL`):** Cache array installation; load retires.
5. **Cycle 26 (`IDLE`):** Load commits to register file.

**Total Baseline Dirty Miss Duration:** 26 nominal cycles (25 stall cycles before retirement; measured empirical average ~50.5 cycles due to DRAM arbitration and refresh).

---

## 3. Critical-Beat Semantics and Bus Geometry

### 3.1 Mathematical Definition
For the 64-byte cache line and 8-beat 64-bit refill geometry, the critical beat index is defined strictly by physical address bits `[5:3]`:
$$b_{\text{crit}} = \text{target\_pa\_q}[5:3] \in [0 \dots 7]$$
Subword byte offset within that 64-bit beat is governed by:
$$\text{byte\_offset} = \text{target\_pa\_q}[2:0] \in [0 \dots 7]$$

### 3.2 Bus Refill Ordering: Fixed Ascending ($0 \to 7$) Preserved
L1D-ER v1 strictly preserves **Fixed Sequential ($0 \to 7$) Refill**:
- Refill requests issue in strictly ascending order: $0, 1, 2, 3, 4, 5, 6, 7$.
- Zero modifications to the external memory bus, memory controller, or interconnect.
- Critical beat arrival occurs at Cycle $(2 \times b_{\text{crit}} + 2)$ of the refill phase.

---

## 4. Empirical Critical-Beat Distribution Ground Truth

### 4.1 Measurement Methodology & Dataset
The critical beat distribution was directly instrumented and measured during a full 24,810,759 cycle Linux 6.6.50 cold boot to userspace characterization run on Fursoy Slice-0 (`results/perf-nlp-s0.json`).

Measurements were partitioned strictly into:
- **Clean Load Misses:** 24,074 misses (21.63% of total).
- **Dirty-Victim Load Misses:** 87,211 misses (78.37% of total; required dirty writeback prior to refill).
- **Total Load Misses:** 111,285 misses (100.00%).

### 4.2 Authoritative Empirical Distribution Table

```
====================================================================================================
                       EMPIRICAL L1D LOAD MISS CRITICAL BEAT CHARACTERIZATION
====================================================================================================
Metric / Category                     Clean Load Misses       Dirty-Victim Misses       All Load Misses
----------------------------------------------------------------------------------------------------
Total Miss Count                                 24,074                    87,211               111,285
Share of Total Load Misses                       21.63%                    78.37%               100.00%
Average Pre-Critical Latency               12.26 cycles              16.56 cycles          15.63 cycles
Average Trailing Latency                    9.24 cycles               9.64 cycles           9.56 cycles
Theoretical Max Trailing Cycles                 222,336                   841,015             1,063,351
----------------------------------------------------------------------------------------------------
Beat 0  (target_pa[5:3] == 000)          5,510 (22.89%)           21,176 (24.28%)       26,686 (23.98%)
  ↳ Trailing cycles per miss: 15          82,650 cycles            317,640 cycles        400,290 cycles
Beat 1  (target_pa[5:3] == 001)          3,613 (15.01%)           11,818 (13.55%)       15,431 (13.87%)
  ↳ Trailing cycles per miss: 13          46,969 cycles            153,634 cycles        200,603 cycles
Beat 2  (target_pa[5:3] == 010)          2,542 (10.56%)           10,437 (11.97%)       12,979 (11.66%)
  ↳ Trailing cycles per miss: 11          27,962 cycles            114,807 cycles        142,769 cycles
Beat 3  (target_pa[5:3] == 011)          2,302 (9.56%)            10,605 (12.16%)       12,907 (11.60%)
  ↳ Trailing cycles per miss: 9           20,718 cycles             95,445 cycles        116,163 cycles
Beat 4  (target_pa[5:3] == 100)          2,997 (12.45%)           10,950 (12.56%)       13,947 (12.53%)
  ↳ Trailing cycles per miss: 7           20,979 cycles             76,650 cycles         97,629 cycles
Beat 5  (target_pa[5:3] == 101)          2,938 (12.20%)           10,260 (11.76%)       13,198 (11.86%)
  ↳ Trailing cycles per miss: 5           14,690 cycles             51,300 cycles         65,990 cycles
Beat 6  (target_pa[5:3] == 110)          2,098 (8.71%)            9,787 (11.22%)       11,885 (10.68%)
  ↳ Trailing cycles per miss: 3            6,294 cycles             29,361 cycles         35,655 cycles
Beat 7  (target_pa[5:3] == 111)          2,074 (8.62%)            2,178 (2.50%)          4,252 (3.82%)
  ↳ Trailing cycles per miss: 1            2,074 cycles              2,178 cycles          4,252 cycles
====================================================================================================
```

### 4.3 Key Empirical Conclusions
1. **Dirty Victims Dominate (78.37%):** 87,211 of 111,285 load misses require a dirty victim eviction. Because dirty eviction strictly precedes demand refill, the 857,809 cycles of dirty eviction latency are strictly on the critical path and **unremovable** by Early Restart.
2. **True Weighted Average Trailing Latency is 9.5552 Cycles:** Across all 111,285 misses, the weighted average trailing latency under sequential $0 \to 7$ refill is 9.5552 cycles per miss, not the 12.0 cycles hypothesized before measurement.
3. **Mathematical Upper Ceiling:** The absolute theoretical upper bound for trailing latency across the workload is **1,063,351 cycles** (burst + 1-cycle install). The burst-only ceiling is **952,066 cycles** ($1,063,351 - 111,285$).

---

## 5. Storage Architecture and Unified FSM Taxonomy

### 5.1 Elimination of Dual-FSM Ambiguity (P1-3 Resolution)
The prior draft ambiguously referenced separate `RFB_BURST` and `REFILL_RSP` states. Under L1D-ER v1, there is **exactly ONE unified primary L1D FSM** that controls all cache operations, refill sequencing, and retirement handshaking.

The primary FSM state enumeration is:
```systemverilog
typedef enum logic [3:0] {
    L1D_IDLE        = 4'd0,  // Ready for new requests, serves hits
    L1D_AMO_CYCLE2  = 4'd1,  // Indivisible cycle 2 of AMO RMW
    L1D_EVICT_REQ   = 4'd2,  // Issue writeback request for dirty victim beat
    L1D_EVICT_BURST = 4'd3,  // Stream 8-beat writeback burst to DRAM
    L1D_REFILL_REQ  = 4'd4,  // Issue refill request for beat b
    L1D_REFILL_RSP  = 4'd5,  // Await memory response for beat b; format early data
    L1D_INSTALL     = 4'd6,  // 1-cycle atomic directory & SRAM array installation
    L1D_MMIO_REQ    = 4'd7,  // Uncached MMIO request
    L1D_MMIO_RSP    = 4'd8,  // Uncached MMIO response
    L1D_FLUSH_SWEEP = 4'd9,  // Maintenance flush dirty line scan
    L1D_FLUSH_REQ   = 4'd10, // Maintenance dirty line evict request
    L1D_FLUSH_BURST = 4'd11, // Maintenance dirty line evict burst
    L1D_FLUSH_DONE  = 4'd12, // Maintenance completion pulse
    L1D_DRAIN_ERROR = 4'd13  // Draining outstanding burst after pre-critical bus error
} l1d_state_e;
```

### 5.2 Dedicated Refill Registers
To manage early restart within the unified FSM, L1D maintains the following dedicated registered storage:

```systemverilog
// Dedicated Refill Storage & Tracking:
logic [63:0] refill_buf_q [8];           // Accumulates 8 beats (512 bits)
logic [2:0]  beat_cnt_q;                 // Current beat index (0..7)
logic [2:0]  target_crit_beat_q;         // Latched critical beat: target_pa_q[5:3]
logic [63:0] target_va_q;                // Original full effective VA for xTVAL
logic        target_is_ordinary_load_q;  // Strictly ordinary demand load flag (P0-3)

// Persistent Handshake Registers (P0-1 & P1-4):
logic        er_retire_valid_q;          // Persistent retirement valid to Stage E
logic [63:0] er_retire_rd_data_q;        // Registered formatted data to Stage E
logic        rfb_crit_consumed_q;        // Result resolved: committed OR squashed; not retirement authority
logic        er_load_retired_q;          // Set only by authoritative successful retire_ack_i
logic        er_load_squashed_q;         // Set by redirect before retirement; never means retired
logic        refill_poisoned_q;          // Latched upon bus error (P1-1)
```

### 5.3 Main Directory Isolation
- The main cache directory (`valid_q[set][way]`) is **never marked valid** for a partially refilled line.
- If the victim was dirty, the victim way is invalidated upon miss capture (`valid_q[set][way] <= 0`), preventing stale hits.
- Full line publication occurs as an **authoritative single-cycle atomic write** at state `L1D_INSTALL`.
- Tree-PLRU updates to mark the way MRU **only at state `L1D_INSTALL`**.

---

## 6. Persistent Handshake and Registered Data Staging

### 6.1 Persistent Handshake Contract (P0-1 Resolution)
The single-cycle retirement pulse (`er_retire_pulse_q`) is completely eliminated. Load retirement is governed by the persistent valid register `er_retire_valid_q`.

**Handshake Rules:**
1. **Assertion:** `er_retire_valid_q` asserts on clock edge $T \to T+1$ if and only if:
   - State is `L1D_REFILL_RSP`,
   - Beat $b = \text{target\_crit\_beat\_q}$ has completed handshake: `dmem_rsp_valid_i && dmem_rsp_ready_o`,
   - `dmem_rsp_error_i == 1'b0` and `refill_poisoned_q == 1'b0`,
   - `target_is_ordinary_load_q == 1'b1` (strictly ordinary load),
   - `rfb_crit_consumed_q == 1'b0` (has not already been consumed).
2. **Persistence:** Once asserted, `er_retire_valid_q` **remains stably asserted** across any number of clock cycles until the core accepts the transfer or an architectural squash occurs.
3. **Stable Data Hold:** `er_retire_rd_data_q` holds the exact formatted load result stably throughout the entire assertion period.
4. **Authoritative Core Transfer Event:** `er_load_retired_q` is set if and only if
   `retire_ack_i && er_retire_valid_q` identifies successful architectural commit of the
   original ordinary L1D-ER load. Critical-beat arrival, result availability, redirect,
   squash, trap, or interrupt never sets it.
5. **Result Resolution vs Retirement:** `rfb_crit_consumed_q` prevents a duplicate normal
   retirement at INSTALL and may be set by either successful acknowledgement or squash.
   It is not architectural retirement evidence and MUST NOT classify later errors.
6. **Deassertion:** `er_retire_valid_q` clears to `1'b0` on the clock edge immediately
   following authoritative commit, or upon an architectural pipeline squash through
   `redirect_i`. A squash also sets `er_load_squashed_q` but leaves
   `er_load_retired_q == 0`. `res_invalidate_i` is exclusively LR-reservation
   invalidation and is never an ER pipeline squash indication.
7. **Lifetime:** `er_load_retired_q` and `er_load_squashed_q` clear on reset and at new
   L1D-ER transaction allocation. They remain stable through trailing refill and clear
   only when that transaction reaches legal INSTALL or finishes error cleanup.

### 6.2 Core Interface Signals and Loop-Free Handshake Proof
To implement the persistent handshake without ambiguous signals or combinational loops:

```systemverilog
// Interface addition to fursoy_s0_l1d:
input  logic        retire_ack_i;  // Authoritative core commit strobe
input  logic        redirect_i;    // Core pipeline flush/redirect strobe
```

**Signal Definition in `fursoy_s0_core.sv`:**
```systemverilog
// In core, retire_ack_i strobes when Stage E commits the ordinary load:
assign l1d_retire_ack = commit_fire && is_stage_e_load;
assign l1d_redirect   = redirect_any_e;
```

**Combinational Loop Freedom Proof:**
- `er_retire_valid_q` is a sequential register output from L1D.
- `l1d_retire_valid` drives into Core Stage E combinational stall logic:
  $$\text{lsu\_load\_stall} = \text{is\_stage\_e\_load} \land \neg\text{l1d\_retire\_valid} \land \dots$$
- When `er_retire_valid_q` is 1, `lsu_load_stall` becomes 0, and `stall_e` becomes 0.
- Core combinational signal `commit_fire` evaluates to 1:
  $$\text{commit\_fire} = \text{fe\_q.valid} \land \neg\text{stall\_e} \land \neg\text{sync\_trap\_e} \land \dots$$
- Core drives `l1d_retire_ack = commit_fire && is_stage_e_load`.
- Inside L1D, `l1d_retire_ack` is connected strictly to the synchronous D-flip-flop inputs of `er_retire_valid_q` and `rfb_crit_consumed_q`:
  ```systemverilog
  if (retire_ack_i && er_retire_valid_q) begin
      er_retire_valid_q   <= 1'b0;
      rfb_crit_consumed_q <= 1'b1;
      er_load_retired_q   <= 1'b1;
  end
  ```
- There is **zero combinational path** from `retire_ack_i` back into `retire_valid_o` or `stall_e_o`. The path terminates at flip-flop inputs. Hence, combinational loop formation is mathematically impossible.

### 6.3 Registered Data Staging Datapath (P1-4 Resolution)
To guarantee strict physical timing closure and eliminate combinational feedthrough from external memory pins:

```
[External DRAM Interconnect]
          |
          | dmem_rsp_data_i (64 bits)
          v
+-------------------------------------------------------------+
| Cycle T: Capture into Refill Buffer Flip-Flops              |
|   refill_buf_q[beat_cnt_q] <= dmem_rsp_data_i;              |
+-------------------------------------------------------------+
          |
          | Registered storage output (internal flip-flop)
          v
+-------------------------------------------------------------+
| Cycle T+1: Selection & Sign/Zero Extension into Output Reg  |
|   er_retire_rd_data_q <= extend_load(                       |
|       refill_buf_q[target_crit_beat_q],                     |
|       target_pa_q[2:0], target_size_q, target_unsigned_q    |
|   );                                                        |
|   er_retire_valid_q   <= 1'b1;                              |
+-------------------------------------------------------------+
          |
          | retire_rd_data_o (registered, stable)
          v
[Core Stage E Register File Write Port]
```

**Normative Rule:** Stage E never receives load data through `extend_load(dmem_rsp_data_i, ...)`. Load data is formatted strictly from internal flip-flop `refill_buf_q[b]`, adding exactly 1 cycle of registered staging latency.

### 6.4 Detailed 8-Step Lifecycle Trace

```
Cycle 0: Demand load misses in L1D. Coordinates latched.
Cycle 1..T-1: Pre-critical refill beats 0..b_crit-1 arrive and latch into refill_buf_q.
Cycle T:
  - Critical beat b_crit memory response handshakes: dmem_rsp_valid_i && dmem_rsp_ready_o.
  - Beat data registered: refill_buf_q[b_crit] <= dmem_rsp_data_i.
  - No combinational data forwarded to Stage E on this cycle.
Cycle T+1:
  - Registered staging: er_retire_rd_data_q <= extend_load(refill_buf_q[b_crit], ...).
  - Persistent valid asserts: er_retire_valid_q <= 1'b1.
  - L1D outputs: retire_valid_o = 1, retire_rd_data_o = er_retire_rd_data_q.
Cycle T+1 .. T+N (Stage E Stall Hold):
  - If Stage E is stalled by downstream backpressure (stall_e == 1):
    * er_retire_valid_q holds stably asserted at 1'b1.
    * er_retire_rd_data_q holds stable data.
    * rfb_crit_consumed_q remains 1'b0 (NOT marked consumed).
    * retire_ack_i remains 1'b0.
Cycle T+N+1 (Stage E Advance & Commit):
  - Stage E stall clears (stall_e == 0).
  - Core evaluates commit_fire = 1'b1.
  - Register file writes rd <= retire_rd_data_o; minstret strobes once.
  - Core asserts retire_ack_i = 1'b1.
Cycle T+N+2:
  - L1D latches rfb_crit_consumed_q <= 1'b1, er_load_retired_q <= 1'b1,
    and er_retire_valid_q <= 1'b0.
  - Stage E advances to next instruction.
  - Trailing refill beats continue in background (state L1D_REFILL_REQ / L1D_REFILL_RSP).
Cycle T_final:
  - Beat 7 arrives; state transitions to L1D_INSTALL.
  - Full line written to SRAM arrays; valid_q <= 1; Tree-PLRU updated.
  - State transitions to L1D_IDLE.
```

### 6.5 Pipeline Redirect / Trap While `er_retire_valid_q` Is Pending
If an asynchronous redirect (trap, interrupt, or older squash) arrives in Stage E while `er_retire_valid_q == 1` and before `retire_ack_i` has asserted:
1. Core asserts `redirect_i = 1'b1`.
2. L1D immediately clears `er_retire_valid_q <= 1'b0`, sets
   `rfb_crit_consumed_q <= 1'b1` and `er_load_squashed_q <= 1'b1`, and keeps
   `er_load_retired_q == 1'b0`.
3. The early load does NOT commit; `rd` is not written; `minstret` is not incremented.
4. The trailing refill continues safely to Beat 7 completion and installs into the cache array (`L1D_INSTALL`).
5. Future instruction fetches or memory accesses benefit from the refilled line in cache.
6. If a later refill beat errors after this squash, the line is poisoned and discarded and
   accepted traffic is drained. The squashed instruction receives no retroactive precise
   fault, but the error also does not take the committed-load fatal path. No INSTALL or
   PLRU/metadata publication occurs.

### 6.6 Verification Control Isolation

Verification-only controls are not architectural or platform interfaces. In particular,
`test_stall_e_i` and `test_redirect_e_i` MUST NOT remain unconditional ports of
`fursoy_s0_core` or any production wrapper.

- **Multi-cycle Stage-E stall:** the focused L1D-ER test may use a verification-only
  bind/shim or an internal injection term compiled exclusively in the simulation
  configuration and excluded from synthesis. It may hold Stage E after
  `er_retire_valid_q` asserts, but it must not directly modify L1D retirement state,
  `retire_ack_i`, register-file state, or memory-bus signals. The test must prove stable
  valid/data for arbitrary cycles and release the stall to produce the normal
  `commit_fire && is_stage_e_load` acknowledgement. No corresponding production core
  input is permitted.
- **Redirect while early result is pending:** an L1D unit-level test drives the real
  production `redirect_i` input of the L1D instance. In the present two-stage core, this
  exact core-level state has no reachable production redirect: interrupt entry requires
  `!stall_e && !lsu_valid`, while branch, return, trap, and serialization redirects decode
  the current Stage-E instruction, which is the held load. Therefore this contract does
  not claim a core-level redirect stimulus for the exact pending/stalled state. Existing
  reachable branch-mispredict, synchronous-trap, return, serialization, and interrupt
  paths remain covered by their normal directed suites. No `test_redirect_e_i` production
  core input is permitted. If later pipeline control makes this state reachable, an
  integration case must then exercise the normal production source.

Simulation-only control must be visibly guarded (`ifndef SYNTHESIS` or an equivalent
verification-only source/bind file omitted from production file lists). Production builds
must elaborate the normal core interface without either test port and without a constant
or floating substitute that can affect behavior.

---

## 7. Dirty-Victim Behavior and Eviction Ordering

### 7.1 Normative Sequence
For a dirty victim miss, the sequence is strictly ordered:
$$\text{Victim Capture} \to \text{Atomic Invalidation} \to \text{Synchronous Eviction Burst} \to \text{Demand Refill} \to \text{Critical Early Restart} \to \text{Trailing Refill} \to \text{Install}$$

```mermaid
sequenceDiagram
    autonumber
    participant Core as Stage E (Load)
    participant L1D as L1D Controller
    participant DRAM as DRAM Interconnect
    
    Core->>L1D: Load Miss (PA, Dirty Victim)
    L1D->>L1D: Capture Victim to Eviction Buffer
    L1D->>L1D: Invalidate Victim Way in Directory
    loop 8 Beats Eviction Burst
        L1D->>DRAM: 8-Beat Burst Writeback to DRAM
    end
    Note over L1D,DRAM: Eviction Latency (16-24 cycles) CANNOT BE HIDDEN in v1
    loop Refill Beats 0..crit
        L1D->>DRAM: Refill Burst Request / Rsp
    end
    DRAM-->>L1D: Critical Beat b_crit Arrives (Cycle T)
    L1D->>L1D: Cycle T+1: Registered Staging & er_retire_valid_q <= 1
    L1D->>Core: Persistent Handshake: retire_valid_o = 1
    Core->>Core: Commit Load to Regfile; retire_ack_i <= 1
    Note over Core: Stage E resumes executing independent non-memory instructions!
    loop Trailing Beats (crit+1)..7
        L1D->>DRAM: Trailing Refill Beats in Background
    end
    L1D->>L1D: Atomic Directory Install (Way=MRU, Valid=1, Dirty=0)
    L1D->>Core: l1d_idle_o <= 1 (L1D Ready for Next Memory Operation)
```

### 7.2 Non-Removable Eviction Latency
Because dirty writeback must complete before the DRAM controller accepts demand refill requests, early restart **cannot remove any of the 857,809 dirty eviction cycles**:
$$\text{Removable}_{\text{dirty}}(b) = \max\left(0, 2 \times (7 - b) - 1\right) \text{ cycles}$$
All eviction latency remains strictly on the critical execution path in v1.

---

## 8. Subsequent Pipeline Transactions During Trailing Refill

### 8.1 Conservative Policy Rules (P0-2 Resolution)
During the trailing refill window (from load early retirement until `L1D_INSTALL` completes):
1. **`l1d_idle_o = 1'b0` throughout:** L1D signals busy to the pipeline and Store Buffer continuously until `L1D_INSTALL` finishes.
2. **No Resident Cache Hits:** Single-port SRAM arrays cannot be arbitrated between external refill beats and internal lookups. Resident loads stall Stage E.
3. **No Selective Store Buffer Drains:** SB drain logic observes `l1d_idle_o == 0` and suspends all drains until `L1D_INSTALL` finishes.

### 8.2 Subsequent Transaction Hazard Matrix

| Scenario | Subsequent Instruction in Stage E | Architectural Action in v1 | Performance Impact |
| :--- | :--- | :--- | :--- |
| **A. Independent Non-Memory** | ALU, Shift, Compare, Branch, CSR read | **Executes and commits normally in Stage E** | **Cycles fully overlapped** with background refill burst. |
| **B. Subsequent Load (Any Address)**| Load to same line or any other cached line | **Stage E stalls** until `L1D_INSTALL` completes | Pipeline stalls safely; resumes immediately once L1D enters `IDLE`. |
| **C. Subsequent Store (DRAM)** | Store instruction entering Stage E | **Enqueues into Store Buffer** without stalling Stage E | Overlaps with refill unless 4-entry Store Buffer is already full. |
| **D. Store Buffer Full** | Store enters Stage E when SB has 4 entries | **Stage E stalls** (`sb_enqueue_stall == 1`) | Stalls Stage E until trailing refill finishes and SB resumes draining. |
| **E. Store Buffer Drain** | `sb_head` requesting drain to L1D | **Drain suspended** (`grant_sb_drain == 0`) | Zero overwrite risk; zero SRAM port collisions. |
| **F. Uncached MMIO** | MMIO load/store in Stage E | **Stage E stalls** until trailing refill finishes | Strict in-order memory bus serialization preserved. |
| **G. RV64A Atomic (AMO/LR/SC)** | Atomic instruction in Stage E | **Stage E stalls** until trailing refill finishes | Atomic Indivisibility and reservation rules 100% preserved. |

---

## 9. Stores During Trailing Refill

### 9.1 Prevention of Late-Arriving Refill Overwrite
If an architectural store were allowed to update the cache or refill buffer while beats were in flight, a later-arriving DRAM beat could overwrite newer store data.

Under the conservative v1 policy:
1. **Stores Enqueue into SB:** Ordinary stores enqueue into the 4-entry Store Buffer without accessing L1D.
2. **SB Drains Blocked:** The Store Buffer drain controller is gated by `l1d_idle_o == 1'b0` and cannot initiate a drain.
3. **Zero Overwrite Risk:** Because no store writes to the cache array or `refill_buf_q` during trailing refill, late-arriving DRAM beats can never overwrite newer store data.
4. **Drain Resumption:** Once `L1D_INSTALL` finishes and L1D returns to `L1D_IDLE`, the Store Buffer drains to the newly installed clean line in cache via standard single-cycle store hits.

---

## 10. Store Refill Buffer (SRB) Interaction

### 10.1 Interconnect Mutual Exclusion
The Store Refill Buffer (`srb`) and L1D Load Refill engine share the single 64-bit DRAM bus:
- **Invariant:** L1D Load Refill and SRB Refill are **strictly mutually exclusive**:
  $$\text{DRAM Bus Master} \in \{\text{NONE}, \text{PTW}, \text{SRB}, \text{L1D\_LOAD}, \text{L1I}\}$$
- If an L1D load misses while `srb_busy_o == 1`, Stage E asserts `srb_sec_load_stall` until SRB completes installation.
- While an L1D load trailing refill is active, `srb_capture` cannot fire because SB drains are suspended.
- Existing SRB victim snapshot, dirty accounting, and atomic way invalidation contracts remain 100% unchanged.

---

## 11. Store Buffer (SB) Interaction and RAW Ordering

### 11.1 RAW Hazard Interlock Preservation
Before an L1D load miss can initiate in `L1D_IDLE`:
- Frozen SB logic inspects all 4 entries for physical doubleword match:
  $$\text{sb\_raw\_hazard} = \bigvee_{i=0}^{3} \left(\text{sb\_valid}[i] \land (\text{sb\_paddr}[i] == \text{target\_pa\_q}[55:3])\right)$$
- If a RAW hazard is detected, the load **stalls Stage E** until the Store Buffer drains to L1D.
- Early restart does not modify this check: any load that initiates refill has zero uncommitted stores pending in the Store Buffer for its requested address.
- Store-to-Load Forwarding (STLF) is strictly excluded from v1.

---

## 12. RV64A Atomic and LR/SC Exclusion (P0-3 Resolution)

### 12.1 Explicit Transaction Class Latching
Baseline L1D defined `op_is_load = !req_store_i && !req_amo_i`, which inadvertently included `req_lr_i`.

Under L1D-ER v1, transaction classification is latched explicitly at miss acceptance in `L1D_IDLE`:
```systemverilog
// Exact transaction classification at miss detection:
always_ff @(posedge clk_i) begin
    if (rst_i) begin
        target_is_ordinary_load_q <= 1'b0;
        target_is_lr_q            <= 1'b0;
        target_is_sc_q            <= 1'b0;
        target_is_amo_q           <= 1'b0;
        target_is_store_q         <= 1'b0;
    end else if (state_q == L1D_IDLE && can_lookup && !tag_matched) begin
        target_is_ordinary_load_q <= req_valid_i && !req_store_i && !req_lr_i && !req_sc_i && !req_amo_i;
        target_is_lr_q            <= req_lr_i;
        target_is_sc_q            <= req_sc_i;
        target_is_amo_q           <= req_amo_i;
        target_is_store_q         <= req_store_i;
    end
end
```

### 12.2 Exclusion Rules
1. **`LR.W` / `LR.D`:** Excluded from Early Restart (`target_is_ordinary_load_q == 0`). Misses execute synchronous 8-beat refill, install the line into cache at `L1D_INSTALL`, establish reservation (`res_valid_q <= 1'b1`, `res_granule_pa_q <= target_pa_q[55:6]`), and retire strictly at `L1D_INSTALL`.
2. **`SC.W` / `SC.D`:** Excluded from Early Restart. Completes write-allocate refill, updates cache line at `L1D_INSTALL`, and retires with `rd = 0` (success).
3. **`AMO` (All 9 Operations):** Excluded from Early Restart. Completes synchronous refill, installs clean line at `L1D_INSTALL`, and transitions to `L1D_AMO_CYCLE2` to perform the indivisible atomic read-modify-write sequence.

---

## 13. Bus Error Semantics and Platform Fault Taxonomy

### 13.1 Authoritative Classification State

Beat position does not determine whether a refill error is precise or fatal. The sole
authority is whether the original L1D-ER load actually retired:

- `er_load_retired_q` resets to 0 and is cleared at transaction allocation.
- It is set only by `retire_ack_i && er_retire_valid_q` for the original ordinary load.
- Critical-beat arrival, registered result availability, redirect, squash, trap, and
  interrupt never set it.
- It remains available through trailing refill and is cleared only when that transaction
  legally installs or completes error cleanup.
- `rfb_crit_consumed_q` may represent either commit or cancellation and MUST NOT be used
  for precise-versus-fatal classification.

L1D also latches the original full 64-bit effective address as `target_va_q` at miss
acceptance, alongside the translated physical `target_pa_q`. `target_pa_q` is used for
cache tags, refill addresses, and bus ownership. Every precise L1D-ER access-fault path
reports `fault_addr_o = target_va_q`; it never reconstructs xTVAL from PA. When Sv39
translation is active, xTVAL is therefore the original full VA as required by the frozen
Sv39 contract. In Bare/bypass operation the original effective address is itself the
architectural physical address, so reporting `target_va_q` directly preserves the frozen
effective-physical-address rule, including failures that cannot be represented by
reconstructing the implemented PA width.

### 13.2 Four Authoritative Error Cases

All cases poison and discard the refill, suppress INSTALL and successful PLRU/metadata
publication, stop issuing later unaccepted beats, and drain accepted protocol obligations.
The architectural disposition is:

1. **Case A — before the critical beat, not retired:** `er_load_retired_q == 0` and the
   original load is not squashed. Cancel any pending result and, after drain, raise a
   precise load-access-fault (cause 5) with the faulting instruction PC and
   `fault_addr_o = target_va_q`.
2. **Case B — exactly on the critical beat, not retired:** the erroneous beat is never
   captured as usable early data; `er_retire_valid_q` never becomes architecturally
   consumable. After drain, raise the same precise cause 5 fault using `target_va_q`.
3. **Case C — later beat after good critical data, but no acknowledgement:** even if
   `er_retire_valid_q == 1`, `er_load_retired_q == 0` means the load has not retired.
   Clear/cancel the pending result, leave its destination register unchanged, and raise
   the same precise cause 5 fault after drain. This case is not fatal.
4. **Case D — later beat after authoritative acknowledgement:**
   `er_load_retired_q == 1` means the load is committed. It remains committed, no
   retroactive exception is generated, and the common sticky fatal-halt policy applies.

If the original load was legitimately squashed before acknowledgement,
`er_load_squashed_q == 1` and `er_load_retired_q == 0`. A later error poisons/discards the
background refill and drains traffic, but generates neither a retroactive load fault nor
the committed-load fatal response. This narrow silent-discard rule applies only to a
transaction whose original instruction was authoritatively squashed; it does not mask an
error for a still-live unretired load.

Classification priority on an error edge is:

1. valid coincident authoritative acknowledgement of the original early load;
2. previously latched `er_load_retired_q`;
3. coincident or previously latched authoritative squash;
4. otherwise, live pre-retirement precise fault.

Thus redirect/squash is cancellation, never retirement.

### 13.3 Same-Cycle Retirement and Fatal-Detection Priority

The implementation must keep classification and side-effect gating combinationally
acyclic. L1D exposes a raw accepted refill/writeback error-edge indication to the core;
this indication does not depend on `commit_fire` or `retire_ack_i`. The core first computes
an ungated `commit_candidate_e`. It may then recognize exactly one exception:

```systemverilog
allow_coincident_er_commit = l1d_error_edge && er_retire_valid &&
                             commit_candidate_e && is_original_stage_e_er_load &&
                             !other_fatal_source;
architectural_enable_e = !fatal_halt_q &&
                         (!l1d_error_edge || allow_coincident_er_commit);
commit_fire = commit_candidate_e && architectural_enable_e;
retire_ack_i = commit_fire && is_original_stage_e_er_load;
```

The names are conceptual; the required ordering and absence of a feedback loop are
normative. `l1d_error_edge` is a real internal L1D-to-core hardware signal, while the
existing `fatal_error_o` remains the sticky reset-only state. The coincident exception is
permitted only when the pending registered early result belongs to the same Stage-E load
that produces `retire_ack_i`. It does not authorize an unrelated ALU/CSR/store/atomic
instruction or another fatal source to commit.

Cycle-level Case D example:

- Before edge T, registered `er_retire_valid_q=1`, `er_load_retired_q=0`, and the original
  load has an otherwise valid `commit_candidate_e`.
- In cycle T, a later refill response handshakes with error. `l1d_error_edge=1` and the
  narrow coincident exception permits that original load's register write/minstret update;
  `retire_ack_i=1`.
- At edge T, L1D records both authoritative retirement and sticky fatal state, poisons the
  refill, and suppresses installation.
- From cycle T+1 until reset, fatal halt permits no architectural side effects or new work.

For a previously retired load, or any error edge without the narrow coincident original
load acknowledgement, fatal/error detection has priority on that same edge. It gates off:
normal commit and register-file write, CSR/PMP write, MRET, SRET, LR reservation changes,
SC/AMO effects, Store Buffer enqueue, trap/interrupt entry, maintenance start/publication,
new cache/PTW request allocation, fetch transfer, and PC/pipeline advancement. No side
effect may occur merely because its old combinational enable was high.

Mandatory non-architectural cleanup may continue: accepted response consumption,
ready/valid stability for a request already presented while stalled, response-owner
bookkeeping, poisoning, and error drain. Cleanup must never install poisoned data, publish
valid/dirty/tag state, update PLRU as a successful install, or initiate new architectural
execution.

### 13.4 Sticky Fatal-Halt Enforcement and Platform Verification

For Case D and pre-existing unrecoverable L1D writeback/SRB errors, L1D holds
`fatal_error_o` high until `rst_i`; this is hardware state, not simulation `$fatal` or a
precise RISC-V exception. The core exposes sticky `fatal_halt_o`, freezes Stage F/E, blocks
all architectural effects and new requests under Section 13.3, and lets only mandatory
protocol cleanup complete. Once prior obligations drain, instruction/data request valid
outputs remain low. The SoC propagates `fatal_halt_o` as a top-level platform indication.
Only reset clears the L1D/core/SoC fatal state; software, traps, returns, interrupts, and
maintenance cannot clear it. No NMI, machine-check, debug halt, or reset-request subsystem
is assumed or required.

Platform verification must inject Case D through the SoC/top-level path and observe the
top-level `fatal_halt_o`, not merely internal L1D state. It proves the acknowledged load
commits exactly once, no precise fault is generated, the line never installs, fatal state
is sticky, detection-edge side effects are limited to the one explicitly allowed load
commit, subsequent architectural/platform side effects stop, bus obligations drain, and
reset clears halt and restarts the normal reset sequence. Simulation may terminate only
after checking these hardware-visible properties; termination is not the hardware policy.

---

## 14. Pipeline Redirects, Traps, and Interrupts

### 14.1 Behavioral Matrix

```
+------------------------------------+---------------------------------------------------------------+
| Pipeline Event Timing              | Architectural Behavior & Invariants                           |
+------------------------------------+---------------------------------------------------------------+
| Interrupt before Critical Beat     | Masked during synchronous load stall. Cannot preempt load.    |
+------------------------------------+---------------------------------------------------------------+
| Redirect while er_retire_valid_q   | Stage E squashed by older trap/redirect. L1D drops            |
| is asserted but not yet accepted   | er_retire_valid_q <= 0; rfb_crit_consumed_q <= 1. Load does   |
|                                    | not commit. Trailing refill continues and installs cleanly.  |
+------------------------------------+---------------------------------------------------------------+
| Synchronous Trap on Critical Beat  | Load access fault (cause 5) raised precisely; load aborts.    |
+------------------------------------+---------------------------------------------------------------+
| Redirect AFTER Early Restart       | Subsequent instruction redirects (branch mispredict/trap).   |
| (during trailing refill burst)     | Stage E squashed. Trailing refill CONTINUES to Beat 7 and     |
|                                    | installs cleanly. Next instruction at redirect target runs.   |
+------------------------------------+---------------------------------------------------------------+
```

---

## 15. Maintenance, Fences, and Serialization

If a trailing refill is active when a serializing instruction reaches Stage E:
- **`FENCE`:** Stalls in Stage E (`fence_stall = 1`) until trailing refill completes and `l1d_idle_o == 1`.
- **`SFENCE.VMA`:** Stalls in Stage E (`sfence_stall = 1`) until trailing refill completes, then initiates TLB/cache flush.
- **`FENCE.I`:** Stalls in Stage E (`fence_i_stall = 1`) until trailing refill completes, then initiates serialized 7-step coherence sweep.
- **`PMP` / `satp` CSR Write:** Stalls in Stage E (`pmp_csr_stall = 1`) until trailing refill completes before updating context.

---

## 16. Unified FSM State Transition Table and Control Invariants

```
========================================================================================================================
                                     L1D-ER v1 UNIFIED PRIMARY FSM TRANSITION TABLE
========================================================================================================================
Current State    Event / Condition                      Next State       Outputs & Action Summary
------------------------------------------------------------------------------------------------------------------------
L1D_IDLE         req_valid & hit                        L1D_IDLE         Serve 1-cycle hit; plru_update; retire
                 req_valid & miss & victim dirty        L1D_EVICT_REQ    Capture victim to EB; invalidate way; beat_cnt<=0
                 req_valid & miss & victim clean        L1D_REFILL_REQ   Latch coordinates; target_is_ord_load; beat_cnt<=0
                 maintenance_req                        L1D_FLUSH_SWEEP  Initiate serialized maintenance sweep
                 mmio_req                               L1D_MMIO_REQ     Issue uncached MMIO read/write
------------------------------------------------------------------------------------------------------------------------
L1D_EVICT_REQ    dmem_req_ready_i                       L1D_EVICT_BURST  Assert dmem_req_valid_o, store=1, addr={eb,0}
------------------------------------------------------------------------------------------------------------------------
L1D_EVICT_BURST  dmem_req_ready & beat_cnt < 7          L1D_EVICT_BURST  beat_cnt <= beat_cnt + 1; stream writeback beat
                 dmem_req_ready & beat_cnt == 7         L1D_REFILL_REQ   Clear dirty bit; beat_cnt <= 0; issue refill
                 dmem_req_error | dmem_rsp_error        L1D_IDLE         fatal_error_o <= 1
------------------------------------------------------------------------------------------------------------------------
L1D_REFILL_REQ   dmem_req_ready & !error                L1D_REFILL_RSP   Assert dmem_req_valid_o, store=0; addr={pa,b}
                 accepted error & retired/ack           L1D_IDLE         poison/discard; sticky fatal overlay
                 accepted error & squashed              L1D_IDLE/drain   poison/discard; no trap and no fatal
                 accepted error & live, not retired     L1D_DRAIN_ERROR  poison; cancel ER; later precise fault using VA
------------------------------------------------------------------------------------------------------------------------
L1D_REFILL_RSP   dmem_rsp_valid & !error & (b == b_crit) L1D_REFILL_REQ   refill_buf_q[b] <= data; er_retire_valid_q <= 1 (T+1)
                 dmem_rsp_valid & !error & (b < 7)      L1D_REFILL_REQ   refill_buf_q[b] <= data; beat_cnt <= b + 1
                 dmem_rsp_valid & !error & (b == 7)     L1D_INSTALL      refill_buf_q[7] <= data; transition to INSTALL
                 accepted error & retired/ack           L1D_IDLE         poison/discard; sticky fatal overlay
                 accepted error & squashed              L1D_IDLE/drain   poison/discard; no trap and no fatal
                 accepted error & live, not retired     L1D_DRAIN_ERROR  poison; cancel ER; later precise fault using VA
  * Handshake *  retire_ack_i && er_retire_valid_q       (same state)     result done; er_load_retired_q<=1; valid<=0
  * Squash *     redirect_i && !retire_ack_i             (same state)     result done; er_load_squashed_q<=1; valid<=0
------------------------------------------------------------------------------------------------------------------------
L1D_INSTALL      (1 cycle unconditional)                L1D_IDLE         Write data_q & tag_q; valid_q<=1; plru_update;
                                                                         If !rfb_crit_consumed: standard retire pulse
------------------------------------------------------------------------------------------------------------------------
L1D_DRAIN_ERROR  in-flight memory traffic drained       L1D_IDLE         Raise precise cause 5 with target_va_q; rd unmod
========================================================================================================================
```

The sticky fatal-halt control is an orthogonal global overlay, not an additional primary
L1D FSM state. While it is asserted, the core enforcement rules in Section 13.2 prevent
new L1D use even if the refill FSM has returned to `L1D_IDLE` after protocol cleanup.

---

## 17. Four-Tier Performance Model (P1-2 Resolution)

### 17.1 Analytical Framework & Modeling Constraints
Under the conservative v1 interface policy (P0-2) and registered data staging (P1-4):
1. **Registered Staging Cost:** +1 cycle per early restart (Cycle T capture into `refill_buf_q`, Cycle T+1 valid assertion).
2. **Trailing Burst Available:** $2 \times (7 - b) - 1$ cycles of potential execution overlap.
3. **Subsequent Memory Stalls:** Any subsequent load or store buffer saturation stalls Stage E until `L1D_INSTALL`.
4. **Non-Hideable Eviction Latency:** 857,809 cycles of dirty eviction latency remain strictly unremovable.
5. **Non-Hideable Install Bubble:** The 1-cycle `L1D_INSTALL` array write requires single-port ownership.

### 17.2 Four Tiers of Performance Projection

```
====================================================================================================
                               L1D-ER v1 FOUR-TIER PERFORMANCE MODEL
====================================================================================================
Model Tier            Key Assumptions & Constraints                 Cycles Saved     Modeled IPC
----------------------------------------------------------------------------------------------------
Tier 1: Conservative  - Conservative v1 interface (P0-2)             450,000 to       0.6118 to
Lower Bound           - All subsequent loads stall until INSTALL       550,000         0.6143
                      - SB absorbs 1-2 stores before full stall
                      - Overlap limited to ~4.5 cycles / miss
                      - Net runtime reduction: ~1.8% to 2.2%

Tier 2: Expected      - Conservative v1 interface (P0-2)             650,000 to       0.6169 to
Realistic             - Stage E executes non-memory code blocks        750,000         0.6194
                        (ALU, branches, shifts) during burst
                      - Overlap averages ~6.3 cycles / miss
                      - Net runtime reduction: ~2.6% to 3.0%

Tier 3: Optimistic    - 100% of trailing burst cycles hidden           952,066         0.6247
Burst Ceiling         - Zero subsequent memory stall interruptions
                      - Install cycle NOT hidden (1-cycle bubble)
                      - Ideal non-memory instruction overlap

Tier 4: Theoretical   - Absolute mathematical upper bound            1,063,351         0.6275
Upper Ceiling           (all burst + 1-cycle install hidden)
                      - Unreachable under single-port SRAM contract
====================================================================================================
```

---

## 18. PPA Assessment

### 18.1 Silicon Area & Storage Overhead
- `refill_buf_q`: 8 $\times$ 64-bit = 512 flip-flops (already present in baseline `fursoy_s0_l1d.sv`).
- `er_retire_rd_data_q`: 64 flip-flops (registered staging to isolate timing).
- `er_retire_valid_q`: 1 flip-flop (persistent handshake).
- `rfb_crit_consumed_q`: 1 flip-flop.
- `er_load_retired_q`: 1 flip-flop (authoritative error classification).
- `er_load_squashed_q`: 1 flip-flop (cancelled-transaction classification).
- `target_va_q`: 64 flip-flops (original effective address for precise xTVAL).
- `refill_poisoned_q`: 1 flip-flop.
- Additional error-edge/side-effect qualification is small control logic off the normal
  error-free datapath. No percentage area claim is made until synthesis measurement.

### 18.2 Timing Closure & SRAM Port Discipline
- **Zero Combinational Bus Feedthrough:** Load data is registered into `er_retire_rd_data_q` before presentation to Stage E.
- **Zero New SRAM Ports:** Array remains strictly 1 R/W port. Zero layout congestion or cell-area increase.

---

## 19. Directed and Adversarial Verification Plan (34 Scenarios)

```
====================================================================================================
                     L1D-ER v1 DIRECTED & ADVERSARIAL VERIFICATION MATRIX (34 CASES)
====================================================================================================
ID          Category                  Description & Verification Objective
----------------------------------------------------------------------------------------------------
ER-DIR-01   Critical Beat Sweep       Clean load miss, Beat 0 (verifies 13 trailing burst cycles hidden).
ER-DIR-02   Critical Beat Sweep       Clean load miss, Beat 1 (verifies 11 trailing burst cycles hidden).
ER-DIR-03   Critical Beat Sweep       Clean load miss, Beat 2 (verifies 9 trailing burst cycles hidden).
ER-DIR-04   Critical Beat Sweep       Clean load miss, Beat 3 (verifies 7 trailing burst cycles hidden).
ER-DIR-05   Critical Beat Sweep       Clean load miss, Beat 4 (verifies 5 trailing burst cycles hidden).
ER-DIR-06   Critical Beat Sweep       Clean load miss, Beat 5 (verifies 3 trailing burst cycles hidden).
ER-DIR-07   Critical Beat Sweep       Clean load miss, Beat 6 (verifies 1 trailing burst cycle hidden).
ER-DIR-08   Critical Beat Sweep       Clean load miss, Beat 7 (verifies 0 trailing burst cycles; install).
ER-DIR-09   Dirty Victim              Dirty victim miss, Beat 0 (verifies 8-beat eviction completes before ER).
ER-DIR-10   Dirty Victim              Dirty victim miss, Beat 3 (verifies eviction + partial refill + ER).
ER-DIR-11   Dirty Victim              Dirty victim miss, Beat 7 (verifies eviction + full burst install).
ER-ADV-12   Multi-Cycle Stall         Critical beat arrives while Stage E stalled N cycles (P0-1).
ER-ADV-13   Stable Valid/Data Hold    retire_valid_o & data remain perfectly stable throughout N stall cycles.
ER-ADV-14   Exactly-Once Commit       Exactly one retirement commits when stall clears; minstret strobes once.
ER-ADV-15   Pre-Critical Bus Error    Bus error on b < b_crit; ceases requests, drains, poisons line, cause 5.
ER-ADV-33   Exact Critical-Beat Error Bus error exactly on b == b_crit; erroneous data is never consumable,
                                        no early retirement, precise cause 5, exact fault PC/mepc, poisoned safe
                                        drain, no install/valid/PLRU publication. Include translated Sv39 variant
                                        with VA != PA and require xTVAL == original full effective VA.
ER-ADV-34   Pending-ER Later Error    Good critical data and er_retire_valid, but no retire_ack; later beat errors.
                                        Cancel result; precise cause 5 with original VA; no fatal and no install.
ER-ADV-16   Acknowledged Later Error Later beat errors after authoritative retire_ack (including same-cycle ack/error
                                        ordering); committed load remains, no precise fault, line discarded, and
                                        top-level sticky fatal_halt_o stops ordinary execution until reset.
ER-ADV-17   Subsequent Load Stall     Subsequent load in Stage E stalls until INSTALL completes (P0-2).
ER-ADV-18   Store Buffer Drains Held  SB drain held (grant_sb_drain=0) throughout trailing refill (P0-2).
ER-ADV-19   Store Buffer Full Stall   SB reaches 4 entries during trailing refill; Stage E stalls safely.
ER-ADV-20   Independent ALU Overlap   Independent ALU/branch instructions execute during trailing burst.
ER-ADV-21   LR.W/D Exclusion          LR miss proves no early restart; reservation established at INSTALL (P0-3).
ER-ADV-22   SC.W/D Exclusion          SC proves no early restart; completes write-allocate at INSTALL (P0-3).
ER-ADV-23   AMO Exclusion             AMO miss proves no early restart; enters AMO_CYCLE2 after INSTALL (P0-3).
ER-ADV-24   SRB Collision Exclusion   Store miss during trailing refill holds SRB until INSTALL completes.
ER-ADV-25   Randomized Wait States    Refill requests/responses with randomized 0..5 cycle memory delays.
ER-ADV-26   Trap During Trailing Refill Synchronous trap in Stage E during burst; refill installs cleanly.
ER-ADV-27   Redirect While Valid      Drive real L1D redirect_i while valid is pending; drops valid, records squash,
                                        no commit. A subsequent refill error silently discards/drains with no fault,
                                        no fatal, no install; no unreachable core-level redirect claim.
ER-ADV-28   Maintenance FENCE         FENCE in Stage E stalls until trailing refill completes and bus idle.
ER-ADV-29   Maintenance SFENCE.VMA    SFENCE.VMA stalls until trailing refill completes before sweep.
ER-ADV-30   Context PMP CSR Write     PMP CSR write stalls until trailing refill completes before update.
ER-ADV-31   Atomic INSTALL Publication Line valid bit and data array write occurs atomically at INSTALL cycle.
ER-ADV-32   Tree-PLRU Exactly-Once    Tree-PLRU updates exactly once at INSTALL cycle for latched victim way.
====================================================================================================
```

---

## 20. Architecture Self-Audit and Repository Discipline

### 20.1 Verification Self-Audit Checklist
- [x] **No single-cycle retirement pulse remains:** Replaced by persistent `er_retire_valid_q` handshake (P0-1).
- [x] **No hit-under-refill claim remains:** Completely removed; subsequent loads stall until `INSTALL` (P0-2).
- [x] **No selective SB drain claim remains:** Completely removed; SB drains suspend until `INSTALL` (P0-2).
- [x] **LR/SC/AMO/Store excluded:** Explicitly latched `target_is_ordinary_load_q` required for early restart (P0-3).
- [x] **Retirement-based error classification:** `er_load_retired_q`, not beat position or result consumption, selects precise fault versus fatal; squash is independently represented.
- [x] **Original VA retained:** Every translated L1D-ER precise access fault reports the original full effective VA, never reconstructed PA.
- [x] **Pre-retirement bus errors defined:** Before-critical, exact-critical, and pending-result/later-beat errors have distinct coverage; unaccepted requests stop, traffic drains, the line is poisoned, and precise cause 5 uses the original VA.
- [x] **Early data strictly registered:** Formatted from flip-flop `refill_buf_q`, registered into `er_retire_rd_data_q` (P1-4).
- [x] **Unified FSM taxonomy:** Single primary FSM table with complete state transitions (P1-3).
- [x] **Rebuilt performance model:** 450k-550k conservative, 650k-750k expected, 952k burst ceiling, 1.063M upper bound (P1-2).
- [x] **Detection-edge priority defined:** All architectural side effects are gated on the raw error edge except the narrowly ordered same-load coincident acknowledgement; cleanup remains permitted.
- [x] **Platform fatal policy defined:** Sticky L1D-to-core-to-SoC `fatal_halt_o` stops normal execution, preserves protocol drain, and clears only on reset; no NMI is assumed.
- [x] **Production verification ports prohibited:** Stage-E stall uses simulation-only injection; the pending-result redirect corner is tested directly through real L1D `redirect_i`; no unreachable core stimulus is claimed.
- [x] **Expanded verification matrix:** Exact-critical, pending-unacknowledged later-error, acknowledged later-error, and post-squash cleanup are explicit; directed/adversarial total is 34 scenarios.
- [x] **Architecture-amendment scope:** The amendment itself changed specification and documentation only; RTL implementation follows only after independent acceptance.

### 20.2 Milestone Conclusion Status

The original L1D-ER v1 architecture was independently accepted. The first fatal-halt
amendment review returned 2 P0, 3 P1, and 1 P2 findings. The focused correction resolved
retirement-based error classification, original-VA fault reporting, detection-edge
side-effect priority, reachable redirect verification, strengthened error coverage, and
frozen-baseline terminology. The subsequent independent closure review returned
`ACCEPT AND RE-FREEZE — RTL AUTHORIZED`; all prior blocking findings are closed. The
remaining `res_invalidate_i` terminology observation is incorporated above: only
`redirect_i` participates in the ER squash lifecycle.

`L1D-ER v1 ARCHITECTURE ACCEPTED AND RE-FROZEN — RTL IMPLEMENTATION AUTHORIZED`
