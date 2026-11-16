# Slice-0 Store Buffer / Store-Path Architectural Contract — v1

Status: **Slice-0 Store Buffer Architecture v1 — FROZEN**  
Normative Baselines:
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 (RV64I base, "Zifencei" Instruction-Fetch Fence, "A" Standard Extension for Atomicity v2.1)
- RISC-V Memory Consistency Model (RVWMO)
- `docs/architecture/l1d-cache-v1.md` (Frozen L1 Data Cache v1 contract)
- `docs/architecture/pipeline-s0-v1.md` (Frozen Slice-0 2-stage F | E in-order pipeline contract)
- `docs/architecture/l1i-cache-v1.md` (Frozen L1 Instruction Cache v1 contract)
- `docs/architecture/sv39-tlb-v1.md` (Frozen Sv39 TLB v1 contract)
- `docs/architecture/sv39-mmu-v1.md` (Frozen Sv39 MMU & PTW contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection contract)
- `docs/architecture/rv64a-v1.md` (Frozen RV64A Atomic Extension contract)
- `results/perf-baseline-s0.json` (Frozen Post-L1D Bottleneck Profiling telemetry)

---

## 1. Authority, Scope, and Design Objectives

### 1.1 Purpose and Measured Motivation
This document defines the architectural contract for the hardware **Store Buffer (SB)** subsystem for the single-hart Fursoy Slice-0 processor.

The Post-L1D observational bottleneck profiling pass established that **store stalls represent the single largest remaining bottleneck in the core**:
- **Total store stall cycles**: **4,753,916 cycles** (**16.829% of total execution time**; **35.750% of all non-retirement stall cycles**).
  - Hit-path latency: 207,196 cycles (0.733% of runtime).
  - Clean miss line refill: 261,270 cycles (0.925% of runtime).
  - Dirty victim eviction + refill: **4,285,450 cycles** (**15.171% of runtime**; **90.146% of all store stalls**).
- **Physical Dynamics**:
  - Store instructions committed: 2,578,037 instructions.
  - L1D store hit rate: **92.98%** (2,385,861 hits vs 180,250 misses).
  - Dirty evictions: 252,055 lines written back to DRAM (86.05% of all 292,928 refills).
  - Because Slice-0's frozen L1D v1 implementation executes dirty evictions and refills **strictly synchronously** while holding Stage E frozen, each dirty store miss stalls the entire pipeline for ~28–40 cycles.

The objective of this architecture is to decouple store instruction retirement from L1D completion, absorbing store miss and dirty eviction latencies behind independent execution, while preserving 100% of frozen architectural, memory-ordering, and precise-exception invariants.

### 1.2 Non-Goals and Out-of-Scope Machinery
To preserve the timing closure and simplicity of the in-order Slice-0 core:
- **No Out-of-Order Execution**: Instructions issue, execute, and retire in strict program order.
- **No Speculative Store Buffering**: Stores enter the buffer only after all precise synchronous exceptions have been evaluated and retired.
- **No Speculative or Buffered MMIO**: MMIO accesses remain strictly unbuffered and synchronous.
- **No Speculative SC Buffering (P1-2)**: `SC` instructions are strictly serialized and never buffered.
- **No Complex Byte-Granular CAM Forwarding**: A conservative stall-on-RAW policy is adopted to eliminate forwarding multiplexer timing paths and sub-word merge corner cases.
- **No Multicore Snooping / Coherence**: Slice-0 remains a single-hart system.

---

## 2. Normative Memory Visibility and Serialization Lifecycle

To eliminate ambiguity across all execution, serialization, and flush boundaries, the architecture normatively distinguishes ten discrete states in a store transaction's lifecycle:

```
[Stage E] --(1. Allocated)--> [SB Entry] --(2. Architecturally Retired)--> [3. Pending]
                                                                                |
                                                                     (4. Selected for Drain)
                                                                                |
                                                                       (5. L1D Req Issued)
                                                                                |
                                                                       (6. L1D Req Accepted)
                                                                                |
                                                                       (7. Applied to L1D Array)
                                                                                |
                                                     [8. SB Entry Removed] <----+
                                                              |
                                                    [9. L1D Dirty State]
                                                              |
                                                   (Dirty Eviction / Flush)
                                                              |
                                                    [10. DRAM Visibility]
```

1. **SB Entry Allocated**: The store request payload (`PA[55:3]`, formatted data, byte mask) is latched into the Store Buffer tail slot at the clock edge of Stage E execution.
2. **Store Architecturally Retired**: All precise synchronous exception checks (alignment, translation, page write permission, PMP) have passed. Architectural state (`mepc`, `instret`, PC) advances past the store.
3. **Pending in SB**: The entry resides in the SB FIFO waiting for selection by the drain arbiter.
4. **Selected for Drain**: The drain arbiter grants L1D port access to `sb_head`.
5. **L1D Request Issued**: `sb_req_valid_o` is asserted to the L1D port with `sb_head` payload.
6. **L1D Request Accepted**: L1D asserts `sb_req_ready_i`. Address and control are latched into L1D pipeline registers. **Note**: The store is NOT yet applied.
7. **Store Applied to L1D**: L1D definitively updates the cache tag/data array (on hit) or completes refill and installs the merged line at `INSTALL` (on miss). L1D pulses `l1d_store_ack_o` for 1 cycle.
8. **SB Entry Removed**: Upon the `l1d_store_ack_o` pulse, `sb_valid[sb_head]` is cleared, `sb_head` advances modulo depth, and `sb_count` decrements.
9. **L1D Dirty State**: The target line resides in the L1D cache array marked valid and dirty. Visible to all local load hits.
10. **DRAM Visibility**: The dirty line is written back to physical DRAM via an 8-beat burst and the DRAM write path is confirmed idle. Visible to hardware PTW and L1I after invalidation.

---

## 3. Buffer Geometry, Allocation, and Retirement

### 3.1 Buffer Geometry
The Store Buffer is organized as a 4-entry circular FIFO managed by read pointer `sb_head[1:0]`, write pointer `sb_tail[1:0]`, and occupancy counter `sb_count[2:0]`.

Each entry contains:
```
+-------+--------------------+------------------+------------------+------------+
| valid |   paddr[55:3]      |    data[63:0]    |  byte_mask[7:0]  | size[1:0]  |
| (1 b) |     (53 bits)      |    (64 bits)     |     (8 bits)     |   (2 b)    |
+-------+--------------------+------------------+------------------+------------+
```
- `valid`: Entry contains an architecturally committed store pending application to L1D.
- `paddr[55:3]`: 53-bit physical doubleword base address (`paddr[2:0]` is implicitly zero).
- `data[63:0]`: 64-bit store data right-justified / positioned according to `byte_mask`.
- `byte_mask[7:0]`: Active byte enable mask indicating which bytes of the doubleword are modified.
- `size[1:0]`: Original transfer size (`00`=B, `01`=H, `10`=W, `11`=D) for telemetry/tracing.

### 3.2 Allocation and Retirement Semantics
1. **Stage E Execution & Precise Fault Resolution**:
   - Effective address is computed: `vaddr = rs1 + imm`.
   - Alignment is verified: if `vaddr[size-1:0] != 0`, raise precise `store-address-misaligned` (cause 6).
   - DTLB translates `vaddr` to `paddr[55:0]`. If translation fails, raise precise `store-page-fault` (cause 15).
   - PMP checks `paddr[55:0]`. If denied, raise precise `store-access-fault` (cause 7).
   - Cacheability is determined: `0x8000_0000 – 0x8FFF_FFFF` is cacheable DRAM; all other ranges are uncached MMIO.
2. **Architectural Retirement**:
   - For cacheable DRAM stores: Once alignment, translation, PMP, and cacheability are verified, **NO SYNCHRONOUS EXCEPTION CAN OCCUR**.
   - The store is enqueued into the Store Buffer (or merged into the tail per Section 4).
   - Stage E retires the store instruction immediately (**1 cycle execution latency**).
   - The architectural program counter, `mepc`, and instruction retire counter (`instret`) advance.
   - Stage F delivers the next instruction into Stage E on the next clock cycle.
3. **Buffer Full Backpressure**:
   - If `sb_count == 4` and no tail merge is possible, the buffer is full.
   - Stage E asserts `stall_e` until `l1d_store_ack_o` pops `sb_head` and decrements `sb_count`.

---

## 4. Safe Store Merging Contract (Resolving P0-1)

To prevent race conditions, timing loopbacks, and corruption of draining entries:

### 4.1 Strict Tail-Only Merging Rule
A new store arriving in Stage E may merge **strictly into the youngest unissued tail entry** (`sb_tail - 1`). It is **NEVER** permitted to search or merge into arbitrary older SB entries, and **NEVER** permitted to merge into the active/draining head.

A merge into tail entry `T = (sb_tail - 1) mod 4` is permitted **IF AND ONLY IF ALL** of the following conditions are simultaneously true:
1. `sb_count > 0` (buffer is not empty).
2. `sb_valid[T] == 1` (tail entry is valid).
3. `new_store_pa[55:3] == sb_paddr[T][55:3]` (exact 8-byte aligned doubleword address match).
4. Entry `T` is **NOT** currently selected for drain (`T != sb_head` or drain arbiter is idle).
5. No L1D request derived from entry `T` has been issued or accepted (`sb_req_valid_o` is not active for entry `T`).
6. Entry `T` remains completely mutable in the current clock cycle.

If any of conditions 1–6 is false:
- Merging is prohibited.
- If `sb_count < 4`, the store allocates a new FIFO entry at `sb_tail`.
- If `sb_count == 4`, Stage E stalls with backpressure until `sb_head` pops.

### 4.2 Byte-Mask Merge Semantics
When a safe tail merge occurs into entry `T`:
1. **Younger Byte Overwrite Precedence**: For each byte lane `b ∈ [0, 7]`:
   ```text
   sb_data[T][8b+7:8b] ←
     new_store_data[8b+7:8b]  if new_store_mask[b] == 1
     sb_data[T][8b+7:8b]      if new_store_mask[b] == 0
   ```
2. **Byte Mask Accumulation**:
   `sb_byte_mask[T] ← sb_byte_mask[T] | new_store_mask`
3. Untouched bytes already present in entry `T` remain strictly preserved.
4. `sb_tail` does **not** advance; `sb_count` does **not** increment.
5. The store retires in Stage E in 1 cycle.

---

## 5. Elimination of the Ghost Window (Resolving P0-3)

### 5.1 The Ghost Window Vulnerability
If an SB entry were popped upon L1D request acceptance (`sb_req_ready_i == 1`), a hazard window opens during L1D miss processing (up to 35+ cycles):
- The store is no longer in the SB (RAW detection inactive).
- The store is not yet written into the L1D array (line is invalid or in refill buffer).
- A younger load to the same address querying L1D would read stale DRAM/cache data or initiate a duplicate colliding miss.

### 5.2 Normative Retention Contract
1. **Continuous Hazard Participation**: Every entry in the Store Buffer—including `sb_head`—remains marked `valid == 1` and actively participates in RAW hazard comparisons across all of the following phases:
   - Waiting for drain selection.
   - Selected for drain and asserting `sb_req_valid_o`.
   - Accepted by L1D and actively executing tag lookup.
   - Waiting through L1D miss processing, dirty line eviction, and line refill.
   - Waiting for final line installation and store application.
2. **Deallocation on Positive Acknowledgement Only**:
   - L1D asserts a dedicated 1-cycle acknowledgement pulse `l1d_store_ack_o` **only after the store has definitively updated the cache array**:
     - On L1D Hit: At the conclusion of the 1-cycle array write.
     - On L1D Miss: At the `INSTALL` state, after the 8th refill beat is received, the merged line is written to SRAM tags/data, and the dirty bit is set.
   - `sb_valid[sb_head]` is cleared, `sb_head` advances, and `sb_count` decrements **strictly on the clock edge observing `l1d_store_ack_o == 1`**.
   - Request acceptance alone (`sb_req_ready_i == 1`) **NEVER** deallocates an entry.

---

## 6. Load Path and Conservative Stall-on-RAW

### 6.1 Conservative Doubleword Hazard Detection
When a load instruction executes in Stage E:
1. `load_pa[55:0]` is translated by DTLB and validated by PMP.
2. `load_pa[55:3]` (the 8-byte aligned doubleword address) is compared against `sb_paddr[i][55:3]` for all valid entries `i ∈ [0, 3]`.
3. **Hazard Equation**:
   `RAW_Hazard = OR_i=0^3 ( sb_valid[i] && (load_pa[55:3] == sb_paddr[i]) )`
4. **Resolution Policy**:
   - If `RAW_Hazard == 1`:
     - Stage E asserts `stall_e = 1`.
     - The load does not issue to L1D.
     - The drain arbiter prioritizes draining the Store Buffer.
     - Stage E remains stalled until all matching entries have received `l1d_store_ack_o` and deallocated.
     - Once `RAW_Hazard == 0`, the load queries L1D, reading the updated, fully merged data directly from the cache array.
   - If `RAW_Hazard == 0`:
     - The load queries L1D directly without stalling (subject to L1D arbitration per Section 7).

### 6.2 Handling of Overlap Corner Cases

| Scenario | Definition | Architecture Contract |
| :--- | :--- | :--- |
| **Exact Doubleword Match** | Load doubleword matches buffered store (`LD A` after `SD A`). | Stalls until store receives `l1d_store_ack_o`. Reads L1D in 1 cycle. |
| **Partial Overlap** | Store writes byte 1; Load reads word (`LW` at offset 0). | Stalls until store applied to L1D. L1D sub-word logic reads merged data. |
| **Same-Doubleword Non-Overlapping** | Store writes byte 0; Load reads byte 1 (`PA[55:3]` matches). | **Stalls until store applied to L1D**. Conservative doubleword granularity guarantees zero false forwarding or stale partial reads. |
| **Multiple Matching Entries** | Store 1 and Store 2 both target doubleword `A`; Load reads `A`. | Stalls until both stores have received `l1d_store_ack_o`. |
| **Different Sizes** | `SB` followed by `LD`; or `SD` followed by `LB`. | Stalls until applied. L1D sign/zero extension handles formatting. |
| **Same Line, Different Doublewords** | Store targets doubleword 0; Load reads doubleword 1. | **Zero stall cycles**. Addresses differ (`load_pa[55:3] != sb_paddr[55:3]`). Load reads L1D directly. |

---

## 7. Deterministic Single-Port L1D Arbitration (Resolving P1-1)

Because L1D possesses a single physical access port shared between Stage-E loads and the Store Buffer drain, arbitration must guarantee deterministic forward progress and zero starvation.

### 7.1 Arbitration Priority Rules
At every clock cycle where L1D is idle and available:
1. **Opportunistic Drain**: If Stage E has no memory instruction (ALU, branch, jump, CSR, bubble), SB drain has absolute priority.
2. **Load Priority with Starvation Bound**: If Stage E presents a valid non-conflicting load:
   - If `sb_count < 4` and `sb_starve_count < 4`: The **Stage-E load is granted** L1D access. SB drain waits.
   - If `sb_count == 4` (buffer full): **SB drain is granted** L1D access to relieve pipeline backpressure. Stage E stalls.
   - If `sb_starve_count >= 4` (starvation threshold reached): **SB drain is granted** L1D access. Stage-E load stalls for 1 cycle.
3. **RAW-Conflicting Load**: If Stage E presents a RAW-conflicting load, the load stalls unconditionally, and **SB drain is granted**.

### 7.2 Starvation Counter Semantics
- Hardware maintains a 3-bit saturation counter `sb_starve_count[2:0]`.
- **Increment Condition**: In any cycle where:
  - `sb_count > 0` (SB has a valid entry ready to drain), AND
  - L1D is idle, AND
  - A Stage-E load requests L1D, AND
  - The load is granted over SB drain.
  `sb_starve_count ← min(sb_starve_count + 1, 4)`
- **Reset Condition**: `sb_starve_count` resets to `0` whenever:
  - An SB drain request is granted L1D access, OR
  - `sb_count == 0` (buffer becomes empty).
- **Forward Progress Guarantee**: Continuous back-to-back non-conflicting loads can delay an SB drain for at most **4 cycles** before the arbiter forces an SB drain cycle. Live-lock and starvation are mathematically impossible.

---

## 8. RV64A Coherence, Reservation, and Synchronization

### 8.1 Ordinary Store Reservation Invalidation (Resolving P0-2)
To preserve the frozen RV64A specification (`docs/architecture/rv64a-v1.md`):
- **Contract**: Whenever an ordinary store instruction (`SB`, `SH`, `SW`, `SD`) successfully enqueues into the Store Buffer and architecturally retires in Stage E:
  - Its physical line address `store_pa[55:6]` is compared against the registered reservation address `res_pa[55:6]`.
  - If `store_pa[55:6] == res_pa[55:6]`:
    `res_valid ← 0`
  - This invalidation occurs **at the exact architectural retirement/enqueue cycle in Stage E**.
  - It is **NEVER deferred** to when the store drains or writes to L1D.
- **Sequence Verification (`LR -> ordinary store -> SC`)**:
  - `LR` sets `res_valid = 1`, `res_pa = line_pa`.
  - Ordinary store to `line_pa` enters SB; `res_valid` is immediately cleared to `0`.
  - Subsequent `SC` to `line_pa` observes `res_valid == 0`, fails immediately (`rd = 1`), and commits zero stores.
  - Correctness is guaranteed regardless of whether the ordinary store is still in the SB or in L1D.

### 8.2 SC Synchronization (Resolving P1-2)
**Store-Conditional (`SC.W` / `SC.D`) is strictly NON-BUFFERED**:
1. When an `SC` instruction reaches Stage E:
   - Stage E stalls until `sb_count == 0` (Store Buffer completely drained and all older stores applied to L1D).
2. Once the SB is empty:
   - `SC` evaluates reservation validity: `res_valid && (paddr == res_pa) && (size == res_size)`.
   - **If Failed**: `SC` writes `rd = 1` into the register file. Zero memory writes are issued. Reservation is cleared. Completes in 1 cycle.
   - **If Succeeded**: `SC` writes `rd = 0` into the register file. `SC` issues directly to L1D as a synchronous write-allocate transaction, updating the cache array. Reservation is cleared.
3. `SC` instructions never enter the Store Buffer.

### 8.3 Load-Reserved (`LR.W` / `LR.D`)
1. When `LR` reaches Stage E:
   - Stage E stalls until `sb_count == 0`.
2. Once the SB is empty, `LR` queries L1D, returns data to `rd`, and registers `res_valid = 1`, `res_pa = paddr`, `res_size = size`.
3. Eliminates any hazard of establishing a reservation over pending, unapplied stores.

### 8.4 Atomic Memory Operations (AMO)
- AMOs (`AMOADD`, `AMOSWAP`, etc.) stall Stage E until `sb_count == 0`.
- Once the SB is empty, the AMO executes its 2-cycle atomic read-modify-write sequence directly in L1D with interrupts masked.

---

## 9. System Serialization and Coherence Integration

Every serialization mechanism enforces an explicit completion boundary using the definitions in Section 2:

### 9.1 Ordinary FENCE
- **Contract**: `FENCE` stalls Stage E until all older SB stores are **applied to L1D** (`sb_count == 0`) AND L1D is idle.

### 9.2 FENCE.I (Instruction-Fetch Fence)
- **Serialized Sequence**:
  1. Freeze Stage F fetch.
  2. **Drain SB**: Stall Stage E until all older SB stores are **applied to L1D** (`sb_count == 0`).
  3. **L1D Dirty Flush**: L1D traverses sets and writes back all dirty lines to physical DRAM via 8-beat bursts.
  4. **Establish DRAM Idle**: Wait until DRAM write path is confirmed idle.
  5. **Pulse L1I Invalidation**: Pulse `fence_i_flush_i` to L1I for 1 cycle (flash-invalidation).
  6. **Pipeline Drain & Resume**: Flush Stage E, resume Stage F fetch at `PC + 4`.
- **Invariant**: Self-modifying code written to the SB is guaranteed to reach physical DRAM before L1I is invalidated.

### 9.3 SFENCE.VMA (Address-Translation Fence)
- **Serialized Sequence**:
  1. Freeze Stage F fetch and inhibit translations.
  2. **Drain SB**: Stall Stage E until all older SB stores are **applied to L1D** (`sb_count == 0`).
  3. **L1D Dirty Flush**: L1D traverses sets and flushes all dirty lines to DRAM.
  4. **Establish DRAM Visibility**: Wait until DRAM write path is confirmed idle.
  5. **TLB Invalidation**: Invalidate matching ITLB/DTLB entries.
  6. **Resume Translations & Fetch**: Resume fetch at `PC + 4`.
- **Invariant**: Page table updates written to the SB are guaranteed visible in DRAM to the hardware PTW before any new translation can occur.

### 9.4 PMP CSR Modification (Resolving P1-3)
To maintain the complete frozen PMP maintenance contract:
- **Serialized Sequence**:
  1. `PMP CSR` instruction (`csrw pmpcfg*` / `csrw pmpaddr*`) reaches Stage E.
  2. Freeze Stage F fetch.
  3. **Drain SB**: Stall Stage E until all older SB stores are **applied to L1D** (`sb_count == 0`).
  4. **L1D Dirty Flush**: L1D traverses sets and flushes all dirty lines to physical DRAM.
  5. **Establish DRAM Idle**: Confirm DRAM write path is completely idle.
  6. **Pulse L1I Invalidation**: Pulse `fence_i_flush_i` to clear L1I instructions fetched under old permissions.
  7. **Update PMP CSR**: Write new configuration into `fursoy_s0_pmp`.
  8. **Pipeline Restart**: Flush pipeline and restart fetch at `PC + 4`.
- **Invariant**: No stores evaluated under older PMP rules remain pending in SB or unwritten in L1D when new security boundaries take effect.

### 9.5 Uncached MMIO Transactions
- **Contract**:
  1. Any MMIO store (UART, CLINT, PLIC) stalls Stage E until `sb_count == 0`.
  2. The MMIO store executes synchronously over the peripheral bus; Stage E stalls until acknowledged.
  3. Any MMIO load stalls Stage E until `sb_count == 0` before issuing.
- **Invariant**: Strictly zero speculative, buffered, or reordered MMIO transactions.

### 9.6 Traps, Interrupts, and Privilege Transitions
- **Synchronous Traps (Exceptions / ECALL)**:
  - Faulting instruction does not commit.
  - The core **drains the SB completely** (`sb_count == 0`) before executing the first instruction at `mtvec`/`stvec`.
- **Asynchronous Interrupts**:
  - Taken strictly at instruction retirement boundary.
  - The core **drains the SB completely** (`sb_count == 0`) before vectoring to `mtvec`.
  - *Latency Characteristic*: Mandatory SB draining on interrupt entry introduces a bounded latency. While ~35 cycles is approximately the cost of a single dirty store miss requiring writeback + refill, a full 4-entry SB can require multiple serialized L1D transactions. Under pathological worst-case conditions (e.g. four independent dirty misses), drain latency may reach roughly ~100–140 cycles (~136 cycles). This is a bounded latency/performance characteristic, not a correctness issue.
- **Privilege Transitions (`MRET` / `SRET`)**:
  - `MRET`/`SRET` stalls Stage E until `sb_count == 0` before restoring privilege mode and jumping to `mepc`/`sepc`.

---

## 10. Analytical Performance Model & Upper Bounds (P2)

Using the measured profile from `results/perf-baseline-s0.json`:
- **Current Store Stall Pool**: **4,753,916 cycles**.
  - Hit-path latency: 207,196 cycles.
  - Clean miss refill: 261,270 cycles.
  - Dirty eviction + refill: 4,285,450 cycles.
- **Workload Concurrency Characteristics**:
  - Non-memory instructions: 9,764,735 (65.3% of instruction stream; ALU 6.82M + control flow 2.94M).
  - Average distance between memory instructions: ~2.6 instructions.
- **Analytical Range & Upper Bound**:
  - *Hit Latency Absorption*: The 4-entry SB absorbs virtually 100% of hit-path latency (207k cycles) because hit stores retire in 1 cycle.
  - *Miss Latency Absorption*: During the ~28 cycles of a dirty store miss refill, independent ALU and control-flow instructions execute concurrently in Stage E until the 4-entry buffer saturates or a RAW hazard occurs.
  - *Analytical Absorption Estimate*: **60%–75%** of store stalls (**~2.85M–3.56M cycles**).
  - **Normative Disclaimer**: This projected 60%–75% absorption represents an **analytical upper bound/range** based on ideal instruction stream distribution, **not a guaranteed empirical measurement**. Realized speedup will be determined by RTL simulation accounting for actual RAW stall frequency, buffer-full backpressure, and single-port L1D arbitration contention.

---

## 11. Adversarial Verification Matrix

The future RTL implementation of this specification must pass the following 26 adversarial verification scenarios:

| Test ID | Scenario Description | Expected Architectural Contract |
| :---: | :--- | :--- |
| **SB-ORD-01** | Consecutive stores to distinct doublewords (`SD A`, `SD B`, `SD C`, `SD D`) | Enqueued in program order; drained strictly in FIFO order to L1D. |
| **SB-MRG-01** | Consecutive stores to same doubleword (`SW low`, `SW high`) | Merged into single tail SB entry; single L1D write transaction. |
| **SB-MRG-02** | Overlapping byte writes to same doubleword (`SB A[0]`, `SD A`) | Younger store overwrites byte 0; byte mask reflects all active bytes. |
| **SB-MRG-03** | Merge attempt into draining head | **Rejected**. Head entry is unmergeable; store allocates new FIFO entry. |
| **SB-MRG-04** | Tail merge while head drains | Head drains miss to L1D; younger store merges safely into tail entry. |
| **SB-MRG-05** | Multiple partial stores to same doubleword (`SB A[0]`, `SB A[2]`, `SB A[1]`) | Merges correctly into tail; untouched bytes preserved; correct mask. |
| **SB-MRG-06** | Younger-byte overwrite precedence (`SB A[0]=0x11`, then `SB A[0]=0x22`) | Byte 0 holds `0x22`; byte mask remains valid. |
| **SB-RAW-01** | Exact doubleword RAW: `SD A` followed immediately by `LD A` | Stage E stalls until `SD A` receives `l1d_store_ack_o`; `LD A` reads correct data. |
| **SB-RAW-02** | Partial-overlap RAW: `SB A[1]` followed immediately by `LW A[0]` | Stage E stalls until `SB` applied to L1D; L1D sub-word logic returns clean data. |
| **SB-RAW-03** | Multiple older stores overlapping one load (`SB A[0]`, `SB A[1]`, `LH A[0]`) | Stage E stalls until both stores applied; load reads merged halfword. |
| **SB-RAW-04** | Non-conflicting load: `SD A[0]` followed by `LD B[0]` (`A != B`) | **Zero stall cycles**. Load accesses L1D directly while store is in SB. |
| **SB-RAW-05** | RAW load while matching head is accepted by L1D but not yet applied | **Stalls Stage E**. Ghost window eliminated; load waits for `l1d_store_ack_o`. |
| **SB-RAW-06** | Same-doubleword non-overlapping load (`SB A[0]` followed by `LB A[1]`) | **Stalls Stage E**. Conservative doubleword granularity guarantees safety. |
| **SB-RAW-07** | Multiple matching SB entries with younger load | Stalls Stage E until all matching entries receive `l1d_store_ack_o`. |
| **SB-ARB-01** | Continuous loads attempting to starve SB | Load burst granted 4 cycles; starvation counter forces SB drain grant. |
| **SB-ARB-02** | Full buffer + dirty eviction + younger load | SB full (4 entries); head misses and evicts; younger load stalls cleanly. |
| **SB-BP-01** | Store Buffer full backpressure: 5 consecutive store misses | 4 stores enqueue; 5th store stalls Stage E until head entry pops. |
| **SB-EXC-01** | Store with misaligned address (`SD 0x80000001`) | Traps immediately in Stage E (cause 6); **zero** SB entries allocated. |
| **SB-EXC-02** | Store with page fault (unmapped / read-only page) | Traps immediately in Stage E (cause 15); **zero** SB entries allocated. |
| **SB-EXC-03** | Store denied by PMP rule | Traps immediately in Stage E (cause 7); **zero** SB entries allocated. |
| **SB-ATM-01** | `LR -> buffered ordinary store -> SC` sequence | Ordinary store clears `res_valid` at Stage-E enqueue; `SC` fails (`rd = 1`). |
| **SB-ATM-02** | Synchronous `SC` execution | `SC` stalls until `sb_count == 0`, evaluates exact PA+size, executes in L1D. |
| **SB-ATM-03** | `AMOADD.D` with pending stores in SB | Stage E stalls until `sb_count == 0`; AMO executes atomic hit in L1D. |
| **SB-PMP-01** | `CSRW pmpcfg0` with stores in SB | Stage E stalls until `sb_count == 0`, flushes L1D, invalidates L1I, updates PMP. |
| **SB-VM-01** | Buffered PTE store + `SFENCE.VMA` + immediate PTW | SB drains completely; L1D flushes to DRAM; PTW reads updated PTE. |
| **SB-FNC-01** | Buffered code store + `FENCE.I` | SB drains completely; L1D flushes; L1I invalidates; fetch gets new code. |
| **SB-MMIO-01** | MMIO store/load following buffered DRAM stores | SB drains completely; MMIO executes synchronously without buffering. |
| **SB-TRP-01** | External/Timer interrupt with stores in SB | Core drains SB completely before vectoring to `mtvec`. |
| **SB-RST-01** | Reset pulse while SB contains valid entries | All valid bits, pointers, and counters clear; buffer enters empty state. |

---

## 12. Summary of Key Architectural Decisions for Focused Re-Review

1. **Strict Tail-Only Merging (P0-1)**: Merging allowed only into the youngest unissued tail entry, never into draining/active head.
2. **Immediate Reservation Invalidation (P0-2)**: Ordinary stores clear `res_valid` upon Stage-E enqueue/retirement, preserving the RV64A contract for `LR -> store -> SC`.
3. **Ghost Window Elimination (P0-3)**: Head entry remains valid for RAW detection until L1D asserts positive application pulse `l1d_store_ack_o`.
4. **Deterministic Arbitration (P1-1)**: Load priority with 4-cycle starvation bound and full-buffer override guarantees bounded forward progress.
5. **Synchronous Non-Buffered SC (P1-2)**: `SC` stalls until SB is empty, executing synchronously through L1D.
6. **Full PMP Maintenance Restored (P1-3)**: PMP CSR modifications enforce SB drain, L1D dirty flush, and L1I flash-invalidation.
7. **Complete Serialization Specifications**: Distinct 10-state lifecycle applied consistently across all memory and system fences.
