# Fursoy Slice-1 Milestone 2 — Integer Out-of-Order Scheduling and Execution Backend Architecture Specification

**Document ID:** `docs/architecture/slice1-m2-backend-v1.md`  
**Status:** ARCHITECTURAL SPECIFICATION v1.1 (Milestone 2 Focused Correction Baseline)  
**Target Core:** Fursoy Slice-1 (Milestone 2: Integer OoO Backend, RV64IMAZbaZbb)  
**Predecessor Substrate:** Fursoy Slice-1 Milestone 1 (Verified & Frozen Substrate: PRF80, ROB48, FreeList48, SRAT/ARAT, Recovery)  
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m2-backend-v1.md`

> **Post-Phase-3 RTL Note (`bab4ceb`):** While this document preserves the frozen Milestone 2 integer-backend baseline (`PRF80`, `ROB48`, `IntIQ16`, `8` checkpoints), the production core (`docs/architecture/slice1-core-v1.md`) scales these to `PRF = 160`, `ROB = 128`, `IntIQ = 32`, `NUM_CHECKPOINTS = 16`, and uses the shared 64-bit Kogge-Stone `fursoy_s1_ks_adder` in `fursoy_s1_alu` and `fursoy_s1_branch_unit`.

---

## 1. Executive Summary & Milestone Scope

### 1.1 Context & Objective
Fursoy Slice-1 Milestone 1 (M1) established and froze the architectural rename, allocation, and recovery substrate:
- 2-wide rename / dispatch with intra-group RAW/WAW dependency resolution;
- 80-entry Physical Register File (PRF) readiness metadata tracking (`fursoy_s1_prf_status.sv`);
- 48-entry circular Reorder Buffer (ROB) with 4-bit per-slot generation tags (`rob_epoch_t`) for stale-completion immunity;
- 48-entry circular Free List with backwards squash recovery (2 uops/cycle) and deterministic full-flush reconstruction;
- 8 branch checkpoints with single-cycle speculative SRAT rollback;
- Complete physical register ownership and disjoint-set invariants.

**Milestone 2 (M2)** turns this bookkeeping substrate into a functional, high-throughput, timing-loop-free **Integer Out-of-Order Execution Backend**.

### 1.2 In-Scope for Milestone 2
1. **64-bit Physical Register File (PRF)** data storage array semantics (`80 × 64-bit` registers) with M1-validated write-enable gating.
2. **Integer Issue Queue (IntIQ)**: 16-entry out-of-order scheduler with wrap-safe ROB-head-relative age selection and port-aware dual-issue matching.
3. **Conservative, Loop-Free Pipeline Staging**: Authoritative `DS -> IS -> RF -> EX -> validated WB -> CMT` timing model with zero unvalidated bypass paths.
4. **Execution Port 0**: ALU0 (64-bit base integer, shifts, Zba, Zbb) + Branch Resolution Unit with lifetime-gated recovery requests.
5. **Execution Port 1**: ALU1 (symmetric integer ALU) + Pipelined Multiplier + Radix-4 Iterative Divider.
6. **Provably Lossless Port 1 Completion Network**: Credit-reserved per-unit completion queues preventing buffer overflow under arbitrary collision patterns.
7. **End-to-End Epoch Lifetime Protection**: Result validation via M1 `comp_ack_o` gating PRF data writes, PRF readiness updates, ROB completion, and recovery requests.
8. **RV64M Normative Corner-Case Compliance**: Exact sign-extended 32-bit results for all W-forms (`DIVW`, `DIVUW`, `REMW`, `REMUW`, `MULW`).
9. **Branch Execution Interface**: Future-facing branch prediction metadata (`pred_taken`, `pred_target`, type flags) and actual-vs-predicted evaluation.
10. **Squash & Active Invalidation Mechanics**: Clearing younger IntIQ entries, multiplier stages, divider FSM (`divider_cancel_i`), and Port 1 completion buffers.
11. **Comprehensive M2 Verification Contract**: Directed, adversarial, and randomized test matrices with formal-grade assertions.

### 1.3 Out-of-Scope for Milestone 2 (Deferred to Later Milestones)
- **Port 2 / LSU / Memory Execution**: AGU execution, Mem-IQ, Load Queue, Store Queue, L1D cache, MSHRs, and atomics belong strictly to Milestone 3 (M3). Port 2 writeback interfaces are reserved and tied idle (`comp_valid_i[2] = 1'b0`) in M2.
- **Frontend & Fetch**: Decoupled instruction fetch queue, L1I cache, branch predictor algorithms (BTB/RAS/TAGE), and ITLB belong to Milestone 4 (M4).
- **System / Privilege / MMU**: CSR execution, Sv39 page walks, PMP checks, and interrupts remain as verified in Slice-0 and M1 substrate contracts.

---

## 2. Microarchitecture Specification: Subsystem by Subsystem

### 2.1 Physical Register File (PRF) Data Storage & Validation

```
+===================================================================================================+
|                               64-BIT PHYSICAL REGISTER FILE (PRF)                                 |
+===================================================================================================+

   Writeback Ports (M2: 2W, Target: 3W)                   Read Ports (M2: 4R, Target: 6R)
   
   Port 0 Res (ALU0/BR)  ===> [W0: 64b]                   [R0: 64b] ===> Port 0 Operand A (ALU0/BR)
   Port 1 Res (ALU1/M/D) ===> [W1: 64b]   +-----------+   [R1: 64b] ===> Port 0 Operand B (ALU0/BR)
   [Port 2 Res (LSU)]    ===> [W2: Idle]  |  80 x 64b |   [R2: 64b] ===> Port 1 Operand A (ALU1/M/D)
                                          | Registers |   [R3: 64b] ===> Port 1 Operand B (ALU1/M/D)
                                          | (p0..p79) |   [R4: Idle]===> [Port 2 Base / AGU]
                                          +-----------+   [R5: Idle]===> [Port 2 Store Data]
                                                |
                                                v
                                  p0 unconditionally reads 64'd0
                                  Writes to p0 are strictly suppressed
```

#### 2.1.1 Logical Interface & Port Requirements
- **Storage Capacity**: Exactly 80 physical registers (`p_0` to `p_79`), each 64 bits wide.
- **Milestone 2 Port Requirements**:
  - **Read Ports**: 4 logical read ports (2 operands for Port 0, 2 operands for Port 1).
  - **Write Ports**: 2 logical write ports (1 result from Port 0, 1 result from Port 1).
- **Eventual Full Backend Compatibility**:
  - The abstract PRF interface scales to **6 Read Ports and 3 Write Ports** (6R3W) in M3 when Port 2 (LSU) is activated, preserving M1 allocation namespaces and invariants.

#### 2.1.2 Register `p_0` Semantics
- Register `p_0` is hardwired to `64'h0000_0000_0000_0000`.
- Any read of physical register `p_0` unconditionally returns zero on the same cycle without reading array storage.
- Any writeback targeting `p_0` is combinationally or synchronously suppressed. `p_0` is immutable.

#### 2.1.3 PRF Data Write-Enable Lifetime Gating (Resolution of P0-1)
- **Correctness Invariant**: A result may modify PRF data storage **ONLY** after the M1 substrate accepts the corresponding completion lifetime.
- **Write-Enable Logic**:
  `prf_we[w] = wb_valid[w] && comp_ack_o[w] && (wb_pnew[w] ≠ p_0)`
- **Stale-Completion Quarantine**:
  When an execution unit finishes, it presents `{data, pnew, rob_idx, rob_epoch}` to the writeback network.
  The M1 substrate validates `comp_epoch_i[w] == rob_entry[idx].epoch`.
  If the epoch does not match (or the entry is invalid), M1 asserts `comp_ack_o[w] = 1'b0`.
  A rejected (stale) completion MUST NOT:
  1. Write PRF data storage (`prf_we = 1'b0`);
  2. Assert PRF readiness (`fursoy_s1_prf_status` is already gated by `comp_ack_o`);
  3. Mark ROB completion in M1;
  4. Record an exception in ROB;
  5. Assert branch mispredict recovery;
  6. Wake dependent instructions in IntIQ.

#### 2.1.4 Bypass Validation & PRF Read Timing
- **Execution Bypass Rule**: Any data forwarded via execution bypass from the writeback stage to an issuing consumer MUST be qualified with `comp_ack_o`. Unvalidated speculative data is never forwarded to live consumers.
- **RF Read Timing**: Since PRF writes occur on the clock edge following validated writeback, consumers reading PRF in stage `RF` read stable, committed PRF data cells.
- **Physical Organization Status**:
  - **The abstract logical 4R2W (scalable to 6R3W) interface is FROZEN**.
  - The underlying physical realization (monolithic multi-ported array vs. 2-way banked `2 × (3R2W)` vs. replicated arrays for FPGA) remains **PROVISIONAL**.

---

## 2.2 Integer Issue Queue (IntIQ) Architecture

```
+===================================================================================================+
|                                16-ENTRY INTEGER ISSUE QUEUE (IntIQ)                               |
+===================================================================================================+

  Dispatch Stage (2 uops/cycle, gated by M1 rename_ack_o)
        |
        v
  +-----------------------------------------------------------------------------------------------+
  | Entry 0  | V | UOP_CTRL | PRS1 [6:0] | R1 | PRS2 [6:0] | R2 | PNEW [6:0] | ROB_TAG | PRED_META  |
  | Entry 1  | V | UOP_CTRL | PRS1 [6:0] | R1 | PRS2 [6:0] | R2 | PNEW [6:0] | ROB_TAG | PRED_META  |
  |   ...    | . |   ...    |    ...     | .. |    ...     | .. |    ...     |   ...   |   ...      |
  | Entry 15 | V | UOP_CTRL | PRS1 [6:0] | R1 | PRS2 [6:0] | R2 | PNEW [6:0] | ROB_TAG | PRED_META  |
  +-----------------------------------------------------------------------------------------------+
        ^                   ^                                                 |
        |                   | (Validated Wakeup Tags from WB: 2 ports)        v
  Squash / Flush            +=====================================   Port-Aware Bipartite Arbiter
  Recovery Bus                                                       (ROB-Head-Relative Age Order)
                                                                              |
                                                                              +---> Issue Port 0 (ALU0/BR)
                                                                              +---> Issue Port 1 (ALU1/M/D)
```

#### 2.2.1 Entry Structure & Metadata
The IntIQ contains **16 entries** (provisional capacity). Each entry buffers:
1. `valid` (1 bit): Entry occupancy flag.
2. `uop_class` (4 bits): Operation category (ALU_INT, ALU_SHIFT, ALU_ZBA, ALU_ZBB, BRANCH, JAL, JALR, MUL, DIV).
3. `sub_op` (4 bits): Specific operation opcode (e.g. ADD, SUB, SLT, AND, SLLW, CLZ, DIVW, REMUW).
4. `imm` (64 bits): Sign-extended immediate or displacement operand.
5. `use_imm` (1 bit): Indicates operand B is taken from `imm` rather than `prs2`.
6. `prs1` (7 bits) & `prs1_ready` (1 bit): Source 1 register and readiness flag.
7. `prs2` (7 bits) & `prs2_ready` (1 bit): Source 2 register and readiness flag.
8. `pnew` (7 bits): Physical destination register (`p_0 ... p_79`).
9. `rob_idx` (6 bits): Reorder buffer entry index (`0 ... 47`).
10. `rob_epoch` (4 bits): Slot lifetime generation epoch matching M1 substrate.
11. `chkpt_id` (3 bits): Branch checkpoint tag for conditional branches.
12. `pc` (64 bits): Instruction PC.
13. `pred_taken` (1 bit): Future branch direction prediction (Resolution of P1-2).
14. `pred_target` (64 bits): Future branch target prediction (Resolution of P1-2).
15. `is_branch` (1 bit), `is_jal` (1 bit), `is_jalr` (1 bit): Branch type metadata (Resolution of P1-2).
16. `port_mask` (2 bits): Execution port eligibility mask:
    - Bit 0: Port 0 eligible (ALU0, Branch, JAL, JALR).
    - Bit 1: Port 1 eligible (ALU1, Multiplier, Divider).
    - Symmetric integer operations set `port_mask = 2'b11`.

#### 2.2.2 Allocation Handshake (Resolution of P2-3)
- **Allocation Rule**: IntIQ entry allocation is explicitly gated by M1 accepted rename/dispatch slots:
  `iq_alloc_valid[slot] = renamed_valid_o[slot] && rename_ack_o[slot]`
  No IntIQ entry may be created merely because IntIQ itself has free space. If M1 stalls (e.g., Free List empty, ROB full, Checkpoints exhausted, or `sys_blocked`), `rename_ack_o = 2'b00` and zero entries are allocated.
- **Partial Acceptance**: If `rename_ack_o == 2'b01`, uop0 is allocated into IntIQ; uop1 is NOT allocated and remains held in the rename buffer.
- **Backpressure Generation**: IntIQ outputs `dispatch_ready_o[1:0]` to M1:
  - `dispatch_ready_o[0] = (free_entries >= 1)`
  - `dispatch_ready_o[1] = (free_entries >= 2)`

#### 2.2.3 ROB48 Wrap-Safe Age Comparison (Resolution of P2-2 & P3-2)
- **Mathematical Age Distance**: Rather than maintaining an expensive `16 × 16` triangular flip-flop age matrix, IntIQ computes the age of each entry dynamically using its `rob_idx` relative to `rob_head_o` exported by M1:

  ```text
  dist(idx, head) = (idx - head + ROB_DEPTH) mod ROB_DEPTH
  ```

- **Age Ordering Relation**: For any two valid entries `i` and `j`:

  ```text
  Entry i is older than Entry j  <=>  dist(rob_idx[i], rob_head_o) < dist(rob_idx[j], rob_head_o)
  ```

- **Retirement Invariance**: In-flight uncompleted instructions in IntIQ have ROB indices strictly downstream of `rob_head_o`. When the ROB head advances during retirement, the relative circular distance between uncompleted instructions is strictly preserved.
- **Classification**: ROB-head-relative age ordering is **FROZEN SEMANTIC CONTRACT**. An age matrix implementation remains an optional provisional alternative if comparator tree timing on specific ASIC cells requires it.

#### 2.2.4 Port-Aware Scheduler Matching (Resolution of P2-1)
- **Objective**: Select up to two ready uops such that legal port assignment is achieved whenever one exists, strictly avoiding artificial serialization while preserving age priority.
- **Readiness Condition**: An entry is ready if:

  ```text
  Ready = valid && prs1_ready && (prs2_ready || use_imm)
  ```

  - Multiplier uops additionally require Port 1 multiplier issue credits (`mul_fifo_free > muls_in_flight`).
  - Divider uops additionally require `!divider_busy && !div_buf.valid`.
  - ALU1 uops requiring Port 1 require Port 1 ALU credits (`alu1_fifo_free > alu1_in_flight`).
- **Deterministic 2-Port Matching Logic**:
  Let `R` be the set of ready uops ordered by age (`u_0` oldest, `u_1` second-oldest, etc.).
  Partition `R` into:
  - `S_P0`: P0-only uops (Branch, JAL, JALR).
  - `S_P1`: P1-only uops (Multiplier, Divider).
  - `S_flex`: Symmetric ALU uops (`port_mask = 2'b11`).

  **Arbitration Rules**:
  1. If `u_0 ∈ S_P0`: Assign `u_0 → Port 0`. Port 1 selects oldest ready uop in `S_P1 ∪ S_flex`.
  2. If `u_0 ∈ S_P1`: Assign `u_0 → Port 1`. Port 0 selects oldest ready uop in `S_P0 ∪ S_flex`.
  3. If `u_0 ∈ S_flex`:
     - Inspect `u_1`:
       - **If `u_1 ∈ S_P0`**: Assign `u_1 → Port 0` and `u_0 → Port 1` *(Resolves the reviewer critical example: flexible ALU + branch dual-issue in 1 cycle!)*.
       - **If `u_1 ∈ S_P1`**: Assign `u_0 → Port 0` and `u_1 → Port 1`.
       - **If `u_1 ∈ S_flex`**: Assign `u_0 → Port 0` and `u_1 → Port 1`.
       - If no second ready uop exists: Assign `u_0 → Port 0`.
  4. If both `u_0, u_1 ∈ S_P0`: Assign `u_0 → Port 0`. Port 1 selects the oldest ready uop in `S_P1 ∪ S_flex` (if any).
  5. If both `u_0, u_1 ∈ S_P1`: Assign `u_0 → Port 1`. Port 0 selects the oldest ready uop in `S_P0 ∪ S_flex` (if any).

---

## 2.3 Authoritative Pipeline Staging & Timing Model (Resolution of P1-1)

```
+===================================================================================================+
|                               AUTHORITATIVE PIPELINE TIMING MODEL                                 |
+===================================================================================================+

  Stage Name                  Notation   Operations Performed in Stage
  -------------------------   --------   ------------------------------------------------------------
  Dispatch Stage              [ DS ]     Renamed uops written to IntIQ (gated by M1 rename_ack_o).
  Issue & Select Stage        [ IS ]     Ready evaluation; wrap-safe port-aware oldest selection.
  Register Fetch Stage        [ RF ]     Physical registers read from 64-bit PRF storage array.
  Execution Stage             [ EX ]     ALU compute, branch evaluation, MUL pipe, DIV iterative step.
  Validated Writeback Stage   [ WB ]     M1 epoch validation; PRF data write; ROB complete; WB tag.
  In-Order Retirement Stage   [ CMT ]    ROB head in-order commit; Pold return to Free List.
```

### 2.3.1 Explicit Cycle Progression & Dependency Distance
The conservative M2 contract eliminates speculative wakeup and timing loops across functional units:

| Cycle | Producer Stage | Producer Action | Consumer Stage | Consumer Action |
|:---:|:---:|:---|:---:|:---|
| **C0** | **`IS`** | Producer issued from IntIQ | — | Waiting in IntIQ (not ready) |
| **C1** | **`RF`** | Producer reads operands from PRF | — | Waiting in IntIQ |
| **C2** | **`EX`** | Producer executes in ALU/Branch | — | Waiting in IntIQ |
| **C3** | **`WB`** | M1 validates epoch (`comp_ack_o`); PRF data written; tag broadcast | — | IntIQ receives tag broadcast; asserts `prs_ready` |
| **C4** | — | Producer in ROB complete state | **`IS`** | Consumer selected via port-aware matching |
| **C5** | — | — | **`RF`** | Consumer reads PRF data (written in C3) |
| **C6** | — | — | **`EX`** | Consumer executes in ALU/Branch |

### 2.3.2 Authoritative Latency & Distance Definitions
1. **ALU Execution Latency**: Exactly **1 cycle** (`EX` stage).
2. **Producer Result Availability → Consumer Selection**: Exactly **1 cycle** (Producer validated at C3 → Consumer selected in C4 `IS`).
3. **Consumer Register Fetch (`RF`)**: Exactly **1 cycle** (Reads stable PRF data storage in C5).
4. **Producer Issue (`IS`) → Consumer Issue (`IS`) Dependency Distance**: Exactly **3 cycles** (C1 → C4).
5. **Dependent ALU Producer `EX` → Consumer `EX` Dependency Distance**: Exactly **3 cycles** (C2 → C6).
6. **No Same-Cycle Wakeup-and-Select**: Combinational loops between arithmetic outputs and scheduler arbitration inputs are strictly forbidden. This eliminates timing closure risks on FPGA and deep sub-micron ASIC flows.

---

## 2.4 Execution Port 0: ALU0 and Branch Resolution Unit

```
+===================================================================================================+
|                                    EXECUTION PORT 0 ARCHITECTURE                                  |
+===================================================================================================+

                    +-----------------------+   +-----------------------+
                    | Operand A (from RF/BY)|   | Operand B (from RF/BY)|
                    +-----------------------+   +-----------------------+
                                |                           |
                                +-------------+-------------+
                                              |
                     +------------------------+------------------------+
                     |                                                 |
                     v                                                 v
        +--------------------------+                      +--------------------------+
        |  64-Bit Integer ALU0     |                      |  Branch Resolution Unit  |
        |  - Add / Sub / Logic     |                      |  - Condition Comparator  |
        |  - SLL / SRL / SRA       |                      |  - Actual Target Compute |
        |  - 32-bit Word Ops (W)   |                      |  - Actual vs Pred Check  |
        |  - Zba (sh1/2/3add)      |                      |  - Link PC+4 Writeback   |
        |  - Zbb (clz/min/rol/etc) |                      +--------------------------+
        +--------------------------+                                   |
                     |                                                 v
                     |                                    +--------------------------+
                     |                                    | Lifetime-Gated Recovery: |
                     |                                    | Asserted ONLY upon       |
                     |                                    | comp_ack_o[0] from M1!   |
                     +-------------------+----------------+--------------------------+
                                         |
                                         v
                            Port 0 Result to WB Bus
```

### 2.4.1 ALU0 Capabilities (Latency = 1 cycle)
- **Base RV64I**: `ADD`, `SUB`, `AND`, `OR`, `XOR`, `SLL`, `SRL`, `SRA`, `SLT`, `SLTU`, `LUI`, `AUIPC`.
- **RV64I Word Operations**: `ADDW`, `SUBW`, `SLLW`, `SRLW`, `SRAW` (32-bit result sign-extended to 64 bits).
- **Extension Zba**: `SH1ADD`, `SH2ADD`, `SH3ADD`, `SH1ADD.UW`, `SH2ADD.UW`, `SH3ADD.UW`, `ADD.UW`, `SLLI.UW`.
- **Extension Zbb**: `ANDN`, `ORN`, `XNOR`, `CLZ`, `CTZ`, `CPOP`, `MAX`, `MAXU`, `MIN`, `MINU`, `SEXTB`, `SEXTH`, `ZEXTH`, `ROL`, `ROR`, `ORC.B`, `REV8`.

### 2.4.2 Branch Resolution Unit & Prediction Check (Resolution of P1-2)
- **Supported Control Ops**: `BEQ`, `BNE`, `BLT`, `BGE`, `BLTU`, `BGEU`, `JAL`, `JALR`.
- **Return Link Calculation**: Computes `Link = PC + 4` (written to `P_new` for JAL/JALR).
- **Actual-vs-Predicted Evaluation**:
  1. *Conditional Branch*:
     - `actual_taken = eval_cond(rs1, rs2, sub_op)`
     - `actual_target = actual_taken ? (PC + imm) : (PC + 4)`
     - `mispredict = (actual_taken != pred_taken) || (actual_taken && (actual_target != pred_target))`
  2. *Direct Jump (`JAL`)*:
     - `actual_taken = 1'b1`
     - `actual_target = PC + imm`
     - `mispredict = (actual_target != pred_target)`
  3. *Indirect Jump (`JALR`)*:
     - `actual_taken = 1'b1`
     - `actual_target = (rs1 + imm) & ~64'd1`
     - `mispredict = (actual_target != pred_target)`

### 2.4.3 Lifetime-Gated Branch Recovery Interface (Resolution of P1-3)
- **Correctness Rule**: A branch result must NEVER initiate recovery if it belongs to a squashed or stale lifetime. Raw unvalidated recovery requests from `EX` are strictly prohibited.
- **Safe Recovery Sequencing**:
  1. Branch execution in Port 0 produces completion metadata `{rob_idx, rob_epoch, chkpt_id, mispredict}`.
  2. Port 0 presents this completion to M1:
     - `comp_valid_i[0] = 1'b1`
     - `comp_rob_idx_i[0] = br_rob_idx`
     - `comp_epoch_i[0] = br_rob_epoch`
     - `comp_branch_mispred_i[0] = mispredict`
  3. M1 substrate validates `comp_epoch_i[0] == rob[idx].epoch` and produces `comp_ack_o[0]`.
  4. M2 gates recovery and asserts `recover_valid_i` to M1 combinationally in the SAME cycle using the authoritative recovery equation:
     `recover_valid_i = comp_valid_i[0] && comp_branch_mispred_i[0] && comp_ack_o[0] && ! flush_active && ! recovering_o`
     `recover_rob_idx_i = comp_rob_idx_i[0]`
     `recover_chkpt_id_i = br_chkpt_id`
  5. **Semantics of Authoritative Recovery Gating**:
     - **`recovering_o` Protection**: `recovering_o` is the frozen M1 recovery-active indication exported by `fursoy_s1_substrate.sv`. A younger or in-flight branch completion cannot initiate another recovery while an older recovery walk is already active.
     - **Stale Branch Suppression**: Stale branch completions from older squashed epochs remain strictly suppressed by `comp_ack_o[0] == 1'b0` (`recover_valid_i = 1'b0`).
     - **Flush Priority**: Full architectural flush (`flush_active` / `flush_valid_i`) retains higher priority over branch recovery.
  6. This sequences same-cycle branch completion and recovery cleanly without modifying the frozen M1 RTL interface.

---

## 2.5 Execution Port 1: ALU1, Multiplier, and Iterative Divider

```
+===================================================================================================+
|                                    EXECUTION PORT 1 ARCHITECTURE                                  |
+===================================================================================================+

                    +-----------------------+   +-----------------------+
                    | Operand A (from RF/BY)|   | Operand B (from RF/BY)|
                    +-----------------------+   +-----------------------+
                                |                           |
                                +-------------+-------------+
                                              |
                +-----------------------------+-----------------------------+
                |                             |                             |
                v                             v                             v
   +-------------------------+   +-------------------------+   +-------------------------+
   | 64-Bit Integer ALU1     |   | Pipelined Multiplier    |   | Radix-4 Iterative Div   |
   | (Symmetric with ALU0)   |   | (RV64M, K stages)       |   | (RV64M, 8 to 34 cyc)    |
   | Latency: 1 cycle        |   | Latency: Provisional    |   | Single-occupancy        |
   +-------------------------+   +-------------------------+   +-------------------------+
                |                             |                             |
                v                             v                             v
       [ alu1_fifo (A>=2) ]          [ mul_fifo (K>=3) ]             [ div_buf (1 entry) ]
                |                             |                             |
                +-----------------------------+-----------------------------+
                                              |
                                              v
                              +-------------------------------+
                              | Lossless Priority Arbiter     |
                              | Priority: DIV > MUL > ALU1    |
                              +-------------------------------+
                                              |
                                              v
                                   Port 1 Result to WB Bus
```

### 2.5.1 ALU1 (1-Cycle Latency)
- Fully symmetric with ALU0 integer operations (RV64I base, W-forms, Zba, Zbb).

### 2.5.2 Pipelined Multiplier Subsystem (Resolution of P3-1 & Closeout Item 2)
- **Supported Operations**: `MUL`, `MULH`, `MULHSU`, `MULHU`, `MULW`.
- **Pipeline Architecture**: Fully pipelined 64-bit multiplier. Accepts up to 1 operation per cycle when downstream credits are available.
- **Classification & Parameterization**:
  - **FROZEN SEMANTIC CONTRACT**: Pipelined multiplier architecture, exact RV64M arithmetic, credit-gated issue (`mul_fifo_free_entries > muls_in_pipeline`), lossless completion, and completion FIFO/credit sizing parameterized consistently with `K`. Exact multiplier latency is NOT frozen semantically.
  - **PROVISIONAL MICROARCHITECTURAL PARAMETER**: Multiplier pipeline depth `K` with baseline `K=3` (initial candidates `K ∈ {3, 4}`). The exact depth is selected later using synthesis and physical place-and-route timing evidence.

### 2.5.3 Iterative Divider Subsystem & RV64M W Semantics (Resolution of P1-4)
- **Supported Operations**: `DIV`, `DIVU`, `REM`, `REMU`, `DIVW`, `DIVUW`, `REMW`, `REMUW`.
- **Implementation**: Radix-4 non-restoring iterative division engine (8 to 34 cycles, provisional). Single-occupancy. Asserts `divider_busy_o = 1'b1` while calculating.
- **Active Cancellation**: Asserting `divider_cancel_i` aborts computation and clears `divider_busy_o` within **1 clock cycle** on branch mispredict or flush.
- **Normative RV64M Corner Cases & Sign Extension (Exact Compliance)**:
  1. *Division by Zero*:
     - `DIV`: Returns all-ones (`64'hFFFF_FFFF_FFFF_FFFF`, -1).
     - `DIVU`: Returns all-ones (`64'hFFFF_FFFF_FFFF_FFFF`, `2^64-1`).
     - `REM`: Returns dividend `rs1`.
     - `REMU`: Returns dividend `rs1`.
     - `DIVW`: Returns `64'hFFFF_FFFF_FFFF_FFFF` (32-bit -1 sign-extended to 64 bits).
     - **`DIVUW`**: Returns **`64'hFFFF_FFFF_FFFF_FFFF`** (32-bit `2^32-1` sign-extended to 64 bits; NOT zero-extended).
     - `REMW`: Returns `sext64(rs1[31:0])`.
     - `REMUW`: Returns `sext64(rs1[31:0])`.
  2. *Signed Overflow* (`rs1 = -2^63, rs2 = -1`; or `rs1 = -2^31, rs2 = -1` for W-forms):
     - `DIV`: Returns `-2^63` (`64'h8000_0000_0000_0000`).
     - `REM`: Returns `64'h0000_0000_0000_0000`.
     - `DIVW`: Returns `sext64(-2^31) = 64'hFFFF_FFFF_8000_0000`.
     - `REMW`: Returns `64'h0000_0000_0000_0000`.
  3. *Word Operations (`.W`)*:
     - `MULW`, `DIVW`, `DIVUW`, `REMW`, `REMUW` extract 32-bit operands. Signed operations sign-extend; unsigned operations zero-extend into internal execution datapath.
     - **All 32-bit results are explicitly sign-extended to 64 bits before writeback**.

---

## 2.6 Provably Lossless Port 1 Completion Network (Resolution of P0-2)

### 2.6.1 The Collision Dilemma & Maximum In-Flight Pressure
Port 1 has 3 heterogeneous functional units (Divider: 8–34 cyc, Multiplier: `K` stages, ALU1: 1 cyc) competing for **1 physical Port 1 writeback port**.
If an arbitrary burst occurs:
- Multiplier has `K` operations in flight in stages `1 ... K`;
- ALU1 finishes a 1-cycle operation;
- Divider completes in the exact same cycle.
A single 1-entry holding register per unit is mathematically insufficient and would overflow on consecutive multiplier completions while Divider holds writeback.

### 2.6.2 Provably Lossless Sizing & Credit Accounting Architecture
To guarantee **ZERO result loss under all legal collision sequences**:
1. **Dedicated Output Completion Queues**:
   - **Divider Buffer (`div_buf`)**: Exactly **1 entry**. Divider is single-occupancy; `divider_busy` remains asserted until `div_buf` writes back and clears.
   - **Multiplier FIFO (`mul_fifo`)**: Exactly **`K` entries** (where `K` is the multiplier pipeline depth, baseline `K=3`).
   - **ALU1 FIFO (`alu1_fifo`)**: Exactly **`A` entries** (where `A ≥ 2`).
2. **Pre-Issue Completion Reservation (Issue Gating)**:
   An operation is issued from IntIQ to Port 1 **IF AND ONLY IF** downstream buffer capacity is guaranteed:
   - **Multiplier Issue Condition**:
     `mul_fifo_free_entries > muls_in_pipeline`
     *Proof*: The maximum number of multiplications that can reach `mul_fifo` without draining is bounded by `K`. The FIFO capacity is `K`. **Overflow probability = 0.**
   - **ALU1 Issue Condition**:
     `alu1_fifo_free_entries > alu1_in_flight`
     *Proof*: ALU1 has 1-cycle latency. With `A ≥ 2`, even if WB is blocked for 1 cycle, ALU1 safely buffers without dropping.
   - **Divider Issue Condition**:
     `! divider_busy_o && ! div_buf.valid`
     *Proof*: Divider can never start while an unbuffered or active division exists.
3. **Lossless Priority Arbiter**:
   Deterministic priority hierarchy:
   `Priority 1 (Highest): div_buf > Priority 2: mul_fifo > Priority 3 (Lowest): alu1_fifo`
   - When `div_buf` wins: writes to WB, clears `div_buf`, releases `divider_busy`.
   - When `mul_fifo` wins: writes to WB, pops head of `mul_fifo`.
   - When `alu1_fifo` wins: writes to WB, pops head of `alu1_fifo`.
4. **Starvation-Freedom Proof**:
   - Divider writes back at most once every 8 cycles (1 cycle occupancy on WB).
   - Multiplier can write back for at most `K` consecutive cycles before its pipeline empties (if new issues are held).
   - Therefore, ALU1 is guaranteed writeback access within at most `K + 1` cycles. No unit is starved indefinitely.
5. **Squash & Flush of Completion Queues**:
   - On branch mispredict: Any entry in `div_buf`, `mul_fifo`, or `alu1_fifo` younger than the recovering branch is invalidated (`valid <= 0`), immediately freeing buffer capacity.
   - On full flush: All entries in `div_buf`, `mul_fifo`, and `alu1_fifo` are cleared (`valid <= 0`, pointers reset).

---

## 2.7 Writeback Network & M1 Substrate Integration

```
+===================================================================================================+
|                                    WRITEBACK & COMPLETION NETWORK                                 |
+===================================================================================================+

    Port 0 Completion                      Port 1 Completion                      [Port 2 (LSU)]
    {pnew, data, rob_idx, epoch}           {pnew, data, rob_idx, epoch}           {Tied Idle in M2}
                |                                      |                                   |
                +-------------------+------------------+-----------------------------------+
                                    |
                                    v
       +-------------------------------------------------------------+
       | Upstream to M1 Substrate Interface:                         |
       | - comp_valid_i[2:0]                                         |
       | - comp_rob_idx_i[2:0], comp_epoch_i[2:0], comp_preg_i[2:0]  |
       | - comp_branch_mispred_i[2:0], comp_exception_i[2:0]         |
       +-------------------------------------------------------------+
                                    |
                                    v
       +-------------------------------------------------------------+
       | M1 Substrate Epoch Matching (fursoy_s1_rob.sv):             |
       | IF (comp_epoch_i[p] == rob_entry[idx].epoch):               |
       |     rob_entry[idx].completed <= 1'b1                        |
       |     prf_status.ready[comp_preg_i[p]] <= 1'b1                |
       |     comp_ack_o[p] <= 1'b1                                   |
       | ELSE:                                                       |
       |     comp_ack_o[p] <= 1'b0 (Stale completion dropped safely) |
       +-------------------------------------------------------------+
                                    |
                                    v
       +-------------------------------------------------------------+
       | Downstream M2 PRF Data Write & Tag Broadcast:               |
       | prf_we[p] = comp_valid_i[p] && comp_ack_o[p] && (pnew != 0) |
       | Broadcast tag to IntIQ ONLY IF comp_ack_o[p] == 1'b1        |
       +-------------------------------------------------------------+
```

---

## 2.8 Branch Misprediction, Squash, and Recovery Flow

### 2.8.1 Misprediction Trigger Sequence
1. Port 0 evaluates a branch/jump and detects misprediction.
2. Port 0 asserts completion with mispredict flag to M1 substrate.
3. M1 acknowledges live completion (`comp_ack_o[0] = 1'b1`).
4. Provided `!recovering_o` and `!flush_active`, M2 asserts `recover_valid_i = 1'b1` to M1 with `recover_rob_idx_i` and `recover_chkpt_id_i`. If an older recovery is already active (`recovering_o == 1'b1`), new recovery initiation is strictly inhibited.
5. M1 substrate enters `RECOVER` state: restores SRAT from checkpoint `chkpt_id`, halts rename (`rename_ack_o = 2'b00`), and begins backwards ROB squash walk (2 uops/cycle).

### 2.8.2 In-Flight Execution Flush Mechanics
- **Integer Issue Queue**: Entries younger than the mispredicted branch (`dist(rob_idx, head) > dist(br_rob_idx, head)`) have `valid <= 1'b0` in cycle 0.
- **Multiplier Pipeline**: Multiplier stages carry `{rob_idx, rob_epoch}`. Stages younger than the recovering branch are cleared (`valid <= 1'b0`).
- **Divider Cancellation**: If the active division is younger than the branch, `divider_cancel_i = 1'b1` clears the divider FSM in 1 cycle.
- **Port 1 Completion Queues**: Entries in `mul_fifo`, `alu1_fifo`, and `div_buf` younger than the branch are invalidated.
- **Stale Writeback Immunity**: Any un-cancelled uop reaching writeback is rejected by M1 epoch mismatch (`comp_ack_o = 1'b0`).

---

## 3. Structural Parameter Classification Table

| Subsystem / Parameter | M2 Architectural Specification | Master Classification |
|---|---|---|
| **PRF Capacity** | 80 physical registers (`p_0 ... p_79`) | **FROZEN SEMANTIC CONTRACT** |
| **PRF Data Width** | 64 bits per register | **FROZEN SEMANTIC CONTRACT** |
| **PRF Logical Ports (M2)** | 4 Read Ports, 2 Write Ports | **FROZEN SEMANTIC CONTRACT** |
| **PRF Logical Ports (Full)** | 6 Read Ports, 3 Write Ports (Port 2 reserved) | **FROZEN SEMANTIC CONTRACT** |
| **PRF Data Write Gating** | `prf_we = wb_valid && comp_ack && (pnew != 0)` | **FROZEN SEMANTIC CONTRACT** |
| **p0 Semantics** | Hardwired 64'd0; writes suppressed | **FROZEN SEMANTIC CONTRACT** |
| **PRF Physical Organization**| Monolithic vs. Banked vs. Replicated | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **IntIQ Capacity** | 16 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **IntIQ Allocation Handshake**| `alloc_valid = renamed_valid && rename_ack` | **FROZEN SEMANTIC CONTRACT** |
| **IntIQ Age Selection** | Wrap-safe ROB-head-relative circular distance | **FROZEN SEMANTIC CONTRACT** |
| **IntIQ Issue Matching** | Port-aware bipartite matching (flexible ALU + BR) | **FROZEN SEMANTIC CONTRACT** |
| **Pipeline Timing Staging** | `DS -> IS -> RF -> EX -> validated WB -> CMT` | **FROZEN SEMANTIC CONTRACT** |
| **ALU Dependent Distance** | 3-cycle issue-to-issue / EX-to-EX distance | **FROZEN SEMANTIC CONTRACT** |
| **Port 0 Capabilities** | 64-bit ALU0 + Branch Unit | **FROZEN SEMANTIC CONTRACT** |
| **Port 0 Branch Prediction**| Carries `pred_taken`, `pred_target`, type flags | **FROZEN SEMANTIC CONTRACT** |
| **Branch Recovery Gating** | `recover_valid_i = comp_valid[0] && comp_mispred[0] && comp_ack[0] && !flush_active && !recovering_o` | **FROZEN SEMANTIC CONTRACT** |
| **Port 1 Capabilities** | ALU1 (Symmetric) + Multiplier + Iterative Divider | **FROZEN SEMANTIC CONTRACT** |
| **Multiplier Pipeline Depth**| `K` stages (`K ∈ {3, 4}`, baseline `K=3`; selected via physical timing) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **Divider Engine** | Radix-4 non-restoring SRT (8–34 cyc, provisional) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **Divider Concurrency & Busy**| 1 active op; `divider_busy_o` backpressure | **FROZEN SEMANTIC CONTRACT** |
| **Divider Corner Cases** | RV64M normative compliance (exact sign-extended W) | **FROZEN SEMANTIC CONTRACT** |
| **Divider Cancellation** | Single-cycle abort on squash (`divider_cancel_i`) | **FROZEN SEMANTIC CONTRACT** |
| **Port 1 Completion Queues** | Pre-issue credit reserved; `div_buf` + `mul_fifo` + `alu1_fifo` | **FROZEN SEMANTIC CONTRACT** |
| **Port 1 Arbiter Priority** | Lossless deterministic: Divider > Multiplier > ALU1 | **FROZEN SEMANTIC CONTRACT** |
| **M1 Epoch Tag Tracking** | `{rob_idx, rob_epoch}` carried end-to-end to WB | **FROZEN SEMANTIC CONTRACT** |
| **LSU / Port 2 AGU** | Interface reserved; execution omitted from M2 | **DEFERRED TO LATER MILESTONE (M3)** |
| **Frontend / Predictors** | Instruction fetch and branch prediction algorithms | **DEFERRED TO LATER MILESTONE (M4)** |

---

## 4. Formal Backpressure & Deadlock Freedom Analysis

### 4.1 Dependency & Structural Loop Analysis
We evaluate the complete execution loop for circular wait conditions:
`Free List --(alloc)-> Rename --(dispatch)-> IntIQ --(issue)-> PRF Read --(exec)-> EX --(buf)-> P1 Queues --(arb)-> WB --(retire)-> ROB --(free)-> Free List`

#### Scenario A: IntIQ Full with Stalled Older Multiplier / Divider
- *Precondition*: IntIQ fills to 16 entries with dependent uops while an older 34-cycle division is active on Port 1.
- *Analysis*: IntIQ asserts `dispatch_ready_o = 2'b00`. Rename and Dispatch stages stall cleanly. The in-flight division progresses unconditionally every cycle. Upon completion, divider writes back, wakes dependent uops, and IntIQ drains.
- *Verdict*: **Deadlock-free; strictly acyclic progress**.

#### Scenario B: Sustained Multiplier Pressure with Concurrent Divider Completion
- *Precondition*: Multiplier has `K` operations in flight (parameterized depth, baseline `K=3`). Single-cycle ALU1 issues. Divider completes in the same cycle.
- *Analysis*:
  - Divider wins writeback in Cycle `N`.
  - Multipliers `M_1, M_2, M_3` enter `mul_fifo` without loss.
  - ALU1 enters `alu1_fifo` without loss.
  - Multiplier issue is blocked because `mul_fifo_free_entries == 0`.
  - Cycles `N+1 ... N+3`: `mul_fifo` drains to writeback.
  - Cycle `N+4`: `alu1_fifo` drains to writeback.
- *Verdict*: **Zero results dropped; exactly bounded drain latency**.

#### Scenario C: Rapid Branch Misprediction with Stale Multiplier Completion
- *Precondition*: Branch mispredicts at Cycle `N` while a younger Multiplier uop is in Stage 2. ROB slot is recycled for a new uop at Cycle `N+4`.
- *Analysis*: Stale multiplier uop reaches WB with `comp_epoch = 4'd1`. Recycled ROB slot has `epoch = 4'd2`. M1 substrate asserts `comp_ack_o = 1'b0`. Stale completion is dropped: PRF data write suppressed (`prf_we = 0`), PRF status untouched, new uop uncorrupted.
- *Verdict*: **Zero corruption; complete PRF data and ROB integrity**.

---

## 5. Milestone 2 Verification Contract

The implementation of Milestone 2 must be proven through a comprehensive test suite in `verification/s1_m2_tb.cpp` and runner `tools/run_s1_m2.py`.

### 5.1 Mandatory Directed Test Scenarios (Minimum 35 Scenarios)
1. **Basic ALU Arithmetic**: All base RV64I add/sub, logic, shifts, compares.
2. **Word-Sized ALU (RV64I W-form)**: Sign-extension verification for `ADDW`, `SUBW`, `SLLW`, `SRAW`.
3. **Bitmanip ALU (Zba & Zbb)**: Verification of `sh1/2/3add`, `clz`, `ctz`, `cpop`, `min/max`, `rol/ror`.
4. **RAW Dependency Chains**: Back-to-back dependent ALU instructions verifying the 3-cycle issue-to-issue distance.
5. **WAW Independence**: Independent execution of renamed WAW registers without artificial stalls.
6. **Dual-ALU Simultaneous Issue**: Two ready symmetric ALU uops issued concurrently to Port 0 and Port 1.
7. **Port-Aware Flexible ALU + Port0-Only Branch Matching (P2-1)**: Proving flexible ALU routes to Port 1 while branch routes to Port 0 without serialization.
8. **Port Conflict Serialization**: Two ready uops requiring Port 1 serialized across consecutive cycles.
9. **Branch Condition True**: Taken branch evaluation and link register writeback.
10. **Branch Condition False**: Untaken branch fall-through evaluation.
11. **Branch Synthetic Prediction Match**: Correct prediction verifying zero recovery request.
12. **Branch Synthetic Prediction Mispredict**: Actual-vs-predicted mismatch verifying recovery request generation.
13. **Lifetime-Gated Branch Recovery (P1-3)**: Proving stale branch mispredict does NOT assert `recover_valid_i`.
14. **Branch Recovery Across ROB Wrap (P2-2)**: Correct squash distance calculation when branch and younger uops span the circular ROB index boundary.
15. **Multiplier Basic Operations**: `MUL`, `MULH`, `MULHU`, `MULHSU`, `MULW` arithmetic correctness.
16. **MULHSU Signed `×` Unsigned Boundary Vectors**: Positive/negative boundary vector verification.
17. **Multiplier Pipeline Concurrency**: Sustained multiplier issue filling all `K` pipeline stages.
18. **Divider Basic Operations**: `DIV`, `DIVU`, `REM`, `REMU`, `DIVW`, `DIVUW`, `REMW`, `REMUW`.
19. **Divider Zero Quotient & Remainder**: Division of 0 by non-zero dividend.
20. **Divider Division by Zero**: Verification of normative RISC-V all-ones return and dividend remainder.
21. **DIVUW / REMUW Sign-Extension Vectors (P1-4)**: Proving `DIVUW` by zero returns `64'hFFFF_FFFF_FFFF_FFFF`.
22. **Divider Signed Overflow**: `-2^63 / -1` returning `-2^63` and remainder 0; `-2^31 / -1` sign-extended for `DIVW`.
23. **Divider Busy Backpressure**: Younger division stalled while divider is active.
24. **Sustained Multiplier Completion Pressure (P0-2)**: Back-to-back multiplier completions against stalled writeback.
25. **Simultaneous Tri-Unit Collision (DIV + MUL + ALU1)**: All 3 units completing same cycle; zero-drop drain.
26. **Port 1 Completion Buffer / Credit Saturation**: Issue stalled when `mul_fifo` or `alu1_fifo` credits are exhausted.
27. **Branch Misprediction Flush of IntIQ**: Younger instructions in IntIQ squashed cleanly.
28. **Branch Misprediction Flush of Active Multiply**: Multiplier pipeline cleared on mispredict.
29. **Branch Misprediction Active Divide Cancel**: Divider aborted within 1 cycle via `divider_cancel_i`.
30. **Stale Completion PRF Data Immunity (P0-1)**: Proving stale writeback CANNOT overwrite 64-bit PRF data.
31. **Stale Completion Bypass / Wakeup Immunity (P0-1)**: Proving stale writeback CANNOT wake or bypass into consumers.
32. **PRF `p_0` Read/Write Immunity**: Writing non-zero data to `p_0` and verifying readback remains strictly `64'd0`.
33. **IntIQ Allocation Handshake & Partial Acceptance (P2-3)**: Verifying `rename_ack_o == 2'b01` allocates uop0 only.
34. **Simultaneous Flush + WB / Recovery + WB**: Handling full flush or branch recovery occurring concurrently with writeback.
35. **Same-Cycle IntIQ Issue + Two Allocations**: Issue clearing entries while two new uops allocate in the same cycle.

### 5.2 Mandatory RTL Assertions
1. `assert property (@(posedge clk_i) !(comp_valid_i[p] && !comp_ack_o[p] && prf_we[p]));`  
   *(Stale completions must NEVER write PRF data).*
2. `assert property (@(posedge clk_i) !(recover_valid_i && (!comp_ack_o[0] || recovering_o || flush_valid_i)));`  
   *(Branch recovery must be lifetime-validated and cannot trigger while older recovery or flush is active).*
3. `assert property (@(posedge clk_i) !(port1_wb_valid && dropped_completion));`  
   *(Port 1 completion network must never drop an execution result).*
4. `assert property (@(posedge clk_i) !(divider_busy && divider_accept_new));`  
   *(Divider must never accept a new operation while busy).*
5. `assert property (@(posedge clk_i) (prs_read_p0_val == 64'd0));`  
   *(Physical register `p_0` must always evaluate to zero).*

---

## 6. Performance Targets (Design Targets Only)

- **Long-Term Full-Core Target**: Exceed Slice-0's measured IPC of `~ 0.648` to achieve `≥ 1.20` IPC on representative Linux workloads once the complete core (with LSU and Frontend) is integrated.
- **Milestone 2 Backend Throughput Target**:
  - Peak structural throughput: **2.0 uops / cycle** on compute-bound integer ALU blocks.
  - Multiplier throughput: **1.0 product / cycle** (when unthrottled).
  - Port-aware matching eliminates artificial serialization of flexible ALU and branch uops.
  - These targets are engineering design goals to prevent microarchitectural bottlenecks; zero application IPC numbers are fabricated for this isolated execution backend milestone.
