# Fursoy Slice-1 Milestone 4 — Frontend, Fetch, Prediction & Instruction Memory Architecture Specification

**Document ID:** `docs/architecture/slice1-m4-frontend-v1.md`  
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.0 (Milestone 4 Architecture — FROZEN)  
**Target Core:** Fursoy Slice-1 (Milestone 4: Instruction Fetch Subsystem, RV64IMA + Zicsr + Zifencei + Zba + Zbb + Sv39)  
**Predecessor Substrates (Frozen):**
- Milestone 1 (Verified & Frozen: PRF80, ROB48, FreeList48, SRAT/ARAT, Recovery Substrate)
- Milestone 2 (Verified & Frozen: PRF Data Storage 64b, IntIQ 16, Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV, Lossless WB)
- Milestone 3 (Verified & Frozen: MemIQ 12, LQ16, SQ16, Port 2 AGU, L1D 16 KiB 4W, 4 MSHR, 2 WBB, TRT4, PRF 6R3W)  
**Freeze Commit (M3):** `2ae4246eac2dcf4f98fc1209d70a3fd06e8dfe4a`  
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m2-backend-v1.md`, `docs/architecture/slice1-m3-memory-v1.md`

---

## 1. Executive Summary & Milestone Scope

### 1.1 Context & Objective
Fursoy Slice-1 Milestones 1, 2, and 3 established and froze a high-performance, 2-wide out-of-order execution core:
- **Milestone 1** provided the rename, allocation, circular ROB48, circular FreeList48, and branch checkpoint/recovery substrate.
- **Milestone 2** delivered 64-bit PRF storage, 16-entry IntIQ, Port 0 (ALU0/Branch), Port 1 (ALU1/MUL/DIV), lossless writeback arbitration, and M1-validated completion gating.
- **Milestone 3** integrated the out-of-order memory execution subsystem: Port 2 AGU, 12-entry MemIQ, 16-entry Load Queue, 16-entry Store Queue with bifurcated completion, non-blocking L1D cache, MSHRs, WBB, and persistent translation request tracking (TRT).

**Milestone 4 (M4)** completes the core by delivering the **instruction supply engine**: the instruction fetch unit, decoupled fetch queue, dynamic branch prediction subsystem, Return Address Stack (RAS), non-blocking L1 Instruction Cache (L1I), Instruction TLB (ITLB), centralized shared Page Table Walker (PTW), PMP execute validation, precise fetch exception delivery, and architectural `FENCE.I` synchronization.

```
+===================================================================================================+
|                                    MILESTONE 4 ARCHITECTURAL BOUNDARY                             |
+===================================================================================================+

    [ F0: Next-PC Gen & Redirect Mux ] <=========================== Backend Redirects (Port 0 EX)
                   |                                                ROB Head Traps / Returns
                   v
    [ F1: I-Cache & ITLB Request ] <---> [ ITLB (64-entry base + 8-entry CAM) ] <---> [ Shared PTW ]
                   |                                                                         |
                   v                                                                         v
    [ F2: L1I Read & Skid Buffer ] <---> [ 2-Entry I-MSHR ]                            Coherent Bus /
         |               |                                                             Interconnect
         |               +===> [ BTB (512-entry) ] ===> [ Gshare BPU ] ===> [ 16-entry RAS ]
         v                                                                        |
    [ F3: Align & Early JAL Check ] <---------------------------------------------+
         |
         v (Up to 2 Insts/Cycle + Metadata)
    [ F4: Decoupled Fetch Queue (12-entry FIFO) ]
         |
         v (2-wide Dequeue)
    [ D0: 2-Wide Parallel Decode & Exception Bypass ]
         |
         v uop_rename_in_t [1:0]
    +=============================================================================================+
    | FROZEN M1+M2+M3 EXECUTION CORE & MEMORY BACKEND                                             |
    | - 2-Wide Rename / Dispatch (M1)    - 48-Entry Circular ROB (M1)    - 8 Checkpoints (M1)     |
    | - 80-Entry PRF Data Storage (6R3W) - 16-Entry IntIQ / Port 0 / 1   - Port 0 Branch/JALR     |
    | - 12-Entry MemIQ / Port 2 AGU      - 16-Entry LQ / 16-Entry SQ     - Non-blocking L1D       |
    | - Cross-Milestone Extension: L1D Clean All Interface for FENCE.I (dcache_clean_all_req/done)|
    | - Cross-Milestone Extension: Port 0 JALR Target Misprediction Recovery                      |
    | - Cross-Milestone Extension: Shared PTW Memory Bus Arbitration Layer                        |
    +=============================================================================================+
```

### 1.2 In-Scope for Milestone 4
1. **Multistage Decoupled Frontend Pipeline**: F0 (Next-PC), F1 (I$/ITLB Request), F2 (I$ Read & Skid Buffer), F3 (Align & Early JAL Check), F4 (Fetch Queue Buffer), D0 (Decode & Exception Bypass).
2. **64-bit Fetch Bandwidth & Alignment**: Delivery of up to two 32-bit instructions per cycle from 64-bit aligned fetch blocks.
3. **Explicit RVC Exclusion**: Initial baseline strictly excludes 16-bit compressed instructions; all instructions are naturally 4-byte aligned ($PC[1:0] == 2\text{'b}00$).
4. **Decoupled Fetch Queue (Instruction Buffer)**: 12-entry FIFO isolating frontend memory latency and predictor bubbles from decode/rename.
5. **Dynamic Branch Prediction Subsystem**:
   - **BTB**: 512 entries, 2-way set-associative, with dual-branch evaluation per 64-bit block.
   - **Direction Predictor**: 4096-entry Gshare predictor with 12-bit global history register (GHR).
   - **Return Address Stack (RAS)**: 16-entry circular stack with full 16-entry checkpoint recovery.
6. **Speculative JALR Target-Mispredict Recovery (Resolution of P0-1)**: Defining a minimal cross-milestone integration extension allowing speculative JALR and return target predictions to allocate an M1 branch checkpoint, enabling Port 0 to assert recovery redirect on target mismatch.
7. **Speculative GHR Ownership (`pre_branch_ghr`)**: Every predicted conditional branch captures and carries its exact pre-branch GHR snapshot; younger branches cannot mutate older checkpointed history.
8. **Frontend-Local Predictor Recovery**: Clean rollback of speculative GHR and RAS state for unrenamed branches squashed in the Fetch Queue.
9. **Instruction Address Misaligned Attribution**: Attributed strictly to the control-flow instruction itself in the execution unit upon taken transfer to an unaligned target ($Target[1:0] \neq 2\text{'b}00$).
10. **Early Decode JAL Redirect Gating**: Gated by `!already_correctly_predicted` to eliminate duplicate redirects.
11. **Synchronous L1I Response Skid Buffer (Stage F2)**: 1-entry skid buffer absorbing synchronous SRAM responses during downstream Fetch Queue backpressure without data loss or duplicate enqueue.
12. **Dual Instruction MSHRs (I-MSHR)**: 2 MSHR entries eliminating redirect-under-miss starvation; dead refills install into L1I but suppress pipeline delivery.
13. **Instruction Translation Lookaside Buffer (ITLB) & Persistent ITRT**: 64-entry base page TLB + 8-entry superpage CAM for Sv39, with persistent request ownership tracking.
14. **Shared Hardware Page Table Walker (PTW) Implementation**: Centralized Sv39 3-level walker implemented in M4, arbitrating between M3 DTLB and M4 ITLB with bounded fairness (4:1).
15. **Architectural `FENCE.I` Visibility with Dirty L1D Clean (Resolution of P0-2)**: Full serialization sequence utilizing a cross-milestone L1D dirty line clean maintenance interface (`dcache_clean_all_req/done`) to ensure self-modifying code visibility before L1I invalidation.
16. **Real M4 System Serialization Controller (Elimination of Rejected Phantom Signals)**: Replacing rejected historical conceptual proposals (such as non-existent ROB `fence_i_flush_o` or `retire_stall_o` ports) with a real M4 System Serialization Controller tracking exact FENCE.I ROB lifetimes (`fence_i_rob_idx`, `fence_i_rob_epoch`) against frozen M1 `head_o` and driving `retire_ready_i` to hold retirement while M3 L1D clean and L1I invalidation complete.
17. **Decode Exception Bypass**: Stage D0 checks `exception_valid` first, emitting exception uops and bypassing opcode decode to prevent spurious Illegal Instruction traps.

### 1.3 Out-of-Scope for Milestone 4 (Deferred)
- **16-bit Compressed Instructions (RVC)**: Deferred to a dedicated extension pass; initial core strictly requires 32-bit aligned instructions.
- **Hardware Loop Predictors / TAGE**: Advanced predictor algorithms are provisional candidates; Gshare + BTB + RAS forms the canonical initial contract.
- **Instruction Pre-decoding Cache**: Pre-decode bits inside L1I are deferred.
- **Multi-Core Hardware Snoop Coherence**: Full directory coherence engine belongs to multi-core platform integration; M4 provides protocol-neutral invalidation hooks.

---

## 2. Master Parameter Classification Table

| Subsystem / Parameter | Milestone 4 Architectural Specification | Master Classification |
|---|---|---|
| **Fetch Bandwidth** | 64 bits / cycle (8-byte aligned fetch block) | **FROZEN SEMANTIC CONTRACT** |
| **Instruction Length** | 32 bits fixed (RVC compressed instructions excluded) | **FROZEN SEMANTIC CONTRACT** |
| **Decode Width** | 2 instructions / cycle into canonical micro-ops | **FROZEN SEMANTIC CONTRACT** |
| **Rename Handoff Width** | Up to 2 uops / cycle (gated by M1 `rename_ack_o`) | **FROZEN SEMANTIC CONTRACT** |
| **RVC Exclusion** | Canonical initial baseline strictly requires $PC[1:0] == 2\text{'b}00$ | **FROZEN SEMANTIC CONTRACT** |
| **Exact Redirect Priority** | Reset > Trap > MRET/SRET > Branch/JALR Mispredict > Early JAL > BPU > NextPC | **FROZEN SEMANTIC CONTRACT** |
| **JALR Recovery Extension** | Speculative JALR allocates M1 checkpoint; Port 0 triggers target recovery | **CROSS-MILESTONE INTEGRATION EXTENSION** |
| **FENCE.I Visibility** | Complete L1D dirty-line clean before L1I invalidation | **FROZEN SEMANTIC CONTRACT** |
| **L1D Clean Maintenance API**| `dcache_clean_all_req` / `dcache_clean_all_done` handshake | **CROSS-MILESTONE INTEGRATION EXTENSION** |
| **Shared PTW Scope** | Centralized Sv39 3-level PTW state machine implemented in M4 | **FROZEN SEMANTIC CONTRACT** |
| **PTW Memory Interface** | Dedicated memory arbitration layer outside frozen L1D | **CROSS-MILESTONE INTEGRATION EXTENSION** |
| **PTW Bounded Fairness** | Bounded 4:1 grant ratio (DTLB preferred; ITLB guaranteed after 4 grants)| **FROZEN SEMANTIC CONTRACT** |
| **Structural Non-Aliasing** | Persistent I-MSHR and ITRT transaction ownership until bus termination | **FROZEN SEMANTIC CONTRACT** |
| **Decode Exception Bypass** | Stage D0 bypasses decode if `exception_valid == 1` | **FROZEN SEMANTIC CONTRACT** |
| **Misaligned Attribution** | Attributed to control-flow instruction upon taken unaligned transfer | **FROZEN SEMANTIC CONTRACT** |
| **Early JAL Gating** | Gated by `!already_correctly_predicted` (eliminates double redirects) | **FROZEN SEMANTIC CONTRACT** |
| **F2 Skid Buffer** | 1-entry synchronous SRAM response hold buffer | **FROZEN SEMANTIC CONTRACT** |
| **GHR Ownership** | Carries `pre_branch_ghr`; restored from checkpoint on mispredict | **FROZEN SEMANTIC CONTRACT** |
| **RAS Rollback** | Full 16-entry logical state restoration per checkpoint | **FROZEN SEMANTIC CONTRACT** |
| **L1I Way Size Bound** | Way Size $\le 4\text{ KiB}$ ($64\text{ sets} \times 64\text{ bytes} = 4096\text{ bytes/way}$) | **FROZEN SEMANTIC CONTRACT** |
| **Reset Entry PC** | `64'h0000_0000_8000_0000` | **FROZEN SEMANTIC CONTRACT** |
| **Pipeline Partitioning** | 6-stage physical partitioning (F0, F1, F2, F3, F4, D0) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **Fetch Queue Depth** | 12 entries | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **BTB Capacity / Config** | 512 entries, 2-way set-associative (256 sets) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **Direction Predictor** | 4096-entry Gshare (12-bit GHR, 2-bit saturating counters) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **Return Address Stack** | 16 entries, circular stack | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **I-MSHR Depth** | 2 entries (eliminates redirect-under-miss starvation) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **L1I Capacity / Config** | 16 KiB 4-Way (baseline) or 32 KiB 8-Way (candidate) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **ITLB Base Capacity** | 64 entries, 4-way set-associative (4 KiB pages) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |
| **ITLB Superpage Capacity**| 8 entries, fully-associative CAM (2 MiB / 1 GiB pages) | **PROVISIONAL MICROARCHITECTURAL PARAMETER** |

---

## 3. Frontend Pipeline Stages & Skid Buffer Control

```
+===================================================================================================+
|                                  FRONTEND STAGE STRUCTURE (F0 - D0)                               |
+===================================================================================================+

 Stage  Name      Primary Function
 -----  --------  ----------------------------------------------------------------------------------
  F0    GenPC     Arbitrate next fetch PC among redirects and sequential stream.
  F1    ReqMem    Drive Fetch PC to L1I SRAM address decoders and ITLB CAM arrays.
  F2    RspMem    Read 64-bit I-cache block; evaluate ITLB; read BPU; 1-entry Skid Buffer.
  F3    Align     Extract up to two 32-bit instructions; evaluate early JAL; format metadata.
  F4    Queue     12-entry Decoupled Fetch Queue FIFO; buffers against backend backpressure.
  D0    Decode    Read up to 2 instructions; bypass on exception; decode to uop_rename_in_t.
```

### 3.1 Stage F0: Next-PC Generation (`GenPC`)
- **Sequential Next-PC Calculation**:
  - If fetch begins at lower half ($PC[2] == 0$): Both Slot 0 and Slot 1 are fetched. Next sequential fetch block address is:
    $$\text{next\_pc} = PC + 8$$
  - If fetch begins at upper half ($PC[2] == 1$): Only Slot 1 is delivered (Slot 0 masked). Next sequential fetch block address is:
    $$\text{next\_pc} = \{PC[63:3] + 1\text{'b}1, 3\text{'b}000\} = PC + 4$$
  - **CRITICAL**: The frontend **NEVER adds 8 to an odd-slot PC** ($PC[2]==1$), which would skip Slot 0 of the adjacent 64-bit block!

### 3.2 Stage F2: Synchronous L1I Response Skid Buffer (Resolution of P1 Finding)
Synchronous SRAM arrays present read data exactly 1 cycle after address assertion. If the downstream Fetch Queue becomes full in the exact cycle data emerges from L1I, the data cannot be accepted into F3/F4 and cannot be held inside the SRAM output latches without being clobbered:
- **1-Entry Skid / Hold Buffer (`f2_skid`)**:
  - `f2_skid_valid` (1 bit)
  - `f2_skid_data` (64 bits)
  - `f2_skid_pc` (64 bits)
  - `f2_skid_meta` (translation and exception flags)
- **Skid Operation Protocol**:
  1. Under normal operation (`f2_skid_valid == 0`), L1I SRAM data flows directly from F2 into F3.
  2. If F3/F4 asserts backpressure (`fetch_queue_full`):
     - The emerging L1I data is captured into the F2 skid buffer (`f2_skid_valid <= 1'b1`).
     - F0 and F1 freeze immediately (`stall_f0 = 1`, `stall_f1 = 1`). No new SRAM read is launched!
  3. While `f2_skid_valid == 1`:
     - F1 cannot launch new requests.
     - When F3/F4 unblocks, data is drained from the skid buffer into F3, and `f2_skid_valid <= 1'b0`.
  4. Guarantees: Zero dropped instruction bytes, zero SRAM overwrites, and zero duplicate enqueues.

### 3.3 Stage F3: Instruction Alignment & Gated Early JAL Redirect
- Slices 64-bit fetch block into Slot 0 ($PC[2]==0$, bits [31:0]) and Slot 1 ($PC[2]==1$, bits [63:32]).
- Evaluates JAL instructions. To prevent spurious duplicate redirects:
  ```verilog
  early_jal_redirect = decoded_jal && !already_correctly_predicted;
  ```
  where `already_correctly_predicted = btb_hit && (pred_target == computed_jal_target)`.
  - If the BTB already predicted the exact JAL target in F2, F3 **suppresses redirection**.
  - If the BTB missed or predicted the wrong target, F3 redirects F0 to the exact computed target $PC + \text{imm}$ immediately, saving execution-stage misprediction penalty cycles.

### 3.4 Stage D0: Decode & Exception Decode Bypass (Resolution of P1 Finding)
- **Decode Exception Bypass Rule**:
  Stage D0 tests `exception_valid` **FIRST**:
  ```verilog
  if (fetch_queue_rdata[slot].exception_valid) begin
      // Bypass normal instruction decoding entirely!
      uop_out[slot].valid           = 1'b1;
      uop_out[slot].exception       = 1'b1;
      uop_out[slot].exc_cause       = fetch_queue_rdata[slot].exception_cause;
      uop_out[slot].pc              = fetch_queue_rdata[slot].pc;
      uop_out[slot].uop_class       = UOP_ALU_INT; // benign placeholder uop
      uop_out[slot].rd              = 5'd0;        // x0 target (suppresses PRF write)
  end else begin
      // Standard 2-wide RISC-V instruction decode
      uop_out[slot] = decode_rv64(fetch_queue_rdata[slot].inst, fetch_queue_rdata[slot].pc);
  end
  ```
  - Faulting instruction bits are non-authoritative and treated as don't-care.
  - Guarantees that an instruction page fault or access fault is **never overwritten by an Illegal Instruction exception (Cause 2)**!

---

## 4. Control-Flow Checkpoint Classification & JALR Target Mispredict Recovery (Resolution of P0-1)

### 4.1 Evaluation of Approaches & Architectural Choice
The frozen backend previously evaluated target mismatches for `UOP_JALR` in the branch execution unit, but `fursoy_s1_backend.sv` only raised branch misprediction recovery for `UOP_BRANCH`. Under speculative target prediction (via RAS for returns or BTB for indirect calls/jumps), an incorrect target prediction would execute wrong-path instructions without a backend recovery path unless explicitly supported.

Two architectural approaches were evaluated:
1. **Conservative Fallback (Serialization)**:
   - Stall frontend fetch or dispatch upon encountering an unresolved `UOP_JALR` / return uop so that no younger instruction can become architecturally speculative past it.
   - Redirect frontend only after the actual target register is computed on Port 0.
   - *Evaluation*: Rejects speculative return and indirect branch prediction entirely. Incurs a 4-to-6 cycle penalty on every function return and indirect call, crippling IPC on typical workloads.
2. **Preferred Approach (Extend Control-Flow Recovery Semantics — CHOSEN & FROZEN)**:
   - Preserve speculative JALR/return execution by extending the control-flow integration contract:
     - JAL/JALR/return uops carry prediction metadata (`predicted_taken`, `predicted_target`, snapshot ID).
     - Port 0 branch/jump execution unit compares actual target against predicted target for conditional branches, JAL, JALR, and return uops.
     - Target mismatch on `UOP_JALR` generates the exact same precise recovery class as branch misprediction (`p0_wb_mispredict`).
     - Speculative `UOP_JALR` uops allocate an M1 branch checkpoint at Rename.
   - *Evaluation*: Preserves high single-thread performance while maintaining bit-exact recovery precision without altering frozen M1/M2 arithmetic, ROB ordering, or rename semantics.

### 4.2 Exhaustive Control-Flow Recovery Taxonomy
Every control-flow micro-op entering the pipeline is strictly classified across direction, target, and predictor-state recovery:

```
+===================================================================================================================================+
|                                              EXHAUSTIVE CONTROL-FLOW RECOVERY TAXONOMY                                            |
+===================================================================================================================================+

 Opcode Class         Target Nature     Pred Source   Dir Recovery?  Tgt Recovery?  Predictor Recovery?  Chkpt?  Recovery Trigger
 -------------------  ----------------  ------------  -------------  -------------  -------------------  ------  --------------------
 UOP_BRANCH           Cond PC+imm       Gshare + BTB  YES (Port 0)   YES (Port 0)   YES (GHR Rollback)   YES     Port 0 Dir/Tgt Mismatch
 UOP_JAL              Direct PC+imm     Computed/BTB  NO (Always T)  YES (F3 Early) NO                   NO      Stage F3 Early Corr
 CALL (JAL)           Direct PC+imm     Computed/BTB  NO (Always T)  YES (F3 Early) YES (RAS Spec Push)  NO      Stage F3 Early Corr
 CALL (JALR)          Reg Indirect      BTB           NO (Always T)  YES (Port 0)   YES (RAS Spec Push)  YES     Port 0 Target Mismatch
 RET (JALR)           Reg Indirect      RAS           NO (Always T)  YES (Port 0)   YES (RAS Spec Pop)   YES     Port 0 Target Mismatch
 UOP_JALR (Indirect)  Reg Indirect      BTB           NO (Always T)  YES (Port 0)   YES (BTB Tag Update) YES     Port 0 Target Mismatch
 Coroutine Swap JALR  Reg Indirect      RAS           NO (Always T)  YES (Port 0)   YES (RAS Pop+Push)   YES     Port 0 Target Mismatch
```

**Authoritative Invariant**: Every predicted target that can be wrong MUST allocate a recovery path (an M1 branch checkpoint) before younger instructions may enter the out-of-order execution window.

### 4.3 Detailed Speculative JALR Integration Contract
1. **Prediction Metadata Flow**:
   - Stage F2 captures `pred_target[63:0]` and `pred_taken` from RAS or BTB.
   - Stage F3/F4 packages this into `fetch_queue_entry.pred_target`.
   - Stage D0 decodes `UOP_JALR`. If speculatively predicted, D0 asserts `is_branch_i = 1'b1` to M1 Rename.
2. **Checkpoint Allocation at Rename**:
   - M1 Rename allocates one of the **8 branch checkpoints** for the speculative `JALR`, copying SRAT map, Free List state, `pre_branch_ghr`, and RAS logical state.
3. **Port 0 Resolution & Recovery**:
   - `u_branch_unit` calculates $\text{actual\_target} = (op\_a + \text{imm}) \ \& \ \sim 64\text{'d}1$.
   - Evaluates $\text{target\_mispredict} = (\text{actual\_target} \neq \text{pred\_target})$.
   - Port 0 writeback stage asserts `p0_wb_mispredict`:
     ```verilog
     p0_wb_mispredict <= (rf0_uop_q.uop_class == UOP_BRANCH || rf0_uop_q.uop_class == UOP_JALR) ? br_mispredict : 1'b0;
     ```
   - When `p0_wb_mispredict` asserts, M1 asserts `recover_fire`:
     - SRAT restored from the JALR's checkpoint;
     - All younger instructions in ROB, IntIQ, MemIQ, LQ, SQ, and Fetch Queue squashed;
     - Frontend redirected to `actual_target_o`.

---

## 5. Speculative GHR Ownership & Pre-Rename Predictor Recovery (Resolution of P1 Findings)

### 5.1 Carried Pre-Branch History (`pre_branch_ghr`)
Snapshotting the live frontend GHR at Rename is strictly forbidden because younger branches fetched while older branches wait in the Fetch Queue mutate the live GHR, corrupting the older branch's checkpoint.

1. **Prediction Point Capture (Stage F2)**:
   When conditional branch $B$ is evaluated in F2, it captures its exact pre-branch history:
   $$B.\text{pre\_branch\_ghr}[11:0] \Leftarrow \text{GHR}[11:0]$$
2. **Speculative Live Advancement**:
   The live frontend GHR shifts immediately to predict subsequent branches in the stream:
   $$\text{GHR} \Leftarrow \{\text{GHR}[10:0], B.\text{pred\_taken}\}$$
3. **Queue Encapsulation**:
   $B.\text{pre\_branch\_ghr}$ is stored in the Fetch Queue entry alongside $B$.
4. **Checkpoint Copy at Rename**:
   When branch $B$ allocates M1 checkpoint $k$ at Rename:
   $$\text{chkpt\_table}[k].\text{ghr}[11:0] \Leftarrow B.\text{pre\_branch\_ghr}[11:0]$$
   Younger branches in the Fetch Queue have zero influence on `chkpt_table[k].ghr`.
5. **Resolution & History Reconstruction on Port 0**:
   - *Correct Prediction*: Speculative GHR sequence is retained.
   - *Misprediction*: The recovery logic restores the branch's exact pre-branch snapshot and appends the actual resolved direction:
     $$\text{GHR}_{\text{recovered}} = \{\text{chkpt\_table}[k].\text{ghr}[10:0], \text{actual\_taken}\}$$
   - Bit-exact mathematical history restoration is guaranteed.

### 5.2 Frontend-Local Predictor Recovery Before Rename
Backend checkpoints do not exist for instructions waiting in the Fetch Queue. Four required scenarios must be handled without permanent GHR or RAS drift:
1. **Branch Predicted but Never Renamed**:
   - Occurs when a backend redirect or trap squashes the Fetch Queue while unrenamed predicted branches reside within it.
   - *Action*: Entire Fetch Queue is cleared; live GHR is restored from the backend checkpoint's $\text{GHR}_{\text{recovered}}$ (or cleared on trap/reset).
2. **Early Decode Redirect (Stage F3 JAL Correction)**:
   - When an unpredicted or mispredicted JAL redirects in F3, any younger branches fetched in F0..F2 are squashed.
   - *Action*: Live GHR is restored to the `pre_branch_ghr` of the instruction immediately following the JAL.
3. **Trap / Full Flush Before Branch Reaches Rename**:
   - An asynchronous interrupt or older instruction fault triggers an architectural flush.
   - *Action*: Live GHR is restored from the committed architectural state (or cleared).
4. **Backend Stall with Multiple Predicted Branches in Fetch Queue**:
   - Backend backpressure stalls Rename; multiple predicted branches accumulate in F4.
   - *Action*: Each branch preserves its own carried `pre_branch_ghr`. If a subsequent redirect invalidates a subset of the queue, the surviving queue boundary provides the authoritative restore snapshot.

---

## 6. Return Address Stack (RAS) Architecture & Full State Rollback

```
+===================================================================================================+
|                                    16-ENTRY CIRCULAR RAS DATAFLOW                                 |
+===================================================================================================+

    Push (Call): tos_ptr <= (tos_ptr + 1) & 4'hF;  RAS[tos_ptr] <= PC + 4;  depth <= min(depth+1, 16)
    Pop  (Ret):  pred_target <= RAS[tos_ptr];      tos_ptr <= (tos_ptr - 1) & 4'hF;  depth <= max(depth-1, 0)
    
    Full Checkpoint Storage (per M1 Checkpoint):
    [ 16 x 64-bit Return Addresses (1024 bits) | 4-bit tos_ptr | 5-bit depth ] = 1033 bits (~129 bytes)
```

### 6.1 The Overwrite Hazard & Full Logical State Checkpointing
Because the RAS is circular with finite depth (16 entries), speculative function calls on wrong execution paths can overwrite valid return addresses. Restoring only `tos_ptr` leaves the circular array containing corrupted return addresses, causing subsequent correct-path returns to mispredict.

- **Authoritative M4 Baseline Contract**:
  - Each of M1's **8 branch checkpoints** allocates a full logical RAS backup:
    $$\text{chkpt\_ras\_table}[k] = \{\text{ras\_array}[15:0], \text{tos\_ptr}[3:0], \text{depth}[4:0]\}$$
  - Total flip-flop overhead: $8 \times 1033\text{ bits} \approx 1\text{ KiB}$ of storage across the core.
- **Rollback Operation**:
  When Port 0 asserts `recover_valid_o` with checkpoint $k$:
  $$\text{ras\_array}[15:0] \Leftarrow \text{chkpt\_ras\_table}[k].\text{ras\_array}[15:0]$$
  $$\text{tos\_ptr} \Leftarrow \text{chkpt\_ras\_table}[k].\text{tos\_ptr}$$
  $$\text{depth} \Leftarrow \text{chkpt\_ras\_table}[k].\text{depth}$$
  - Fully restores the exact pre-branch call stack in 1 cycle, completely immune to speculative call overwrites.

### 6.2 Exhaustive Operational Semantics
- **Nested Calls**: Increments `tos_ptr` and pushes $PC + 4$.
- **Nested Returns**: Reads predicted target at `tos_ptr` and decrements `tos_ptr`.
- **Speculative Calls & Returns**: Updated speculatively at F2/F3 prediction time; protected by M1 checkpointing.
- **Overflow & Circular Wrap**: When `depth == 16`, subsequent calls increment `tos_ptr` modulo 16 and overwrite the oldest return address, saturating `depth` at 16.
- **Underflow**: When `depth == 0`, return reads `RAS[tos_ptr]` and keeps `depth = 0`.
- **Misprediction Recovery**: Fully restores array, pointer, and depth to checkpointed state.
- **Call PC Semantics**: The pushed return address is strictly $PC + 4$ (instructions are 4-byte fixed length; RVC excluded).

---

## 7. Instruction Address Misaligned Attribution & Precise Fault Packaging (Resolution of P1 Findings)

### 7.1 Misaligned Target Attribution Contract
In strict accordance with the RISC-V Unprivileged Specification:
1. **Attribution to Control-Flow Instruction**:
   The Instruction Address Misaligned exception (Cause 0) is generated **in the execute stage (Port 0)** by the branch or jump instruction whose target calculation violates alignment:
   ```verilog
   wire target_misaligned = (actual_target_o[1:0] != 2'b00);
   wire cause0_fire        = (uop_class == UOP_JAL || uop_class == UOP_JALR || 
                             (uop_class == UOP_BRANCH && actual_taken_o)) && target_misaligned;
   ```
2. **Conditional Branch Rule**:
   - If a conditional branch is **NOT TAKEN**, **ZERO exception is raised**, even if its immediate offset specifies an unaligned address!
3. **Exception Packaging**:
   - `retire_exception_o = 1'b1`
   - `retire_exc_cause_o = 5'd0` (Instruction Address Misaligned)
   - `retire_exc_pc_o = branch_uop.pc` (the PC of the branch/jump itself)
   - `mtval` / `stval` $\Leftarrow \text{actual\_target\_o}$ (the invalid misaligned address).
4. **Target Fetch Uop Eliminated**: No target fetch uop is ever launched or needed to report this trap.

### 7.2 Fetch Exception Precision & Fault Packet Definition
When a memory access fault (Cause 1) or page fault (Cause 12) occurs during instruction fetch:
- **Fault Packet Format**:
  - `fault_pc[63:0]`: Virtual address of the faulting instruction.
  - `cause[4:0]`: Precise RISC-V trap cause (Cause 1 or Cause 12).
  - `fault_addr[63:0]`: `mtval` / `stval` candidate (faulting virtual address).
  - `priv_mode[1:0]`: Privilege mode at fetch time.
- **Pipeline Progression**:
  - Fault packet flows through F3, F4, and D0 without mutation.
  - Stage D0 bypasses decode and emits a placeholder exception uop with `rd = x0`.
  - Wrong-path fault packets are squashed silently if an older branch mispredicts or redirects.
  - Architectural trap state (`mepc`, `mcause`, `mtval`, `mstatus`) updates **ONLY when the faulting uop reaches ROB head**.

---

## 8. Non-Blocking L1I Cache & Dual Instruction MSHRs

```
+===================================================================================================+
|                                     L1I CACHE & DUAL I-MSHRs                                      |
+===================================================================================================+

   Line Size: Exactly 64 Bytes (512 bits)
   Way Size:  Exactly 4 KiB (64 Sets x 64 Bytes = 4096 Bytes)  <=== VIPT Synonym Safe!
   Baseline:  16 KiB, 4-Way Set Associative (64 Sets, 4 Ways) [Provisional]
   Candidate: 32 KiB, 8-Way Set Associative (64 Sets, 8 Ways) [Provisional]

   Instruction MSHR Array (2 Entries):
   [ I-MSHR 0 ]: {valid, line_paddr[55:6], waiter_valid, fetch_request_id, bus_tag=0}
   [ I-MSHR 1 ]: {valid, line_paddr[55:6], waiter_valid, fetch_request_id, bus_tag=1}
```

### 8.1 Dual I-MSHR Architecture & Starvation Immunity
With a single I-MSHR, if a wrong-path fetch misses in L1I and a branch redirect occurs, the frontend stalls until the slow external DRAM refill returns before issuing the correct-path fetch.
- **Dual I-MSHR Operation**:
  1. Wrong-path fetch allocates `I-MSHR[0]`.
  2. Branch misprediction occurs: `I-MSHR[0].waiter_valid <= 1'b0`.
  3. Correct-path fetch immediately launches and, if it misses, allocates `I-MSHR[1]`.
  4. Both external memory refills proceed concurrently.
  5. When `I-MSHR[0]` returns: Data installs into L1I tags/data array, but **delivery to fetch pipeline is suppressed** (`waiter_valid == 0`). `I-MSHR[0]` deallocates.
  6. When `I-MSHR[1]` returns: Data installs into L1I and delivers instructions immediately to F3/F4.
  7. Eliminates frontend pipeline starvation under branch mispredictions.

---

## 9. Instruction Translation (ITLB), Persistent ITRT & Shared Hardware PTW

```
+===================================================================================================+
|                                 SHARED HARDWARE PTW & ARBITRATION                                 |
+===================================================================================================+

    M4 ITLB Requester (itrt_id)                       M3 DTLB Requester (tr_id)
               |                                                 |
               v                                                 v
   +============================================================================+
   | CENTRALIZED HARDWARE PAGE TABLE WALKER (Sv39 3-LEVEL FSM)                  |
   | - Scope: Milestone 4 RTL Deliverable                                       |
   | - Priority Arbiter: DTLB Priority 1; ITLB Priority 2                       |
   | - Bounded Fairness: Forced ITLB Grant after 4 consecutive DTLB grants      |
   | - Dedicated Memory Read Port: Coherent 64-bit PTE reads outside frozen L1D |
   +============================================================================+
               |                                                 |
               v                                                 v
    M4 ITLB Refill / Replay                           M3 DTLB Refill / Replay
```

### 9.1 Shared PTW Ownership (M4 RTL Scope)
The centralized Sv39 hardware Page Table Walker is an **authoritative Milestone 4 RTL deliverable**:
- Accepts translation requests from M3 DTLB (carrying `tr_id[1:0]`) and M4 ITLB (carrying `itrt_id`).
- Implements 3-level page table traversal ($L2 \rightarrow L1 \rightarrow L0$).
- Performs memory reads via a dedicated memory arbitration layer outside frozen L1D.
- Memory access attributes: Strictly read-only, 64-bit aligned, subject to PMP execute/read checks, with persistent response tags matching request transaction IDs.

### 9.2 Exact Bounded Fairness Arbitration Algorithm
```verilog
always_ff @(posedge clk_i) begin
    if (rst_i) begin
        dtlb_grants_since_itlb <= 3'd0;
    end else if (ptw_arb_fire) begin
        if (ptw_grant_itlb) begin
            dtlb_grants_since_itlb <= 3'd0;
        end else if (ptw_grant_dtlb && itlb_req_pending) begin
            dtlb_grants_since_itlb <= dtlb_grants_since_itlb + 1'b1;
        end
    end
end

always_comb begin
    if (itlb_req_pending && (dtlb_grants_since_itlb >= 3'd4)) begin
        ptw_grant_itlb = 1'b1;
        ptw_grant_dtlb = 1'b0;
    end else if (dtlb_req_pending) begin
        ptw_grant_dtlb = 1'b1;
        ptw_grant_itlb = 1'b0;
    end else begin
        ptw_grant_itlb = itlb_req_pending;
        ptw_grant_dtlb = 1'b0;
    end
end
```
- Guarantees that frontend instruction translation can **never be starved indefinitely** under intense data memory traffic, while preserving DTLB priority to clear head stores.

### 9.3 Persistent ITRT Identity
Translation requests maintain persistent ownership across frontend flushes:
- If a redirect occurs while an ITLB miss is undergoing PTW translation, the ITRT entry sets `waiter_valid <= 1'b0`.
- When the PTW returns the PTE, the translation installs into the ITLB, but instruction fetch restart is suppressed.
- Guarantees zero response aliasing across translation epochs.

---

## 10. Architectural `FENCE.I` Synchronization & Dirty L1D Clean (Resolution of P0-2)

### 10.1 The Write-Back L1D Hazard
Because M3 L1D is write-back, a hart-local store modifying instruction bytes writes into an L1D cache line and marks it dirty. Draining the SQ and WBB does NOT push dirty bytes from L1D to external memory or L1I! If `FENCE.I` only invalidates L1I, subsequent instruction fetch will reload stale bytes from external memory.

### 10.2 Authoritative 9-Step `FENCE.I` Visibility Sequence
Milestone 4 defines a **Cross-Milestone Integration Extension** adding a maintenance clean handshake to L1D:
- `dcache_clean_all_req` (output from Serialization Controller to L1D)
- `dcache_clean_all_done` (input to Serialization Controller from L1D)

```
 Step  Subsystem              Action / Event
 ----  ---------------------  ----------------------------------------------------------------------
  1    Hart Store             Store modifies instruction bytes in memory.
  2    Store Retirement       Store commits at ROB head, drains from SQ into L1D, marks line DIRTY.
  3    FENCE.I at ROB Head    Exact tracked FENCE.I lifetime {rob_idx, rob_epoch} reaches ROB head_o;
                              Serialization Controller takes ownership and drives retire_ready_i = 1'b0.
  4    SQ Quiescence          Controller verifies SQ is completely empty (sq_empty_i == 1; all stores in L1D).
  5    L1D Clean Request      Controller asserts dcache_clean_all_req to L1D.
  6    L1D Write-Back Sweep   L1D writes back all dirty lines through WBB to memory; WBB drains;
                              L1D asserts dcache_clean_all_done.
  7    Frontend Invalidation  Controller asserts l1i_inval_all; L1I clears all valid tags;
                              Fetch Queue flushes; F0..D0 pipeline stages clear; I-MSHR killed.
  8    FENCE.I Retirement     Controller releases hold (retire_ready_i = 1'b1); FENCE.I retires
                              from ROB head exactly once.
  9    Architectural Refetch  Frontend redirects fetch to FENCE.I PC + 4, guaranteed to observe
                              fresh instruction bytes from coherent memory.
```

### 10.3 Real M4 System Serialization Controller (Elimination of Rejected Phantom Signals)
The frozen M1 ROB contains no `fence_i_flush_o` output port, nor does it define `retire_uop_o` or `retire_stall_o` signals. Any earlier conceptual references to such ports are explicitly recognized as rejected, non-existent historical wording. Milestone 4 defines the real authoritative **System / Control Serialization Controller** interfacing strictly with the verified frozen M1 ROB and M3 LSU interfaces:

1. **Exact FENCE.I Identity & Lifetime Tracking**:
   At FENCE.I dispatch and allocation in Rename, the controller captures the exact ROB allocation token from the frozen allocation bus (`alloc_rob_idx_o`, `alloc_rob_epoch_o`, `alloc_pc_i`):
   - `fence_i_rob_idx <= alloc_rob_idx_o[slot]` (6-bit ROB slot index)
   - `fence_i_rob_epoch <= alloc_rob_epoch_o[slot]` (ROB generation epoch tag)
   - `fence_i_pc <= alloc_pc_i[slot]` (FENCE.I instruction PC)
   - `fence_i_pending <= 1'b1`
   
   *Structurally Safe Ownership Invariant*: Tracking the combined tuple `{fence_i_rob_idx, fence_i_rob_epoch}` guarantees that circular ROB slot reuse across 48 entries can never cause a stale serialization controller entry to capture or alias a newly allocated younger instruction.

2. **ROB Head Detection via `head_o`**:
   The controller monitors the actual frozen M1 ROB head interface:
   - `head_o` (`rob_idx_t`)
   - `retire_rob_idx_o[0]` and `retire_epoch_o[0]`
   
   FENCE.I becomes the active serialization operation only when the exact tracked FENCE.I lifetime reaches the ROB head:
   ```verilog
   wire fence_i_at_head = fence_i_pending && (head_o == fence_i_rob_idx) && (retire_epoch_o[0] == fence_i_rob_epoch);
   ```

3. **Retirement Hold via Frozen `retire_ready_i`**:
   While FENCE.I is at the ROB head and serialization is incomplete, the controller drives:
   ```verilog
   retire_ready_i = !fence_i_hold_active;
   ```
   During this hold:
   - `retire_ready_i = 1'b0` is driven into the existing frozen ROB retirement ready port;
   - No FENCE.I retirement occurs;
   - No younger instruction can retire past FENCE.I (strict in-order retirement in `fursoy_s1_rob.sv` is maintained);
   - All older instructions prior to FENCE.I have already retired normally;
   - Memory quiescence and dirty cache maintenance proceed cleanly.

4. **Older Memory Quiescence & Dirty L1D Clean Handshake**:
   - The controller verifies older store quiescence by checking `sq_empty_i` from `fursoy_s1_lsu_queues.sv`, guaranteeing all prior stores have retired and drained from the Store Queue into L1D.
   - The controller then asserts `dcache_clean_all_req_o = 1'b1` to `fursoy_s1_l1d.sv`.
   - L1D executes an exhaustive sweep across all 64 sets $\times$ 4 ways, writes back all dirty lines through the Writeback Buffer (WBB) to external memory, and verifies WBB is empty before asserting `dcache_clean_all_done_i = 1'b1`.

5. **Frontend Invalidation & Pipeline Purge**:
   - Only after receiving `dcache_clean_all_done_i`, the controller asserts `l1i_inval_all_o = 1'b1`, clearing all valid tags across the entire L1I array.
   - Concurrently, the controller kills active instruction fetch waiters (I-MSHR `waiter_valid <= 1'b0`, ITRT `waiter_valid <= 1'b0`), purges the 12-entry Decoupled Fetch Queue, and resets all frontend pipeline stage registers (F0 through D0).

6. **Eventual Retirement & PC+4 Refetch**:
   - After L1D clean completion, WBB complete drain, L1I tag invalidation, and frontend purge are all confirmed:
     The controller releases the retirement hold by driving `retire_ready_i = 1'b1`.
   - `fursoy_s1_rob.sv` retires FENCE.I exactly once.
   - Upon FENCE.I retirement, the controller clears its pending flag (`fence_i_pending <= 1'b0`) and initiates a frontend redirect to `FENCE.I PC + 4`.
   - The frontend begins fetching the newly written instructions from coherent memory.

### 10.4 Self-Modifying Code Verification Matrix
The verification suite must explicitly validate dirty lines in three distinct states:
1. Dirty modified line resident in L1D cache array.
2. Modified line resident in Writeback Buffer (WBB) awaiting bus arbitration.
3. Modified line simultaneously involved in an active L1D refill and victim writeback.

---

## 11. Deterministic Redirect Priority Hierarchy & Side-Effects Matrix

```
+===================================================================================================+
|                              AUTHORITATIVE REDIRECT SIDE-EFFECTS MATRIX                           |
+===================================================================================================+

 Priority  Redirect Source      PC Target   F0..F3  Queue   GHR Action        RAS Action  I-MSHR  ITRT
 --------  -------------------  ----------  ------  ------  ----------------  ----------  ------  -----
    1      Reset (rst_i)        0x80000000  Reset   Reset   GHR <= 0          Reset       Kill    Kill
    2      Trap (ROB Head)      mtvec/stvec Clear   Clear   Restore ARAT/GHR  Reset       Kill    Kill
    3      Return (MRET/SRET)   mepc/sepc   Clear   Clear   Restore ARAT/GHR  Retain      Kill    Kill
    4      Port 0 Mispredict    actual_tgt  Clear   Clear   Restore Checkpoint Restore    Kill[w] Kill[w]
    5      Early JAL (F3)       PC + imm    ClearF0-F2 ClearQueue GHR Restore     Retain      Retain  Retain
    6      BPU Predict (F2)     pred_target ClearF0-F1 Retain Shift pred_taken Spec Update Retain Retain
    7      Sequential Next-PC   PC+8 / PC+4 Normal  Normal  Retain            Retain      Normal  Normal
```

### 11.1 Simultaneous Redirect Conflict Resolution
1. **Trap + Port 0 Mispredict**: ROB head trap has higher priority (Priority 2 vs Priority 4). Trap PC updates `PC`; branch mispredict recovery is squashed.
2. **MRET/SRET + Port 0 Mispredict**: MRET at ROB head overrides concurrent Port 0 branch recovery.
3. **FENCE.I Completion + Port 0 Mispredict**: FENCE.I at ROB head has already serialized all older uops; concurrent younger mispredict is impossible.
4. **Early JAL Correction + F2 BPU Prediction**: Stage F3 early JAL correction has higher priority (Priority 5 vs Priority 6), overriding concurrent F2 prediction.

---

## 12. Cross-Milestone Integration Extensions Summary

To preserve the absolute correctness and frozen status of Milestones 1, 2, and 3:

1. **Port 0 JALR Target Misprediction Recovery (Milestone 2 Extension)**:
   - `fursoy_s1_branch_unit.sv`: Evaluates target equality for `UOP_JALR`.
   - `fursoy_s1_backend.sv`: Asserts `p0_wb_mispredict` for `UOP_JALR` upon target mismatch.
   - `fursoy_s1_substrate.sv`: M1 Rename allocates branch checkpoints for speculative `UOP_JALR`.
2. **L1D Cache Clean Maintenance Interface (Milestone 3 Extension)**:
   - `fursoy_s1_l1d.sv`: Exposes `dcache_clean_all_req_i` and `dcache_clean_all_done_o`, performing an exhaustive sweep of all 64 sets $\times$ 4 ways, evicting dirty lines through WBB.
3. **Shared PTW Memory Arbitration Layer (Milestone 3 Extension)**:
   - Arbitrates external memory read requests between M3 L1D refills/writebacks and the M4 shared Page Table Walker outside the frozen L1D core.

---

## 13. Milestone 4 Verification Contract

### 13.1 Mandatory Directed Test Suite (48 Enumerated Scenarios)
Each test specifies explicit stimulus, expected architectural state/output, and explicit failure conditions:

1. **Sequential 2-Wide Fetch**:
   - *Stimulus*: 64 consecutive 32-bit ALU instructions at $PC=0x8000\_0000$.
   - *Expected*: Fetch and Decode sustain 2 uops/cycle delivery.
   - *Failure*: Any unexpected stall or bubble.
2. **Upper-Half Fetch Start ($PC[2]==1$)**:
   - *Stimulus*: Redirect to $PC=0x8000\_0004$.
   - *Expected*: Cycle 1 delivers Slot 1 only; Cycle 2 fetches from $PC=0x8000\_0008$.
   - *Failure*: Next-PC adds 8 to odd PC ($0x8000\_000C$) or drops Slot 1.
3. **Cache Line Boundary Crossing**:
   - *Stimulus*: Sequential execution across 64-byte boundary ($0x8000\_003C \rightarrow 0x8000\_0040$).
   - *Expected*: Seamless transition between L1I cache lines with zero dropped bytes.
   - *Failure*: Pipeline stall or wrong PC fetched.
4. **4 KiB Virtual Page Boundary Crossing**:
   - *Stimulus*: Code crossing from $0x8000\_0FFC$ to $0x8000\_1000$ under Sv39.
   - *Expected*: ITLB translates both pages seamlessly.
   - *Failure*: False page fault or incorrect physical address.
5. **Predicted Taken Branch (BTB Hit)**:
   - *Stimulus*: Conditional branch with BTB entry predicting taken.
   - *Expected*: F0 redirects to target in 1 cycle.
   - *Failure*: Sequential fetch continuation.
6. **Predicted Not-Taken Branch**:
   - *Stimulus*: Conditional branch predicting not-taken.
   - *Expected*: Sequential fetch continues uninterrupted.
   - *Failure*: Erroneous target redirect.
7. **Direction Misprediction Recovery**:
   - *Stimulus*: Branch predicted taken, actually not taken.
   - *Expected*: Port 0 asserts mispredict; M1 recovers SRAT; PC restores to fallthrough $PC+4$.
   - *Failure*: Pipeline hang or incorrect architectural register state.
8. **Conditional Target Misprediction Recovery**:
   - *Stimulus*: Branch predicted taken with incorrect target address.
   - *Expected*: Port 0 redirects to actual target; GHR restored.
   - *Failure*: Stale PC refetched.
9. **JALR Target Misprediction Recovery (Resolution of P0-1)**:
   - *Stimulus*: Indirect JALR predicted to address $A$; actual register contains address $B$.
   - *Expected*: Port 0 asserts `p0_wb_mispredict`; checkpoint recovers SRAT and RAS; fetch redirects to $B$.
   - *Failure*: Execution continues at $A$, or backend hangs without recovery.
10. **Return RAS Target Misprediction (Resolution of P0-1)**:
    - *Stimulus*: Function modifies return address on stack; `RET` predicted via stale RAS target.
    - *Expected*: Port 0 detects mismatch against actual register $ra$; triggers checkpoint recovery to correct address.
    - *Failure*: Wrong-path execution commits.
11. **Gated Early JAL Redirect (No Duplicate Redirect)**:
    - *Stimulus*: JAL instruction with BTB hit predicting exact target.
    - *Expected*: F3 early redirect is suppressed (`early_jal_redirect == 0`).
    - *Failure*: F3 issues duplicate redirect, causing fetch bubble.
12. **Early JAL Target Correction**:
    - *Stimulus*: JAL instruction missing in BTB.
    - *Expected*: F3 detects JAL and immediately redirects F0 to $PC+\text{imm}$ before Rename.
    - *Failure*: Redirect deferred until execution stage.
13. **Unrenamed Branch Squashed in Fetch Queue**:
    - *Stimulus*: 3 predicted branches queued in F4; older branch mispredicts.
    - *Expected*: Queue cleared; GHR restored from backend checkpoint; zero permanent GHR drift.
    - *Failure*: GHR retains speculative history of squashed branches.
14. **`pre_branch_ghr` Isolation**:
    - *Stimulus*: Branch $B_1$ queued; younger branch $B_2$ predicted in F2.
    - *Expected*: $B_1$'s checkpointed GHR matches history at $B_1$'s prediction cycle, unaffected by $B_2$.
    - *Failure*: $B_1$'s checkpoint contains $B_2$'s shifted history.
15. **Full RAS Checkpoint Rollback (Resolution of P1 Finding)**:
    - *Stimulus*: Speculative path executes 5 nested calls overwriting RAS array; branch resolves mispredicted.
    - *Expected*: Checkpoint restores full 16-entry array, `tos_ptr`, and depth bit-for-bit.
    - *Failure*: RAS retains overwritten addresses from wrong path.
16. **RAS Circular Wrap**:
    - *Stimulus*: 20 consecutive function calls without return.
    - *Expected*: `tos_ptr` wraps cleanly; oldest 4 entries overwritten; `depth` saturates at 16.
    - *Failure*: Pointer out-of-bounds or stack corruption.
17. **Instruction Address Misaligned on Taken Branch (Resolution of P1 Finding)**:
    - *Stimulus*: Taken branch with target ending in `2'b10`.
    - *Expected*: Port 0 raises Cause 0; exception PC = branch PC; `mtval` = misaligned target.
    - *Failure*: Target fetch uop launched, or exception attributed to target PC.
18. **Untaken Branch with Misaligned Offset**:
    - *Stimulus*: Untaken branch with immediate offset ending in `2'b10`.
    - *Expected*: Zero exception raised; execution continues sequentially.
    - *Failure*: Spurious Cause 0 exception.
19. **F2 Skid Buffer Absorption (Resolution of P1 Finding)**:
    - *Stimulus*: Downstream Fetch Queue becomes full in the cycle L1I SRAM data emerges.
    - *Expected*: Data captured in F2 skid buffer; F0/F1 frozen; data drained upon unblock without loss.
    - *Failure*: Data dropped or duplicated.
20. **Dual I-MSHR Redirect-Under-Miss (Resolution of P1 Finding)**:
    - *Stimulus*: Wrong-path fetch misses (`I-MSHR[0]`); branch redirects; correct-path fetch misses (`I-MSHR[1]`).
    - *Expected*: Both refills proceed concurrently; `I-MSHR[1]` delivers data immediately upon arrival.
    - *Failure*: Frontend stalls until `I-MSHR[0]` completes.
21. **Dead Refill Delivery Suppression**:
    - *Stimulus*: In-flight refill whose waiter was killed by redirect completes.
    - *Expected*: Data installs into L1I tags/data array; zero instructions pushed into Fetch Queue.
    - *Failure*: Wrong-path instructions delivered to queue.
22. **ITLB Base Page Hit**:
    - *Stimulus*: Fetch from mapped 4 KiB virtual page.
    - *Expected*: Single-cycle translation.
    - *Failure*: Multi-cycle translation stall.
23. **ITLB Superpage Hit**:
    - *Stimulus*: Fetch from mapped 2 MiB / 1 GiB superpage.
    - *Expected*: Single-cycle translation via 8-entry CAM.
    - *Failure*: Miss or incorrect physical page translation.
24. **ITLB Miss & Hardware PTW Walk**:
    - *Stimulus*: ITLB miss under Sv39.
    - *Expected*: Shared PTW completes 3-level walk, refills ITLB, resumes fetch.
    - *Failure*: PTW hang or illegal page table traversal.
25. **Shared PTW Bounded Fairness (Resolution of P1 Finding)**:
    - *Stimulus*: Continuous DTLB miss stream with 1 ITLB miss pending.
    - *Expected*: PTW grants ITLB request after exactly 4 DTLB grants.
    - *Failure*: ITLB starves for $>4$ DTLB grants.
26. **Decode Exception Bypass (Resolution of P1 Finding)**:
    - *Stimulus*: Instruction Page Fault (Cause 12) arrives at D0 with random data bits.
    - *Expected*: Stage D0 preserves Cause 12, bypasses decode, does not raise Cause 2.
    - *Failure*: Illegal Instruction (Cause 2) generated.
27. **Instruction Page Fault (Cause 12)**:
    - *Stimulus*: Fetch from page with $X=0$ in PTE.
    - *Expected*: Precise Cause 12 at ROB head with `stval` = faulting PC.
    - *Failure*: Instruction executes or wrong trap cause.
28. **Instruction Access Fault (Cause 1)**:
    - *Stimulus*: PMP execute denial on fetch address.
    - *Expected*: Precise Cause 1 at ROB head; external bus access suppressed.
    - *Failure*: Instruction executed.
29. **Wrong-Path Exception Suppression**:
    - *Stimulus*: Branch speculatively jumps into unmapped page; branch resolves not-taken.
    - *Expected*: Page fault squashed silently; zero architectural trap state updated.
    - *Failure*: Spurious trap invoked.
30. **`SFENCE.VMA` Invalidation**:
    - *Stimulus*: `SFENCE.VMA` executed.
    - *Expected*: ITLB entries invalidated; next fetch re-walks page table.
    - *Failure*: Stale translation used.
31. **`FENCE.I` Dirty L1D Clean (Resolution of P0-2)**:
    - *Stimulus*: Store modifies code; line dirty in L1D; `FENCE.I` executed.
    - *Expected*: L1D sweeps dirty line clean to memory; L1I invalidated; new code executed.
    - *Failure*: Stale old code executed from L1I.
32. **`FENCE.I` with Modified Line in WBB**:
    - *Stimulus*: Store modifies code; line evicted to WBB; `FENCE.I` executed.
    - *Expected*: WBB drains completely before L1I invalidation.
    - *Failure*: Stale code reloaded.
33. **Dual-Branch Block (Slot 0 Taken)**:
    - *Stimulus*: 64-bit block containing branches in Slot 0 and Slot 1; Slot 0 predicted taken.
    - *Expected*: Slot 1 masked and prevented from enqueue.
    - *Failure*: Slot 1 enqueued or executed.
34. **Dual-Branch Block (Slot 0 Not-Taken, Slot 1 Taken)**:
    - *Stimulus*: Slot 0 not-taken branch, Slot 1 taken branch.
    - *Expected*: Both enqueued; Slot 1 redirects next fetch.
    - *Failure*: Slot 1 dropped.
35. **Gshare Counter Saturation**:
    - *Stimulus*: 10 consecutive taken outcomes for same index.
    - *Expected*: Counter saturates at `2'b11`.
    - *Failure*: Counter wraps to `2'b00`.
36. **BTB Replacement Policy**:
    - *Stimulus*: 3 branches aliasing to same 2-way BTB set.
    - *Expected*: Pseudo-LRU replacement evicts oldest entry.
    - *Failure*: Thrashing or corrupted tags.
37. **Indirect `JALR` Non-Return Jump**:
    - *Stimulus*: Switch-table jump via `JALR x0, rs1, 0`.
    - *Expected*: Predicted via BTB; verified on Port 0.
    - *Failure*: Incorrectly pushed to RAS.
38. **Privilege Mode Switch (MRET / SRET)**:
    - *Stimulus*: SRET transitions from S-mode to U-mode.
    - *Expected*: ITLB enforces U-mode execute permissions immediately.
    - *Failure*: Privilege leak.
39. **Reset Sequence & Entry**:
    - *Stimulus*: Reset asserted and released.
    - *Expected*: Initial fetch begins at `0x8000_0000`; predictors clean.
    - *Failure*: Stale PC fetched.
40. **Simultaneous Trap and Branch Mispredict**:
    - *Stimulus*: ROB head trap and Port 0 branch mispredict fire in same cycle.
    - *Expected*: Trap overrides mispredict; fetch redirects to trap handler.
    - *Failure*: Fetch redirects to branch target.
41. **Simultaneous MRET and Branch Mispredict**:
    - *Stimulus*: MRET at ROB head and Port 0 mispredict fire in same cycle.
    - *Expected*: MRET overrides mispredict; fetch redirects to `mepc`.
    - *Failure*: Fetch redirects to branch target.
42. **Simultaneous Early JAL and BPU Predict**:
    - *Stimulus*: F3 detects unpredicted JAL while F2 predicts branch.
    - *Expected*: F3 JAL redirect overrides F2 prediction.
    - *Failure*: F2 branch takes precedence.
43. **Checkpoint Exhaustion Backpressure**:
    - *Stimulus*: 8 unresolved conditional branches in flight; 9th branch arrives at Rename.
    - *Expected*: Rename stalls cleanly until oldest branch resolves.
    - *Failure*: Checkpoint overwritten or dropped.
44. **Fetch Queue Empty to Full Transitions**:
    - *Stimulus*: Backend throttles dispatch, causing queue to fill, then clears.
    - *Expected*: Queue fills to 12, asserts backpressure, drains to 0 without deadlock.
    - *Failure*: FIFO pointer corruption.
45. **Call / Return Coroutine Swap**:
    - *Stimulus*: `JALR x1, x5, 0` swapping execution contexts.
    - *Expected*: Pops target from RAS, pushes $PC+4$.
    - *Failure*: Stack unbalanced.
46. **F2 Skid Buffer Flush on Redirect**:
    - *Stimulus*: F2 skid buffer valid when Port 0 mispredict redirect occurs.
    - *Expected*: Skid buffer flushed in 1 cycle (`f2_skid_valid <= 0`).
    - *Failure*: Stale instruction leaked into pipeline after redirect.
47. **ITRT Stale Response Suppression**:
    - *Stimulus*: ITLB miss squashed by redirect while PTW walk is active.
    - *Expected*: PTE installs in ITLB; instruction fetch replay suppressed.
    - *Failure*: Stale fetch launched.
48. **Adversarial Control-Flow Torture**:
    - *Stimulus*: 50,000 randomized branches, calls, returns, page table updates, and interrupts compared against architectural C++ reference model.
    - *Expected*: 0 mismatches, 0 assertion failures, 0 watchdog trips.
    - *Failure*: Any discrepancy between RTL and reference model.

### 13.2 Mandatory RTL Simulation Assertions
1. `assert property (@(posedge clk_i) !(fetch_valid && (fetch_pc[1:0] != 2'b00)));`
2. `assert property (@(posedge clk_i) !(uop_valid && uop_exception && !at_rob_head && csr_trap_fire));`
3. `assert property (@(posedge clk_i) !(imshr_rsp_valid && !imshr_waiter_valid && fetch_queue_push));`
4. `assert property (@(posedge clk_i) !(recover_fire && (recovered_ghr != expected_checkpoint_ghr)));`
5. `assert property (@(posedge clk_i) !(fence_i_retire && (l1i_valid_count != 0 || l1d_dirty_count != 0)));`
6. `assert property (@(posedge clk_i) !(f2_skid_valid && f2_sram_read_req));`
7. `assert property (@(posedge clk_i) !(itlb_pending && (dtlb_consecutive_grants > 4)));`
8. `assert property (@(posedge clk_i) !(fetch_queue_push && fetch_queue_full));`

---

## 14. Hardware Performance Event Instrumentation
1. `CSR_HPM_FETCH_WORDS`: Total 64-bit fetch blocks requested.
2. `CSR_HPM_FETCH_UOPS`: Total valid instruction uops delivered to Decode.
3. `CSR_HPM_FETCH_EMPTY_CYC`: Cycles frontend starved backend (Fetch Queue empty).
4. `CSR_HPM_FETCH_FULL_CYC`: Cycles frontend stalled on backend (Fetch Queue full).
5. `CSR_HPM_L1I_HITS`: Total L1I cache hits.
6. `CSR_HPM_L1I_MISSES`: Total L1I cache misses.
7. `CSR_HPM_ITLB_HITS`: Total ITLB translation hits.
8. `CSR_HPM_ITLB_MISSES`: Total ITLB translation misses.
9. `CSR_HPM_BTB_HITS`: Total branches finding a matching BTB entry.
10. `CSR_HPM_BTB_MISSES`: Total branches missing in the BTB.
11. `CSR_HPM_BPU_COND_PRED`: Total conditional branch predictions made.
12. `CSR_HPM_BPU_DIR_MISPRED`: Conditional branch direction mispredictions resolved on Port 0.
13. `CSR_HPM_BPU_TGT_MISPRED`: Branch or indirect jump target mispredictions resolved on Port 0.
14. `CSR_HPM_RAS_CALLS`: Total call pushes to RAS.
15. `CSR_HPM_RAS_RETURNS`: Total return pops from RAS.
16. `CSR_HPM_RAS_CORRECT`: Return instructions whose RAS prediction was verified correct on Port 0.
17. `CSR_HPM_FENCE_I_FLUSHES`: Total `FENCE.I` full L1D clean & L1I invalidation sequences completed.
18. `CSR_HPM_REDIRECT_CYC`: Pipeline penalty cycles lost during branch and trap flushes.

---

## 15. Conclusion & Architecture Freeze Sign-Off
Milestone 4 architectural specification v1.0 comprehensively resolves all review findings (P0=0, P1=0, P2=0, P3=0). It establishes mathematically sound JALR target recovery, architecturally rigorous `FENCE.I` dirty-line visibility, GHR/RAS checkpoint precision, dual I-MSHR starvation immunity, bounded-fair PTW arbitration, and seamless integration with the frozen M1/M2/M3 substrates. The Milestone 4 architecture is formally FROZEN. Milestone 4 RTL implementation is NOT STARTED.
