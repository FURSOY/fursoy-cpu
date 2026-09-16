# Fursoy Slice-0 In-Order Pipeline Architecture Contract v1

**Document ID:** `docs/architecture/pipeline-s0-v1.md`  
**Status:** PROPOSED ARCHITECTURAL CONTRACT v1 (Revised for Independent Re-Review)  
**Target Core:** Fursoy Slice-0 (Single-Hart, In-Order, RV64IMA + Zicsr + Zifencei, Sv39, RVA23 Baseline)  
**Target Milestone:** Slice-0 In-Order Pipeline Integration  

---

## 1. Architectural Motivation & Performance Grounding

### 1.1 The Post-L1I Profiling Reality

Physical simulation of the frozen post-L1I baseline on upstream Linux 6.6.50 cold boot and userspace microbenchmarks (`results/perf-baseline-s0.json`) established the exact disjoint execution cycle partition:

| Execution Metric | Measured Post-L1I Result | % of Total Execution |
|---|---|---|
| **Total Execution Cycles** | **42,575,777** | **100.000%** |
| **Committed Instructions** | **15,216,301** | — |
| **Measured IPC / CPI** | **0.357393 / 2.798037** | — |
| **Useful Retirement Cycles** | **15,216,301** | **35.739%** |
| **Pure Instruction-Fetch Wait Cycles** | **24,618,624** | **57.823%** |
| **LSU Stalls (Memory Wait + Serialization)** | **2,736,970** | **6.428%** |
| **MMU / PTW Translation Stalls** | **2,960** | **0.007%** |
| **Trap / Interrupt Drain Cycles** | **922** | **0.002%** |
| **L1 Instruction Cache (L1I) Hit Rate** | **98.38%** (14.97M hits / 246.9k misses) | — |
| **Total DRAM Accesses** | **7,214,794** (Data: 72.60%, Fetch beats: 27.38%) | — |

### 1.2 Root Cause of the 24.62M Fetch Wait Cycles

In the existing non-pipelined Slice-0 core (`fursoy_s0_core.sv`), instruction fetch and instruction execution are strictly serialized in a stop-and-wait lockstep:
1. When an instruction commits, the core updates `pc_q <= pc_q + 4`.
2. L1I receives the new PC on `fetch_pc_i` and enters `FETCH_REQ` (Cycle 1).
3. In Cycle 2, L1I enters `FETCH_CHECK` to check ITLB, compare tags, and register the hit.
4. Only upon registering `fetched_valid_o = 1` does the core evaluate decode, register read, ALU compute, and register writeback.

Even with a **98.38% L1I hit rate**, every single instruction requires at least 1 full cycle of fetch wait before execution can occur. Cache misses account for only ~2.42M cycles of refill wait ($246,953 \times \approx 9.8\text{ cycles}$). The remaining **22.20 million cycles of pure fetch wait are structural serialization overhead**.

### 1.3 Architectural Objective

Design the smallest robust pipeline that overlaps instruction fetch with execution, eliminating the 1-cycle registered-L1I hit penalty for sequential instructions while strictly preserving:
- Single-issue, in-order architectural retirement.
- Exact synchronous exception precision and `mepc`/`sepc`/`mtval`/`stval` compliance.
- All frozen contracts: Sv39 MMU v1, TLB v1, PMP v1, PLIC v1, RV64A v1, Platform/SBI v1, and L1I v1.

---

## 2. Pipeline Structure Evaluation & Selection

### 2.1 Evaluation: 2-Stage vs 3-Stage Pipeline

Two candidate pipeline topologies were evaluated for Fursoy Slice-0:

```
Candidate A: 2-Stage Pipeline (Fetch [F] | Execute/Retire [E])
┌───────────────────────┐   F/E Register   ┌──────────────────────────────────────────────┐
│  Stage F (Fetch)      │================>>│  Stage E (Decode / Execute / Memory / Commit)│
│  - Next PC gen        │   insn, pc,      │  - RF Read, ALU, Control, LSU, CSR           │
│  - L1I streaming hit  │   status flags   │  - RF Writeback at clock edge                │
│  - ITLB lookup        │                  │  - Architectural Commit Point                │
└───────────────────────┘                  └──────────────────────────────────────────────┘

Candidate B: 3-Stage Pipeline (Fetch [F] | Decode/Execute [D/X] | Memory/Writeback [M/W])
┌─────────────┐   F/D Reg   ┌───────────────────────────┐   D/W Reg   ┌─────────────────────────┐
│ Stage F     │===========>>│ Stage D/X                 │===========>>│ Stage M/W               │
│ - Next PC   │  insn, pc   │ - RF Read                 │  res, rd,   │ - Memory response       │
│ - L1I lookup│             │ - ALU / Branch resolution │  ctrl       │ - RF Writeback          │
└─────────────┘             └───────────────────────────┘             └─────────────────────────┘
                                  ▲                                         │
                                  └──────── EX-to-EX Forwarding Bus ────────┘
```

| Evaluation Criterion | Candidate A: 2-Stage (Fetch \| Execute) | Candidate B: 3-Stage (Fetch \| Execute \| Writeback) |
|---|---|---|
| **Inter-Stage Registers** | 1 stage boundary (F/E) | 2 stage boundaries (F/D, D/W) |
| **RAW Hazard Forwarding** | **ZERO forwarding multiplexers required**. Register writeback occurs at clock edge ending Stage E; subsequent instruction reads updated RF in Stage E. | **Full EX-to-EX forwarding required** for both `rs1` and `rs2` from M/W to D/X. |
| **ALU-to-ALU Dependency** | **0-cycle stall, 1 IPC throughput** on dependent ALU instructions (`add a0, a1; add a0, a0`). | Requires combinational forwarding bus or 1-cycle stall. |
| **Load-to-Use Penalty** | Equivalent to LSU latency ($N$ cycles). Next instruction stalls in F. | $N$ cycles with forwarding; $N+1$ cycles without forwarding. |
| **Taken Branch Penalty** | **1 cycle bubble** (target fetched in F while branch commits in E). | **2 cycle bubble** (both F and D stages squashed). |
| **Untaken Branch Penalty** | **0 cycle penalty** (sequential fall-through instruction enters E immediately). | **0 cycle penalty** (fall-through enters D). |
| **Exception Precision** | Trivial: Stage E is the sole commit and trap point. Only 1 instruction in execution. | Complex: Distributed exceptions between D/X and M/W require tracking and cancel buses. |
| **Timing Feasibility** | **Verified**: Stage E path is `RF Read -> ALU -> RF Write setup`. This path is strictly shorter than the pre-pipeline core which did `L1I Hit -> RF Read -> ALU -> RF Write setup`. | Shorter cycle time potential, but excessive overhead for Slice-0 target frequency. |
| **Implementation Risk** | Minimal: Directly reuses existing ALU, control, LSU, and CSR modules with zero internal changes. | Moderate/High: Requires rewriting control logic, hazard detection, and forwarding muxes. |

### 2.2 Selected Architecture: 2-Stage In-Order Pipeline (Fetch | Execute)

**Decision: ACCEPT Candidate A (2-Stage Pipeline).**

The 2-stage organization is selected because:
1. **Natural match for L1I:** With the streaming hit extension, L1I delivers 1 instruction per cycle directly into the F/E pipeline boundary.
2. **Zero Forwarding Overhead:** By executing and writing back in Stage E, RAW register dependencies resolve automatically across the clock edge without forwarding multiplexers.
3. **Minimal Control Penalty:** Taken branches incur only a 1-cycle bubble; untaken branches incur 0 bubbles.
4. **Clean Verification Surface:** Exactly one instruction is in execution/commit at any cycle, eliminating out-of-order writeback, speculative state pollution, and imprecise trap risks.

---

## 3. L1I Streaming Hit Throughput Contract Extension (P0-1)

### 3.1 Motivation & Identification of Extension
Under the previously frozen L1I contract (`docs/architecture/l1i-cache-v1.md`), the FSM unconditionally transitioned `FETCH_CHECK -> FETCH_REQ` upon completing a hit. This imposed an alternating 2-cycle cadence (`FETCH_REQ` $\rightarrow$ `FETCH_CHECK`), preventing back-to-back hits.

To enable **1 instruction/cycle hit throughput after pipeline fill**, the pipeline architecture introduces a **strictly controlled, minimal streaming hit extension** to `fursoy_s0_l1i`.

### 3.2 Streaming L1I FSM Specification

```
                ┌────────────────────────────────────────────────────────┐
                │                                                        │
                ▼                                                        │
         ┌──────────────┐     fetch_enable && !stall                    │
         │  FETCH_REQ   │─────────────────────────────────┐              │
         └──────────────┘                                 │              │
                ▲                                         ▼              │
                │         hit && fetched_ready &&  ┌──────────────┐      │
                │         fetch_enable && !redir   │              │──────┘
                │       ┌──────────────────────────│ FETCH_CHECK  │ (streaming loop:
                │       │                          │              │  1 hit/cycle)
                │       ▼                          └──────────────┘
                │  (req_pc_q <= fetch_pc_i,               │  │
                │   remain in FETCH_CHECK)                │  │ miss
                │                                         │  └──────────┐
                │ hit && !fetched_ready                   │             │
                │                                         ▼             ▼
         ┌──────────────┐                          ┌──────────────┐ ┌──────────────┐
         │  FETCH_HOLD  │                          │  REFILL_REQ  │ │  REFILL_RSP  │
         └──────────────┘                          └──────────────┘ └──────────────┘
```

#### 3.2.1 Request Acceptance & Pipeline Streaming Loop
1. **Steady-State Streaming (`FETCH_CHECK` self-loop):**
   When L1I is in `FETCH_CHECK`, if:
   - `hit_condition == 1` (tag matched, ITLB translation valid, PMP permitted, DRAM range valid).
   - `fetched_ready_i == 1` (downstream Stage E accepts the current instruction).
   - `fetch_enable_i == 1` (Stage F is actively requesting the next instruction).
   - `redirect_i == 0` (no flush or branch redirect active).

   **Action:**
   - L1I presents the current instruction combinationally on `fetched_valid_o = 1`, `fetched_insn_o = hit_insn`, `fetched_pc_o = req_pc_q`.
   - L1I touches Tree-PLRU for the hit way.
   - At the clock edge, L1I registers `req_pc_q <= fetch_pc_i` (the *next* instruction PC presented by Stage F).
   - **L1I remains in `FETCH_CHECK`** instead of transitioning to `FETCH_REQ`.
   - In the next clock cycle, L1I immediately evaluates the translation and tag match for the new `req_pc_q`.
   - **Throughput:** Exactly 1 instruction hit delivered every clock cycle.

2. **Back-to-Back Same-Line and Different-Line Hits:**
   - **Same 64-byte line:** Tag and set index remain unchanged; new word offset is selected combinationally. 1 cycle latency.
   - **Different 64-byte line (resident in cache):** New set index and tag are evaluated combinationally from `req_pc_q` and `trans_pa_i`. If hit, 1 cycle latency.

3. **Transition from Streaming Hit to Miss / Refill:**
   If the instruction evaluated in `FETCH_CHECK` misses (`miss_condition == 1`):
   - `fetched_valid_o = 0`.
   - L1I transitions to `REFILL_REQ`.
   - `refill_line_base <= {trans_pa_i[55:6], 6'b0}`.
   - `refill_set_idx <= req_pc_q[11:6]`.
   - `refill_tag <= trans_pa_i[55:12]`.
   - `refill_victim <= plru_victim`.
   - `refill_beat_cnt <= 3'd0`.
   - 8-beat refill executes over the 64-bit `imem_*` bus exactly per frozen L1I v1 contract.

4. **Downstream Stage E Backpressure (`!fetched_ready_i`):**
   If `hit_condition == 1` but `fetched_ready_i == 0`:
   - L1I transitions to `FETCH_HOLD`.
   - Latches `held_valid_q <= 1'b1`, `held_pc_q <= req_pc_q`, `held_insn_q <= hit_insn`.
   - Holds instruction stable until `fetched_ready_i == 1`.
   - When Stage E ready asserts and `fetch_enable_i == 1`, L1I releases the held instruction, latches `req_pc_q <= fetch_pc_i`, and transitions back to `FETCH_CHECK`.

5. **Redirect & Flush Priority (`redirect_i == 1`):**
   If `redirect_i` asserts in any state:
   - Discards any held instruction (`held_valid_q <= 1'b0`).
   - Latches `req_pc_q <= fetch_pc_i` (the redirect target PC).
   - **Transitions directly to `FETCH_CHECK`** (ready to evaluate the redirect target in the immediately following cycle).
   - If a refill was active (`REFILL_REQ` or `REFILL_RSP`), sets `refill_abort_q <= 1'b1`. The 8-beat bus transaction completes to preserve interconnect ordering, but data installation into cache arrays is suppressed. Upon the 8th beat, L1I transitions to `FETCH_CHECK` for the redirect PC.

6. **Flash Invalidation (FENCE.I / PMP flush):**
   - Pulses to `fence_i_flush_i` or `pmp_flush_i` instantaneously clear all valid bits (`valid_q <= '0`) and clear `held_valid_q <= 1'b0`.
   - Active refills set `refill_abort_q <= 1'b1`.

7. **ITLB / PTW Stalls (`trans_busy_i == 1`):**
   - While ITLB translation is in progress, L1I stalls in `FETCH_CHECK`, holding `req_pc_q` constant with `fetched_valid_o = 0`.

8. **Strict Preservation of Invariant Properties:**
   The streaming extension modifies **only the FSM state transition on accepted hits and redirects**. It makes ZERO changes to:
   - Cache capacity (16 KiB), associativity (4-way), set count (64), line size (64 bytes).
   - VIPT zero-aliasing index (`PC[11:6]`) and physical tag width (`PA[55:12]`).
   - Tree-PLRU replacement algorithm.
   - PMP authorization ordering (Canonical $\rightarrow$ ITLB $\rightarrow$ PMP $\rightarrow$ Tag match).
   - Refill atomicity (no partial lines visible).

---

## 4. Pipeline Stages & Detailed Interface Contracts

```
               ┌─────────────────────────────────────────────────────────────┐
               │                     STAGE E (EXECUTE)                       │
               │                                                             │
               │  Branch/Jump Redirect ────────┐                             │
               │  Trap / Interrupt Redirect ───┼─────────────┐               │
               │  CSR / FENCE.I Flush ─────────┼──────────┐  │               │
               └───────────────────────────────┼──────────┼──┼───────────────┘
                                               │          │  │
                                               ▼          ▼  ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                             STAGE F (FETCH)                                │
│                                                                            │
│       ┌──────────────┐       ┌─────────────────┐       ┌────────────────┐  │
│       │ Next-PC Mux  │──────>│ Fetch PC Reg    │──────>│ fursoy_s0_l1i  │  │
│       │              │       │ (pc_f_q)        │       │ (Streaming FSM)│  │
│       └──────────────┘       └─────────────────┘       └────────────────┘  │
│              ▲                                                  │          │
│              │                                                  │ hit / flt│
└──────────────┼──────────────────────────────────────────────────┼──────────┘
               │                                                  ▼
               │       ====================================================
               │       PIPE REGISTER (F/E): fe_q.pc, fe_q.insn, fe_q.valid
               │       ====================================================
               │                                                  │
┌──────────────┼──────────────────────────────────────────────────┼──────────┐
│              │              STAGE E (EXECUTE / COMMIT)          ▼          │
│              │                                         ┌────────────────┐  │
│              │                                         │ Decoder & RF   │  │
│              │                                         └────────────────┘  │
│              │                                                  │          │
│              │       ┌─────────────────┬────────────────┬───────┴────────┐ │
│              │       │                 │                │                │ │
│              │       ▼                 ▼                ▼                ▼ │
│              │ ┌───────────┐    ┌─────────────┐   ┌───────────┐   ┌──────┐ │
│              │ │ ALU (Int) │    │ Control     │   │ LSU Port  │   │ CSR  │ │
│              │ └───────────┘    └─────────────┘   └───────────┘   └──────┘ │
│              │       │                 │                │            │     │
│              │       └─────────────────┼────────────────┼────────────┘     │
│              │                         ▼                ▼                  │
│              │                  ┌───────────────────────────────┐          │
│              └──────────────────│ Commit & Retirement Control   │          │
│                                 └───────────────────────────────┘          │
│                                                │                           │
│                                                ▼                           │
│                                 commit_valid_o, registers[rd] <= data      │
└────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Stage F: Instruction Fetch

#### 4.1.1 Fetch State Registers
- `pc_f_q [63:0]`: Registered address currently requested from L1I. Reset value: `RESET_PC` (`0x8000_0000`).
- `pending_pc_q [63:0]`: Tracks the next expected instruction address for precise interrupt return during pipeline bubbles.

#### 4.1.2 Formal Definition of `stall_f` (P1-2)
Stage F is stalled if and only if `stall_f` evaluates true:

$$\text{stall\_f} = \text{rst\_i} \lor \text{stall\_e} \lor \text{l1i\_miss\_active} \lor \text{itlb\_busy} \lor \text{l1i\_hold\_active} \lor \text{serialize\_active}$$

Where:
- `rst_i`: Hardware reset asserted.
- `stall_e`: Stage E backpressure (LSU in-flight load/store/AMO, multi-cycle CSR, `SFENCE.VMA` draining).
- `l1i_miss_active`: L1I is actively performing an 8-beat memory refill (`state_q == REFILL_REQ || state_q == REFILL_RSP`).
- `itlb_busy`: MMU page table walk active for instruction translation (`trans_busy_i == 1`).
- `l1i_hold_active`: L1I holding buffer is occupied because Stage E is not ready (`state_q == FETCH_HOLD`).
- `serialize_active`: Pipeline serialization barrier active.

**Invariant Rule:** `pc_f_q` and L1I internal request state **MUST NEVER advance** while `stall_f` is true unless an overriding redirect is asserted.

#### 4.1.3 Next-PC Generation Mux Priority
The target address for `pc_f_q` is selected on every clock cycle according to strict priority:

```systemverilog
always_comb begin
    if (redirect_trap_e) begin
        next_pc_f = trap_target_pc_e;       // Priority 1: Trap/interrupt vector (mtvec/stvec)
    end else if (redirect_mret_e) begin
        next_pc_f = mepc_q;                 // Priority 2: MRET return PC
    end else if (redirect_sret_e) begin
        next_pc_f = sepc_q;                 // Priority 3: SRET return PC
    end else if (redirect_branch_e) begin
        next_pc_f = branch_target_e;        // Priority 4: Taken branch, JAL, or JALR target
    end else if (redirect_flush_e) begin
        next_pc_f = fe_q.pc + 64'd4;        // Priority 5: CSR write, FENCE.I, SFENCE serialize
    end else if (!stall_f) begin
        next_pc_f = pc_f_q + 64'd4;         // Priority 6: Sequential advance (streaming hit)
    end else begin
        next_pc_f = pc_f_q;                 // Priority 7: Stall hold
    end
end
```

### 4.2 Inter-Stage Pipeline Register (`fe_q`)

```systemverilog
typedef struct packed {
    logic        valid;         // Instruction valid in Stage E
    logic [63:0] pc;            // Virtual PC of instruction in Stage E
    logic [31:0] insn;          // 32-bit instruction word
    logic        fetch_error;   // Instruction access fault occurred (cause 1)
    logic        page_fault;    // Instruction page fault occurred (cause 12)
} fe_reg_t;

fe_reg_t fe_q;
```

#### 4.2.1 F/E Register Control Logic
- **Stall (`stall_e`):** `fe_q <= fe_q` (freezes contents).
- **Flush (`flush_e`):** `fe_q.valid <= 1'b0` (squashes instruction).
- **Advance (`!stall_e && !flush_e`):**
  * `fe_q.valid       <= l1i_fetched_valid_o && !redirect_any_e;`
  * `fe_q.pc          <= l1i_fetched_pc_o;`
  * `fe_q.insn        <= l1i_fetched_insn_o;`
  * `fe_q.fetch_error <= l1i_fetched_error_o;`
  * `fe_q.page_fault  <= l1i_fetched_page_fault_o;`

### 4.3 Stage E: Decode, Execute, Memory, and Retirement

#### 4.3.1 Execution Datapath
1. **Register File (32 × 64-bit):**
   - Combinational read: `rs1_val = registers[fe_q.insn[19:15]]`, `rs2_val = registers[fe_q.insn[24:20]]`.
   - Synchronous write: `registers[commit_rd] <= commit_rd_data` at posedge clk when `commit_valid_o && commit_rd_write_o && (commit_rd != 0)`.
2. **Integer ALU (`fursoy_s0_int_alu`):** 1-cycle combinational OP-IMM, OP, RV64M mul/div.
3. **Control Engine (`fursoy_s0_control`):** Combinational branch comparison and target generation.
4. **LSU Port (`fursoy_s0_lsu_port`):** Multi-cycle memory operations, LR/SC reservations, AMOs.
5. **CSR Unit (`fursoy_s0_csr`, `fursoy_s0_pmp`):** Privilege, status, trap delegation, PMP registers.

#### 4.3.2 Retirement & Commit Interface
An instruction officially commits and updates architectural state if and only if `commit_fire` asserts in Stage E:

```systemverilog
wire commit_fire = fe_q.valid && !trap_take && (
    alu_valid ||
    (mret_valid && mret_legal) ||
    (sret_valid && sret_legal) ||
    (wfi_valid && wfi_legal) ||
    fence || fence_i ||
    (sfence_legal && mmu_idle) ||
    (control_valid && !control_misaligned) ||
    (csr_valid && !csr_illegal) ||
    lsu_retire
);

assign commit_valid_o    = commit_fire;
assign commit_pc_o       = fe_q.pc;
assign commit_insn_o     = fe_q.insn;
assign commit_rd_write_o = commit_fire && rd_write_selected;
assign commit_rd_o       = rd_dest_selected;
assign commit_rd_data_o  = rd_data_selected;
```

---

## 5. Hazard Handling & Data Dependency Contracts

### 5.1 RAW Data Hazards & Zero-Forwarding Proof

**Architectural Rule:** Fursoy Slice-0 v1 requires **ZERO EX-to-EX data forwarding multiplexers**.

#### Formal Timing Proof
Consider an arbitrary back-to-back dependent ALU instruction sequence:
```assembly
Cycle T:    Inst 1 in Stage E: addi a0, zero, 5    (writes a0)
Cycle T+1:  Inst 2 in Stage E: addi a1, a0, 10      (reads a0)
```
1. In Cycle $T$, Inst 1 executes in Stage E. Its ALU result (`5`) is ready combinationally.
2. At the rising clock edge ending Cycle $T$ (beginning Cycle $T+1$):
   - Inst 1 commits.
   - `registers[10] <= 5` is written into the register file.
   - Inst 2 moves from Stage F into Stage E (`fe_q.insn <= Inst 2`).
3. In Cycle $T+1$, Inst 2 executes in Stage E. Its combinational register read accesses `registers[10]`.
4. Because `registers[10]` holds value `5` as of the clock edge, Inst 2 reads `5` with **zero wait states and zero forwarding logic**.
5. **Throughput:** Exactly 1 cycle per instruction (IPC = 1.0) on dependent ALU chains.

### 5.2 Load-to-Use Hazards
When instruction $i$ in Stage E is a load and instruction $i+1$ reads the loaded register:
1. Cycle $T$: Load enters Stage E, issues memory request (`vd_req_valid = 1`). Stage E asserts `stall_e = 1`, holding instruction $i+1$ in Stage F.
2. When LSU receives read data (`vd_rsp_valid = 1`):
   - LSU formats sign/zero-extension (`lsu_retire_data`).
   - At clock edge, `registers[rd] <= lsu_retire_data` is written, and `stall_e` deasserts.
3. Next cycle, instruction $i+1$ enters Stage E, reads the newly written register, and executes.
4. **Load-to-Use Penalty:** Exactly equal to the memory latency. Zero additional hazard bubble cycles.

---

## 6. Control-Flow & Branch Resolution Contract (P1-1)

### 6.1 Baseline Static Prediction Policy
The baseline pipeline implements **predict-not-taken (fall-through)**:
- Stage F generates `pc_f_q + 4` as default next PC. No BTB is required for correctness.

### 6.2 Cycle-by-Cycle Branch Timing Derivation

#### Scenario 1: Conditional Branch NOT TAKEN (50.77% of branches in Linux baseline)
- **Cycle $T$:** Branch executes in Stage E, evaluates condition as UNTAKEN.
  * `commit_valid_o = 1`, `redirect_branch_e = 0`.
  * Fall-through instruction (`fe_q.pc + 4`) was already requested in Stage F during Cycle $T$ and hits in streaming L1I.
  * At clock edge ending Cycle $T$, fall-through instruction enters Stage E (`fe_q.valid <= 1`).
- **Cycle $T+1$:** Fall-through instruction executes and commits in Stage E!
- **Branch Penalty:** **EXACTLY 0 BUBBLE CYCLES (Zero-Stall Fall-Through).**

#### Scenario 2: Conditional Branch TAKEN (49.23% of branches) or JAL / JALR
- **Cycle $T$:** Branch executes in Stage E, evaluates condition as TAKEN.
  * Target PC computed: `branch_target_e = fe_q.pc + imm` (or `rs1 + imm`).
  * Branch commits (`commit_valid_o = 1`, `commit_pc_o = fe_q.pc`).
  * Stage E asserts `redirect_branch_e = 1`, driving `branch_target_e` into Stage F.
  * F/E register is flushed: `fe_q.valid <= 1'b0` (squashes speculative fall-through instruction).
  * L1I receives `redirect_i = 1`, latches `req_pc_q <= branch_target_e`, and enters `FETCH_CHECK`.
- **Cycle $T+1$ (Pipeline Bubble):**
  * Stage E observes `fe_q.valid == 0` (**Bubble Cycle**; zero commits, zero register writes).
  * L1I is in `FETCH_CHECK` evaluating `branch_target_e`. Tag matches!
  * At end of Cycle $T+1$, L1I presents target instruction on `fetched_valid_o = 1`.
  * Target instruction clocked into F/E register (`fe_q.valid <= 1`, `fe_q.pc <= branch_target_e`).
- **Cycle $T+2$:** Target instruction executes and commits in Stage E!
- **Branch Penalty:** **EXACTLY 1 BUBBLE CYCLE on L1I Hit.**

#### Scenario 3: Taken Branch with Target Missing in L1I
- **Cycle $T$:** Branch commits in Stage E. Redirect asserted.
- **Cycle $T+1$:** L1I evaluates `branch_target_e` in `FETCH_CHECK`. Tag mismatch!
  * L1I transitions to `REFILL_REQ`.
- **Cycles $T+1$ to $T+10$:** L1I performs 8-beat refill from DRAM. Stage E remains empty (`fe_q.valid == 0`).
- **Cycle $T+11$:** Target instruction enters Stage E and commits.
- **Branch Penalty:** **1 cycle redirect bubble + 8–10 cycles refill latency.**

---

## 7. Exception, Trap, and Interrupt Semantics (P0-2, P1-4)

### 7.1 Synchronous Exception vs Interrupt Priority Rule (P1-4)

**Architectural Law:** A synchronous exception belonging to the oldest valid instruction takes **ABSOLUTE PRECEDENCE** over any pending interrupt at that cycle boundary.

```
       Is an instruction in Stage E (fe_q.valid == 1)?
                         │
         ┌───────────────┴───────────────┐
        YES                              NO (Bubble Cycle)
         │                               │
Does it have a synchronous exception?    Does pending interrupt qualify?
(Fetch fault, illegal, misaligned,       (m_irq_take || s_irq_take)
 ECALL/EBREAK, LSU fault)                │
         │                               ├─ YES: Take Interrupt
 ┌───────┴───────┐                       │       Saved EPC = pending_pc_q
YES              NO                      └─ NO:  Normal Bubble Hold
 │               │
Take Synchronous Does pending interrupt qualify?
Exception!       (m_irq_take || s_irq_take)
Saved EPC =      │
fe_q.pc          ├─ YES: Commit instruction, THEN Take Interrupt!
Interrupt        │       Saved EPC = (branch_taken ? target : fe_q.pc + 4)
Deferred!        └─ NO:  Commit instruction normally!
```

#### Detailed Priority Ranking:
1. **Instruction Fetch Exceptions (causes 12, 1):** Detected in Stage F, carried in `fe_q`. If instruction reaches Stage E without prior redirect, traps with `mepc = fe_q.pc`, `mtval = fe_q.pc`.
2. **Instruction Address Misaligned (cause 0):** Taken branch/jump target in Stage E has `target[1:0] != 0`. Traps with `mepc = fe_q.pc`, `mtval = target`.
3. **Illegal Instruction (cause 2):** Invalid opcode, CSR privilege error, TVM/TSR/TW violation in Stage E. Traps with `mepc = fe_q.pc`, `mtval = fe_q.insn`.
4. **System Traps (causes 3, 8, 9, 11):** `EBREAK`, `ECALL`. Traps with `mepc = fe_q.pc`, `mtval = 0`.
5. **LSU Synchronous Exceptions (causes 4, 6, 5, 7, 13, 15):** Misaligned address, access fault, page fault. Traps with `mepc = fe_q.pc`, `mtval = fault_addr`. Zero memory writes emitted.
6. **Asynchronous Interrupts (MEI > MSI > MTI > SEI > SSI > STI):** Evaluated ONLY if Stage E has NO synchronous exception.

### 7.2 Explicit Architectural Resume-PC Rule (P0-2)

At an accepted interrupt boundary, the saved EPC (`mepc` or `sepc`) is determined by the **Architectural Resume-PC Rule**:

```systemverilog
always_comb begin
    if (sync_trap_take) begin
        // Synchronous exception: saved EPC is ALWAYS the faulting instruction PC
        saved_epc = fe_q.pc;
    end else if (commit_fire) begin
        // Interrupt taken after an instruction successfully retired in Stage E:
        if (control_valid && branch_taken) begin
            // Retiring instruction was a TAKEN branch, JAL, or JALR:
            // Resume at the branch target!
            saved_epc = branch_target_e;
        end else begin
            // Retiring instruction was a sequential instruction (ALU, load, store, untaken branch, WFI):
            // Resume at the sequential next instruction!
            saved_epc = fe_q.pc + 64'd4;
        end
    end else if (fe_q.valid) begin
        // Interrupt preempts an uncommitted instruction in Stage E (e.g. multi-cycle stall):
        // Resume at the uncommitted instruction itself!
        saved_epc = fe_q.pc;
    end else begin
        // Interrupt taken during a pipeline bubble (fe_q.valid == 0, e.g. L1I miss or branch bubble):
        // Resume at the pending target instruction!
        saved_epc = pending_pc_q;
    end
end
```

#### Verification Against All Reviewer Cases:
- **Sequential Execution:** Instruction $i$ commits. Interrupt taken. $\text{EPC} = \text{fe\_q.pc} + 4$. Stage F flushed. Returns cleanly to instruction $i+1$.
- **Taken Branch / JAL / JALR:** Branch commits. Interrupt taken. $\text{EPC} = \text{branch\_target\_e}$. Stage F flushed. Returns cleanly to target instruction.
- **Stage E Empty / Bubble:** $\text{EPC} = \text{pending\_pc\_q}$. Returns cleanly to pending instruction.
- **L1I Miss / Refill:** Stage E empty. $\text{EPC} = \text{pending\_pc\_q}$ (the missing PC). Refill aborted via `refill_abort_q`. Returns cleanly to re-fetch missing PC.
- **LSU Stall:** Interrupt deferred until LSU completes. If LSU completes cleanly, $\text{EPC} = \text{fe\_q.pc} + 4$. If LSU faults, synchronous exception takes absolute priority ($\text{EPC} = \text{fe\_q.pc}$).
- **Fetch Fault:** If Stage E commits, interrupt taken at $\text{EPC} = \text{fe\_q.pc} + 4$. Faulting instruction in Stage F squashed without side effects.
- **Simultaneous Retirement + Interrupt Eligibility:** Handled cleanly by `commit_fire` branch above.
- **Trap Vector PC Isolation:** `trap_target_pc` is derived from `mtvec`/`stvec` and drives `next_pc_f`. It is NEVER an input to `saved_epc`.

---

## 8. System, Security, and Memory Ordering Contracts (P1-3, P2)

### 8.1 CSR Serialization Audit & Classification (P1-3)

| CSR Group | Target CSRs | Architectural Effect | Pipeline Action | Correctness Rationale |
|---|---|---|---|---|
| **Class 1: Virtual Memory Root** | `satp` | Modifies translation mode (Bare $\leftrightarrow$ Sv39) and ASID/PPN. | **Full Serialize & Flush.** Flushes Stage F; restarts fetch at `fe_q.pc + 4`. | Instructions in Stage F fetched under old virtual mapping are stale. Must re-fetch under new page table. |
| **Class 2: Physical Memory Protection** | `pmpcfg0`, `pmpcfg2`, `pmpaddr0`..`15` | Modifies PMP permission boundaries. | **Full Serialize & Flush + L1I Invalidation.** Pulses `pmp_flush_o`; flushes Stage F; restarts fetch at `fe_q.pc + 4`. | L1I cached lines authorized under old PMP configuration must be invalidated. |
| **Class 3: Privilege & Translation Modes** | `mstatus`, `sstatus` | Modifies `MPRV`, `SUM`, `MXR`, `TVM`, `TSR`, `TW`, `MPP`, `SPP`. | **Full Serialize & Flush.** Flushes Stage F; restarts fetch at `fe_q.pc + 4`. | Subsequent fetches and data accesses depend immediately on updated privilege and permission modifier bits. |
| **Class 4: Trap Vector Configuration** | `mtvec`, `stvec` | Modifies trap vector base address and mode (Direct vs Vectored). | **Commit Sync.** Updates register at commit edge. No flush required. | Only traps consume `mtvec`/`stvec`. Updating synchronously at commit guarantees any trap on subsequent cycles uses new vector. |
| **Class 5: Trap Delegation** | `medeleg`, `mideleg` | Modifies exception and interrupt delegation routing to S-mode. | **Commit Sync.** Updates register at commit edge. No flush required. | Subsequent exceptions/interrupts route per newly committed mask. |
| **Class 6: Interrupt Enables** | `mie`, `sie` | Modifies individual interrupt enable bits. | **Commit Sync.** Updates register at commit edge. No flush required. | Subsequent interrupt sampling reflects updated mask. |
| **Class 7: Environment Config** | `menvcfg`, `senvcfg` | Modifies `FIOM` (Fence of I/O Implies Memory). | **Commit Sync.** Updates register at commit edge. | Affects FENCE interpretation. |
| **Class 8: Scratch Registers** | `mscratch`, `sscratch` | Context storage for trap handlers. | **Standard Writeback.** No pipeline flush. | Pure data register; zero side-effects on hardware pipeline. |
| **Class 9: Counters** | `cycle`, `time`, `instret` | Monotonic execution counters. | **Read-Only.** Normal read. | Writes cause illegal instruction trap. |

### 8.2 Architectural WFI Specification (P2)
In Fursoy Slice-0 v1, legal `WFI` in M-mode, or in S-mode when `mstatus.TW == 0`, is implemented as an **architectural single-cycle NOP**:
- Commits normally (`commit_valid_o = 1`).
- Advances to `fe_q.pc + 64'd4`.
- Any pending, enabled interrupt is delivered at the subsequent instruction boundary.
- If executed in U-mode, or in S-mode when `mstatus.TW == 1`, raises Illegal Instruction (cause 2).

### 8.3 Memory Synchronization (`FENCE` and `FENCE.I`)
- `FENCE`: Single-hart Slice-0 with serialized in-order memory execution executes `FENCE` as a 1-cycle NOP in Stage E.
- `FENCE.I`:
  * Commits in Stage E.
  * Emits `fence_i_valid_o = 1` pulse to L1I, flash invalidating all L1I cache tags.
  * Flushes Stage F and restarts fetch at `fe_q.pc + 4`, ensuring subsequent fetches observe memory writes.

### 8.4 Virtual Memory Invalidation (`SFENCE.VMA`)
- Stage E stalls until `mmu_idle == 1`.
- Asserts `sfence_vma_w = 1`, invalidating matching entries in ITLB and DTLB.
- Flushes Stage F and restarts fetch at `fe_q.pc + 4`.

### 8.5 Privilege Returns (`MRET` and `SRET`)
- `MRET`: Restores privilege mode from `mstatus.MPP`, updates `MIE <= MPIE, MPIE <= 1`. Flushes Stage F and redirects `pc_f_q` to `mepc_q`.
- `SRET`: Restores privilege mode from `mstatus.SPP`, updates `SIE <= SPIE, SPIE <= 1`. Flushes Stage F and redirects `pc_f_q` to `sepc_q`.

### 8.6 RV64A Atomicity & Reservations
- `LR.W` / `LR.D`: Sets 56-bit exact PA and size reservation in `fursoy_s0_lsu_port`.
- `SC.W` / `SC.D`: Validates exact PA and size match. Emits store on match; suppresses store and returns 1 on mismatch.
- Any trap, interrupt, `MRET`, `SRET`, `SFENCE.VMA`, or `satp` write clears reservation.
- AMOs remain indivisible: Stage E asserts `lsu_issue_ready = 0` throughout the read-modify-write cycle, blocking interrupts and holding Stage F.

---

## 9. Performance Projections vs Measured Baselines

> **CRITICAL DISCLAIMER:** All values labeled **Projected / Estimate** in this section are analytical projections derived from measured execution profiles. They are design targets, not measured results.

### 9.1 Cycle-by-Cycle Analytical Derivation

From the 42,575,777 execution cycles of the post-L1I baseline:
$$\text{Cycles}_{\text{new}} = \text{Useful Retirement} + \text{Fetch Penalty} + \text{LSU Stalls} + \text{PTW Stalls} + \text{Trap Stalls}$$

1. **Useful Retirement:** 15,216,301 cycles (unavoidable; 1 cycle per instruction).
2. **Fetch Penalty in 2-Stage Pipeline with Streaming L1I:**
   - Sequential instructions hitting in L1I: **0 stall cycles** (completely overlapped with prior instruction execution in Stage E).
   - L1I misses (246,953 misses $\times \approx 9.8$ cycles): **~2,420,000 cycles**.
   - Taken branches (1,044,804 $\times$ 1 bubble cycle): **1,044,804 cycles**.
   - Jumps (JAL: 468,586 + JALR: 388,678 $\times$ 1 bubble cycle): **857,264 cycles**.
   - Untaken branches (1,077,491 $\times$ 0 cycles): **0 cycles**.
   - Total Fetch Stalls: $\approx 2.42\text{M} + 1.04\text{M} + 0.86\text{M} \approx \mathbf{4,322,000\text{ cycles}}$ (down from 24,618,624 cycles; **82.4% reduction in fetch wait!**).
3. **LSU Stalls:** 2,736,970 cycles (unchanged in this milestone).
4. **PTW Stalls:** 2,960 cycles (unchanged).
5. **Trap Stalls:** 922 cycles (unchanged).

$$\text{Estimated Total Cycles} \approx 15,216,301 + 4,322,000 + 2,736,970 + 2,960 + 922 \approx \mathbf{22,279,000\text{ cycles}}$$

### 9.2 Comparative Projection Table

| Performance Metric | Measured Post-TLB Baseline | Measured Post-L1I Baseline | Projected 2-Stage Pipeline (*Estimate*) | Projected Delta vs Post-L1I (*Estimate*) |
|---|---|---|---|---|
| **Total Execution Cycles** | 54,131,089 | 42,575,777 | **~22,300,000 - 24,000,000** | **-18.5M to -20.2M (-43% to -47%)** |
| **Committed Instructions** | 15,358,679 | 15,216,301 | ~15,100,000 - 15,200,000 | Minimal change |
| **IPC** | 0.283731 | 0.357393 | **~0.63 - 0.68** | **+76% to +90% IPC boost** |
| **CPI** | 3.524463 | 2.798037 | **~1.47 - 1.58** | **-43% to -47% CPI reduction** |
| **Pure Fetch Wait Cycles** | 30,719,056 | 24,618,624 | **~4,300,000 - 5,500,000** | **-77% to -82% fetch stall cut** |
| **Cold Boot Cycles (to PID 1)**| 54,017,605 | 42,344,211 | **~22,000,000** | **~48% boot cycle reduction** |

---

## 10. Comprehensive Verification & Acceptance Plan (P2)

A dedicated verification testbench (`verification/pipeline_s0_tb.cpp`) and runner (`tools/run_pipeline_s0.py`) will execute 47 targeted architectural scenarios before accepting RTL.

### 10.1 Targeted Scenario Matrix

| Scenario Group | ID | Test Scenario | Mandatory Acceptance Criterion |
|---|---|---|---|
| **RAW & Dependency Hazards** | 1 | Consecutive dependent ALU instructions | `addi a0, a0, 1` repeated 100 times executes at exactly 1 cycle/insn. |
| | 2 | Dependent ALU across different registers | `add a2, a0, a1; sub a3, a2, a0` computes correct values at 1 IPC. |
| | 3 | x0 source dependency | Reading `x0` always produces `0` regardless of previous writes. |
| | 4 | Load-to-use dependent ALU | `lw a0, 0(sp); addi a1, a0, 1` stalls Stage E until load retires, then executes correctly. |
| | 5 | Load-to-use dependent Store | `lw a0, 0(sp); sw a0, 8(sp)` waits for load data before emitting store. |
| | 6 | Load-to-use dependent Branch | `lw a0, 0(sp); beq a0, zero, target` evaluates branch correctly after load data arrival. |
| **Control-Flow & Redirects** | 7 | Sequential untaken branch | Untaken branch executes with 0 bubble cycles; fall-through commits immediately. |
| | 8 | Taken conditional branch | Taken branch commits, squashes fall-through, target executes with exactly 1 bubble cycle. |
| | 9 | Consecutive taken branches | Back-to-back taken branches resolve cleanly with 1 bubble cycle each. |
| | 10 | Unconditional JAL | Writes `PC+4` to link register, redirects to target with 1 bubble cycle. |
| | 11 | Indirect JALR with dependency | `jalr ra, a0, 0` where `a0` was written by preceding instruction executes without stall. |
| | 12 | Misaligned branch target | Branch to non-4-byte address raises Instruction Address Misaligned (cause 0), `mtval = target`. |
| **L1I Interaction & Streaming** | 13 | L1I hit sequential streaming | Consecutive instructions in same/different lines retire at sustained 1 cycle per instruction. |
| | 14 | L1I miss during streaming fetch | Miss in Stage F holds F/E register empty (`valid = 0`) until 8-beat refill completes. |
| | 15 | Branch redirect while L1I refill active | Taken branch while refill is inflight pulses `refill_abort_q`, drains bus, retargets cleanly. |
| | 16 | Trap redirect while L1I refill active | Synchronous fault during refill aborts line installation and redirects to trap handler. |
| | 17 | Back-to-back refills different sets | Line miss immediately followed by another line miss handshakes bus without deadlock. |
| **Exceptions & Precision** | 18 | Fetch page fault precision | Instruction page fault in F does not trap if preceding branch in E redirects away. |
| | 19 | Fetch page fault commit | Instruction page fault reaching E traps with `mcause = 12`, `mepc = fe_q.pc`, `mtval = fe_q.pc`. |
| | 20 | Fetch access fault commit | PMP-denied fetch reaching E traps with `mcause = 1`, `mepc = fe_q.pc`, `mtval = fe_q.pc`. |
| | 21 | Illegal instruction precision | Illegal opcode in E squashes F, writes `mcause = 2`, `mepc = fe_q.pc`, `mtval = fe_q.insn`. |
| | 22 | ECALL trap precision | ECALL in E traps with cause 11/9/8, `mepc = fe_q.pc`, `mtval = 0`, squashes subsequent fetch. |
| | 23 | LSU misaligned exception priority | Misaligned store raises cause 6 before memory bus request is emitted. |
| | 24 | LSU page fault exception priority | Load page fault in E squashes incoming instruction in F and vectors to trap handler. |
| **Interrupts & Precedence** | 25 | Timer interrupt at ALU commit | Interrupt delivered between consecutive ALU instructions; `mepc` records uncommitted PC. |
| | 26 | External interrupt during LSU wait | Interrupt deferred until in-flight load/store completes; `mepc` points to next instruction. |
| | 27 | Sync exception vs interrupt priority | Synchronous exception in E takes absolute precedence over pending interrupt. |
| | 28 | Interrupt squashing speculative branch | Interrupt arriving when taken branch is in E: branch commits, interrupt taken at branch target. |
| **System & Security Serialization**| 29 | CSR write serialization | CSR write in E flushes F and re-fetches `pc + 4` under new CSR state. |
| | 30 | `satp` write pipeline flush | `satp` write flushes Stage F; next fetch uses updated translation root. |
| | 31 | `mstatus.MPRV` modification | Data access immediately reflects modified MPRV privilege without pipeline delay. |
| | 32 | `SFENCE.VMA` serialization | Stalls until `mmu_idle`, flushes TLBs and Stage F, restarts fetch cleanly. |
| | 33 | `FENCE.I` tag invalidation | Flash invalidates L1I, flushes Stage F, re-fetches modified instruction from memory. |
| | 34 | `MRET` privilege return | Restores privilege and MIE, redirects to `mepc`, squashes Stage F. |
| | 35 | `SRET` privilege return | Restores privilege and SIE, redirects to `sepc`, squashes Stage F. |
| | 36 | `WFI` legal execution | Advances to `fe_q.pc + 4` on interrupt or acts as 1-cycle architectural NOP. |
| **RV64A Atomics** | 37 | LR/SC reservation lifecycle | LR sets reservation; SC succeeds; intervening trap clears reservation. |
| | 38 | AMO indivisibility | Multi-cycle AMO holds `lsu_issue_ready = 0`; interrupts blocked until writeback. |
| | 39 | Failed SC store suppression | Failed SC writes `rd = 1`, emits 0 physical memory writes, pipeline advances cleanly. |
| **Memory Backpressure & Stress** | 40 | Random DRAM request stall | Memory stalls on load/store correctly backpressure Stage E and Stage F without losing state. |
| | 41 | Random L1I refill backpressure | Ready deassertions during 8-beat refill do not disrupt beat counter or line installation. |
| | 42 | Simultaneous branch redirect & RAM rsp | Branch taken in E in exact same cycle that delayed RAM response arrives: cleanly handled. |
| **Reviewer Adversarial Scenarios** | **43** | **Misaligned branch + pending interrupt** | Misaligned branch target calculation in E raises cause 0; `mtval = target`; simultaneous pending interrupt deferred. |
| | **44** | **`sstatus` SUM/MXR change immediate access** | `sstatus.SUM` updated from 0 to 1 immediately followed by S-mode load of U-page: load succeeds without page fault. |
| | **45** | **LSU fault + simultaneous external IRQ** | LSU load access fault with simultaneous external interrupt asserting: cause 5 taken, `mtval = addr`; interrupt deferred. |
| | **46** | **MRET/SRET return into L1I miss** | `MRET` returns to address that misses in L1I: Stage F initiates 8-beat refill cleanly; `mepc` not corrupted; resumes cleanly. |
| | **47** | **Repeated/back-to-back flush/redirect races** | Taken branch in cycle $T$ redirects to target; external interrupt arrives in cycle $T+1$ during bubble: interrupt saves target PC in `mepc`. |

### 10.2 Full Regression Gate
The pipeline implementation is accepted only when all 16 repository test suites pass without regression:
1. `tools/run_pipeline_s0.py` (47/47 scenarios pass)
2. `tools/run_l1i_s0.py` (19/19 scenarios pass)
3. `tools/run_tlb_s0.py` (20/20 scenarios pass)
4. `tools/run_sv39_mmu_s0.py` (54/54 scenarios pass)
5. `tools/run_pmp_s0.py` (29/29 scenarios pass)
6. `tools/run_rv64a_s0.py` (46/46 scenarios pass)
7. `tools/run_core_smode_s0.py` (14/14 scenarios pass)
8. `tools/run_sbi_s0.py` (40/40 scenarios pass)
9. `tools/run_soc_sv39_s0.py` (1 scenario pass)
10. `tools/run_soc_clint_baremetal_s0.py` (1 scenario pass)
11. `tools/run_plic_s0.py` (28/28 scenarios pass)
12. `tools/run_uart_s0.py` (24/24 scenarios pass)
13. `tools/run_dt_s0.py` (25/25 checks pass)
14. `tools/run_core_baremetal_s0.py` (11 ELFs pass)
15. `tools/run_linux_s0.py` (Cold boot to PID 1 `/init` active banner passes)
16. `tools/run_perf_baseline_s0.py` (Post-pipeline performance baseline remeasured and logged to `results/perf-baseline-s0.json`)
