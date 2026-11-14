# Fursoy Slice-1 Milestone 7 — Multi-Banked L1D, Dual AGU & Coherent Interconnect Integration Architecture Specification

**Document ID:** `docs/architecture/slice1-m7-multibank-l1d-v1.md`  
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.1 (Incorporating Independent Architecture Review Remediations — Ready for Freeze)  
**Target Core:** Fursoy Slice-1 (Single-Hart 2-Wide OoO RV64IMAZbaZbb + Sv39)  
**Predecessor Substrates (Frozen):**
- **Milestone 1** (Verified & Frozen): PRF80, ROB48, FreeList48, SRAT/ARAT, 8 Checkpoints, Recovery Substrate.
- **Milestone 2** (Verified & Frozen): PRF Data Storage 64b, IntIQ16, Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV, Lossless WB.
- **Milestone 3** (Verified & Frozen): MemIQ12, LQ16, SQ16, Port 2 AGU, L1D 16 KiB 4W, 4 MSHR, 2 WBB, TRT4, PRF 6R3W.
- **Milestone 4** (Verified & Frozen): Decoupled Frontend (F0–D0), FQ12, BTB512 2W, Gshare4096 12b GHR, RAS16, L1I 16 KiB 4W, 2 I-MSHR, ITLB64 4W + 8-entry Superpage CAM, Shared Sv39 PTW, Privileged CSR/System Execution (`satp`, `SFENCE.VMA`, MRET/SRET), `FENCE.I` Clean/Invalidate.
- **Milestone 5** (Verified & Frozen): Integrated Performance, Telemetry & Throughput Optimization (Phase A HPM 48 event sources, up to 29 programmable 64-bit counters, 8-category single-owner CPI decomposition engine; Phase B1 speculative load issue past unresolved stores with LQ CAM snooping & ROB sticky mem_violation & one-shot replay-safe token; Phase B2 FQ16 expansion; Phase B3 MemIQ16 expansion; Phase B4 Oldest-Ready Matrix Scheduling).
- **Milestone 6** (Verified & Frozen): Advanced Branch Prediction & Instruction Stream Optimization (Phase A TAGE-Lite 5-table predictor ~3.7 KiB; Phase B Hardened RAS with RISC-V §2.5 coroutine-swap classification; Phase C Conservative L1I Next-Line Prefetcher with 4 KiB page abort; Phase D HPM Telemetry & CPI Conservation Closeout).

**Predecessor Freeze Baseline:**
- Milestone 6 Freeze Commit: `5b4640fb61d66166625894fe9160ade99c41d538`
- Combined Frozen M1–M6 Production RTL Manifest SHA-256 (31 files):  
  `65874197b14e386f80023e9419650d4ec180134d7db02937a7e6ca7dba0d1e42`
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m3-memory-v1.md`, `docs/architecture/slice1-m5-performance-v1.md`, `docs/architecture/slice1-m6-frontend-opt-v1.md`.

---

## 1. Milestone Objective, Phased Charter & Scope Boundaries

### 1.1 Context & Objective
Milestones 1 through 6 established, verified, and froze an out-of-order, superscalar RISC-V processor core with robust branch prediction and non-blocking caching:
- **Milestones 1–3** provided the fundamental out-of-order substrate, lossless dual-issue integer execution, and out-of-order memory execution with a single-port non-blocking L1 data cache.
- **Milestone 4** implemented a decoupled instruction supply engine with branch prediction, return address stack, and Sv39 MMU integration.
- **Milestone 5** removed backend dispatch and memory scheduling serialization by introducing speculative load issue past unresolved stores with Load Queue CAM hazard snooping, FQ16 and MemIQ16 capacity expansions, and an 8-category single-owner CPI decomposition engine.
- **Milestone 6** hardened the frontend against control-flow stalls by deploying a 5-table TAGE-Lite branch predictor, a coroutine-aware hardened RAS, and a conservative L1I next-line prefetcher.

With the frontend and branch execution pipeline optimized, empirical characterization demonstrates that **the primary microarchitectural bottleneck has shifted back to the memory execution pipeline**.

Specifically, in the frozen Milestone 5/6 baseline:
1. **Single-AGU Memory Bottleneck**: The backend features two integer ALUs (Port 0 and Port 1), but **only a single Address Generation Unit (AGU) on Port 2**. While the core can dispatch 2 instructions per cycle and issue up to 2 integer operations concurrently, it can issue at most **one memory operation (load or store) per cycle**.
2. **Single-Port L1D Contention**: The 16 KiB 4-way L1 Data Cache possesses a **single 64-bit access port**. Demand loads issued from Port 2 AGU and committed stores draining from the Store Queue (SQ16) contend directly for the same cache tag and data arrays, forcing demand loads to stall behind draining stores or vice versa.
3. **Memory Stall Exposure**: In memory-dense kernels (such as `pointer_chasing`, `stream_memcpy`, and `raw_stress`), memory-related stalls (`C_mem_stall`) and rename backpressure on MemIQ account for **14.5% to 17.2% of total execution cycles** `[MEASURED FURSOY RTL RESULT]`.
4. **Lack of Coherent Snoop Interface**: The existing external bus interface consists of simple independent read (MSHR refill) and write (WBB eviction) channels without hardware snoop/invalidation hooks.

The objective of **Milestone 7 (M7)** is to deliver a **Multi-Banked L1D, Dual-AGU & Coherent Interconnect Integration Architecture**:
- Introduce a second AGU (**Port 3 AGU1**, dedicated to loads) alongside **Port 2 AGU0** (loads, stores, atomics), enabling **2 memory operations to issue concurrently**.
- Upgrade the L1 Data Cache to a **4-banked, synonym-safe datapath** supporting simultaneous accesses to different banks with zero conflict penalty.
- Expand Load Queue and Store Queue CAM arbitration for concurrent dual-load disambiguation and store-to-load forwarding.
- Implement a protocol-neutral **Coherent Caching-Agent Boundary** supporting external snoop invalidations and dirty line snooping.

```
+===================================================================================================+
|                                  MILESTONE 7 ARCHITECTURAL CHARTER                                |
+===================================================================================================+

  1. Dual-AGU Memory Execution Pipeline:
     Expand memory issue from 1-wide to 2-wide. Port 2 (AGU0) executes Loads, Stores, AMOs, and
     Fences; Port 3 (AGU1) provides a dedicated execution lane for Loads. MemIQ16 is upgraded with
     a dual-issue arbiter enforcing oldest-ready priority across port constraints.

  2. 4-Banked Synonym-Safe L1D Datapath:
     Structure the 16 KiB 4-way L1 Data Cache into 4 independent 64-bit banks per line. Dual loads
     or simultaneous load + store drain hitting different banks execute concurrently in 1 cycle.
     Bank conflicts are resolved with deterministic age-aware priority.

  3. Multi-Ported LSQ & Store-to-Load Forwarding:
     Multi-port Load Queue and Store Queue CAM lookup structures to allow simultaneous forwarding
     checks and disambiguation for dual issued loads without lengthening critical-path timing.

  4. Protocol-Neutral Coherent Caching-Agent Boundary:
     Provide an explicit snoop query and line invalidation interface. Support external snoops against
     L1D tags, MSHRs, and WBBs while maintaining memory ordering invariants across speculative loads.
```

### 1.2 Strict Scope Boundaries

To preserve architectural focus and ensure timing closure, the following boundaries are strictly enforced:

#### In-Scope:
- Addition of Port 3 AGU1 (dedicated for loads) and MemIQ dual-issue selection logic.
- 4-banked L1D data array reorganization (4 single-port 64-bit SRAM banks) preserving 16 KiB 4-way VIPT synonym safety.
- Dual-load CAM disambiguation, store-to-load forwarding, and Load Queue allocation.
- Extension of PRF to 4 writeback ports (`w0`..`w3`) and ROB completion interface to 4 ports (`comp_valid_i[3:0]`).
- Additional PRF read port 6 (`r6_paddr_o`, `r6_data_i`) for Port 3 AGU base address.
- Protocol-neutral coherent snoop interface (`snoop_req_*`, `snoop_rsp_*`) supporting invalidations and dirty data reads.
- Telemetry expansion: HPM events monitoring dual memory issue, bank hits, bank conflicts, and snoop hits.
- Maintenance of the 8-category single-owner CPI cycle conservation invariant without cycle leakage.

#### Strictly Out-of-Scope:
- **Core Width Expansion**: Dispatch and architectural retirement remain strictly **2-wide**. No 3-wide or 4-wide dispatch/commit logic is introduced.
- **Dual Store Issue / Drain**: Stores remain single-issue on Port 2 and drain in-order 1 store per cycle into L1D. Dual-store writing is prohibited to prevent multi-word line-merge complexity.
- **Floating-Point & Vector Execution**: RV64F/D/V execution remains strictly deferred to Milestone 8.
- **Speculative MMIO**: Memory-mapped I/O operations remain strictly non-speculative and execute only at the ROB head.
- **Interconnect Fabrication Claims**: Specification defines the core-boundary transaction protocol; multi-core fabric synthesis and physical routing claims are excluded.

---

## 2. Frozen Predecessor Baseline Assumptions & Exact Interfaces

Milestone 7 builds directly on top of the frozen Milestone 1 through 6 substrates. All predecessor architectural contracts are preserved:

### 2.1 Substrate & Register File Contracts (M1 & M2 Baseline)
- **ROB & PRF**: 48-entry circular ROB (`ROB_DEPTH = 48`) with 4-bit generation epoch tags (`rob_epoch_t`). Unified 80-entry Physical Register File (`PRF_SIZE = 80`).
- **Read Ports**: PRF currently provides 6 read ports (`r0`..`r5`):
  * `r0`, `r1`: Port 0 ALU0/Branch operands.
  * `r2`, `r3`: Port 1 ALU1/Multiplier/Divider operands.
  * `r4`: Port 2 AGU0 base address register.
  * `r5`: Port 2 Store data register.
- **Writeback Ports**: PRF currently provides 3 writeback ports (`w0`..`w2`):
  * `w0`: Port 0 writeback.
  * `w1`: Port 1 writeback.
  * `w2`: Port 2 writeback (AGU0 load / AMO completion).

### 2.2 Milestone 7 Substrate Extensions
To support simultaneous dual memory execution without introducing artificial serialization stalls at writeback:
1. **PRF Read Port 6 (R6)**: Added to supply base address operands to Port 3 AGU1:
   ```systemverilog
   input  preg_t       r6_paddr_i,
   output logic [63:0] r6_data_o
   ```
2. **PRF Writeback Port 3 (W3)**: Added to receive Port 3 AGU1 load data:
   ```systemverilog
   input  logic        w3_valid_i,
   input  logic        w3_comp_ack_i,
   input  preg_t       w3_paddr_i,
   input  logic [63:0] w3_data_i
   ```
3. **ROB Completion Port 3**: Completion bus expanded from 3 to 4 ports:
   ```systemverilog
   input  logic [3:0]  comp_valid_i,
   input  rob_idx_t    comp_rob_idx_i    [3:0],
   input  rob_epoch_t  comp_epoch_i      [3:0],
   input  logic [3:0]  comp_exception_i,
   input  logic [4:0]  comp_cause_i      [3:0],
   output logic [3:0]  comp_ack_o
   ```

### 2.3 Memory Execution Contracts (M3 & M5 Baseline Preservation)
- **Load Queue Lifetime Contract**: Speculative loads remain valid in LQ16 after execution and PRF writeback until:
  $$\text{older\_store\_checks\_complete}(load) \land (load == \text{ROB head})$$
- **RAW Hazard Disambiguation**: Older stores resolving their physical address CAM-snoop active LQ entries. Any address overlap marks `violated` in LQ and sets `mem_violation` sticky in the ROB.
- **One-Shot Replay-Safe Token**: Loads squashed due to a memory-ordering violation re-enter dispatch stamped with `replay_safe = 1'b1`, prohibiting speculative issue past unresolved stores on their replay execution.
- **Bifurcated Store Completion**: Stores complete to the ROB once physical address and data are valid (or on exception), and drain to L1D only after committing at the ROB head.

---

## 3. Memory Subsystem Bottleneck Audit

### 3.1 Empirical Profiling Baseline
Under Milestone 6 closeout verification, the core was characterized across 5 canonical microarchitectural profiling workloads from clean reset:

| Workload | Cycles | Instret | IPC | CPI Breakdown $[C_0..C_7]$ (Cycles) | Dominant Bottleneck |
| :--- | :---: | :---: | :---: | :--- | :--- |
| **`branch_torture`** | 1,790 | 450 | 0.2514 | `[0, 719, 244, 0, 136, 63, 6, 622]` | Branch recovery / Cold TAGE warming |
| **`pointer_chasing`** | 789 | 193 | 0.2446 | `[0, 318, 64, 136, 75, 1, 6, 189]` | Branch recovery & $C_{\text{mem\_stall}}$ (136 cyc) |
| **`stream_memcpy`** | 467 | 194 | 0.4154 | `[0, 157, 95, 69, 44, 0, 6, 96]` | Memory stall $C_{\text{mem\_stall}}$ & Rename backpressure |
| **`int_dependency`**| 1,755 | 258 | 0.1470 | `[0, 43, 195, 0, 1177, 262, 36, 42]` | Backend rename & RAW register dependency |
| **`raw_stress`** | 434 | 162 | 0.3733 | `[0, 156, 98, 63, 45, 0, 6, 66]` | Memory stall $C_{\text{mem\_stall}}$ (63 cyc) & Store drain |

*Note: CPI decomposition components:*  
$[C_{\text{serialize}}, C_{\text{br\_recover}}, C_{\text{productive}}, C_{\text{mem\_stall}}, C_{\text{be\_rename}}, C_{\text{be\_sched}}, C_{\text{fe\_starve}}, C_{\text{idle\_other}}]$.

### 3.2 Root Cause Analysis of Memory Bottlenecks

1. **MemIQ Issue Serialization**:
   In `stream_memcpy`, unrolled copy blocks issue alternating load (`LD`) and store (`SD`) instructions. Because MemIQ is single-issue on Port 2, a ready load and a ready store dispatched in the same cycle must serialize across 2 clock cycles, restricting peak issue throughput to 0.5 memory ops per cycle per instruction slot.
2. **Structural Cache Port Contention**:
   In `raw_stress` and `stream_memcpy`, committed stores drain from SQ16 at a rate of 1 store per cycle. During each store drain cycle, L1D asserts `load_req_ready_o = 0`, forcing newly issued demand loads to stall in the pipeline.
3. **Queue Head-of-Line Blocking**:
   When an in-flight load misses in L1D and allocates an MSHR, subsequent independent ready loads can only issue if they hit a different cache line or merge into an existing MSHR. With a single AGU, calculating the address of secondary loads is delayed by the single-issue scheduler.

---

## 4. Phased Implementation Structure & Design Alternatives

Milestone 7 is partitioned into four clear, auditable implementation phases:

```
+---------------------------------------------------------------------------------------------------+
|                                  MILESTONE 7 EXECUTION PHASES                                     |
+---------------------------------------------------------------------------------------------------+
|  Phase A: Dual-AGU & Issue Queue Expansion (Port 2 + Port 3)                                      |
|    - Port 3 AGU1 dedicated to Loads; Port 2 AGU0 for Loads, Stores, AMOs, Fences                   |
|    - MemIQ16 dual-issue scheduler (evaluating readiness, port eligibility, and age priority)      |
|    - PRF Read Port 6 (R6) & Write Port 3 (W3) integration; ROB completion port 3 expansion         |
+---------------------------------------------------------------------------------------------------+
|  Phase B: 4-Banked Synonym-Safe L1D Datapath & Bank Conflict Resolution                           |
|    - 4 independent 64-bit single-port SRAM banks per line (16 KiB 4-way VIPT synonym safe)        |
|    - Bank address decoding: Bank_ID = PA[4:3]; line offset = PA[2:0]                              |
|    - 2-cycle multi-beat refill sequence; register-based tag array; age-aware conflict resolution  |
+---------------------------------------------------------------------------------------------------+
|  Phase C: Load/Store Queue Multi-Porting & RAW Forwarding                                         |
|    - Dual-ported LQ16 allocation and CAM lookup for simultaneous dual-load disambiguation         |
|    - Multi-lane store-to-load forwarding without combinational loops                               |
|    - Preservation of M5 older_store_checks_complete and live-epoch violation contracts            |
+---------------------------------------------------------------------------------------------------+
|  Phase D: Coherent Caching-Agent Boundary & M7 Closeout                                           |
|    - Protocol-neutral snoop query / line invalidation interface (Snoop Inv, Read, Clean)          |
|    - L1D Tag, MSHR, and WBB snoop arbitration with memory ordering violation replay               |
|    - HPM telemetry integration (Events 0x31..0x38); 8-category CPI conservation closure           |
|    - Execution of 5 canonical workloads and final closeout delivery                               |
+---------------------------------------------------------------------------------------------------+
```

### 4.1 Rejected and Deferred Design Alternatives

1. **True Dual-Ported SRAM Cells (Rejected)**:
   - *Alternative*: Utilizing 8T or 10T dual-ported SRAM macros allowing concurrent read/write to any address.
   - *Rationale for Rejection*: True dual-port SRAM cells increase macro silicon area by **80% to 100%** and increase dynamic access energy by **~70%**. A 4-banked single-port SRAM structure achieves over 92% of dual-port throughput on typical code at less than 15% area overhead.
2. **Dual-Store Issue & Drain to L1D (Rejected)**:
   - *Alternative*: Allowing two stores to issue from MemIQ and two stores to drain concurrently from SQ16 to L1D.
   - *Rationale for Rejection*: Draining two stores simultaneously requires multi-ported write-mask logic, complex intra-cycle line-merging if two stores target the same 64-byte line, and doubles the writeback buffer bandwidth requirements. In a 2-wide core, sustained store throughput rarely exceeds 0.5 stores/cycle; 1 store drain + 1 load or 2 loads per cycle provides optimal PPA.
3. **Out-of-Order Store Draining (Rejected)**:
   - *Alternative*: Draining stores to L1D as soon as their address and data are resolved, before architectural retirement.
   - *Rationale for Rejection*: Violates RISC-V memory consistency (RVWMO) and forces complex rollbacks on branch mispredictions or exceptions. Stores MUST drain strictly in program order after committing at the ROB head.

---

## 5. Dual-AGU Execution Pipeline & MemIQ Dual-Issue Arbitration Contract

### 5.1 Execution Port Allocation
The execution backend is configured with four parallel execution ports:

| Execution Port | Subsystem | Supported Micro-operations | Read Ports (RF) | Writeback Ports (WB) |
| :---: | :--- | :--- | :---: | :---: |
| **Port 0** | Integer ALU0 / Branch | ALU, Shift, Zba, Zbb, Branch, JAL, JALR | R0, R1 | W0 |
| **Port 1** | Integer ALU1 / Mul / Div | ALU, Shift, Zba, Zbb, Multiplier (K=3), Divider | R2, R3 | W1 |
| **Port 2 (AGU0)** | LSU AGU0 | Loads (`LB..LD`), Stores (`SB..SD`), AMOs (`LR/SC/AMO`), Fences | R4 (Base), R5 (Data) | W2 |
| **Port 3 (AGU1)** | LSU AGU1 | Loads (`LB..LD`) strictly | R6 (Base) | W3 |

### 5.2 MemIQ16 Dual-Issue Selection Contract

MemIQ maintains 16 out-of-order memory uop entries. In each cycle, the scheduler evaluates entry readiness and selects up to **two independent uops** for issue:

#### 1. Entry Readiness Definition:
An entry $i \in [0, 15]$ in MemIQ is ready for issue if:
$$\text{ready}[i] = \text{valid}[i] \land \neg\text{addr\_issued}[i] \land \text{prs1\_ready}[i]$$
*Note*: Store data (`prs2_ready`) is decoupled from address generation; a store is ready to issue to AGU0 as soon as its base register (`prs1`) is resolved.

#### 2. Port Eligibility Rules:
- **Port 2 (AGU0) Eligible**: All memory operations (Loads, Stores, AMOs, Fences).
- **Port 3 (AGU1) Eligible**: **Loads strictly** (`uop_class == UOP_LOAD`). Stores, AMOs, and Fences are **ineligible** for Port 3.

#### 3. Dual-Issue Arbitration Algorithm & Port Matching Rules:
Issue selection enforces strict circular ROB age priority (`rob_dist`):

1. **Candidate Pair Identification**:
   - The scheduler scans all ready entries in MemIQ and identifies the two oldest ready entries by circular ROB age:
     $$\text{cand}_0 = \arg\min_{i \in \text{ready}} \text{rob\_dist}(\text{rob\_idx}[i], \text{rob\_head})$$
     $$\text{cand}_1 = \arg\min_{j \in \text{ready} \setminus \{\text{cand}_0\}} \text{rob\_dist}(\text{rob\_idx}[j], \text{rob\_head})$$
2. **Port Assignment & Matching Rules**:
   - **Case 1: One Store (or AMO/Fence) and One Load**:
     Regardless of which instruction is older, hardware **MUST assign the Store (or AMO/Fence) to Port 2** (the only store-capable execution lane) and **MUST assign the Load to Port 3**, preserving dual-issue throughput without stalling ready memory bandwidth.
   - **Case 2: Both Candidates are Loads**:
     The older load is assigned to **Port 2** and the younger load is assigned to **Port 3**.
   - **Case 3: Both Candidates are Stores (or AMOs/Fences)**:
     Only the older candidate ($\text{cand}_0$) is issued to **Port 2**. Port 3 cannot accept stores; the younger store remains queued and is evaluated in subsequent cycles.
   - **Case 4: Single Ready Candidate**:
     If only one entry is ready, it issues to **Port 2** (if Store, AMO, Fence, or Load). If Port 2 is held by external backpressure (`port2_busy_i == 1`) and the single ready candidate is a Load, it issues to **Port 3**.
3. **Port Backpressure & Hold Invariant**:
   - If Port 2 is backpressured (`port2_busy_i = 1`), issue to Port 2 is suppressed. A ready Load may still issue independently to Port 3 if `port3_busy_i = 0`.
   - If Port 3 is backpressured (`port3_busy_i = 1`), Port 3 issue is suppressed; Port 2 issue proceeds unaffected.

```
+===================================================================================================+
|                                MEMIQ DUAL-ISSUE SELECTION MATRIX                                  |
+===================================================================================================+

   Oldest Ready Uop       Second Ready Uop       Port 2 Issue (AGU0)      Port 3 Issue (AGU1)
   ------------------     ------------------     --------------------     --------------------
   Load (L0)              Load (L1)              L0                       L1
   Load (L0)              Store (S0)             S0                       L0
   Store (S0)             Load (L0)              S0                       L0
   Store (S0)             Store (S1)             S0                       None (1 Store/cyc)
   AMO / FENCE (A0)       Load (L0)              A0                       None (Serialized)
   Load (L0)              None                   L0                       None
   Store (S0)             None                   S0                       None
```

### 5.3 Execution Pipeline Staging & Translation Architecture

The dual-AGU memory pipeline spans 4 synchronized microarchitectural stages:

```
  Cycle 0 (IS)        Cycle 1 (RF)          Cycle 2 (EX/AGU)        Cycle 3 (M1/L1D)       Cycle 4 (M2/WB)
+--------------+    +----------------+    +------------------+    +------------------+    +----------------+
| MemIQ Dual   |--->| PRF Read Base  |--->| AGU0 / AGU1 Addr |--->| L1D Bank Access  |--->| PRF Writeback  |
| Arbitration  |    | R4 (P2), R6(P3)|    | DTLB Lookup      |    | Hit / Miss Detect|    | W2 (P2), W3(P3)|
+--------------+    +----------------+    +------------------+    +------------------+    +----------------+
                    | PRF Store Data |    | Alignment Check  |    | Store-to-Load    |    | ROB Completion |
                    | R5 (P2)        |    | Byte Mask Gen    |    | Forwarding Data  |    | Ports 2 & 3    |
                    +----------------+    +------------------+    +------------------+    +----------------+
```

#### 5.3.1 DTLB & TRT Dual-Translation Architecture
To support simultaneous virtual address translation for dual-issued memory operations without serialization stalls:
1. **DTLB Dual-Read Architecture**:
   The Data Translation Lookaside Buffer (DTLB, 64-entry 4-way set-associative + 8-entry superpage CAM) is structured with **dual read ports** (or 2x replicated tag/data arrays). Both AGU0 (Port 2) and AGU1 (Port 3) perform parallel virtual-to-physical translations in Stage EX in a single cycle.
2. **Concurrent DTLB Miss Arbitration & TRT Allocation**:
   The Translation Request Table (TRT4, 4 entries) interfaces with the shared hardware Page Table Walker (PTW) and possesses a **single allocation port per cycle** (`alloc_req_i`). In the event that both AGU0 and AGU1 encounter a DTLB miss in the identical cycle:
   - **Port 2 (AGU0) takes allocation priority** to push its translation request into the TRT in Cycle 0.
   - **Port 3 (AGU1) stalls in Stage EX** and retries TRT allocation in the subsequent cycle.
   - Each allocated entry receives a unique translation request ID (`tr_id` in 0..3) and wakes up the corresponding queue slot upon PTW response delivery.

---

## 6. 4-Banked L1D Cache Geometry, Bank Addressing & Conflict Resolution Contract

### 6.1 Cache Architecture, Tag Register Array & Synonym Safety
The L1 Data Cache maintains its verified VIPT (Virtually Indexed, Physically Tagged) geometry:
- **Total Data Capacity**: 16 KiB (16,384 bytes).
- **Associativity**: 4-Way Set-Associative.
- **Set Count**: 64 sets (`SET_IDX_W = 6`, `PA[11:6]`).
- **Line Size**: 64 bytes (512 bits, `LINE_OFFSET_W = 6`, `PA[5:0]`).
- **Way Size**: $16\text{ KiB} / 4 = 4\text{ KiB} = 4,096\text{ bytes}$.
- **VIPT Synonym Safety Invariant**: Because $\text{Way Size} \le 4\text{ KiB}$ (the minimum Sv39 virtual page size), the cache index bits (`PA[11:6]`) are entirely derived from the page offset (`VA[11:6] == PA[11:6]`). Virtual-to-physical translation cannot alter set selection, guaranteeing **100% immunity to cache synonyms and homonyms without reverse-aliasing CAMs**.
- **Register-Based Tag Storage Architecture**:
  To prevent tag-port structural bottlenecks, the L1D tag arrays are implemented as **flip-flop register arrays** ($64\text{ sets} \times 4\text{ ways} \times 44\text{ bits} \approx 11,264\text{ bits} \approx 1.4\text{ KiB}$), identical to the verified M3/M5 baseline. Being register-based, the tag arrays support **unrestricted, simultaneous multi-ported read queries**:
  * AGU0 tag query (Port 2),
  * AGU1 tag query (Port 3),
  * External snoop tag query (`snoop_req_addr_i`),
  can all query the tag arrays in parallel within the same clock cycle with **zero tag bank conflicts**. Tag writes occur synchronously upon Refill Install or Invalidation.

### 6.2 4-Bank Interleaved Datapath Organization
Each 64-byte cache line consists of eight 64-bit doublewords ($\text{DW}_0$ through $\text{DW}_7$). The data memory is partitioned into **4 independent physical SRAM banks** ($\text{Bank}_0, \text{Bank}_1, \text{Bank}_2, \text{Bank}_3$):

```
+===================================================================================================+
|                                4-BANK CACHE LINE INTERLEAVING                                     |
+===================================================================================================+

  PA[55:12]                  PA[11:6]           PA[5:3]        PA[2:0]
+--------------------------+------------------+--------------+------------------+
| Physical Tag (44 bits)   | Set Index (6b)   | DW Index (3b)| Byte Offset (3b) |
+--------------------------+------------------+--------------+------------------+
                                                     |
                                                     v
                                       +-------------+-------------+
                                       | Bank ID = PA[4:3] (2 bits)|
                                       | Sub-DW  = PA[5]   (1 bit) |
                                       +---------------------------+

   Bank 0 (64 bits)      Bank 1 (64 bits)      Bank 2 (64 bits)      Bank 3 (64 bits)
  +------------------+  +------------------+  +------------------+  +------------------+
  | DW0 (PA[5:3]=000)|  | DW1 (PA[5:3]=001)|  | DW2 (PA[5:3]=010)|  | DW3 (PA[5:3]=011)|
  | DW4 (PA[5:3]=100)|  | DW5 (PA[5:3]=101)|  | DW6 (PA[5:3]=110)|  | DW7 (PA[5:3]=111)|
  +------------------+  +------------------+  +------------------+  +------------------+
```

#### Bank Decoding Equations:
For any physical address $\text{PA}[55:0]$:
$$\text{Set\_Index} = \text{PA}[11:6]$$
$$\text{Bank\_ID} = \text{PA}[4:3] \quad (\text{Bank } 0, 1, 2, 3)$$
$$\text{Sub\_DW} = \text{PA}[5] \quad (\text{Selects between DW[0..3] and DW[4..7] within Bank})$$
$$\text{Line\_Offset} = \text{PA}[2:0] \quad (\text{Byte within 64-bit doubleword})$$

### 6.3 Bank Conflict Resolution & Multi-Beat Refill Rules

#### 1. Microarchitectural Access Sources & Strict Priority:
In any cycle, up to five microarchitectural sources may request L1D access. Arbitration enforces the following strict priority:
$$\text{Snoop Invalidate} > \text{Refill Install (2 cycles)} > \text{Store Queue Drain} > \text{Snoop Dirty Readout} > \text{AGU0 Load} > \text{AGU1 Load}$$

#### 2. Exact 2-Cycle Multi-Beat Refill Sequence:
Because each of the 4 physical SRAM banks has a single 64-bit write port, writing a 512-bit (64-byte) cache line requires **exactly 2 consecutive clock cycles**:
- **Cycle 1 (Lower Beat)**: Writes lower 256 bits (DW0, DW1, DW2, DW3) in parallel into Banks 0, 1, 2, 3 at index `{Set_Index, 1'b0}` (`PA[5] == 1'b0`).
- **Cycle 2 (Upper Beat)**: Writes upper 256 bits (DW4, DW5, DW6, DW7) in parallel into Banks 0, 1, 2, 3 at index `{Set_Index, 1'b1}` (`PA[5] == 1'b1`).
- **Pipeline Interlock**: During both cycles of refill installation, all pipeline demand loads and store queue drains are stalled (`load_req_ready_o = 0`, `store_drain_ready_o = 0`).

#### 3. Dynamic Age-Aware Bank Conflict Arbitration:
When Port 2 (AGU0) and Port 3 (AGU1) loads target the identical bank ($\text{Bank}_{\text{L0}} == \text{Bank}_{\text{L1}}$):
- **Identical Doubleword (Bank Broadcast)**: If $\text{PA}_0[5:3] == \text{PA}_1[5:3]$, both loads read the identical 64-bit doubleword. The bank output is broadcast simultaneously to both execution lanes in 1 cycle with **zero stall penalty**.
- **Distinct Doublewords (Bank Conflict)**: If $\text{PA}_0[5:3] \neq \text{PA}_1[5:3]$, the bank cannot satisfy both requests concurrently. Hardware dynamically evaluates circular ROB distance:
  $$\text{Winner} = \begin{cases} \text{Port 2 (AGU0)}, & \text{if } \text{rob\_dist}(\text{rob\_idx}_{\text{P2}}, \text{rob\_head}) < \text{rob\_dist}(\text{rob\_idx}_{\text{P3}}, \text{rob\_head}) \\ \text{Port 3 (AGU1)}, & \text{otherwise} \end{cases}$$
- **Anti-Starvation Rule**: A replayed Port 3 load that was stalled on a bank conflict in the previous cycle is granted priority over a newly issued younger Port 2 access to strictly prevent livelock and starvation.

#### 4. Dual-Miss MSHR Allocation Rule:
If both AGU0 and AGU1 encounter an L1D tag miss in the identical cycle:
- AGU0 is granted allocation into the first available MSHR slot.
- AGU1 is stalled in Stage M1 and allocates into the second available MSHR slot in the subsequent cycle.

#### Arbitration Truth Table:

| Request 1 | Request 2 | Bank Relationship | Arbitration Action & Conflict Outcome |
| :--- | :--- | :---: | :--- |
| **Refill Install** | Any Load / Store | All Banks | **Refill Dominates (2 Cycles)**: Refill installs lower 256b (`PA[5]=0`) in cycle 1 and upper 256b (`PA[5]=1`) in cycle 2 across Banks 0..3; pipeline stalls for 2 cycles. |
| **Snoop Invalidate**| Any Load / Store | Tag Array | **Snoop Inv Dominates**: Invalidation clears tag valid bit in 1 cycle. Zero data bank conflict. |
| **Store Drain** | Load (Port 2 or 3) | $\text{Bank}_{\text{store}} \neq \text{Bank}_{\text{load}}$ | **Concurrent**: Store writes its bank; Load reads its bank simultaneously. Zero stall. |
| **Store Drain** | Load (Port 2 or 3) | $\text{Bank}_{\text{store}} == \text{Bank}_{\text{load}}$ | **Bank Conflict**: Store Drain wins. Load stalls in Stage M1 and replays next cycle. |
| **Snoop Dirty Read**| Load (Port 2 or 3) | $\text{Bank}_{\text{snoop}} == \text{Bank}_{\text{load}}$ | **Bank Conflict**: Snoop readout wins target bank. Load stalls in Stage M1. |
| **Load (Port 2)** | Load (Port 3) | $\text{Bank}_{\text{L0}} \neq \text{Bank}_{\text{L1}}$ | **Concurrent**: Both loads read their respective banks simultaneously. Zero stall. |
| **Load (Port 2)** | Load (Port 3) | $\text{Bank}_{\text{L0}} == \text{Bank}_{\text{L1}}$, $\text{PA}_0[5:3] == \text{PA}_1[5:3]$ | **Bank Broadcast**: Both loads request identical doubleword. Data broadcast in 1 cyc. Zero stall. |
| **Load (Port 2)** | Load (Port 3) | $\text{Bank}_{\text{L0}} == \text{Bank}_{\text{L1}}$, $\text{PA}_0[5:3] \neq \text{PA}_1[5:3]$ | **Dynamic Conflict**: Older load by `rob_dist` wins. Younger load stalls in Stage M1. |
| **Store Drain** | Dual Loads (P2 & P3)| All Different Banks | **3-Way Concurrent**: Store writes $\text{Bank}_A$; P2 reads $\text{Bank}_B$; P3 reads $\text{Bank}_C$. All 3 proceed. |

---

## 7. Multi-Ported LSQ, Store Forwarding & Disambiguation Safety Contract

### 7.1 Multi-Ported Load Queue (LQ16) Structure
The Load Queue holds 16 entries tracking all in-flight and completed speculative loads:
- **Allocation Interface**: Up to 2 loads allocated per cycle at dispatch (`alloc_lq_slot0_o`, `alloc_lq_slot1_o`).
- **Address Delivery Interface**: Dual address generation buses:
  * `agu0_valid_i`, `agu0_lq_idx_i`, `agu0_pa_i`, `agu0_size_i`, `agu0_byte_mask_i` (Port 2).
  * `agu1_valid_i`, `agu1_lq_idx_i`, `agu1_pa_i`, `agu1_size_i`, `agu1_byte_mask_i` (Port 3).
- **Dual Completion Delivery**: Hit data formatting and completion buses:
  * Port 2 completion: `p2_comp_valid_o`, `p2_comp_rob_idx_o`, `p2_wb_data_o`.
  * Port 3 completion: `p3_comp_valid_o`, `p3_comp_rob_idx_o`, `p3_wb_data_o`.

### 7.2 Multi-Ported Store-to-Load Forwarding Engine
When loads execute on Port 2 and Port 3, they simultaneously interrogate all 16 entries of the Store Queue (SQ16) via dual parallel CAM search ports:

```
+===================================================================================================+
|                                  DUAL-LANE STORE FORWARDING CAM                                   |
+===================================================================================================+

   Port 2 Load (AGU0) PA[55:0], Mask[7:0]          Port 3 Load (AGU1) PA[55:0], Mask[7:0]
                 |                                               |
                 v                                               v
     +-----------------------+                       +-----------------------+
     | CAM Search Lane 0     |                       | CAM Search Lane 1     |
     | (Interrogates SQ0..15)|                       | (Interrogates SQ0..15)|
     +-----------------------+                       +-----------------------+
                 |                                               |
                 +-----------------------+-----------------------+
                                         |
                                         v
                     +---------------------------------------+
                     | Forwarding / Conflict Resolution Logic |
                     | 1. Exact match on 8B word -> Forward  |
                     | 2. Partial / multi-store match -> Stall|
                     | 3. No match -> Access L1D Bank Array  |
                     +---------------------------------------+
```

#### Forwarding Invariants:
1. **Exact Word Forwarding**: If the youngest older store covering the load's address matches the load's byte lanes completely within an aligned 8-byte word, store data is forwarded directly in Stage M1. Cache access is canceled.
2. **Conservative Partial Overlap Stall**: If an older store partially overlaps the load's byte mask, or if multiple older stores touch different bytes of the load's word, store-to-load forwarding is bypassed and the load stalls until all overlapping stores drain to L1D.
3. **No Inter-Lane Forwarding Hazard**: In cycles where an older Store executes on Port 2 and a younger Load executes on Port 3, the store's physical address is calculated concurrently. The CAM search detects address overlap in Stage M1; if data is not yet available, the load stalls safely without data corruption.

### 7.3 Preservation of Memory Disambiguation Safety

The speculative execution safety invariant proven in Milestone 5 is strictly preserved across both execution lanes:
1. **Load Queue Lifetime Extension**: A load executed on either Port 2 or Port 3 **MUST remain allocated in the Load Queue** after writing its result to the PRF until:
   $$\text{older\_store\_checks\_complete}(load) \land (load == \text{ROB head})$$
2. **Older Store Disambiguation Check**:
   For any load $L$, $\text{older\_store\_checks\_complete}(L)$ is asserted if and only if every store marked in $L$'s dispatch snapshot `sq_older_mask` has resolved its physical address and verified that no address collision exists.
3. **Live-Epoch ROB Violation Qualification**:
   When an older store's physical address is resolved on Port 2, it CAM-snoops all active LQ entries. If a physical address collision is detected against an already-executed speculative load (issued from Port 2 or Port 3), `lsu_violation_valid_o` is pulsed with the target load's `rob_idx` and `rob_epoch`. The ROB latches `mem_violation` sticky and forces a pipeline rollback replay when the load reaches the ROB head.

---

## 8. Coherent Interconnect / Snoop Interface & Line Invalidation Protocol

### 8.1 Coherent Caching-Agent Boundary Specification
Milestone 7 provides a protocol-neutral **Coherent Caching-Agent Interface** compatible with TileLink-C / AXI-ACE style snoop/invalidation buses:

```
+===================================================================================================+
|                                COHERENT CACHING-AGENT BOUNDARY                                    |
+===================================================================================================+

    Core / L1D Subsystem                                Coherence Hub / Shared L2 Interconnect
   +--------------------+                              +---------------------------------------+
   |                    |--- bus_rd_req_valid_o ------>| AcquireBlock (Read Shared / Unique)   |
   |                    |<-- bus_rd_rsp_valid_i -------| GrantData (512-bit cache line refill) |
   |                    |                              |                                       |
   |                    |--- bus_wr_req_valid_o ------>| ReleaseData (Dirty victim writeback)  |
   |                    |<-- bus_wr_rsp_valid_i -------| ReleaseAck (Writeback completion)     |
   |                    |                              |                                       |
   |                    |<-- snoop_req_valid_i --------| Probe / Invalidate Channel             |
   |                    |--- snoop_req_ready_o ------->| (Address query & state downgrade)     |
   |                    |                              |                                       |
   |                    |--- snoop_rsp_valid_o ------->| ProbeAck / ProbeAckData               |
   |                    |    (unthrottled acceptance)  | (Dirty data return or clean ack)      |
   +--------------------+                              +---------------------------------------+
```

### 8.2 Snoop Request & Response Channel Definitions

```systemverilog
// -----------------------------------------------------------------------------
// External Coherence Snoop Channels
// -----------------------------------------------------------------------------
// Incoming Snoop Request from Interconnect
input  logic        snoop_req_valid_i,
input  logic [49:0] snoop_req_addr_i,     // PA[55:6] 64-byte line address
input  logic [1:0]  snoop_req_type_i,     // 2'b00: SNOOP_INV, 2'b01: SNOOP_READ, 2'b10: SNOOP_CLEAN_INV
output logic        snoop_req_ready_o,

// Outgoing Snoop Response to Interconnect (Unthrottled Acceptance)
output logic        snoop_rsp_valid_o,
output logic        snoop_rsp_has_data_o, // 1 = Dirty line returned
output logic [511:0]snoop_rsp_data_o,     // 64-byte payload
output logic        snoop_rsp_was_dirty_o
```
*Response Flow Control Invariant*: Because snoop queries are pull transactions dispatched by the coherence hub with pre-allocated response buffer slots, `snoop_rsp_valid_o` is **unthrottled**; the external interconnect guarantees immediate acceptance without backpressuring the core.

### 8.3 Snoop Collision, Invalidation & Memory Ordering Invariants

1. **L1D Tag Snooping**:
   - Incoming snoop requests check the register-based L1D tag arrays in parallel with pipeline accesses.
   - On `SNOOP_INV`: Matching cache line valid bit is cleared; if the line was dirty, an error is flagged unless preceded by a clean writeback.
   - On `SNOOP_READ` / `SNOOP_CLEAN_INV`: If the matching line is dirty, the dirty line is read out, passed to `snoop_rsp_data_o`, marked clean, and invalidated if requested.
2. **MSHR & WBB Snooping**:
   - If an incoming snoop targets a line currently in-flight in an MSHR, the refill buffer is marked invalidated to prevent installing stale data.
   - If an incoming snoop targets a dirty victim held in the Writeback Buffer (WBB), the WBB directly supplies the newest dirty data to `snoop_rsp_data_o`.
3. **Speculative Load Memory-Ordering Violation on External Invalidation (`SNOOP_INV` / `SNOOP_CLEAN_INV`)**:
   - If an external `SNOOP_INV` or `SNOOP_CLEAN_INV` invalidates a cache line that was read by an uncommitted speculative load currently residing in LQ16, a **coherence memory-ordering violation** has occurred (another hart modified or invalidated data that this hart speculatively consumed).
   - The LQ CAM marks the matching load `violated = 1'b1` and signals the ROB to force a pipeline squash and replay, strictly preserving sequential memory consistency (RVWMO).

---

## 9. Physical Design, Timing Discipline & SRAM Banking Model

### 9.1 SRAM Macro Banking Feasibility
- **Data Memory Macro Architecture**:
  The 16 KiB data cache is implemented using **4 independent single-port (1R/1W) 6T SRAM macros**:
  * Each 64-byte line contains 8 doublewords. Across 4 banks, each bank stores **2 doublewords per cache line** (selected by `PA[5]`).
  * Per-bank dimension: 64 sets $\times$ 4 ways $\times$ 2 doublewords = **512 entries of 64 bits = 32 Kbits = 4 KiB per bank**.
  * Total data storage across 4 banks: **$4 \times 4\text{ KiB} = 16\text{ KiB}$ (131,072 bits)**.
- **Tag Storage Implementation**:
  Implemented as flip-flop register arrays ($64\text{ sets} \times 4\text{ ways} \times 44\text{ bits} \approx 1.4\text{ KiB}$), identical to the M3/M5 baseline, providing multi-ported parallel read access for AGU0, AGU1, and external snoops.
- **Crossbar Routing**: A low-latency $2 \times 4$ read crossbar connects Port 2 and Port 3 AGU addresses to the 4 bank chip-selects. Since bank selection is purely a function of `PA[4:3]`, bank select decoding completes combinationally within the early AGU stage without cycle penalty.

### 9.2 Timing Closure Discipline
1. **No Inter-Bank Chaining**: Bank collision detection operates in parallel with SRAM access; if a collision is detected, the younger load's output data latch is gated, and a replay request is sent to the pipeline control logic.
2. **PRF Multi-Port Scaling**: Expanding the PRF from 6R3W to 7R4W (adding 1 read port and 1 write port) represents an estimated silicon area increase of approximately **12% to 15%** for the PRF macro, with minimal impact on read access latency.
3. **Strict Synchronous Boundary**: The coherence snoop interface is fully synchronous to `clk_i`. Asynchronous CDC logic, if required by an external system bus, belongs outside the core boundary in the SoC tile wrapper.

---

## 10. Verification & Validation Architecture

Milestone 7 mandates comprehensive verification covering unit testbenches, randomized stress torture, and integrated core profiling.

### 10.1 Mandatory 40 Properties Traceability Matrix

| Property ID | Subsystem | Formal Verification Intent | Provenance Suite |
| :--- | :--- | :--- | :--- |
| `PROP_M7_01` | Dual AGU | Port 2 and Port 3 issue two ready independent loads in the same cycle. | Phase A TB |
| `PROP_M7_02` | Dual AGU | Port 2 issues Store while Port 3 issues Load concurrently. | Phase A TB |
| `PROP_M7_03` | MemIQ16 | Store uop is never selected for issue on Port 3 (load-only restriction). | Phase A TB |
| `PROP_M7_04` | MemIQ16 | Oldest-ready uop strictly takes Port 2 when both ports are idle. | Phase A TB |
| `PROP_M7_05` | MemIQ16 | Port 2 backpressure holds Port 2 issue while Port 3 load proceeds. | Phase A TB |
| `PROP_M7_06` | MemIQ16 | Port 3 backpressure holds Port 3 issue while Port 2 issue proceeds. | Phase A TB |
| `PROP_M7_07` | MemIQ16 | AMO and FENCE operations issue strictly as singletons on Port 2. | Phase A TB |
| `PROP_M7_08` | PRF Read | PRF Read Port 6 correctly delivers AGU1 base address operand. | Phase A TB |
| `PROP_M7_09` | PRF Write | Concurrent writebacks on W2 and W3 update distinct destination registers. | Phase A TB |
| `PROP_M7_10` | ROB Comp | Dual completions on ports 2 and 3 retire in program order without drift. | Phase A TB |
| `PROP_M7_11` | L1D Bank | Dual loads hitting different banks complete concurrently in 1 cycle. | Phase B TB |
| `PROP_M7_12` | L1D Bank | Dual loads hitting identical bank and doubleword broadcast data in 1 cyc. | Phase B TB |
| `PROP_M7_13` | L1D Bank | Dual loads hitting same bank with distinct DWs: older uop wins by `rob_dist`, younger stalls. | Phase B TB |
| `PROP_M7_14` | L1D Bank | Store drain and load hitting different banks proceed concurrently. | Phase B TB |
| `PROP_M7_15` | L1D Bank | Store drain and load hitting same bank stalls load; store drain wins. | Phase B TB |
| `PROP_M7_16` | L1D Bank | Refill install updates lower 256b then upper 256b over 2 cycles; pipeline stalls 2 cyc. | Phase B TB |
| `PROP_M7_17` | L1D Bank | Sequential doubleword accesses across line boundary hit alternating banks.| Phase B TB |
| `PROP_M7_18` | L1D Bank | Sub-word accesses (Byte, Half, Word) correctly extract aligned bytes. | Phase B TB |
| `PROP_M7_19` | L1D Bank | Unaligned access raises alignment exception without corrupting banks. | Phase B TB |
| `PROP_M7_20` | L1D Bank | Cache clean-all (`FENCE.I`) purges dirty lines across all 4 banks. | Phase B TB |
| `PROP_M7_21` | LSQ Multi | Up to 2 loads allocate cleanly into LQ16 in a single dispatch cycle. | Phase C TB |
| `PROP_M7_22` | LSQ Multi | Simultaneous CAM search by Port 2 and Port 3 loads against all 16 SQ slots.| Phase C TB |
| `PROP_M7_23` | LSQ Multi | Exact word store-to-load forwarding succeeds concurrently on both lanes. | Phase C TB |
| `PROP_M7_24` | LSQ Multi | Partial overlap store-to-load forwarding stalls load until store drains. | Phase C TB |
| `PROP_M7_25` | LSQ Multi | Load executed on Port 3 remains valid in LQ until older stores resolve. | Phase C TB |
| `PROP_M7_26` | LSQ Multi | Resolving store flags violation on Port 3 load; ROB latches mem_violation. | Phase C TB |
| `PROP_M7_27` | LSQ Multi | Load deallocates at retirement without waiting for older stores to drain. | Phase C TB |
| `PROP_M7_28` | LSQ Multi | Replay-safe token suppresses speculative issue on replayed Port 3 load. | Phase C TB |
| `PROP_M7_29` | LSQ Multi | Full pipeline flush invalidates uncommitted loads across both lanes. | Phase C TB |
| `PROP_M7_30` | LSQ Multi | Branch mispredict rollback selectively squashes younger loads on both lanes.| Phase C TB |
| `PROP_M7_31` | Coherence | External `SNOOP_INV` against clean cache line invalidates valid bit in 1 cyc.| Phase D TB |
| `PROP_M7_32` | Coherence | External `SNOOP_READ` against dirty line returns 512b data on snoop_rsp. | Phase D TB |
| `PROP_M7_33` | Coherence | External `SNOOP_CLEAN_INV` invalidates line and returns dirty data. | Phase D TB |
| `PROP_M7_34` | Coherence | Snoop collision with active MSHR marks refill invalid; avoids stale install.| Phase D TB |
| `PROP_M7_35` | Coherence | Snoop collision with active WBB entry supplies dirty data from buffer. | Phase D TB |
| `PROP_M7_36` | Coherence | `SNOOP_INV` / `SNOOP_CLEAN_INV` matching speculative load in LQ triggers ROB replay. | Phase D TB |
| `PROP_M7_37` | Telemetry | HPM events `0x31`..`0x38` increment accurately on dual issue & bank conflict.| Phase D TB |
| `PROP_M7_38` | Telemetry | 8-category CPI cycle conservation $\sum_{k=0}^7 C_k == \Delta\text{mcycle}$ verified. | Phase D TB |
| `PROP_M7_39` | Multi-Seed | $\ge 100,000$ randomized dual-memory operations pass with 0 mismatches. | Torture Suite|
| `PROP_M7_40` | Workloads | 5 canonical profiling benchmarks run to clean completion with IPC gains. | Profiling Suite |

### 10.2 Hardware Performance Monitor (HPM) Telemetry Expansion
Milestone 7 reserves Event IDs `0x31` through `0x38` for multi-banked memory telemetry. The core event pulse bus `raw_event_pulse_o` is expanded from `[48:1]` to `[56:1]` across `fursoy_s1_hpm.sv` and `fursoy_s1_core.sv`:

| Event ID | Symbolic Name | Increment Qualification Point | Architectural Significance |
| :---: | :--- | :--- | :--- |
| `0x31` | `EV_MEM_DUAL_ISSUE` | MemIQ issue stage | Cycle where Port 2 and Port 3 both issue memory uops |
| `0x32` | `EV_L1D_BANK_ACCESS` | L1D access stage | Total bank accesses initiated across both load/store ports (0..3) |
| `0x33` | `EV_L1D_BANK_CONFLICT` | L1D conflict detect | Access stalled due to simultaneous request to identical bank |
| `0x34` | `EV_L1D_BANK_BROADCAST`| L1D access stage | Dual loads served simultaneously from identical doubleword |
| `0x35` | `EV_STORE_DRAIN_CONCURRENT`| L1D access stage| Store drained to L1D concurrently with load hitting another bank |
| `0x36` | `EV_SNOOP_QUERIES` | Snoop interface | External snoop request received and evaluated by L1D |
| `0x37` | `EV_SNOOP_HITS` | Snoop interface | External snoop hit matching tag in L1D, MSHR, or WBB |
| `0x38` | `EV_SNOOP_REPLAYS` | Load Queue CAM | External snoop invalidation triggered speculative load replay |

---

## 11. Milestone 7 Freeze Gates & Acceptance Criteria

Milestone 7 implementation will be considered complete and eligible for freezing when all the following verification gates are strictly satisfied:

- **Gate 11.1 (Architecture Definition Freeze)**:
  Authoritative specification `docs/architecture/slice1-m7-multibank-l1d-v1.md` passes independent adversarial review with zero open blockers (P0=0, P1=0, P2=0, P3=0).
- **Gate 11.2 (Predecessor Baseline Integrity)**:
  100% clean exit (code 0) across all predecessor regression runners:
  * `wsl python3 tools/run_s1_lint.py` (0 warnings, 0 errors across all production RTL files).
  * `wsl python3 tools/run_s1_substrate.py` (M1 substrate).
  * `wsl python3 tools/run_s1_m2.py` (M2 backend).
  * `wsl python3 tools/run_s1_m3.py` (M3 memory).
  * `wsl python3 tools/run_s1_m4.py` (M4 frontend).
  * `wsl python3 tools/run_s1_m5_b4.py` (M5 scheduling & performance).
  * `wsl python3 tools/run_s1_m6_closeout.py` (M6 branch prediction & frontend).
  * `wsl python3 tools/check_slice0.py` (Slice-0 contract integrity).
- **Gate 11.3 (Mandatory 40 Properties Proved)**:
  All 40 formal verification properties (`PROP_M7_01` through `PROP_M7_40`) pass with zero assertion failures.
- **Gate 11.4 (Multi-Seed Randomized Torture Gate)**:
  Cumulative randomized torture exceeding $\ge 100,000$ operations across canonical seeds (`42`, `20260920`, `20261009`) with zero mismatches against the cycle-accurate C++ golden memory model.
- **Gate 11.5 (CPI Conservation Law Assertion)**:
  Cycle conservation invariant $\sum_{k=0}^7 C_k == \Delta\text{mcycle}$ asserted across every simulation cycle without cycle leakage.
- **Gate 11.6 (Empirical Performance Verification)**:
  Execution of the 5 canonical profiling benchmarks demonstrates measurable microarchitectural gains in memory-bound kernels (`stream_memcpy`, `pointer_chasing`, `raw_stress`), with delta comparisons logged in `results/s1-m7-closeout.json`.
- **Gate 11.7 (RTL Manifest Freeze)**:
  Updated production RTL manifest SHA-256 computed and documented with zero uncommitted modifications.

---

## 12. Conclusion & Specification Sign-Off

Milestone 7 architectural specification v1.1 delivers the design blueprint for transitioning the Fursoy Slice-1 core from a single-AGU bottleneck to a dual-issue, banked memory execution engine. By doubling memory issue bandwidth, interleaving cache data across independent 64-bit banks with a 2-cycle multi-beat refill sequence, multi-porting load/store disambiguation CAMs, and providing a protocol-neutral coherent snoop interface, Milestone 7 directly addresses the primary execution stall source identified in Milestone 6 profiling.
