# Fursoy Slice-0 L1I Demand Refill Early Restart & Streaming (L1I-ER v1) Architecture Contract

**Status:** L1I-ER v1 FINAL ARCHITECTURE CORRECTIONS COMPLETE — RTL STILL NOT AUTHORIZED  
**Milestone:** Milestone A — Demand Refill Critical-Beat Early Restart & Streaming Only  
**Target:** Fursoy Slice-0 (In-Order 2-Stage [F | E] Core)  
**Normative Baselines:**
- `docs/architecture/l1i-cache-v1.md` (Frozen L1 Instruction Cache v1 Contract)
- `docs/architecture/branch-prediction-v1.md` (Frozen Branch Prediction Unit v1 Contract)
- `docs/architecture/l1d-cache-v1.md` (Frozen L1 Data Cache v1 Contract)
- `docs/architecture/store-buffer-v1.md` (Frozen Store Buffer v1 Contract)
- `docs/architecture/l1d-srb-v1.md` (Frozen Store Refill Buffer v1 Contract)
- `docs/architecture/sv39-tlb-v1.md` (Frozen Sv39 TLB v1 Contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection Contract)
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 (Zifencei Instruction-Fetch Fence)

**Performance Baseline:** Frozen Post-BPU Milestone (25,763,419 cycles, 14,921,295 commits, IPC 0.579166, CPI 1.726621, 3,275,140 L1I refill stall cycles, accounting residual = 0).

---

## 1. Scope, Milestone Separation, and Architectural Authority

### 1.1 Architectural Scope & Roadmap Split
Following independent adversarial re-review:
* **Milestone A (This Document — L1I-ER v1):** Focuses exclusively on **Demand Refill Critical-Beat Early Restart & Streaming**. It generates **zero speculative DRAM traffic**, requires no prefetch buffers, introduces no speculative translation/PMP paths, and operates purely on demand instruction fetches that have already passed authoritative canonical, ITLB, and PMP checks.
* **Milestone B (Deferred — L1I-NLP v1):** Autonomous Next-Line Stream Prefetching is deferred to a separate future milestone and is **NOT authorized** for design or implementation in this task.

### 1.2 Target Bottleneck
In the frozen post-BPU profile, **L1I miss refill latency (3,275,140 cycles, 12.71% of total execution time)** represents the #1 system bottleneck (accounting for 30.21% of all non-useful cycles). L1I-ER v1 addresses this stall pool by delivering the demanded instruction word as soon as its containing 64-bit doubleword arrives and is registered from DRAM, decoupling execution resumption from the full 64-byte burst completion.

### 1.3 Strict Architectural Invariants
1. **Zero Speculative DRAM Traffic:** Memory requests are issued exclusively for confirmed demand misses.
2. **100% Contract Preservation:** Completely preserves frozen BPU v1, L1D v1, Store Buffer v1, and SRB v1 contracts.
3. **Strict Single-Port Datapath Adherence:** Respects the frozen single-port L1I directory and RAM arrays. Does not assume parallel or simultaneous tag lookups during active refills.
4. **No Retroactive Exceptions:** Instructions committed via early restart are never retroactively faulted by subsequent memory bus errors.
5. **Atomic Directory Publication:** Main L1I directory (`valid_q[set][way]`) and Tree-PLRU replacement state update if and only if the full 64-byte line completes without error or abort.

---

## 2. Interface, Beat Ordering, Registered Staging, and Sequential Streaming

### 2.1 Refill Interface & Latency Model
The dedicated 64-bit instruction memory interface (`imem_*`) operates with a 2-cycle beat transaction protocol (1 request cycle + 1 response cycle):
```systemverilog
output logic        imem_req_valid_o,
input  logic        imem_req_ready_i,
output logic [63:0] imem_req_addr_o,
input  logic        imem_rsp_valid_i,
output logic        imem_rsp_ready_o,
input  logic [63:0] imem_rsp_data_i,
input  logic        imem_rsp_error_i
```
An entire 64-byte line refill consists of 8 sequential 64-bit doubleword beats (`8 × 2 = 16 cycles` burst latency).

### 2.2 Address Decomposition and Beat-Level Bit Mapping (P2 Cleanup)
For 56-bit physical address `PA[55:0]`:
- **Line Base:** `PA[55:6] << 6` (64-byte aligned cache-line boundary).
- **Refill Beat Index (`b`):** `PA[5:3]` (3 bits, selecting 1 of the eight 64-bit doubleword beats, `0 ... 7`).
- **Instruction Subword Selector (`s`):** `PA[2]` (1 bit, selecting lower vs upper 32-bit instruction within that 64-bit beat):
  - `PA[2] == 1'b0`: selects lower 32 bits `[31:0]` (Word `2b`).
  - `PA[2] == 1'b1`: selects upper 32 bits `[63:32]` (Word `2b+1`).
- **Byte Offset:** `PA[1:0]` (must be `2'b00` for naturally aligned 32-bit RV64I instructions).
- **Instruction Word Index (`w`):** `PA[5:2]` (4 bits, selecting 1 of 16 instruction words within the line: `w = {PA[5:3], PA[2]} ∈ [0 ... 15]`).
- **Critical Beat Index (`b_crit`):** `w >> 1 = PA[5:3]`.
- **Critical Subword Selector (`s_crit`):** `w[0] = PA[2]`.

### 2.3 Beat Ordering: Natural Ascending Order (`0 → 1 ... → 7`)
Beats are requested and transferred in strict ascending order from Beat 0 to Beat 7:
`Beat Address = LineBase + (b × 8) for b ∈ [0 ... 7]`
- **Controller Compatibility:** Standard linear INCR burst; requires zero WRAP burst support or address modulo-8 arithmetic.
- **Forward Locality:** In RISC-V code, sequential instructions advance forward (`w → w+1`). Sourcing in ascending order ensures that trailing beats arriving behind the critical beat naturally service subsequent sequential instruction fetches.

### 2.4 Registered Staging Datapath & Stage-E Backpressure Decoupling (Resolving P0-2 & P1-7)
To prevent transient memory bus coupling and ensure timing closure into Stage-E decode, L1I-ER v1 mandates **strict registered staging**:

```
                  +----------------------------------------------+
                  |  Memory Interface: imem_rsp_data_i [63:0]    |
                  +----------------------------------------------+
                                         |
                       [Clock Edge T -> T+1 on Handshake]
                                         v
                  +----------------------------------------------+
                  |     refill_buf_q [b] <= imem_rsp_data_i      |
                  |     refill_beat_valid_q [b] <= 1'b1          |
                  |     refill_beat_error_q [b] <= imem_rsp_err  |
                  +----------------------------------------------+
                                         |
                                (Cycle T+1 Stable)
                                         v
+--------------------------------------------------------------------------------+
| Output Holding Registers:                                                      |
|   held_insn_q <= s_crit ? refill_buf_q[b][63:32] : refill_buf_q[b][31:0]       |
|   held_pc_q   <= req_pc_q                                                      |
|   held_valid_q <= 1'b1                                                         |
|   fetched_valid_o = 1'b1 (asserted stably to Stage E)                          |
+--------------------------------------------------------------------------------+
```

#### Protocol Rules:
1. **No Combinational Memory Forwarding:** `imem_rsp_data_i` is never wired combinationally to `fetched_insn_o`. Every beat is clocked into `refill_buf_q[b]` on the cycle it handshakes.
2. **Deterministic Early-Restart Latency:**
   - Cycle `T`: Memory asserts `imem_rsp_valid_i` for critical beat `b_crit`.
   - Clock edge `T → T+1`: Beat data is latched into `refill_buf_q[b_crit]`.
   - Cycle `T+1`: Instruction is presented stably to Stage E via `held_*` holding registers.
   - Total latency from miss detection to Stage-E early restart:
     `Latency = 1 (miss detect) + 2 × (b_crit + 1) (beats) + 1 (registered staging) = 2 × b_crit + 4 cycles`
     Compared to the 18-cycle baseline, early restart saves:
     `Cycles Saved = 14 - 2 × b_crit cycles`
3. **Stage-E Backpressure Decoupling:**
   - If Stage E is stalled (`fetched_ready_i == 0`) at Cycle `T+1`:
     - `held_valid_q`, `held_pc_q`, `held_insn_q`, and `held_error_q` hold their exact values indefinitely.
     - `fetched_valid_o = 1` remains stably asserted to Stage E.
     - **Independent Trailing Refill:** The refill state machine **continues handshaking trailing beats (`b_crit+1 ... 7`) from DRAM independently**. Trailing beats fill `refill_buf_q[b]` without disturbing the held instruction.
     - When Stage E finally asserts `fetched_ready_i == 1`, the instruction transfers atomically (`transfer_fire_f`), clearing the hold state.
     - Telemetry strobe `l1i_early_restart_event_o` pulses **strictly once** on Cycle `T+1`, never re-pulsing while Stage E remains stalled.

---

### 2.5 Normative Intra-Line Sequential Streaming Protocol

Once the critical instruction becomes available at Cycle `T+1`, early restart releases the normal full-refill stall. While the remainder of the demand line is still being refilled from DRAM (Beats `b_crit+1 ... 7`), Stage F continues sequential instruction execution within the line according to the following normative rules:

#### 2.5.1 Demanded Next Instruction Addressing
When Stage E accepts the currently delivered instruction and advances sequentially to `PC + 4`:
1. Stage F computes the next physical word coordinates within the active line:
   - Next Word Index: `w_next = PC[5:2]`
   - Next Beat Index: `b_next = PC[5:3]`
   - Next Subword Selector: `s_next = PC[2]`
2. **Line Residency Check:**
   Stage F verifies that `PC[55:6] == refill_line_base[55:6]`. If execution leaves the active line, see §2.5.5.

#### 2.5.2 Servicing from Registered Refill Storage (`refill_buf_q`)
Instruction bits are **strictly sourced from registered refill storage (`refill_buf_q`)**, never directly from transient external signals (`imem_rsp_data_i`):
`stream_insn = s_next ? refill_buf_q[b_next][63:32] : refill_buf_q[b_next][31:0]`

#### 2.5.3 Beat Status and Stage-F Control Behavior
For demanded beat `b_next`:
1. **Case 1 — Hit in Already-Arrived Beat (`refill_beat_valid_q[b_next] == 1 && refill_beat_error_q[b_next] == 0`):**
   - The doubleword is already stably present in `refill_buf_q[b_next]`.
   - `held_insn_q <= stream_insn`, `held_pc_q <= PC`, `held_valid_q <= 1'b1`, `held_error_q <= 1'b0`.
   - `fetched_valid_o = 1'b1` asserts combinationally to Stage E.
   - `l1i_miss_active_o = 1'b0` remains deasserted.
   - **Performance:** **0 stall cycles.** Stage E consumes the instruction immediately with zero wait latency.
2. **Case 2 — Temporary Streaming Wait on Pending Beat (`refill_beat_valid_q[b_next] == 0`):**
   - Beat `b_next` has not yet arrived from DRAM.
   - Stage F asserts temporary streaming backpressure:
     - `fetched_valid_o = 1'b0` (held output deasserted until beat arrives).
     - `l1i_miss_active_o = 1'b1` (asserts `stall_f`, holding `pc_f_q` in Stage F).
   - The memory bus handshake continues advancing trailing beats.
   - On the exact cycle Beat `b_next` arrives and is clocked into `refill_buf_q[b_next]`:
     - At clock edge `T → T+1`, `refill_beat_valid_q[b_next] <= 1'b1`.
     - At Cycle `T+1`, `held_insn_q <= stream_insn`, `held_valid_q <= 1'b1`, `fetched_valid_o = 1'b1`.
     - `l1i_miss_active_o = 1'b0` deasserts, immediately releasing Stage F.
     - **Performance:** Stalls only for the remaining cycles until Beat `b_next` arrives (1 to 2 cycles), completely avoiding stalling for Beat 7.
3. **Case 3 — Poisoned Beat Demanded (`refill_beat_valid_q[b_next] == 1 && refill_beat_error_q[b_next] == 1`):**
   - Beat `b_next` experienced a memory bus error when it arrived.
   - `held_valid_q <= 1'b1`, `held_error_q <= 1'b1`, `held_insn_q <= 32'd0`.
   - Stage E takes the precise `instruction access fault` (`mcause = 1`) for this exact demanded PC.

#### 2.5.4 Handshake, Acceptance, and Arbitrary Stage-E Backpressure
1. **Transfer Event:** Instruction transfer into Stage E occurs atomically when:
   `transfer_fire_f = fetched_valid_o && fetched_ready_i && !redirect_any_e`
2. **Backpressure Decoupling:**
   If Stage E is backpressured (`fetched_ready_i == 0` due to `stall_e` from LSU store buffer full, long divide, or CSR wait):
   - The current instruction remains stably asserted in `held_*` (`fetched_valid_o = 1`).
   - The refill controller **continues absorbing trailing beats from DRAM into `refill_buf_q` independently**.
   - Instruction delivery is guaranteed **strictly exactly-once** upon `transfer_fire_f`.

#### 2.5.5 Boundary Transitions: Terminal Beat 7 and Leaving the Active Line
1. **Execution Reaches Beat 7:**
   - When the instruction at Word 15 (`w = 15`, Beat 7 upper subword) is accepted, the entire 64-byte line has been consumed.
   - By this time, Beat 7 has arrived, completed the burst, and atomically installed the line into L1I (or is completing Beat 7 on the same cycle).
   - Sequential advance to `PC + 4` crosses into the next cache line (`LineBase + 64`).
   - Stage F initiates a standard `FETCH_CHECK` lookup for the new line address.
2. **Execution Leaves the Active Line (Branch Taken / Redirect):**
   - If execution takes a branch or redirects away from the active refill line before Beat 7:
   - Handled strictly by the Option A redirect policy (§4.2).

---

## 3. Exception Precision & Per-Beat Error/Poison Architecture (Resolving P0-1)

### 3.1 Motivation
If critical beat `b_crit` arrives cleanly, the instruction is delivered, decoded, and may commit. If trailing beat `b_trail > b_crit` subsequently encounters `imem_rsp_error_i == 1`, the core must **never retroactively fault** the already committed instruction.

### 3.2 State Tracking
The controller maintains two 8-bit registers and one sticky line-error latch:
- `refill_beat_valid_q[7:0]`: Bit `b` is set when Beat `b` is accepted.
- `refill_beat_error_q[7:0]`: Bit `b` is set if `imem_rsp_error_i` was asserted when Beat `b` was accepted.
- `line_has_error_q`: Latch set to `1'b1` if any beat asserted `imem_rsp_error_i`.

### 3.3 Precise Demand Fault Delivery
1. **Critical Beat Error:**
   If Beat `b_crit` errors upon arrival (`refill_beat_error_q[b_crit] == 1`):
   - At Cycle `T+1`, `held_error_q <= 1'b1`, `held_valid_q <= 1'b1`, `held_insn_q <= 32'd0`.
   - Stage E raises an immediate, precise `instruction access fault` (`mcause = 1`) with `mtval = req_pc_q`.
2. **Trailing Beat Error (Poisoning):**
   If trailing beat `b_trail` errors (`refill_beat_error_q[b_trail] == 1`):
   - `line_has_error_q <= 1'b1`.
   - **No immediate asynchronous exception is generated.**
   - If execution proceeds sequentially into Beat `b_trail`:
     - When Stage F demands the instruction in Beat `b_trail`, it observes `refill_beat_error_q[b_trail] == 1`.
     - Stage F asserts `fetched_error_o = 1'b1` precisely for that demanded PC.
     - Stage E takes the precise `instruction access fault` at the exact PC of the poisoned instruction.
   - If execution redirects away before reaching Beat `b_trail`:
     - The poisoned beat is never demanded.
     - **Zero architectural synchronous exception is ever generated.**
3. **Prohibition of Erroneous Line Publication:**
   - On Beat 7, the line is written to L1I **if and only if** `line_has_error_q == 0`.
   - A line with any poisoned beat is **never installed** (`valid_q` remains 0, PLRU untouched).

---

## 4. Pipeline Redirects and Single-Port Datapath Compliance (Reviewer Option A)

### 4.1 Single-Port Resource Constraint
Fursoy Slice-0 employs a single-port L1I SRAM/register array. The refill controller owns the tag comparators and array write ports during active burst reception. An unrelated redirect target **cannot** perform a parallel tag lookup while a refill is in-flight without adding dual-port hardware.

### 4.2 Reviewer Option A: Unconditional Abort on Redirect (Zero-Interface-Change Policy)
To strictly preserve the frozen single-port datapath without introducing new interface ports or complex hazard logic, L1I-ER v1 adopts **Reviewer Option A**:

> **ANY `redirect_i` asserted during an active refill sets `refill_abort_q` and causes the line to be unconditionally discarded at Beat 7.**

No attempt is made to distinguish architectural branch redirects from maintenance redirects inside L1I.

```
+-----------------------------------------------------------------------------------+
| Refill In-Flight (state_q == REFILL_REQ || state_q == REFILL_RSP)                 |
|                                                                                   |
| [ANY Redirect asserts: redirect_i == 1]                                           |
|   -> pending_redirect_pc_q <= fetch_pc_i;                                         |
|   -> redirect_pending_q    <= 1'b1;                                               |
|   -> refill_abort_q        <= 1'b1;  (UNCONDITIONAL ABORT LATCH)                  |
|   -> held_valid_q          <= 1'b0;  (IMMEDIATELY REVOKE HELD INSTRUCTION)        |
|   -> fetched_valid_o       = 1'b0;   (STOP STREAMING ABANDONED DATA)              |
+-----------------------------------------------------------------------------------+
                                         |
            (Continue absorbing accepted external burst through Beat 7)
                                         v
+-----------------------------------------------------------------------------------+
| Burst Complete (Beat 7)                                                           |
|   -> UNCONDITIONALLY DISCARD LINE (valid_q remains 0)                             |
|   -> DO NOT UPDATE TREE-PLRU                                                      |
|   -> refill_abort_q <= 1'b0                                                       |
+-----------------------------------------------------------------------------------+
                                         |
                   (Release single-port L1I directory)
                                         v
+-----------------------------------------------------------------------------------+
| Transition to FETCH_CHECK with req_pc_q <= pending_redirect_pc_q                  |
| redirect_pending_q <= 1'b0                                                        |
| Perform standard 1-cycle L1I tag lookup for redirect target                       |
+-----------------------------------------------------------------------------------+
```

#### Exact Operational Semantics:
1. **Redirect Target Capture:** When `redirect_i == 1` asserts, the redirect target is latched: `pending_redirect_pc_q <= fetch_pc_i`, and `redirect_pending_q <= 1'b1`.
2. **Immediate Delivery Revocation:** `held_valid_q <= 1'b0` and `held_is_hit_q <= 1'b0`. Any buffered instruction that has not yet been accepted by Stage E is immediately revoked. `fetched_valid_o` deasserts to 0. Zero instruction bits from the abandoned refill are ever delivered to Stage E.
3. **Bus Handshake Completion:** The in-flight DRAM burst continues handshaking through Beat 7 (`imem_rsp_ready_o <= 1'b1` when `imem_rsp_valid_i`). This preserves memory bus protocol integrity and prevents dangling responses.
4. **Unconditional Line Discard:** Upon Beat 7, because `refill_abort_q == 1`, cache array write is completely inhibited (`valid_q` remains 0) and Tree-PLRU state is **not updated**.
5. **Clean Resource Release & Redirect Lookup:** Once Beat 7 completes, `refill_abort_q <= 0` and `redirect_pending_q <= 0`. The L1I directory and tag arrays are now fully released. The state machine transitions to `FETCH_CHECK` with `req_pc_q <= pending_redirect_pc_q`, performing a clean 1-cycle tag comparison for the redirect target.

---

## 5. Maintenance Operations during Partial Refill (Resolving P0-4)

The table below defines the deterministic behavior for all maintenance operations across all temporal phases of a partial refill:

| Phase of Partial Refill | Trigger Event | Invalidation Action | Delivery & Publication Action |
| :--- | :--- | :--- | :--- |
| **Phase 1: Before Critical Beat** (`b < b_crit`) | `FENCE.I` / `pmp_flush` / `satp` / `SFENCE` / `rst_i` | Set sticky `refill_abort_q <= 1'b1`; flash-invalidate main L1I `valid_q <= 0` (for FENCE.I/PMP/reset). | Early restart is inhibited (`held_valid_q <= 0`); trailing beats absorbed; line discarded on Beat 7 (`valid_q` untouched). |
| **Phase 2: Critical Beat Buffered under Stall** | `FENCE.I` / `pmp_flush` / `satp` / `SFENCE` / `rst_i` | Set `refill_abort_q <= 1'b1`; flash-invalidate `valid_q <= 0`. | **Immediately revoke buffered instruction** (`held_valid_q <= 0`, `held_is_hit_q <= 0`); line discarded on Beat 7; Stage E never consumes pre-maintenance instruction. |
| **Phase 3: After Early Restart** (Instruction Committed) | `FENCE.I` / `pmp_flush` / `satp` / `SFENCE` / `rst_i` | Set `refill_abort_q <= 1'b1`; flash-invalidate `valid_q <= 0`. | Instruction already committed; trailing beats absorbed; line discarded on Beat 7 (pre-maintenance code never installs into L1I). |
| **Phase 4: Trailing Refill** (`b > b_crit`) | `FENCE.I` / `pmp_flush` / `satp` / `SFENCE` / `rst_i` | Set `refill_abort_q <= 1'b1`; flash-invalidate `valid_q <= 0`. | Trailing beats absorbed; line discarded on Beat 7. |
| **Phase 5: Refill with Poisoned Beat** | `FENCE.I` / `pmp_flush` / `satp` / `SFENCE` / `rst_i` | Set `refill_abort_q <= 1'b1`; `line_has_error_q` already high. | Line discarded on Beat 7; zero exception raised if poisoned beat was never consumed. |

---

## 6. Replacement Policy and Main Directory Atomic Publication (Resolving P0-5 & P1-8)

### 6.1 Tree-PLRU Function & Victim Selection
L1I-ER v1 preserves the exact frozen Tree-PLRU functions from `docs/architecture/l1i-cache-v1.md`:
- **Victim Selection at Miss Initiation (`FETCH_CHECK`):**
  `refill_victim ← plru_victim(plru_q[check_set_idx], valid_q[check_set_idx])`
  The victim way is latched once at miss initiation and held stable throughout the refill.
- **Tree-PLRU Directory Update at Beat 7:**
  The 3-bit PLRU decision tree is updated to point away from `refill_victim` **if and only if** the line installs successfully:
  `plru_q[refill_set_idx] ← plru_update(plru_q[refill_set_idx], refill_victim)`
  If the refill is aborted (`refill_abort_q == 1`) or poisoned (`line_has_error_q == 1`), the PLRU state is **not updated**.

### 6.2 Atomic Cache Line Installation Rule
The main cache arrays (`valid_q`, `tag_q`, `data_q`) are written **atomically on Beat 7** if and only if:
`refill_beat_cnt == 7 && !refill_abort_q && !line_has_error_q && !imem_rsp_error_i`
A partially refilled line is **never** marked valid in `valid_q`.

---

## 7. Telemetry & Observability Interface (Resolving P1-6)

All telemetry event strobes pulse **strictly for 1 clock cycle per logical occurrence**, implemented via registered one-shot edge latches:

```systemverilog
// Authoritative Telemetry Strobes (Strictly Exactly-Once)
output logic       l1i_hit_event_o,                 // 1 cycle per committed hit
output logic       l1i_miss_event_o,                // 1 cycle on miss initiation
output logic       l1i_refill_event_o,              // 1 cycle on clean line installation
output logic       l1i_early_restart_event_o,       // 1 cycle on critical beat capture
output logic [3:0] l1i_early_restart_saved_cycles_o // Exact cycles saved (14 - 2 * b_crit)
```

- `early_restart_pulsed_q`: Sets when `l1i_early_restart_event_o` fires at Cycle `T+1`. Cleared only upon refill completion or abort. Guarantees that multi-cycle Stage-E stalls never re-pulse telemetry.

---

## 8. Verification Architecture & Adversarial Directed Test Matrix

The verification plan mandates a dedicated testbench (`verification/l1i_er_s0_tb.cpp` and runner `tools/run_l1i_er_s0.py`) covering all baseline refill tests plus the following 16 adversarial scenarios:

| Test ID | Scenario Description | Pass Criteria |
| :--- | :--- | :--- |
| `REFILL-ADV-01` | Stage-E stalled when critical beat arrives | `fetched_ready_i = 0`; critical instruction held stable in `held_*`; trailing beats continue to handshake; delivery occurs exactly once when ready asserts. |
| `REFILL-ADV-02` | Critical instruction commits, trailing beat errors | Critical instruction commits cleanly; later beat asserts `imem_rsp_error_i`; verify no retroactive exception; poisoned beat marked; line not installed in L1I. |
| `REFILL-ADV-03` | Poisoned trailing beat later demanded | Sequential execution reaches poisoned beat; verify precise `instruction access fault` raised for that exact PC; `mtval = PC`. |
| `REFILL-ADV-04` | Poisoned trailing beat never demanded | Branch redirects away before poisoned beat; verify zero architectural exception raised; line not installed in L1I. |
| `REFILL-ADV-05` | Maintenance before critical beat | `FENCE.I` asserts on Beat 1; critical beat is Beat 4; verify early restart suppressed; trailing beats absorbed; line discarded on Beat 7. |
| `REFILL-ADV-06` | Maintenance while critical instruction is buffered | Critical beat arrives while Stage E stalled; `FENCE.I` asserts; verify `held_valid_q` immediately revoked; no stale instruction commits. |
| `REFILL-ADV-07` | Maintenance after early restart | Critical instruction commits; `FENCE.I` executes during Beat 5; main L1I valid cleared; trailing beats absorbed; line discarded on Beat 7. |
| `REFILL-ADV-08` | Branch redirect immediately after early restart | Branch resolves taken on early-restarted instruction; redirect PC latched; line discarded at Beat 7 per Option A; redirect target checked next. |
| `REFILL-ADV-09` | Branch redirect while critical instruction is held under stall | Branch redirect asserts while critical instruction waiting in `held_*`; buffered instruction revoked; redirect PC latched; burst completes. |
| `REFILL-ADV-10` | Full-line install prohibited on error | Beat 6 errors; verify on Beat 7 that `valid_q[set][victim] == 0` and Tree-PLRU is not updated. |
| `REFILL-ADV-11` | Hardware reset during partial refill | `rst_i` asserted on Beat 3; verify bus returns to clean idle; `valid_q` reset; core vectors to `RESET_PC`. |
| `REFILL-ADV-12` | Back-to-back demand misses | Miss on Line `A` followed immediately by miss on Line `B`; verify clean handoff between bursts without bus hang. |
| `REFILL-ADV-13` | Exactly-once telemetry under long Stage-E stall | Stage E stalled for 50 cycles after critical beat arrival; verify `l1i_early_restart_event_o` pulses for exactly 1 cycle. |
| `REFILL-ADV-14` | Tree-PLRU updated exactly once | Verify Tree-PLRU state updates on Beat 7 and matches authoritative decision tree equation. |
| `REFILL-ADV-15` | Stale refill identity across `satp` write | `satp` CSR write during refill; verify line discarded on Beat 7; subsequent fetch misses cleanly in new address space. |
| `REFILL-ADV-16` | Sequential Streaming Hit in Refill Buffer | Critical instruction early-restarts; next sequential word in already received beat is delivered from `refill_buf_q` without waiting for Beat 7; sequential transition into pending beat waits only until that beat arrives; no duplicate delivery; trailing refill completes cleanly. |

---

## 9. Analytical Performance Hypothesis (Milestone A Only)

*Note: All figures below are analytical hypotheses derived from empirical post-BPU telemetry and do not constitute verified RTL claims until verification completion.*

### 9.1 Empirical Inputs (from Frozen Post-BPU Milestone)
- Total execution cycles: **25,763,419**
- Committed instructions: **14,921,295** (IPC: **0.579166**, CPI: **1.726621**)
- Total L1I demand refills: **207,901**
- L1I miss refill stall pool: **3,275,140 cycles** (average 15.75 cycles per refill)
- Critical beat distribution: Empirical Linux kernel code has average critical beat index `E[b_crit] ≈ 3.2` (uniform midpoint = 3.5).

### 9.2 Cycle Savings & Penalty Breakdown
1. **Gross Early Restart Savings:**
   - With registered staging, latency to early restart is `2 × b_crit + 4 cycles`.
   - Cycles saved per refill: `14 - 2 × b_crit`.
   - For uniform `E[b_crit] = 3.5`: `14 - 7.0 = 7.0 cycles/refill`.
   - For empirical `E[b_crit] = 3.2`: `14 - 6.4 = 7.6 cycles/refill`.
   - **Gross Savings Pool:**
     - Conservative (7.0 cycles): `207,901 × 7.0 = +1,455,307 cycles`
     - Midpoint (7.6 cycles): `207,901 × 7.6 = +1,580,047 cycles`
2. **Unavoidable Trailing Refill Stalls (Option A Redirect Interactions):**
   - Under Option A, if execution branches to another address before Beat 7, the line is discarded and the subsequent demand miss waits for the in-flight burst to finish (averaging ~4 wait cycles on ~12% of refills):
     `Tail Wait Penalty ≈ 207,901 × 0.12 × 4 ≈ -100,000 cycles`
3. **Backend Stall Migration:**
   - Faster frontend instruction issue increases retirement density into Stage E, migrating ~18% of savings into Store Buffer full backpressure and L1D load arbitration stalls:
     `Backend Migration Penalty ≈ 1,455,307 × 0.18 ≈ -262,000 cycles`
4. **Net Projected Cycle Reduction:**
   `Δ_net = 1,455,307 - 100,000 - 262,000 ≈ -1,093,000 cycles (Conservative)`
   `Δ_net = 1,580,047 - 100,000 - 284,000 ≈ -1,196,000 cycles (Midpoint)`

### 9.3 Performance Projection Summary (Milestone A Only)

| Metric | Measured Post-BPU Baseline | Conservative Projection | Midpoint Projection | Optimistic Projection |
| :--- | :---: | :---: | :---: | :---: |
| **Gross Early Restart Savings** | — | +1,455,000 cycles | +1,580,000 cycles | +1,700,000 cycles |
| **Tail Wait & Backend Migration** | — | -362,000 cycles | -384,000 cycles | -420,000 cycles |
| **Net Cycle Reduction** | — | **-1,093,000 cycles** | **-1,196,000 cycles** | **-1,280,000 cycles** |
| **Total Execution Cycles** | 25,763,419 | **24,670,000** | **24,567,000** | **24,483,000** |
| **Projected IPC** | 0.579166 | **0.6048 IPC** | **0.6074 IPC** | **0.6094 IPC** |
| **Throughput Speedup** | baseline | **+4.43%** | **+4.88%** | **+5.22%** |
| **Projected CPI** | 1.726621 | **1.6534** | **1.6464** | **1.6408** |

*Zero contribution from prefetch is included in these figures.*

---

## 10. Roadmap Preservation: Milestone B (L1I-NLP v1 Deferred)

Autonomous Next-Line Stream Prefetching (L1I-NLP v1) is preserved as an independent future optimization:
- It shall be considered only after Milestone A (L1I-ER v1) is fully verified and frozen.
- It will be evaluated with its own dedicated architecture contract, addressing bus contention, prefetch throttling, and page-guard verification.

---
