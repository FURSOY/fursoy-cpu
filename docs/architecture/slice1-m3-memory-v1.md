# Fursoy Slice-1 Milestone 3 — Out-of-Order Memory Execution Subsystem Architecture Specification

**Document ID:** `docs/architecture/slice1-m3-memory-v1.md`
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.2 (Milestone 3 Final Architecture Closeout Baseline)
**Target Core:** Fursoy Slice-1 (Milestone 3: Out-of-Order Memory Subsystem, RV64IMA + Zicsr + Zifencei + Sv39)
**Predecessor Substrates:**
- Milestone 1 (Verified & Frozen: PRF80, ROB48, FreeList48, SRAT/ARAT, Recovery Substrate)
- Milestone 2 (Verified & Frozen: PRF Data Storage, IntIQ, ALU0/1, Branch, Multiplier, Divider, Lossless Port 1 Completion)
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m2-backend-v1.md`

---

## 1. Executive Summary & Milestone Scope

### 1.1 Context & Objective
Fursoy Slice-1 Milestones 1 and 2 established and froze the 2-wide out-of-order execution core for integer arithmetic, branch resolution, and pipelined multiplication/division.
- Milestone 1 provided the verified rename, allocation, circular ROB48, circular FreeList48, and branch checkpoint/recovery substrate.
- Milestone 2 turned this into a functional execution engine with 64-bit PRF storage, 16-entry IntIQ, Port 0 (ALU0/BR), Port 1 (ALU1/MUL/DIV), lossless writeback arbitration, and M1-validated completion gating.

**Milestone 3 (M3)** turns this execution core into a processor capable of **correct, high-throughput, speculative out-of-order memory execution**. M3 defines the complete Load/Store Unit (LSU), Memory Issue Queue (MemIQ), Load Queue (LQ), Store Queue (SQ), Address Generation Unit (Port 2 AGU), non-blocking L1 Data Cache (L1D), Miss Status Holding Registers (MSHR), dedicated Writeback Buffer (WBB), store-to-load forwarding, translation interface, and end-to-end memory transaction lifetime protection.

```
+===================================================================================================+
|                                    MILESTONE 3 ARCHITECTURAL BOUNDARY                             |
+===================================================================================================+

   +---------------------------------------------------------------------------------------------+
   | FROZEN M1+M2 ARCHITECTURAL SUBSTRATE & INTEGER BACKEND                                      |
   | - 2-Wide Rename / Dispatch         - 48-Entry Circular Free List    - 8 Branch Checkpoints  |
   | - 80-Entry PRF Data Storage (6R3W) - 48-Entry Circular ROB          - Epoch Tag Protection  |
   | - Execution Port 0 (ALU0/Branch)   - Execution Port 1 (ALU1/M/D)    - rob_dist Wrap Safety  |
   +---------------------------------------------------------------------------------------------+
               |                                                                   ^
               | uop_renamed_t [1:0]                                               | comp_valid_i[2]
               | prf_ready_o [79:0]                                                | comp_rob_idx_i, epoch_i
               | R4 (Base), R5 (Store Data)                                        | comp_ack_o[2]
               v                                                                   | recover_valid_i, flush
   +=============================================================================================+
   | IN-SCOPE: MILESTONE 3 OUT-OF-ORDER MEMORY SUBSYSTEM                                         |
   |                                                                                             |
   |   [ 12-Entry MemIQ ] ===> [ Age Select ] ===> [ Port 2 AGU ] <---> [ DTLB / PMP Interface ] |
   |          |                                            |                                     |
   |          v                                            v                                     |
   |   [ 16-Entry Load Queue ] <================== [ 16-Entry Store Queue ]                      |
   |          |                  (Disambig & Forward)      |                                     |
   |          v                                            v (In-Order at Commit)                |
   |   +-------------------------------------------------------------------------------------+   |
   |   | Non-Blocking L1D Cache (16 KiB 4-Way / 32 KiB 8-Way, VIPT Synonym Safe Way <= 4 KiB)|   |
   |   | - 4 MSHRs (Multi-Waiter Sizing, Selective Waiter Squash, Structural Non-Aliasing)   |   |
   |   | - 2-Entry Dirty Writeback Buffer (WBB) (Authoritative Dirty Owner, Pre-Allocated)   |   |
   |   +-------------------------------------------------------------------------------------+   |
   |          |                                                                                  |
   |          v                                                                                  |
   |   [ Port 2 Validated Writeback ] -----------------------------------------------------------+
   +=============================================================================================+
               |
               v
    Bus Interface / Coherent Memory Interconnect (Protocol-Neutral Boundary)
```

### 1.2 PRF Port Expansion (Clarification of M2 vs M3 Scope)
- **Frozen M2 Baseline**: M2 implemented logical and physical PRF use as **4 Read Ports, 2 Write Ports (4R2W)** for Port 0 and Port 1.
- **Milestone 3 Requirement**: M3 activates the reserved third execution and writeback channel, expanding the active backend demand to **6 Read Ports and 3 Write Ports (6R3W)**:
  - `R0`, `R1`: Port 0 operands (ALU0 / Branch);
  - `R2`, `R3`: Port 1 operands (ALU1 / Multiplier / Divider);
  - `R4`: Port 2 Base Address operand (`prs1`);
  - `R5`: Port 2 Store Data operand (`prs2`);
  - `W0`: Port 0 writeback;
  - `W1`: Port 1 writeback;
  - `W2`: Port 2 Load writeback into $P_{\text{new}}$.

### 1.3 In-Scope for Milestone 3
1. **Execution Port 2 & AGU**: 64-bit effective address calculation ($EA = \text{base} + \text{imm}$), natural alignment check, size/sign attributes, byte mask generation, and exception reporting.
2. **Memory Issue Queue (MemIQ)**: 12-entry out-of-order memory scheduler with wrap-safe circular ROB age selection, base-operand readiness gating, and decoupled store-data readiness.
3. **Load Queue (LQ)**: 16-entry tracking structure for speculative loads, address resolution, cache request state, forwarding metadata, and completion status.
4. **Store Queue (SQ)**: 16-entry tracking structure for speculative stores, address resolution, store-data buffering, committed retirement state, and in-order cache drain.
5. **Safe Older-Store Age Tracking**: Explicit `sq_older_mask[15:0]` snapshot per load with slot lifetime isolation, clearing on every legal deallocation path (drain, recovery squash, trap/flush), eliminating SQ wrap/reuse aliasing.
6. **Bifurcated Store Completion Boundary**: Strict separation between normal store completion (`store_success_complete = pa_valid && data_valid && !exception_pending`) and immediate exceptional store completion (`store_exception_complete = exception_pending`). Faulting stores complete immediately to ROB without waiting for store data or data producers, preventing deadlock.
7. **Speculative Store Containment**: Uncommitted stores execute AGU, translate, and participate in SQ forwarding, but cause **ZERO cache line mutations, MSHR allocations, WBB allocations, or external bus traffic**.
8. **Conservative Memory Ordering Baseline**: Loads issue to memory only after all older stores have resolved physical addresses; non-overlapping loads issue in parallel with older pending stores.
9. **Store-to-Load Forwarding**: Exact-match and fully-contained sub-word forwarding on aligned 8-byte words; conservative stalling on partial overlap or pending older store data.
10. **Structural Non-Aliasing for Long-Latency Memory & Translation**: Rigorous transaction identity proof based on persistent MSHR ownership with active per-waiter descriptors, and persistent Translation Request Table (TRT) ownership, immune to unbounded DRAM/PTW delay and finite epoch wrapping.
11. **Non-Blocking L1 Data Cache (L1D)**: Physically tagged, write-back, write-allocate cache with hit-under-miss and miss-under-miss concurrency, with explicit ready/valid request/response contracts.
12. **MSHR Subsystem with Selective Waiter Squash**: 4-entry MSHRs supporting secondary load misses and committed-store-drain misses to pending lines, with active per-waiter descriptors (`waiter_mask[15:0]`), clearing only squashed waiters on recovery while preserving older waiters.
13. **Dedicated Writeback Buffer (WBB)**: 2-entry buffer acting as the authoritative newest dirty line owner, with deadlock-free pre-reservation at MSHR miss allocation time.
14. **Port 2 PRF & ROB Writeback Integration**: Validated completion into M1 substrate (`comp_valid_i[2]`, `comp_ack_o[2]`) gating 64-bit PRF write port `W2`, with faulting loads strictly prohibited from writing PRF data or waking dependents.
15. **Variable-Latency Translation (DTLB) Boundary & Persistent Request Ownership**: Clean query/response interface supporting DTLB misses, `WAIT_TRANSLATION` state, pipeline release, persistent Translation Request Table (TRT) ownership until response/cancel termination, and safe squash cancellation.
16. **Strict Non-Speculative MMIO / Uncached Path**: Serialized execution at ROB head, non-interruptible once issued, with deferred interrupts and L1D bypass.
17. **Atomic Operations (AMO) and LR/SC Placement**: Non-speculative indivisible execution at ROB head; 56-bit physical reservation tracking with exact access size matching.
18. **Branch Recovery & Full Flush for Memory**: Instantaneous squash of younger speculative loads/stores; safe drain of committed store obligations and WBB dirty lines.
19. **Comprehensive M3 Verification Contract**: 45 mandatory directed test scenarios and formal simulation assertions.

### 1.4 Out-of-Scope for Milestone 3 (Deferred to Later Milestones)
- **Frontend & Instruction Fetch**: Decoupled instruction buffer, L1 Instruction Cache (L1I), branch predictors (BTB, Direction Predictor, RAS), and ITLB belong to Milestone 4 (M4).
- **Physical Coherence Protocol Engine**: M3 maintains a protocol-neutral bus/interconnect boundary (Acquire, Probe, Release, Grant). Full directory/snooping coherence controller belongs to multi-core platform integration.
- **Hardware Page Table Walker (PTW)**: Translation requests query DTLB. Full hardware PTW state machine is co-integrated with MMU platform deliverables.

---

## 2. Structural Parameter Classification Table

Every architectural parameter and design decision is strictly classified:

| Subsystem / Parameter | Milestone 3 Architectural Specification | Master Classification |
|---|---|---|
| **Port 2 Allocation** | Dedicated to Memory Execution (AGU / Load / Store) | **FROZEN SEMANTIC CONTRACT** |
| **PRF Logical Ports** | 6 Read Ports, 3 Write Ports (M2 was 4R2W; M3 adds R4, R5, W2) | **FROZEN SEMANTIC CONTRACT** |
| **MemIQ Capacity** | 12 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **MemIQ Allocation Width**| Up to 2 memory uops / cycle (gated by M1 `rename_ack_o`) | **FROZEN SEMANTIC CONTRACT** |
| **MemIQ Selection Policy** | Oldest-ready via wrap-safe ROB distance (`rob_dist`) | **FROZEN SEMANTIC CONTRACT** |
| **Store Data Decoupling** | Store AGU issues with `prs1` ready; store data (`prs2`) captured asynchronously | **FROZEN SEMANTIC CONTRACT** |
| **Load Queue (LQ) Depth** | 16 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **Store Queue (SQ) Depth**| 16 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **SQ Age Tracking** | `sq_older_mask[15:0]` snapshot per load; cleared on all deallocation paths (drain/squash/flush) | **FROZEN SEMANTIC CONTRACT** |
| **Store Completion Boundary**| Bifurcated: Normal (`pa_valid && data_valid && !exception_pending`) vs Exceptional (`exception_pending`, no data wait) | **FROZEN SEMANTIC CONTRACT** |
| **Speculative Store Policy**| Zero cache/bus mutation before commit; purely SQ-contained | **FROZEN SEMANTIC CONTRACT** |
| **Memory Ordering Policy**| Conservative baseline: Load issues when all older stores have valid PA | **FROZEN SEMANTIC CONTRACT** |
| **Store-to-Load Forwarding**| Exact-match & fully-contained forwarding; partial overlap stalls | **FROZEN SEMANTIC CONTRACT** |
| **Multi-Store Merge Forward**| Prohibited in baseline M3; load stalls until stores drain | **FROZEN SEMANTIC CONTRACT** |
| **Store Architectural Commit**| Stores commit in-order at ROB head; drain to L1D post-retirement | **FROZEN SEMANTIC CONTRACT** |
| **Memory Exception Timing** | Precise; attaches to ROB slot; alters state ONLY at retirement | **FROZEN SEMANTIC CONTRACT** |
| **Faulting Load PRF Write**| `prf_we[2] = comp_valid[2] && comp_ack[2] && !comp_exception[2] && (pnew != 0)` | **FROZEN SEMANTIC CONTRACT** |
| **MMIO / Uncached Execution**| Non-speculative at ROB head; drains older memory ops; non-interruptible | **FROZEN SEMANTIC CONTRACT** |
| **VIPT Synonym Safety** | Way Size $\le 4\text{ KiB}$ ($64\text{ sets} \times 64\text{ bytes} = 4\text{ KiB/way}$) | **FROZEN SEMANTIC CONTRACT** |
| **L1D Capacity / Config** | 16 KiB 4-Way (baseline) or 32 KiB 8-Way (candidate); both 64 sets | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **L1D Cache Policy** | Physically tagged, write-back, write-allocate, non-blocking | **FROZEN SEMANTIC CONTRACT** |
| **Cache Priority Contract** | Refill Install > Committed Store Drain > Speculative Load Issue | **FROZEN SEMANTIC CONTRACT** |
| **MSHR Depth** | 4 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **MSHR Multi-Waiter Model**| Explicit per-waiter active descriptors (`waiter_mask[15:0]`); selective squash | **FROZEN SEMANTIC CONTRACT** |
| **MSHR Line Merging** | Secondary load misses and committed-store-drain misses to pending line merge into active MSHR | **FROZEN SEMANTIC CONTRACT** |
| **Writeback Buffer (WBB)** | 2 entries; authoritative newest dirty copy owner | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **WBB Deadlock Prevention** | Dirty victim WBB slot pre-reserved at MSHR miss allocation time | **FROZEN SEMANTIC CONTRACT** |
| **WBB RAW Snooping** | Loads and MSHRs associatively snoop WBB to prevent stale reads | **FROZEN SEMANTIC CONTRACT** |
| **Long-Latency Identity** | Structural non-aliasing: persistent MSHR ownership until bus response | **FROZEN SEMANTIC CONTRACT** |
| **DTLB Query Interface** | Variable-latency request/response protocol with `WAIT_TRANSLATION` | **FROZEN SEMANTIC CONTRACT** |
| **Translation Request Ownership** | Persistent Translation Request Table (TRT) ownership until response/cancel termination; structurally immune to finite epoch wrapping | **FROZEN SEMANTIC CONTRACT** |
| **Translation Table Capacity**| 4 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **LR/SC Semantics** | LR registers 56-bit PA & size reservation; SC non-speculative at ROB head | **FROZEN SEMANTIC CONTRACT** |
| **AMO Semantics** | Single non-speculative micro-op; executes indivisibly at ROB head | **FROZEN SEMANTIC CONTRACT** |
| **FENCE Semantics** | Retires at ROB head after draining loads, stores, MSHRs, WBB, and MMIO | **FROZEN SEMANTIC CONTRACT** |
| **Coherence Interface** | Protocol-neutral caching agent boundary (Acquire/Probe/Release/Grant) | **FROZEN SEMANTIC CONTRACT** |
| **Frontend / ITLB / L1I** | Instruction fetch and predictor infrastructure | **DEFERRED TO LATER MILESTONE (M4)** |

---

## 3. Execution Port 2 & Address Generation Unit (AGU)

```
+===================================================================================================+
|                                  EXECUTION PORT 2 & AGU PIPELINE                                  |
+===================================================================================================+

    MemIQ Issue (Port 2)
            |
            v
    [ Register Fetch (RF) ] ===> R4: Base Address (prs1) from 64b PRF Array
            |
            v
    [ Address Generation (AGU) ]
    - 64-bit Adder: EA = Base[63:0] + Immediate[63:0]
    - Natural Alignment Check:
        Byte: OK | Half: EA[0]==0 | Word: EA[1:0]==0 | Double: EA[2:0]==0
    - Canonical Sv39 Virtual Address Check: EA[63:39] == {25{EA[38]}}
            |
            v
    +--------------------------------------------------------------+
    | Variable-Latency DTLB / PMP Query Protocol                   |
    | - If DTLB Hit: Single-cycle response with Physical Address   |
    | - If DTLB Miss: Release pipeline, enter WAIT_TRANSLATION    |
    +--------------------------------------------------------------+
            |
            v
    [ Translation Output ]
    - Physical Address: PA[55:0] = {PPN[43:0], EA[11:0]}
    - Attributes: Cacheable, Idempotent, Strongly-Ordered (MMIO)
    - Fault Flags: PageFault (Load/Store), AccessFault (PMP Denial)
            |
            +---------------------------------------+
            |                                       |
            v (If Load)                             v (If Store)
    Write PA to Allocated LQ Entry         Write PA to Allocated SQ Entry
    Evaluate Disambiguation / L1D          Wait for Store Data & ROB Retirement
                                           (or Immediate Exception Complete if Fault)
```

### 3.1 Address Generation & Natural Alignment
- **Effective Address (EA)**:
  $$\text{EA}[63:0] = \text{base}[63:0] + \text{imm}[63:0]$$
- **Alignment Checks & Precise Traps**:
  - `LB` / `LBU` / `SB`: Byte operations, naturally aligned.
  - `LH` / `LHU` / `SH`: Halfword operations, require $\text{EA}[0] == 1\text{'b}0$.
  - `LW` / `LWU` / `SW`: Word operations, require $\text{EA}[1:0] == 2\text{'b}00$.
  - `LD` / `SD`: Doubleword operations, require $\text{EA}[2:0] == 3\text{'b}000$.
  - If natural alignment fails, AGU asserts `align_fault = 1'b1`. The operation skips DTLB and cache lookups, recording a precise exception in its queue entry (Cause 4 Load Address Misaligned, Cause 6 Store/AMO Address Misaligned). For stores, this immediately asserts `exception_pending = 1'b1`, enabling instant exceptional completion to the ROB without waiting for store data.

### 3.2 Faulting Load PRF Write Suppression (Resolution of P1-6)
- **Correctness Rule**: A load that incurs an exception (misaligned, page fault, access fault) must **NEVER** write data into its destination physical register, and must **NEVER** wake dependent instructions or forward speculative fault data via bypass.
- **Authoritative Port 2 PRF Write-Enable Equation**:
  $$\text{prf\_we}[2] = \text{comp\_valid\_i}[2] \land \text{comp\_ack\_o}[2] \land \neg \text{comp\_exception\_i}[2] \land (\text{comp\_preg\_i}[2] \neq 7\text{'d}0)$$
- **Dependent Wakeup & Bypass Suppression**:
  When `comp_exception_i[2] == 1'b1`, Port 2 writeback asserts exception status to M1 ROB, but suppresses tag wakeup broadcasts to IntIQ/MemIQ and forces execution bypass validity to `0`.

---

## 4. Memory Issue Queue (MemIQ) Architecture

### 4.1 Entry Structure & Metadata
The MemIQ contains **12 entries** (provisional parameter). Each entry buffers:
1. `valid` (1 bit): Entry occupancy flag.
2. `uop_class` (3 bits): `UOP_LOAD`, `UOP_STORE`, `UOP_AMO`, `UOP_FENCE`.
3. `size` (2 bits): Byte (`2'b00`), Halfword (`2'b01`), Word (`2'b10`), Doubleword (`2'b11`).
4. `sign_ext` (1 bit): 1 for signed loads (`LB`, `LH`, `LW`), 0 for unsigned (`LBU`, `LHU`, `LWU`, `LD`).
5. `imm` (64 bits): Sign-extended 12-bit I-type displacement (loads) or S-type displacement (stores).
6. `prs1` (7 bits) & `prs1_ready` (1 bit): Base address physical register and readiness flag.
7. `prs2` (7 bits) & `prs2_ready` (1 bit): Store data physical register and readiness flag (stores only).
8. `pnew` (7 bits): Physical destination register ($p_0 \dots p_{79}$) for loads.
9. `rob_idx` (6 bits) & `rob_epoch` (4 bits): ROB lifetime generation identity matching M1 substrate.
10. `lq_idx` (4 bits): Assigned Load Queue slot (loads only).
11. `sq_idx` (4 bits): Assigned Store Queue slot (stores only).
12. `pc` (64 bits): Instruction PC (for precise trap reporting).

### 4.2 Allocation Handshake & Combined Dispatch Backpressure
- Dispatched memory micro-ops allocate into MemIQ in program order. Allocation requires:
  1. Free slot in MemIQ;
  2. Free slot in LQ (for loads) or SQ (for stores);
  3. M1 substrate assertion of `rename_ack_o[slot]`.
- The core dispatch controller combines IntIQ, MemIQ, LQ, and SQ free counts:
  $$\text{mem\_can\_dispatch}[s] = (\text{memiq\_free} > s) \land (\text{is\_load}[s] \implies \text{lq\_free} > s) \land (\text{is\_store}[s] \implies \text{sq\_free} > s)$$

### 4.3 Issue Eligibility & Store-Data Decoupling
- **Load Issue Eligibility**:
  $$\text{load\_can\_issue} = \text{valid} \land (\text{uop\_class} == \text{UOP\_LOAD}) \land \text{prs1\_ready}$$
- **Store AGU Issue Eligibility (Decoupled Store Data)**:
  $$\text{store\_agu\_can\_issue} = \text{valid} \land (\text{uop\_class} == \text{UOP\_STORE}) \land \text{prs1\_ready} \land \neg \text{sq\_entry.addr\_issued}$$
  Store address generation requires **ONLY `prs1` (base)**. Store data (`prs2`) is NOT required to issue to AGU! Once the store address is generated and written to the SQ, the physical address is visible to all younger loads.
- **Store Data Asynchronous Capture**:
  Store data register `prs2` is monitored by the Store Queue. When `prs2_ready` asserts (or when data is forwarded from `W0`/`W1`/`W2`), `prs2` reads PRF Read Port 5 (`R5`) and writes directly into `sq_entry.data`.
- **Selection Policy**:
  MemIQ selects the **oldest ready uop** using the frozen wrap-safe circular ROB distance:
  $$\text{rob\_dist}(\text{rob\_idx}, \text{rob\_head\_o}) = (\text{rob\_idx} - \text{head} + 48) \pmod{48}$$

---

## 5. Load Queue (LQ) & Store Queue (SQ) Architecture

### 5.1 Structurally Safe SQ Age Tracking (Resolution of P0-1)
To eliminate aliasing across circular Store Queue pointer wrapping, the raw `sq_tail_at_alloc` pointer is replaced by an **explicit older-store bitmask with slot lifetime isolation**:
- **Allocation Snapshot (`sq_older_mask[15:0]`)**:
  When a load allocates into the Load Queue at cycle $T$, it captures:
  $$\text{lq\_entry.sq\_older\_mask}[i] = \text{sq\_entry}[i].\text{valid} \quad (\forall i \in [0, 15])$$
  Bit $i = 1$ if and only if SQ physical slot $i$ contains an active store older than this load in program order at allocation time.
- **Comprehensive Dependency Clearing on SQ Slot Deallocation**:
  The older-store mask must clear when the corresponding older store ceases to exist as an active memory dependency for **ANY legal reason**. For every live Load Queue entry:
  $$\text{lq\_entry.sq\_older\_mask}[i] \Leftarrow 1\text{'b}0$$
  when SQ slot $i$ is deallocated because of:
  1. **Normal committed cache drain** (committed store finishes write to L1D and deallocates);
  2. **Branch-mispredict recovery squash** (uncommitted speculative store is squashed by older branch recovery);
  3. **Architectural / trap / full speculative flush** (speculative store is wiped by pipeline flush);
  4. **Any other speculative deallocation path**.
- **Crucial Invariant: Retirement vs Drain**:
  The older-store mask bit **DOES NOT** clear merely because an older store retires from the ROB into the committed SQ state (`sq_entry.committed <= 1'b1`).
  A retired-but-not-yet-drained committed store remains an active older memory dependency for younger loads until:
  - store-to-load forwarding fully satisfies the load; or
  - its memory effect becomes visible according to M3 ordering rules when it completes its cache drain and deallocates.
- **Slot Lifetime Isolation (Wrap Immunity)**:
  When a NEW younger store allocates into SQ slot $i$, it asserts `sq_entry[i].valid`. However, this allocation **MUST NOT and DOES NOT reassert bit $i$** in any already-allocated, older load's `sq_older_mask`!
- **Explicit SQ Wrap Example (Slots 15 $\rightarrow$ 0)**:
  1. Store $S_{14}$ occupies slot 14; Store $S_{15}$ occupies slot 15.
  2. Load $L_A$ allocates: captures $\text{sq\_older\_mask} = 16\text{'b1100\_0000\_0000\_0000}$ (bits 14 and 15 set).
  3. Store $S_{14}$ drains: deallocates slot 14 $\rightarrow$ broadcasts clear pulse $14 \rightarrow L_A.\text{sq\_older\_mask} = 16\text{'b1000\_0000\_0000\_0000}$.
  4. Store $S_{15}$ drains: deallocates slot 15 $\rightarrow$ broadcasts clear pulse $15 \rightarrow L_A.\text{sq\_older\_mask} = 16\text{'b0000\_0000\_0000\_0000}$.
  5. A new younger Store $S_{16}$ allocates into physical slot 0; Store $S_{17}$ allocates into physical slot 1; Store $S_{31}$ allocates into physical slot 15 (reusing slot 15).
  6. $L_A.\text{sq\_older\_mask}[15]$ remains **`0`**. $L_A$ correctly classifies $S_{31}$ as younger, never inspecting, waiting on, or forwarding from $S_{31}$.

### 5.2 Store Completion Boundary & Atomic Retirement Handshake (Resolution of P0-3 & P0-1 Closeout)
- **Bifurcated Store Completion Architecture**:
  Store address generation and store ROB completion are fundamentally decoupled events. To prevent deadlocks on faulting stores whose data may depend on unresolved multi-cycle operations (e.g. integer dividers), Milestone 3 replaces any single biconditional completion rule with **TWO distinct completion paths**:

  1. **Successful Store Completion**:
     A non-faulting store may assert Port 2 completion only when:
     ```verilog
     store_success_complete =
         pa_valid
      && data_valid
      && !exception_pending;
     ```
     When `store_success_complete` asserts:
     - `comp_valid_i[2] = 1'b1`
     - `comp_exception_i[2] = 1'b0`
     - ROB records normal completion for the store uop.
     - The store uop waits at the ROB until reaching the head of the ROB.
     - Retirement at ROB head atomically transfers responsibility into committed SQ state (`sq_entry.committed <= 1'b1`).

  2. **Exceptional Store Completion**:
     A faulting store must be able to complete to the ROB **immediately once the fault is known**:
     ```verilog
     store_exception_complete = exception_pending;
     ```
     When `store_exception_complete` asserts:
     - `comp_valid_i[2] = 1'b1`
     - `comp_exception_i[2] = 1'b1`
     - `comp_cause_i[2] = sq_entry.exc_cause`
     - No PRF write (`prf_we[2] = 1'b0`).
     - No memory side effect.
     - No committed SQ obligation created.

  **CRITICAL DEADLOCK ELIMINATION INVARIANT**:
  Exceptional store completion **MUST NOT wait for**:
  - `data_valid`;
  - normal PA-valid success condition;
  - store-data producer completion.

  *Fault Examples*:
  - Misaligned store detected at AGU (`align_fault == 1'b1`, Cause 6);
  - DTLB page fault (`dtlb_page_fault == 1'b1`, Cause 15);
  - PMP access fault (`pmp_fault == 1'b1`, Cause 7).

  If an address fault is already known while store data depends on an active 34-cycle division or other pending producer, the store exception is reported to the ROB **immediately in cycle 1**. At the ROB head, precise exception handling proceeds normally.
  **A faulting store NEVER transitions into committed-store drain state** (`committed` remains `1'b0`, no cache write occurs, and the SQ entry is deallocated/squashed on trap flush).

- **Atomic Retirement Handshake**:
  1. When a successfully completed store reaches the head of the ROB, the ROB verifies no older traps exist.
  2. The ROB asserts `retire_valid_o` for the store.
  3. In the exact same cycle, the Store Queue asserts:
     $$\text{sq\_entry}[\text{sq\_head}].\text{committed} \Leftarrow 1\text{'b}1$$
  4. Responsibility transfers **atomically** from the speculative ROB domain to the committed Store Queue domain.
  5. The ROB deallocates the entry. The committed store persists in the SQ as an irrevocable architectural memory obligation.
  6. **Trap / Flush Immunity**: A later trap, interrupt, or full architectural flush **CANNOT discard a committed store**. Committed stores drain to L1D unconditionally.

### 5.3 Speculative Store Containment (Resolution of P1-1)
- **Baseline Non-Mutating Contract**:
  Uncommitted stores ($\text{committed} == 1\text{'b}0$) may execute AGU, query DTLB, resolve PA, capture store data, and participate in SQ forwarding.
- **Strict Prohibition on Speculative Side Effects**:
  Uncommitted stores are **STRICTLY FORBIDDEN** from:
  1. Mutating L1D cache tags or data arrays;
  2. Allocating an MSHR for a write-allocate store miss;
  3. Allocating a Writeback Buffer (WBB) entry or evicting dirty lines;
  4. Launching external bus or interconnect transactions.
  All store cache writes, miss allocations, and line refills begin **strictly post-retirement** when the store is at the SQ head with `committed == 1'b1`.

### 5.4 Load Queue & Store Queue Branch Recovery and Flush Semantics
- **Branch Recovery Protocol (`recover_valid_i`)**:
  When a branch misprediction resolves on Port 0 with recovery ROB index `br_rob_idx`:
  1. **Selective LQ Squash**: All Load Queue entries younger than the branch in program order:
     $$\text{is\_squashed} = \text{rob\_dist}(\text{lq\_entry.rob\_idx}, \text{rob\_head\_o}) > \text{rob\_dist}(\text{br\_rob\_idx}, \text{rob\_head\_o})$$
     are immediately invalidated (`lq_entry.valid <= 1'b0`).
  2. **Selective SQ Squash**: All uncommitted Store Queue entries younger than the branch:
     $$\text{is\_squashed} = (\text{sq\_entry.committed} == 1\text{'b}0) \land (\text{rob\_dist}(\text{sq\_entry.rob\_idx}, \text{rob\_head\_o}) > \text{rob\_dist}(\text{br\_rob\_idx}, \text{rob\_head\_o}))$$
     are immediately invalidated (`sq_entry.valid <= 1'b0`). The SQ speculative allocation tail rolls back to match the checkpointed SQ tail state.
  3. **Older-Mask Deallocation Broadcasting on Squash**:
     Each SQ slot $i$ deallocated by branch recovery immediately asserts a deallocation pulse `sq_squash_dealloc[i]`. For every surviving live Load Queue entry, the corresponding older dependency bit is cleared:
     $$\text{lq\_entry.sq\_older\_mask}[i] \Leftarrow 1\text{'b}0$$
     This guarantees surviving loads never deadlock waiting on squashed stores.
  4. **Committed Store Protection**: Stores already marked `committed == 1'b1` are older than any speculative branch checkpoint. They are **never squashed** and continue draining to L1D.
- **Architectural Trap / Full Speculative Flush Protocol (`flush_active`)**:
  When an architectural exception, trap, interrupt, or full fence clears the pipeline:
  1. All speculative LQ entries are invalidated (`lq_entry.valid <= 1'b0`).
  2. All uncommitted speculative SQ entries are invalidated (`sq_entry.valid <= 1'b0`), and SQ allocation pointers reset to match the committed head.
  3. All committed stores (`committed == 1'b1`) persist unconditionally in the SQ, continuing their in-order drain to L1D. They are immune to pipeline flushes.
  4. All speculative MemIQ entries are cleared.
  5. Outstanding translation requests in the Translation Request Table have their waiter valid bits cleared (`waiter_valid <= 1'b0`), ensuring late PTW responses are dropped without updating any state.

---

## 6. Memory Ordering & Disambiguation Rules

### 6.1 Conservative Load Issue Contract
- **Normative Rule**:
  A load micro-op $L$ in the Load Queue is eligible to access the L1D cache or evaluate forwarding if and only if **all older stores recorded in $L.\text{sq\_older\_mask}$ have resolved physical addresses (`pa_valid == 1`)**:
  $$\text{load\_can\_disambiguate} = \forall i \in [0, 15] : (L.\text{sq\_older\_mask}[i] \implies \text{sq\_entry}[i].\text{pa\_valid})$$
- **Data-Independent Concurrency**:
  Older store **data (`data_valid`) is NOT required** for non-overlapping loads! If all older stores have `pa_valid == 1` and none overlap with load $L$, load $L$ issues to L1D immediately.

---

## 7. Formal Store-to-Load Forwarding Mechanics (Resolution of P1-7)

Let $A_L = \text{PA}(L)$ and $A_S = \text{PA}(S)$ be physical addresses.
Let $M_L[7:0]$ and $M_S[7:0]$ be active byte lane masks relative to the aligned 8-byte word ($PA[55:3]$).

```
+===================================================================================================+
|                                  FORWARDING EVALUATION ON 8-BYTE WORDS                            |
+===================================================================================================+

 Aligned 8-Byte Word:  [ Byte 7 | Byte 6 | Byte 5 | Byte 4 | Byte 3 | Byte 2 | Byte 1 | Byte 0 ]
 Byte Lane Mask Bit:        7        6        5        4        3        2        1        0

 Condition 1: Same 8-Byte Aligned Word:   A_L[55:3] == A_S[55:3]
 Condition 2: Genuine Byte Lane Overlap: (M_L & M_S) != 8'b0000_0000
```

### 7.1 Forwarding Evaluation Algorithm
An older store $S$ (with $L.\text{sq\_older\_mask}[S] == 1$) genuinely overlaps load $L$ if and only if:
$$\text{Overlap}(L, S) = (A_L[55:3] == A_S[55:3]) \land ((M_L \land M_S) \neq 8\text{'b0000\_0000})$$
Stores with disjoint masks ($M_L \land M_S == 8\text{'b0}$) or different word addresses do **not** overlap and do **not** shadow older stores!

**Forwarding Steps**:
1. Filter older stores to the set of genuinely overlapping stores $\mathcal{S}_{\text{overlap}} = \{S \in \text{SQ} \mid L.\text{sq\_older\_mask}[S] \land \text{Overlap}(L, S)\}$.
2. If $\mathcal{S}_{\text{overlap}} == \emptyset$: **No dependency**. Load $L$ accesses L1D directly.
3. Identify the **youngest older overlapping store** $S_{\text{youngest}} \in \mathcal{S}_{\text{overlap}}$ (highest age in program order).
4. **Coverage Evaluation**:
   - **Full Single-Store Coverage**: If $(M_L \land M_{S_{\text{youngest}}}) == M_L$:
     - If $S_{\text{youngest}}.\text{data\_valid} == 1$: **Forward directly**! Extract matching byte lanes, format sign/zero extension, and complete load in 1 cycle.
     - If $S_{\text{youngest}}.\text{data\_valid} == 0$: **Stall Load** in LQ awaiting store data capture.
   - **Partial Overlap**: If $(M_L \land M_{S_{\text{youngest}}}) \neq M_L$:
     - **Forwarding is strictly prohibited**. The load stalls in the LQ until $S_{\text{youngest}}$ commits and drains to L1D.
5. **Multi-Store Merge Prohibition**:
   Even if multiple older stores jointly supply all required bytes, **multi-store merging is prohibited in baseline M3**. The load stalls until the older stores drain to L1D.

### 7.2 Explicit Byte Forwarding Examples
- **Example 1 (Contained 32-bit Load from 64-bit Store)**:
  - Store $S$: $PA = \text{0x1000}$, Size = 8B, $M_S = 8\text{'b1111\_1111}$, Data = `0x0123_4567_89AB_CDEF`.
  - Load $L$: $PA = \text{0x1000}$, Size = 4B (LW), $M_L = 8\text{'b0000\_1111}$.
  - Overlap check: $M_L \land M_S = 8\text{'b0000\_1111} == M_L$ (Full Coverage).
  - *Result*: Forwards bytes $3 \dots 0$ (`0x89AB_CDEF`), sign-extended to 64 bits.
- **Example 2 (Partial Overlap Stall)**:
  - Store $S$: $PA = \text{0x1000}$, Size = 2B (SH), $M_S = 8\text{'b0000\_0011}$.
  - Load $L$: $PA = \text{0x1000}$, Size = 4B (LW), $M_L = 8\text{'b0000\_1111}$.
  - Overlap check: $M_L \land M_S = 8\text{'b0000\_0011} \neq M_L$ (Partial Overlap).
  - *Result*: Load stalls in LQ until Store $S$ commits and drains to L1D.
- **Example 3 (Disjoint Mask Non-Shadowing)**:
  - Older Store $S_1$: $PA = \text{0x1000}$, Size = 4B, $M_{S1} = 8\text{'b0000\_1111}$ (Bytes 0–3).
  - Younger Store $S_2$: $PA = \text{0x1004}$, Size = 4B, $M_{S2} = 8\text{'b1111\_0000}$ (Bytes 4–7).
  - Load $L$: $PA = \text{0x1000}$, Size = 4B (LW), $M_L = 8\text{'b0000\_1111}$ (Bytes 0–3).
  - Overlap check: $S_2$ has $M_L \land M_{S2} == 8\text{'b0000\_0000}$ (Disjoint; does NOT overlap).
  - *Result*: $S_2$ does not shadow $S_1$. Overlap search selects $S_1$, fully covers load $\rightarrow$ forwards from $S_1$!

---

## 8. Non-Blocking L1 Data Cache (L1D) Architecture

```
+===================================================================================================+
|                                     L1D CACHE ORGANIZATION                                        |
+===================================================================================================+

   Line Size: Exactly 64 Bytes (512 bits)
   Way Size:  Exactly 4 KiB (64 Sets x 64 Bytes/Line = 4096 Bytes)  <=== VIPT Synonym Safe!

   Baseline:  16 KiB, 4-Way Set Associative (64 Sets, 4 Ways) [Provisional Capacity]
   Candidate: 32 KiB, 8-Way Set Associative (64 Sets, 8 Ways) [Provisional Capacity]

   Address Breakdown (64-bit Virtual / 56-bit Physical):
   +---------------------------------------+-------------+-------------+
   | Physical Tag: PA[55:12] (44 bits)     | Set: [11:6] | Line: [5:0] |
   +---------------------------------------+-------------+-------------+
   | Virtual Index: VA[11:6] (6 bits)      <=== Bit-for-bit identical to PA[11:6]!
```

### 8.1 Semantic Cache Request / Response Contract (Resolution of P2-4)
The L1D controller exposes an explicit ready/valid semantic interface:
- **Cache Request Channel**:
  - `l1d_req_valid_o`: Request valid.
  - `l1d_req_ready_i`: Cache pipeline accepts request.
  - `l1d_req_op_o` (2 bits): `REQ_LOAD`, `REQ_STORE_COMMIT`, `REQ_AMO`, `REQ_REFILL_INSTALL`.
  - `l1d_req_pa_o` (56 bits): Physical address.
  - `l1d_req_mask_o` (8 bits): Active byte lane mask.
  - `l1d_req_data_o` (64 bits): Store/AMO write payload.
  - `l1d_req_tag_o` (6 bits): Requester identifier (`lq_idx` or `sq_idx`).
- **Cache Response Channel**:
  - `l1d_rsp_valid_i`: Response valid.
  - `l1d_rsp_hit_i`: 1 for hit, 0 for miss.
  - `l1d_rsp_data_i` (64 bits): Read data extracted from line.
  - `l1d_rsp_tag_i` (6 bits): Matches request tag.
  - `l1d_rsp_mshr_id_i` (2 bits): Assigned MSHR slot on miss.

### 8.2 Internal Cache Arbitration Priority (Resolution of P1-8)
To prevent structural resource deadlocks and guarantee forward progress:
$$\text{Priority 1 (Highest)}: \text{Refill Install} > \text{Priority 2}: \text{Committed Store Drain} > \text{Priority 3 (Lowest)}: \text{Speculative Load Issue}$$
- *Refill Install* has highest priority to clear MSHRs and free external bus resources immediately.
- *Committed Store Drain* has second priority to relieve SQ capacity pressure and unblock the ROB head.
- *Speculative Load Issue* takes remaining cycles.

### 8.3 VIPT Synonym Safety (Resolution of P3-2)
Both candidate cache configurations strictly adhere to the 4 KiB way size bound:
- **16 KiB 4-Way**: $16\text{ KiB} / 4\text{ ways} = 4\text{ KiB/way}$ (64 sets $\times$ 64 B).
- **32 KiB 8-Way**: $32\text{ KiB} / 8\text{ ways} = 4\text{ KiB/way}$ (64 sets $\times$ 64 B).
Because both configurations have exactly 64 sets, the index is bits $[11:6]$, falling completely within the 4 KiB page offset. **VIPT synonym safety is mathematically guaranteed**.

---

## 9. MSHR Subsystem with Selective Waiter Squash (Resolutions of P0-4 & P2-1)

```
+===================================================================================================+
|                                    MSHR ENTRY STRUCTURE (4 ENTRIES)                               |
+===================================================================================================+

  Field Name          Width     Description
  -----------------   -------   ---------------------------------------------------------------------
  valid               1 bit     MSHR slot occupancy flag.
  line_addr           50 bits   64-byte aligned physical line address (PA[55:6]).
  state               3 bits    IDLE, WAIT_BUS, REQ_SENT, REFILL_DATA, DRAIN_WAITERS.
  bus_tag             2 bits    External interconnect transaction ID (equals MSHR index).
  wbb_reserved_slot   1 bit     Index of pre-allocated WBB slot for dirty victim eviction.
  waiter_mask         16 bits   Bitmask of active Load Queue entries waiting for this line.
  store_drain_mask    16 bits   Bitmask of committed SQ entries waiting to write-allocate.

  Per-Waiter Active Descriptors (Array of 16 Descriptors, indexed by LQ slot):
  - waiter_valid      1 bit     Individual waiter validity (cleared independently on squash).
  - lq_idx            4 bits    Target Load Queue index.
  - line_offset       6 bits    Byte offset within the 64-byte line (PA[5:0]).
  - size              2 bits    Access size (Byte, Half, Word, Double).
  - sign_ext          1 bit     Signed vs unsigned extension.
  - pnew              7 bits    Physical destination register.
  - rob_idx           6 bits    Associated ROB slot index.
  - rob_epoch         4 bits    ROB lifetime epoch.
```

- **Per-Waiter Active Descriptor Lifecycle Rules**:
  1. **Initialization on Join**: A descriptor is explicitly initialized when a load miss allocates or merges into an active MSHR (asserting `waiter_mask[w] = 1'b1` and `waiter_valid = 1'b1`).
  2. **Active Stability**: The descriptor contents remain stable while that specific waiter bit is live (`waiter_mask[w] == 1'b1`).
  3. **Reuse after Clear**: The physical descriptor slot in the MSHR may be reused only after that waiter bit is cleared (via normal refill service completion, branch recovery squash, or architectural flush).
  4. **Explicit Join on Slot Reuse**: A new load allocating into the same physical LQ slot represents a new explicit join event; it never implicitly inherits or activates an existing in-flight MSHR descriptor.

### 9.1 Selective Waiter Squash on Branch Recovery
When a branch recovery occurs with recovery ROB index `br_rob_idx`:
1. For each active MSHR $m$ and for each waiter $w$ where $m.\text{waiter\_mask}[w] == 1$:
   - Check if waiter $w$ is younger than the branch:
     $$\text{is\_squashed} = \text{rob\_dist}(m.\text{waiter}[w].\text{rob\_idx}, \text{rob\_head\_o}) > \text{rob\_dist}(\text{br\_rob\_idx}, \text{rob\_head\_o})$$
   - If squashed:
     $$m.\text{waiter\_mask}[w] \Leftarrow 1\text{'b}0, \quad m.\text{waiter}[w].\text{waiter\_valid} \Leftarrow 1\text{'b}0$$
2. **Surviving Waiter Integrity**:
   Older waiter entries ($\text{is\_squashed} == 1\text{'b}0$) **remain completely active**.
3. **Refill Service**:
   When refill data arrives:
   - For every surviving waiter ($m.\text{waiter\_mask}[w] == 1$), data is extracted from the 64-byte line at `line_offset`, formatted, and presented to Port 2 writeback.
   - For squashed waiters, writeback signaling is **suppressed**.
   - If ALL waiters were squashed ($m.\text{waiter\_mask} == 16\text{'b0}$), the incoming refill line still installs into the L1D cache, but **ZERO writeback or ROB completion is generated**.
   - The MSHR does NOT abort or squash wholesale; line caching proceeds safely.

### 9.2 Secondary Miss Merging Contract
- **Line Merging Eligibility**:
  **Secondary load misses and committed-store-drain misses** to a 64-byte cache line currently being refilled merge directly into the active MSHR tracking that line:
  - An issuing load that misses in L1D but matches an active MSHR `line_addr` registers into `waiter_mask` and initializes its active descriptor without allocating a new MSHR slot.
  - A committed store at the SQ head draining to an active MSHR `line_addr` registers into `store_drain_mask` without allocating a new MSHR slot.
- **Speculative Store Prohibition**:
  Uncommitted speculative stores are **strictly prohibited** from allocating or merging into MSHRs under any circumstances. All store miss allocations and line merges occur **strictly post-retirement** when `committed == 1'b1`.

---

## 10. Dedicated Writeback Buffer (WBB) & Deadlock Elimination (Resolutions of P1-3 & P1-4)

### 10.1 WBB Deadlock Elimination via Miss Pre-Reservation
- **The Deadlock Hazard**: If a line refill arrives from external memory and finds a dirty victim in L1D, but the WBB is full, the refill cannot install and the external response hangs, deadlocking the bus.
- **Pre-Allocation Contract**:
  At the time an MSHR miss is allocated:
  1. The cache controller determines the set and selects the replacement victim way.
  2. If the victim way is **DIRTY**:
     - A free WBB slot **MUST BE RESERVED AND ALLOCATED IMMEDIATELY** before launching the external miss request to the bus!
     - If no WBB slot is free (`wbb_free_count == 0`), MSHR miss allocation stalls at the core side.
  3. If the victim way is **CLEAN**:
     - No WBB slot is needed.
- **Guarantee**: When the refill returns, dirty victim buffer space is **100% guaranteed**. Refill installation never stalls waiting for WBB capacity.

### 10.2 WBB as Authoritative Dirty Line Owner
- **Single Authoritative Copy Invariant**:
  At any instant, there is **exactly one authoritative newest copy** of any physical cache line among L1D and WBB.
- **Load Access to WBB-Resident Line**:
  If an issuing load hits an address residing in the WBB:
  - Data is read directly from the WBB payload buffer (1-cycle hit latency via associative snoop).
- **Committed Store to WBB-Resident Line**:
  If a committed store drains to a line currently held in the WBB:
  - Store byte writes are merged directly into the WBB data payload (`wbb_entry.dirty_data`), updating the dirty mask, OR the store stalls until the WBB entry drains to L2/DRAM.
  - The store **DOES NOT** launch a redundant, stale refill from external memory for that line!
- **Refill Reconciliation**:
  Because miss allocation reserves replacement ways and checks WBB residency, an MSHR cannot fetch a stale copy of an active WBB line.

---

## 11. Long-Latency Transaction Identity (Structural Non-Aliasing Proof) (Resolution of P0-2)

The claim of correctness under arbitrarily unbounded memory latency is founded on **STRUCTURAL NON-ALIASING**, not finite generation counters:

```
+===================================================================================================+
|                                  STRUCTURAL NON-ALIASING PROOF                                    |
+===================================================================================================+

 Principle 1: Persistent MSHR Transaction Ownership
 --------------------------------------------------
 Each external memory transaction is owned by an active MSHR slot. The MSHR bus transaction
 tag equals the MSHR index (0..3). An MSHR slot CANNOT be freed or reallocated until the
 external bus transaction completes and terminates. Bus transaction tags NEVER alias.

 Principle 2: Bus Responses Route to MSHRs, Never Directly to LQ Slots
 ---------------------------------------------------------------------
 Returning external memory responses address the MSHR, not a Load Queue index. The bus has
 zero knowledge of LQ slots or ROB lifetimes.

 Principle 3: Explicit per-Waiter Structural Membership
 ------------------------------------------------------
 Waiter membership within an MSHR is maintained as explicit, independent active descriptors.
 A squashed load clears its waiter bit (waiter_mask[w] = 0). While live, descriptor fields
 remain stable; upon squash or completion, the descriptor is deactivated.

 Principle 4: Physical Slot Reuse Does Not Recreate Waiter Ownership
 -------------------------------------------------------------------
 When an LQ slot is deallocated or squashed and subsequently reallocated to a new load, the
 new load DOES NOT inherit any waiter relationship to an in-flight MSHR.
 A new load joins an MSHR IF AND ONLY IF its own physical address explicitly matches the
 MSHR line address during its own active cache lookup.

 Principle 5: Suppression of Dead Refills
 ---------------------------------------
 If all waiters of an MSHR are squashed before refill return, the arriving line installs into
 L1D, but creates ZERO uop, ROB, or PRF writeback completion.

 Principle 6: Persistent Translation-Request Ownership (Structural Translation Non-Aliasing)
 -----------------------------------------------------------------------------------------
 Parallel to MSHRs, outstanding asynchronous translation requests (DTLB miss / PTW) are owned
 by persistent entries in a dedicated Translation Request Table (TRT). PTW tags equal the TRT
 request ID (`tr_id`). The TRT entry remains allocated until translation response or cancel
 termination. Reused LQ/SQ slots cannot inherit an in-flight translation response.
```

- **Theorem**: Stale completion aliasing is **structurally impossible** regardless of external memory or translation latency. Finite generation counters remain active strictly as simulation debug and defense-in-depth checks.

---

## 12. Variable-Latency Translation (DTLB) Interface Boundary & Persistent Request Ownership (Resolution of P1-2 & Closeout)

To eliminate aliasing across long-latency Page Table Walks (PTWs) where finite epoch counters can wrap, Milestone 3 replaces direct queue-slot tag matching with **structural request-slot ownership via a Translation Request Table (TRT)**:

```
+===================================================================================================+
|                        PERSISTENT TRANSLATION REQUEST OWNERSHIP PROTOCOL                          |
+===================================================================================================+

 LSU / AGU Stage                                                     DTLB / PTW Subsystem
 -----------------                                                   --------------------
 dtlb_req_valid_o   ==============================================>  Sample translation query
 dtlb_req_va_o      [Virtual Address EA[63:0]]
 dtlb_req_type_o    [Load / Store / AMO]
                                                                     Evaluate Base / Superpage TLB
                                                                     - Hit:  dtlb_rsp_hit_i = 1
                                                                     - Miss: dtlb_rsp_hit_i = 0

 [ If DTLB Hit (Single-Cycle) ]: <=================================  dtlb_rsp_valid_i = 1
 - Immediate PA write to LQ/SQ entry                                 dtlb_rsp_hit_i   = 1
 - Proceed to disambiguation / L1D lookup                            dtlb_rsp_pa_i    = Physical Addr

 [ If DTLB Miss (Multi-Cycle / PTW) ]: <===========================  dtlb_rsp_valid_i = 1
 - Allocate entry in Translation Request Table (TRT)                 dtlb_rsp_hit_i   = 0 (Miss)
 - Record TRT entry: {is_store, q_idx, vpn, access_type, waiter_valid=1}
 - Tag request to PTW with persistent request ID: tr_id[1:0]
 - Mark LQ/SQ entry: WAIT_TRANSLATION
 - Release Port 2 AGU pipeline (younger uops continue!)

 [ Outstanding PTW in Flight ]:
 - PTW traverses multi-level page table (arbitrary latency).
 - If requesting uop is squashed (branch mispredict / trap flush):
     TRT marks entry: waiter_valid <= 1'b0
     TRT entry REMAINS ALLOCATED until PTW response arrives!
     tr_id IS NOT REUSED until transaction terminates.

 [ Asynchronous Translation Response ]: <==========================  ptw_rsp_valid_i = 1
 - Matches ptw_rsp_tr_id_i against persistent TRT entries             ptw_rsp_tr_id_i = tr_id
 - If TRT[tr_id].waiter_valid == 1:                                  ptw_rsp_pa_i    = PA
     Verify VPN matches defense-in-depth                             ptw_rsp_fault_i = Fault Flags
     Write PA/fault to LQ/SQ entry at TRT[tr_id].q_idx
     Advance uop state to PA_VALID / DISAMBIGUATE
     Deallocate TRT[tr_id] slot (tr_id now available for reuse)
 - If TRT[tr_id].waiter_valid == 0 (Waiter Squashed):
     Silently drop translation response! Zero LQ/SQ side effects!
     Deallocate TRT[tr_id] slot (tr_id now available for reuse)
```

### 12.1 Translation Request Table (TRT) Structure & Lifecycle
The TRT contains **4 persistent request entries** (provisional parameter):
1. `valid` (1 bit): Request table entry occupancy flag.
2. `is_store` (1 bit): 1 for Store/AMO queue slot; 0 for Load queue slot.
3. `q_idx` (4 bits): Physical index of target LQ or SQ slot.
4. `vpn` (27 bits): Virtual Page Number ($EA[38:12]$) used for defense-in-depth sanity checking.
5. `access_type` (2 bits): Read, Write, Execute / AMO attribute check.
6. `waiter_valid` (1 bit): Indicates whether the original memory micro-op is still alive.

### 12.2 Structural Non-Aliasing Translation Invariants
- **Persistent Request Ownership**:
  Each in-flight translation request object remains allocated from the instant a PTW is launched until the PTW response returns or explicit cancellation handshake terminates. The request ID `tr_id` is **never reused** until termination.
- **Queue-Slot Reuse Isolation**:
  When an LQ or SQ entry in `WAIT_TRANSLATION` is squashed by branch recovery or full flush:
  1. The core clears `TRT[tr_id].waiter_valid <= 1'b0`.
  2. The physical queue slot (`q_idx`) may subsequently be deallocated, reused, and reallocated to a completely unrelated younger instruction.
  3. Because returning PTW responses route to the persistent `tr_id` rather than directly to queue slots, the returning response addresses the TRT.
  4. Seeing `waiter_valid == 1'b0`, the LSU **immediately drops the response**, never touching, mutating, or advancing the state of the reused physical queue slot.
- **Architectural Invariant**:
  A PTW/DTLB response may update an LQ/SQ entry **only if that exact live translation waiter still owns the response**. A reused queue slot can **never accidentally inherit an old PTW result**, regardless of how many times queue slots or finite epochs wrap.

---

## 13. Strict Non-Speculative MMIO / Uncached Memory Execution (Resolution of P1-5)

```
+===================================================================================================+
|                                    NON-SPECULATIVE MMIO PROTOCOL                                  |
+===================================================================================================+

 1. Qualification:
    - Translation response indicates uncacheable space (dtlb_rsp_cacheable == 1'b0).
    - Queue entry marks is_mmio = 1'b1.

 2. Pre-Issue Serialization:
    - MMIO instruction is HELD IN QUEUE until it reaches the ROB HEAD (head_o == rob_idx).
    - Core enforces complete quiescence: all older stores drained, all older MSHRs completed.
    - Younger memory operations are blocked from issuing.

 3. Non-Interruptible Bus Handshake:
    - Once the MMIO bus request handshake occurs (mmio_req_valid && mmio_req_ready):
      * The MMIO instruction becomes NON-INTERRUPTIBLE and NON-SQUASHABLE until bus termination.
      * Asynchronous interrupts are deferred until bus transaction completion.
      * Branch recovery cannot affect it (it is ROB head and serialized).
      * Request is NEVER replayed, retried, or duplicated.

 4. Completion & Retirement:
    - Bus returns response: data captured into PRF (loads) or acknowledged (stores).
    - If bus error: raises precise Access Fault (Cause 5 / 7) at ROB head.
    - Instruction retires; deferred interrupts may then be serviced.
```

---

## 14. Atomic Operations (AMO) and LR/SC (Resolution of P2-2)

- **`LR.W` / `LR.D`**:
  - Issues when older store addresses resolve.
  - Registers an architectural reservation tracking both:
    1. Physical Address: `reservation_pa[55:0]`;
    2. Access Size: `reservation_size[1:0]` (Word vs Doubleword).
- **`SC.W` / `SC.D` (Exact Size Matching)**:
  - Executes non-speculatively at the head of the ROB.
  - Validates:
    $$\text{sc\_success} = \text{reservation\_valid} \land (\text{reservation\_pa} == \text{store\_pa}) \land (\text{reservation\_size} == \text{sc\_size})$$
  - *Size Mismatch Failure*: An `LR.W` reservation does **NOT** permit an incompatible `SC.D`! `SC.D` fails, suppresses memory write, returns `1` to PRF, and clears reservation.
- **AMOs**: Single micro-op; executed indivisibly at ROB head when the Store Queue is completely empty.

---

## 15. Memory Fences (FENCE and FENCE.I) (Resolution of P2-3)

- **`FENCE` Complete Visibility Point**:
  A `FENCE` micro-op commits at the ROB head if and only if:
  1. All older loads have completed and written back;
  2. All older stores have committed and completely drained from the Store Queue into L1D;
  3. All active MSHRs have completed line installation;
  4. All Writeback Buffer (WBB) dirty lines have drained to external memory/interconnect;
  5. Any prior MMIO transactions are fully completed.
- **`FENCE.I`**: Drains memory to quiescence, invalidates L1I cache tags, and signals frontend fetch redirect.

---

## 16. Formal Deadlock-Freedom Analysis

```
+===================================================================================================+
|                                 FORMAL DEADLOCK-FREEDOM ANALYSIS                                  |
+===================================================================================================+

 Structural Resource Dependency Graph:
 ROB Head ---> SQ Committed ---> L1D Cache Port ---> MSHR (if miss) ---> WBB (if dirty) ---> Bus
```

### Scenario A: All MSHRs Full + Dirty Victim Required + WBB Full (P1-4)
- *Precondition*: 4 MSHRs are awaiting refills. Refill 0 arrives, requiring dirty line eviction.
- *Resolution*: By Section 10.1, the WBB slot for Refill 0 was **pre-reserved at miss allocation time**. WBB saturation stalls miss allocation, never refill return. WBB drains dirty lines to the bus with highest priority. Acyclic forward progress is guaranteed.

### Scenario B: ROB Head Store Waiting for Cache Access (P1-8)
- *Precondition*: Core is blocked at ROB head on a committed store. L1D is busy with load traffic.
- *Resolution*: Committed Store Drain has higher arbitration priority than Speculative Load Issue ($\text{Priority 2} > \text{Priority 3}$). The store drains to L1D in the next cycle, unblocking the ROB head.

### Scenario C: Speculative Load Waits on Unresolved Older Store Address
- *Precondition*: Load $L$ is stalled because older store $S$ has not resolved address (`pa_valid == 0`).
- *Resolution*: Store $S$ progresses through integer ALU and AGU independently. Store address calculation never depends on younger loads. Store $S$ resolves PA, asserting `pa_valid = 1`, and unblocks load $L$.

### Scenario D: Divider-Produced Store Data
- *Precondition*: Store data depends on an active 34-cycle division.
- *Resolution*: Store address resolves early in AGU, allowing younger non-overlapping loads to proceed. Store marks `data_valid = 0`. If a younger overlapping load requires store data, it stalls in LQ. When the divider completes, store data latches, `store_success_complete` asserts, the store completes in the ROB, and the load forwards data. Acyclic progress is maintained.
- *Exceptional Case (Address/Translation Fault with Data Pending)*: If the store incurs an AGU misalignment exception, DTLB page fault, or PMP access fault while store data is pending from the divider, the store asserts `store_exception_complete = 1'b1` immediately. It does NOT wait for `data_valid` or the divider to finish. The store completes to the ROB with `comp_exception_i[2] = 1'b1`, suppressing committed SQ obligation and memory side effects. When reaching the ROB head, the exception is taken without deadlock.

### Scenario E: Non-Speculative MMIO at ROB Head with In-Flight Memory Traffic
- *Precondition*: MMIO uop reaches ROB head while background MSHRs are active.
- *Resolution*: The MMIO state machine waits for active MSHRs to complete and SQ to empty. Because all older operations are finite and acyclic, the core reaches quiescence, issues the MMIO, and commits.

---

## 17. Milestone 3 Verification Contract (Resolution of P1-9)

The implementation of Milestone 3 must be proven through a comprehensive test suite in `verification/s1_m3_tb.cpp` and runner `tools/run_s1_m3.py`.

### 17.1 Mandatory Directed Test Suite (45 Enumerated Scenarios)
1. **`LB` / `LBU` / `LH` / `LHU` / `LW` / `LWU` / `LD`**: Correct data extraction and sign/zero extension.
2. **`SB` / `SH` / `SW` / `SD`**: Correct byte lane enable masks and physical positioning.
3. **Misalignment Exceptions & Faulting Store Immediate Completion**: Halfword, word, and doubleword misalignment triggering Cause 4 / 6. Crucially, a misaligned store with store data pending from an active division asserts `store_exception_complete` immediately, reporting Cause 6 to the ROB without waiting for `data_valid` or divider completion, creating zero committed SQ obligation and zero memory side effect.
4. **Store Address Resolves Before Data**: Store AGU issues with `prs1` ready while `prs2` is not ready.
5. **Successful Store Requires Data Valid (Bifurcated Completion)**: Proving that for a non-faulting store, normal ROB completion (`store_success_complete`) strictly stalls until both `pa_valid == 1` and `data_valid == 1`, whereas faulting stores complete immediately on error detection.
6. **Load Waits Behind Unresolved Older Store PA**: Load stalls when older store has `pa_valid == 0`.
7. **Overlapping Store with Data Not Ready Blocks Load**: Load stalls when older store overlaps and data is pending.
8. **Exact Store-to-Load Forwarding**: 64-bit store forwarding directly to 64-bit load in 1 cycle.
9. **Contained Sub-Word Forwarding**: 64-bit store forwarding to 32-bit, 16-bit, and 8-bit loads.
10. **Partial Overlap Conservative Stall**: 16-bit store overlapping 32-bit load; proving load stalls until store drains.
11. **Disjoint Younger-Mask Store Does Not Shadow Older Store**: Older matching store forwards data past younger disjoint store.
12. **Youngest Older Matching Store Wins**: Multiple stores to same address; verifying youngest data forwards.
13. **Multi-Store Combined Coverage Stalls**: Two stores jointly covering a load stall until both drain.
14. **SQ Older-Mask Deallocation Clearing & Wrap Immunity (P0-1 Closeout)**: Proving slot 15 reuse does not forward to load. Verifying that when an older speculative store is squashed while a younger load survives, the load's corresponding `sq_older_mask[i]` bit clears immediately via `sq_squash_dealloc[i]`, preventing load deadlock. Verifying that when a later younger store reallocates the same physical SQ slot, it does not reassert in the pre-existing load's older mask.
15. **LQ Slot Reuse**: New load in recycled LQ slot functions correctly with fresh generation token.
16. **L1D Cache Hit**: Single-cycle load hit in L1D cache.
17. **L1D Cache Miss**: Load miss allocating MSHR and fetching line from bus.
18. **Multiple Concurrent MSHRs**: 4 concurrent misses in flight simultaneously.
19. **Same-Line Multi-Waiter Merge (P0-4)**: Multiple loads merging into a single MSHR refill.
20. **Selective Waiter Squash (P0-4)**: Squashing younger waiter while older waiter in same MSHR survives and completes.
21. **All Waiters Squashed Then Refill Returns**: All waiters squashed; refill installs into L1D with zero writeback.
22. **Structural Stale-Response Non-Aliasing Test (P0-2)**: Arbitrarily delayed bus response safely discarded after slot recycling.
23. **Dirty Line Eviction to WBB**: Cache refill evicting dirty victim into WBB.
24. **WBB Full Blocks Miss Allocation (P1-4)**: MSHR miss allocation stalled when WBB is full, preventing deadlock.
25. **Load to WBB-Resident Line (P1-3)**: Load reading data directly from WBB dirty victim buffer.
26. **Committed Store to WBB-Resident Line (P1-3)**: Committed store merging byte writes into WBB entry.
27. **Refill / WBB Same-Line Collision (P1-3)**: Reconciling refill with active dirty WBB entry.
28. **Non-Blocking Hit-Under-Miss**: Load hit servicing concurrently with active MSHR miss.
29. **Non-Blocking Miss-Under-Miss**: Independent misses to different lines progressing concurrently.
30. **DTLB Hit**: Single-cycle physical address translation.
31. **DTLB Miss $\rightarrow$ Pending $\rightarrow$ Replay (P1-2)**: DTLB miss releasing AGU and replaying on translation return.
32. **Translation Stale-Response Attack & Persistent Request Ownership (P1-2 Closeout)**: Old translation request launched (`tr_id` allocated in TRT). Requesting memory uop squashed by branch mispredict; TRT marks `waiter_valid = 0` while holding `tr_id`. Target queue slot reused many times across multiple allocations. Delayed translation response returns: verified that response is dropped cleanly and NO new or reused LQ/SQ entry is modified! Also verifying that a new waiter in the reused slot intentionally issues a translation after slot reuse, allocates a distinct `tr_id`, and receives only its own response.
33. **Translation Page Fault with Pending Data**: Load and store page faults triggering Cause 13 / 15 at ROB head. Store page fault with store data pending from an active division completes immediately as an exception without waiting for store data.
34. **PMP Access Fault Denial with Pending Data**: PMP denial on physical address triggering Cause 5 / 7. Store access fault with store data pending completes immediately as an exception without waiting for store data.
35. **Faulting Load Does Not Write PRF (P1-6)**: Proving `prf_we[2] == 0` on load exception.
36. **Speculative Store Causes Zero Cache/Bus Mutation (P1-1)**: Uncommitted store verified to cause zero state changes.
37. **Committed Store Survives Full Flush (P0-3)**: Store committed at ROB head drains to L1D after trap flush.
38. **MMIO Exactly-Once Execution (P1-5)**: MMIO load/store issued strictly once at ROB head without duplication.
39. **Interrupt Deferred During Active MMIO (P1-5)**: Asynchronous interrupt held until MMIO bus transaction terminates.
40. **FENCE Complete Pipeline Drain (P2-3)**: FENCE stalling until loads, stores, MSHRs, and WBB are quiescent.
41. **`LR.W` / `LR.D` Reservation Success Flow**: Registering reservation and `SC` succeeding with return `0`.
42. **`LR` / `SC` Invalidation on Conflicting Store**: Conflicting store clearing reservation; `SC` fails with return `1`.
43. **`SC` Size Mismatch Fails (P2-2)**: `LR.W` followed by `SC.D` failing due to size mismatch.
44. **AMO Non-Speculative Indivisible Execution**: `AMOADD` executing atomically at ROB head with empty SQ.
45. **ROB / LQ / SQ Circular Wrap Interaction**: Stress test with all circular queues wrapping concurrently under load.

### 17.2 Mandatory Randomized Adversarial Verification
The testbench must implement an **independent byte-addressable C++ architectural memory reference model**:
- Tracks committed physical memory state, speculative SQ stores, and expected forwarding outcomes.
- Models randomized DTLB miss delays, randomized bus refill delays, randomized victim evictions, and randomized branch mispredictions.
- Compares retired physical register values and committed memory bytes against the reference model on every instruction commit.

### 17.3 Mandatory RTL Simulation Assertions
1. `assert property (@(posedge clk_i) !(comp_valid_i[2] && !comp_ack_o[2] && prf_we[2]));`
   *(Stale load completions must NEVER write PRF data).*
2. `assert property (@(posedge clk_i) !(comp_valid_i[2] && comp_exception_i[2] && prf_we[2]));`
   *(Faulting load completions must NEVER write PRF data).*
3. `assert property (@(posedge clk_i) !(store_drain_valid && !sq_entry.committed));`
   *(Stores must NEVER modify L1D cache or memory before architectural retirement).*
4. `assert property (@(posedge clk_i) !(load_issued_to_l1d && older_store_pa_unresolved));`
   *(Loads must NEVER access memory while older store physical addresses are unresolved).*
5. `assert property (@(posedge clk_i) !(forward_valid && partial_overlap_detected));`
   *(Store-to-load forwarding must NEVER occur on partial address overlap).*
6. `assert property (@(posedge clk_i) !(mshr_alloc_valid && (mshr_free_count == 0)));`
   *(MSHR must never overflow).*
7. `assert property (@(posedge clk_i) !(wbb_alloc_valid && (wbb_free_count == 0)));`
   *(Writeback buffer must never overflow or drop dirty victim lines).*
8. `assert property (@(posedge clk_i) !(mmio_bus_req_valid && !is_at_rob_head));`
   *(MMIO accesses must NEVER issue speculatively).*
9. `assert property (@(posedge clk_i) (reservation_valid && (reservation_pa[5:0] != 6'd0) == 1'b0));`
   *(LR reservation physical address must be line/word aligned).*
10. `assert property (@(posedge clk_i) !(sq_entry.exception_pending && sq_entry.committed));`
    *(Faulting stores must NEVER transition into committed-store drain state).*
11. `assert property (@(posedge clk_i) !(comp_valid_i[2] && comp_exception_i[2] && is_store_uop && !sq_entry.exception_pending));`
    *(Store exception completion asserts IF AND ONLY IF an exception is pending).*
12. `assert property (@(posedge clk_i) !(ptw_rsp_valid_i && (ptw_rsp_tr_id_i < 4) && !trt_entry[ptw_rsp_tr_id_i].waiter_valid && lq_or_sq_entry_modified));`
    *(Squashed translation responses must NEVER modify any LQ or SQ entry).*

---

## 18. Performance Intent (Design Goals Only)

- **Long-Term Full-Core Target**: Exceed Slice-0's measured IPC of $\sim 0.648$ to achieve $\ge 1.20$ IPC on representative Linux server workloads (with stretch target $\ge 1.50$ IPC) once the complete core is integrated.
- **Milestone 3 Memory Parallelism Target**:
  - Sustained load throughput: **1.0 load / cycle** on L1D cache hits.
  - Zero load stalls behind non-overlapping stores.
  - Up to **4 concurrent cache misses** processed simultaneously via MSHRs.
  - 1-cycle store-to-load forwarding latency on exact matches.
  - Zero fabricated IPC numbers: M3 is an out-of-order memory execution backend; application performance will be measured once the frontend is integrated in Milestone 4.
