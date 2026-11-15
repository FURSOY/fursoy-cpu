# Fursoy Slice-1 Core Architecture Specification v1

- **Document ID:** `docs/architecture/slice1-core-v1.md`
- **Status:** CANONICAL SEMANTIC ARCHITECTURE v1 (Synced to Implemented Stage 3 / M8–M9 RTL; M2/M5 Baseline Noted)
- **Target Core:** Fursoy Slice-1 (Single-Hart, 2-Wide Fetch/Decode/Retire, 5-Port Out-of-Order Execution, `RV64IMAFDV + Zba + Zbb + Zicsr + Zifencei`, Sv39)
- **Predecessor Reference:** Fursoy Slice-0 (Frozen Baseline)

---

## 1. Architectural Scope & Design Discipline

Fursoy Slice-1 is a clean-slate 64-bit single-core RISC-V out-of-order processor designed as a Linux-capable execution engine with an extensible external cache-coherence boundary.

The Slice-1 microarchitecture addresses the empirical bottlenecks measured in Slice-0:
1. **Severing the In-Order Single-Issue Ceiling**: Replaces the monolithic 2-stage (Fetch | Execute) pipeline with a decoupled, out-of-order execution core featuring 2-wide fetch/decode/rename/dispatch, **5 decoupled scalar execution ports** (up to 5 scalar operations/cycle peak across 2 integer, 2 memory, and 1 FP port, expanded from the initial M2/M5 3-port baseline), an 8-entry sequential RVV execution queue (`vecq_q[8]`), and 2-wide in-order retirement.
2. **Eliminating Memory Miss Serialization**: Replaces the single-outstanding Store Refill Buffer (SRB) with a non-blocking, 8-bank (`PA[5:3]`) L1 data cache featuring multiple Miss Status Holding Registers (MSHRs) and a dedicated dirty-victim Writeback Buffer (WBB).
3. **Pipelining Arithmetic & Translation Resources**: Replaces the combinational divider (>91.5k LUT4s in Slice-0) with an independent multi-cycle iterative Radix-4 divider, and replaces the ripple-carry pseudo-LRU TLB with split 64-entry Base + 8-entry Superpage TLBs utilizing localized Tree-PLRU.

---

## 2. Frozen Semantic Architecture

The following architectural structures and policies are **FROZEN SEMANTIC CONTRACTS**. Any conforming Slice-1 RTL implementation must adhere to these rules.

### 2.1 Pipeline Topology & Issue Width Terminology
The execution pipeline is structured into discrete conceptual stages:
$$\text{F1} \rightarrow \text{F2} \rightarrow \text{D} \rightarrow \text{RN} \rightarrow \text{DS} \rightarrow \text{IS} \rightarrow \text{RF} \rightarrow \text{EX} \rightarrow \text{M1/WB} \rightarrow \text{CMT}$$

```text
+===================================================================================================+
|                               FURSOY SLICE-1 10-STAGE CONCEPTUAL PIPELINE                         |
+===================================================================================================+

  Stage:    [ F1 ]       [ F2 ]       [ D ]        [ RN ]       [ DS ]       [ IS ]       [ RF ]       [ EX ]          [ M1/WB ]    [ CMT ]
  Function: Next-PC      L1I SRAM     2-Wide       2-Wide       2-Wide       Issue Queues PRF Read     P0:ALU0/BR/CSR  8-Bank L1D   2-Wide
            TAGE-Lite    Array Read   Decode,      Rename,      Dispatch     Wakeup,      Operand      P1:ALU1/MUL/DIV PRF Write,   In-Order
            ITLB Lookup  Way Select   Uop Gen      SRAT Alloc   ROB / IQs    Select       Bypass Mux   P2/P3:AGU0/1    Tag Match    Retire
                                                                                                       P4:FMA/FDIV/FCV (+ vecq_q)

  Bandwidth: 64 bits/cyc 64 bits/cyc  2 uops/cyc   2 uops/cyc   2 uops/cyc   <= 5 scalar  Port-fed     5 scalar peak   Multi-port   2 uops/cyc
```

- **Fetch Bandwidth**: 64 bits / cycle (delivers two 32-bit instructions per fetch block; no compressed `C` extension).
- **Decode Bandwidth**: 2 instructions / cycle into standardized internal micro-operations (`uops`).
- **Rename Bandwidth**: 2 uops / cycle allocating physical register destinations from the Free List.
- **Dispatch Bandwidth**: 2 uops / cycle allocated into the Reorder Buffer (ROB) and Issue Queues.
- **Execution Issue Bandwidth**: Up to **5 scalar operations / cycle** peak across **5 decoupled scalar issue ports** (expanded from the initial M2/M5 3-port baseline `Port 0–2`), plus sequential fetched-RVV execution:
  - **Port 0 (`IntIQ`)**: `ALU0` (1c Kogge-Stone) + Branch Resolution Unit (1c, max 1 branch/cycle) + System/CSR + `int2fp` dispatch.
  - **Port 1 (`IntIQ`)**: `ALU1` (1c via `alu1_fifo`) + 3-stage Pipelined Multiplier + Iterative Radix-4 Divider (`~34c`).
  - **Port 2 (`MemIQ` / `AGU0`)**: Address Generation Unit for Loads, Stores, AMOs, and `FENCE`/`FENCE.I`.
  - **Port 3 (`MemIQ` / `AGU1`)**: Second Address Generation Unit for Loads only (enabling 2 loads/cycle or 1 load + 1 store AGU/cycle across 8 L1D banks).
  - **Port 4 (`FPIQ`)**: Scalar Floating-Point `FMA` (3c FP32 / 4c FP64) + non-blocking Radix-4 `FDIV/FSQRT` (12–28c) + `FCONV/FCMP`.
  - **Vector Path (`vecq_q[8]`)**: Fetched `RVV 1.0` instructions execute sequentially in an 8-entry core FIFO FSM over `48 × 256-bit` 4-banked `VRF` (with standalone dual-lane `VIQ8` RTL verified via dedicated testbench harness ports).
- **Commit Bandwidth**: 2 uops / cycle retired in strict program order from the ROB head.

---

### 2.2 Register Renaming & Physical Register File (PRF)

#### 2.2.1 Unified PRF Architecture
- Physical registers are unified: scalar integer values are written once to the Integer PRF; the ROB maintains only instruction metadata, epoch/status tags, and exception flags.
- Register $p_0$ is hardwired to `0x0`, is permanently marked ready, and is never allocated from the Free List.
- **Implemented Numeric Dimensioning**: **`160` integer physical registers** ($p_0 \dots p_{159}$) paired with a **`128`-entry ROB** (`ROB_DEPTH = 128`), plus dedicated **`64` FP physical registers** ($fp_0 \dots fp_{63}$) and **`48 × 256-bit` physical vector registers** (`VRF`).
  - *Mathematical Rationale*: `32` committed architectural integer registers (ARAT) + `128` maximum in-flight speculative destinations (`ROB_DEPTH = 128`) = `160` registers. This preserves the structural invariant that **the Free List cannot be exhausted before the ROB fills**, eliminating cross-queue capacity deadlocks. (Earlier M2–M5 milestones started at `80` integer PRFs for a `48`-entry ROB before Stage 2/3 PPA/IPC expansion to `160` PRFs and `128` ROB entries.)

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
- Let $P_{\text{displaced}} = \{ u.P_{\text{old}} \mid u \in \text{ROB}_{\text{active}}, u.rd \ne x0, u.P_{\text{old}} \ne p_0 \}$.
- Let $P_{\text{spec}} = \{ u.P_{\text{new}} \mid u \in \text{ROB}_{\text{active}}, u.rd \ne x0 \}$.
- Let $P_{\text{free}} = \text{FreeList}$.

**Normative Invariants**:
1. **Mutual Exclusion**: The sets $P_{\text{committed}}$, $P_{\text{displaced}}$, $P_{\text{spec}}$, and $P_{\text{free}}$ are pairwise disjoint, and their union equals $\{p_1, \dots, p_{\text{PRF}-1}\}$.
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
- **Base-Page TLB**: Dedicated `64`-entry 4-way set-associative structure (`16` sets × `4` ways) for standard 4 KiB leaves with localized Tree-PLRU replacement per set (single-port ITLB, dual-port DTLB).
- **Superpage TLB**: Dedicated `8`-entry fully-associative CAM structure for 2 MiB megadirectories and 1 GiB gigadirectories.
- **Parallel Hit Query**: Both TLBs are looked up simultaneously in single-cycle hit time.
- **Required Correctness Semantics**:
  - Full Sv39 translation support: 4 KiB, 2 MiB, 1 GiB leaves.
  - ASID / global translation matching.
  - `SFENCE.VMA`: Selective invalidation by Virtual Address (`VA`) and/or Address Space ID (`ASID`), paired with Store Queue drain and L1D clean synchronization.
  - `satp` modifications: Flushes translation state and cancels active in-flight PTW requests.

---

### 2.7 Protocol-Neutral Coherent Cache Boundary
The L1D cache interfaces to the external memory subsystem via a **protocol-neutral coherent caching-agent boundary**:
- **Acquire Channel**: Core requests shared or exclusive cache line ownership from interconnect/L2.
- **Probe Channel**: Interconnect queries and/or invalidates local cached lines to maintain external cache coherency.
- **Release Channel**: Core evicts dirty lines from WBB to L2/interconnect and acknowledges probe completion.
- **Grant Channel**: Interconnect returns refill data and grants ownership to MSHR.
- **Reservation Invalidation**: Coherent invalidations to a line holding an active LR/SC reservation clear the local reservation flag.
*(Implemented SoC integration uses the internal 5-to-1 priority crossbar in `fursoy_s1_soc`; external coherence bus protocol selection—such as TileLink-C or ACE—remains decoupled).*

---

### 2.8 Implemented ISA Scope
The implemented ISA for Fursoy Slice-1 comprises:
- **RV64I**: Base integer instruction set.
- **RV64M**: Hardware integer multiplication and division.
- **RV64A**: Standard atomic memory operations (AMOADD..MAX, LR/SC).
- **RV64FD**: Single- and double-precision IEEE-754 scalar floating-point extensions (added in Milestone 8).
- **RVV 1.0 (`V`)**: Vector extension (`VLEN = 256`, `ELEN = 64`; added in Milestone 8).
- **Zicsr**: Control and status register instructions.
- **Zifencei**: Instruction-fetch synchronization.
- **Zba**: Address generation instructions (`sh1add`, `sh2add`, `sh3add`, and `.uw` variants).
- **Zbb**: Basic bit-manipulation instructions (`clz`, `ctz`, `cpop`, `min`, `max`, `rol`, `ror`, `sext.b/h`, `zext.h`, `andn`/`orn`/`xnor`, `orc.b`, `rev8`).
- **Privilege Architecture**: Machine (M), Supervisor (S), and User (U) modes (`medeleg`/`mideleg`, `MRET`/`SRET`, `WFI`).
- **Sv39 MMU**: 3-level page table translation (`4 KiB` / `2 MiB` / `1 GiB`).

*(Earlier M1–M7 milestones implemented `RV64IMA + Zicsr + Zifencei + Zba + Zbb` prior to Milestone 8 addition of `F`, `D`, and `V`. `C` Compressed, `H` Hypervisor, and `Zicbo*` remain out of scope.)*

---

## 3. Master Parameter Classification Table

| Parameter / Subsystem | Architectural Specification (Implemented RTL) | Master Classification |
|---|---|---|
| **Fetch Width** | 64 bits / cycle (two 32-bit instructions) | **FROZEN — NUMERIC PARAMETER** |
| **Decode Width** | 2 instructions / cycle into micro-ops | **FROZEN — NUMERIC PARAMETER** |
| **Rename Width** | 2 uops / cycle | **FROZEN — NUMERIC PARAMETER** |
| **Dispatch Width** | 2 uops / cycle allocated to ROB & Schedulers | **FROZEN — NUMERIC PARAMETER** |
| **Execution Issue Architecture** | Up to 5 scalar ops / cycle across 5 decoupled ports (`P0–P1` Int, `P2–P3` Mem/AGU, `P4` FP) + `8`-entry fetched RVV FSM (expanded from M2/M5 3-port baseline `P0–P2`) | **FROZEN — NUMERIC PARAMETER** |
| **Commit Width** | 2 uops / cycle in-order retirement | **FROZEN — NUMERIC PARAMETER** |
| **ROB Capacity** | `128` entries (`ROB_DEPTH = 128`), circular FIFO with 4-bit epoch tags (expanded in Stage 3 from M2/M5 `48`-entry baseline) | **FROZEN — NUMERIC PARAMETER** |
| **Integer PRF Capacity** | `160` physical registers (`PRF_SIZE = 160`: $p_0 \dots p_{159}$, `32` arch + `128` Free List; expanded in Stage 2 from M2/M5 `80`-entry baseline) | **FROZEN — NUMERIC PARAMETER** |
| **FP & Vector Register Files** | `64 × 64b` FP PRF (`32` arch + `32` free); `48 × 256b` 4-banked `VRF` | **FROZEN — NUMERIC PARAMETER** |
| **Free List Recovery** | ROB-directed $P_{\text{new}}$ reclaim; checkpointed SRAT; `RECOVER` FSM | **FROZEN — SEMANTIC CONTRACT** |
| **Branch Checkpoint Semantics** | Snapshot SRAT/GHR/RAS; stall dispatch on exhaustion | **FROZEN — SEMANTIC CONTRACT** |
| **Branch Checkpoint Depth** | `8` checkpoints (`NUM_CHECKPOINTS = 8`) | **FROZEN — NUMERIC PARAMETER** |
| **Integer Issue Queue (Int-IQ)**| `32` entries (`INT_IQ_DEPTH = 32`, feeds `P0` & `P1`; expanded in Stage 3 from M2/M5 `16`-entry baseline) | **FROZEN — NUMERIC PARAMETER** |
| **Memory Issue Queue (Mem-IQ)** | `32` entries (`MEM_IQ_DEPTH = 32`, feeds `P2 AGU0` & `P3 AGU1`; expanded in Stage 3 from M2/M5 `12`/`16`-entry baseline) | **FROZEN — NUMERIC PARAMETER** |
| **FP & Vector Execution Queues** | `16`-entry `FPIQ` (feeds `P4`); `8`-entry fetched RVV FIFO `vecq_q[8]` in `fursoy_s1_core` (standalone `VIQ8` module in testbench harness) | **FROZEN — NUMERIC PARAMETER** |
| **Load Queue / Store Queue / TRT** | `16`-entry `LQ`, `16`-entry `SQ`, `32`-entry `TRT` | **FROZEN — NUMERIC PARAMETER** |
| **L1I Cache Architecture** | `16 KiB` 4-way VIPT (`64` sets × `64 B`), Next-Line Prefetcher, `2` I-MSHRs | **FROZEN — SEMANTIC & GEOMETRY CONTRACT** |
| **L1D Cache Architecture** | `16 KiB` 4-way VIPT (`64` sets × `64 B`), `8`-bank (`PA[5:3]`), non-blocking | **FROZEN — SEMANTIC & GEOMETRY CONTRACT** |
| **MSHR Architecture** | Non-blocking demand miss tracking, secondary miss merge | **FROZEN — SEMANTIC CONTRACT** |
| **MSHR / WBB Capacity** | `4` L1D MSHRs, `2`-entry Writeback Buffer (`WBB`) | **FROZEN — NUMERIC PARAMETER** |
| **TLB Organization** | Split 4 KiB Base-TLB + Superpage-TLB, parallel query | **FROZEN — SEMANTIC CONTRACT** |
| **TLB Capacities** | `64`-entry 4-way Base (Tree-PLRU) + `8`-entry Superpage CAM (`ITLB` single-port, `DTLB` dual-port) | **FROZEN — NUMERIC PARAMETER** |
| **Branch Predictor Architecture** | `512`-entry 2-way BTB + `TAGE-Lite` (`30,208b`, `108`-bit GHR) + `16`-entry RAS | **FROZEN — IMPLEMENTED PARAMETER** |
| **LSU Ordering Policy** | Conservative issue: all older store addresses resolved | **FROZEN — SEMANTIC CONTRACT** |
| **Store Forwarding Contract** | Exact & contained forward; partial overlap stalls to commit | **FROZEN — SEMANTIC CONTRACT** |
| **AMO Execution Policy** | Single non-speculative uop serialized at ROB head | **FROZEN — SEMANTIC CONTRACT** |
| **LR/SC Contract** | 56-bit PA reservation; SC non-speculative at ROB head | **FROZEN — SEMANTIC CONTRACT** |
| **Port 1 Writeback Arbitration** | Lossless holding arbiter; Priority: Divider > Mul > ALU1 | **FROZEN — SEMANTIC CONTRACT** |
| **Stage Sequence** | Conceptual 10-stage sequence (`F1..F2..D..RN..DS..IS..RF..EX..M1/WB..CMT`) | **FROZEN — SEMANTIC CONTRACT** |
| **Coherence Interface** | Protocol-neutral caching agent boundary (Acquire, Probe, Release) | **FROZEN — SEMANTIC CONTRACT** |
| **Implemented ISA Scope** | `RV64IMAFDV + Zba + Zbb + Zicsr + Zifencei + Sv39` (`F/D/V` added in M8; `C`/`H`/`Zicbo*` excluded) | **FROZEN — SEMANTIC CONTRACT** |

---

## 4. Architectural Summary

The canonical Slice-1 microarchitecture specification aligns with the verified Stage 3 / M8–M9 RTL:
1. **P1-1 (PRF Sizing)**: Expanded from the initial M2–M5 `PRF = 80 / ROB = 48` baseline to **`PRF = 160` / `ROB = 128`** (preserving the exact `32` ARAT + `128` Free List no-exhaustion invariant), supplemented by `FPRF = 64` and `VRF = 48`.
2. **P1-2 (Queue Model)**: Structural dispatch throughput and analytical queue modeling guided Stage 2/3 scaling (`IntIQ = 32`, `MemIQ = 32`, `FPIQ = 16`, `NUM_CHECKPOINTS = 8`).
3. **P1-3 (Free List Recovery)**: Specified exact FSM gating, $P_{\text{new}}$ squash reclamation, and immediate $P_{\text{old}}$ commit return.
4. **P1-4 (MSHR/WBB & Banking)**: Semantic separation frozen with `4` MSHRs, `2` WBB entries, and `8`-bank (`PA[5:3]`) L1D.
5. **Issue Port & Translation Convergence**: Initial M2–M5 3-port execution expanded to `5` decoupled scalar issue ports (`P0–P1` Int, `P2–P3` dual-AGU Mem, `P4` scalar FP) + sequential fetched RVV (`vecq_q[8]`), backed by split `64`-entry 4-way Base + `8`-entry Superpage ITLB/DTLBs.
