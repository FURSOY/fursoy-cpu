# Physical Memory Protection (PMP) architectural contract — frozen v1

Status: independent architectural and RTL reviews completed; **ACCEPT AND FREEZE**.
This contract defines the correctness-first PMP specification for the single-core Fursoy
RV64 implementation. The reviewed and frozen M/S/U Bare architecture (`s-mode-bare-v1.md`)
and Sv39 MMU architecture (`sv39-mmu-v1.md`) remain the compatibility baseline.

---

## 1. Authority, terminology, and scope

Normative reference: RISC-V ISA manual release **20260120**, Machine-Level ISA
**1.13**, Section 3.7 (*"Physical Memory Protection"*), and Supervisor-Level ISA **1.13**:

- [Machine-Level ISA, Section 3.7 Physical Memory Protection](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html#pmp)
- [Supervisor-Level ISA, including Sv39 and MPRV/SUM/MXR](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- [Privileged CSR Architecture](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html)

Architectural descriptions below adapt these RISC-V International specifications,
licensed [CC BY 4.0](https://github.com/riscv/riscv-isa-manual/blob/main/LICENSE).
The classifications used throughout are:

- **Required** — ratified-spec behavior. RTL has no project freedom except a
  choice expressly permitted by the specification.
- **Choice** — a Fursoy decision among architecturally permitted behaviors.
- **Simplification** — a correctness-preserving first-version restriction that
  must not be mistaken for the intended server-class endpoint.

This specification defines physical memory protection for physical instruction
fetches, physical data loads/stores, and hardware page-table-walk (PTW) physical
reads. It integrates with the existing in-order single-issue pipeline, the Sv39
MMU, the CSR unit, and the platform memory/CLINT interconnect.

Explicitly deferred: Smepmp (enhanced PMP / machine-mode isolation), PMP paging
extensions, hardware PMA dynamic registers, multiple harts, dynamic granularity
$G > 0$, caches, TLBs, and Linux boot.

---

## 2. Supported PMP version and scope

### 2.1 Entry count and CSR assignment

**Choice**: Fursoy implements **16 PMP entries** ($N = 16$, indexed 0 through 15).
This matches the standard RISC-V profile baseline for RV64 server/Linux-capable cores,
providing sufficient entries for OpenSBI, Linux kernel memory protection, device
isolation, and user payload sandboxing without excess gate count in Slice-0.

**Required (RV64 CSR packing)**:
In RV64, PMP configuration registers are packed 8 entries per 64-bit CSR, placed
at even CSR addresses:

- `pmpcfg0` (CSR `0x3a0`): RW from M-mode; packs configuration bytes for entries 0..7:
  - `pmpcfg0[7:0]`   = `pmp0cfg`
  - `pmpcfg0[15:8]`  = `pmp1cfg`
  - `pmpcfg0[23:16]` = `pmp2cfg`
  - `pmpcfg0[31:24]` = `pmp3cfg`
  - `pmpcfg0[39:32]` = `pmp4cfg`
  - `pmpcfg0[47:40]` = `pmp5cfg`
  - `pmpcfg0[55:48]` = `pmp6cfg`
  - `pmpcfg0[63:56]` = `pmp7cfg`
- `pmpcfg2` (CSR `0x3a2`): RW from M-mode; packs configuration bytes for entries 8..15:
  - `pmpcfg2[7:0]`   = `pmp8cfg`
  - `pmpcfg2[15:8]`  = `pmp9cfg`
  - `pmpcfg2[23:16]` = `pmp10cfg`
  - `pmpcfg2[31:24]` = `pmp11cfg`
  - `pmpcfg2[39:32]` = `pmp12cfg`
  - `pmpcfg2[47:40]` = `pmp13cfg`
  - `pmpcfg2[55:48]` = `pmp14cfg`
  - `pmpcfg2[63:56]` = `pmp15cfg`
- `pmpcfg1` (CSR `0x3a1`) and `pmpcfg3` (CSR `0x3a3`): **Illegal in RV64**. Any access
  from any privilege mode raises an illegal-instruction exception (cause 2).
- `pmpcfg4`..`pmpcfg15` (CSRs `0x3a4`..`0x3af`): Unimplemented, raise illegal-instruction exception.

**Required (PMP address registers)**:
Each entry $i \in \{0 \dots 15\}$ has an individual 64-bit CSR `pmpaddr`$i$:

- `pmpaddr0`..`pmpaddr15` (CSRs `0x3b0`..`0x3bf`): RW from M-mode.
- `pmpaddr16`..`pmpaddr63` (CSRs `0x3c0`..`0x3ef`): Unimplemented, raise illegal-instruction exception.

### 2.2 Configuration byte layout (`pmpicfg`)

Each 8-bit `pmpicfg` layout:

| Bit | Field | Description | WARL / Implementation behavior |
|---|---|---|---|
| 0 | R | Read permission | RW (when $L=0$) |
| 1 | W | Write permission | WARL (when $L=0$): writable only when $R=1$ (or with $R$ written as 1). Combinations with $W=1, R=0$ are reserved in base PMP; writes coerce $W \to 0$ (Section 4.1) |
| 2 | X | Execute permission | RW (when $L=0$) |
| 4:3 | A | Address-matching mode | RW (when $L=0$); supports OFF(00), TOR(01), NA4(10), NAPOT(11) |
| 6:5 | Reserved | Reserved bits | Hardwired to `2'b00` (WARL read-only zero) |
| 7 | L | Lock bit | Writable $0 \to 1$ from M-mode; once 1, locked until reset |

### 2.3 Address granularity ($G$) and address width

**Choice**: Granularity parameter **$G = 0$**.
Per the RISC-V privileged specification, the minimum region size is $2^{G+2}$ bytes:
- With $G = 0$, minimum region size is $2^{0+2} = 4$ bytes.
- Mode **NA4** ($A = 2'b10$) is fully supported.
- Mode **NAPOT** ($A = 2'b11$) supports power-of-two regions $\ge 8$ bytes ($2^{k+3}$ bytes for $k \ge 0$).

**Required (Physical address mapping to `pmpaddr`)**:
Under Sv39, the architectural physical address width is 56 bits (`PA[55:0]`).
In RV64 with $G = 0$, `pmpaddr`$i$ holds bits `PA[55:2]`:

- `pmpaddr`$i$`[53:0]`: Holds `PA[55:2]` (54 bits).
- `pmpaddr`$i$`[63:54]`: Hardwired to zero (WARL read-only zero). Writes to bits 63:54 are ignored.

### 2.4 Reset state

**Required**:
- Upon hardware reset, all configuration bytes `pmp0cfg`..`pmp15cfg` reset to `8'h00` ($L=0$, $A=\text{OFF}$, $R=0$, $W=0$, $X=0$).
- All address registers `pmpaddr0`..`pmpaddr15` reset to `64'h0000_0000_0000_0000`.
- In this reset state:
  - M-mode has unrestricted access to the entire physical address space.
  - S-mode and U-mode have **no access** to physical memory (any S-mode or U-mode access is denied and triggers an access-fault exception).

---

## 3. Address matching mechanics

Every physical access has an address range $[A_{\text{start}}, A_{\text{end}}]$, where:
- $A_{\text{start}} = \text{PA}$;
- $A_{\text{end}} = \text{PA} + \text{len} - 1$, with $\text{len} \in \{1, 2, 4, 8\}$ bytes.

All physical address comparisons operate on full 56-bit zero-extended physical addresses.

### 3.1 Address matching modes ($A$ field)

#### 1. OFF ($A = 2'b00$)
The PMP entry is disabled. It matches no address.

#### 2. TOR — Top of Range ($A = 2'b01$)
Defines a region $[B_{\text{lower}}, B_{\text{upper}})$ where:
- For entry $i = 0$: $B_{\text{lower}} = 0$;
- For entry $i > 0$: $B_{\text{lower}} = \text{pmpaddr}_{i-1}[53:0] \ll 2$;
- For entry $i \ge 0$: $B_{\text{upper}} = \text{pmpaddr}_i[53:0] \ll 2$.

**Required boundary rules**:
- Range is half-open: $B_{\text{lower}} \le \text{address} < B_{\text{upper}}$.
- If $B_{\text{lower}} \ge B_{\text{upper}}$, the region is null/empty and matches no address.
- `pmpaddr_{i-1}` defines the lower bound for entry $i$ regardless of the configuration or mode ($A$ field) of entry $i-1$ (even if entry $i-1$ is OFF).
- **TOR upper-bound limitation**: Because `pmpaddr` holds `PA[55:2]`, the highest representable TOR upper bound is `54'h3f_ffff_ffff_ffff << 2 = 56'hffff_ffff_ffff_fffc`. TOR cannot cover the uppermost 4 bytes (`56'hffff_ffff_ffff_fffc .. 56'hffff_ffff_ffff_ffff`) of the 56-bit PA space; software requiring protection or access covering the entire 56-bit space must configure a NAPOT region.

#### 3. NA4 — Naturally Aligned 4-byte Region ($A = 2'b10$)
Because $G = 0$, NA4 is available:
- $B_{\text{lower}} = \text{pmpaddr}_i[53:0] \ll 2$;
- Region size = 4 bytes;
- Region is $[B_{\text{lower}}, B_{\text{lower}} + 4)$.

#### 4. NAPOT — Naturally Aligned Power-of-Two Region ($A = 2'b11$)
The region size and base address are encoded by the position of the least-significant zero bit in `pmpaddr_i[53:0]`:

Let $k$ be the index of the least-significant zero bit in `pmpaddr_i[53:0]` (i.e. bits $k-1:0$ are all ones):
- For $k \in \{0 \dots 52\}$: size = $2^{k+3}$ bytes:
  - If `pmpaddr_i[0] == 0` ($k=0$): size = 8 bytes ($2^3$);
  - If `pmpaddr_i[1:0] == 2'b01` ($k=1$): size = 16 bytes ($2^4$);
  - If `pmpaddr_i[2:0] == 3'b011` ($k=2$): size = 32 bytes ($2^5$).
- For $k = 53$ (bit 53 is 0, bits 52:0 are 1): size = $2^{53+3} = 2^{56}$ bytes. Base address is 0. This exactly spans the entire implemented 56-bit physical address space $[0, 2^{56})$.
- For $k = 54$ (all 54 bits `pmpaddr_i[53:0] == 54'h3f_ffff_ffff_ffff`): size = $2^{54+3} = 2^{57}$ bytes. Base address is 0. This saturates and also covers the entire 56-bit physical address space $[0, 2^{56})$.
- Base address calculation:
  $$\text{Base} = (\text{pmpaddr}_i[53:0] \gg (k+1)) \ll (k+3)$$
  (i.e., clearing bit $k$ and all lower bits $k-1:0$, then shifting left by 2).
- Region is $[\text{Base}, \text{Base} + \text{Size})$.

**No address overflow**:
All memory accesses in Fursoy (4-byte instruction fetch, 1/2/4/8-byte naturally aligned LSU accesses, and 8-byte PTW PTE reads) are naturally aligned powers of two $\le 8$ bytes. Consequently, the access range $[A_{\text{start}}, A_{\text{end}}]$ with $A_{\text{end}} = A_{\text{start}} + \text{len} - 1$ will never overflow or wrap around the 56-bit physical address space boundary ($2^{56}$).

### 3.2 Entry predicates and first-match priority

**Required predicates**:
For every configured PMP entry $i \in \{0 \dots 15\}$ that is active ($A \ne \text{OFF}$), two formal predicates are evaluated against the access $[A_{\text{start}}, A_{\text{end}}]$:

1. **`overlaps[i]`**: Entry $i$ contains at least one byte of the access $[A_{\text{start}}, A_{\text{end}}]$:
   $$\max(A_{\text{start}}, B_{\text{lower}, i}) \le \min(A_{\text{end}}, B_{\text{upper}, i} - 1)$$
2. **`contains[i]`**: Entry $i$ wholly contains every byte of the access $[A_{\text{start}}, A_{\text{end}}]$:
   $$B_{\text{lower}, i} \le A_{\text{start}} \quad \text{and} \quad A_{\text{end}} < B_{\text{upper}, i}$$

For an inactive entry ($A = \text{OFF}$), `overlaps[i] = 0` and `contains[i] = 0`.

**Required selection and priority rule**:
PMP entries are prioritized strictly in index order (entry 0 has the highest priority, entry 15 has the lowest):

1. Identify the **lowest-indexed entry $i$** for which `overlaps[i] == 1`.
2. If **no entry overlaps** the access (`overlaps[i] == 0` for all $i \in \{0 \dots 15\}$):
   - Apply the default no-match privilege rule (Section 3.4).
3. If a lowest-indexed overlapping entry $i$ exists:
   - **Boundary-crossing denial**: If `contains[i] == 0` (entry $i$ overlaps at least one byte but fails to contain all bytes of the access):
     - The access crosses a protection boundary. It is **denied immediately** and raises an **access-fault exception** (causes 1, 5, or 7).
     - Hardware **must NOT inspect any subsequent entry $j > i$**. A later entry cannot rescue the access even if entry $j$ covers the remaining bytes or the entire span.
     - This denial applies unconditionally, including for current/effective M-mode and even when the selected entry has $L = 0$.
   - **Full containment**: If `contains[i] == 1` (entry $i$ contains all bytes of the access):
     - Apply entry $i$'s permission and effective-privilege enforcement rules (Section 4.3).
     - No subsequent entry $j > i$ is examined.

### 3.3 Partial-match semantics and boundary crossing rationale

A single architectural instruction fetch or memory access must not span distinct protection domains, split permissions, or be partially committed. The two-predicate formulation (`overlaps` and `contains`) ensures:
- If an access straddles the boundary between two adjacent PMP regions (e.g. entry 0 covers bytes $0..3$ and entry 1 covers bytes $4..7$ of an 8-byte access), entry 0 is the lowest-indexed overlapping entry (`overlaps[0] = 1`), but `contains[0] = 0`. The access faults immediately; entry 1 is never evaluated.
- If an access crosses the boundary between a configured PMP region and an unconfigured region, it faults immediately.
- Even M-mode with $L=0$ is barred from spanning across active PMP region boundaries.

### 3.4 Default behavior (no matching entry)

**Required**:
If an access does not match any byte of any PMP entry (all entries are OFF, or no region covers any byte of the access):
- If the access privilege is **M-mode**: the access **succeeds**.
- If the access privilege is **S-mode** or **U-mode**: the access **fails** and raises an **access-fault exception**.

---

## 4. Permissions and privilege enforcement

### 4.1 Permission bits (R, W, X) and WARL legalization

The permission bits $R$, $W$, and $X$ in `pmpicfg` specify access rights:
- $R = 1$: Read permission granted.
- $W = 1$: Write permission granted.
- $X = 1$: Execute (instruction fetch) permission granted.

**Base PMP WARL legalization rule**:
In the ratified base RISC-V Privileged ISA (without Smepmp), configurations where $W=1$ and $R=0$ are **reserved for future standard use**. Write-only physical memory regions do not exist.
Fursoy v1 implements the explicit, deterministic WARL legalization rule:
$$W_{\text{effective}} = R_{\text{written}} \mathbin{?} W_{\text{written}} : 1'b0$$

Consequently:
- An attempt by software to write `R=0, W=1` (with either $X=0$ or $X=1$) results in $W$ being cleared to 0 upon writeback and readback ($W=0$), while other independently legal fields ($X, A, L$) are preserved.
- Writing `pmpicfg = 8'h02` ($R=0, W=1, X=0$) legalizes and reads back as `8'h00` ($R=0, W=0, X=0$).
- Writing `pmpicfg = 8'h06` ($R=0, W=1, X=1$) legalizes and reads back as `8'h04` ($R=0, W=0, X=1$).
- Write-only physical memory regions are strictly unsupported and non-existent.

**Supported permission encodings**:
The valid legal permission encodings in `pmpicfg` are:
| R | W | X | Meaning |
|---|---|---|---|
| 0 | 0 | 0 | No access (non-accessible guard region; all accesses fail) |
| 1 | 0 | 0 | Read-only |
| 1 | 1 | 0 | Read-write |
| 0 | 0 | 1 | Execute-only |
| 1 | 0 | 1 | Read-execute |
| 1 | 1 | 1 | Read-write-execute |

Status bits SUM and MXR (from `mstatus`/`sstatus`) **do not alter PMP checks**. MXR makes execute-only pages readable *only* in the Sv39 page-table walker; it does **not** override a PMP entry where $R = 0$.

### 4.2 Effective privilege evaluation

Let $P_{\text{arch}} \in \{\text{U}(00), \text{S}(01), \text{M}(11)\}$ be the current architectural privilege mode of the core.
Define the effective privilege $P_{\text{eff}}$ for a physical access as follows:

| Access type | Condition | Effective privilege $P_{\text{eff}}$ |
|---|---|---|
| Instruction fetch | Always | $P_{\text{arch}}$ (MPRV is ignored) |
| Page-table-walk (PTW) memory read | Always | **S-mode** ($P_{\text{eff}} = \text{S}$) |
| Explicit load / store | $P_{\text{arch}} = \text{M}$ and `mstatus.MPRV = 1` | **`mstatus.MPP`** |
| Explicit load / store | All other cases | $P_{\text{arch}}$ |

### 4.3 Permission checking rules

For an access with required operation $\text{Op} \in \{\text{Fetch}, \text{Load}, \text{Store}\}$:
- $\text{Fetch}$ requires $X = 1$;
- $\text{Load}$ requires $R = 1$;
- $\text{Store}$ requires $W = 1$.

Given effective privilege $P_{\text{eff}}$ and the selected entry $i$ (where `overlaps[i] == 1` and `contains[i] == 1`):

1. **If a containing entry $i$ is selected**:
   - If $P_{\text{eff}} == \text{M}$:
     - If $L = 0$: **Permitted** (M-mode bypasses permissions of unlocked entry).
     - If $L = 1$: Permissions enforced. The access succeeds if the corresponding permission bit is 1; otherwise, it **fails**.
   - If $P_{\text{eff}} \in \{\text{S}, \text{U}\}$:
     - Permissions enforced regardless of $L$. The access succeeds if the corresponding permission bit is 1; otherwise, it **fails**.

2. **If no entry overlaps the access (`overlaps[i] == 0` for all $i$)**:
   - If $P_{\text{eff}} == \text{M}$: **Permitted**.
   - If $P_{\text{eff}} \in \{\text{S}, \text{U}\}$: **Failed** (denied by default).

---

## 5. Lock semantics ($L$ bit)

### 5.1 Locking of configuration and address registers

When bit 7 ($L$) of `pmpicfg` is set to 1:
1. Entry $i$ is **locked**.
2. Any subsequent write from software to `pmpicfg` has no effect on any bit of `pmpicfg` ($L, A, X, W, R$ remain unchanged).
3. Any subsequent write from software to `pmpaddr`$i$ has no effect on `pmpaddr`$i$.
4. The $L$ bit can only be cleared by a **hardware reset**.
5. The permissions $R, W, X$ of entry $i$ apply to M-mode accesses as well as S and U modes.

### 5.2 Preceding TOR entry lock rule

**Required**:
If entry $i$ has $L = 1$ and $A = \text{TOR}$ ($2'b01$), where $i > 0$:
- The lower bound of entry $i$ is determined by `pmpaddr_{i-1}`.
- Therefore, **writes to `pmpaddr_{i-1}` are also ignored**, even if entry $i-1$ itself has $L = 0$.
- However, if entry $i-1$ has $L = 0$, writes to `pmp(i-1)cfg` remain permitted (the configuration byte of entry $i-1$ is not locked by entry $i$'s lock).

*Rationale*: Prevents software from altering the effective protected range of locked entry $i$ by modifying its lower bound in `pmpaddr_{i-1}`.

---

## 6. Interaction with Sv39 / MMU

PMP and Sv39 virtual memory are strictly hierarchical and orthogonal:
1. **Sv39 translation stage**: Operates on virtual addresses (VA). Checks PTE validity, canonical address formation, superpage alignment, PTE $U/S$ permissions, PTE $R/W/X$ permissions, SUM, MXR, and Svade $A/D$ bits. Generates **page faults** (causes 12, 13, 15).
2. **PMP protection stage**: Operates exclusively on **physical addresses (PA)**. Checks physical range and PMP permissions. Generates **access faults** (causes 1, 5, 7).

### 6.1 Page-Table-Walk (PTW) physical accesses

During an active Sv39 translation:
- PTW issues 8-byte naturally aligned physical memory reads to fetch level-2, level-1, or level-0 PTEs.
- **Required**: Each PTW memory read is subjected to PMP checking.
- **Privilege**: PTW PMP checks use **$P_{\text{eff}} = \text{S}$** (implicit supervisor physical access), regardless of current architectural privilege and regardless of `mstatus.MPRV`.
- **Permission**: Requires $R = 1$.

**Failure behavior and microarchitectural integration (deadlock prevention)**:
- PMP checking of the PTE physical address must be resolved **before** an externally visible PTW physical request is accepted or issued to the memory interconnect.
- If PMP denies the PTW read:
  - **Zero external physical requests**: No request is emitted to the platform interconnect (`pd_req_valid_o = 0`, `ram_req_valid_o = 0`). Zero memory write/read strobes pulse and no platform request reaches RAM or CLINT.
  - **Terminal internal fault transition**: The MMU must observe the internal PMP denial immediately and transition directly to the terminal access-fault response state (`I_FAULT_RSP` for instruction fetch, `D_FAULT_RSP` for load, or `STORE_FAULT_REQ` for store).
  - **No deadlock in `PTW_REQ`**: The MMU PTW state machine must **never** remain stalled or waiting in `PTW_REQ` for an external bus handshake (`pd_req_ready_i`) or bus response (`pd_rsp_valid_i`) that will never exist.
  - The eventual RTL decomposition may implement this inside the MMU wrapper or through an explicit local request-result interface, but the terminal non-deadlocking behavior above is mandatory.
  - The access fault raised corresponds to the original triggering instruction:
    - If triggered by an instruction fetch: **instruction access fault** (cause 1);
    - If triggered by a load: **load access fault** (cause 5);
    - If triggered by a store: **store/AMO access fault** (cause 7).
  - The fault is **not** a page fault.
  - **`xtval` authority**: `xtval` receives the **original 64-bit virtual address** that initiated the walk. This is a **deliberate Fursoy project choice inherited from the frozen Sv39 contract** (`sv39-mmu-v1.md` Section 8.1), which is permitted by the RISC-V Privileged ISA, rather than uniquely mandated by the base ISA.

### 6.2 Translated final instruction access

Once virtual translation succeeds:
- Translated physical address $\text{PA} = \text{leaf\_address}$ is checked against PMP.
- **Privilege**: $P_{\text{eff}} = P_{\text{arch}}$ (S or U mode).
- **Permission**: Requires $X = 1$.
- **Failure behavior**:
  - If PMP denies the fetch: no physical instruction bus request is issued (`pi_req_valid_o = 0`).
  - Generates an **instruction access fault** (cause 1).
  - `xtval` is loaded with the **original virtual PC**.

### 6.3 Translated final data access (load / store)

Once virtual translation succeeds:
- Translated physical address is checked against PMP.
- **Privilege**: $P_{\text{eff}} = (P_{\text{arch}} == \text{M} \ \&\& \ \text{MPRV}) \ ? \ \text{MPP} : P_{\text{arch}}$.
- **Permission**: Load requires $R = 1$; Store requires $W = 1$.
- **Failure behavior**:
  - If PMP denies access: no physical data bus request is issued (`pd_req_valid_o = 0`).
  - Generates **load access fault** (cause 5) or **store/AMO access fault** (cause 7).
  - `xtval` is loaded with the **original virtual data address**.
  - A denied store produces **zero** memory or MMIO side effects.

### 6.4 Bare / bypass accesses

In Bare mode (`satp.MODE = Bare`) or M-mode without translation:
- Effective address is directly a physical address.
- Checked against PMP using $P_{\text{eff}}$ ($P_{\text{arch}}$ for fetch; `D_eff` for data).
- Failure generates cause 1, 5, or 7; `xtval` is loaded with the **faulting physical address**.
- No physical request is issued to the memory interconnect.

### 6.5 PMP register modification and `SFENCE.VMA` synchronization

**Architectural requirement**:
Per the ratified RISC-V Privileged ISA (Section 3.7):
When page-based virtual memory is active, software must execute:
$$\text{SFENCE.VMA } x0, x0$$
after modifying PMP registers when required to ensure that subsequent implicit page-table walks observe the updated PMP configuration.

**Fursoy Slice-0 behavior and forward compatibility**:
- In the current Slice-0 implementation, there is no TLB, PTE cache, or speculative address translation.
- PMP CSR writes retire at precise instruction boundaries in the in-order single-issue pipeline.
- Subsequent serialized walks naturally evaluate current PMP register state.
- Nevertheless, software running on Fursoy (e.g. OpenSBI, Linux kernel) must adhere to the architectural `SFENCE.VMA x0, x0` requirement for specification compliance.
- Retaining this requirement guarantees forward compatibility for future packages introducing TLBs or translation caching.

---

## 7. Fault classification, causes, and delegation

### 7.1 Trap cause and value summary

| Access type | Translation mode | PMP failure cause | Destination `xtval` | Destination `xepc` |
|---|---|---|---|---|
| Instruction fetch | Sv39 | Cause 1 (instruction access fault) | Original virtual PC | Faulting virtual PC |
| Instruction fetch | Bare | Cause 1 (instruction access fault) | Physical PC | Faulting physical PC |
| Load | Sv39 | Cause 5 (load access fault) | Original virtual data VA | Faulting virtual PC |
| Load | Bare | Cause 5 (load access fault) | Effective physical address | Faulting physical PC |
| Store | Sv39 | Cause 7 (store/AMO access fault) | Original virtual data VA | Faulting virtual PC |
| Store | Bare | Cause 7 (store/AMO access fault) | Effective physical address | Faulting physical PC |
| PTW PTE read (Fetch) | Sv39 | Cause 1 (instruction access fault) | Original virtual PC | Faulting virtual PC |
| PTW PTE read (Load) | Sv39 | Cause 5 (load access fault) | Original virtual data VA | Faulting virtual PC |
| PTW PTE read (Store) | Sv39 | Cause 7 (store/AMO access fault) | Original virtual data VA | Faulting virtual PC |

**Crucial invariant**: PMP denial **never** generates page fault causes (12, 13, 15). Page faults originate solely from Sv39 translation/PTE violations.

### 7.2 Exception delegation

Trapping and delegation follow the existing processor trap logic:
- If the access originated in **M-mode** (including an M-mode access operating under MPRV):
  - Traps directly to **M-mode** (`mcause`, `mepc`, `mtval`, `mstatus`).
  - Exceptions originating in M-mode are **never delegated** to S-mode.
- If the access originated in **S-mode** or **U-mode**:
  - If `medeleg[cause] == 1`: traps to **S-mode** (`scause`, `sepc`, `stval`, `sstatus`).
  - If `medeleg[cause] == 0`: traps to **M-mode** (`mcause`, `mepc`, `mtval`, `mstatus`).

---

## 8. Access width, alignment, and side-effect suppression

### 8.1 Access widths in Fursoy

- Instruction fetch: exactly 4 bytes, 4-byte naturally aligned.
- LSU data accesses: 1, 2, 4, or 8 bytes naturally aligned. (Natural misalignment is trapped early as cause 4/6 before issuance).
- PTW accesses: exactly 8 bytes, naturally aligned.

### 8.2 Region boundary straddling

Even though accesses are naturally aligned:
- A PMP region boundary configured via TOR or NA4 can fall on a 4-byte boundary.
- An 8-byte load/store at address $A$ where $A \equiv 0 \pmod 8$ may have bytes $[A, A+3]$ in region $i$ and bytes $[A+4, A+7]$ outside region $i$ (or in region $i+1$).
- Per Section 3.2, entry $i$ is the lowest-indexed overlapping entry (`overlaps[i] = 1`), but fails to contain all 8 bytes (`contains[i] = 0`); therefore, the access crosses a boundary and **fails** unconditionally with an access fault, without inspecting any subsequent entry.

### 8.3 Zero physical side effects

**Required**:
- If a store is denied by PMP, the physical store request **must never be asserted** (`pd_req_valid_o = 0`, `ram_req_valid_o = 0`).
- No RAM write enables may pulse, no memory cell may be updated, and no device/CLINT register may observe write intent.
- If a load or fetch is denied by PMP, no physical read is issued.
- If an instruction traps due to PMP:
  - Destination register $rd$ is not updated;
  - Ordinary CSRs are not updated;
  - No commit trace is emitted;
  - `fence_i_valid_o` is not asserted.

---

## 9. CSR privilege behavior and WARL specifications

### 9.1 Privilege gating

All PMP CSRs (`pmpcfg0`, `pmpcfg2`, `pmpaddr0`..`pmpaddr15`) are M-mode CSRs (address bits `11:8 = 4'h3`, minimum privilege M).
- An attempt to read or write any PMP CSR from S-mode or U-mode raises an **illegal-instruction exception** (cause 2).
- Neither read nor write side effects occur on illegal access.

### 9.2 RV64 CSR Read-Modify-Write and write suppression

PMP CSRs adhere to standard Zicsr semantics:
- When a CSR instruction specifies `rs1 = x0` (or `zimm = 0` for immediate forms), write intent is suppressed. A read-only probe does not trigger lock checks or alter configuration state.
- When an individual entry $i$ is locked ($L = 1$):
  - A write targeting `pmpcfg0` or `pmpcfg2` updates any unlocked configuration bytes within that register, while **ignoring changes to locked configuration bytes**.
  - A write targeting `pmpaddr`$i$ has no effect.

### 9.3 WARL rules summary

1. `pmpicfg.A`: Accepts all 4 values (`00`, `01`, `10`, `11`).
2. `pmpicfg.Reserved`: Hardwired to `2'b00`. Nonzero writes are ignored and read back as zero.
3. `pmpicfg.L`: Writable from 0 to 1; once 1, writes attempting to clear it to 0 are ignored.
4. `pmpicfg.W`: WARL. Writable only when $R=1$ (or $R$ is written as 1). Writes of $W=1, R=0$ are legalized to $W=0$ ($W_{\text{effective}} = R_{\text{written}} \mathbin{?} W_{\text{written}} : 1'b0$).
5. `pmpaddr`$i$`[63:54]`: Hardwired to 10'd0. Nonzero writes are ignored.
6. `pmpaddr`$i$`[53:0]`: Fully writable when unlocked.

---

## 10. Platform physical-address assumptions

### 10.1 Full 56-bit architectural address comparison

- PMP matches against the full 56-bit physical address.
- Hardware must **never** truncate physical addresses to 32 bits or to the local RAM memory size before performing PMP matching.
- An address in unmapped address space (e.g. above platform RAM and outside CLINT) that matches an allowed PMP region will pass PMP and subsequently receive a bus/platform access error from the interconnect.
- An address that is rejected by PMP will fault immediately at the core boundary without reaching the platform interconnect.

---

## 11. Reset, lifecycle, and microarchitectural integration

### 11.1 Microarchitectural pipeline placement

PMP checking logic sits directly at the physical request boundary:
1. **Instruction fetch**: Between virtual fetch / translation output and `imem_req_valid_o`.
2. **Data LSU**: Between LSU / translation output and `dmem_req_valid_o`.
3. **PTW**: Between PTW state machine address generation and physical data port arbitration.

```
       +---------------------------------------------+
       |                  Core                       |
       |  Fetch VA                LSU VA             |
       +-----+----------------------+----------------+
             |                      |
             v                      v
       +---------------------------------------------+
       |                  Sv39 MMU                   |
       |  - Canonical check   - Page-table walk      |
       |  - Leaf PTE check    - PTW PA generation    |
       +-----+----------------------+----------------+
             | Physical Fetch PA    | Physical Data PA / PTW PA
             v                      v
       +---------------------------------------------+
       |                  PMP Unit                   |
       |  16 entries: OFF / TOR / NA4 / NAPOT        |
       |  Evaluates P_eff, Permissions, Locks        |
       +-----+----------------------+----------------+
             | Permitted PA         | Permitted PA
             v                      v
       +---------------------------------------------+
       |       Platform Interconnect (RAM / CLINT)   |
       +---------------------------------------------+
```

### 11.2 Request / response handshake contract and deadlock prevention

- PMP checking is evaluated **combinationally** on the generated physical request before it reaches the external bus.
- If PMP denies an access:
  - **Suppression of external request**: Physical request valid to the bus (`pi_req_valid_o` or `pd_req_valid_o`) is **held low** (0). No platform handshake (`ram_req_valid_o`) occurs.
  - **Deadlock-free PTW termination**: For PTW PTE reads, the MMU state machine must immediately observe the local PMP denial and transition directly to the appropriate terminal fault response state (`I_FAULT_RSP`, `D_FAULT_RSP`, or `STORE_FAULT_REQ`) without waiting for external bus ready (`pd_req_ready_i`) or response (`pd_rsp_valid_i`) handshakes. The PTW state machine must never hang in `PTW_REQ`.
  - **Instruction fetch denial**: For translated or Bare instruction fetches, `pi_req_valid_o` is suppressed and an instruction access fault is returned to the core.
  - **Explicit LSU access denial**: For translated or Bare explicit LSU accesses, `pd_req_valid_o` is suppressed and a load/store access fault is returned to the core with zero bus transaction and zero memory/CLINT write enable pulses.
  - **Reset stability**: Stalled physical bus requests must remain stable; asserting reset suppresses all outstanding physical valid signals in compliance with the frozen MMU contract.

---

## 12. Verification contract and test matrix

Before PMP implementation freeze, simulation must cover the following test matrix:

### 12.1 CSR and WARL verification
- Reset values of all 16 configuration bytes (all 0) and address registers (all 0).
- RW capability of `pmpcfg0`, `pmpcfg2`, and `pmpaddr0`..`pmpaddr15`.
- Illegal-instruction traps on `pmpcfg1`, `pmpcfg3`, `pmpcfg4`..`pmpcfg15`, and `pmpaddr16`..`pmpaddr63`.
- S-mode and U-mode attempts to access any PMP CSR generating illegal-instruction trap.
- WARL behavior: `pmpicfg[6:5]` read-only zero; `pmpaddr[63:54]` read-only zero.
- WARL legalization of reserved permission combinations: writing both `R=0, W=1, X=0` (0x02) and `R=0, W=1, X=1` (0x06); asserting that `W` is coerced to 0 upon readback (reading 0x00 and 0x04 respectively) and that write-only access is never permitted.
- Lock bit behavior: $L=0 \to 1$ transition; attempt to clear $L=1 \to 0$ ignored.
- Locked `pmpaddr` write suppression.
- Hardware reset clearing locked entries: assert that hardware reset (`rst_i = 1`) clears all $L$ bits to 0 and restores writeability of `pmpcfg` and `pmpaddr`.
- Preceding TOR entry lock edge cases:
  - Entry 0 ($i=0$) with TOR and $L=1$: verify no out-of-bounds register access or array overflow in RTL.
  - Entry $i$ with TOR and $L=1$: verify writes to `pmpaddr_{i-1}` are ignored, but verify `pmp(i-1)cfg` remains writable if entry $i-1$ has $L=0$.
  - Chained TOR locks: entries $i$ and $i-1$ both locked with TOR ($L=1$); verify both `pmpaddr_{i-1}` and `pmpaddr_{i-2}` are locked against writes.
  - Entry $i$ locked with NAPOT, NA4, or OFF: verify `pmpaddr_{i-1}` is NOT locked and remains writable.

### 12.2 Matching modes, predicates, and priority
- OFF mode: entry ignored (`overlaps = 0`, `contains = 0`).
- TOR mode: single entry ($i=0$), multi-entry ($i > 0$), lower $\ge$ upper null region.
- NA4 mode: exact 4-byte matching.
- NAPOT mode: 8 B, 16 B, 64 B, 4 KiB, 2 MiB, 1 GiB, full 56-bit address space via $k=53$ and $k=54$.
- First-match priority: higher-priority entry denying access overriding lower-priority entry granting access.
- First-match priority: higher-priority entry granting access overriding lower-priority entry denying access.
- Strict boundary overlap and adjacent-region tests:
  - 8-byte access straddling the upper boundary of an NA4 region (4B inside, 4B outside) -> immediate access fault.
  - 8-byte access straddling the lower/upper boundary of a TOR region -> immediate access fault.
  - 8-byte access spanning the boundary between two adjacent PMP entries (entry 0 covers low half, entry 1 covers high half): verify immediate access fault, proving entry 0's partial overlap blocks entry 1 from matching.
  - Boundary-crossing denial applies unconditionally in M-mode even when $L=0$.

### 12.3 Privilege and permissions
- M-mode bypass of unlocked ($L=0$) matching entry.
- M-mode enforcement of locked ($L=1$) matching entry.
- M-mode default allow when no entry matches.
- S-mode and U-mode enforcement on matching entry ($L=0$ and $L=1$).
- S-mode and U-mode default deny when no entry matches.
- Permission enforcement: fetch without $X$, load without $R$, store without $W$.
- Comprehensive MPRV matrix:
  - `MPRV=1, MPP=U`: U-mode rules enforced (default deny, permissions checked).
  - `MPRV=1, MPP=S`: S-mode rules enforced (default deny, permissions checked).
  - `MPRV=1, MPP=M`: M-mode rules enforced (unlocked bypass, default allow).
  - `MPRV=0`: explicit data accesses in M-mode use M-mode rules regardless of MPP value.
- MPRV fetch: verifying instruction fetch remains M-mode privilege despite `MPRV=1`.

### 12.4 MMU, PTW, and Bare interaction
- Bare mode: physical fetch, load, and store PMP faults reporting physical address in `xtval`.
- Sv39 final translated access: PMP faults reporting original full virtual address in `xtval`.
- Sv39 PTW PTE read PMP denial across all three walk levels:
  - Level 2 (root table read denied): terminates walk immediately with zero bus read, raises access fault (cause 1/5/7) reporting original VA in `xtval`.
  - Level 1 (intermediate table read denied): terminates walk immediately, zero bus read, correct cause, original VA in `xtval`.
  - Level 0 (leaf table read denied): terminates walk immediately, zero bus read, correct cause, original VA in `xtval`.
  - Verifying MMU PTW state machine transitions directly to fault response without deadlocking in `PTW_REQ`.
- PMP denial vs platform/interconnect access error precedence:
  - Access to unmapped physical address (outside RAM and CLINT) when denied by PMP: assert immediate PMP access fault at core boundary with `pd_req_valid_o = 0` (zero bus request), ensuring platform decode is never stimulated.
  - Same unmapped address when permitted by PMP: request issued to SoC interconnect, SoC interconnect returns error response -> core receives bus access fault.
- PMP reconfiguration followed by `SFENCE.VMA x0, x0`:
  - End-to-end scenario: S-mode PTW denied under initial default PMP -> trap to M-mode -> M-mode configures PMP entry granting S-mode read to page tables -> M-mode executes `SFENCE.VMA x0, x0` -> `mret`/`sret` -> subsequent PTW succeeds cleanly.
- MXR separation: verifying MXR=1 does not bypass a PMP entry with $R=0$.
- Zero physical side effects: verifying physical RAM content is completely unaltered on denied stores.
- Delegation: verifying PMP access faults are correctly routed to S-mode when `medeleg` is set, and to M-mode when clear or originating from M-mode.

### 12.5 High-value formal properties
1. **Safety**: No physical write strobe (`ram_req_store_o && ram_req_valid_o`) is ever asserted for an address and width not fully permitted by PMP.
2. **First-match exclusivity**: PMP decision is determined solely by the lowest-indexed overlapping entry, or default if no overlap exists.
3. **Lock immutability**: For any entry $i$, if $L = 1$, neither `pmpicfg` nor `pmpaddr_i` may change value while reset is low.
4. **PTW classification**: Any PMP failure occurring during a page table walk produces cause 1, 5, or 7 with `xtval` equal to the input VA.

---

## 13. Review gates and deliberate project decisions

The following project decisions are submitted for independent architecture review:
1. **16 entries**: Balances Linux/OpenSBI capability with Slice-0 gate complexity.
2. **$G = 0$ (4-byte granularity)**: Implements complete NA4 and NAPOT without restriction.
3. **Strict partial-match denial via `overlaps` and `contains` predicates**: Any access spanning a PMP boundary fails unconditionally, without inspecting subsequent entries.
4. **Base PMP WARL legalization ($W_{\text{effective}} = R_{\text{written}} \mathbin{?} W_{\text{written}} : 1'b0$)**: Reserved $W=1, R=0$ combinations are deterministically coerced to $W=0$.
5. **PTW S-mode physical access model with deadlock-free terminal fault transition**: PTW memory reads require S-mode PMP read permission, terminating immediately on denial without bus transactions, reporting original virtual address in `xtval` (inherited from frozen Sv39 contract).
6. **Preceding TOR entry lock enforcement**: Writes to `pmpaddr_{i-1}` are suppressed when entry $i$ is locked with $A=\text{TOR}$.
7. **Architectural `SFENCE.VMA x0, x0` synchronization**: Required in software after PMP modifications under active virtual memory.
