# Platform-Level Interrupt Controller (PLIC) architectural contract — accepted and frozen v1

Status: PLIC architecture + RTL independently reviewed — ACCEPT AND FREEZE.
This contract defines the minimal, correctness-first PLIC specification for the single-core
Fursoy RV64 platform (Slice-0), while establishing a clean, standard-compliant foundation
for future multicore scaling (4 to 8 cores). The reviewed and frozen M/S/U Bare privilege
architecture (`s-mode-bare-v1.md`), Sv39 MMU architecture (`sv39-mmu-v1.md`), and PMP
architecture (`pmp-v1.md`) serve as the compatibility baseline.

---

## 1. Scope and architectural authority

### 1.1 Normative references

The normative authority for the conventional PLIC architecture defined in this document is:

1. **RISC-V Platform-Level Interrupt Controller (PLIC) Specification**, Version 1.0.0.
2. **RISC-V Instruction Set Manual, Volume II: Privileged Architecture**, Document Version
   20260120 (Machine-Level ISA 1.13 and Supervisor-Level ISA 1.13).
3. CC BY 4.0 license applies to adapted specification text.

Throughout this specification, provisions are categorized as:

- **Required**: Mandatory standard RISC-V PLIC behavior. RTL has no project freedom except
  where explicit implementation choices are permitted by the specification.
- **Choice**: A project design decision for the Fursoy platform among architecturally legal
  options.
- **Simplification**: A correctness-first restriction tailored for the single-hart Slice-0
  baseline that must not compromise future multicore server expansion.

### 1.2 Distinctions and roadmap

| Feature Dimension | Standard RISC-V PLIC Baseline | Fursoy v1 Choice (Slice-0) | Deferred Multicore / Server Scaling |
|---|---|---|---|
| **Max Interrupt Sources** | Up to 1023 sources (IDs 1..1023) | **31 sources** (IDs 1..31) | 63 or 127 sources for server peripherals |
| **Source Triggering** | Level or Edge | **Level-sensitive only** | Configurable Edge / Level gateways |
| **Implemented Target Contexts** | Up to 15,872 contexts | **2 contexts** (Hart 0 M, Hart 0 S) | Hart $H$ M ($2H$) and S ($2H+1$) for 4→8 cores (platform convention) |
| **Priority Width** | 1 to 32 bits (typically 3 or 7) | **3 bits** (priorities 0..7) | Preserved at 3 bits (8 priority levels) |
| **Priority Threshold Width** | Matches priority width | **3 bits** (thresholds 0..7) | Preserved at 3 bits |
| **MMIO Access Width** | 32-bit naturally aligned | **Strict 32-bit aligned only** | 32-bit aligned (64-bit optional on interconnect) |
| **Interrupt Delivery** | Dedicated line per context | Direct to `irq_meip_i` & `irq_seip_i` | Independent context lines to each core |

**Explicitly Out of Scope (Non-Goals)**:
- RISC-V Advanced Interrupt Architecture (AIA), including Advanced PLIC (APLIC) and Incoming
  MSI Controller (IMSIC).
- Message-Signaled Interrupts (MSI) and PCIe root complex / MSI translation.
- Concrete peripheral device implementations (UART, console, timers, storage, network, virtio).
- Core Local Interrupts: **CLINT timer interrupt (MTIP) and software interrupt (MSIP) remain completely separate from the PLIC and are never routed through PLIC sources.**
- SBI implementation (e.g. OpenSBI firmware services) and Linux boot software.
- TLB/cache and performance optimizations.

---

## 2. Interrupt sources

### 2.1 Source count and allocation

**Choice**: Fursoy PLIC v1 implements **31 physical interrupt sources**, numbered from
**Source ID 1 through 31**. Total interrupt source IDs supported is 32 (IDs 0..31).

- Source IDs fit exactly into a single 32-bit register word for pending and enable bits.
- This minimizes gate count and verification surface for the initial Slice-0 baseline while
  providing ample interrupt capacity for initial platform bring-up.

### 2.2 Source ID 0 semantics

**Required**:
- Interrupt Source ID 0 does **not** represent a physical interrupt source. It is reserved by
  the RISC-V PLIC architecture to signify the absence of an interrupt ("no interrupt").
- The Priority register for Source ID 0 (offset `0x000000`) is hardwired to 0 (RO0). Writes are
  silently ignored.
- The Pending bit for Source ID 0 (bit 0 of Pending Word 0, offset `0x001000`) is hardwired to 0
  (RO0).
- The Enable bit for Source ID 0 (bit 0 of each context enable register, offset `0x002000 + c * 0x80`)
  is hardwired to 0 (RO0).
- A Claim read returning 0 indicates that no interrupt is currently eligible for that context.
- A Completion write specifying Source ID 0 has zero effect on the PLIC gateway or core state.

### 2.3 Initial platform source assignments

**Choice**: For Slice-0, interrupt source allocations are defined generically:

| Source ID | Device / Source | Triggering Type | Description / Platform Integration |
|---|---|---|---|
| **0** | *Reserved / None* | N/A | Hardwired zero; represents "no interrupt" |
| **1..31** | External Interrupt Inputs `irq_source_i[1..31]` | Level-sensitive (active-high) | Generic platform interrupt lines; concrete peripheral bindings deferred to later SoC integration milestones |
| **$\ge 32$** | *Unimplemented* | N/A | Exceeds v1 capacity; accesses handled per Section 15 |

**Core / Platform Separation Rule**:
CLINT interrupts (`irq_timer_i` / MTIP and `irq_software_i` / MSIP) are direct core interrupt
inputs driven by the CLINT block (`fursoy_s0_clint.sv`). They are architecturally distinct
from external interrupts and are **not** routed through PLIC sources.

---

## 3. Targets and contexts

### 3.1 Context definition and numbering

**Required / Choice**:
In the RISC-V PLIC architecture, an interrupt **target** is an execution context on a given
hart (e.g., Hart 0 Machine-mode or Hart 0 Supervisor-mode).

Fursoy v1 implements **2 target contexts** for the single Slice-0 core (Hart 0):

- **Context 0**: Hart 0 Machine-mode (M-mode) external interrupt context.
- **Context 1**: Hart 0 Supervisor-mode (S-mode) external interrupt context.

**Fursoy Platform Convention for Multicore Expansion**:
The RISC-V PLIC specification does not mandate a universal context numbering scheme across all
implementations. For the Fursoy platform, the numbering convention is fixed as:
$$\text{Context Index for Hart } H, \text{ Mode } M = \begin{cases} 2H & \text{for M-mode} \\ 2H + 1 & \text{for S-mode} \end{cases}$$
This aligns with common RISC-V server platform convention (e.g., QEMU virt, SiFive FU540/FU740).
When expanding to 4 cores (Harts 0..3), Contexts 0..7 are defined; for 8 cores (Harts 0..7),
Contexts 0..15 are defined. Slice-0 physically instantiates Contexts 0 and 1 while preserving
the linear stride in the MMIO layout.

### 3.2 Relationship to core MEIP and SEIP

**Required**:
- Context 0 drives the physical active-high level output signal **`irq_meip_o`**, which connects
  directly to the core input `irq_external_i` (feeding bit 11, `MEIP`, of the `mip` CSR).
- Context 1 drives the physical active-high level output signal **`irq_seip_o`**, which connects
  directly to the core input `irq_seip_i` (feeding bit 9, `SEIP`, of the `mip` CSR).

### 3.3 Avoidance of double-delegation ambiguity

**Required**:
A critical pitfall in RISC-V interrupt controller design is "double-delegation" or routing
supervisor external interrupts through M-mode CSR delegation.

The Fursoy PLIC contract eliminates this ambiguity through explicit architectural separation:
1. **Independent Context Outputs**: The PLIC produces **two completely independent level-sensitive
   interrupt notification signals**: `irq_meip_o` (Context 0) and `irq_seip_o` (Context 1).
2. **No PLIC Internal Forwarding**: The PLIC contains no internal routing or dependency on core
   CSRs or delegation registers (`mideleg`). Each context has its own independent enable,
   threshold, and claim/complete registers.
3. **Core Delivery Semantics**:
   - In the core, `mip[11]` (`MEIP`) directly reflects `irq_meip_o`. Per the RISC-V Privileged
     Architecture, `mideleg[11]` is hardwired to 0; MEIP is always an M-mode interrupt.
   - In the core, `mip[9]` (`SEIP`) is architecturally the logical-OR of the software-injected
     latch (`seip_q`, set via M-mode `mip` write) and the external interrupt line `irq_seip_i`:
     $$\text{mip}[9] = \text{seip\_q} \lor \text{irq\_seip\_i}$$
   - When M-mode firmware configures `mideleg[9] = 1`, any assertion of Context 1 (`irq_seip_o = 1`)
     is delivered **directly to S-mode** as an S-mode external interrupt (`scause = 9`, `stvec`)
     whenever S-mode interrupt conditions are satisfied ($P < S$ or ($P = S$ and `sstatus.SIE = 1`)).
   - **Zero M-mode Intermediation**: S-mode external interrupts do NOT trap to M-mode, do NOT require
     M-mode software emulation, and do NOT experience double-delegation.
   - If `mideleg[9] == 0` (non-delegated), `mip[9]` targets M-mode directly per the frozen core
     priority table (`MEI > MSI > MTI > SEI > SSI > STI`).

---

## 4. Priority architecture

### 4.1 Field width and supported range

**Choice**: Fursoy PLIC v1 implements **3-bit priority fields** ($P = 3$).
- Stored within 32-bit MMIO Priority registers.
- Bits `[2:0]` are Read-Write (RW).
- Bits `[31:3]` are WARL (Write-Any, Read-Legal) hardwired to 0 (RO0); writes are ignored.
- Supported priority values are integers from **0 to 7**:
  - **Priority 0**: Reserved by the PLIC specification to mean **"Never Interrupt"** (disabled).
    An interrupt source with priority 0 can neither trigger an interrupt notification nor be claimed
    by any context, regardless of enable settings or context threshold.
  - **Priorities 1..7**: Active priorities, where **1 is the lowest active priority** and
    **7 is the highest priority**.

### 4.2 Separation of claim eligibility from notification eligibility

**Required (PLIC v1.0.0 Ratified Semantics)**:
The PLIC specification strictly separates interrupt notification (signaled via external wires to
the core) from interrupt claim arbitration (performed when software reads the Claim register).
Crucially: **the claim operation is not affected by the priority threshold register.**

The architecture defines two distinct predicates for source $i \in \{1 \dots 31\}$ and context $c \in \{0, 1\}$:

#### 1. Claim Eligibility
$$\text{claim\_eligible}(c, i) = \text{pending}[i] \land \text{enable}[c][i] \land (\text{priority}[i] > 0)$$
- A source is eligible to be claimed by context $c$ if it is pending, enabled in context $c$,
  and has a non-zero priority.
- **The context priority threshold is NOT evaluated for claim eligibility.**
- Software reading the Claim register may successfully claim an interrupt even while the context
  external interrupt notification line (`irq_meip_o` / `irq_seip_o`) is low because the threshold
  masks notification.

#### 2. Notification Eligibility
$$\text{notify\_eligible}(c, i) = \text{claim\_eligible}(c, i) \land (\text{priority}[i] > \text{threshold}[c])$$
- An interrupt source stimulates the context interrupt notification line (`irq_meip_o` or `irq_seip_o`)
  if and only if it is claim-eligible **and** its priority is strictly greater than `threshold[c]`.
- The physical context external interrupt output is asserted high if and only if:
  $$\text{context\_irq}[c] = \exists i \in \{1 \dots 31\} : \text{notify\_eligible}(c, i)$$

#### Summary of Gating Controls:
- **Enable**: Gating for both notification and claim. If disabled (`enable[c][i] == 0`), source $i$ can neither notify context $c$ nor be claimed by context $c$.
- **Threshold**: Gating **only for notification**. Threshold masks MEIP/SEIP assertion, but does not prevent software from polling and claiming `claim_eligible` sources.
- **Priority 0**: Completely disabled. Never notifies and can never be claimed.

### 4.3 Tie-breaking rule

**Required**:
When selecting an interrupt (either for asserting the context notification line or for returning a
source ID during a Claim read):
1. The PLIC selects the source with the **highest priority** among eligible sources.
2. If two or more eligible sources share the identical highest priority value, arbitration breaks
   the tie deterministically in favor of the source with the **lowest numerical interrupt source ID**.

---

## 5. Pending bits

### 5.1 Semantics and access policy

**Required**:
- The PLIC maintains an internal pending state bit $\text{pending}[i]$ for each physical
  interrupt source $i \in \{1 \dots 31\}$.
- **Read-Only (RO) to Software**: Software can inspect the pending status of all sources by
  reading the Pending register (offset `0x001000`). Writes to the Pending register are silently
  ignored and have zero side effects on pending bits or gateway state.
- $\text{pending}[0]$ is hardwired to 0 (RO0).

### 5.2 Triggering model (v1 baseline)

**Choice**: Fursoy PLIC v1 exclusively implements the **level-sensitive** source model.
- Each physical source input `irq_source_i[i]` is an active-high level-sensitive signal.
- Minimal, clean gateway lifecycle eliminates race conditions and edge-capture buffers.

---

## 6. Enable bits

### 6.1 Per-context register layout

**Required / Choice**:
Each target context has its own independent interrupt enable bitmask:
- Context 0 Enable Word 0 is located at offset **`0x002000`**.
- Context 1 Enable Word 0 is located at offset **`0x002080`**.
- Enable bit 0 of each word corresponds to Source ID 0 and is hardwired to 0 (RO0).
- Enable bits `[31:1]` are Read-Write (RW).
- Enable bits for unimplemented source IDs ($\ge 32$) are unmapped or RO0.

### 6.2 Reset state and isolation

**Required**:
- Upon hardware reset, all enable bits in all contexts reset to **0** (all interrupts disabled).
- Enable bits are completely independent per context: enabling Source $i$ in Context 1 does
  not enable it in Context 0.

---

## 7. Threshold

### 7.1 Register specification

**Choice**:
Each target context has a dedicated **Priority Threshold** register:
- Context 0 Threshold: located at offset **`0x200000`**.
- Context 1 Threshold: located at offset **`0x201000`**.
- Threshold field width is **3 bits** (matching priority width).
- Bits `[2:0]` are Read-Write (RW), reset to `3'b000`.
- Bits `[31:3]` are WARL hardwired to 0 (RO0); writes are ignored.

### 7.2 Strict inequality notification masking rule

**Required**:
To stimulate the context external interrupt notification line, an interrupt's priority must be
**strictly greater than** the context threshold:
$$\text{Priority} > \text{Threshold}$$

| Threshold Value | Notified Source Priorities | Notification Behavior | Claim Behavior via Claim Read |
|---|---|---|---|
| **0** | 1, 2, 3, 4, 5, 6, 7 | All active priorities assert context IRQ | All active priorities claimable |
| **1** | 2, 3, 4, 5, 6, 7 | Priority 1 notification masked | Priorities 1..7 all claimable |
| **2** | 3, 4, 5, 6, 7 | Priorities 1..2 notification masked | Priorities 1..7 all claimable |
| **3** | 4, 5, 6, 7 | Priorities 1..3 notification masked | Priorities 1..7 all claimable |
| **4** | 5, 6, 7 | Priorities 1..4 notification masked | Priorities 1..7 all claimable |
| **5** | 6, 7 | Priorities 1..5 notification masked | Priorities 1..7 all claimable |
| **6** | 7 | Only priority 7 asserts context IRQ | Priorities 1..7 all claimable |
| **7** | *None* | **Notification completely masked** (IRQ low) | **Priorities 1..7 remain claimable** |

*Key Takeaway*: Setting `threshold = 7` suppresses the physical interrupt wire (`irq_meip_o` or `irq_seip_o`),
permitting polled-mode interrupt servicing where software periodically reads the Claim register
without taking an asynchronous core trap.

---

## 8. Claim and complete semantics — HIGH PRIORITY

The claim and complete mechanism governs atomic handoff and serialization between the PLIC
hardware gateway and the core interrupt service routine (ISR).

### 8.1 Claim read semantics

**Required**:
Reading the Claim/Complete register for context $c$ (Context 0 at `0x200004`, Context 1 at `0x201004`)
triggers an **atomic claim transaction**:

1. **Evaluation**: The PLIC core evaluates all currently **claim-eligible** sources for context $c$:
   $$\text{claim\_eligible}(c, i) = \text{pending}[i] \land \text{enable}[c][i] \land (\text{priority}[i] > 0)$$
   **Notice**: `threshold[c]` is NOT evaluated during claim.
2. **Selection**:
   - If no sources are claim-eligible, the read returns **0**.
   - If one or more sources are claim-eligible, the PLIC selects the source with the highest priority
     (breaking ties in favor of the lowest numerical source ID). Let this selected source be $k \in \{1 \dots 31\}$.
3. **Atomic Side Effects**:
   - The read data returned on the bus is $k$.
   - The pending bit for source $k$ is **atomically cleared**: $\text{pending}[k] \leftarrow 0$.
   - The gateway marks source $k$ as **in-service** (claimed): $\text{in\_service}[k] \leftarrow 1$.
   - The interrupt notification output for context $c$ (`irq_meip_o` or `irq_seip_o`) is immediately
     re-evaluated; if no `notify_eligible` interrupts remain for context $c$, the context line deasserts.
   - If no sources were claim-eligible (read returned 0), **zero state changes occur**.

### 8.2 Complete write semantics and cross-context protection

**Required**:
Writing a 32-bit value $k$ to the Claim/Complete register for context $c$ triggers a
**completion transaction**.

1. **Completion Validation**:
   The completion transaction is valid if and only if all of the following conditions hold:
   $$\text{valid\_complete}(c, k) = (1 \le k \le 31) \land \text{enable}[c][k] \land \text{in\_service}[k]$$
   - $k$ must be a valid implemented physical source ID ($1 \le k \le 31$).
   - Source $k$ must be currently **in-service** ($\text{in\_service}[k] == 1$).
   - Source $k$ must be **enabled in context $c$** ($\text{enable}[c][k] == 1$).
   *(Note: The PLIC specification does not require tracking which specific context claimed the source,
   nor matching the last claimed ID; however, checking `enable[c][k]` ensures that an unauthorized context
   cannot inadvertently complete an interrupt it does not own).*

2. **Valid Completion State Actions**:
   If $\text{valid\_complete}(c, k)$ is true:
   - The gateway clears the in-service state: $\text{in\_service}[k] \leftarrow 0$.
   - **Level Re-evaluation**: The gateway immediately samples the physical input line `irq_source_i[k]`:
     - If `irq_source_i[k] == 1` (the peripheral still holds its level line high), the gateway
       **immediately re-asserts pending**: $\text{pending}[k] \leftarrow 1$.
     - If `irq_source_i[k] == 0` (the ISR successfully serviced and cleared the peripheral),
       $\text{pending}[k]$ remains 0, and the source returns to `IDLE`.

3. **Invalid / Spurious Completion**:
   If $\text{valid\_complete}(c, k)$ is false (including writing $k = 0$, out-of-range $k \ge 32$,
   source not in service, or source disabled in context $c$):
   - The write is **silently ignored with zero state effect**:
     - $\text{in\_service}[k]$ remains asserted.
     - No pending bits are cleared or manufactured.
     - The gateway does not release or resample the source line.

4. **Cross-Context Completion Protection Example**:
   - Source $k$ is configured such that $\text{enable}[0][k] == 1$ and $\text{enable}[1][k] == 0$.
   - Context 0 claims source $k$, setting $\text{in\_service}[k] = 1$.
   - Context 1 writes $k$ to its Complete register (`0x201004`):
     Because $\text{enable}[1][k] == 0$, $\text{valid\_complete}(1, k)$ evaluates to false.
     The write is silently ignored, and source $k$ remains securely in-service until Context 0 completes it.

---

## 9. Source gateway model

### 9.1 Lifecycle state machine

**Required**:
For each physical interrupt source $i \in \{1 \dots 31\}$, the gateway maintains two state bits:
- $\text{pending}[i]$: Indicates that an unserviced interrupt request is waiting for target claim.
- $\text{in\_service}[i]$: Indicates that the interrupt has been claimed by a target context and
  has not yet completed.

```
       +-------------------------------------------------------+
       |                                                       |
       v                                                       |
  +---------+   irq_source_i[i] == 1    +-----------+          |
  |  IDLE   | ------------------------> |  PENDING  |          |
  +---------+                           +-----------+          |
       ^                                      |                |
       |                                      | Claim read     |
       |                                      | returns ID i   |
       |                                      v                |
       |  valid_complete(c, i)         +-------------+         |
       |  && irq_source_i[i] == 0      | IN_SERVICE  |         |
       +------------------------------ |  (Claimed)  | --------+
                                       +-------------+  valid_complete(c, i)
                                                        && irq_source_i[i] == 1
```

### 9.2 Gateway formal invariant rules

1. **Mutual Exclusion of Ownership**: A source can never have more than one outstanding claim
   ownership across the entire system:
   $$\text{assert}(\text{in\_service}[i] \le 1)$$
2. **Suppression of Re-pending While Claimed**: While $\text{in\_service}[i] == 1$, changes on
   `irq_source_i[i]` (including high levels or repeated transitions) **cannot set $\text{pending}[i]$**.
   This guarantees that no target can claim the same source a second time before the servicing context
   completes the transaction.
3. **No Lost Level Interrupts**: If an active-high level interrupt source remains asserted across
   valid completion, the transition $\text{IN\_SERVICE} \rightarrow \text{PENDING}$ guarantees the
   interrupt will immediately re-enter arbitration.
4. **Deassertion Before Completion**: If a peripheral asserts an interrupt, the interrupt is claimed
   (entering $\text{IN\_SERVICE}$), and the ISR services the peripheral such that `irq_source_i[i]`
   deasserts to 0 *before* software writes completion, the completion write cleanly transitions the
   gateway $\text{IN\_SERVICE} \rightarrow \text{IDLE}$ without generating a spurious second interrupt.
5. **Transient Level Pulse Latching**: If an external level source asserts high long enough to latch
   pending on an active clock edge and then drops low *before* being claimed:
   - The pending bit remains latched ($\text{pending}[i] = 1$).
   - A subsequent Claim read successfully claims source $i$, clearing pending and entering $\text{IN\_SERVICE}$.
   - When software writes valid completion, the gateway samples `irq_source_i[i] == 0` and returns
     directly to `IDLE` without re-pending.

---

## 10. MMIO register map

### 10.1 Memory aperture and address allocation

**Required / Choice**:
The Fursoy PLIC MMIO block is allocated a **4 MiB physical address window** starting at base address
**`0x0000_0000_0C00_0000`** (`0x0C00_0000` through `0x0C3F_FFFF`).
This standard base address is fully compatible with the standard RISC-V Linux platform memory map
(e.g., QEMU virt, SiFive Freedom SoC).

**System Memory Map Non-Overlap Proof**:
- CLINT aperture: `0x0000_0000_0200_0000` – `0x0000_0000_0200_FFFF` (64 KiB)
- PLIC aperture: `0x0000_0000_0C00_0000` – `0x0000_0000_0C3F_FFFF` (4 MiB)
- RAM aperture: `0x0000_0000_8000_0000` – `0x0000_0000_FFFF_FFFF` (2 GiB)
- Address regions are disjoint; zero overlap.

### 10.2 Register layout table

All addresses are offsets from `PLIC_BASE_ADDR` (`0x0000_0000_0C00_0000`):

| Offset Range | Register Name | Context / Source | Width | Access | Reset Value | Description |
|---|---|---|---|---|---|---|
| `0x000000` | `PRIORITY[0]` | Source 0 | 32b | RO | `0x00000000` | Hardwired to 0 (no interrupt) |
| `0x000004` .. `0x00007C` | `PRIORITY[1..31]` | Sources 1..31 | 32b | RW | `0x00000000` | Bits [2:0] priority (0..7); [31:3] RO0 |
| `0x000080` .. `0x000FFC` | *Unimplemented Priority* | Sources 32..1023 | 32b | RAZ/WI | `0x00000000` | Read-As-Zero, Writes-Ignored |
| `0x001000` | `PENDING[0]` | Sources 0..31 | 32b | RO | `0x00000000` | Bit $i$ indicates source $i$ pending. Bit 0 is RO0. Writes ignored. |
| `0x001004` .. `0x00107C` | *Unimplemented Pending* | Sources 32..1023 | 32b | RAZ/WI | `0x00000000` | Read-As-Zero, Writes-Ignored |
| `0x002000` | `ENABLE_C0[0]` | Context 0, Word 0 | 32b | RW | `0x00000000` | Enable mask for sources 0..31 in Context 0 (Hart 0 M). Bit 0 is RO0. |
| `0x002004` .. `0x00207C` | *Unimplemented C0 Enable* | Context 0, Words 1..31 | 32b | RAZ/WI | `0x00000000` | Read-As-Zero, Writes-Ignored |
| `0x002080` | `ENABLE_C1[0]` | Context 1, Word 0 | 32b | RW | `0x00000000` | Enable mask for sources 0..31 in Context 1 (Hart 0 S). Bit 0 is RO0. |
| `0x002084` .. `0x0020FC` | *Unimplemented C1 Enable* | Context 1, Words 1..31 | 32b | RAZ/WI | `0x00000000` | Read-As-Zero, Writes-Ignored |
| `0x002100` .. `0x1FFFFC` | *Reserved Enable Space* | Contexts $\ge 2$ | 32b | Error | N/A | Generates platform bus access error |
| `0x200000` | `THRESHOLD_C0` | Context 0 (Hart 0 M) | 32b | RW | `0x00000000` | Priority threshold for Context 0. Bits [2:0] RW; [31:3] RO0. |
| `0x200004` | `CLAIM_C0` | Context 0 (Hart 0 M) | 32b | RW | `0x00000000` | Read = Claim; Write = Complete for Context 0 |
| `0x201000` | `THRESHOLD_C1` | Context 1 (Hart 0 S) | 32b | RW | `0x00000000` | Priority threshold for Context 1. Bits [2:0] RW; [31:3] RO0. |
| `0x201004` | `CLAIM_C1` | Context 1 (Hart 0 S) | 32b | RW | `0x00000000` | Read = Claim; Write = Complete for Context 1 |
| `0x202000` .. `0x3FFFFC` | *Reserved Context Space* | Contexts $\ge 2$ | 32b | Error | N/A | Generates platform bus access error |

### 10.3 Access constraints and bus rules

**Required / Choice**:
1. **Access Width**: All accesses to PLIC MMIO registers **must be 32-bit words** (`req_size == 3'd2`).
2. **Alignment**: All accesses **must be naturally aligned to 4 bytes** (`req_addr[1:0] == 2'b00`).
3. **Rejection of Sub-word and Misaligned Accesses**:
   - Any access with `req_size != 3'd2` (e.g. byte `size = 0`, halfword `size = 1`, or doubleword `size = 3`) or with unaligned address (`req_addr[1:0] != 2'b00`) is **rejected** at the PLIC slave interface:
     - The PLIC asserts `rsp_error_o = 1` and `access_error_o = 1`.
     - Read data is returned as `0`.
     - Stores make **zero modifications** to PLIC internal state (priorities, enables, thresholds, pending bits, or claim/complete states remain untouched).
4. **Zero Side Effects on Rejected Claim/Complete Transactions**:
   - A rejected Claim read (misaligned or invalid width) returns `rsp_error_o = 1` and produces **zero claim side effects**: it does not clear pending and does not set in-service.
   - A rejected Complete write (misaligned or invalid width) returns `rsp_error_o = 1` and produces **zero completion side effects**: it does not clear in-service and does not resample the gateway.
5. **Reserved and Unmapped Address Spaces**:
   - Accesses to unmapped addresses outside the implemented registers (e.g., offsets beyond the implemented context windows) return a platform bus error (`rsp_error_o = 1`), raising an architectural Load/Store Access Fault (`cause = 5 / 7`) at the core boundary.

---

## 11. PMP interaction

**Required**:
1. **Physical Access Precedence**: All PLIC MMIO accesses are normal physical data accesses subject
   to Physical Memory Protection (PMP) checks inside the core (`fursoy_s0_mmu.sv` / `fursoy_s0_pmp_check.sv`)
   **before** any request is emitted onto the platform interconnect.
2. **PMP Denial Guarantees**:
   - If a load or store targeting the PLIC address range (`0x0C00_0000`–`0x0C3F_FFFF`) is denied
     by PMP:
     - The core generates a precise **Load Access Fault** (`cause = 5`) or **Store Access Fault**
       (`cause = 7`).
     - `mtval` (or `stval` if delegated) receives the faulting address.
     - The transaction is **suppressed locally**: `dmem_req_valid_o` is never asserted to the SoC.
     - The request **never reaches the PLIC MMIO logic**.
     - The PLIC experiences **zero side effects**: no pending bits are cleared, no in-service state
       is altered, and no registers are modified.

---

## 12. Privilege and access policy

**Required**:
1. **Unprivileged MMIO Slave Hardware**: The PLIC hardware block is an MMIO slave on the SoC
   interconnect. It does **not** inspect processor execution privilege mode ($M, S, U$) on its
   bus interface.
2. **Software and Architectural Protection**:
   - Access permission to PLIC registers is governed exclusively by:
     - **PMP (Physical Memory Protection)**: M-mode firmware can configure PMP regions to allow or
       restrict S-mode and U-mode access to the PLIC physical address range.
     - **Virtual Memory (Sv39)**: When virtual memory is enabled (`satp.MODE = Sv39`), S-mode
       operating systems access PLIC registers via page tables. The OS maps Context 1 registers
       (enable and threshold/claim pages) to supervisor virtual addresses while omitting Context 0
       or setting $U=0$ to prevent user-mode tampering.
3. **No Artificial Hardware Restrictions**: The PLIC will not artificially block S-mode physical
   accesses to Context 0 or M-mode physical accesses to Context 1; memory protection is the
   responsibility of PMP and page table configuration.

---

## 13. Core interrupt interaction

### 13.1 Signal wiring interface

The PLIC exports two independent active-high level interrupt notification lines to the core:

```
+---------------------+                    +----------------------+
|     PLIC v1         |                    |   fursoy_s0_core     |
|                     |                    |                      |
| Context 0 (Hart0 M) |--- irq_meip_o ---->| irq_external_i (MEIP)|
|                     |                    |                      |
| Context 1 (Hart0 S) |--- irq_seip_o ---->| irq_seip_i     (SEIP)|
+---------------------+                    +----------------------+
```

### 13.2 Core CSR integration

Inside `fursoy_s0_core.sv`:
- `mip[11]` (MEIP) reflects `irq_external_i` (`irq_meip_o`).
- `mip[9]` (SEIP) reflects $\text{seip\_q} \lor \text{irq\_seip\_i}$.
- `mideleg[9]` controls whether SEIP is delegated to S-mode.
- When delegated (`mideleg[9] = 1`), assertion of `irq_seip_o` directly stimulates S-mode interrupt
  eligibility:
  $$\text{s\_irq\_eligible\_sei} = \text{mip}[9] \land \text{sie}[9] \land \text{mideleg}[9] \land \text{s\_irq\_global\_en}$$
  where $\text{s\_irq\_global\_en} = (P < S) \lor (P == S \land \text{sstatus.SIE} == 1)$.

### 13.3 Preservation of frozen core interrupt priorities

The core interrupt priority order frozen in `docs/architecture/s-mode-bare-v1.md` and
`fursoy_s0_core.sv` remains completely preserved:
1. Eligible M-target interrupts take absolute priority over S-target interrupts.
2. Within M-target: $\text{MEI} > \text{MSI} > \text{MTI} > \text{SEI} > \text{SSI} > \text{STI}$.
3. Within S-target: $\text{SEI} > \text{SSI} > \text{STI}$.
4. If Context 0 (MEIP) and Context 1 (SEIP) are both simultaneously asserted by the PLIC:
   - When running in M-mode with `mstatus.MIE = 1`, MEIP is taken (cause 11 to `mtvec`).
   - When running in S-mode with `sstatus.SIE = 1`, if `mideleg[9] = 1`, MEIP takes precedence
     and causes a trap to M-mode (`mtvec`); if MIE is globally disabled in M-mode, S-mode takes
     SEIP (cause 9 to `stvec`).

---

## 14. Reset semantics

**Required**:
Hardware assertion of `rst_i` places the PLIC into a fully deterministic, quiescent state:
- All Priority registers (`PRIORITY[0..31]`) reset to `32'h0000_0000` (all sources disabled).
- All Pending bits (`pending[0..31]`) reset to `0`.
- All Enable registers (`ENABLE_C0[0]`, `ENABLE_C1[0]`) reset to `32'h0000_0000`.
- All Threshold registers (`THRESHOLD_C0`, `THRESHOLD_C1`) reset to `32'h0000_0000`.
- All Gateway in-service bits (`in_service[0..31]`) reset to `0` (all gateways in `IDLE`).
- External interrupt outputs `irq_meip_o` and `irq_seip_o` reset to `1'b0`.
- Bus response signals `rsp_valid_o` and `rsp_error_o` reset to `1'b0`.

### 14.1 Reset release and deassertion semantics

**Required**:
1. **Quiescence During Reset**: While `rst_i` is held asserted, internal pending and in-service
   states remain continuously cleared (`0`).
2. **First Clock Edge Post-Reset**:
   - If an external interrupt line `irq_source_i[k]` is asserted high when reset is deasserted,
     source $k$ transitions to `PENDING` on the **first active clock edge following reset release**
     ($\text{pending}[k] \leftarrow 1$).
3. **No Spurious Interrupts Upon Reset Release**:
   - Because all priority registers reset to `0` and all enable registers reset to `0`,
     $\text{claim\_eligible}(c, k)$ and $\text{notify\_eligible}(c, k)$ evaluate to **false** for all
     contexts.
   - Consequently, external interrupt notification outputs (`irq_meip_o`, `irq_seip_o`) remain
     quiescent at `0` upon reset release, and Claim reads return `0`, until software explicitly
     programs non-zero priorities and enables.

---

## 15. Fault and side-effect behavior

| Condition / Access Type | Bus Response | PLIC Internal State Effect | Core Trap Behavior |
|---|---|---|---|
| **Valid 32-bit read to RW register** | `rsp_valid = 1, rsp_error = 0, rsp_data = RegVal` | None | Normal register load |
| **Valid 32-bit write to RW register** | `rsp_valid = 1, rsp_error = 0` | Register updated | Normal register store |
| **Valid 32-bit read to Claim register** | `rsp_valid = 1, rsp_error = 0, rsp_data = ClaimID` | If ClaimID != 0: atomic claim of ClaimID (clears pending, sets in-service) | Normal load; atomic side effect on claimed source |
| **Valid 32-bit write to Complete register** | `rsp_valid = 1, rsp_error = 0` | If $\text{valid\_complete}(c, k)$: clears in-service, re-samples level | Normal store |
| **Write to Read-Only register (Pending, Priority 0, Enable 0)** | `rsp_valid = 1, rsp_error = 0` | **Zero effect** (write ignored) | Normal store completes without error |
| **Spurious Complete write (ID 0, unowned ID, out-of-range ID, or disabled in context)** | `rsp_valid = 1, rsp_error = 0` | **Zero effect** (silently ignored) | Normal store completes without error |
| **Misaligned Claim read (`addr[1:0] != 0`)** | `rsp_valid = 1, rsp_error = 1, access_error = 1` | **Zero effect** (no claim side effect; pending & in-service unchanged) | Load Access Fault (`cause = 5`) |
| **Misaligned Complete write (`addr[1:0] != 0`)** | `rsp_valid = 1, rsp_error = 1, access_error = 1` | **Zero effect** (no completion effect; in-service unchanged) | Store Access Fault (`cause = 7`) |
| **Invalid access size (`size != 3'd2`) on Claim/Complete or MMIO** | `rsp_valid = 1, rsp_error = 1, access_error = 1` | **Zero effect** (no claim or completion side effect) | Load/Store Access Fault (`cause = 5 / 7`) |
| **Unmapped address in reserved context windows** | `rsp_valid = 1, rsp_error = 1, access_error = 1` | **Zero effect** | Load/Store Access Fault (`cause = 5 / 7`) |
| **PMP-denied access** | Request suppressed before bus | **Zero effect** (never reaches PLIC) | Local PMP Load/Store Access Fault (`cause = 5 / 7`) |

---

## 16. Verification plan and formal properties

### 16.1 Verification matrix

| Req ID | Scenario / Test Description | Acceptance Criteria |
|---|---|---|
| **PLIC-01** | Reset Quiescence | All priorities, enables, thresholds, pending, and outputs reset to 0; zero spurious interrupts. |
| **PLIC-02** | Priority Programming & WARL | Priorities 1..31 accept values 0..7; bits [31:3] read back 0; Priority 0 remains 0 on write. |
| **PLIC-03** | Priority 0 Disablement | Source with priority 0 never asserts context interrupt and is never returned from Claim even if pending and threshold = 0. |
| **PLIC-04** | Pending Bit Level Latching | Active-high level sets pending bit; reading Pending register shows bit set; software write to Pending is ignored. |
| **PLIC-05** | Enable Masking | Pending source with priority > threshold asserts context interrupt only when its enable bit is set in that context. |
| **PLIC-06** | Threshold Masking on Notification | Priority <= Threshold suppresses `irq_meip_o` / `irq_seip_o`; Priority > Threshold asserts IRQ line; Threshold = 7 blocks all notifications. |
| **PLIC-07** | **Claim While Threshold Masks Notification** | Source is pending, enabled, with Priority <= Threshold (`context_irq == 0`); Claim read **still successfully returns source ID**, pending clears, and source enters in-service. |
| **PLIC-08** | **Disabled Source Claim** | Source is pending with Priority > 0, but disabled in context $c$ (`enable[c][k] == 0`); Claim read in context $c$ returns 0; pending bit remains set. |
| **PLIC-09** | Highest Priority Selection | Given multiple claim-eligible sources with distinct priorities, Claim read returns the source with highest priority. |
| **PLIC-10** | Equal-Priority Lowest-ID Tie-Break | Given sources $A < B$ with identical eligible priorities, Claim read returns $A$. |
| **PLIC-11** | Empty Claim Return | Claim read with no claim-eligible interrupts returns 0 and produces zero internal state side effects. |
| **PLIC-12** | Claim Atomic Side Effect | Claim read returning source $k$ atomically clears $\text{pending}[k]$, sets $\text{in\_service}[k]$, and deasserts context line if no other interrupts eligible. |
| **PLIC-13** | Gateway In-Service Lockout | While source $k$ is claimed ($\text{in\_service}[k] == 1$), further level changes on source $k$ cannot set $\text{pending}[k]$; claim cannot return $k$ again. |
| **PLIC-14** | Completion While Level Still High | Writing valid $k$ to Complete while `irq_source_i[k] == 1` clears in-service and immediately re-asserts $\text{pending}[k]$. |
| **PLIC-15** | Completion After Level Deassertion | Writing valid $k$ to Complete after `irq_source_i[k] == 0` clears in-service and leaves source in `IDLE` ($\text{pending}[k] = 0$). |
| **PLIC-16** | **Cross-Context Invalid Completion** | Source $k$ enabled only in Context 0 and claimed by Context 0; Context 1 writes $k$ to Complete: write is ignored, and $\text{in\_service}[k]$ remains asserted. |
| **PLIC-17** | Spurious / Unowned Completion | Writing an unowned source ID, ID 0, or ID $\ge 32$ to complete has zero effect on pending or in-service states. |
| **PLIC-18** | **Shared-Source Multi-Context Contention** | Source $k$ enabled in both Context 0 and Context 1; both notification lines assert; first context to claim $k$ succeeds and clears global pending; other context notification line deasserts; subsequent Claim there returns 0. |
| **PLIC-19** | **Transient Level Before Claim** | Source asserts to latch pending, then deasserts before Claim: pending remains latched; subsequent Claim returns source; valid complete while low returns gateway to `IDLE` without re-pending. |
| **PLIC-20** | Context 0 (MEIP) Delivery | Eligible interrupt in Context 0 asserts `irq_meip_o`; core takes trap cause 11 to `mtvec`. |
| **PLIC-21** | Context 1 (SEIP) Delivery | Eligible interrupt in Context 1 asserts `irq_seip_o`; with `mideleg[9] = 1`, core takes direct trap cause 9 to `stvec`. |
| **PLIC-22** | Context Independence | Enabling source in Context 1 does not assert Context 0; claiming in Context 0 does not clear Context 1 if not shared. |
| **PLIC-23** | Simultaneous MEIP and SEIP | When both contexts have eligible interrupts, core prioritizes MEIP if in M-mode, or SEIP if in S-mode with delegation. |
| **PLIC-24** | Sub-word Access Error Rejection | Byte (`size = 0`) or Halfword (`size = 1`) read/write produces `rsp_error = 1`; stores make zero register modifications. |
| **PLIC-25** | Misaligned Access Rejection | Unaligned address (`addr[1:0] != 0`) produces `rsp_error = 1`; zero state changes. |
| **PLIC-26** | **Rejected Claim Access Side Effect** | Misaligned or sub-word Claim read produces bus error (`rsp_error = 1`); **zero claim side effects** (pending and in-service unchanged). |
| **PLIC-27** | Unmapped Address Rejection | Access to reserved context windows ($\ge 2$) produces `rsp_error = 1` and causes bus access fault in core. |
| **PLIC-28** | PMP Denial Precedence | PMP-denied load/store to PLIC generates local core access fault; request never reaches PLIC; zero side effects. |
| **PLIC-29** | Multiple Pending Sources | Multiple simultaneous pending sources are serviced sequentially in strict priority/ID order across successive claim/complete cycles. |
| **PLIC-30** | Reset During In-Service State | Reset asserted while sources are in `PENDING` and `IN_SERVICE` cleanly clears all state to quiescent `IDLE`. |
| **PLIC-31** | Reset Release with Asserted Source | Source asserted high across reset release transitions to `PENDING` on first active clock edge after reset release; notifications remain deasserted due to reset priority/enable = 0. |

### 16.2 Formal properties and assertions

1. **At Most One Outstanding Claim**:
   $$\text{always\_comb } \forall i \in \{1 \dots 31\}, \quad \text{in\_service}[i] \le 1$$
2. **No Duplicate Claim Before Completion**:
   $$\text{assert property (@(posedge clk) (claim\_fire \&\& claim\_id == i) |=> !((claim\_fire \&\& claim\_id == i) until (complete\_fire \&\& complete\_id == i \&\& valid\_complete(c, i))))}$$
3. **Context Notification Line Assertion**:
   $$\text{assign context\_irq}[c] = \exists i \in \{1 \dots 31\} : (\text{pending}[i] \land \text{enable}[c][i] \land (\text{priority}[i] > \text{threshold}[c]) \land (\text{priority}[i] > 0))$$
4. **Claim Arbitration Independent of Threshold**:
   $$\text{assert property (@(posedge clk) claim\_fire \&\& (claim\_id != 0) |-> \text{claim\_eligible}(c, \text{claim\_id}))}$$
5. **Deterministic Tie-Break Correctness**:
   $$\text{assert property (@(posedge clk) claim\_fire \&\& (claim\_id != 0) |-> (\text{priority}[\text{claim\_id}] == \max_{j} (\text{claim\_eligible}(c, j))) \land (\forall j < \text{claim\_id}, \text{priority}[j] < \text{priority}[\text{claim\_id}]))}$$
6. **Cross-Context Completion Protection**:
   $$\text{assert property (@(posedge clk) complete\_write \&\& !enable[c][k] |=> $stable(in\_service[k]))}$$
7. **No Spurious Pending Creation on Completion**:
   $$\text{assert property (@(posedge clk) complete\_fire \&\& valid\_complete(c, i) \&\& !irq\_source\_i[i] |=> !pending[i])}$$
8. **Zero Side Effect on Rejected Bus Error**:
   $$\text{assert property (@(posedge clk) req\_valid \&\& access\_error |=> $stable(all\_registers))}$$

---

## 17. Scope exclusions

The following components and features are explicitly excluded from this milestone:
- **AIA / APLIC / IMSIC**: Advanced Interrupt Architecture is not implemented in v1.
- **Message-Signaled Interrupts (MSI)**: Conventional wire-based level interrupts only.
- **PCIe / Virtio**: Platform bus device emulation or driver models.
- **Concrete Peripherals**: UART, console, RTC, timer, network, storage.
- **CLINT Integration into PLIC**: CLINT MSIP/MTIP remain separate core interrupts, not PLIC sources.
- **SBI / OS Boot Flow**: Software firmware and kernel boot flows are subsequent milestones.
- **Hardware Multicore Routing**: Beyond defining standard context numbering offsets ($2H, 2H+1$), multicore hardware buses and crossbar routing are excluded.
- **Interrupt Virtualization**: No hypervisor interrupt virtualization extensions (H-extension / AIA).
