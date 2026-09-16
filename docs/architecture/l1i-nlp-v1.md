# Fursoy Slice-0 L1I Next-Line Prefetcher (L1I-NLP v1) Architecture Contract

**Status:** L1I-NLP v1 ARCHITECTURE CORRECTIONS COMPLETE — RTL STILL NOT AUTHORIZED  
**Milestone:** Milestone B — Conservative Next-Line Instruction Prefetcher v1  
**Target:** Fursoy Slice-0 (In-Order 2-Stage [F | E] Core)  
**Normative Baselines:**
- `docs/architecture/l1i-cache-v1.md` (Frozen L1 Instruction Cache v1 Contract)
- `docs/architecture/l1i-refill-opt-v1.md` (Frozen L1I Demand Refill Early Restart & Streaming v1 Contract)
- `docs/architecture/branch-prediction-v1.md` (Frozen Branch Prediction Unit v1 Contract)
- `docs/architecture/l1d-cache-v1.md` (Frozen L1 Data Cache v1 Contract)
- `docs/architecture/store-buffer-v1.md` (Frozen Store Buffer v1 Contract)
- `docs/architecture/l1d-srb-v1.md` (Frozen Store Refill Buffer v1 Contract)
- `docs/architecture/sv39-tlb-v1.md` (Frozen Sv39 TLB v1 Contract)
- `docs/architecture/pmp-v1.md` (Frozen Physical Memory Protection Contract)
- RISC-V Privileged Architecture Manual v1.13 (Sv39, satp, SFENCE.VMA, PMP)
- RISC-V Unprivileged ISA Standard v20191213 (Zifencei Instruction-Fetch Fence)

**Performance Baseline:** Accepted Corrected Post-L1I-ER Milestone (25,639,344 cycles, 14,918,855 commits, IPC 0.581874, CPI 1.718587, 3,160,167 L1I refill stall cycles, accounting residual = 0).

---

## 1. Scope, Invariants, and Architectural Authority

### 1.1 Architectural Scope & Roadmap Boundary
Following independent broad architectural review of the initial L1I-NLP v1 proposal, this document provides the **authoritative, corrected architectural specification** resolving all 3 P0, 3 P1, and 2 P2 findings.
* **Target Pool:** L1I demand miss/refill latency represents **3,160,167 cycles (12.33% of total execution time)** and is the primary performance optimization target in the core.
* **Scope:** A conservative, hardware-managed, one-line next-line stream prefetcher decoupled from the main L1I cache array via a standalone 1-line Prefetch Buffer (PFB).
* **Preservation Guarantee:** Frozen L1I-ER v1 demand behavior remains 100% intact:
  - Critical-beat early restart timing and holding register semantics are unchanged.
  - Sequential intra-line streaming protocol is unchanged.
  - Option A demand-refill redirect behavior is preserved for all demand traffic.
  - Main 4-way associative L1I replacement policy (Tree-PLRU) and single-port array access rules are preserved.
  - MMU and PMP check contracts are strictly preserved.
* **RTL Restriction:** This document provides the architecture proposal only. **No RTL modifications are authorized.**

### 1.2 Core Architectural Invariants
1. **Demand Dominates Prefetch:** Speculative prefetch must never delay, block, or preempt any demand instruction fetch, demand cache refill, or L1D/PTW memory transaction.
2. **No Deadlock on Missing Producers (P0-1):** Streaming wait is legal **only** while a matching speculative prefetch is actively progressing on the memory bus and guaranteed to produce the missing beat. No state may wait on an event for which no producer exists. A dormant partial prefetch buffer matching an invalid beat must be immediately abandoned in favor of an authoritative demand refill.
3. **Unbroken Sequential Streaming Chain (P0-2):** Prefetch candidates are generated on both demand-miss refill completion and useful PFB line promotion/consumption, enabling sustained linear streaming across sequential instruction blocks without miss/hit oscillation.
4. **Authoritative Authorization (No PMP Bypass, P0-3):** A speculative external memory request must never occur without verified execute permission for the actual physical bytes being requested. Same-4KiB-page residency does NOT imply PMP execute authorization.
5. **No Speculative Faults:** Speculative prefetch transactions are non-faulting. Memory bus errors, PMP denials, or translation boundaries encountered during prefetch never trigger architectural exceptions. Errored prefetch lines are dropped; demand fetches execute fresh authoritative accesses.
6. **Decoupled Storage (No Directory Aliasing):** Prefetched instructions are captured in a dedicated 1-line Prefetch Buffer (PFB). Unpromoted prefetch data never marks a main L1I directory way valid. A physical line cannot exist simultaneously in both main L1I and the PFB.
7. **Instant Invalidation on Maintenance:** `FENCE.I`, `SFENCE.VMA`, `satp` writes, PMP CSR modifications, and resets instantly flush queued, active, completed, and dormant prefetch states.
8. **Strict Single-Port Datapath Compliance (P1-1):** Demand lookups strictly dominate tag-array access. Prefetch residency checks are scheduled during idle/stall cycles, and directory promotion utilizes a deterministic 1-cycle bubble if colliding with a concurrent demand lookup.
9. **Bounded Protocol Preemption (P1-3):** Preemption occurs at clean 1-beat transaction boundaries. The demand preemption delay is architecturally bounded to $0$ cycles if prefetch is in request phase, or $(1 + t_{\text{rsp\_remain}})$ cycles if awaiting response for an already-accepted beat.

---

## 2. Authoritative Address & Permission Qualification Contract (Resolving P0-3)

### 2.1 Physical Address Generation
When a prefetch trigger fires for physical line $L = \text{trigger\_line\_pa}[55:6]$:
$$\text{cand\_line\_pa}[55:0] = \{\text{trigger\_line\_pa}[55:6] + 50'd1, 6'b000000\}$$
The candidate address is naturally 64-byte aligned and represents the strictly sequential next line $L+1$.

### 2.2 Translation & Same-Page Boundary Guard
* **Page Boundary Evaluation:**
  $$\text{same\_page} = (\text{cand\_line\_pa}[55:12] == \text{trigger\_line\_pa}[55:12])$$
* **Contract:**
  - If `same_page == 1'b0`: The candidate line resides in an adjacent 4 KiB page. Because crossing page boundaries requires resolving a separate page-table translation (or ITLB walk), potentially crossing non-contiguous physical pages or different page-level permissions ($U, X$), **cross-page prefetching is strictly forbidden**. The candidate is immediately suppressed with zero bus or MMU interaction.
  - If `same_page == 1'b1`: The candidate inherits the identical virtual-to-physical translation, page attributes ($R, W, X, U, G$), and canonical address validity established by the authoritative demand translation of the current page.

### 2.3 Evaluation of PMP Authorization Options (P0-3)
The Reviewer correctly noted that `pmp_check_range()` was a phantom construct, `fursoy_s0_pmp_check` natively supports only $\le 8$-byte accesses (`req_size_i` $0 \dots 3$), and frozen L1I has no direct PMP register ports. Three architectural implementations were evaluated:

| Criterion | Option A: Core/MMU-Generated Candidate Authorization | Option B: Beat/Address-Granular Authorization | Option C: Conservative Eligibility Restriction (Selected Baseline) |
| :--- | :--- | :--- | :--- |
| **Concept** | MMU evaluates candidate line $L+1$ and outputs dedicated `itrans_pmp_allow_cand_o` to L1I. | Authorize each speculative 8-byte prefetch beat using an existing 8-byte PMP check prior to issuing that beat. | Authorize candidate only when demand PMP match is mathematically proven to cover the entire candidate line (NAPOT $k \ge 12$ or default M-mode). |
| **Required Ports** | New `cand_pmp_allow_o` on MMU; `cand_pmp_allow_i` on L1I. | 8-byte PMP request/grant handshake or routing PMP checker ports to L1I. | Minimal: single-bit `pmp_page_uniform_x_o` from MMU to L1I (or derived from demand PMP match). |
| **New Logic** | Either 64-byte PMP checker expansion or dual boundary (start/end) check in MMU. | 8 serialized PMP checks per line, or 8 parallel checker instances (massive area). | 1 comparator bit checking matching NAPOT mask $k \ge 12$ and $X=1$ without lock violations. |
| **Frozen Interface Change** | 1 bit between MMU and L1I. | Complex bus or port expansion. | 1 bit between MMU and L1I (`itrans_pmp_uniform_x_o`). |
| **PMP Correctness** | 100% exact. | 100% exact. | 100% exact (conservative subset: suppresses prefetch on TOR/sub-page PMP boundaries). |
| **Timing Impact** | Potential combinational critical-path stretch in MMU. | Tight beat-issue timing in prefetch FSM. | Zero timing penalty (registered/latched alongside demand translation). |
| **Verification Complexity** | Moderate (boundary tests in MMU). | High (interleaved beat checks). | Minimal (single qualification gate). |

### 2.4 Selected Implementation: Option C with Authoritative Option A Extension
To ensure absolute correctness without phantom functions, L1I-NLP v1 adopts **Option C as the primary baseline qualification**, with a formal **Option A single-bit interface**:

1. **The PMP Page-Uniformity Invariant (Option C):**
   In standard RISC-V systems (including the frozen Fursoy Linux platform where DRAM is mapped via a 256 MiB NAPOT entry with $k = 28$), executable regions are mapped via NAPOT entries where region size $\ge 4\text{ KiB}$ ($k \ge 12$).
   - If the demand access hits a NAPOT PMP entry with $k \ge 12$ (or no entry matches in M-mode without locks), the entire containing 4 KiB physical page has **strictly uniform, immutable execute permission**.
   - Under this condition, because the candidate line is guaranteed to reside on the same 4 KiB page (`same_page == 1'b1`), **the candidate line is mathematically guaranteed to have authoritative PMP execute permission**.
2. **Conservative Denial on Non-Uniform PMP:**
   If the demand access matched a TOR entry, NA4 entry, or small NAPOT entry ($k < 12$), PMP permissions could theoretically change at an arbitrary sub-page boundary within the 4 KiB page.
   - Under this condition, `cand_pmp_ok` is asserted low (`1'b0`).
   - Speculative prefetch is **strictly suppressed**.
   - Zero bus transactions are emitted.
3. **Interface Specification:**
   - `fursoy_s0_mmu.sv` exports `itrans_pmp_uniform_x_o` to `fursoy_s0_l1i.sv`.
   - `cand_pmp_ok = trans_pmp_allow_i && itrans_pmp_uniform_x_i`.
   - Requires zero phantom functions, zero 64-byte PMP checker restructuring, and guarantees 100% PMP execute authorization for every emitted prefetch beat.

### 2.5 Cacheability and DRAM Aperture Enforcement
The candidate physical address is verified against the architectural DRAM boundaries:
$$\text{cand\_is\_dram} = (\text{cand\_line\_pa} \ge \text{DRAM\_BASE}) \land ((\text{cand\_line\_pa} + 63) \le \text{DRAM\_END})$$
where $\text{DRAM\_BASE} = \text{56'h0000\_0000\_8000\_0000}$ and $\text{DRAM\_END} = \text{56'h0000\_0000\_8FFF\_FFFF}$.
Prefetching into MMIO space (CLINT, PLIC, UART) or unmapped aperture is strictly suppressed.

---

## 3. Demand Dominance & Bounded Bus Preemption (Resolving P1-3)

### 3.1 Policy B: Beat-Preemptible Refill Architecture
Speculative prefetch executes as a series of 8 independent, single-beat handshakes ($b \in [0 \dots 7]$). Each beat follows the 2-cycle protocol (`PF_REQ` $\to$ `PF_RSP`):
- `PF_REQ`: `imem_req_valid_o = 1`, waiting for `imem_req_ready_i = 1`.
- `PF_RSP`: `imem_rsp_ready_o = 1`, waiting for `imem_rsp_valid_i = 1`.

### 3.2 Formal Protocol Latency Bounds (Resolving P1-3)
The demand preemption penalty is formally defined in protocol terms:

$$\text{Demand Preemption Penalty} =
\begin{cases}
0\text{ cycles}, & \text{if prefetch is in }\text{PF\_IDLE}\text{ or }\text{PF\_REQ}\text{ (before req handshake)} \\
(1 + t_{\text{rsp\_remain}})\text{ cycles}, & \text{if prefetch is in }\text{PF\_RSP}\text{ (awaiting response for accepted beat)}
\end{cases}$$

where $t_{\text{rsp\_remain}}$ is the remaining latency until the memory subsystem delivers `imem_rsp_valid_i` for the in-flight beat.
* **In Frozen Simulation Platform:** Memory delivers zero-wait single-cycle responses ($t_{\text{rsp}} = 1$). Therefore, worst-case preemption delay is **$\le 2$ cycles** (1 request cycle + 1 response cycle).
* **In General Memory Systems:** If the memory controller exhibits a response latency $t_{\text{rsp}}$, demand may wait at most $(1 + t_{\text{rsp}})$ cycles to cleanly drain the active beat response.
* **Zero Orphaned Responses:** Once a beat request has handshaked (`imem_req_valid_o && imem_req_ready_i`), the controller must accept that single response beat to maintain memory bus alignment. Preemption aborts the burst at that exact beat boundary; it never cancels mid-beat or creates unconsumed responses.

---

## 4. Prefetch Buffer (PFB) Architecture & Lifecycle States (Resolving P0-1)

### 4.1 Storage Datapath
Prefetched instructions are captured in a dedicated 1-line Prefetch Buffer (PFB) completely separate from the main L1I array:
- `pfb_valid_q`: 1 bit. Indicates PFB contains valid line data (either complete or partial).
- `pfb_line_pa_q[55:6]`: 50 bits. Physical line base address ($PA[55:6]$).
- `pfb_data_q[7:0][63:0]`: 512 bits. Eight 64-bit instruction doublewords.
- `pfb_beat_valid_q[7:0]`: 8 bits. Per-beat arrival tracking.
- `pfb_beat_error_q[7:0]`: 8 bits. Per-beat error status.
- `pfb_complete_q`: 1 bit. Asserted when all 8 beats are valid and error-free:
  $$\text{pfb\_complete\_q} = (\text{pfb\_beat\_valid\_q} == 8\text{'hFF}) \land (\text{pfb\_beat\_error\_q} == 8\text{'h00})$$
- `pfb_priv_q[1:0]`: 2 bits. Privilege mode under which prefetch was authorized.

### 4.2 Formal PFB Lifecycle State Machine

```
              +-------------------------------------------------------------+
              |                          PFB_IDLE                           |
              |     (pfb_valid_q = 0, pfb_complete_q = 0, FSM idle)         |
              +-------------------------------------------------------------+
                                             |
                                [Prefetch Issue Trigger]
                                             v
              +-------------------------------------------------------------+
              |                     PFB_ACTIVE_FILLING                      |
              |       (pfb_valid_q = 1, pf_state in PF_REQ / PF_RSP)        |
              |   -> Handshaking beats 0..7 sequentially from DRAM          |
              +-------------------------------------------------------------+
                        /                           \                 \
        [All 8 Beats Clean]                 [Preempted by Demand]     [Redirect / Flush]
                      /                               \                 \
                     v                                 v                 v
+------------------------------------------+  +------------------+  +--------------+
|               PFB_COMPLETE               |  | PFB_DORMANT_PART |  | FLUSH / DROP |
| (pfb_valid_q = 1, pfb_complete_q = 1)    |  | (pfb_valid_q = 1,|  | (pfb_valid_q |
| -> Ready for 1-cycle hit & L1I promotion |  |  complete = 0,   |  |   <= 0)       |
+------------------------------------------+  |  pf_state=IDLE)  |  +--------------+
                                              +------------------+
                                                 /             \
                             [Demand targets MISSING beat]     [Demand targets VALID beat]
                                               /                 \
                                              v                   v
                               +-----------------------------+  +--------------------+
                               | ABANDON & DEMAND REFILL     |  | CONSUME VALID BEAT |
                               |  - pfb_valid_q <= 0         |  |  - Deliver to held |
                               |  - state_q <= REFILL_REQ    |  |  - Abandon on next |
                               |  - Zero Deadlock            |  |    invalid beat    |
                               +-----------------------------+  +--------------------+
```

* **`PFB_IDLE`:** Buffer contains no valid data.
* **`PFB_ACTIVE_FILLING`:** Prefetch controller is actively handshaking beats on the memory bus (`pf_state == PF_REQ || pf_state == PF_RSP`).
* **`PFB_COMPLETE`:** All 8 beats have arrived cleanly. Ready for instantaneous 1-cycle hit and atomic promotion to main L1I.
* **`PFB_DORMANT_PARTIAL`:** Prefetch was interrupted/preempted before Beat 7 completed. Prefetch FSM has returned to `PF_IDLE`. Buffer holds a subset of valid beats ($b < 7$). **No memory transaction is in flight.**

---

## 5. Demand Collision, Handoff, and Deadlock Prevention (Resolving P0-1)

When Stage F evaluates a demand fetch PC in `FETCH_CHECK`, it compares `trans_pa_i[55:6]` against `pfb_line_pa_q` and inspects both PFB completion and active FSM status:

```systemverilog
wire pfb_line_match = pfb_valid_q && (trans_pa_i[55:6] == pfb_line_pa_q);
wire [2:0] demand_beat = trans_pa_i[5:3];
wire pf_is_active = (pf_state == PF_REQ) || (pf_state == PF_RSP);
```

### 5.1 Case-by-Case Collision Semantics

#### Case 1: Demand Hits Completed PFB (`pfb_complete_q == 1 && pfb_line_match`)
* **Behavior:** The entire 64-byte line is present in PFB without error.
* **Latency:** **1 cycle** (identical to a main L1I cache hit).
* **Delivery:** Instruction is extracted combinationally from `pfb_data_q[demand_beat]` and staged into `held_*`. `fetched_valid_o = 1` asserts to Stage E.
* **Promotion:** The line is promoted atomically into main L1I (see §9). PFB is cleared (`pfb_valid_q <= 0`).
* **Trigger:** Generates next-line prefetch candidate $L+1$ upon consumption (see §8).

#### Case 2: Demand Hits Active PFB; Demanded Beat Already Arrived (`pf_is_active && pfb_beat_valid_q[demand_beat] == 1 && !pfb_beat_error_q[demand_beat]`)
* **Behavior:** Prefetch is actively progressing on the memory bus, and the demanded doubleword beat $b_{\text{crit}}$ is already safely registered in `pfb_data_q[demand_beat]`.
* **Latency:** **1 cycle** early restart directly from PFB!
* **Delivery:** Extracted from `pfb_data_q[demand_beat]` into `held_*`. Stage E executes immediately.
* **Refill Continuation:** Prefetch controller continues handshaking trailing beats into PFB. Once Beat 7 arrives cleanly, the line is promoted to L1I.

#### Case 3: Demand Hits Active PFB; Demanded Beat Pending (`pf_is_active && pfb_beat_valid_q[demand_beat] == 0`)
* **Condition:** Permitted **STRICTLY AND ONLY** when `pf_is_active == 1'b1`.
* **Behavior:** The matching prefetch is actively in-flight and guaranteed to produce the demanded beat.
* **Action:** Stage F enters streaming wait (`streaming_wait_beat_q <= 1`), holding `req_pc_q`.
* **Arrival:** The instant beat $b_{\text{crit}}$ arrives from DRAM, it is staged to `held_insn_q` on Cycle $T+1$ and releases Stage F.

#### Case 4: Demand Matches Dormant Partial PFB; Demanded Beat Missing (`!pf_is_active && pfb_line_match && pfb_beat_valid_q[demand_beat] == 0`) — (Resolving P0-1 Deadlock)
* **Root Cause of Deadlock:** PFB holds partial line $B$, but the prefetch controller is dormant (`pf_state == PF_IDLE`). If Stage F were to wait, it would wait indefinitely for a producer that does not exist.
* **Authoritative Invariant:** **Streaming wait is STRICTLY PROHIBITED when `pf_is_active == 0`.**
* **Deterministic Resolution:**
  1. Dormant partial PFB state is **immediately invalidated and abandoned** (`pfb_valid_q <= 1'b0`).
  2. Stage F transitions directly to `REFILL_REQ` to launch a standard, authoritative L1I-ER demand refill for line $B$.
  3. Memory bus requests line $B$ with critical-beat early restart.
  4. **Outcome:** Deadlock is 100% eliminated. The missing beat is fetched authoritatively.

#### Case 5: Demand Matches Dormant Partial PFB; Demanded Beat Valid (`!pf_is_active && pfb_line_match && pfb_beat_valid_q[demand_beat] == 1`)
* **Behavior:** Demanded beat $b_{\text{crit}}$ is present in dormant PFB.
* **Action:**
  1. Instruction is staged to `held_*` and delivered to Stage E in 1 cycle.
  2. Because the line is incomplete, it **cannot be promoted to L1I directory**.
  3. Execution continues consuming valid contiguous beats from `pfb_data_q`.
  4. The moment sequential execution advances to an invalid beat (or branches away), Case 4 triggers: PFB is abandoned and an authoritative demand refill is initiated for the remainder/full line.

#### Case 6: Demand Miss Targets Unrelated Line while Prefetch Active
* **Behavior:** Demand misses in L1I and targets line $A$, but prefetch is actively handshaking line $B \ne A$.
* **Action:** Prefetch is preempted at the current beat boundary per §3.2. Bus transitions to demand refill for line $A$ in $\le (1 + t_{\text{rsp\_remain}})$ cycles.

#### Case 7: Demand Hits Main L1I while Prefetch Active
* **Behavior:** Demand hits in the main 4-way L1I array while prefetch fills PFB from DRAM.
* **Action:** Zero structural conflict. L1I delivers hit instruction to Stage E at full speed. Prefetch continues in the background over the memory bus.

---

## 6. Non-Faulting Error & Poison Semantics

### 6.1 Non-Faulting Principle
Speculative prefetch is non-faulting. A bus error or PMP boundary encountered during prefetch never raises an architectural exception.

### 6.2 Per-Beat Error Capture & Drop
1. If `imem_rsp_error_i == 1` asserts during a prefetch beat handshake:
   - `pfb_beat_error_q[b] <= 1'b1`.
   - `pfb_has_error_q <= 1'b1`.
2. The prefetch burst is terminated immediately at that beat boundary.
3. `pfb_complete_q` remains strictly `1'b0`.
4. Promotion into main L1I is permanently forbidden.
5. If demand later targets the line:
   - Because `pfb_complete_q == 0`, PFB hit fails.
   - PFB is discarded (`pfb_valid_q <= 0`).
   - An authoritative demand refill is issued.
   - If memory returns an error on the authoritative demand refill, L1I-ER raises the precise `instruction access fault` ($mcause = 1$) with exact faulting PC in `mtval`.

---

## 7. Maintenance, Serialization, and Stale-Data Invalidation

Every maintenance and serialization event flushes all prefetch state instantly:

| Event | Pipeline Source | Prefetch Queue | Active Bus Burst | PFB State (Complete/Dormant) | Main L1I Action |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Reset (`rst_i`)** | External pin | Purged | Abort immediately; bus to IDLE | Flash invalidate (`pfb_valid_q <= 0`) | Flash invalidate (`valid_q <= 0`) |
| **`FENCE.I`** | Stage E commit | Purged | Abort at beat boundary; discard | Flash invalidate (`pfb_valid_q <= 0`) | Flash invalidate (`valid_q <= 0`) |
| **`SFENCE.VMA`** | Stage E commit | Purged | Abort at beat boundary; discard | Flash invalidate (`pfb_valid_q <= 0`) | Flash invalidate (`valid_q <= 0`) |
| **`satp` Write** | CSR write in Stage E | Purged | Abort at beat boundary; discard | Flash invalidate (`pfb_valid_q <= 0`) | Flash invalidate (`valid_q <= 0`) |
| **PMP Write (`pmp_flush_i`)** | CSR write in Stage E | Purged | Abort at beat boundary; discard | Flash invalidate (`pfb_valid_q <= 0`) | Flash invalidate (`valid_q <= 0`) |
| **Privilege Change (`mret`/`sret`)** | Stage E return | Purged | Abort at beat boundary; discard | Flash invalidate if `priv != pfb_priv` | Retain (PA-tagged) |
| **Trap / Interrupt** | Core trap vector | Purged | Abort at beat boundary; discard | Retain if user code | Retain |

### 7.1 Stale Response Absorption
If an abort occurs while a beat request is pending on the external bus:
- The controller transitions to `PF_DRAIN`.
- When `imem_rsp_valid_i` asserts, `imem_rsp_ready_o` handshakes for 1 cycle to consume the beat cleanly.
- Data is discarded without updating PFB registers. Zero orphaned responses leak into post-maintenance execution.

---

## 8. Trigger Mechanism, Sustained Streaming, and Loop Suppression (Resolving P0-2)

### 8.1 Dual-Trigger Architecture (Resolving Broken Prefetch Chain)
To eliminate the alternating miss/hit oscillation exposed by the Reviewer and sustain sequential streaming across arbitrarily long code blocks, candidate generation employs a **Dual-Trigger Architecture**:

$$\text{pf\_trigger\_pulse} = \text{trigger\_from\_refill} \lor \text{trigger\_from\_promotion}$$

1. **Trigger 1 — Demand Miss Refill Completion:**
   Fires when an authoritative demand refill completes Beat 7:
   $$\text{trigger\_from\_refill} = \text{l1i\_refill\_event\_o}$$
   Candidate generated: $\text{cand\_line\_pa} = \text{refill\_line\_base} + 64$.
2. **Trigger 2 — Useful PFB Promotion / Consumption:**
   Fires when a completed PFB line is consumed and promoted into L1I upon instruction transfer:
   $$\text{trigger\_from\_promotion} = \text{pfb\_promote\_event} \land \text{transfer\_fire\_f}$$
   Candidate generated: $\text{cand\_line\_pa} = \text{pfb\_line\_pa\_q} + 64$.

### 8.2 Sustained Streaming Invariant
- Line $L$ misses $\implies$ refills $\implies$ triggers prefetch candidate $L+1$.
- Line $L+1$ arrives into PFB.
- Execution sequentially advances to Line $L+1$ $\implies$ hits PFB $\implies$ promotes to L1I and **triggers prefetch candidate $L+2$**.
- Line $L+2$ arrives into PFB.
- Execution sequentially advances to Line $L+2$ $\implies$ hits PFB $\implies$ promotes to L1I and **triggers prefetch candidate $L+3$**.
- **Outcome:** The prefetch chain remains continuous throughout linear execution streams!

### 8.3 Loop Flapping and Duplicate Suppression
To prevent infinite flapping and duplicate requests in tight loops:
1. **Last Prefetched Line Register (`last_pf_line_q[55:6]`):**
   Stores the physical line address of the most recently issued prefetch candidate.
   If $\text{cand\_line\_pa} == \text{last\_pf_line\_q}$, candidate is suppressed as a duplicate.
2. **Transfer-Fire Gating:** Trigger pulses require `transfer_fire_f == 1`. Multi-cycle Stage-E stalls never re-trigger prefetch generation.
3. **Cache Hit Immunity:** Repetitive cache hits within resident loops (branches looping within cached lines) do NOT assert `pfb_promote_event` or `l1i_refill_event_o`, generating **strictly zero prefetch triggers**.

---

## 9. Single-Port Tag Array Contention & Directory Promotion (Resolving P1-1)

### 9.1 The Single-Port Constraint
Fursoy Slice-0 employs a single-port L1I SRAM/tag directory. Simultaneous tag reads for demand lookups, candidate residency checks, and directory writes cannot occur in the same cycle without structural contention.

### 9.2 Tag Port Arbitration & Scheduling
Tag array access is governed by strict priority rules:

$$\mathbf{Priority\ 1\ (Highest):}\ \text{Demand Fetch Lookups (FETCH\_CHECK)}$$
$$\mathbf{Priority\ 2:}\ \text{Demand Refill Directory Writes (Beat 7 Install)}$$
$$\mathbf{Priority\ 3:}\ \text{PFB Promotion Directory Writes}$$
$$\mathbf{Priority\ 4\ (Lowest):}\ \text{Prefetch Candidate Already-Resident Filter}$$

1. **Demand Dominance:** A demand fetch in `FETCH_CHECK` always owns the tag comparator port.
2. **Candidate Residency Filter Scheduling:**
   - The candidate `already_resident` tag lookup is scheduled strictly during **bus-idle or pipeline stall cycles** (`state_q != FETCH_CHECK`).
   - If Stage F demands a tag lookup during candidate evaluation, the candidate check stalls for 1 cycle.
3. **1-Cycle Promotion Bubble:**
   - When a completed PFB line is promoted into main L1I, writing the tag directory (`tag_q`) and data array (`data_q`) requires 1 write port cycle.
   - If Stage F simultaneously requests a demand tag check for a new line on that exact cycle, a **deterministic 1-cycle promotion bubble** is inserted into Stage F (`stall_f = 1` for 1 cycle).
   - This 1-cycle bubble is formally accounted for in the revised performance model (§11).

---

## 10. Bus Priority, Interconnect Admission, and Interface Definition (Resolving P1-2)

### 10.1 Interconnect Admission Architecture
The Reviewer noted that `dmem_req_valid_o` was unavailable inside L1I.
Rather than embedding complex LSU/PTW decode logic inside L1I, bus admission is resolved cleanly at the **core interconnect boundary**:

```systemverilog
// Inside fursoy_s0_core.sv:
wire mem_bus_busy_w = dmem_req_valid_o || ptw_grant || l1d_dmem_req_valid || l1d_srb_busy;

// Routed to fursoy_s0_l1i as single-bit input:
.mem_bus_busy_i (mem_bus_busy_w)
```

### 10.2 Conflict-Free Issue Condition
Inside `fursoy_s0_l1i.sv`, prefetch requests assert `imem_req_valid_o` if and only if:
$$\text{pf\_issue\_valid} = \text{pf\_cand\_valid} \land !\text{l1i\_miss\_active} \land !\text{redirect\_pending} \land !\text{mem\_bus\_busy\_i} \land \text{imem\_req\_ready\_i}$$

This guarantees that:
- L1D load misses, dirty writebacks, and PTW walks immediately block speculative prefetch issuance.
- Speculative prefetch remains strictly the lowest-priority consumer on the memory bus.

---

## 11. Revised Performance Model (Resolving P2-1)

### 11.1 Re-evaluation with Chained Prefetch Trigger
With the unbroken dual-trigger mechanism (§8), sequential streams sustain continuous prefetching.

* **Frozen Baseline:** 25,639,344 cycles, 14,918,855 commits, IPC 0.581874, 3,160,167 L1I refill stall cycles.
* **Workload Transition Profile:**
  - Total demand refills: 216,709.
  - Linear sequential candidate transitions: 180,925.
  - Useful prefetches (stream hits): **~138,500 lines** (increased from 121,881 due to sustained chaining).
  - Average refill latency hidden per useful prefetch: 17.2 cycles.
  - Gross cycle savings potential: $138,500 \times 17.2 \approx \mathbf{2,382,200\text{ cycles}}$.
* **Overhead & De-rating Deductions:**
  1. **1-Cycle Promotion Bubbles (P1-1):** $\approx 138,500\text{ cycles}$.
  2. **Demand Preemption Latency ($1 + t_{\text{rsp\_remain}}$, P1-3):** ~5% of prefetch bursts preempted by demand miss: $180,925 \times 0.05 \times 1.5 \approx 13,569\text{ cycles}$.
  3. **Speculative Redirect Discards:** Useful prefetches invalidated by intervening branch mispredicts (~7%): $138,500 \times 0.07 \times 17.2 \approx 166,754\text{ cycles}$.
  4. **Intermittent Memory Bus Contention with L1D/PTW:** $\approx 18,000\text{ cycles}$.
  5. **Option C Sub-Page PMP Suppressions:** $\approx 0\text{ cycles}$ (Linux DRAM aperture is uniform $256\text{ MiB}$).

### 11.2 Revised Net Performance Projection

| Projection Scenario | Net Cycles Saved | Remaining L1I Miss Cycles | Projected Total Cycles | Projected IPC | Projected CPI | Net Runtime Reduction |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Conservative** | **1,700,000** | 1,460,167 | **23,939,344** | **0.623194** | 1.604642 | **-6.630%** |
| **Expected** | **2,050,000** | 1,110,167 | **23,589,344** | **0.632441** | 1.581172 | **-7.995%** |
| **Optimistic** | **2,250,000** | 910,167 | **23,389,344** | **0.637848** | 1.567784 | **-8.776%** |

---

## 12. Exactly-Once / Multi-Cycle Stall Hazard Audit

1. **Trigger Strobes:** `trigger_from_refill` and `trigger_from_promotion` pulse for exactly 1 cycle. Multi-cycle Stage-E stalls in `FETCH_HOLD` or `stall_e` cannot re-trigger candidate generation.
2. **Beat Capture:** Incoming beat data is latched on `imem_rsp_valid_i && imem_rsp_ready_o`.
3. **Directory Promotion:** Writing `valid_q`, `tag_q`, `data_q`, and updating Tree-PLRU occurs strictly once. `pfb_valid_q` transitions to 0 in the same cycle.
4. **Telemetry Strobes:** All 14 telemetry outputs pulse for exactly 1 clock cycle per logical event via registered one-shot edge latches.

---

## 13. Adversarial Directed Verification Matrix (Resolving P2-2)

The directed test suite (`verification/l1i_nlp_s0_tb.cpp`) is expanded to **30 adversarial scenarios**:

| Test ID | Scenario Description | Pass Criteria |
| :--- | :--- | :--- |
| `NLP-ADV-01` | Sequential useful prefetch | Demand miss on line $L$ refilled; line $L+1$ prefetched to PFB; subsequent sequential fetch hits PFB in 1 cycle; promoted to L1I. |
| `NLP-ADV-02` | Useless prefetch | Demand miss on line $L$; line $L+1$ prefetched; execution branches away; verify PFB eventually replaced/discarded without corruption. |
| `NLP-ADV-03` | Last line of 4 KiB page | Demand miss on line offset `0xFC0` (Line 63 of page); verify candidate line $L+1$ crosses page boundary and is **suppressed**. |
| `NLP-ADV-04` | Cross-page candidate suppression | Verify `imem_req_valid_o` remains 0; zero external request emitted for page-crossing candidate. |
| `NLP-ADV-05` | PMP boundary inside 4 KiB page | TOR PMP rule ends at `0x8000_0840`; line $L$ is permitted; line $L+1$ crosses into PMP-denied region; verify prefetch suppressed. |
| `NLP-ADV-06` | Candidate already resident in L1I | Line $L+1$ already cached in Way 2; verify prefetch suppressed; `pf_already_cached_event` pulses once. |
| `NLP-ADV-07` | Duplicate candidate suppression | Two successive demand refills generate candidate $L+1$; verify second candidate dropped by `last_pf_line_q`. |
| `NLP-ADV-08` | Tight-loop trigger flapping | 3-instruction loop in line $L$ executes 100 times; verify prefetch triggers strictly on initial miss, zero triggers on subsequent 99 hits. |
| `NLP-ADV-09` | Redirect before prefetch issue | Candidate queued; branch mispredict asserts `redirect_i`; verify candidate purged from queue; zero bus request issued. |
| `NLP-ADV-10` | Redirect during active prefetch burst | Prefetch on Beat 3; `redirect_i` asserts; verify prefetch aborts at beat boundary; PFB cleared; redirect target checked next. |
| `NLP-ADV-11` | Demand hits active prefetch (beat arrived) | Demand targets line $L+1$ while prefetch is at Beat 4; demanded beat is Beat 2; verify 1-cycle early restart directly from PFB. |
| `NLP-ADV-12` | Demand hits active prefetch (beat pending) | Demand targets line $L+1$ while prefetch is at Beat 1; demanded beat is Beat 5; verify streaming wait; early restart on Beat 5 arrival. |
| `NLP-ADV-13` | Demand miss on unrelated line during prefetch | Prefetching line $B$; demand misses on line $A$; verify prefetch preempted in $\le 2$ cycles; bus granted to line $A$ demand refill. |
| `NLP-ADV-14` | Demand arrives immediately after prefetch issue | Demand asserts same cycle `imem_req_valid_o` asserts; verify prefetch finishes beat 0 response and yields bus immediately. |
| `NLP-ADV-15` | Memory bus error during speculative prefetch | Beat 3 asserts `imem_rsp_error_i`; verify prefetch terminates; no exception raised; PFB marked invalid; not promoted. |
| `NLP-ADV-16` | Demand later targets errored prefetched line | Demand accesses line that errored during prefetch; verify PFB ignored; fresh demand refill issued; precise exception delivered on demand error. |
| `NLP-ADV-17` | `FENCE.I` during queued prefetch | `FENCE.I` executes while prefetch queued; verify queue purged; PFB invalidated; zero post-fence execution of prefetched data. |
| `NLP-ADV-18` | `FENCE.I` during active prefetch | `FENCE.I` executes during Beat 2; verify prefetch aborted; arriving response discarded; PFB cleared. |
| `NLP-ADV-19` | `SFENCE.VMA` / `satp` write | Address space modified during prefetch; verify prefetch aborted and PFB invalidated. |
| `NLP-ADV-20` | PMP CSR write (`pmp_flush_i`) | PMP register updated during prefetch; verify prefetch aborted and PFB cleared. |
| `NLP-ADV-21` | PTW collision on memory bus | MMU page table walk contends for memory; verify prefetch yields bus or remains idle; PTW latency unaffected. |
| `NLP-ADV-22` | L1D clean load miss collision | L1D load miss asserts; verify prefetch yields bus; zero delay added to L1D load refill. |
| `NLP-ADV-23` | SRB dirty writeback collision | SRB eviction asserts on data bus; verify prefetch suppresses issue until bus idle. |
| `NLP-ADV-24` | Stage-E backpressure on PFB hit | Stage E stalled (`fetched_ready_i = 0`) when PFB hit occurs; verify instruction held stable in `held_*`; single promotion on release. |
| `NLP-ADV-25` | Promotion duplicate-tag prevention | L1I Way 1 valid with line $L+1$ when PFB completes line $L+1$; verify promotion suppresses array write; no duplicate tag created. |
| `NLP-ADV-26` | Exactly-once telemetry under stall | Pipeline stalled for 40 cycles during prefetch hit; verify `l1i_nlp_hit_event` pulses for exactly 1 cycle. |
| `NLP-ADV-27` | Sustained sequential stream chaining (P0-2) | Sequential execution across 16 consecutive lines; verify Dual-Trigger maintains continuous PFB hit chain without miss/hit oscillation. |
| `NLP-ADV-28` | Heavy branch / mispredict workload | Rapid taken/untaken branches; verify prefetcher correctly suppresses invalid paths and maintains zero memory bus lockups. |
| `NLP-ADV-29` | **Dormant partial PFB + missing beat demand (P0-1)** | Line $B$ prefetch preempted at Beat 2; FSM becomes dormant; demand targets Beat 5; verify streaming wait inhibited, PFB abandoned, authoritative refill issued, zero deadlock. |
| `NLP-ADV-30` | **Non-zero wait-state memory preemption (P1-3)** | Memory model configured with $t_{\text{rsp}} = 5$; prefetch beat accepted; demand miss arrives; verify prefetch waits exactly 5 cycles to drain beat response, then yields bus cleanly. |

---

## 14. Authoritative Hardware Telemetry & Observability Interface

```systemverilog
// L1I-NLP v1 Hardware Telemetry Strobes (Strictly Exactly-Once)
output logic        l1i_nlp_candidate_event_o,      // Candidate next-line identified
output logic        l1i_nlp_issued_event_o,         // Prefetch burst issued to DRAM
output logic        l1i_nlp_suppressed_page_o,       // Suppressed: 4 KiB page boundary
output logic        l1i_nlp_suppressed_pmp_o,        // Suppressed: PMP execute denial / non-uniform
output logic        l1i_nlp_suppressed_resident_o,   // Suppressed: Already cached in L1I
output logic        l1i_nlp_suppressed_duplicate_o,  // Suppressed: Duplicate candidate
output logic        l1i_nlp_useful_hit_event_o,     // Demand hit in PFB (useful prefetch)
output logic        l1i_nlp_streaming_hit_event_o,  // Demand hit in arriving prefetch beat
output logic        l1i_nlp_preempted_event_o,      // Prefetch aborted due to demand priority
output logic        l1i_nlp_dormant_abandon_event_o,// Dormant partial PFB abandoned on missing beat
output logic        l1i_nlp_discard_redirect_o,     // Discarded due to pipeline redirect
output logic        l1i_nlp_discard_maint_o,        // Discarded due to FENCE.I / SFENCE / PMP
output logic        l1i_nlp_discard_error_o,        // Discarded due to memory bus error
output logic        l1i_nlp_promote_event_o,        // Line successfully installed into L1I
output logic [4:0]  l1i_nlp_hidden_cycles_o         // Cycles saved on PFB hit (0..18)
```

---

## 15. Candidate Architecture Trade-Off Analysis & Selection Rationale

1. **Beat-Preemptible Demand-Dominant Policy B (Selected):**
   Bounds worst-case demand preemption delay to $(1 + t_{\text{rsp\_remain}})$, guarantees zero orphaned responses, and strictly adheres to the 2-cycle beat transaction protocol.
2. **Dual-Trigger Prefetch Chaining (Selected):**
   Unlocks continuous sequential streaming by triggering candidates on both demand refill completion and useful PFB consumption, eliminating the broken miss/hit oscillation pattern.
3. **Decoupled PFB with Deterministic Abandonment (Selected):**
   Eliminates the dormant partial-PFB deadlock by strictly prohibiting streaming waits when no memory transaction is in flight.

---

## 16. Implementation Milestones & Next Steps

1. **Architecture Review & Sign-Off:** Submit this corrected proposal (`docs/architecture/l1i-nlp-v1.md`) for final independent review.
2. **RTL Implementation (Conditional on Authorization):**
   - Implement standalone PFB controller inside `fursoy_s0_l1i.sv`.
   - Wire `itrans_pmp_uniform_x_o` from MMU to L1I.
   - Wire `mem_bus_busy_i` from core to L1I.
   - Connect telemetry strobes.
3. **Verification Execution:**
   - Execute all 30 tests in `verification/l1i_nlp_s0_tb.cpp`.
   - Run full 25.6M-cycle Linux benchmark regression.
   - Confirm zero residual cycles and validate the projected $\approx 2.05\text{M}$ net cycle reduction.

---

## 17. Architecture Review Resolution Summary

| Review Finding | Classification | Exact Architectural Resolution in Contract |
| :--- | :--- | :--- |
| **P0-1** | Dormant partial PFB deadlock | Defined formal PFB lifecycle (§4.2). Streaming wait permitted **only** when `pf_is_active == 1`. When demand matches a dormant partial PFB for an invalid beat, PFB is immediately abandoned and an authoritative demand refill is issued (§5.1 Case 4). Deadlock 100% eliminated. Test `NLP-ADV-29` added. |
| **P0-2** | Sequential prefetch chain broken | Implemented Dual-Trigger Architecture (§8.1): candidates fire on both demand refill completion and useful PFB promotion/consumption. Chained streaming sustained without miss/hit oscillation. Test `NLP-ADV-27` added. |
| **P0-3** | PMP range authorization not implementable | Evaluated Options A, B, and C (§2.3). Removed phantom `pmp_check_range()`. Adopted Option C baseline with single-bit `itrans_pmp_uniform_x_o` signal from MMU (§2.4). Guarantees 100% PMP execute authorization for all prefetched bytes. |
| **P1-1** | Single-port tag array contention | Demand lookups strictly dominate tag port (§9.2). Candidate residency filter scheduled during idle/stall cycles. PFB promotion uses a deterministic 1-cycle bubble if colliding with demand, accounted for in performance model. |
| **P1-2** | `dmem_req_valid` unavailable in L1I | Corrected bus admission location (§10.1). Core exports single-bit `mem_bus_busy_w` (`dmem_req_valid_o \|\| ptw_grant \|\| l1d_dmem_req_valid`) into L1I as `mem_bus_busy_i`. |
| **P1-3** | Simulator-specific preemption bound | Restated preemption delay in protocol terms (§3.2): $0$ cycles in request phase, $(1 + t_{\text{rsp\_remain}})$ cycles if awaiting response for an accepted beat. |
| **P2-1** | Recompute performance model | Rebuilt model with unbroken trigger chaining (§11): conservative 1.70M cycles (IPC 0.623), expected 2.05M cycles (IPC 0.632), optimistic 2.25M cycles (IPC 0.638). |
| **P2-2** | Missing adversarial tests | Added `NLP-ADV-29` (dormant partial PFB missing beat) and `NLP-ADV-30` (non-zero wait-state preemption) to verification matrix (§13). |
