# Fursoy Slice-0 Branch Prediction Architecture v1 Contract

**Status:** BRANCH PREDICTION v1 ARCHITECTURE & RTL FROZEN (Independent Review Verdict: ACCEPT AND FREEZE; P0=0, P1=0; deferred non-blocking P2: x1/x5 coroutine-swap predictor classification for future frontend work)  
**Target:** Fursoy Slice-0 (In-Order 2-Stage [F | E] Core)  
**Normative Baseline:** Frozen post-SRB milestone (27,323,198 cycles, 14,946,915 commits, IPC 0.547041, CPI 1.828016, 1,874,770 branch redirect bubble cycles)  
**Primary Goal:** Eliminate up to ~650k–850k branch redirect bubble cycles without modifying the frozen L1D, SB, SRB, or memory subsystem.  
**Validated Evidence:** 25,763,419 cycles, 14,921,295 commits, IPC 0.579166, CPI 1.726621; -1,559,779 cycles (-5.71%), branch redirect bubbles reduced to 357,666 cycles (-80.92%). Residual = 0.

---

## 1. Scope and Core Architectural Principles

1. **Strict Performance-Only Enhancement:**
   Branch prediction is purely speculative and non-architectural. Any prediction error, aliased entry, stale target, or corrupted predictor state must affect only cycle performance, never architectural correctness, exception precision, or ISA compliance.
2. **Zero Modification to Memory Hierarchy:**
   The Branch Prediction Unit (BPU) operates entirely within Stage F and Stage E. It has zero coupling to the L1 Data Cache (L1D), Store Buffer (SB), Store Refill Buffer (SRB), Memory Management Unit Page Table Walker (PTW), or platform DRAM buses.
3. **Pristine Stage-F Parallel Lookup:**
   BTB and direction prediction access occurs strictly in parallel with L1 Instruction Cache (L1I) tag/data lookup using the registered fetch PC (`pc_f_q`). Stage-F prediction logic introduces zero additional pipeline stages, does not depend on instruction decode bits (which are unavailable during parallel lookup), and does not elongate cycle time.
4. **Single-Cycle Bubble Elimination:**
   In the baseline 2-stage pipeline, every taken branch, JAL, or JALR generates a 1-cycle redirect bubble in Stage F while Stage E resolves the target. A correct taken prediction provides the target PC to L1I combinationally for the immediately following cycle, achieving a **0-bubble penalty** on correctly predicted taken control-flow transfers.
5. **Deterministic Misprediction Recovery & Stage-E Redirect Safety:**
   Stage E remains the authoritative arbiter of all control-flow outcomes. A branch mispredict or false-BTB-hit redirect must **never destroy an instruction held by `stall_e`**. Mispredict redirects fire **if and only if** the instruction in Stage E is actually eligible to resolve and commit (`!stall_e && !sync_trap_e && !trap_take`). Synchronous traps and interrupts strictly dominate branch misprediction.
6. **Anti-Duplication and Exactly-Once State Updates:**
   No architectural or predictor-authoritative side effect may occur repeatedly or prematurely while Stage E is stalled. All predictor updates (BTB allocation/update, bimodal saturating counter update, authoritative RAS push/pop, and false-BTB-hit deallocation) are gated strictly by `commit_fire == 1`. When `stall_e == 1`, all BPU update enables are combinationally forced to `0`.

---

## 2. Branch Target Buffer (BTB) Specification

### 2.1 Capacity, Organization, and Indexing
* **Entry Count:** 512 entries.
* **Associativity:** 2-way set-associative (256 sets).
* **Replacement Policy:** 1-bit Pseudo-LRU (PLRU) per set.
* **Indexing:**
  * In RV64I, instructions are naturally 32-bit aligned (`PC[1:0] == 2'b00`).
  * With future RVC (compressed instruction) support in mind, halfword alignment is preserved (`PC[0] == 1'b0`).
  * **Set Index:** `PC[9:2]` (8 bits, selecting 1 of 256 sets).
  * **Tag:** `PC[38:10]` (29 bits, covering the 39-bit canonical Sv39 virtual address space).
  * Bits `PC[63:39]` are checked for Sv39 canonical sign-extension (`PC[63:39] == {25{PC[38]}}`).

### 2.2 Entry Payload and Metadata Fields
Each BTB entry comprises 99 bits of state:

```
+-------+-------+---------------+--------------------+-----------------+-------------+
| Valid | Way   | Tag           | Branch Type        | 2-bit Direction | Target PC   |
| (1 b) | PLRU  | PC[38:10]     | Metadata (3 b)     | Counter (2 b)   | [63:0]      |
|       | (1 b) | (29 bits)     |                    |                 | (64 bits)   |
+-------+-------+---------------+--------------------+-----------------+-------------+
```

1. **`valid` (1 bit):** Set to `1` when an entry contains valid branch metadata. Initialized to `0` upon reset, `FENCE.I`, `SFENCE.VMA`, `satp` CSR write, or explicit false-hit deallocation.
2. **`tag` (29 bits):** Upper virtual PC bits `PC[38:10]` of the branch instruction.
3. **`target_pc` (64 bits):** Computed target address of the branch or jump.
4. **`branch_type` (3 bits):** Explicitly distinguishes structural control-flow classes so Stage F requires **zero instruction decode bits**:
   * `3'b000` (`COND_BRANCH`): Conditional branch (BEQ, BNE, BLT, BGE, BLTU, BGEU). Direction is modulated by the 2-bit saturating counter; target from BTB `target_pc`. No RAS action.
   * `3'b001` (`JAL_JUMP`): Unconditional direct jump (JAL with destination register `rd != x1 && rd != x5`). Always predicted taken; target from BTB `target_pc`. No RAS action.
   * `3'b010` (`CALL_DIRECT`): Direct subroutine call (JAL with `rd == x1 || rd == x5`). Always predicted taken; target from BTB `target_pc`; pushes `PC+4` to RAS.
   * `3'b011` (`RET`): Subroutine return (JALR with `rs1 == x1 || rs1 == x5` and `rd == x0`). Always predicted taken; target popped from RAS.
   * `3'b100` (`CALL_INDIRECT`): Indirect subroutine call (JALR with `rd == x1 || rd == x5` and `rs1 != rd`). Always predicted taken; target from BTB `target_pc`; pushes `PC+4` to RAS.
   * `3'b101` (`JUMP_INDIRECT`): Indirect jump / switch dispatch (JALR with non-link `rd` and non-link `rs1`). Always predicted taken; target from BTB `target_pc`. No RAS action.
   * `3'b110` (`CO_SWAP`): Coroutine swap (JALR with both `rd` and `rs1` link registers). Always predicted taken; pops target from RAS, then pushes `PC+4` to RAS.
   * `3'b111`: Reserved.
5. **`bimodal_counter` (2 bits):** 2-bit saturating counter for direction prediction (integrated directly per way).

---

## 3. Direction Predictor & Counter Update Policy

### 3.1 Bimodal Saturating Counter State Machine
Conditional branches utilize a standard 2-bit saturating counter (Smith predictor):
* `2'b00` (**Strongly Not-Taken - SNT**): Predict Not-Taken (`pred_taken = 0`).
* `2'b01` (**Weakly Not-Taken - WNT**): Predict Not-Taken (`pred_taken = 0`).
* `2'b10` (**Weakly Taken - WT**): Predict Taken (`pred_taken = 1`).
* `2'b11` (**Strongly Taken - ST**): Predict Taken (`pred_taken = 1`).

```
                Taken                      Taken                      Taken
         +----------------->        +----------------->        +----------------->
       +----+                      +----+                     +----+                     +----+
       | 00 |                      | 01 |                     | 10 |                     | 11 |
       |SNT |                      |WNT |                     | WT |                     | ST |
       +----+                      +----+                     +----+                     +----+
         <-----------------+        <-----------------+        <-----------------+
              Not-Taken                  Not-Taken                  Not-Taken
```

### 3.2 Counter Allocation and Update Rules
1. **Allocation on Miss:**
   When a conditional branch resolves in Stage E and misses in the BTB:
   * If resolved **Taken** and retiring (`commit_fire && is_branch && branch_cond_met`): Allocate the entry in the selected PLRU way, set `valid = 1`, store tag and target, set `branch_type = COND_BRANCH`, and initialize counter to `2'b10` (**Weakly Taken**).
   * If resolved **Not-Taken**: Do not allocate in the BTB (prevents polluting the BTB with untaken branches).
2. **Commit-Time Exactly-Once Update:**
   * Predictor updates occur **strictly on `commit_fire == 1`** in Stage E.
   * If resolved **Taken**: Saturate upwards (`min(counter + 1, 3)`).
   * If resolved **Not-Taken**: Saturate downwards (`max(counter - 1, 0)`).
   * PLRU for the set is toggled to point away from the accessed way.
   * Under `stall_e == 1`, update enable is forced to `0`. A branch held across multi-cycle stalls triggers exactly one counter update upon retirement.
3. **Unconditional Jumps and Calls:**
   JAL and JALR instructions bypass the bimodal counter. When hitting in the BTB, their direction is **unconditionally predicted Taken**.

---

## 4. Return Address Stack (RAS) Specification

### 4.1 Motivation and Justification
In the measured post-SRB Linux workload, **365,000 indirect jumps (`JALR`)** were committed, of which ~290,000 are standard function returns (`ret` / `jalr x0, 0(ra)`). Because subroutine returns have dynamic targets depending on the call site, a static BTB target misses whenever a function is called from multiple sites. A dedicated Return Address Stack recovers up to **~217,000 cycles** with minimal hardware overhead.

### 4.2 RAS Organization and Transfer Qualification
* **Capacity:** 16 entries (circular buffer).
* **Pointer:** 4-bit top-of-stack pointer (`ras_tos_q`).
* **Transfer Qualification Requirement:**
  Speculative RAS push and pop actions in Stage F must occur **if and only if** a real frontend transfer takes place:
  ```systemverilog
  wire transfer_fire_f = fetched_valid && !stall_f && !redirect_any_e;
  ```
  If `stall_f == 1`, `redirect_any_e == 1`, or `fetched_valid == 0`, speculative RAS actions are strictly inhibited.

### 4.3 Stage-F Speculative RAS Operations
When `transfer_fire_f == 1` and Stage F hits in the BTB:
* **Speculative Call Push (`branch_type == CALL_DIRECT || branch_type == CALL_INDIRECT`):**
  * Pushes `pc_f_q + 64'd4` onto the RAS at `ras_tos_q + 4'd1`.
  * Increments `ras_tos_q <= ras_tos_q + 4'd1`.
* **Speculative Return Pop (`branch_type == RET`):**
  * Selects `ras_stack_q[ras_tos_q]` as `pred_target`.
  * Decrements `ras_tos_q <= ras_tos_q - 4'd1`.
* **Speculative Coroutine Swap (`branch_type == CO_SWAP`):**
  * Selects `ras_stack_q[ras_tos_q]` as `pred_target`.
  * Overwrites `ras_stack_q[ras_tos_q] <= pc_f_q + 64'd4` (pointer unchanged).

### 4.4 Inter-Stage Checkpointing (`fe_q`)
To support exact recovery from mispredictions, false BTB hits, traps, and interrupts:
* Stage F latches checkpoint metadata into `fe_q`:
  * `fe_q.ras_action`: `2'b00` (None), `2'b01` (Push), `2'b10` (Pop), `2'b11` (Swap).
  * `fe_q.ras_tos_prev`: The 4-bit `ras_tos_q` value immediately prior to any speculative modification.

### 4.5 Stage-E Authoritative Handling and Recovery Rules
1. **Every Committed Call Must Authoritatively Push `PC+4`:**
   * Any call instruction retiring in Stage E (`commit_fire && is_call_e`):
     * **Cold BTB Miss (`fe_q.ras_action == NONE`):** Stage E authoritatively pushes `fe_q.pc + 64'd4` onto the RAS (`ras_stack_q[ras_tos_q + 1] <= fe_q.pc + 4; ras_tos_q <= ras_tos_q + 1`). This covers cold `JAL ra` and indirect `JALR ra, rs1` calls.
     * **BTB Hit with Target Misprediction:** If an indirect call (`JALR ra, a0`) hit in the BTB and speculatively pushed `PC+4`, but its target address was mispredicted:
       * Stage E asserts `redirect_branch_e = 1` to `actual_target`.
       * **The call is committing!** Its return address `fe_q.pc + 4` on the RAS **must be preserved**. The rollback logic **MUST NOT** revert the call's push.
     * **BTB Hit with Target Correct:** Speculative push already in place; no adjustment required.
2. **Authoritative Return Retirement:**
   * Any return instruction retiring in Stage E (`commit_fire && is_ret_e`):
     * **Cold BTB Miss (`fe_q.ras_action == NONE`):** Stage E authoritatively pops the RAS (`ras_tos_q <= ras_tos_q - 4'd1`).
     * **BTB Hit Return:** Pop already completed speculatively; preserved.
3. **Speculative Rollback on False Hits or Trapped/Flushed Instructions:**
   * If Stage E resolves a **false BTB hit** (non-control instruction with speculative RAS action), an **untaken branch** that falsely predicted taken, a **synchronous trap**, or an **asynchronous interrupt**:
     * The speculative RAS action was invalid.
     * Stage E restores `ras_tos_q <= fe_q.ras_tos_prev`.
4. **Stall Immunity:**
   * Authoritative RAS modifications and rollbacks occur **only on the retirement/resolution cycle** (`commit_fire == 1` or trap/interrupt firing). When `stall_e == 1`, the RAS pointer and stack contents remain strictly unchanged.

---

## 5. Pipeline Timing, Stage-F Lookup & Next-PC Selection

### 5.1 Stage-F Combinational Lookup Timing
In cycle $t$, Stage F evaluates the registered fetch PC `pc_f_q`:

```
Cycle t:
Stage F (Fetch PC: pc_f_q):
  |---> [ L1I Tag & Data Read ] ---------------> fetched_insn, fetched_valid
  |
  |---> [ BTB Set Lookup (pc_f_q[9:2]) ]
  |       |--> Way 0 Tag Match? -> Match0
  |       |--> Way 1 Tag Match? -> Match1
  |       |--> Select Hit Way Target, Counter & Branch Type (3 b)
  |
  |---> [ RAS Read (ras_tos_q) ] --------------> ras_target
  |
  +---> [ Prediction Evaluation ]:
          transfer_fire_f = fetched_valid && !stall_f && !redirect_any_e;
          is_uncond = (branch_type != COND_BRANCH);
          is_ret    = (branch_type == RET || branch_type == CO_SWAP);
          pred_taken = btb_hit && (is_uncond || counter[1]);
          pred_target = is_ret ? ras_target : btb_target;
```

### 5.2 Next-PC Priority Multiplexer
The authoritative next-PC multiplexer in Stage F enforces strict priority:

```systemverilog
always_comb begin
    if (redirect_any_e) begin
        // Priority 1: Authoritative Stage-E redirects (traps, MRET/SRET, mispredicts, flushes)
        next_pc_f = redirect_target_e;
    end else if (stall_f) begin
        // Priority 2: Pipeline stall (L1I miss, ITLB PTW, Stage E backpressure, L1D maintenance)
        next_pc_f = pc_f_q;
    end else if (transfer_fire_f && btb_hit && pred_taken) begin
        // Priority 3: Speculative Predicted Taken Target
        next_pc_f = pred_target;
    end else if (transfer_fire_f) begin
        // Priority 4: Default Sequential Advance (pc + 4)
        next_pc_f = pc_f_q + 64'd4;
    end else begin
        // Priority 5: Fetch Hold (waiting for L1I response)
        next_pc_f = pc_f_q;
    end
end
```

### 5.3 Inter-Stage Pipeline Register (`fe_q`) Extension
The `fe_q` structure is augmented with branch prediction tracking fields:
```systemverilog
typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    logic [31:0] insn;
    logic        fetch_error;
    logic        page_fault;
    // Branch Prediction Metadata (Stage F -> Stage E)
    logic        pred_taken;       // Was this instruction predicted taken?
    logic [63:0] pred_target;      // What target PC was predicted?
    logic        btb_hit;          // Did this instruction hit in BTB?
    logic [7:0]  btb_set;          // BTB set index for update
    logic        btb_way;          // BTB way index for update
    logic [1:0]  ras_action;       // Speculative RAS action taken in Stage F
    logic [3:0]  ras_tos_prev;     // Checkpointed RAS pointer before speculative action
} fe_reg_t;
```

---

## 6. Stage-E Resolution & Misprediction Recovery

### 6.1 Authoritative Execution & Condition Check
In cycle $t+1$, the instruction in `fe_q` is decoded and executed in Stage E:
* `actual_taken`:
  * Conditional Branch: Evaluated from integer ALU register comparisons (`rs1_val`, `rs2_val`).
  * JAL / JALR: Always taken (`actual_taken = 1`).
  * Non-control instruction: Always not-taken (`actual_taken = 0`).
* `actual_target`:
  * Conditional Branch: `fe_q.pc + imm_b`
  * JAL: `fe_q.pc + imm_j`
  * JALR: `(rs1_val + imm_i) & ~64'd1`
  * Non-control instruction: `fe_q.pc + 64'd4`

### 6.2 Misprediction Classification and Stage-E Redirect Safety
A misprediction occurs if and only if:
```systemverilog
wire dir_mispredict    = (fe_q.pred_taken != actual_taken);
wire target_mispredict = actual_taken && (fe_q.pred_target != actual_target);
wire false_btb_hit     = fe_q.pred_taken && !control_valid;

// Stage-E Redirect Safety: Mispredict MUST NOT fire while stalled or taking a trap/interrupt
wire bpu_mispredict = fe_q.valid && !sync_trap_e && !trap_take && !stall_e &&
                      (dir_mispredict || target_mispredict || false_btb_hit);
```

**Normative Invariant (Stage-E Redirect Safety):**
* If `stall_e == 1`, `redirect_branch_e` **MUST be combinationally forced to 0**.
* A branch misprediction or false BTB hit must **never destroy an instruction held in `fe_q` by `stall_e`**.
* Mispredict redirects fire **only when the instruction is actually eligible to resolve and commit** (`!stall_e && !sync_trap_e && !trap_take`).

### 6.3 Recovery Action and Redirect Target Selection
1. **Prediction Correct (`bpu_mispredict == 0` && `!false_btb_hit`):**
   * If `actual_taken == 1`: Stage F is ALREADY fetching the target instruction. **Zero bubble cycles incurred.**
   * If `actual_taken == 0`: Stage F is ALREADY fetching the fall-through sequential instruction (`PC + 4`). **Zero bubble cycles incurred.**
   * Counter is updated upon `commit_fire`. No redirect asserted (`redirect_branch_e = 0`).
2. **Prediction Incorrect (`bpu_mispredict == 1`):**
   * Stage E asserts `redirect_branch_e = 1`.
   * The redirect target is selected as:
     * If `actual_taken == 1`: `redirect_target_e = actual_target` (branch was taken, but predicted not-taken or wrong target).
     * If `actual_taken == 0`: `redirect_target_e = fe_q.pc + 64'd4` (branch was untaken, or false BTB hit on non-control instruction; restore fall-through).
   * At the clock edge:
     * `fe_q` is invalidated (`fe_q.valid <= 0`), discarding the speculatively fetched wrong-path instruction.
     * `pc_q <= redirect_target_e`.
     * `L1I` receives `redirect_i = 1`, flushing any pending fetch and starting lookup at `redirect_target_e`.
   * **Misprediction Cost:** Exactly **1 bubble cycle** (identical to baseline taken branch latency).

### 6.4 False BTB Hit Deallocation
A false BTB hit occurs when an entry hits on a non-control instruction (e.g. ALU arithmetic, load, store, or CSR access) due to aliasing or stale code:
* **Recovery:** Stage E redirects to fall-through `fe_q.pc + 64'd4`.
* **Deallocation:** The offending BTB entry must be explicitly invalidated:
  ```systemverilog
  wire btb_dealloc_en = commit_fire && fe_q.btb_hit && !control_valid;
  ```
  On `btb_dealloc_en == 1`, `btb_valid[fe_q.btb_set][fe_q.btb_way] <= 1'b0`.
* This deallocation occurs **strictly once on `commit_fire`** (never during stalls), ensuring the entry cannot repeatedly mispredict or create livelock loops.

---

## 7. Stall Interaction & Anti-Duplication Rules

### 7.1 Anti-Duplication Invariant
When Stage E experiences an LSU stall (`lsu_stall`), memory drain stall (`memory_drained == 0`), or CSR serialization delay, `fe_q` is held constant for multiple consecutive clock cycles (`stall_e == 1`).

**Normative Rule (Section 7.1):**
Predictor updates (`btb_update_en`, `pht_update_en`, `ras_update_en`, `btb_dealloc_en`) must be asserted **if and only if `commit_fire == 1`**.
* The ambiguous independent `mispredict_fire` signal is **permanently eliminated**.
* Under `stall_e == 1`, all BPU write-enable signals MUST be combinationally forced to `0`.
* A branch instruction held in Stage E across $N$ stall cycles triggers **exactly one** update to the BTB and saturating counters on the final cycle it retires.
* Trapped, interrupted, or flushed wrong-path instructions generate **zero** predictor updates.

### 7.2 Stage F Frozen Under Backpressure
When `stall_f == 1` (due to `stall_e`, `l1i_miss_active`, `itrans_busy`, `l1i_hold_active`, or `l1d_maintenance_active`):
* `pc_q` holds its value.
* BTB tag and direction outputs are ignored by the next-PC multiplexer.
* Speculative RAS push/pop operations are strictly suppressed.

---

## 8. System, Exception, Interrupt & Maintenance Invariants

### 8.1 Priority Dominance
Stage-E redirect sources strictly maintain the following absolute hierarchy:
1. **Priority 1 (Dominant): Synchronous Traps & Interrupts** (`redirect_trap_e`)
   * An exception (illegal instruction, misaligned access, page fault, access fault) or pending interrupt immediately flushes the pipeline and vectors to `mtvec` / `stvec`. Any concurrent branch prediction is unconditionally discarded.
2. **Priority 2: MRET** (`redirect_mret_e`)
   * Vectors to `mepc_q`.
3. **Priority 3: SRET** (`redirect_sret_e`)
   * Vectors to `sepc_q`.
4. **Priority 4: Branch / Jump Misprediction & False BTB Hit** (`redirect_branch_e`)
   * Handled only when `!stall_e && !sync_trap_e && !trap_take`.
5. **Priority 5: Serialization Flushes** (`redirect_flush_e`)
   * `FENCE.I`, `SFENCE.VMA`, `satp` CSR write, and PMP CSR writes resume execution at `fe_q.pc + 4`.

### 8.2 Maintenance Flushing (`FENCE.I`, `SFENCE.VMA`, `satp` Writes, Reset)
1. **`FENCE.I` (Instruction Synchronization):**
   * Flushes L1I valid bits, flash-invalidates all 512 BTB entries (`btb_valid_q <= '0`), and resets `ras_tos_q <= '0`.
   * Guarantees dynamically modified code cannot fetch stale branch targets.
2. **`SFENCE.VMA` (Address Translation Flush):**
   * Upon `SFENCE.VMA`, all BTB entries are flash-invalidated (`btb_valid_q <= '0') and RAS is reset (`ras_tos_q <= '0').
3. **`satp` CSR Write (Address-Space Switch):**
   * In Sv39 systems, writing `satp` changes the page directory root (PPN). Because the BTB uses virtual PC indexing and tags without ASID qualification, all BTB entries are **flash-invalidated (`btb_valid_q <= '0') and RAS is reset (`ras_tos_q <= '0') on every committed `satp` CSR write**.
4. **Reset (`rst_i == 1`):**
   * All BTB `valid` bits cleared to `0`.
   * All 2-bit bimodal counters reset to `2'b01` (Weakly Not-Taken).
   * All PLRU bits initialized to `0`.
   * RAS stack and pointers cleared to `0`.

---

## 9. Virtual Memory, ITLB, PMP & Speculative Safety

### 9.1 Speculative Instruction Fetch Boundary
When Stage F predicts a branch as taken and redirects fetch to `pred_target`:
* The address `pred_target` enters L1I and ITLB.
* `pred_target` may be stale, corrupted, unmapped, non-canonical, misaligned, or point to an unauthorized physical memory region.

### 9.2 Mandatory Speculative Safety Invariants
1. **Zero Premature Trap Assertion:**
   If a speculative fetch to `pred_target` triggers an ITLB page fault (`itrans_page_fault`) or PMP access fault (`itrans_pmp_allow == 0`):
   * L1I latches `fetched_error = 1` or `fetched_page_fault = 1` into `fe_q`.
   * **Stage F MUST NEVER directly trigger a trap.**
   * If Stage E resolves an older branch as a misprediction, `fe_q` is flushed (`fe_q.valid <= 0`), and the speculative fault is **silently discarded**.
   * Only if the speculative instruction reaches Stage E on a verified architectural path and becomes eligible to commit does `sync_trap_e` assert and vector to `mtval`/`mcause`.
2. **Prohibition of Non-DRAM Speculative Memory Traffic:**
   * L1I and ITLB strictly prohibit fetching from MMIO apertures (`0x1000_0000` UART, `0x0C00_0000` PLIC, `0x0200_0000` CLINT).
   * Any speculative fetch targeting non-DRAM space is terminated immediately with a local access fault status, generating **zero bus requests to external peripherals**. Speculative execution cannot create peripheral side effects.
3. **Safe Handling of Arbitrary Corrupt / Misaligned Targets:**
   * **Non-Canonical Virtual Addresses (`PC[63:39] != {25{PC[38]}}`):** Caught by ITLB canonical check; marked as speculative page fault in `fe_q`; never causes core exception unless committed.
   * **Misaligned Branch Targets (`target[1:0] != 2'b00`):** Stage E evaluates actual alignment. If the branch actually jumps to a misaligned target, Stage E raises a precise `Instruction address misaligned` exception (`cause 0`, `tval = actual_target`). If the misalignment was purely speculative (corrupt BTB target), Stage E detects target misprediction, squashes the speculative fetch, and redirects to the correct path.
   * **Arbitrary Predictor Contents:** Corrupted predictor SRAM bits can degrade performance, but can **never** violate architectural memory safety or cause platform bus hangs.

---

## 10. Performance Telemetry and Diagnostic Registers

To empirically validate prediction accuracy and monitor branch behavior during Linux boot and benchmarks, the following observational event signals are defined:

```systemverilog
output logic bpu_branch_count_o     /* verilator public_flat_rd */, // Total conditional branches committed
output logic bpu_branch_taken_o     /* verilator public_flat_rd */, // Taken conditional branches committed
output logic bpu_branch_correct_o   /* verilator public_flat_rd */, // Correctly predicted branches
output logic bpu_branch_mispred_o   /* verilator public_flat_rd */, // Mispredicted conditional branches
output logic bpu_jal_count_o        /* verilator public_flat_rd */, // Total JAL instructions committed
output logic bpu_jal_correct_o      /* verilator public_flat_rd */, // JAL hitting in BTB (0 bubble)
output logic bpu_jalr_count_o       /* verilator public_flat_rd */, // Total JALR instructions committed
output logic bpu_jalr_correct_o     /* verilator public_flat_rd */, // JALR correctly predicted (BTB/RAS)
output logic bpu_ras_push_count_o   /* verilator public_flat_rd */, // Authoritative RAS pushes committed
output logic bpu_ras_pop_count_o    /* verilator public_flat_rd */, // Authoritative RAS pops committed
output logic bpu_false_hit_count_o  /* verilator public_flat_rd */, // False BTB hits detected and deallocated
output logic bpu_bubble_saved_o     /* verilator public_flat_rd */  // Exact cycle saved (0-bubble taken transfer)
```

* `bpu_bubble_saved_o`: Pulses for exactly 1 cycle whenever a taken branch, JAL, or JALR commits with `fe_q.pred_taken == 1 && fe_q.pred_target == actual_target`.

---

## 11. Adversarial Verification Matrix

The test suite (`verification/bpu_s0_tb.cpp`, `tools/run_bpu_s0.py`) must implement and pass at least the following 38 targeted scenarios:

| ID | Category | Scenario Description | Expected Invariant / Pass Criteria |
| :--- | :--- | :--- | :--- |
| **BPU-DIR-01** | Direction | Cold conditional branch (BTB miss) resolved Taken | Allocates BTB on commit; takes 1 bubble redirect; counter initialized to WT (`2'b10`). |
| **BPU-DIR-02** | Direction | Cold conditional branch (BTB miss) resolved Not-Taken | No BTB allocation; 0 bubble cycles; fall-through continues. |
| **BPU-DIR-03** | Direction | Repeated loop branch: 5 taken iterations | First iteration misses (1 bubble); iterations 2–5 hit and predict taken (0 bubble). |
| **BPU-DIR-04** | Direction | Loop exit: branch resolves Not-Taken after 5 taken | Predicts taken; mispredicts; Stage E restores fall-through (1 bubble); counter decrements. |
| **BPU-DIR-05** | Direction | Alternating branch (T-NT-T-NT) | Counter transitions correctly across 4 saturating states without deadlock. |
| **BPU-JAL-01** | JAL | Unconditional JAL cold miss | First execution allocates BTB (1 bubble); second execution hits and takes 0 bubbles. |
| **BPU-JAL-02** | JAL | Tight JAL backward loop (spin / polling loop) | 100% hits in BTB; executes with zero redirect bubbles. |
| **BPU-RET-01** | RAS | Simple subroutine call (`jal ra`) and return (`ret`) | Call pushes `PC+4` to RAS; return pops RAS; 0 bubbles on return. |
| **BPU-RET-02** | RAS | Nested calls 8 levels deep | All 8 returns match RAS in reverse order; 0 redirect bubbles. |
| **BPU-RET-03** | RAS | Circular stack overflow (call depth > 16) | Oldest entries overwritten gracefully; top 16 return addresses correctly popped. |
| **BPU-RET-04** | RAS | Non-return indirect JALR (function pointer / jump table) | Uses BTB target, bypassing RAS pop. |
| **BPU-RET-07** | RAS | Indirect `JALR` call RAS push | `jalr ra, a0` commits and authoritatively pushes `PC+4` to RAS; distinguished from non-call JALR. |
| **BPU-RET-08** | RAS | Indirect-call target mispredict with return preserved | `jalr ra, a0` with wrong target redirects to actual target, but preserves return address `PC+4` on RAS. |
| **BPU-RET-09** | RAS | Cold-call BTB miss RAS push | Direct/indirect call missing in BTB pushes `PC+4` to RAS on commit; subsequent return hits in RAS. |
| **BPU-AL-01** | Aliasing | Two branches mapping to same set index with different tags | 2-way associativity accommodates both; both achieve 0-bubble execution. |
| **BPU-AL-02** | Aliasing | Three branches mapping to same set index | PLRU selects victim way; victim re-allocated cleanly without corruption. |
| **BPU-AL-03** | Aliasing | False BTB hit on non-control ALU instruction | Stage E detects non-control type; redirects to fall-through (1 bubble); ALU instruction commits. |
| **BPU-AL-04** | Aliasing | False-BTB-hit deallocation | False BTB hit deallocates offending entry (`valid=0`); subsequent fetch at same PC does not mispredict. |
| **BPU-TG-01** | Target | Indirect JALR changes target address between calls | Stage E detects target mismatch; redirects to new target; updates BTB target. |
| **BPU-B2B-01** | Sequence | Back-to-back conditional branches (Cycle $t$ and Cycle $t+1$) | Both evaluated correctly; pipeline in-order semantics strictly preserved. |
| **BPU-B2B-02** | Sequence | Branch in delay slot of mispredicted branch | Speculative branch cleanly flushed; zero spurious predictor state updates. |
| **BPU-STL-01** | Stalls | Stage E stalls for 10 cycles on LSU load while branch in `fe_q` | Predictor counter updated exactly once on commit cycle, not 10 times. |
| **BPU-STL-02** | Stalls | Stage F stalls on L1I cache miss during predicted target fetch | `pc_q` holds target; speculative RAS actions suppressed while stalled; target instruction arrives cleanly. |
| **BPU-STL-03** | Stalls | False BTB hit while Stage E is stalled | `stall_e` inhibits redirect; instruction in `fe_q` preserved; redirects and deallocates only on commit. |
| **BPU-TRP-01** | Traps | Synchronous exception on instruction following predicted branch | Wrong-path instruction exception suppressed if branch mispredicts; taken if correct. |
| **BPU-TRP-02** | Traps | Asynchronous timer interrupt arrives during predicted branch | Interrupt vectors to `mtvec`; branch finishes execution or re-executes cleanly. |
| **BPU-TRP-03** | Traps | Branch concurrent with asynchronous interrupt | Interrupt takes absolute priority; branch does not commit; zero predictor updates; clean `mepc`. |
| **BPU-RET-05** | Priv | MRET executes while BTB predicts branch in Stage F | MRET redirects to `mepc_q`; speculative branch fetch flushed unconditionally. |
| **BPU-RET-06** | Priv | SRET executes while BTB predicts branch in Stage F | SRET redirects to `sepc_q`; speculative branch fetch flushed unconditionally. |
| **BPU-FNC-01** | Maint | `FENCE.I` execution | Flash-invalidates all 512 BTB entries; clears RAS; subsequent branches miss. |
| **BPU-FNC-02** | Maint | `SFENCE.VMA` execution | Flash-invalidates all BTB entries; flushes TLB; zero stale virtual target hits. |
| **BPU-MNT-01** | Maint | `satp` CSR write execution | Flash-invalidates all 512 BTB entries; clears RAS; prevents stale cross-address-space predictions. |
| **BPU-RST-01** | Reset | Reset asserted during active prediction and fetch | All BTB valid bits cleared; counters reset to `2'b01`; starts clean at `RESET_PC`. |
| **BPU-MMU-01** | MMU | Speculative fetch targets unmapped page | ITLB page fault held in `fe_q`; flushed cleanly if branch mispredicts; no trap leak. |
| **BPU-MMU-02** | MMU | Speculative prediction into MMIO aperture | L1I/ITLB terminates with local fault; zero bus requests emitted to peripheral interconnect. |
| **BPU-PMP-01** | PMP | Speculative fetch targets PMP-denied space | Access fault held in `fe_q`; flushed cleanly if branch mispredicts; no spurious bus error. |
| **BPU-PMP-02** | PMP | PMP CSR modification flushes pipeline | BTB entries in revoked regions invalidated or safely fault in Stage E. |
| **BPU-MIS-01** | Alignment | Misaligned target address generated by branch | Traps with cause 0 (`Instruction address misaligned`) in Stage E; tval holds target. |

---

## 12. Quantitative Analytical Performance Model

### 12.1 Empirical Baseline Metrics
From the validated post-SRB benchmark (`results/perf-srb-s0.json`):
* **Total Execution Cycles:** 27,323,198
* **Committed Instructions:** 14,946,915
* **Baseline IPC:** 0.547041 (CPI: 1.828016)
* **Branch Redirect Bubble Cycles:** **1,874,770** (6.861% of all execution time)
* **Control Instruction Commit Distribution:**
  * Conditional Branches: 1,624,000 (1,059,000 Taken [65.2%], 565,000 Untaken [34.8%])
  * Direct Jumps (`JAL`): 199,000 (100% Taken)
  * Indirect Jumps (`JALR`): 365,000 (100% Taken; ~290k Subroutine Returns, ~75k Function Pointers)
  * **Total Taken Control Transfers:** **1,623,000**

### 12.2 Conservative Cycle Recovery Estimation
Following architectural review, the previous cycle recovery estimate of 1.25M–1.42M cycles was recognized as overly optimistic due to BTB capacity limits (512 entries across the large Linux kernel text footprint), cold calls, context switches, and stall migration. A conservative revised performance model is established below:

1. **Unconditional JAL (199,000 commits):**
   * Static target, always taken.
   * Realistic BTB capacity hit rate across kernel text: 75.0%.
   * **Gross Cycles Saved:** $199{,}000 \times 0.75 = \mathbf{+149{,}250\text{ cycles}}$.
2. **Indirect Returns via 16-Entry RAS (~290,000 commits):**
   * Realistic RAS hit rate accounting for deep call stacks, cold call misses, and context switches: 75.0%.
   * **Gross Cycles Saved:** $290{,}000 \times 0.75 = \mathbf{+217{,}500\text{ cycles}}$.
3. **Indirect Jumps via BTB (~75,000 commits):**
   * Hit rate on monomorphic function pointers and switch dispatch: 45.0%.
   * **Gross Cycles Saved:** $75{,}000 \times 0.45 = \mathbf{+33{,}750\text{ cycles}}$.
4. **Conditional Taken Branches (1,059,000 commits):**
   * 2-way 512-entry BTB hit rate + 2-bit bimodal accuracy: 65.0%.
   * **Gross Cycles Saved:** $1{,}059{,}000 \times 0.65 = \mathbf{+688{,}350\text{ cycles}}$.
5. **Conditional Untaken Branches (565,000 commits):**
   * 88.0% correctly predicted Not-Taken (0 cycle delta vs baseline).
   * 12.0% (67,800) mispredicted as Taken:
     * Incurs a 1-cycle corrective redirect to fall-through (`fe_q.pc + 4`) that was not present in the non-speculative baseline.
   * **Cycle Penalty:** $565{,}000 \times 0.12 \times (-1) = \mathbf{-67{,}800\text{ cycles}}$.
6. **Gross Direct Bubble Reduction:**
   $$149{,}250 + 217{,}500 + 33{,}750 + 688{,}350 - 67{,}800 = \mathbf{+1{,}021{,}050\text{ cycles}}$$
7. **Stall Migration into Memory Subsystem:**
   * Eliminating branch bubbles accelerates instruction retirement, increasing the issue density of loads and stores into the single-ported L1D and 4-entry Store Buffer.
   * Based on empirical stall migration observed during the SB and SRB milestones, approximately **25% to 30%** of gross cycle savings migrate into L1D load arbitration contention and Store Buffer full backpressure ($\approx -255{,}000\text{ to } -306{,}000\text{ cycles}$).
8. **Conservative Net Projected Performance Range:**
   * **Net Cycle Reduction:** **650,000 – 850,000 cycles** (midpoint $\approx \mathbf{740{,}000\text{ cycles}}$).
   * **Projected Execution Cycles:** **26,470,000 – 26,670,000 cycles** (down from 27.32M).
   * **Projected IPC:** **0.560 – 0.565 IPC** (vs 0.547041 baseline; net **+2.4% to +3.3% throughput gain**).
   * **Projected CPI:** **1.77 – 1.79** (down from 1.828).

> [!IMPORTANT]
> All performance figures are unverified analytical hypotheses based on empirical kernel statistics. Performance is not a correctness requirement; authoritative RTL validation will occur after architectural freeze.

---

## 13. Architectural Trade-off Rationale & Extensibility

1. **Explicit 3-Bit Metadata vs Combinational Instruction Decode:**
   * Storing 3 bits of branch type metadata in each BTB entry requires only 1 extra bit per entry over 2-bit encoding (128 bytes total across 512 entries).
   * In return, Stage F completely decouples from L1I instruction data decoding, eliminating critical-path timing pressure and avoiding dependency on cache hit availability.
2. **Why 2-Way Associativity over Direct-Mapped?**
   * In Linux kernel execution, critical loop kernels frequently contain tight branch interleavings (e.g. hash table lookups, spinlocks, and scheduler loops). A direct-mapped BTB suffers from ping-pong thrashing between conflicting branch addresses.
   * 2-way set associativity eliminates index collisions between callers and loop bodies, boosting hit rates by >12% for only 1 additional comparator per set.
3. **Hardware Deallocation of False BTB Hits:**
   * In an in-order pipeline, a false BTB hit incurs a 1-cycle redirect penalty. Without deallocation, an aliased entry would mispredict on every execution of that non-control instruction.
   * Adding a single-bit deallocation strobe (`valid <= 0`) on `commit_fire` cleanly resolves the collision without requiring complex multi-tag structures.
4. **Extensibility toward Future Out-of-Order Fursoy Core:**
   * The decoupled Stage-F lookup and Stage-E resolution interfaces establish a standardized **Branch Prediction Service Interface**.
   * When Fursoy transitions to a deeper 4→8 core superscalar or out-of-order pipeline, the BPU can be replaced with an advanced decoupled TAGE / Perceptron engine without altering the pipeline control contracts, exception models, or memory interfaces.

---
