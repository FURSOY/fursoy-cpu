# Slice-0 L1D Store Refill Buffer (SRB) Architectural Contract — v1

Status: **ACCEPTED AND FROZEN BASELINE — UNRECOVERABLE-ERROR TERMINOLOGY NORMALIZED TO THE COMMON STICKY FATAL-HALT CONTRACT; THAT NARROW L1D-ER AMENDMENT REMAINS PENDING FOCUSED RE-REVIEW**  
Normative Baselines:
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 (RV64I base, "Zifencei" Instruction-Fetch Fence, "A" Standard Extension for Atomicity v2.1)
- RISC-V Memory Consistency Model (RVWMO)
- `docs/architecture/l1d-cache-v1.md` (Frozen L1 Data Cache v1 contract)
- `docs/architecture/store-buffer-v1.md` (Frozen Store Buffer v1 contract)
- `docs/architecture/pipeline-s0-v1.md` (Frozen Slice-0 2-stage F | E in-order pipeline contract)
- `docs/architecture/l1i-cache-v1.md` (Frozen L1 Instruction Cache v1 contract)
- `docs/architecture/sv39-tlb-v1.md` (Frozen Sv39 TLB v1 contract)
- `docs/architecture/sv39-mmu-v1.md` (Frozen Sv39 MMU & PTW contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection contract)
- `docs/architecture/rv64a-v1.md` (Frozen RV64A Atomic Extension contract)
- `results/perf-sb-s0.json` (Post-Store-Buffer Bottleneck Profiling telemetry)

---

## 1. Authority, Scope, and Design Objectives

### 1.1 Purpose and Measured Motivation
This document defines the normative architectural contract for the hardware **L1D Store Refill Buffer (SRB)** subsystem for the single-hart Fursoy Slice-0 processor.

The Post-Store-Buffer observational performance measurement and bottleneck profiling pass (`results/perf-sb-s0.json`) established that while the 4-entry Store Buffer eliminated **1,951,974 cycles** of direct store retirement stalls (a 41.06% reduction in the store stall pool), a substantial stall migration occurred:
- **Single-port L1D load arbitration stalls surged to 4,015,726 cycles** (**14.547% of total execution time**; 31.72% of all non-retirement stall cycles).
- **Physical Dynamics**:
  - The Store Buffer completed 2,372,092 drain operations.
  - While 99.90% of drain operations were L1D cache hits, the remaining **179,244 store misses** (14,060 clean misses and 165,184 dirty misses) locked the single-ported L1D cache array for the entire duration of victim eviction and line refill (**28–40 cycles per dirty store miss**).
  - During these store-miss refill intervals, Stage-E loads were completely blocked from querying the L1D array, creating massive load arbitration backpressure.
  - Furthermore, subsequent stores accumulated in the 4-entry Store Buffer, causing **2,801,942 cycles** of Store Buffer full backpressure stalls (10.150% of total cycles).

The objective of the Store Refill Buffer (SRB) is to decouple off-core DRAM store miss handling from the on-core L1D tag and data arrays. By offloading dirty victim writeback, DRAM line refill, and store data merging into a dedicated, single-entry background buffer, the L1D cache remains available to service hits for independent Stage-E loads.

### 1.2 Architectural Review Outcome (SRB-v1)
The initial SRB-v1 architecture proposal underwent independent architectural review and
received 3 P0 and 4 P1 findings. Those findings were corrected; subsequent independent
review accepted the implemented SRB-v1 milestone, which is now the frozen baseline
recorded in `results/perf-srb-s0.json`.

This document incorporates all mandatory architectural corrections:
1. **P0-1 (Atomic Victim Invalidation)**: Selected victim way invalidated in L1D array at the exact capture edge; way is permanently unhittable from capture through install.
2. **P0-2 (Static Victim Ownership)**: Set index and victim way latched into SRB at capture; installation targets exact latched way without PLRU re-evaluation; PLRU updated only at installation.
3. **P0-3 (SB Drain Mutual Exclusion)**: Store Buffer drains strictly suspended while `srb_busy`; exact ownership transfer of drained store into SRB defined.
4. **P1-1 (Dual-Source RAW Detection)**: Full-line RAW hazard detection against SRB line (`load_pa[55:6] == srb_line_pa[55:6]`) added in parallel with SB doubleword RAW checks.
5. **P1-2 (Unconditional Installation Priority)**: Removed proposed 2-cycle starvation counter; SRB installation receives unconditional 1-cycle L1D array priority immediately upon refill readiness; Stage-E loads incur at most a 1-cycle bubble.
6. **P1-3 (Late Error Contract)**: Background DRAM bus errors during SRB eviction/refill defined as asynchronous platform fatal errors; synchronous exception generation on retired stores strictly forbidden.
7. **P1-4 (Serialization, Maintenance, and Dirty Accounting)**: Strict mutual exclusion and completion predicates established for LR, SC, AMO, FENCE, FENCE.I, SFENCE.VMA, PMP CSR writes, traps, interrupts, maintenance flushes, and reset.

### 1.3 Non-Goals and Explicit Restrictions
- **No Non-Blocking Loads**: Loads that miss in L1D remain strictly synchronous and stall Stage E until refill completes.
- **No Multi-Line Allocation**: The SRB is strictly a single-entry buffer handling exactly one active store miss.
- **No Store Buffer In-Flight Bypass**: The SRB services exclusively the head of the Store Buffer (`sb_head`), never uncommitted Stage-E stores.
- **No Speculative Execution**: Only architecturally committed, retired stores that have drained from the Store Buffer can enter the SRB.
- **No Hardware Cache Coherence**: Slice-0 remains a single-hart system without external snoop intervention.

---

## 2. Hardware Architecture and Storage Organization

### 2.1 Subsystem Topology
The SRB resides structurally between the Store Buffer drain port, the L1D tag/data arrays, and the shared DRAM interconnect:

```
[Stage E Load] ----------------------------------+
                                                 | (L1D Port Arbiter)
[Store Buffer (4-entry)] ---> [Drain Head] ---> [L1D Array: 16 KiB, 4-Way]
                                     |                   ^
                              (Store Miss)               | (1-Cycle Install)
                                     v                   |
                          +------------------------------+----+
                          |    Store Refill Buffer (SRB)      |
                          |  - Static Target Way & Set        |
                          |  - 64B Victim Eviction Buffer     |
                          |  - 64B Refill Line Buffer         |
                          |  - Merged Store Payload & Mask    |
                          +-----------------------------------+
                                     |                   ^
                               (DRAM Burst)        (DRAM Burst)
                                     v                   |
                          +-----------------------------------+
                          |      Physical DRAM Interconnect   |
                          +-----------------------------------+
```

### 2.2 Register and Payload Specification
The SRB maintains the following physical register fields:

| Field Name | Bit Width | Description |
| :--- | :---: | :--- |
| `srb_busy` | 1 bit | Active status flag. Asserted on capture; deasserted at the conclusion of installation. |
| `srb_line_pa[55:6]` | 50 bits | Base physical line address (64-byte aligned) of the missing store. |
| `srb_set[5:0]` | 6 bits | Latched L1D set index (`0 ... 63`) targeted by the missing store. |
| `srb_way[1:0]` | 2 bits | Latched L1D victim way (`0 ... 3`) selected by Tree-PLRU at the capture cycle. |
| `srb_victim_dirty` | 1 bit | Latched dirty status of the victim line. |
| `srb_victim_tag[43:0]` | 44 bits | Latched physical tag of the victim line, used to form DRAM writeback address. |
| `srb_victim_data[511:0]`| 512 bits | 64-byte data buffer holding the victim line for DRAM writeback. |
| `srb_refill_data[511:0]`| 512 bits | 64-byte data buffer accumulating 8 beats of DRAM refill data. |
| `srb_word_offset[5:3]` | 3 bits | Doubleword offset of the store within the 64-byte line. |
| `srb_store_data[63:0]` | 64 bits | Store data payload drained from the Store Buffer. |
| `srb_store_mask[7:0]` | 8 bits | Byte-enable mask drained from the Store Buffer. |
| `srb_beat_count[2:0]` | 3 bits | Counter tracking beats (`0 ... 7`) during DRAM eviction and refill bursts. |

---

## 3. Normative Microarchitectural Mechanics

### 3.1 P0-1: Atomic Victim Invalidation at Capture
When a Store Buffer drain request queries L1D and determines a cache miss:
1. **Selection**: The L1D Tree-PLRU logic evaluates the current 3-bit PLRU state for `set = store_pa[11:6]` and identifies victim way `W ∈ [0, 3]`.
2. **Atomic Invalidation**: On the **exact clock edge** where L1D asserts `srb_capture`:
   - The victim line's valid bit in the L1D tag array is cleared:
     `l1d_valid_array[store_pa[11:6]][W] ← 1'b0`
   - The victim line's dirty bit in the L1D tag array is cleared:
     `l1d_dirty_array[store_pa[11:6]][W] ← 1'b0`
3. **Victim Invisibility Guarantee**:
   - Throughout the entire duration where `srb_busy == 1`, way `W` of that set is marked invalid.
   - Subsequent loads querying this set will observe way `W` as invalid. It cannot hit under any circumstances.
   - If a load queries this set and hits another way (`W' ≠ W`), the load hits normally and returns in 1 cycle.
   - If a load queries this set and misses all remaining valid ways, the load detects an L1D miss. However, because `srb_busy == 1`, the load stalls Stage E and cannot allocate a refill until the SRB completes.

### 3.2 P0-2: Static Victim Ownership and PLRU Preservation
1. **Static Latching**:
   - At the capture clock edge, the set index and victim way are permanently latched:
     `srb_set ← store_pa[11:6], srb_way ← W`
2. **Immutable Target**:
   - During the 28–40 cycles of background DRAM activity, Stage-E loads may query the same set, hit other ways (`W'`), and update the set's PLRU state.
   - **Normative Rule**: Under no circumstances shall PLRU be re-evaluated or queried during or at the conclusion of the refill.
   - When the refill completes, the installation write is directed **strictly and unconditionally** to the latched coordinates: `set = srb_set`, `way = srb_way`.
3. **PLRU State Update**:
   - The L1D Tree-PLRU bits for `srb_set` are updated to mark `srb_way` as most-recently-used (MRU) **only at the exact cycle of installation (`SRB_INSTALL`)**.
   - No PLRU update occurs at capture.

### 3.3 P0-3: Store Buffer Drain Mutual Exclusion & Ownership Transfer
1. **Drain Gate**:
   - The drain arbiter evaluates `srb_busy`.
   - In any cycle where `srb_busy == 1`, Store Buffer draining is **strictly suspended**:
     `sb_drain_enable = sb_count > 0 && ! srb_busy && ...`
   - No second store drain may be presented to the L1D port while an SRB refill is pending.
2. **Ownership Handshake and SB Pop**:
   - On the capture cycle (`srb_capture == 1`):
     - All store payload fields (`paddr`, `data`, `byte_mask`) are latched into `srb_line_pa`, `srb_word_offset`, `srb_store_data`, and `srb_store_mask`.
     - L1D asserts `l1d_store_ack_o = 1` to the Store Buffer for exactly 1 cycle.
     - The Store Buffer observes `l1d_store_ack_o == 1`, clears `sb_valid[sb_head]`, increments `sb_head`, and decrements `sb_count`.
   - **Architectural Consequence**: The store definitively transfers from the Store Buffer into the SRB. The Store Buffer slot is freed, relieving backpressure for older stores, while the store's hazard responsibility transfers seamlessly to the SRB.
3. **Cascading Miss and Collision Prevention**:
   - Because `srb_busy` prevents subsequent SB drains, a second store miss cannot enter the system.
   - Same-line store collisions are prevented: subsequent stores to the same line remain safely queued in the Store Buffer until `srb_busy == 0`.

### 3.4 P1-1: Dual-Source RAW Hazard Detection
To ensure that Stage-E loads observe all prior stores in program order without hazard windows:
1. **Store Buffer RAW**: The existing 4-entry doubleword comparison is preserved:
   `SB_RAW = OR_i=0^3 ( sb_valid[i] && (load_pa[55:3] == sb_paddr[i][55:3]) )`
2. **SRB Full-Line RAW**: A dedicated comparator checks the load against the active SRB line:
   `SRB_RAW = srb_busy && (load_pa[55:6] == srb_line_pa[55:6])`
3. **Unified Hazard Stall**:
   `RAW_Hazard = SB_RAW || SRB_RAW`
4. **Resolution Policy**:
   - If `RAW_Hazard == 1`:
     - Stage E asserts `stall_e = 1`.
     - The load does not issue to L1D.
     - If caused by `SRB\_RAW`, Stage E remains stalled until `srb_busy == 0` (the line is fully installed into L1D).
     - On the cycle immediately following installation, the load queries L1D and hits in the newly installed way with 0 penalty cycles, reading the merged data.

### 3.5 P1-2: Unconditional One-Cycle Installation Priority
1. **Elimination of Starvation Mechanism**:
   - The proposed 2-cycle starvation counter is completely eliminated.
2. **Array Priority Rule**:
   - In the cycle where the 8th beat of the DRAM refill is received and data is merged, the SRB signals installation readiness.
   - On the immediately following cycle, the SRB is granted **unconditional, non-preemptible priority** over the L1D tag and data arrays for exactly **1 cycle**:
     `l1d_port_grant = srb_install_ready ? GRANT_SRB : (stage_e_load_req ? GRANT_LOAD : GRANT_SB)`
3. **Load Pipeline Impact**:
   - If a Stage-E load requests L1D in the installation cycle, the load receives an L1D port stall for exactly **1 cycle** (an installation bubble).
   - On the subsequent cycle, the load access proceeds without further delay.

### 3.6 P1-3: Asynchronous Late Error Contract
1. **Context**:
   - Stores entering the Store Buffer and draining into the SRB are **already architecturally committed and retired** in Stage E.
   - Program counter `mepc` and instruction counter `minstret` have already advanced.
2. **Contract Specification**:
   - If DRAM asserts `pd_req_error_i` or `pd_rsp_error_i` during SRB dirty victim eviction or refill:
     - The core **must NEVER generate a synchronous exception** (such as cause 7 `store-access-fault`) for the retired store.
     - The error is categorized strictly as an **unrecoverable asynchronous platform bus error**.
     - The SRB transitions to `SRB_FATAL_ERROR`.
     - SRB/L1D assert the common sticky unrecoverable-error indication; core and SoC
       enter the reset-only `fatal_halt_o` state defined in
       `docs/architecture/l1d-refill-opt-v1.md`, Section 13. No NMI or recoverable
       machine-check alternative is implied.
     - Writeback of the refilled line to L1D is aborted.

---

## 4. Finite State Machine (FSM) Specification

The SRB is governed by an explicit 7-state Moore FSM:

```
                  +--------------+
                  |   SRB_IDLE   | <------------------------------------+
                  +--------------+                                      |
                         | (Store Miss & Drain Grant)                   |
                         v                                              |
                  +--------------+                                      |
                  |  SRB_CAPTURE |                                      |
                  +--------------+                                      |
                    /          \                                        |
      (Victim Dirty)            (Victim Clean)                          |
           v                         v                                  |
    +---------------+         +---------------+                         |
    | SRB_EVICT_REQ |         | SRB_REFILL_REQ|                         |
    +---------------+         +---------------+                         |
           |                         ^                                  |
     (8 Beats Sent)                  |                                  |
           +-------------------------+                                  |
                                     | (8 Beats Recv)                   |
                                     v                                  |
                              +---------------+                         |
                              |   SRB_MERGE   |                         |
                              +---------------+                         |
                                     | (Data Merged)                    |
                                     v                                  |
                              +---------------+                         |
                              |  SRB_INSTALL  | ------------------------+
                              +---------------+   (1 Cycle Array Write)
                                     |
                             (DRAM Bus Error)
                                     v
                              +---------------+
                              |SRB_FATAL_ERROR|
                              +---------------+
```

### 4.1 Detailed State Transitions
1. **`SRB_IDLE`**:
   - `srb_busy = 0`.
   - If Store Buffer drain requests L1D and L1D detects a miss: transition to `SRB_CAPTURE`.
2. **`SRB_CAPTURE`**:
   - `srb_busy = 1`.
   - Latch `srb_line_pa`, `srb_set`, `srb_way`, `srb_store_offset`, `srb_store_data`, `srb_store_mask`.
   - Atomic invalidation: pulse `l1d_tag_invalidate` for `srb_set` and `srb_way`.
   - Pulse `l1d_store_ack_o = 1` to Store Buffer (popping store from SB).
   - Read victim tag and dirty bit. Latch into `srb_victim_dirty` and `srb_victim_tag`.
   - If `srb_victim_dirty == 1`: read 64B victim data from L1D array into `srb_victim_data`; transition to `SRB_EVICT_REQ`.
   - If `srb_victim_dirty == 0`: transition to `SRB_REFILL_REQ`.
3. **`SRB_EVICT_REQ`**:
   - Issue 8-beat DRAM burst write to `addr = {srb_victim_tag, srb_set, 6'd0}`.
   - Stream `srb_victim_data` across 8 beats using `srb_beat_count`.
   - If DRAM bus error: transition to `SRB_FATAL_ERROR`.
   - Upon completion of 8th beat: reset beat counter; transition to `SRB_REFILL_REQ`.
4. **`SRB_REFILL_REQ`**:
   - Issue 8-beat DRAM burst read to `addr = {srb_line_pa, 6'd0}`.
   - Collect 8 beats of read data into `srb_refill_data` using `srb_beat_count`.
   - If DRAM bus error: transition to `SRB_FATAL_ERROR`.
   - Upon receipt of 8th beat: transition to `SRB_MERGE`.
5. **`SRB_MERGE`**:
   - Combinatorially merge `srb_store_data` into `srb_refill_data` at doubleword offset `srb_store_offset` using `srb_store_mask`.
   - Assert `srb_install_ready = 1`.
   - Transition to `SRB_INSTALL`.
6. **`SRB_INSTALL`**:
   - Assert unconditional L1D array write grant.
   - Write merged 64B data into L1D data array at `set = srb_set`, `way = srb_way`.
   - Write physical tag `srb_line_pa[55:12]`, set `valid = 1`, set `dirty = 1` in L1D tag array at `set = srb_set`, `way = srb_way`.
   - Update L1D Tree-PLRU for `srb_set` to mark `srb_way` as MRU.
   - Clear `srb_busy <= 0`.
   - Transition to `SRB_IDLE`.
7. **`SRB_FATAL_ERROR`**:
   - Abort installation and preserve required bus cleanup. Assert the common sticky L1D
     fatal indication; core/SoC enforce and expose reset-only `fatal_halt_o` per the
     common Section 13 contract.

---

## 5. Serialization, Maintenance, Traps, and Reset Integration

### 5.1 Unified Synchronization Predicate
To guarantee that memory ordering and architectural boundaries remain completely hazard-free, every serialization mechanism in the core must enforce the **Combined Memory Drain Predicate**:

`Memory_Drained = (sb_count == 0) && (srb_busy == 0) && l1d_idle`

### 5.2 Specific Operation Semantics
1. **FENCE**:
   - Stalls Stage E until `Memory_Drained == 1`.
2. **FENCE.I (Instruction-Fetch Fence)**:
   - Stalls Stage E until `Memory_Drained == 1`.
   - Executes standard L1D dirty flush across all sets.
   - Awaits DRAM bus idle, pulses L1I flash invalidation, resumes pipeline.
3. **SFENCE.VMA (Address-Translation Fence)**:
   - Stalls Stage E until `Memory_Drained == 1`.
   - Executes L1D dirty flush, awaits DRAM bus idle, invalidates TLBs, resumes pipeline.
4. **PMP CSR Configuration Writes**:
   - Gated by `commit_fire && csr_valid && csr_write`.
   - Stalls Stage E until `Memory_Drained == 1`.
   - Executes L1D dirty flush, updates PMP shadow registers, resumes pipeline.
5. **Atomic Operations (LR, SC, AMO)**:
   - Stalls Stage E until `Memory_Drained == 1`.
   - `SC` and `AMO` execute strictly synchronously directly in L1D.
6. **Trap Entries and Interrupts**:
   - Traps and interrupts do not purge or discard the SRB.
   - The SRB continues background execution to completion while the trap redirects fetch to `mtvec`/`stvec`.
   - If an interrupt handler executes stores that miss, they queue in the Store Buffer; if the Store Buffer fills, the handler stalls naturally.
7. **MRET / SRET**:
   - Stalls Stage E until `Memory_Drained == 1` to ensure privilege domain transitions never leave pending stores in microarchitectural buffers.

### 5.3 Coherent Dirty Accounting and Maintenance Flushes
1. **Dirty Ownership Transfer**:
   - At the capture edge, the victim line's dirty bit is cleared in L1D and transferred into `srb_victim_dirty`.
   - Because any maintenance operation (such as `SFENCE.VMA` or `FENCE.I`) enforces `srb_busy == 0` before initiating set traversal:
     - Maintenance cannot commence while a dirty victim is in flight in the SRB.
     - The dirty victim is guaranteed to be fully written to DRAM before the maintenance scan begins.
     - Double-counting and early-termination bugs are physically eliminated.
2. **Installed Dirty State**:
   - At `SRB_INSTALL`, the newly installed line is marked `dirty = 1` in the L1D tag array.
   - Any subsequent maintenance scan will observe this line and write it back normally.

### 5.4 Platform Reset Contract
1. **Reset during Active DRAM Burst**:
   - If `rst_i == 1` asserts while `srb_busy == 1` and a DRAM burst is in flight:
     - Internal SRB registers reset to `SRB_IDLE` (`srb_busy <= 0`).
     - In accordance with the normative SoC bus contract (`fursoy_s0_soc.sv`), outstanding DRAM response beats must be cleanly drained.
     - The core asserts `ram_rsp_ready_o = 1` during reset to sink late arriving DRAM beats without deadlock.
     - No post-reset memory leaks or orphaned transactions can attach to post-reset execution.

---

## 6. Formal Architectural Invariants

The RTL implementation must strictly adhere to the following seven formal invariants:

### Invariant 1: Victim Invisibility Invariant
`∀ t ∈ [t_capture, t_install), l1d_hit(srb_set, srb_way) ≡ 0`
*Between the capture clock edge and the installation clock edge, the designated victim way in the designated set must never produce a cache hit for any load or store.*

### Invariant 2: Static Way Ownership Invariant
`install_set ≡ srb_set, install_way ≡ srb_way`
*The cache set and way updated at installation must match the exact set and way latched at the capture edge, regardless of any intervening PLRU state modifications.*

### Invariant 3: SRB Line RAW Exclusion Invariant
`(srb_busy && (load_pa[55:6] == srb_line_pa[55:6])) ==> stall_e = 1`
*Any load instruction targeting any doubleword within the 64-byte line currently owned by the SRB must stall in Stage E until the line is installed.*

### Invariant 4: Store Buffer Drain / SRB Mutual Exclusion Invariant
`srb_busy ==> sb_drain_req = 0`
*The Store Buffer drain engine shall never assert a drain request to L1D while the SRB is active.*

### Invariant 5: Coherent Dirty Accounting Invariant
`maintenance_active ==> srb_busy = 0`
*No cache maintenance flush (FENCE.I, SFENCE.VMA, PMP sync) shall begin set traversal while the SRB contains an active transaction.*

### Invariant 6: Single-Cycle Installation Priority Invariant
`srb_install_ready ==> (l1d_grant_srb = 1 && l1d_grant_load = 0)`
*An installation-ready SRB transaction shall preempt Stage-E load access for exactly one cycle without starvation delay.*

### Invariant 7: Asynchronous Late Error Invariant
`(srb_busy && dram_bus_error) ==> (sync_trap = 0 && fatal_platform_error = 1)`
*A DRAM bus fault encountered during background SRB operation shall never raise a synchronous architectural trap on a retired instruction.*

---

## 7. Expanded Verification Scenario Matrix

To validate the corrected architecture, the verification suite must implement the following 28 directed scenarios:

| Test ID | Category | Scenario Description | Expected Architectural Behavior |
| :--- | :--- | :--- | :--- |
| **SRB-INV-01** | Invalidation | Store miss captures clean victim line. | Victim way valid bit cleared at capture edge; subsequent load to victim address misses. |
| **SRB-INV-02** | Invalidation | Store miss captures dirty victim line. | Victim way valid & dirty bits cleared at capture edge; victim written back to DRAM. |
| **SRB-INV-03** | Invalidation | Load hits in same set on non-victim way while SRB active. | Load hits in 1 cycle without stalling; data returned cleanly. |
| **SRB-INV-04** | Invalidation | Multiple loads hit alternate ways in same set during SRB. | All loads hit cleanly; no corruption of victim way. |
| **SRB-WAY-01** | Static Way | 10 intervening loads hit in target set, toggling PLRU bits. | SRB installs strictly into originally latched `srb_way`, ignoring toggled PLRU. |
| **SRB-WAY-02** | Static Way | Intervening loads hit way 0, 1, 2; victim is way 3. | Installation targets way 3; PLRU updated to MRU for way 3 only at install cycle. |
| **SRB-WAY-03** | Static Way | Victim way empty (invalid line). | Valid bit remains 0 until install; line installed into empty way. |
| **SRB-MUTEX-01**| Mutual Excl | Store Buffer has 3 pending stores when store miss occurs. | First store enters SRB; remaining 2 stores remain held in SB until `srb_busy == 0`. |
| **SRB-MUTEX-02**| Mutual Excl | Store Buffer fills to 4 entries while SRB is active. | Pipeline stalls on `sb_full`; zero cascading store misses issue; drains resume upon install. |
| **SRB-MUTEX-03**| Mutual Excl | Subsequent store in SB targets same line as SRB. | Subsequent store waits in SB; after install, second store drains, hits in L1D in 1 cycle. |
| **SRB-MUTEX-04**| Mutual Excl | Ownership transfer timing test. | Store popped from SB on exact capture cycle (`l1d_store_ack_o == 1`). |
| **SRB-RAW-01** | RAW Hazard | Load targets exact doubleword of active SRB store. | Load stalls on `SRB_RAW`; unblocks after install; reads merged data. |
| **SRB-RAW-02** | RAW Hazard | Load targets different doubleword in active SRB 64B line. | Load stalls on `SRB_RAW`; unblocks after install; reads refilled DRAM data. |
| **SRB-RAW-03** | RAW Hazard | Load targets doubleword in SB AND another load targets SRB. | Both hazards correctly detected; pipeline stalls until respective buffers clear. |
| **SRB-RAW-04** | RAW Hazard | Back-to-back loads: Load 1 targets SRB line, Load 2 independent. | Load 1 stalls pipeline in Stage E; Load 2 held in Stage F until Load 1 unblocks. |
| **SRB-PRIO-01** | Priority | Stage-E load requests L1D on exact cycle SRB is ready to install. | SRB granted array write; Load stalled for exactly 1 cycle (installation bubble). |
| **SRB-PRIO-02** | Priority | Load proceeds on cycle immediately following 1-cycle install. | Load completes tag check and returns data on cycle `t+1`. |
| **SRB-PRIO-03** | Priority | Back-to-back load stream contending with install. | SRB steals exactly 1 cycle; stream resumes without further delay. |
| **SRB-MAINT-01**| Maintenance | `SFENCE.VMA` executes while SRB is active. | `SFENCE.VMA` stalls until `srb_busy == 0`; dirty flush proceeds without double-counting. |
| **SRB-MAINT-02**| Maintenance | `FENCE.I` executes while SRB is active. | `FENCE.I` stalls until `srb_busy == 0`; dirty flush writes all lines before L1I invalidation. |
| **SRB-MAINT-03**| Maintenance | PMP CSR write executes while SRB is active. | CSR write stalls until `srb_busy == 0`; flush completes cleanly. |
| **SRB-ATOMIC-01**| Atomicity | `SC` executes while SRB is active. | `SC` stalls in Stage E until `sb_count == 0 && srb_busy == 0`. |
| **SRB-ATOMIC-02**| Atomicity | `LR` executes while SRB is active. | `LR` stalls in Stage E until `sb_count == 0 && srb_busy == 0`. |
| **SRB-ATOMIC-03**| Atomicity | `AMOADD` executes while SRB is active. | AMO stalls in Stage E until `sb_count == 0 && srb_busy == 0`. |
| **SRB-ERR-01** | Bus Error | DRAM asserts error response during SRB victim eviction. | Top-level sticky `fatal_halt_o` asserted; execution halts after safe drain; zero synchronous trap on retired store. |
| **SRB-ERR-02** | Bus Error | DRAM asserts error response during SRB line refill. | Top-level sticky `fatal_halt_o` asserted; line installation aborted; safe drain; zero synchronous trap. |
| **SRB-RST-01** | Reset | `rst_i` asserted during SRB victim eviction burst. | SRB aborts to IDLE; remaining DRAM beats drained cleanly via `ram_rsp_ready_o`. |
| **SRB-RST-02** | Reset | `rst_i` asserted during SRB line refill burst. | SRB aborts to IDLE; remaining DRAM beats drained cleanly via `ram_rsp_ready_o`. |

---

## 8. Conservative Analytical Performance Hypothesis

### 8.1 Critical Modeling Revisions
The original informal conjecture that "most of the 4.015M load arbitration stall pool will disappear" is **formally rejected** as unphysical and architecturally unsound.

A rigorous analytical breakdown of the 4,015,726 load arbitration cycles reveals three distinct physical components:
1. **True Overlappable Store-Miss Load Stalls (~25–40%)**:
   - Cycles where an independent load in Stage E was blocked solely because L1D was executing a store miss refill, AND the load targets a different, valid cache line.
   - Only this fraction can be directly absorbed by the SRB.
2. **Stall Migration into Store Buffer Full (~40–55%)**:
   - In real workloads (such as Linux page copying and `memset`/`memcpy`), store misses occur in dense bursts.
   - Because a dirty store miss requires 28–40 cycles on the DRAM bus, subsequent stores rapidly saturate the 4-entry Store Buffer.
   - Once `sb_count == 4`, Stage E stalls on `sb_full`.
   - Consequently, cycles eliminated from single-port load arbitration largely migrate into Store Buffer full stalls.
3. **RAW and Same-Line Dependent Stalls (~10–15%)**:
   - Loads that target the line currently undergoing refill in the SRB stall on `SRB_RAW`.

### 8.2 Conservative Performance Estimate
Under normative analytical evaluation:
- **Load Stall Absorption**: **~25–40%** of the 4.015M load arbitration stall cycles (**~1.0M to 1.6M cycles absorbed**).
- **Stall Migration**: A substantial portion of the absorbed latency migrates into `sb_full` backpressure stalls.
- **Projected Net Runtime Reduction**: **~2.5% to 4.5% net cycle reduction** on the frozen Linux cold boot workload (approx. **690K to 1.24M net cycles saved**).
- **Contract Principle**: This figure represents a **conservative analytical hypothesis only**, not measured hardware performance. Under no circumstances shall correctness, timing closure, or invariant enforcement be compromised to chase this performance estimate. Correctness is absolute.

---

## 9. Architectural Review Resolution Summary

| SRB-v1 Finding | Severity | Description | Architecture Contract Resolution |
| :--- | :---: | :--- | :--- |
| **Finding 1** | **P0** | Victim way remains valid during refill, allowing stale hits or aliased overwrites. | **Section 3.1 & Invariant 1**: Atomic victim invalidation at capture edge; way is permanently unhittable until install. |
| **Finding 2** | **P0** | PLRU re-evaluation at install targets wrong way or corrupts another line. | **Section 3.2 & Invariant 2**: Set and way latched statically at capture; install targets latched way; PLRU updated only at install. |
| **Finding 3** | **P0** | Secondary store drains collide with SRB or trigger cascading misses. | **Section 3.3 & Invariant 4**: Store Buffer drain strictly gated by `!srb_busy`; store popped from SB at capture edge. |
| **Finding 4** | **P1** | Loads to refilling line read stale L1D or unmerged DRAM data (RAW hazard). | **Section 3.4 & Invariant 3**: Dual-source RAW check; `load_pa[55:6] == srb_line_pa[55:6]` stalls Stage E until install. |
| **Finding 5** | **P1** | 2-cycle install starvation mechanism introduces complex timing and stalls. | **Section 3.5 & Invariant 6**: Starvation counter eliminated; SRB gets unconditional 1-cycle priority; loads take 1-cycle bubble. |
| **Finding 6** | **P1** | Late DRAM bus errors erroneously attempt synchronous trap on retired store. | **Section 3.6 & Invariant 7**: Background errors defined as asynchronous platform fatal errors; synchronous trap strictly forbidden. |
| **Finding 7** | **P1** | Incomplete serialization, maintenance, dirty accounting, and reset contracts. | **Section 5 & Invariant 5**: Combined drain predicate (`sb_empty && ! srb_busy && l1d_idle`) enforced; clean reset bus drain. |

---

## 10. Status and Roadmap

- **SRB Architecture Contract v1**: **HISTORICALLY ACCEPTED AND FROZEN**.
- **Current Status**: Frozen SRB behavior is unchanged; only fatal-path terminology now
  defers to the common sticky fatal-halt contract.
- **L1D-ER Dependency**: The common fatal-halt amendment remains pending independent
  focused re-review and does not authorize further RTL implementation.
