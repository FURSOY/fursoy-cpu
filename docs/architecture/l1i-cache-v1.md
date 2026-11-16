# L1 Instruction Cache (L1I) Architectural Contract — v1

Status: **REVISED ARCHITECTURE CONTRACT** (Resolving Independent Architecture Review Findings)  
Normative Baselines:
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 ("Zifencei" Instruction-Fetch Fence)
- `docs/architecture/sv39-tlb-v1.md` (Frozen Sv39 TLB v1 contract)
- `docs/architecture/sv39-mmu-v1.md` (Frozen Sv39 MMU & PTW contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection contract)
- `docs/architecture/fetch-s0.md` (Baseline Slice-0 fetch engine contract)

---

## 1. Authority, Scope, and Design Objectives

### 1.1 Purpose
This document defines the architectural contract for the first hardware **L1 Instruction Cache (L1I)** subsystem for the single-hart Fursoy Slice-0 processor.

The L1I acts strictly as an **instruction-fetch acceleration layer** integrated into the core frontend, positioned between the program counter sequencer and the physical memory interface. Its sole objective is to eliminate the dominant performance bottleneck identified in the post-TLB profiling milestone: **30,719,056 cycles** (56.75% of total execution time, 74.32% of all physical RAM accesses) spent waiting on 2-cycle external DRAM instruction round-trips.

### 1.2 Non-Goals and Deferred Features
The following features are explicitly deferred from the v1 milestone:
- **L1 Data Cache (L1D)**: Deferred to a subsequent memory optimization milestone.
- **Multicore Cache Coherence**: No hardware snooping, MESI protocols, or broadcast invalidations (Slice-0 is single-hart).
- **Instruction Prefetching**: No next-line or stream prefetch engines.
- **Branch Prediction / BTB**: Deferred until fetch pipelining is introduced.
- **Non-Blocking / Hit-Under-Miss**: The v1 core stalls sequentially on an L1I miss until line refill completes.
- **Modified TLB or Translation Behavior**: The Sv39 TLB v1 architecture and RTL remain completely frozen.

### 1.3 Module Boundary, Hierarchy, and Interface Contract
- **Module Identifier**: `fursoy_s0_l1i` (`rtl/core/fursoy_s0_l1i.sv`).
- **Hierarchy Location**: Instantiated within `fursoy_s0_core.sv`. It supersedes the basic `fursoy_s0_fetch` transaction block by integrating cache storage, Tree-PLRU replacement, hit detection, and the 8-beat refill state machine.
- **Architectural Port Definition**:
```systemverilog
module fursoy_s0_l1i #(
    parameter logic [63:0] RESET_PC = 64'h0000_0000_8000_0000
) (
    input  logic        clk_i,
    input  logic        rst_i,

    // Core Pipeline / Fetch Control
    input  logic        fetch_enable_i,
    input  logic        redirect_i,
    input  logic [63:0] fetch_pc_i,
    output logic        fetched_valid_o,
    input  logic        fetched_ready_i,
    output logic [63:0] fetched_pc_o,
    output logic [31:0] fetched_insn_o,
    output logic        fetched_error_o,
    output logic        fetched_page_fault_o,

    // Translation & Authorization Interface (from fursoy_s0_mmu)
    output logic [63:0] trans_req_addr_o,
    output logic        trans_req_valid_o,
    input  logic        trans_busy_i,         // Asserted when ITLB misses and PTW is active
    input  logic        trans_valid_i,        // Translation valid
    input  logic [55:0] trans_pa_i,           // Translated physical address
    input  logic        trans_page_fault_i,   // Canonical or page permission fault
    input  logic        trans_pmp_allow_i,    // Authoritative PMP execution permission

    // Flush and Invalidation Inputs
    input  logic        fence_i_flush_i,      // FENCE.I flash invalidation pulse
    input  logic        pmp_flush_i,          // PMP CSR write flush pulse

    // Dedicated Physical Refill Bus (Widened to 64-bit)
    output logic        imem_req_valid_o,
    input  logic        imem_req_ready_i,
    output logic [63:0] imem_req_addr_o,
    input  logic        imem_rsp_valid_i,
    output logic        imem_rsp_ready_o,
    input  logic [63:0] imem_rsp_data_i,
    input  logic        imem_rsp_error_i
);
```

---

## 2. Cache Organization and Geometry

### 2.1 Capacity, Associativity, and Line Size
- **Total Data Capacity**: **16 KiB** (16,384 bytes).
- **Line Size**: **64 bytes** (512 bits, or 16 standard 32-bit RISC-V instructions).
- **Associativity**: **4-way set-associative**.
- **Number of Sets**: **64 sets** (`64 sets × 4 ways × 64 bytes/line = 16,384 bytes`).
- **Replacement Policy**: **Tree-based Pseudo-LRU (Tree-PLRU)** (3 bits of replacement state per set).
- **Valid State**: 1 valid bit per line (256 valid bits total).

### 2.2 Address Decomposition
The Fursoy architecture employs 56-bit physical addresses (`PA[55:0]`) derived from Sv39 translation or bare-metal/M-mode identity addressing. The physical address is decomposed as follows:

| Field | Bit Range | Width | Description |
| :--- | :---: | :---: | :--- |
| **Byte Offset** | `PA[5:0]` | 6 bits | Selects byte within 64-byte line |
| ↳ *Instruction Word Select* | `PA[5:2]` | 4 bits | Selects one of sixteen 32-bit instruction words |
| ↳ *Subword Byte Offset* | `PA[1:0]` | 2 bits | Must be `2'b00` for 32-bit aligned instructions |
| **Set Index** | `PA[11:6]` | 6 bits | Selects one of 64 sets (`0 ... 63`) |
| **Physical Tag** | `PA[55:12]` | 44 bits | Compared against way tags for hit determination |

```
 55                                                12 11        6 5        2 1 0
+----------------------------------------------------+-----------+----------+----+
|                    Physical Tag                    | Set Index | Word Sel | 00 |
|                      (44 bits)                     |  (6 bits) | (4 bits) |(2b)|
+----------------------------------------------------+-----------+----------+----+
                                                     <------- Page Offset ------>
                                                     <-------- (12 bits) ------->
```

### 2.3 Physical and Virtual Index Equivalence (Zero-Aliasing VIPT)
Under the standard RISC-V Sv39 specification, pages are aligned to 4 KiB boundaries (`2^12` bytes). Therefore:
`VA[11:0] ≡ PA[11:0]`

Because the L1I set index (`bits [11:6]`) and byte offset (`bits [5:0]`) sum to exactly 12 bits, **the virtual index is mathematically identical to the physical index**:
`VA[11:6] ≡ PA[11:6]`

#### Architectural Invariants:
1. **Zero Synonym / Homonym Hazards**: Different virtual addresses mapping to the same physical address index the exact same cache set. No virtual aliasing or page-coloring restrictions can exist.
2. **Parallel Indexing with Physical Tagging (VIPT)**: The L1I set index can be selected combinationally using `PC[11:6]` simultaneously with the ITLB lookup, while tags are compared using the translated physical address `PA[55:12]`.

### 2.4 Cache Storage Array Layout
Each way entry in each set comprises:
1. **Valid Bit**: 1 bit (`valid_q`).
2. **Physical Tag**: 44 bits (`tag_q[43:0]`).
3. **Data Line**: 512 bits (`data_q[511:0]`, arranged as `8 × 64`-bit doublewords).

Total state storage:
- **Data Array**: `64 sets × 4 ways × 512 bits = 131,072 bits = 16 KiB`.
- **Tag Array**: `64 sets × 4 ways × (44 tag + 1 valid) = 11,520 bits = 1.406 KiB`.
- **PLRU State**: `64 sets × 3 bits = 192 bits`.

### 2.5 Replacement Policy (Tree-PLRU)
Each of the 64 sets maintains a 3-bit binary decision tree (`b0, b1, b2`):
- `b0`: Points to left pair (Ways 0, 1) when 0, or right pair (Ways 2, 3) when 1.
- `b1`: Points to Way 0 when 0, or Way 1 when 1.
- `b2`: Points to Way 2 when 0, or Way 3 when 1.

#### Victim Selection:
When a replacement is required on a line refill:

```text
Victim Way =
  Way 0,  if b_0 == 0 && b_1 == 0
  Way 1,  if b_0 == 0 && b_1 == 1
  Way 2,  if b_0 == 1 && b_2 == 0
  Way 3,  if b_0 == 1 && b_2 == 1
```

#### Tree Update on Access:
Whenever Way `W` is accessed (on a hit or upon refill completion), the tree bits are updated to point **away** from the accessed way:
- Access Way 0: `b0 <= 1`, `b1 <= 1`
- Access Way 1: `b0 <= 1`, `b1 <= 0`
- Access Way 2: `b0 <= 0`, `b2 <= 1`
- Access Way 3: `b0 <= 0`, `b2 <= 0`

---

## 3. Physical / Virtual Placement and Architectural Sequencing

To strictly preserve all frozen Sv39 TLB, Page Table Walker, and Physical Memory Protection (PMP) contracts, L1I access follows a mandatory, non-bypassable sequential authorization pipeline.

```
                    +------------------------------------+
                    |  Virtual Program Counter (PC_q)   |
                    +------------------------------------+
                                      |
                         [1. Canonical Check]
                                      |
                     +----------------+----------------+
                     | Valid Sv39                      | Non-canonical
                     v                                 v
        +-------------------------+      +---------------------------+
        |  ITLB Translation Stage |      |  Instruction Page Fault   |
        +-------------------------+      | (mtval = PC, no L1I/DRAM) |
                     |                   +---------------------------+
         [2. Perm & A/D Check]
                     |
       +-------------+-------------+
       | Pass                      | Page Fault (X=0, U mismatch, A=0)
       v                           v
+------------------+     +---------------------------+
| Physical Address |     |  Instruction Page Fault   |
|   (PA[55:0])     |     | (mtval = PC, no L1I/DRAM) |
+------------------+     +---------------------------+
       |
  [3. PMP Check]
       |
       +-------------+-------------+
       | Allowed                   | PMP Denied (X=0)
       v                           v
+------------------------+ +-----------------------------+
| L1I Physical Tag Match | |  Instruction Access Fault   |
|   (Set[11:6], Tag)     | | (mtval = PC, no L1I/DRAM)   |
+------------------------+ +-----------------------------+
       |
       +-------------+-------------+
       | Hit                       | Miss
       v                           v
+--------------------+     +-----------------------------+
| Return 32-bit Insn |     | 8-Beat DRAM Refill Sequence |
| (1-cycle hit path) |     |  (Validate line on complete)|
+--------------------+     +-----------------------------+
```

### 3.1 Strict Security and Fault Invariants
1. **No Cache Access Prior to Canonical Verification**: If `VA[63:39] != {25{VA[38]}}`, the core combinationally triggers an `instruction page fault` (`mcause=12`). Neither ITLB translation, L1I tag comparison, nor refill may occur.
2. **No Cache Access on Permission Faults**: If translation fails or page permissions disallow execution (`PTE.X == 0`, privilege mismatch, or un-accessed `PTE.A == 0`), an `instruction page fault` is generated. L1I lookup is aborted immediately.
3. **Authoritative PMP Barrier on Every Access**: PMP execution permission is evaluated on the exact physical address `PA[55:0]` on **every single instruction fetch and cache hit**. If PMP execution permission is denied (`trans_pmp_allow_i == 0`), an `instruction access fault` (`mcause=1`) is triggered immediately. **A hit in L1I shall never bypass PMP.**
4. **Original Virtual Address in `xTVAL`**: All instruction fetch synchronous exceptions write the original virtual address `PC_q` to `mtval` or `stval`, preserving Section 5.3 of the RISC-V Privileged ISA.

### 3.2 ITLB Miss Coordination and Refill Inhibition
1. **Parallel VIPT Indexing**: The set index `PC[11:6]` selects the target cache set in parallel with the ITLB translation request (`trans_req_addr_o <= PC`).
2. **Pipeline Stall on ITLB Miss / PTW Active**:
   - If ITLB misses, `fursoy_s0_mmu` asserts `trans_busy_i` and initiates a hardware Page Table Walk (PTW).
   - During the PTW, the physical address is not yet known. **L1I must completely stall**: tag comparison, hit completion, and refill initiation are strictly inhibited. L1I holds its indexed way data until the PTW completes.
3. **Strict Prohibition of Speculative Refills**:
   - Under no circumstances may an external DRAM refill request be launched while translation is pending or if translation/permission checks fail.
   - A physical memory refill request (`imem_req_valid_o`) is legally permitted **only after**:
     `trans_valid_i == 1 && trans_page_fault_i == 0 && trans_pmp_allow_i == 1 && l1i_tag_miss == 1`

---

## 4. Fetch Behavior and Pipeline Timing

### 4.1 Hit Latency and Interface Contract
- **Baseline Target: 1-Cycle Registered Hit Path**:
  - **Cycle 0 (`FETCH_REQ`)**: The fetch unit presents `PC_q`. The set index `PC[11:6]` selects the set in the L1I array combinationally, while `fursoy_s0_mmu` evaluates the canonical check and ITLB translation.
  - **Cycle 1 (`FETCH_HIT`)**: Assuming translation succeeds without PTW stall, physical tags are compared against `PA[55:12]`, qualified by `trans_pmp_allow_i`. On a hit, the matching way's data line is muxed by `PA[5:2]` to extract the 32-bit instruction word, and `fetched_valid_o` asserts to the core decode stage.
  - **Total Hit Latency**: Exactly **1 cycle** (saving 1 of the 2 wait cycles required by the external DRAM bus).
- **Permissible 0-Cycle Forwarding Mode**:
  - If physical synthesis and timing closure permit, an optional combinational hit path may be enabled. However, the architectural contract guarantees correctness under the 1-cycle registered path to avoid creating an unrealistic timing bottleneck.

### 4.2 Miss Detection and Stall Timing
- On Cycle 1, if all 4 tags in the selected set fail to match or have `valid == 0` (and translation/PMP checks have passed), an **L1I Miss** is signaled.
- The fetch unit asserts internal backpressure, preventing PC advancement and instruction retirement.
- The L1I controller transitions to the **Refill State Machine**.

---

## 5. Cache Refill Protocol

### 5.1 Refill Physical Interface and Bus Binding (Resolution of P1-1)
To preserve the existing simplicity of the Slice-0 memory hierarchy and avoid complex shared-bus arbitration with LSU/PTW traffic, L1I refills are bound to the **dedicated instruction memory interface (`imem_*`)**:

1. **Port Width Widening**:
   - The physical data path of the instruction response interface is widened from 32-bit (`imem_rsp_insn_i[31:0]`) to **64-bit data (`imem_rsp_data_i[63:0]`)** across `fursoy_s0_core.sv`, `fursoy_s0_soc.sv`, and simulation testbenches.
   - Signal definitions:
     - `output logic        imem_req_valid_o`: Refill beat request valid
     - `input  logic        imem_req_ready_i`: Memory controller beat request ready
     - `output logic [63:0] imem_req_addr_o`: Refill beat doubleword address
     - `input  logic        imem_rsp_valid_i`: Memory controller beat response valid
     - `output logic        imem_rsp_ready_o`: Refill beat response ready (always asserted during active refill)
     - `input  logic [63:0] imem_rsp_data_i`: 64-bit doubleword payload from DRAM
     - `input  logic        imem_rsp_error_i`: DRAM bus error indicator
2. **Refill Sequencing**:
   - A 64-byte cache line refill consists of **8 sequential 64-bit doubleword read requests**:
     `Line Base = PA[55:6] << 6`
     - Beat 0: `Line Base + 0x00`
     - Beat 1: `Line Base + 0x08`
     - Beat 2: `Line Base + 0x10`
     - Beat 3: `Line Base + 0x18`
     - Beat 4: `Line Base + 0x20`
     - Beat 5: `Line Base + 0x28`
     - Beat 6: `Line Base + 0x30`
     - Beat 7: `Line Base + 0x38`
3. **Decoupled Valid/Ready Handshake**:
   - A request beat fires when `imem_req_valid_o && imem_req_ready_i`.
   - A response beat is accepted when `imem_rsp_valid_i && imem_rsp_ready_o`.
   - Beats may experience arbitrary, randomized wait states from the memory controller without loss of synchronization.
4. **Zero Shared-Bus Arbitration**:
   - LSU loads, stores, AMOs, and Page Table Walker (PTW) memory accesses continue to exclusively use the separate, dedicated 64-bit `ram_*` port.
   - There is zero interleaving, zero bus contention, and no arbitration logic required between I-cache refills and data/PTW traffic.
   - The platform MMIO aperture decoding, CLINT, PLIC, and UART interfaces remain completely unaffected.

### 5.2 Line Atomicity and Partial Refill Invisibility
1. **Temporary Holding Buffer**: Incoming refill beats accumulate in an internal 512-bit refill line buffer (`refill_buf_q[511:0]`).
2. **Atomic Validation**: The targeted cache way (`tag_q`, `data_q`, and `valid_q`) is updated in a single atomic cycle **only after all 8 beats have been received without bus error and without an abort event**.
3. **No Architectural Visibility of Partial Lines**: A partially refilled line is never marked valid and cannot be hit by any subsequent fetch.

### 5.3 Deterministic Stale-Refill Suppression (Resolution of P1-2)
To eliminate all ambiguity and ensure strict determinism across traps, interrupts, resets, and code-modification events, L1I implements an unconditional abort mechanism:

1. **Refill Abort Trigger Events**:
   If ANY of the following events occurs while an 8-beat refill is active:
   - **Hardware Reset (`rst_i`)**
   - **`FENCE.I` execution (`fence_i_flush_i`)**
   - **PMP CSR write (`pmp_flush_i`)**
   - **Pipeline Redirect (`redirect_i` from synchronous trap or asynchronous interrupt)**
2. **Deterministic Abort Rule**:
   - The controller sets a sticky internal abort latch (`refill_abort_q <= 1'b1`).
   - **Bus Protocol Preservation**: The refill state machine must continue to handshake and cleanly absorb all remaining beats of the outstanding 8-beat transaction from the memory bus (`imem_rsp_ready_o <= 1'b1` when `imem_rsp_valid_i`). This prevents dangling bus responses or protocol desynchronization.
   - **Unconditional Line Discard**: Upon receipt of Beat 7:
     - The holding buffer is unconditionally discarded.
     - Cache array write is **inhibited**; `valid_q` remains `0`.
     - Tree-PLRU replacement state is **not updated**.
     - The fetched instruction is **never forwarded** to the core execution pipeline.
     - The abort latch is cleared (`refill_abort_q <= 1'b0`), and L1I returns to idle.
3. **Security and Consistency Guarantee**:
   - A line refill initiated prior to an invalidation event can **never** install or validate in the cache after the invalidation event.
   - Stale instructions or newly prohibited PMP regions cannot be installed into the cache through race conditions with in-flight refills.

### 5.4 Bus Fault Handling during Refill
If the platform memory interface asserts `imem_rsp_error_i` on any of the 8 beats:
1. The line buffer is discarded; `valid_q` is **not** set.
2. An `instruction access fault` (`mcause=1`) is signaled to the core.
3. **Never Cache a Fault**: A memory bus error is never installed into the cache.

---

## 6. Memory Attributes and MMIO Handling

### 6.1 Cacheable Address Range
Only physical addresses falling within platform DRAM aperture are cacheable:
`Cacheable Range = [0x8000_0000, 0x8FFF_FFFF] (256 MiB DRAM)`

### 6.2 MMIO and Unmapped Range Enforcement
- **Non-Cacheable Regions**:
  - CLINT: `0x0200_0000`
  - PLIC: `0x0C00_0000`
  - 16550 UART: `0x1000_0000`
  - Unmapped system apertures.
- **Enforcement Policy**:
  - Instruction fetches targeting physical addresses outside DRAM bypass the L1I cache entirely.
  - No cache line allocation or refill shall ever be initiated for MMIO or unmapped addresses.
  - Per the Fursoy platform contract, executing instructions from MMIO space generates an immediate `instruction access fault`.

---

## 7. `FENCE.I` and Invalidation Policy

### 7.1 `FENCE.I` Architectural Semantics
Per the RISC-V Zifencei standard, `FENCE.I` guarantees that stores to instruction memory executed prior to the fence become visible to instruction fetches executed after the fence.

In Fursoy Slice-0:
1. **Flash Invalidation**: `FENCE.I` synchronously clears all 256 valid bits across all sets and ways in a single cycle:
   `valid_q[0 ... 63][0 ... 3] ← 0`
2. **Fetch Buffer Flush**: Clears any pending or held instruction in `fursoy_s0_fetch`.
3. **In-Flight Refill Invalidation**: If an L1I refill is active when `FENCE.I` executes, the arriving line is discarded upon completion and not validated.
4. **Execution Synchronization**: Core instruction retirement resumes only after the invalidation is complete.

### 7.2 Comprehensive Invalidation Matrix

| Event / Instruction | L1I Invalidation Action | Architectural Justification |
| :--- | :---: | :--- |
| **Hardware Reset** | **Flash Invalidate All (256 lines)** | Mandatory; resets cache to empty state. |
| **`FENCE.I`** | **Flash Invalidate All (256 lines)** | Mandatory by RISC-V Zifencei specification. |
| **PMP CSR Write** | **Flash Invalidate All (256 lines)** | Conservative defense-in-depth: clears cached lines for newly restricted regions. (Authoritative security barrier remains the combinational PMP check evaluated on every hit). |
| **`SFENCE.VMA`** | **No Action** (L1I retains valid lines) | L1I is physically tagged (PIPT); physical memory contents are unchanged. Software modifying code must execute `FENCE.I`. (ITLB is flushed). |
| **`satp` CSR Write** | **No Action** (L1I retains valid lines) | Physical memory contents unchanged. (ITLB is flushed). |
| **Synchronous Traps** | **No Action** | Exception entry redirects PC; does not alter instruction contents. |
| **Interrupts (MTIP/SEIP)**| **No Action** | Interrupt service routines are regular code; cache contents remain valid. |
| **`MRET` / `SRET`** | **No Action** | Privilege mode return redirects PC; cache contents remain valid. |
| **Ordinary `FENCE`** | **No Action** | Standard `FENCE` orders data memory (LSU) accesses; does not affect instruction caches. |
| **Branches / Jumps** | **No Action** | Normal control-flow redirection. |

---

## 8. Coherence and Software Synchronization Rules

### 8.1 Single-Hart Coherence Contract
Slice-0 is a single-hart uniprocessor without hardware data-to-instruction cache snooping. Data stores from the LSU bypass L1I and write directly to physical DRAM.

### 8.2 Required Software Sequence for Code Modification
Software that modifies instructions in memory (such as JIT compilers, dynamic linkers, bootloaders loading ELFs, or kernel module loaders) must adhere to the standard RISC-V synchronization protocol:
```assembly
    # 1. Store modified instructions to memory
    sd      t0, 0(a0)
    # 2. Ensure data store reaches platform memory
    fence   w, w
    # 3. Synchronize instruction fetch by invalidating L1I
    fence.i
    # 4. Jump to newly generated code
    jalr    zero, 0(a0)
```
Following `fence.i`, any subsequent fetch to `0(a0)` misses L1I and fetches the updated instruction word directly from DRAM.

### 8.3 Hardware Store Invariant and `FENCE.I` Timing (No-L1D Architecture)
In the current Fursoy Slice-0 core:
1. **Unbuffered Synchronous Stores**: The core datapath (`fursoy_s0_lsu_port.sv`) contains no store buffers, write queues, or data cache. A store instruction retires only after the write transaction has been accepted by the platform memory controller (`ram_req_ready_i`).
2. **No In-Flight Stores at `FENCE.I`**: Because the core is non-pipelined and strictly in-order, all stores preceding `FENCE.I` in program order are guaranteed to have physically completed to platform DRAM before `FENCE.I` is decoded and executed.
3. **Flash Invalidation Sufficiency**: Therefore, a 1-cycle flash invalidation of the 256 valid bits in `fursoy_s0_l1i` (`valid_q <= '0'`) is fully sufficient to guarantee that all subsequent instruction fetches observe all previous stores, satisfying the RISC-V Zifencei architectural specification.

---

## 9. Verification Plan

The L1I implementation shall be verified using a dedicated Verilator testbench suite (`verification/l1i_s0_tb.cpp` and `tools/run_l1i_s0.py`) containing the following directed and randomized scenarios:

1. **Cold Miss & Refill**: Initial fetch to cold address verifies L1I miss, 8-beat DRAM refill, Tree-PLRU state update, and subsequent hit on repeated fetch.
2. **Intra-Line Sequential Hit**: Sequential execution across all 16 words within a single 64-byte line verifies 1 miss followed by 15 consecutive 1-cycle hits.
3. **Line Boundary Crossing**: Fetch spanning from word 15 of Line `N` to word 0 of Line `N+1` verifies clean transition and backpressure.
4. **4-Way Conflict & Tree-PLRU Replacement**: 5 consecutive addresses aliasing to the same set index (`addr[11:6]`) verify allocation into Ways 0, 1, 2, 3, followed by correct Tree-PLRU victim eviction and replacement.
5. **Redirect during Active Refill**: Triggering `redirect_i` during an 8-beat refill verifies that memory bus handshakes complete cleanly, the arriving line is discarded (`valid == 0`), the core PC vectors to the redirect target, and no stale instruction is executed.
6. **`FENCE.I` Invalidation**: Populating all 4 ways of multiple sets, executing `FENCE.I`, and verifying that every subsequent fetch causes a miss and fresh DRAM refill.
7. **Active Refill Interrupted by `FENCE.I`**: Asserting `fence_i_flush_i` on beat 3 of an 8-beat refill verifies that the bus transaction completes cleanly, line validation is suppressed (`valid == 0`), and subsequent fetches miss.
8. **Active Refill Interrupted by PMP CSR Write**: Asserting `pmp_flush_i` during an active refill verifies that line validation into the cache array is inhibited upon burst completion.
9. **Refill Bus Wait-State Jitter**: Injecting randomized multi-cycle delays on `imem_rsp_valid_i` between refill beats verifies proper accumulation in `refill_buf_q` without state machine desynchronization.
10. **Exhaustive Tree-PLRU Eviction Traversal**: Exercising all 8 replacement trajectories across all 4 ways to prove exact compliance with the Tree-PLRU decision tree equation.
11. **Code Modification Sequence**: Storing a new instruction opcode to DRAM, executing `FENCE w, w` and `FENCE.I`, and verifying that the core fetches and executes the new instruction rather than stale cached data.
12. **Stale Code Preservation without `FENCE.I`**: Storing to DRAM without `FENCE.I` verifies architectural adherence (stale cached instruction continues to hit and execute).
13. **Sv39 ITLB Translation Integration**: Active Sv39 paging verifies seamless translation through ITLB, correct physical tag matching, and multi-level superpage (2 MiB / 1 GiB) offset handling.
14. **ITLB Miss & PTW Pipeline Stall**: Verifying that an ITLB miss completely stalls L1I tag evaluation and inhibits external refill requests until PTW completes.
15. **PMP Execution Denial on Hit & Miss**: Setting a PMP rule denying execution verifies that PMP raises an `instruction access fault` without returning cache data, both on cache hits and misses.
16. **Non-Canonical Page Fault**: Attempting to fetch from non-canonical virtual addresses verifies immediate page fault without L1I allocation or memory transactions.
17. **Refill Bus Error**: Injecting `imem_rsp_error_i` during refill verifies line invalidation and generation of an `instruction access fault`.
18. **MMIO / Unmapped Refill Suppression**: Fetching from UART/CLINT/PLIC MMIO space or unmapped apertures verifies immediate access fault generation and proves that **zero** physical refill requests (`imem_req_valid_o`) are ever launched toward non-DRAM space.
19. **Linux 6.6.50 Boot Regression**: Full execution of the standard post-TLB Linux workload verifying:
    - Identical boot log and PID 1 `/init` execution.
    - Deterministic completion of CPU and Memory micro-benchmarks.
    - Zero kernel panics or register corruption.

---

## 10. Performance Opportunity Estimates

*Note: All figures below are theoretical projections based on the frozen post-TLB profiling baseline and do not represent measured RTL claims until completion of the verification milestone.*

### 10.1 Baseline Metrics (Post-TLB Frozen Baseline)
- Total execution cycles: **54,131,089**
- Committed instructions: **15,358,679**
- Baseline CPI: **3.524463** (IPC: 0.283731)
- Pure fetch wait cycles: **30,719,056** (56.75% of total cycles)
- Instruction fetch RAM transactions: **15,359,798** (74.32% of all RAM traffic)

### 10.2 Projected L1I v1 Impact (16 KiB 4-Way Set-Associative)

| Metric | Frozen Baseline (No L1I) | Projected L1I (1-Cycle Hit Path) | Projected L1I (0-Cycle Hit Path) | Projected Delta / Improvement |
| :--- | :---: | :---: | :---: | :---: |
| **L1I Hit Rate** | 0.0% | **~98.0% – 99.0%** | **~98.0% – 99.0%** | +98.5% cache hit rate |
| **Instruction DRAM Requests** | 15,359,798 | **~300,000 – 500,000** | **~300,000 – 500,000** | **~97.5% reduction** in fetch bus traffic |
| **Fetch Wait Cycles Saved** | 0 | **~15,050,000 cycles** | **~30,100,000 cycles** | Saves 1 cycle (registered) or 2 cycles (combinational) per hit |
| **Remaining Fetch Wait** | 30,719,056 | **~15,669,000 cycles** | **~619,000 cycles** | 49.0% (registered) to 98.0% (combinational) reduction |
| **Total Workload Cycles** | 54,131,089 | **~39,081,000 cycles** | **~24,031,000 cycles** | **1.385x speedup** (registered) / **2.252x speedup** (combinational) |
| **Projected Effective CPI** | **3.524** | **~2.544** | **~1.565** | **-0.98 CPI** (registered) / **-1.96 CPI** (combinational) |
| **Projected Effective IPC** | **0.284** | **~0.393** | **~0.639** | **+38.5% IPC** (registered) / **+125.1% IPC** (combinational) |
