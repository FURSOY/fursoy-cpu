# RV64A Standard Extension for Atomic Instructions — Architecture Contract — Accepted and Frozen v1

Status: RV64A architecture: independently reviewed — ACCEPT AND FREEZE.
This contract defines the minimal, correctness-first specification for implementing the
**RV64A** extension (Standard Extension for Atomic Instructions, Version 2.1) in the
single-core Fursoy RV64 platform (Slice-0).

The reviewed and frozen M/S/U Bare privilege architecture (`s-mode-bare-v1.md`),
Sv39 MMU architecture (`sv39-mmu-v1.md`), PMP architecture (`pmp-v1.md`), and
PLIC architecture (`plic-v1.md`) serve as the compatibility baseline.

---

## 1. Scope and architectural authority

### 1.1 Normative references

The normative authority for the RV64A extension defined in this document is:

1. **The RISC-V Instruction Set Manual, Volume I: Unprivileged Architecture**,
   Document Version 20240411 (Chapter 8: "A" Standard Extension for Atomic Instructions, Version 2.1).
2. **The RISC-V Instruction Set Manual, Volume II: Privileged Architecture**,
   Document Version 20260120 (Machine-Level ISA 1.13 and Supervisor-Level ISA 1.13).
3. **RISC-V Memory Consistency Model (RVWMO)**.

Provisions throughout this specification are categorized as:

- **Required**: Mandatory standard RISC-V RV64A behavior. RTL has no project freedom except
  where explicit implementation choices are permitted by the specification.
- **Choice**: A project design decision for the Fursoy platform among architecturally legal options.
- **Simplification**: A correctness-first restriction tailored for the single-hart Slice-0 baseline.

### 1.2 Scope Distinctions

| Feature Dimension | Standard RISC-V RV64A Baseline | Fursoy v1 Choice (Slice-0) | Slice-1 Evolution |
|---|---|---|---|
| **Supported Instructions** | LR/SC and 9 AMOs in `.W` (32-bit) and `.D` (64-bit) | **Full RV64A: 22 instructions** | Preserved |
| **Hart Count** | 1 or more harts | **Single Hart (Hart 0)** | Single Hart (`fursoy_s1_core`) |
| **Memory System** | Weakly ordered (RVWMO) | **In-order, single-outstanding serialized bus** | Coherent L1/L2 caches with MESI/MOESI |
| **AMO Execution** | Atomic bus transaction or coherent cache line locking | **Internal serialized Read-Modify-Write sequence** | Coherent cache line exclusivity or AXI5/TileLink atomic transactions |
| **SC Success Matching** | Exact address and matching access size | **Exact physical address (`pa[55:0]`) and exact size (`res_size`)** | Preserved |
| **Reservation Invalidation** | Physical address, granule between word and 4 KiB | **Physical Address (PA), 64-byte aligned granule** | Physical Address (PA), cache line granule (64 bytes) |
| **`aq` / `rl` Ordering** | Enforces memory ordering constraints | **Honored inherently by serialized program-order execution** | Enforced via store buffer draining and cache ordering tags |

**Explicitly Out of Scope (Non-Goals)**:
- Out-of-order execution, speculative memory accesses, store buffering, or non-blocking loads.
- L1/L2 data caches, MESI/MOESI cache coherence protocols, and snoop filters.
- Multicore hardware crossbars, interconnect-level atomic routing, or multi-hart synchronization.
- RISC-V Zabha (Byte and Halfword Atomics) or Zacas (Compare-and-Swap).
- Unaligned atomic accesses (strictly prohibited by RISC-V RV64A; unconditionally fault).

---

## 2. Complete instruction set and encodings

### 2.1 Instruction encoding taxonomy

All RV64A instructions belong to the major opcode **AMO** (`7'b0101111` = `0x2F`).
The encoding format is standard R-type with atomic ordering bits:

```
 31       27 26 25 24     20 19     15 14   12 11      7 6      0
+-----------+--+--+---------+---------+-------+---------+--------+
|  funct5   |aq|rl|   rs2   |   rs1   |funct3 |   rd    | 0101111|
+-----------+--+--+---------+---------+-------+---------+--------+
```

- **`funct3`**:
  - `3'b010`: 32-bit word operation (`.W`)
  - `3'b011`: 64-bit doubleword operation (`.D`)
  - All other `funct3` values (`000, 001, 100, 101, 110, 111`) are reserved and raise an **illegal instruction exception (cause 2)**.
- **`aq` (bit 26)**: Acquire memory ordering annotation.
- **`rl` (bit 25)**: Release memory ordering annotation.
- **`rs1` (bits 19:15)**: Source register specifying the effective memory address.
- **`rs2` (bits 24:20)**: Source register specifying operand 2 (store data for SC; second ALU operand for AMOs; **must be 00000 for LR**).
- **`rd` (bits 11:7)**: Destination register receiving loaded value (or SC completion status).

### 2.2 Instruction matrix

| Instruction | funct5 | funct3 | rs2 requirement | Operation Description |
|---|---|---|---|---|
| `LR.W` | `5'b00010` | `3'b010` | Must be `5'd0` | Load-Reserved 32-bit word; sign-extend to `rd`; register PA reservation |
| `LR.D` | `5'b00010` | `3'b011` | Must be `5'd0` | Load-Reserved 64-bit doubleword; load to `rd`; register PA reservation |
| `SC.W` | `5'b00011` | `3'b010` | Store data `rs2` | Store-Conditional 32-bit word; store if reservation matches; `rd <= success ? 0 : 1` |
| `SC.D` | `5'b00011` | `3'b011` | Store data `rs2` | Store-Conditional 64-bit doubleword; store if reservation matches; `rd <= success ? 0 : 1` |
| `AMOSWAP.W` | `5'b00001` | `3'b010` | Swap operand `rs2` | Atomic Swap word: `rd <= mem[rs1]`, `mem[rs1] <= rs2[31:0]` |
| `AMOSWAP.D` | `5'b00001` | `3'b011` | Swap operand `rs2` | Atomic Swap doubleword: `rd <= mem[rs1]`, `mem[rs1] <= rs2` |
| `AMOADD.W` | `5'b00000` | `3'b010` | Add operand `rs2` | Atomic Add word: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] + rs2[31:0]` |
| `AMOADD.D` | `5'b00000` | `3'b011` | Add operand `rs2` | Atomic Add doubleword: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] + rs2` |
| `AMOXOR.W` | `5'b00100` | `3'b010` | XOR operand `rs2` | Atomic XOR word: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] ^ rs2[31:0]` |
| `AMOXOR.D` | `5'b00100` | `3'b011` | XOR operand `rs2` | Atomic XOR doubleword: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] ^ rs2` |
| `AMOAND.W` | `5'b01100` | `3'b010` | AND operand `rs2` | Atomic AND word: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] & rs2[31:0]` |
| `AMOAND.D` | `5'b01100` | `3'b011` | AND operand `rs2` | Atomic AND doubleword: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] & rs2` |
| `AMOOR.W` | `5'b01000` | `3'b010` | OR operand `rs2` | Atomic OR word: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] | rs2[31:0]` |
| `AMOOR.D` | `5'b01000` | `3'b011` | OR operand `rs2` | Atomic OR doubleword: `rd <= mem[rs1]`, `mem[rs1] <= mem[rs1] | rs2` |
| `AMOMIN.W` | `5'b10000` | `3'b010` | Min operand `rs2` | Atomic Signed Min word: `rd <= mem[rs1]`, `mem[rs1] <= min_signed(mem, rs2)` |
| `AMOMIN.D` | `5'b10000` | `3'b011` | Min operand `rs2` | Atomic Signed Min doubleword: `rd <= mem[rs1]`, `mem[rs1] <= min_signed(mem, rs2)` |
| `AMOMAX.W` | `5'b10100` | `3'b010` | Max operand `rs2` | Atomic Signed Max word: `rd <= mem[rs1]`, `mem[rs1] <= max_signed(mem, rs2)` |
| `AMOMAX.D` | `5'b10100` | `3'b011` | Max operand `rs2` | Atomic Signed Max doubleword: `rd <= mem[rs1]`, `mem[rs1] <= max_signed(mem, rs2)` |
| `AMOMINU.W` | `5'b11000` | `3'b010` | MinU operand `rs2` | Atomic Unsigned Min word: `rd <= mem[rs1]`, `mem[rs1] <= min_unsigned(mem, rs2)` |
| `AMOMINU.D` | `5'b11000` | `3'b011` | MinU operand `rs2` | Atomic Unsigned Min doubleword: `rd <= mem[rs1]`, `mem[rs1] <= min_unsigned(mem, rs2)` |
| `AMOMAXU.W` | `5'b11100` | `3'b010` | MaxU operand `rs2` | Atomic Unsigned Max word: `rd <= mem[rs1]`, `mem[rs1] <= max_unsigned(mem, rs2)` |
| `AMOMAXU.D` | `5'b11100` | `3'b011` | MaxU operand `rs2` | Atomic Unsigned Max doubleword: `rd <= mem[rs1]`, `mem[rs1] <= max_unsigned(mem, rs2)` |

**Required (Illegal Encodings)**:
- If `LR.W` or `LR.D` specifies `rs2 != 5'd0`, the instruction is reserved and raises an **illegal instruction exception (cause 2)**.
- Any undefined `funct5` value raises an **illegal instruction exception (cause 2)**.

---

## 3. Load-Reserved / Store-Conditional (LR/SC) specification

### 3.1 Reservation registration: Physical Address (PA)

**Choice**: The reservation address is tracked strictly using the **Physical Address (PA)** resulting from address translation (or bare physical address), rather than the Virtual Address (VA).

**Rationale**:
1. **Virtual Aliasing**: Multiple distinct virtual addresses ($VA_1 \neq VA_2$) may map to the same physical address ($PA$). Tracking PA guarantees that an intervening store through an alias address $VA_2$ correctly invalidates a reservation registered through $VA_1$.
2. **Translation Context Modifications**: Virtual-to-physical mappings can change dynamically via page table updates or ASID/SATP switches. A VA-based reservation would become stale or dissociated from physical memory.
3. **Coherent Physical Address Space**: External snoop/invalidation buses operate in physical address space; tracking PA keeps the reservation model clean and alias-free.

### 3.2 Reservation state architecture: separation of matching and invalidation

**Critical Distinction**: The core separates the predicate for **SC success matching** from the granule used for **reservation invalidation / conflict tracking**.

The core maintains the following explicit reservation state:
- `res_valid`: 1-bit active reservation flag.
- `res_exact_pa`: Exact 56-bit physical byte address (`pa[55:0]`) of the registered `LR` instruction.
- `res_size`: Exact access size of the registered `LR` instruction (`2'b10` for 32-bit word, `2'b11` for 64-bit doubleword).
- `res_granule_pa`: 64-byte aligned reservation set address (`pa[55:6]`), used exclusively for conflict detection against intervening writes.

### 3.3 SC success matching rule

A Store-Conditional (`SC.W` or `SC.D`) evaluates success strictly by comparing:
- Active reservation flag (`res_valid`);
- Exact physical address match (`sc_pa[55:0] == res_exact_pa`);
- Exact access width match (`sc_size == res_size`).

$$\text{reservation\_matches} = \text{res\_valid} \land (\text{sc\_pa} == \text{res\_exact\_pa}) \land (\text{sc\_size} == \text{res\_size})$$

**Architectural Consequences**:
- `LR.W @ A` followed by `SC.W @ A` may succeed.
- `LR.D @ A` followed by `SC.D @ A` may succeed.
- `LR.W @ A` followed by `SC.W @ A+4` **must fail**, even though both addresses reside within the same 64-byte reservation granule.
- `LR.W @ A` followed by `SC.D @ A` **must fail** (size mismatch).
- `LR.D @ A` followed by `SC.W @ A` **must fail** (size mismatch).

### 3.4 LR operation semantics

`LR.W` and `LR.D` execute with the following lifecycle:

1. **Address Calculation & Alignment Check**:
   - Compute effective virtual address: $VA = \text{rs1}$.
   - Check natural alignment:
     - `LR.W`: $VA[1:0] == 2'b00$. If misaligned, raise **Load address misaligned exception (cause 4)** with $mtval/stval = VA$.
     - `LR.D`: $VA[2:0] == 3'b000$. If misaligned, raise **Load address misaligned exception (cause 4)** with $mtval/stval = VA$.
2. **MMU Translation & PMP Check**:
   - Perform address translation as a **LOAD** operation (`req_op = 2'b01`).
   - Evaluate Sv39 leaf PTE permissions ($R=1$ or ($MXR=1 \land X=1$); $U/S$ permissions; $A=1$ under Svade).
   - Evaluate PMP matching entry for read permission ($R=1$).
   - If translation fails, raise **Load page fault (cause 13)** with $mtval/stval = VA$.
   - If PMP fails, raise **Load access fault (cause 5)** with $mtval/stval = VA$.
3. **Memory Access & Registration**:
   - Issue physical read to memory adapter.
   - If memory adapter returns bus error, raise **Load access fault (cause 5)** with $mtval/stval = VA$.
   - On successful read data return:
     - Register active reservation:
       - `res_valid <= 1'b1`;
       - `res_exact_pa <= pa[55:0]`;
       - `res_size <= (insn[12] ? 2'b11 : 2'b10)`; // D: 2'b11, W: 2'b10
       - `res_granule_pa <= pa[55:6]`.
     - Write loaded data to destination register `rd`:
       - `LR.W`: 32-bit data is **sign-extended** to 64 bits: $rd \Leftarrow \{\{32\{\text{data}[31]\}\}, \text{data}[31:0]\}$.
       - `LR.D`: 64-bit data is loaded directly: $rd \Leftarrow \text{data}[63:0]$.
     - If $rd == x0$, register update is suppressed per RV64I base rules, but the reservation **is still registered**.

### 3.5 SC operation semantics

`SC.W` and `SC.D` execute with the following lifecycle:

1. **Address Calculation & Alignment Check**:
   - Compute effective virtual address: $VA = \text{rs1}$.
   - Check natural alignment:
     - `SC.W`: $VA[1:0] == 2'b00$. If misaligned, raise **Store/AMO address misaligned exception (cause 6)** with $mtval/stval = VA$.
     - `SC.D`: $VA[2:0] == 3'b000$. If misaligned, raise **Store/AMO address misaligned exception (cause 6)** with $mtval/stval = VA$.
   - *Crucial Rule*: Alignment check occurs unconditionally. A misaligned SC raises cause 6 regardless of whether a valid reservation exists.
2. **MMU Translation & PMP Check**:
   - Perform address translation as a **STORE** operation (`req_op = 2'b10`).
   - Evaluate Sv39 leaf PTE permissions ($W=1 \land D=1 \land A=1$; $U/S$ permissions).
   - Evaluate PMP matching entry for write permission ($W=1$).
   - If translation fails, raise **Store/AMO page fault (cause 15)** with $mtval/stval = VA$.
   - If PMP fails, raise **Store/AMO access fault (cause 7)** with $mtval/stval = VA$.
   - *Crucial Rule*: Address translation and PMP checks occur before reservation success evaluation. An SC to an unmapped or write-protected page raises cause 15 or cause 7, even if no reservation exists or the address mismatches.
3. **Reservation Match Evaluation**:
   - Evaluate $\text{reservation\_matches} = \text{res\_valid} \land (\text{sc\_pa} == \text{res\_exact\_pa}) \land (\text{sc\_size} == \text{res\_size})$.
4. **Conditional Execution**:
   - **Case A: Successful SC** ($\text{reservation\_matches} == 1$):
     - Atomically issue physical store to memory:
       - `SC.W`: writes `rs2[31:0]` (size 32-bit word, `req_size = 3'b010`).
       - `SC.D`: writes `rs2[63:0]` (size 64-bit doubleword, `req_size = 3'b011`).
     - If memory adapter returns a store error:
       - Suppress `rd` writeback.
       - Do not commit the instruction.
       - Take precise **Store/AMO access fault (cause 7)** with $mtval/stval = VA$.
       - Clear reservation (`res_valid <= 1'b0`).
     - On successful store completion:
       - Clear reservation: `res_valid <= 1'b0`.
       - Write status **`0`** (success) to destination register `rd` ($rd \Leftarrow 0$).
       - If $rd == x0$, register write is suppressed, but memory is updated and reservation is cleared.
       - Instruction retires with commit.
   - **Case B: Failed SC** ($\text{reservation\_matches} == 0$):
     - **CRITICAL**: **Zero physical memory request is emitted.** Memory is completely untouched.
     - Clear reservation: `res_valid <= 1'b0`.
     - Write status **`1`** (failure) to destination register `rd` ($rd \Leftarrow 1$).
     - If $rd == x0$, register write is suppressed, but memory remains completely unmodified.
     - Instruction retires with commit.

---

## 4. Atomic Memory Operations (AMOs) specification

### 4.1 Explicit AMO/RMW MMU and PMP operation type

To guarantee that read-only, execute-only, or improperly privileged pages can never be partially read or written by an AMO, the core defines an explicit **AMO/RMW** request classification (`req_op = REQ_AMO` or `is_amo = 1`):

#### 4.1.1 Sv39 leaf validation for AMO
When translating an AMO address, the hardware page table walker and leaf permission checker enforce:
- **`R == 1`** (Read permission);
- **`W == 1`** (Write permission);
- **`A == 1`** (Accessed bit set under Svade);
- **`D == 1`** (Dirty bit set under Svade);
- Standard User/Supervisor privilege checks ($U/S$, $SUM$).
- **`MXR` Strict Exclusion**: `mstatus.MXR` makes execute-only pages readable *only for loads*. `MXR` **must never make an execute-only page valid for AMO**. An execute-only page ($R=0, W=0, X=1$) or any page with $R=0$ or $W=0$ unconditionally raises a **Store/AMO page fault (cause 15)**.

#### 4.1.2 PMP validation for AMO
The matching PMP entry must grant **both Read and Write permissions**:
- Requires **PMP Read ($R=1$)**;
- Requires **PMP Write ($W=1$)**.
- If either permission is missing, the core raises a **Store/AMO access fault (cause 7)**.

**Invariant**: Both Sv39 and PMP validations must succeed **before** any physical memory read phase is issued.

### 4.2 Formalized AMO indivisibility and multi-cycle FSM lifecycle

An AMO is a single indivisible architectural instruction executed through an internal multi-cycle controller FSM with states equivalent to:

```
+----------------+       Fault       +------------+
| AMO_TRANSLATE  |------------------>|  AMO_TRAP  |
+----------------+                   +------------+
        | Success                          ^
        v                                  | Bus Error
+----------------+                         |
|  AMO_READ_REQ  |                         |
+----------------+                         |
        | Read Fire                        |
        v                                  |
+----------------+       Bus Error         |
|  AMO_READ_WAIT |-------------------------+
+----------------+                         |
        | Read Valid                       |
        v                                  |
+----------------+                         |
|  AMO_COMPUTE   |                         |
+----------------+                         |
        |                                  |
        v                                  |
+----------------+                         |
| AMO_WRITE_REQ  |                         |
+----------------+                         |
        | Write Fire                       |
        v                                  |
+----------------+       Bus Error         |
| AMO_WRITE_WAIT |-------------------------+
+----------------+
        | Write Ack
        v
+----------------+
|  AMO_COMPLETE  |
+----------------+
```

1. **`AMO_TRANSLATE`**:
   - Checks natural alignment (misaligned raises cause 6).
   - Validates Sv39 dual-permission ($R=1, W=1, A=1, D=1$) and PMP dual-permission ($R=1, W=1$).
   - On fault, transitions directly to `AMO_TRAP` (cause 15 or cause 7) with zero bus requests emitted.
2. **`AMO_READ_REQ` & `AMO_READ_WAIT`**:
   - Issues physical read transaction to address $PA$ with operation width.
   - Waits for memory response. If bus returns error, transitions to `AMO_TRAP` (cause 7) with write phase suppressed.
   - On valid response, captures $\text{mem\_orig}$.
3. **`AMO_COMPUTE`**:
   - Performs ALU operation between $\text{mem\_orig}$ and `rs2` to produce $\text{mem\_new}$.
   - For `.W`: operation is performed on 32-bit words with 32-bit wrap.
   - For `.D`: operation is performed on 64-bit doublewords.
4. **`AMO_WRITE_REQ` & `AMO_WRITE_WAIT`**:
   - Issues physical write transaction of $\text{mem\_new}$ to address $PA$.
   - Waits for store completion. If bus returns error, transitions to `AMO_TRAP` (cause 7); `rd` writeback is suppressed and commit is aborted.
5. **`AMO_COMPLETE`**:
   - Inactive/clears any active reservation (`res_valid <= 1'b0`).
   - Writes $\text{mem\_orig}$ (sign-extended for `.W`) to destination register `rd` (unless $rd == x0$).
   - Asserts `commit_valid_o` for exactly one cycle and retires.

### 4.3 Pipeline isolation, non-preemption, and reset rules

During an in-progress AMO:
- **No Younger Instruction Issue**: The fetch engine and issue stage are held in stall. Younger memory operations must not issue.
- **No Younger Instruction Retirement**: No instructions may retire past the in-progress AMO.
- **Asynchronous Interrupt Deferral**: External, timer, and software interrupts **must be deferred** until the AMO reaches a legal architectural boundary (after `AMO_COMPLETE` or upon taking `AMO_TRAP`). No interrupt may preempt the core between the successful read and the required write.
- **Single Commit**: `commit_valid_o` occurs exactly once, upon successful write completion.
- **Reset Invariant**: Reset (`rst_i == 1`) terminates the FSM to `IDLE`, suppresses any pending or not-yet-issued write request, and safely drains bus ownership without creating orphaned/stale response attribution.
- **Exclusivity Scope**: The single-hart, single-master Slice-0 system provides external RMW exclusivity strictly because no other master (CPU or DMA) can access the physical bus while the core holds transaction mastership.

### 4.4 AMO ALU operations definition

Let $A$ be the original memory value loaded in Phase 1, and $B = \text{rs2}$.

| Operation | 32-bit Word Semantics (`.W`) | 64-bit Doubleword Semantics (`.D`) |
|---|---|---|
| `AMOSWAP` | $\text{new}[31:0] = B[31:0]$ | $\text{new} = B$ |
| `AMOADD` | $\text{new}[31:0] = A[31:0] + B[31:0]$ | $\text{new} = A + B$ |
| `AMOXOR` | $\text{new}[31:0] = A[31:0] \oplus B[31:0]$ | $\text{new} = A \oplus B$ |
| `AMOAND` | $\text{new}[31:0] = A[31:0] \land B[31:0]$ | $\text{new} = A \land B$ |
| `AMOOR` | $\text{new}[31:0] = A[31:0] \lor B[31:0]$ | $\text{new} = A \lor B$ |
| `AMOMIN` | $\text{new}[31:0] = (\text{signed}(A[31:0]) < \text{signed}(B[31:0])) \mathbin{?} A[31:0] : B[31:0]$ | $\text{new} = (\text{signed}(A) < \text{signed}(B)) \mathbin{?} A : B$ |
| `AMOMAX` | $\text{new}[31:0] = (\text{signed}(A[31:0]) > \text{signed}(B[31:0])) \mathbin{?} A[31:0] : B[31:0]$ | $\text{new} = (\text{signed}(A) > \text{signed}(B)) \mathbin{?} A : B$ |
| `AMOMINU` | $\text{new}[31:0] = (\text{unsigned}(A[31:0]) < \text{unsigned}(B[31:0])) \mathbin{?} A[31:0] : B[31:0]$ | $\text{new} = (\text{unsigned}(A) < \text{unsigned}(B)) \mathbin{?} A : B$ |
| `AMOMAXU` | $\text{new}[31:0] = (\text{unsigned}(A[31:0]) > \text{unsigned}(B[31:0])) \mathbin{?} A[31:0] : B[31:0]$ | $\text{new} = (\text{unsigned}(A) > \text{unsigned}(B)) \mathbin{?} A : B$ |

### 4.5 Return value and `rd == x0` semantics

- **Architectural Return Value**:
  - For `.W`: $rd \Leftarrow \{\{32\{A[31]\}\}, A[31:0]\}$.
  - For `.D`: $rd \Leftarrow A[63:0]$.
- **Destination Register `x0`**:
  - If $rd == x0$, register writeback is suppressed.
  - **Crucial Rule**: The memory Read-Modify-Write operation **is still executed in its entirety**. Software uses `amoswap.w x0, rs2, (rs1)` or `amoadd.w x0, rs2, (rs1)` as atomic memory updates without requiring a temporary register.

---

## 5. Memory ordering (`aq` and `rl`) semantics

### 5.1 RISC-V Weak Memory Ordering (RVWMO) definition

The RV64A extension specifies two ordering bits on every atomic instruction:
- **`aq` (bit 26, Acquire)**: Guarantees that the atomic operation is globally observed before any subsequent memory operations in program order.
- **`rl` (bit 25, Release)**: Guarantees that all preceding memory operations in program order are globally observed before this atomic operation.
- **`aq=1, rl=1`**: Sequential Consistency (both acquire and release).
- **`aq=0, rl=0`**: Relaxed memory ordering.

### 5.2 Slice-0 architectural implementation scope

**Implementation Property**: In the current single-hart Slice-0 implementation, with:
- in-order instruction execution and in-order retirement;
- no store buffer or write queue;
- no data cache;
- no DMA master;
- serialized, single-outstanding memory transactions on the interconnect;

memory operations execute and commit strictly in program order. This serialized execution is sufficient to satisfy current RVWMO `aq` and `rl` ordering requirements without additional hardware barriers or pipeline stalls.

**Warning on Multicore / Cache Boundary**: This is strictly a Slice-0 implementation property. It does not represent general sequential consistency and will not hold once caches, store buffers, DMA masters, multiple outstanding transactions, or multicore crossbars are introduced. At that milestone, active store-buffer draining and cache coherence barriers will become mandatory.

---

## 6. Deterministic reservation invalidation table

The reservation flag `res_valid` is deterministically updated according to the following matrix:

| Triggering Event | Next `res_valid` | Justification & Architectural Rule |
|---|---|---|
| **Successful `LR.W` / `LR.D`** | `1'b1` | Registers new reservation on exact $PA$, size, and 64-byte granule |
| **Successful `SC.W` / `SC.D`** | `1'b0` | Atomically consumed upon successful store |
| **Failed `SC.W` / `SC.D`** | `1'b0` | Standard RISC-V rule: SC clears reservation regardless of success/failure |
| **Normal Store (`SB`, `SH`, `SW`, `SD`) by Hart 0** | `1'b0` | **Conservative Invalidation**: Any local store clears reservation |
| **Any `AMO*.W/D` by Hart 0** | `1'b0` | AMOs perform memory writes; clears reservation |
| **Trap Entry (Synchronous Exception)** | `1'b0` | Context switch / fault boundary; prevents cross-thread leakage |
| **Trap Entry (Asynchronous Interrupt)** | `1'b0` | Preemption boundary; prevents ISR from inheriting reservation |
| **Trap Return (`MRET` or `SRET`)** | `1'b0` | Privilege domain transition; prevents kernel/user reservation leakage |
| **`SFENCE.VMA` Execution** | `1'b0` | Address translation synchronization; invalidates active reservations |
| **`satp` CSR Write** | `1'b0` | Address space switch; virtual address mappings change |
| **Platform Reset (`rst_i == 1`)** | `1'b0` | Clears all internal architectural and microarchitectural state |
| **External Interconnect / DMA Write (Future)** | `1'b0` (if $PA \in \text{granule}$) | Coherence snoop invalidation on matching 64-byte granule |

---

## 7. Precise exception and fault suppression rules

### 7.1 Scope of physical bus-error side-effect guarantees

**Pre-Store Faults (Zero Side Effects Guaranteed)**:
For any fault detected *before* a physical store request is issued:
- Address misalignment;
- Translation failure / page fault (causes 13, 15);
- PMP permission denial (causes 5, 7);
- Failed SC (mismatched address, mismatched size, or missing reservation);
- AMO read-phase platform bus error;

the store request **is never issued to the bus**, guaranteeing **zero external memory mutation**.

**Post-Store Bus Errors (Access Fault Semantics)**:
For:
- Successful SC physical store returning a platform bus error;
- AMO write-phase store returning a platform bus error;

the core guarantees:
1. Destination register `rd` writeback is suppressed.
2. The instruction is not committed (`commit_valid_o = 0`).
3. Precise **Store/AMO access fault (cause 7)** is taken with $mepc/sepc = \text{PC}$ and $mtval/stval = VA$.
4. Internal atomic state and reservations are cleared.

**Explicit Scope Limitation**: The core **does not and cannot guarantee external memory or peripheral rollback** once a store request has been accepted by the platform interconnect. The state of external memory or device registers following a faulting issued store is governed entirely by platform/bus slave behavior.

---

## 8. Memory interface implications and implementation model

### 8.1 Single-hart execution model in Slice-0

The Slice-0 memory interface (`dmem_req_*`, `dmem_rsp_*`) remains a single-outstanding request/response bus.

- **LR**: Executes as a single load transaction; on response data return, registers reservation state.
- **SC**: Checks alignment, translation, and PMP. Evaluates `reservation_matches`. If matched, issues a store and writes `0` to `rd`. If not matched, suppresses the store request and writes `1` to `rd`.
- **AMO**: Executes as a serialized 2-phase sequence (`READ` followed by `WRITE`) managed by the internal LSU controller. Exclusivity is maintained because the core is the sole bus master on Slice-0.

### 8.2 Coherent Cache / External Bus Considerations

If extending to coherent cached or multi-hart topologies:
1. **Coherent L1 D-Cache Line Locking**: AMOs will execute in L1 cache by acquiring exclusive line ownership (M state in MESI) and completing the read-modify-write atomically before releasing the line.
2. **Interconnect Atomics**: For uncached MMIO regions, the bus interface will support atomic read-modify-write commands (e.g., AXI5 Atomic Transactions or TileLink Atomic operations).
3. **Multi-Hart SNOOP Invalidation**: Stores from Hart $A$ will snoop and invalidate matching reservations held by Hart $B$.

---

## 9. Verification plan and formal invariants

### 9.1 Verification scenario matrix

| Test ID | Scenario Description | Expected Outcome |
|---|---|---|
| **A-LRSC-01** | Basic `LR.W` followed immediately by `SC.W` to same address | SC succeeds: `rd=0`, memory updated, `res_valid` cleared |
| **A-LRSC-02** | Basic `LR.D` followed immediately by `SC.D` to same address | SC succeeds: `rd=0`, memory updated, `res_valid` cleared |
| **A-LRSC-03** | `SC.W` executed without prior `LR` | SC fails: `rd=1`, memory untouched, zero store emitted |
| **A-LRSC-04** | `SC.D` executed without prior `LR` | SC fails: `rd=1`, memory untouched, zero store emitted |
| **A-LRSC-05** | `LR.W @ A` followed by `SC.W @ A+4` (same 64-byte granule) | SC fails: `rd=1`, memory untouched (exact address mismatch) |
| **A-LRSC-06** | `LR.W @ A` followed by `SC.D @ A` (same address, size mismatch) | SC fails: `rd=1`, memory untouched (size mismatch) |
| **A-LRSC-07** | `LR.D @ A` followed by `SC.W @ A` (same address, size mismatch) | SC fails: `rd=1`, memory untouched (size mismatch) |
| **A-LRSC-08** | Virtual alias: `LR.W` via $VA_1 \to PA$, conflicting store via $VA_2 \to PA$, then `SC.W` via $VA_1$ | SC fails: `rd=1`, PA-based conflict invalidates reservation |
| **A-LRSC-09** | Invalid reservation + `SC.W` to unmapped virtual page | Store/AMO page fault (cause 15); not simple SC failure |
| **A-LRSC-10** | `LR.W` followed by normal store `SW` to same address, then `SC.W` | SC fails: `rd=1`, memory untouched |
| **A-LRSC-11** | `LR.W` followed by normal store `SW` to *different* address, then `SC.W` | SC fails (conservative invalidation policy) |
| **A-LRSC-12** | `LR.W` followed by `AMOADD.W`, then `SC.W` | SC fails: `rd=1`, memory untouched |
| **A-LRSC-13** | `LR.W` followed by synchronous trap (`ECALL`/`EBREAK`), `MRET`, then `SC.W` | SC fails: trap invalidates reservation |
| **A-LRSC-14** | `LR.W` followed by timer/external interrupt, `MRET`, then `SC.W` | SC fails: interrupt invalidates reservation |
| **A-LRSC-15** | `LR.W` followed by `SFENCE.VMA`, then `SC.W` | SC fails: fence invalidates reservation |
| **A-LRSC-16** | `LR.W` followed by `satp` CSR write, then `SC.W` | SC fails: context change invalidates reservation |
| **A-LRSC-17** | `LR.W` with negative 32-bit value (bit 31=1) | Destination `rd` is sign-extended to 64 bits |
| **A-LRSC-18** | `LR.W` with $rd == x0$ | Reservation registered; `x0` remains 0; subsequent SC succeeds |
| **A-LRSC-19** | `SC.W` with $rd == x0$ (successful matching reservation) | Memory updated; `x0` remains 0; reservation cleared |
| **A-LRSC-20** | `LR.W` with non-zero `rs2` field | Illegal instruction exception (cause 2), `mtval = insn` |
| **A-LRSC-21** | Misaligned `LR.W` ($addr[1:0] \neq 0$) | Load address misaligned (cause 4), `mtval = addr` |
| **A-LRSC-22** | Misaligned `SC.W` ($addr[1:0] \neq 0$) | Store address misaligned (cause 6), `mtval = addr` |
| **A-LRSC-23** | Misaligned `LR.D` ($addr[2:0] \neq 0$) | Load address misaligned (cause 4), `mtval = addr` |
| **A-LRSC-24** | Misaligned `SC.D` ($addr[2:0] \neq 0$) | Store address misaligned (cause 6), `mtval = addr` |
| **A-AMO-01** | `AMOSWAP.W` and `AMOSWAP.D` | Original value returned; memory updated with `rs2` |
| **A-AMO-02** | `AMOADD.W` and `AMOADD.D` with positive and negative values | Correct arithmetic sum; `.W` 32-bit wrap verified |
| **A-AMO-03** | `AMOXOR.W` and `AMOXOR.D` | Correct bitwise XOR |
| **A-AMO-04** | `AMOAND.W` and `AMOAND.D` | Correct bitwise AND |
| **A-AMO-05** | `AMOOR.W` and `AMOOR.D` | Correct bitwise OR |
| **A-AMO-06** | `AMOMIN.W` and `AMOMIN.D` (signed comparison) | Minimum signed operand selected; signed boundary test |
| **A-AMO-07** | `AMOMAX.W` and `AMOMAX.D` (signed comparison) | Maximum signed operand selected |
| **A-AMO-08** | `AMOMINU.W` and `AMOMINU.D` (unsigned comparison) | Minimum unsigned operand selected; unsigned boundary test |
| **A-AMO-09** | `AMOMAXU.W` and `AMOMAXU.D` (unsigned comparison) | Maximum unsigned operand selected |
| **A-AMO-10** | `AMO*.W` with bit 31 set | Original value sign-extended to 64 bits in `rd` |
| **A-AMO-11** | `AMO*.W/D` with $rd == x0$ | Memory updated atomically; `x0` remains 0 |
| **A-AMO-12** | Misaligned `AMO.W` ($addr[1:0] \neq 0$) | Store address misaligned (cause 6); no read or write |
| **A-AMO-13** | Misaligned `AMO.D` ($addr[2:0] \neq 0$) | Store address misaligned (cause 6); no read or write |
| **A-SYS-01** | Sv39 Page Fault: AMO on read-only page ($R=1, W=0$) | Store/AMO page fault (cause 15); memory untouched |
| **A-SYS-02** | Sv39 Page Fault: AMO on execute-only page with `MXR=1` | Store/AMO page fault (cause 15); `MXR` cannot validate AMO |
| **A-SYS-03** | Sv39 Page Fault: AMO on Svade un-dirty page ($D=0$) | Store/AMO page fault (cause 15); memory untouched |
| **A-SYS-04** | PMP Denial: AMO on PMP read-only region ($R=1, W=0$) | Store/AMO access fault (cause 7); no physical read/store |
| **A-SYS-05** | PMP Denial: SC on PMP denied region | Store/AMO access fault (cause 7); no physical store |
| **A-SYS-06** | Platform Bus Error: Read phase error during AMO | Store/AMO access fault (cause 7); write phase suppressed |
| **A-SYS-07** | Platform Bus Error: Write phase error during AMO | Store/AMO access fault (cause 7); `rd` writeback suppressed; no rollback guarantee |
| **A-SYS-08** | Interrupt arriving between AMO read and write phases | Interrupt deferred; AMO completes write before taking interrupt |
| **A-SYS-09** | Platform Reset asserted during AMO execution | In-flight write suppressed; bus ownership cleanly drained; no post-reset store leak |

### 9.2 SVA formal invariants and architectural assertions

1. **SC Success Match Invariant**:
   A physical memory write with `SC` transaction ownership shall occur if and only if `res_valid == 1`, `sc_pa == res_exact_pa`, and `sc_size == res_size`. Under no circumstances shall an address-mismatched or size-mismatched SC issue a physical store.
2. **Failed SC Store Suppression**:
   If `reservation_matches == 0`, `dmem_req_valid_o` for the SC instruction shall remain permanently `0`.
3. **AMO Non-Preemption Invariant**:
   Between the acceptance of an AMO physical read response and the presentation of the corresponding AMO physical write request, no interrupt, trap, or younger instruction shall be dispatched or retired.
4. **AMO Single Commit Invariant**:
   Every non-faulting AMO instruction shall emit `commit_valid_o` for exactly one cycle upon write-phase completion. The read phase shall never retire the instruction.
5. **Faulting AMO Write Suppression**:
   If an AMO encounters a misalignment, translation page fault, PMP denial, or read-phase bus error, no physical store request shall be issued.
6. **AMO Fault Writeback Suppression**:
   If an AMO write-phase produces a bus error response, destination register writeback `commit_rd_write_o` shall be strictly `0`.
7. **Reset Write Leak Prevention**:
   Following assertion of `rst_i`, no pending AMO write transaction shall be presented to the memory interface.
