# Sv39 TLB / Translation Cache Architectural Contract — v1

Status: **FROZEN** (Accepted and Frozen under Independent Architecture Review)  
Normative Baselines:
- RISC-V Privileged Architecture Manual v1.13 (Supervisor-Level ISA: Sv39, satp, SFENCE.VMA)
- `docs/architecture/sv39-mmu-v1.md` (Frozen Sv39 MMU & PTW contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection contract)
- `docs/architecture/rv64a-v1.md` (Frozen Atomic Memory Operations & LR/SC contract)
- `docs/architecture/s-mode-bare-v1.md` (Frozen Privilege & CSR contract)

---

## 1. Authority, Scope, and Design Philosophy

### 1.1 Scope
This document defines the architectural contract for the first hardware Translation Lookaside Buffer (TLB) subsystem for the single-hart Fursoy Slice-0 processor.

The TLB acts strictly as a **translation caching acceleration** for the frozen, fully verified Sv39 Page Table Walker (PTW). It introduces zero alterations to the architectural memory model, privilege model, exception generation, or PMP validation contracts.

### 1.2 Non-Goals and Deferred Features
The following features are explicitly deferred:
- Multi-hart TLB invalidation broadcasting / hardware shootdown (unsupported on single-hart Slice-0).
- Nonzero ASID support (`ASIDLEN = 0` remains normative; all translations reside in the single address space).
- Speculative page table walks or prefetching.
- Hardware A/D bit updates (`Svadu` is unsupported; `Svade` fault-on-clear remains frozen).
- Sub-page permissions or NAPOT translations (`Svnapot` is unsupported).
- Page-based memory types (`Svpbmt` is unsupported).
- L1/L2 instruction and data cache hierarchies (TLB interfaces directly to the existing memory interface).

---

## 2. TLB Organization and Structure

### 2.1 Split L1 Structure: ITLB and DTLB
To align with the independent instruction-fetch frontend (`fursoy_s0_fetch`) and data memory engine (`fursoy_s0_lsu_port`), Fursoy Slice-0 implements a **split L1 TLB organization**:
1. **Instruction TLB (ITLB)**: Dedicated to translating instruction fetch addresses (`vi_req`).
2. **Data TLB (DTLB)**: Dedicated to translating explicit load, store, and AMO data addresses (`vd_req`).

#### Architectural Rationale
- **Spatial Separation & Thrashing Immunity**: Measured execution during Linux boot and userspace workloads shows 16.78M instruction walks vs 5.97M data walks. In tight execution loops (e.g., userspace micro-benchmarks or kernel spinlocks), instruction fetches and strided buffer data accesses exhibit disjoint working sets. A split design prevents data memory streams from evicting hot code translations.
- **Port Independence**: Instruction fetch and LSU data ports access their respective TLBs in parallel without port arbitration or structural hazards during the request phase.
- **Shared PTW Backend**: A single shared hardware Page Table Walker handles misses from both ITLB and DTLB sequentially, giving strict priority to LSU transactions over instruction fetches.

### 2.2 Capacity and Associativity
- **Capacity**:
  - **ITLB**: 16 entries.
  - **DTLB**: 16 entries.
  - **Total**: 32 translation entries.
- **Associativity**: **Fully Associative**.
- **Replacement Policy**: **True Least-Recently Used (True-LRU)** maintained via a standard $16 \times 16$ triangular age matrix (120 state bits per TLB).

#### Associativity Rationale
Sv39 natively specifies three distinct leaf page granularities: 4 KiB pages, 2 MiB megapages, and 1 GiB gigapages.
In set-associative structures, superpages either require hashing across multiple sets or a dedicated separate superpage array. A fully associative CAM structure trivially supports arbitrary page sizes in every entry without set-conflict thrashing or capacity partitioning. For 16 entries, a parallel CAM search incurs minimal area (<1.5 Kbits total storage) and meets single-cycle timing with large slack.

### 2.3 Exact TLB Entry Layout
Each TLB entry stores exactly 81 bits:

| Bit Range | Field | Width | Description |
| :--- | :--- | :---: | :--- |
| `[80]` | `valid` | 1 | Entry valid flag (1 = valid translation, 0 = empty) |
| `[79:53]` | `vpn` | 27 | Virtual Page Number tag (`VA[38:12]`) |
| `[52:51]` | `level` | 2 | Page size encoding: `2'b00` = 4 KiB, `2'b01` = 2 MiB, `2'b10` = 1 GiB |
| `[50:7]` | `ppn` | 44 | Physical Page Number (`PA[55:12]`) from leaf PTE |
| `[6]` | `u` | 1 | User privilege bit (`PTE.U`) |
| `[5]` | `g` | 1 | Global mapping bit (`PTE.G`) |
| `[4]` | `r` | 1 | Read permission bit (`PTE.R`) |
| `[3]` | `w` | 1 | Write permission bit (`PTE.W`) |
| `[2]` | `x` | 1 | Execute permission bit (`PTE.X`) |
| `[1]` | `a` | 1 | Accessed bit (`PTE.A`) |
| `[0]` | `d` | 1 | Dirty bit (`PTE.D`) |

---

## 3. Supported Leaf Mappings and Superpage Handling

### 3.1 Sv39 Leaf Levels
The TLB supports all three standard Sv39 leaf page sizes as defined in RISC-V Privileged ISA Section 5.3:
- **Level 0**: Standard 4 KiB page.
- **Level 1**: 2 MiB megapage (`PTE.PPN[0] == 9'd0`).
- **Level 2**: 1 GiB gigapage (`PTE.PPN[1:0] == 18'd0`).

Superpage alignment checks (`PTE.PPN[0] == 0` for 2 MiB, `PTE.PPN[1:0] == 0` for 1 GiB) are performed by the PTW prior to insertion into the TLB. Misaligned superpages raise an immediate page fault and are never installed.

### 3.2 Tag Matching Rules
Let `req_vpn` be the 27-bit virtual page number of the incoming virtual address (`req_va[38:12]`). For entry $k$, a match occurs if and only if:

```text
match[k] = valid[k] && (
    (level[k] == 2'b00) ? (vpn[k][26:0]  == req_vpn[26:0])  :  // 4 KiB
    (level[k] == 2'b01) ? (vpn[k][26:9]  == req_vpn[26:9])  :  // 2 MiB
                          (vpn[k][26:18] == req_vpn[26:18])    // 1 GiB
);
```

### 3.3 Physical Address Formation
On a matching hit in entry $k$, the translated 56-bit physical address `pa[55:0]` is constructed combinationally by merging the entry PPN with the unmasked low bits of the incoming virtual address:

```text
pa[55:0] =
    (level[k] == 2'b00) ? {ppn[k][43:0],  req_va[11:0]} :  // 4 KiB
    (level[k] == 2'b01) ? {ppn[k][43:9],  req_va[20:0]} :  // 2 MiB
                          {ppn[k][43:18], req_va[29:0]};   // 1 GiB
```

The upper 8 bits (`pa[63:56]`) are zero-extended on the physical bus interfaces.

---

## 4. Permission Checking & Dynamic Privilege Rules

### 4.1 Cached Static Metadata vs Dynamic Architectural State
The TLB caches only **static PTE metadata** (`U, G, R, W, X, A, D`). All permission evaluations occur against the **live dynamic architectural state** of the core at the cycle of access:
- Current privilege mode: `priv_mode` ($P \in \{M, S, U\}$).
- Effective data privilege: $D_{\text{eff}} = (P == M \land \text{mstatus.MPRV}) \ ? \ \text{mstatus.MPP} : P$.
- Status register bits: `mstatus.SUM` (or `sstatus.SUM`) and `mstatus.MXR` (or `sstatus.MXR`).

*Consequence*: Modifying `SUM`, `MXR`, or `MPRV` takes effect on the very next cycle without requiring an `SFENCE.VMA` flush.

### 4.2 ITLB Hit Permission Checks
On an ITLB hit in entry $k$ for instruction fetch at privilege $P$:
1. **Privilege Check**:
   - If $P == U$: requires $\text{entry}_k.u == 1$. Violation $\rightarrow$ Instruction Page Fault (cause 12).
   - If $P == S$: requires $\text{entry}_k.u == 0$ (Supervisor execution of User pages is strictly prohibited, regardless of `SUM`). Violation $\rightarrow$ Instruction Page Fault (cause 12).
2. **Execute Permission**:
   - Requires $\text{entry}_k.x == 1$. Violation $\rightarrow$ Instruction Page Fault (cause 12).
3. **Accessed Bit (Svade)**:
   - Requires $\text{entry}_k.a == 1$. Violation $\rightarrow$ Instruction Page Fault (cause 12).

### 4.3 DTLB Hit Permission Checks
On a DTLB hit in entry $k$ for load, store, or AMO at effective privilege $D_{\text{eff}}$:
1. **Privilege Check**:
   - If $D_{\text{eff}} == U$: requires $\text{entry}_k.u == 1$. Violation $\rightarrow$ Load Page Fault (cause 13) or Store/AMO Page Fault (cause 15).
   - If $D_{\text{eff}} == S$: if $\text{entry}_k.u == 1$, requires `sstatus.SUM == 1`. Violation $\rightarrow$ Load Page Fault (cause 13) or Store/AMO Page Fault (cause 15).
2. **Read / Write Permission**:
   - For Load: requires $\text{entry}_k.r == 1 \lor (\text{sstatus.MXR} == 1 \land \text{entry}_k.x == 1)$. Violation $\rightarrow$ Load Page Fault (cause 13).
   - For Store: requires $\text{entry}_k.w == 1$. Violation $\rightarrow$ Store/AMO Page Fault (cause 15).
   - For AMO (RV64A): requires **both** read and write permission ($\text{entry}_k.r == 1 \land \text{entry}_k.w == 1$). Violation $\rightarrow$ Store/AMO Page Fault (cause 15).
3. **Accessed and Dirty Bits (Svade)**:
   - All data accesses require $\text{entry}_k.a == 1$. Violation $\rightarrow$ cause 13 (load) or cause 15 (store/AMO).
   - Store and AMO accesses additionally require $\text{entry}_k.d == 1$. Violation $\rightarrow$ Store/AMO Page Fault (cause 15).

---

## 5. PMP Interaction & Physical Address Validation

### 5.1 Non-Bypass Contract
The TLB translates virtual addresses to physical addresses; **it does not bypass PMP**.
Every translated physical address produced by a TLB hit must be validated against the frozen 16-entry Physical Memory Protection (PMP) unit before a physical transaction is dispatched to the bus.

### 5.2 Fault Disambiguation: Page Fault vs Access Fault
- **Page Faults (causes 12, 13, 15)** occur strictly during virtual-to-physical translation or permission checks on the PTE/TLB metadata.
- **Access Faults (causes 1, 5, 7)** occur when PMP denies access to the translated physical address or when the memory system reports a bus error.
- **Trap Value (`xTVAL`)**: In all cases where translation is active, `xTVAL` is written with the **original full 64-bit virtual address**, preserving the frozen specification in `sv39-mmu-v1.md` Section 8.1.

### 5.3 PTW PMP Validation
On a TLB miss, all implicit page table reads performed by the PTW remain subject to PMP checks (access type `READ`, privilege `S`). PMP denial of a PTE fetch generates an access fault on the original virtual address.

---

## 6. Lookup, Hit, and Miss Microarchitecture

```
              +---------------------------+
              | Virtual Request (vi / vd) |
              +---------------------------+
                            |
               [Canonical Address Check]
                   /                 \
             (Noncanonical)       (Canonical)
                 /                     \
       [Raise Page Fault]       +---------------+
                                |  TLB Lookup   |
                                +---------------+
                                  /           \
                             (Hit)             (Miss)
                              /                   \
                   [Permission & A/D]         [Activate PTW Walk]
                        /         \                 |
                   (Violated)   (Passed)      [PTW Completed]
                      /             \           /           \
             [Page Fault]        [PMP Check]  (Fault)    (Valid Leaf)
                                  /       \      |            |
                             (Denied)  (Passed) [Trap]  [Refill TLB (LRU)]
                                /           \                 |
                         [Access Fault]  [Phys Bus]     [Service Access]
```

### 6.1 Hit Latency: 0-Stall Combinational Forwarding
In Bare mode, Slice-0 translates with 0 additional cycles (combinational request forwarding).
The TLB preserves this exact timing as the normative initial implementation target:
- When a virtual address arrives on `vi_req` or `vd_req`, CAM lookup, hit detection, permission check, PA formation, and PMP checking are evaluated combinationally during the request phase.
- On a TLB hit with passed permissions and PMP, the physical request (`pi_req` or `pd_req`) is asserted to memory in the **very same cycle** (Cycle 0).
- DRAM/memory responds in Cycle 1.
- Total access latency on a TLB hit is **2 clock cycles** (identical to bare-metal DRAM access).
- *Timing Adaptation Freedom*: While 0-stall combinational forwarding is the initial implementation target, a 1-cycle registered hit pipeline path is architecturally permissible if subsequent physical synthesis or timing closure evidence demonstrates that the CAM-to-PMP combinational path limits target frequency.

### 6.2 Miss Behavior & PTW Refill
On a TLB miss:
1. The MMU transitions from `IDLE` to `PTW_REQ`.
2. The hardware PTW performs a serialized multi-level walk (taking 4 to 6 cycles depending on page level).
3. Upon successfully fetching and validating a leaf PTE:
   - The leaf PTE and VPN are installed into the corresponding TLB (ITLB for instruction fetch, DTLB for LSU) using the True-LRU replacement algorithm.
   - The original physical access is dispatched immediately (`FINAL_I_REQ` or `FINAL_D_REQ`).
4. If the walk fails at any stage (PTE `V=0`, reserved bits set, superpage misaligned, PMP denial on PTE read, leaf permission failure, or `A=0` / `D=0` failure):
   - The corresponding page fault or access fault is dispatched to the core.
   - **No TLB entry is allocated or updated.** Faulty translations are strictly excluded from the TLB.

### 6.3 Prioritization, Non-Preemption, and Redirect Discard
- LSU data translation misses have strict priority over instruction fetch misses.
- Once a data walk begins, it runs to completion non-preemptibly.
- **Instruction PTW Abort on Redirect**: Instruction fetches may be aborted cleanly if an asynchronous interrupt, trap, or return redirects the core (`redirect_i`) before the PTW completes. Any instruction walk aborted or drained because of `redirect_i` must discard arriving PTW responses and must never refill the ITLB with stale translation state.

---

## 7. `SFENCE.VMA` Semantics

### 7.1 Legality
Per RISC-V Privileged ISA Section 5.3:
- Legal in M-mode unconditionally.
- Legal in S-mode when `mstatus.TVM == 0`.
- Illegal in S-mode when `mstatus.TVM == 1` (raises Illegal Instruction, cause 2).
- Illegal in U-mode unconditionally (raises Illegal Instruction, cause 2).

### 7.2 Invalidation Scope (`ASIDLEN = 0`)
Because Fursoy Slice-0 implements `ASIDLEN = 0`, all address space identifier operands (`rs2`) designate the single local address space.
The implementation supports both global and address-selective flushes:

1. **Global Flush (`rs1 == x0`)**:
   - Clears the `valid` bit of **all 16 entries** in ITLB and **all 16 entries** in DTLB unconditionally.
   - Global mappings (`PTE.G == 1`) are also invalidated when `rs2 == x0`, and because `ASIDLEN = 0`, over-flushing all entries satisfies all `rs2` variants.
2. **Page-Selective Flush (`rs1 != x0`)**:
   - Let `vaddr = registers[rs1]`.
   - Compares `vaddr` against all valid entries in ITLB and DTLB.
   - Invalidates any entry whose mapping range covers `vaddr` (taking leaf `level` into account).
   - *Architectural Over-Flush Freedom*: In accordance with the RISC-V specification, the hardware is permitted to legally over-flush (e.g., executing a global flush on any `SFENCE.VMA`). However, for a 16-entry CAM, exact page invalidation is implemented with a single parallel comparator line.

### 7.3 Pipeline Ordering
An `SFENCE.VMA` instruction:
- Waits for all prior explicit data stores to retire and complete to the local memory visibility point.
- Drains any in-flight PTW transactions.
- Invalidates matching TLB entries in a single clock cycle.
- The subsequent instruction fetch begins only after the fence has committed.

---

## 8. `satp` Write Serialization and Invalidation

### 8.1 Required Serialization
Writing to `satp` (CSR 0x180) changes translation mode (`Bare` $\leftrightarrow$ `Sv39`) or the root page table pointer (`PPN`).
Although the RISC-V Privileged specification mandates that software must execute `SFENCE.VMA` to order page-table changes across address spaces, hardware safety requires deterministic behavior across mode changes.

### 8.2 Invalidation Contract
To eliminate stale translation risks across address spaces:
- **Any committed write to `satp` that modifies `MODE` or `PPN` automatically invalidates all entries in both ITLB and DTLB.**
- Because the core is single-issue and in-order, the new `satp` value is registered at the commit stage, and the very next instruction fetch (at `pc + 4`) immediately uses the fresh translation context.

---

## 9. Privilege Modes, MPRV, and Translation Context
 
| Mode | `satp.MODE` | `mstatus.MPRV` | `mstatus.MPP` | Instruction Fetch | Data Access (Load/Store/AMO) |
| :--- | :---: | :---: | :---: | :--- | :--- |
| **M-mode** | Any | 0 | Any | Bypass TLB; physical access | Bypass TLB; physical access |
| **M-mode** | Bare (0) | 1 | Any | Bypass TLB; physical access | Bypass TLB; physical access |
| **M-mode** | Sv39 (8) | 1 | M (3) | Bypass TLB; physical access | **Bypass TLB; physical access** ($D_{\text{eff}} = M$) |
| **M-mode** | Sv39 (8) | 1 | S (1) | Bypass TLB; physical access | **Translate via DTLB** using $D_{\text{eff}} = S$ |
| **M-mode** | Sv39 (8) | 1 | U (0) | Bypass TLB; physical access | **Translate via DTLB** using $D_{\text{eff}} = U$ |
| **S-mode** | Bare (0) | X | Any | Bypass TLB; physical access | Bypass TLB; physical access |
| **S-mode** | Sv39 (8) | X | Any | **Translate via ITLB** ($P = S$) | **Translate via DTLB** ($D_{\text{eff}} = S$) |
| **U-mode** | Bare (0) | X | Any | Bypass TLB; physical access | Bypass TLB; physical access |
| **U-mode** | Sv39 (8) | X | Any | **Translate via ITLB** ($P = U$) | **Translate via DTLB** ($D_{\text{eff}} = U$) |

*Rule*: Bypassed accesses never probe, allocate, or update the TLB. In particular, when `mstatus.MPRV == 1` but `mstatus.MPP == 2'b11` (M-mode), explicit M-mode data accesses bypass translation completely in conformance with the RISC-V Privileged ISA.

---

## 10. Accessed and Dirty (A/D) Semantics: Svade Policy

Fursoy Slice-0 implements the **Svade** architecture (Section 7 of `sv39-mmu-v1.md`):
- Hardware **never** modifies memory PTEs to set `A` or `D` bits.
- On a TLB hit:
  - If `A == 0`: immediately raises the corresponding page fault.
  - If `D == 0` on a store or AMO: immediately raises Store/AMO Page Fault (cause 15).
- On a TLB miss:
  - The PTW enforces `A == 1` (and `D == 1` for stores) before allowing leaf completion.
  - A leaf installed by a load may have $D = 0$. If a subsequent store hits this entry, the DTLB hit logic detects $D == 0$ combinationally and raises Store Page Fault (cause 15). Software handles the trap, updates the PTE dirty bit in memory, issues `SFENCE.VMA`, and re-executes.

---

## 11. Fault Precision and Trap State

### 11.1 Deterministic Exception Priority
For any memory access, exceptions are evaluated in strict architectural priority:
1. **Control / Instruction Fetch**:
   - Instruction address misaligned (cause 0) [evaluated by control unit before fetch].
   - Instruction Page Fault (cause 12) [noncanonical VA or ITLB/PTW permission/A-D failure].
   - Instruction Access Fault (cause 1) [PMP denial or physical bus error].
2. **Data Operations (Load/Store/AMO)**:
   - Address misaligned (cause 4 for load, cause 6 for store/AMO) [checked before translation].
   - Load/Store Page Fault (cause 13/15) [noncanonical VA or DTLB/PTW permission/A-D failure].
   - Load/Store Access Fault (cause 5/7) [PMP denial or physical bus error].

### 11.2 State Invariance on Faults
A faulting access never updates architectural state:
- No destination GPR is modified.
- No memory bus transaction is issued.
- No reservation is set or cleared.
- The trap records `xEPC = PC` and `xTVAL = VA`.

---

## 12. Interaction with Atomics (RV64A: LR/SC and AMOs)

1. **Load-Reserved (LR.W / LR.D)**:
   - Evaluated through DTLB with read permission.
   - Upon successful translation and PMP check, sets the core reservation register `res_exact_pa` to the exact physical address `pa[55:0]`.
2. **Store-Conditional (SC.W / SC.D)**:
   - Evaluated through DTLB with write permission.
   - Translation and write permissions are validated regardless of reservation status.
   - If write permission is denied (e.g. read-only page), SC raises Store Page Fault (cause 15) even if the reservation is invalid.
   - If valid and permitted, reservation match is verified against `pa[55:0]`.
3. **Atomic Memory Operations (AMO)**:
   - Evaluated through DTLB requiring dual Read and Write permissions ($R=1 \land W=1$) and $D=1$.
   - A single DTLB lookup translation provides the physical address for both the read and write phases of the atomic RMW sequence.

---

## 13. Comprehensive Invalidation Event Matrix

| Event / Instruction | ITLB Effect | DTLB Effect | Rationale / Architectural Requirement |
| :--- | :---: | :---: | :--- |
| **Hardware Reset (`rst_i`)** | Flush All | Flush All | Core initialization; clears all valid bits. |
| **`SFENCE.VMA (rs1=x0, rs2=x0)`** | Flush All | Flush All | Global flush across all address spaces. |
| **`SFENCE.VMA (rs1!=x0)`** | Flush VA | Flush VA | Address-selective flush of matching page. |
| **`satp` Write (CSR 0x180)** | Flush All | Flush All | Address space or MODE change serialization. |
| **`mstatus.SUM` or `MXR` Write** | No Flush | No Flush | Dynamically evaluated on every DTLB hit. |
| **PMP CSR Write (`pmpcfg*`, `pmpaddr*`)**| No Flush | No Flush | PMP checks physical addresses downstream of TLB. |
| **`FENCE.I`** | No Flush | No Flush | Synchronizes instruction cache/pipeline, not MMU. |
| **`FENCE`** | No Flush | No Flush | Orders data memory accesses; translation unaffected. |
| **Trap Entry / `MRET` / `SRET`** | No Flush | No Flush | Privilege mode updates dynamically re-evaluated. |

---

## 14. Verification and Test Plan

The implementation must be validated against a dedicated testbench suite (`verification/tlb_s0_tb.cpp` / `tools/run_tlb_s0.py`) covering at least 30 targeted scenarios:

1. **Basic Functionality & Capacity**:
   - ITLB cold miss $\rightarrow$ PTW walk $\rightarrow$ refill $\rightarrow$ consecutive hit (0-stall).
   - DTLB cold miss $\rightarrow$ PTW walk $\rightarrow$ refill $\rightarrow$ consecutive hit (0-stall).
   - True-LRU replacement verification across all 16 entries (verifying entry 0 eviction upon 17th unique page insertion).
2. **Superpage Translations**:
   - 4 KiB leaf translation and physical address formation.
   - 2 MiB megapage hit verification and address offset blending (`PA[20:0] = VA[20:0]`).
   - 1 GiB gigapage hit verification and address offset blending (`PA[29:0] = VA[29:0]`).
3. **Privilege & Dynamic State Checks**:
   - User page access from User mode (pass).
   - User page execute from Supervisor mode (instruction page fault).
   - User page data access from Supervisor mode with `SUM=0` (load page fault).
   - Dynamic toggle: setting `sstatus.SUM=1` allows immediate DTLB hit without flush.
   - Dynamic toggle: setting `sstatus.MXR=1` allows load from execute-only page without flush.
   - M-mode execution with `mstatus.MPRV=1` directing DTLB translation to `MPP=S`.
4. **Svade A/D Enforcement**:
   - Leaf with $A=0$ causes page fault on TLB lookup / refill.
   - Leaf with $A=1, D=0$ permits load but faults on subsequent store hit.
5. **Invalidation Scenarios**:
   - `SFENCE.VMA (x0, x0)` flushes all entries; subsequent access triggers PTW walk.
   - `SFENCE.VMA (va, x0)` flushes only the targeted page; adjacent page remains hitting.
   - `satp` write flushes TLB; switches translation immediately.
6. **PMP & Fault Handling**:
   - PMP entry denying physical page causes access fault on TLB hit (verifying PMP downstream).
   - PMP modification immediately takes effect without TLB flush.
7. **Atomics & Contention**:
   - Simultaneous ITLB hit and DTLB miss (DTLB PTW walk completes while ITLB remains valid).
   - LR/SC sequence hitting DTLB preserves exact reservation address.
   - AMO hitting DTLB validates read/write permissions atomically.
8. **Regression Suite**:
   - Existing 14 S-mode Bare scenarios pass.
   - Existing 28 PLIC scenarios pass.
   - Existing 40 SBI firmware scenarios pass.
   - Linux boot to `/init` userspace execution passes.

---

## 15. Conservative Performance Projections

Based on the frozen pre-optimization baseline measurements (179,281,319 cycles, 17,164,679 commits, 22,762,432 walks, 95,596,155 PTW-active cycles):

| Metric | Measured Baseline (No TLB) | Projected Range with L1 TLB | Projected Improvement |
| :--- | :---: | :---: | :---: |
| **Page Table Walks** | 22,762,432 walks | **< 1,000,000 walks** | **> 95% reduction** |
| **PTW-Active Cycles** | 95,596,155 cycles (53.3%) | **< 8,000,000 cycles (< 8%)** | **> 90% reduction** |
| **Total Boot Cycles** | 179,281,319 cycles | **95,000,000 – 105,000,000 cycles** | **~1.7x – 1.9x overall speedup** |
| **Overall Core IPC** | 0.0957 | **0.16 – 0.18** | **~1.7x – 1.9x IPC gain** |
| **Micro-Workload PTW %**| 55.8% (CPU) / 57.0% (MEM) | **< 1.0%** | **Virtually eliminated** |

*Note*: These figures are conservative architectural projections based on a 16-entry ITLB and 16-entry DTLB with high locality hit rates (>98% in sequential kernel code and loops). They do not represent measured RTL results.
