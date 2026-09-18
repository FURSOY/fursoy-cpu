# Fursoy Slice-1 Core Architecture Specification v1

**Document ID:** `docs/architecture/slice1-core-v1.md`  
**Status:** FROZEN CANONICAL SEMANTIC ARCHITECTURE v1 (Provisional Implementation Parameters Classified)  
**Target Core:** Fursoy Slice-1 (Single-Hart, 2-Wide Decode, Out-of-Order, RV64IMAZbaZbb, Sv39, RVA23 Foundation)  
**Predecessor Reference:** Fursoy Slice-0 (Frozen Baseline)

---

## 1. Architectural Scope & Design Discipline

Fursoy Slice-1 is a clean-slate 64-bit RISC-V out-of-order processor core designed as the foundational execution engine for a multi-core, Linux-capable server processor family.

The Slice-1 microarchitecture addresses the empirical bottlenecks measured in Slice-0:
1. **Severing the In-Order Single-Issue Ceiling**: Replaces the monolithic 2-stage (Fetch | Execute) pipeline with a decoupled, out-of-order execution core featuring 2-wide decode/rename/dispatch, 3 dedicated execution ports (maximum 3 uops/cycle issue), and 2-wide in-order retirement.
2. **Eliminating Memory Miss Serialization**: Replaces the single-outstanding Store Refill Buffer (SRB) with a non-blocking L1 data cache featuring multiple Miss Status Holding Registers (MSHRs) and a dedicated dirty-victim Writeback Buffer (WBB).
3. **Pipelining Arithmetic & Translation Resources**: Replaces the combinational divider (>91.5k LUT4s in Slice-0) with an independent multi-cycle iterative divider, and replaces the ripple-carry pseudo-LRU TLB with a split Base/Superpage TLB utilizing localized matrix PLRU.

---

## 2. Frozen Semantic Architecture

The following architectural structures and policies are **FROZEN SEMANTIC CONTRACTS**. Any conforming Slice-1 RTL implementation must adhere to these rules.

### 2.1 Pipeline Topology & Issue Width Terminology
The execution pipeline is structured into discrete conceptual stages:
$$\text{F1} \rightarrow \text{F2} \rightarrow \text{D} \rightarrow \text{RN} \rightarrow \text{DS} \rightarrow \text{IS} \rightarrow \text{RF} \rightarrow \text{EX} \rightarrow \text{M1/WB} \rightarrow \text{CMT}$$

```
+===================================================================================================+
|                               FURSOY SLICE-1 10-STAGE CONCEPTUAL PIPELINE                         |
+===================================================================================================+

  Stage:    [ F1 ]       [ F2 ]       [ D ]        [ RN ]       [ DS ]       [ IS ]       [ RF ]       [ EX ]       [ M1/WB ]    [ CMT ]
  Function: Next-PC      L1I SRAM     2-Wide       2-Wide       2-Wide       Issue Queue  PRF Read     ALU0/BR,     L1D Access,  2-Wide
            Branch Pred  Array Read   Decode,      Rename,      Dispatch     Wakeup,      Operand      ALU1/MULDIV, PRF Write,   In-Order
            ITLB Lookup  Way Select   Uop Gen      SRAT Alloc   ROB / IQ     Select       Bypass Mux   AGU Compute  Tag Match    Retire

  Bandwidth: 64 bits/cyc  64 bits/cyc  2 uops/cyc   2 uops/cyc   2 uops/cyc   <= 3 uops    <= 6 ops     3 uops peak  3 res peak   2 uops/cyc
```

- **Fetch Bandwidth**: 64 bits / cycle (delivers two 32-bit instructions or up to four compressed 16-bit instructions).
- **Decode Bandwidth**: 2 instructions / cycle into standardized internal micro-operations (`uops`).
- **Rename Bandwidth**: 2 uops / cycle allocating physical register destinations from the Free List.
- **Dispatch Bandwidth**: 2 uops / cycle allocated into the Reorder Buffer (ROB) and Issue Queues.
- **Execution Issue Bandwidth**: **Maximum 3 uops / cycle** issued across **3 dedicated execution ports**:
  - **Port 0**: ALU0 + Branch Resolution Unit.
  - **Port 1**: ALU1 + Pipelined Multiplier + Multi-Cycle Divider.
  - **Port 2**: Address Generation Unit (AGU) for Load / Store Unit (LSU).
- **Commit Bandwidth**: 2 uops / cycle retired in strict program order from the ROB head.

---

### 2.2 Register Renaming & Physical Register File (PRF)

#### 2.2.1 Unified PRF Architecture
- Physical registers are unified: values are written once to the PRF; the ROB maintains only instruction metadata, status tags, and exception flags.
- Register $p_0$ is hardwired to `0x0`, is permanently marked ready, and is never allocated from the Free List.
- **Baseline Numeric Dimensioning**: **80 physical registers** ($p_0 \dots p_{79}$).
  - *Mathematical Rationale*: 32 committed architectural registers (ARAT) + 48 maximum in-flight speculative destinations (ROB 48) = 80 registers. This establishes the structural invariant that **the Free List cannot be exhausted before the ROB fills**, eliminating cross-queue capacity deadlocks.

#### 2.2.2 Register Lifecycle & Allocation Semantics
$$\text{Free List} \xrightarrow{\text{Rename}} P_{\text{new}}\ (\text{Speculative Live}) \xrightarrow{\text{Execute}} P_{\text{new}}\ (\text{Ready}) \xrightarrow{\text{Commit}} P_{\text{new}}\ (\text{ARAT Committed}) \implies P_{\text{old}}\ \text{Freed Immediately}$$
1. At Rename, an instruction writing architectural destination $rd \ne x0$ pops $P_{\text{new}}$ from the Free List.
2. The current mapping of $rd$ in the Speculative RAT (SRAT) is recorded as $P_{\text{old}}$ in the instruction's ROB entry.
3. The SRAT is updated: $\text{SRAT}[rd] \leftarrow P_{\text{new}}$.
4. When the instruction commits at the ROB head:
   - The Architectural RAT updates: $\text{ARAT}[rd] \leftarrow P_{\text{new}}$.
   - $P_{\text{old}}$ ceases to be part of the committed architectural state and **is returned immediately and exactly once to the Free List**.
5. Instructions with destination $rd = x0$ map to $p_0$, allocate zero Free List entries, and generate zero Free List returns at commit.

#### 2.2.3 Physical Register Ownership Invariants
For all non-$p_0$ physical registers $p \in \{p_1, \dots, p_{\text{PRF}-1}\}$, the core maintains the following formal partition:
- Let $P_{\text{committed}} = \text{Range}(\text{ARAT}) \setminus \{p_0\}$.
- Let $P_{\text{displaced\_pending}} = \{ u.P_{\text{old}} \mid u \in \text{ROB}_{\text{active}}, u.rd \ne x0, u.P_{\text{old}} \ne p_0 \}$.
- Let $P_{\text{spec\_alloc}} = \{ u.P_{\text{new}} \mid u \in \text{ROB}_{\text{active}}, u.rd \ne x0 \}$.
- Let $P_{\text{free}} = \text{FreeList}$.

**Normative Invariants**:
1. **Mutual Exclusion**: The sets $P_{\text{committed}}$, $P_{\text{displaced\_pending}}$, $P_{\text{spec\_alloc}}$, and $P_{\text{free}}$ are pairwise disjoint, and their union equals $\{p_1, \dots, p_{\text{PRF}-1}\}$.
2. **Safety**: No physical register present in the Free List may be referenced by the ARAT, any valid SRAT checkpoint, or any active ROB destination field.
3. **Uniqueness**: Every valid destination-producing entry in the ROB owns exactly one allocated $P_{\text{new}}$ until commit or squash.
4. **Conservation**: Each $P_{\text{new}}$ is reclaimed exactly once on squash or transitions into committed ownership at commit; each committed instruction's displaced $P_{\text{old}}$ is freed exactly once at commit.

#### 2.2.4 Recovery Semantics & Arbitration Contract
1. **Branch Misprediction Recovery**:
   - The core transitions to an explicit `RECOVER` state.
   - Rename allocation is **strictly stalled**. The frontend redirects immediately, but subsequent instructions cannot allocate registers until recovery completes.
   - The SRAT is combinationally restored from the branch's checkpoint: $\text{SRAT} \leftarrow \text{SRAT}_{\text{chkpt}}$.
   - All instructions younger than the branch in the ROB, Issue Queues, LQ, and SQ are invalidated.
   - The recovery engine walks the squashed ROB slice backwards: for each squashed entry with $rd \ne x0$, its allocated $P_{\text{new}}$ is pushed back to the Free List at a fixed rate of **2 registers / cycle**.
   - **$P_{\text{old}}$ of squashed instructions is NEVER reclaimed**.
   - Architecturally older instructions in flight complete normally and are permitted to commit during recovery; their displaced $P_{\text{old}}$ registers return to the Free List via dedicated retirement free ports.
2. **Full Architectural Flush (Traps & Interrupts)**:
   - All speculative in-flight instructions are invalidated.
   - The SRAT is flash-restored from the ARAT: $\text{SRAT} \leftarrow \text{ARAT}$.
   - The Free List FIFO is deterministically reconstructed from the committed ARAT ownership ($P_{\text{free}} \leftarrow \{p \in [1, \text{PRF}-1] \mid p \notin \text{Range}(\text{ARAT})\}$).
   - Rename remains blocked until reconstruction completes. Exact reconstruction latency and scan bandwidth are implementation parameters.

---

### 2.3 Port 1 Writeback Arbitration Contract
Port 1 contains variable-latency execution resources whose completion cycles may coincide:
- **ALU1**: 1-cycle integer operations.
- **Pipelined Multiplier**: 3-cycle pipelined multiplication.
- **Iterative Divider**: Variable-latency multi-cycle division (8 to 34 cycles).

**Arbitration Requirement**:
- Port 1 execution units must interface to the Port 1 PRF writeback bus through a lossless arbiter with holding registers.
- **Initial Deterministic Priority Policy**:
  $$\text{Divider} > \text{Multiplier} > \text{ALU1}$$
- If a higher-priority unit completes in the same cycle as a lower-priority unit, the lower-priority result is captured in a holding register and granted the writeback port in the subsequent cycle. **Zero completions may be dropped**.

---

### 2.4 Branch Handling & Speculative Checkpoint Semantics
- **Resolution Point**: Conditional branches resolve their outcome in Stage `EX` on Port 0.
- **Recovery Sequence**:
  - Misprediction detection in `EX` signals the frontend redirect and initiates the `RECOVER` state.
  - Younger instructions are purged; SRAT is restored from the checkpoint.
  - Corrected instruction fetch proceeds in parallel, but rename allocation stalls until ROB squash reclamation terminates.
- **Checkpoint Exhaustion Contract**:
  - When all branch checkpoints are occupied, rename/dispatch stalls cleanly on subsequent conditional branches. Zero deadlock or speculative corruption is permitted.

---

### 2.5 Memory Subsystem: LSU Ordering, MSHR, WBB & Cache Semantics

#### 2.5.1 Conservative Load Issue & Forward Progress
- A load uop (`uop_load`) is eligible to issue from the Mem-IQ to the AGU/L1D if and only if **all older stores in the Store Queue have their physical addresses resolved**.
- **Disambiguation Rules**:
  1. *Exact Match*: Youngest older matching store forwards data to PRF (1-cycle forward latency).
  2. *Contained Match*: Sub-word extracted from store payload and forwarded to PRF.
  3. *No Overlap*: Load issues to L1D in parallel with older stores in SQ.
  4. *Partial Overlap / Unresolved Store Data*: Load stalls in Mem-IQ/LQ.
- **Forward Progress Guarantee**: Blocked loads wait in the Mem-IQ/LQ until the conflicting store commits from the ROB head and drains from the SQ into L1D. Once drained, the load issues as a standard cache hit, guaranteeing forward progress.

#### 2.5.2 Atomic Operations (AMO) and LR/SC
- **AMO Contract**:
  - Every AMO is decoded as a **single non-speculative micro-op** (`uop_amo`).
  - AMOs are strictly prohibited from issuing out-of-order. An AMO is held in Mem-IQ until it reaches the **head of the ROB** and the Store Queue is completely empty.
  - When at the ROB head, the AMO acquires cache-line atomicity, performs the read-modify-write in the L1D cache, writes the original memory value to the PRF, and commits.
  - AMOs never execute speculatively; AMOs never squash.
- **LR/SC Contract**:
  - `LR.W/D`: Dispatched as a specialized load; executes when older store addresses resolve; registers an architectural reservation on the exact physical address (56-bit PA) and width.
  - `SC.W/D`: Dispatched as a specialized store; **remains non-speculative**; executes strictly at the ROB head. If the reservation is valid, writes store data to L1D and writes `0` to PRF; if invalid, suppresses memory write and writes `1` to PRF.

#### 2.5.3 Non-Blocking L1D, MSHR & Writeback Buffer Semantics
- **Non-blocking L1D**: Supports hit-under-miss and multiple outstanding demand cache-line refills.
- **MSHR (Miss Status Holding Register)**:
  - Tracks outstanding demand miss line addresses to the lower memory hierarchy.
  - Merges secondary misses to the same 64-byte line without allocating new bus requests.
- **Writeback Buffer (WBB)**:
  - Captures dirty victim lines evicted from L1D during line refills.
  - Decouples demand refill acceptance from victim writeback: an incoming refill installs immediately into L1D, while the dirty victim drains asynchronously to L2/interconnect.
- **Backpressure**: When all MSHRs are full, subsequent load misses stall in Mem-IQ; when the WBB is full, refills requiring dirty evictions stall at the bus interface until a WBB entry drains.

#### 2.5.4 Cache Geometry & Synonym-Safety Requirement
- **Theorem**: For a VIPT cache with 4 KiB pages and 64-byte lines, the page offset contains 6 index bits (`VA[11:6]`).
  $$\text{Way Size} = \frac{\text{Capacity}}{\text{Associativity}} \le 4\ \text{KiB}\ (64\ \text{sets})$$
- **Normative Requirement**: Both L1I and L1D must adhere to a **synonym-safe VIPT geometry ($\text{Way Size} \le 4\ \text{KiB}$)** unless explicit architectural synonym-management hardware is introduced.
- A 32 KiB / 4-way VIPT configuration (128 sets, 8 KiB/way) is **NOT inherently synonym-safe** and is prohibited under the baseline VIPT contract for both L1I and L1D.

---

### 2.6 Split-TLB Organization & Translation Semantics
- **Base-Page TLB**: Dedicated to standard 4 KiB leaves. Set-associative structure with localized matrix PLRU per set (zero cross-set ripple chains).
- **Superpage TLB**: Dedicated to 2 MiB megadirectories and 1 GiB gigadirectories. Fully-associative CAM structure with round-robin or FIFO replacement.
- **Parallel Hit Query**: Both TLBs are looked up simultaneously in single-cycle hit time.
- **Required Correctness Semantics**:
  - Full Sv39 translation support: 4 KiB, 2 MiB, 1 GiB leaves.
  - ASID / global translation matching.
  - `SFENCE.VMA`: Selective invalidation by Virtual Address (`VA`) and/or Address Space ID (`ASID`).
  - `satp` modifications: Flushes translation state and cancels active in-flight PTW requests.
  - PMP Enforcement: Sequential 16-entry PMP permission checks evaluated on physical translation output.

---

### 2.7 Protocol-Neutral Coherent Cache Boundary
The L1D cache interfaces to the external memory subsystem via a **protocol-neutral coherent caching-agent boundary**:
- **Acquire Channel**: Core requests shared or exclusive cache line ownership from interconnect/L2.
- **Probe Channel**: Interconnect queries and/or invalidates local cached lines to maintain multi-core coherency.
- **Release Channel**: Core evicts dirty lines from WBB to L2/interconnect and acknowledges probe completion.
- **Grant Channel**: Interconnect returns refill data and grants ownership to MSHR.
- **Reservation Invalidation**: Coherent invalidations to a line holding an active LR/SC reservation clear the local reservation flag.
*(External bus protocol selection—such as TileLink-C or ACE—is deferred).*

---

### 2.8 Mandatory Initial ISA Scope
The mandatory baseline ISA for Fursoy Slice-1 comprises:
- **RV64I**: Base integer instruction set.
- **RV64M**: Hardware integer multiplication and division.
- **RV64A**: Standard atomic memory operations (AMOADD..MAX, LR/SC).
- **Zicsr**: Control and status register instructions.
- **Zifencei**: Instruction-fetch synchronization.
- **Zba**: Address generation instructions (`sh1add`, `sh2add`, `sh3add`).
- **Zbb**: Basic bit-manipulation instructions (`clz`, `ctz`, `cpop`, `min`, `max`, `rol`, `ror`, `sext.b/h`, `zext.h`).
- **Privilege Architecture**: Machine (M), Supervisor (S), and User (U) modes.
- **Sv39 MMU**: 3-level page table translation.
- **16-Entry PMP**: Physical memory protection.

*(All other extensions—including RVV Vector, H Virtualization, Floating-Point F/D, and Zicbo*—are excluded from the initial baseline).*

---

## 3. Master Parameter Classification Table

| Parameter / Subsystem | Architectural Specification | Master Classification |
|---|---|---|
| **Fetch Width** | 64 bits / cycle (2 standard instructions) | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Decode Width** | 2 instructions / cycle into micro-ops | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Rename Width** | 2 uops / cycle | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Dispatch Width** | 2 uops / cycle allocated to ROB & Schedulers | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Execution Issue Architecture** | Max 3 uops / cycle across 3 dedicated ports (Port 0, 1, 2) | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Commit Width** | 2 uops / cycle in-order retirement | **READY TO FREEZE — NUMERIC PARAMETER** |
| **ROB Capacity** | 48 entries, circular FIFO | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Integer PRF Capacity** | 80 physical registers ($p_0 \dots p_{79}$) | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Free List Recovery** | ROB-directed $P_{\text{new}}$ reclaim; checkpointed SRAT; `RECOVER` FSM | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Branch Checkpoint Semantics** | Snapshot SRAT only; stall dispatch on exhaustion | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Branch Checkpoint Depth** | 6 checkpoints (8 alternative candidate) | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Integer Issue Queue (Int-IQ)**| 16 entries (feeds Port 0 & Port 1) | **READY TO FREEZE — NUMERIC PARAMETER** |
| **Memory Issue Queue (Mem-IQ)** | 12 entries (feeds Port 2 AGU) | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Load Queue / Store Queue** | 16 entries LQ, 16 entries SQ | **READY TO FREEZE — NUMERIC PARAMETER** |
| **L1I Cache Architecture** | 64B line, physically tagged, macro-friendly, synonym-safe | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **L1I Capacity & Associativity**| 16 KiB 4-way (Baseline) / 32 KiB 8-way (Candidate) | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **L1D Cache Architecture** | 64B line, physically tagged, non-blocking, synonym-safe | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **L1D Capacity & Associativity**| 16 KiB 4-way (Baseline) / 32 KiB 8-way (Candidate) | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **MSHR Architecture** | Non-blocking demand miss tracking, secondary miss merge | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **MSHR Capacity** | 4 entries | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Writeback Buffer Architecture** | Decoupled dirty victim capture, asynchronous bus drain | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **WBB Capacity** | 2 entries | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **TLB Organization** | Split 4 KiB Base-TLB + Superpage-TLB, parallel query | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **TLB Capacities** | 64-entry Base (4-way, Matrix PLRU) + 8-entry Superpage | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Branch Predictor Architecture** | Decoupled BPU, speculative history recovery, BTB/RAS | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Branch Predictor Algorithm** | TAGE-lite (Candidate) / Bi-Mode (Alternative) | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **LSU Ordering Policy** | Conservative issue: all older store addresses resolved | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Store Forwarding Contract** | Exact & contained forward; partial overlap stalls to commit | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **AMO Execution Policy** | Single non-speculative uop serialized at ROB head | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **LR/SC Contract** | 56-bit PA reservation; SC non-speculative at ROB head | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Port 1 Writeback Arbitration** | Lossless holding arbiter; Priority: Divider > Mul > ALU1 | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **PRF Logical Port Interface** | Up to 6 read operands/cycle, up to 3 writeback results/cycle | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **PRF Physical Organization** | Banking / replication / staging implementation | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Pipeline Stage Sequence** | 10-stage conceptual sequence (`F1..F2..D..RN..DS..IS..RF..EX..M1/WB..CMT`)| **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Stage Fusion / Physical Depth** | Potential fusion of RF/EX or M1/WB based on STA | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Branch Redirect Penalty** | Dependent on implementation timing and queue occupancy | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Coherence Interface** | Protocol-neutral caching agent boundary (Acquire, Probe, Release)| **READY TO FREEZE — SEMANTIC CONTRACT** |
| **External Coherence Protocol** | TileLink-C, ACE, or custom bus protocol | **PROVISIONAL IMPLEMENTATION PARAMETER** |
| **Mandatory Initial ISA** | RV64IMA + Zicsr + Zifencei + Zba + Zbb + Sv39 + 16-entry PMP | **READY TO FREEZE — SEMANTIC CONTRACT** |
| **Vector / Hypervisor / FP** | Interfaces reserved; RTL omitted from initial core | **REMOVED (From Initial Slice-1)** |

---

## 4. Architectural Summary

The canonical Slice-1 microarchitecture baseline is established with complete functional specifications:
1. **P1-1 (PRF Sizing)**: PRF = 80 frozen based on the mathematical no-exhaustion bound for ROB 48.
2. **P1-2 (Queue Model)**: Claims realigned to structural dispatch throughput; application IPC claims retracted.
3. **P1-3 (Free List Recovery)**: Specified exact FSM gating, $P_{\text{new}}$ squash reclamation, and immediate $P_{\text{old}}$ commit return.
4. **P1-4 (MSHR/WBB)**: Semantic separation frozen; exact capacities classified as provisional.
5. **P2/P3 Mechanical Corrections**: Corrected issue bandwidth to maximum 3 uops/cycle across 3 ports; replaced scalar Free List invariant with formal set partition invariants; de-scoped full-flush cycle counts; recorded Port 1 writeback arbitration (Divider > Multiplier > ALU1); corrected L1I synonym-safety derivation; preserved protocol-neutral coherence boundary.
