# Sv39/MMU architectural contract — accepted and frozen v1

Status: independently reviewed, **ACCEPT AND FREEZE**, and implemented by the
first correctness-first Sv39 RTL package. This contract remains authoritative;
future TLB, PMP, or Linux-enablement work must preserve it or undergo a separate
architecture review. The reviewed M/S/U Bare and supervisor-interrupt behavior
in `s-mode-bare-v1.md` remains the compatibility baseline.

## 1. Authority, terminology, and scope

Normative reference: RISC-V ISA manual release **20260120**, Machine-Level ISA
**1.13** and Supervisor-Level ISA **1.13**:

- [Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- [Supervisor-Level ISA, including satp, SFENCE.VMA, and Sv39](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- [CSR addressing conventions](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html)

Architectural descriptions below adapt these RISC-V International
specifications, licensed [CC BY 4.0](https://github.com/riscv/riscv-isa-manual/blob/main/LICENSE).
The classifications used throughout are:

- **Required** — ratified-spec behavior. RTL has no project freedom except a
  choice expressly allowed by the specification.
- **Choice** — a Fursoy decision among architecturally permitted behaviors.
- **Simplification** — a correctness-preserving first-version restriction that
  must not be mistaken for the intended server-class endpoint.

This package adds RV64 Sv39 address translation for instruction fetches and the
existing RV64I loads/stores. It includes page-fault generation, a hardware
page-table walker (PTW), the required status/CSR changes, and `SFENCE.VMA`.
It preserves the existing in-order, single-issue, one-active-LSU-operation,
precise-trap model.

Explicitly deferred: caches, PMP entries, PBMT, NAPOT translations, Sstc, the A
integer/AMO extension, LR/SC, hardware A/D updates, TLBs, multiple or speculative
walks, page-walk prefetching, PLIC, multihart shootdown, full SBI/Linux boot,
Sv48/Sv57, H-stage translation, and performance optimization. The lack of PMP
and a complete platform is not a claim of process isolation or Linux readiness.

## 2. `satp` and status changes

### 2.1 `satp`

Required RV64 layout at CSR 0x180: MODE[63:60], ASID[59:44], PPN[43:0].
Access is legal from M; legal from S only when `mstatus.TVM=0`; illegal from U.
An S-mode read or write while TVM=1 raises illegal instruction (cause 2). M-mode
access ignores TVM. Normal CSR write-intent and side-effect-suppression rules
remain in force.

Choice: supported MODE values are only Bare=0 and Sv39=8. Sv48, Sv57, and all
reserved/custom values are unsupported. A write carrying an unsupported MODE
has no effect on any `satp` field, as required. For MODE=Bare, the deterministic
WARL result is all zero, including PPN and ASID. For MODE=Sv39, MODE and all 44
PPN bits are stored; ASID is forced to zero.

Simplification: ASIDLEN=0. Every read reports ASID=0, nonzero written ASID bits
are ignored, and all translations belong to the single address space. This is
discoverable by the standard write-ones/read-back procedure. The architectural
Sv39 physical address is 56 bits (`PPN[43:0] || page_offset[11:0]`) and is
zero-extended on the existing 64-bit physical ports. No high PPN bit may be
silently truncated or wrapped; an unmapped resulting physical address fails via
the platform's physical access-error response.

Required: Bare means no page translation. Sv39 becomes active when `satp.MODE=8`
and the effective privilege of the access is S or U. A committed MODE or ASID
change affects subsequently begun translations immediately. A `satp` write does
not itself order page-table stores and does not architecturally imply a
translation-cache flush.

Choice/simplification: v1 has no translation cache, so a committed `satp` write
has no cached entries to invalidate. The single-issue commit boundary guarantees
that no old walk is active when a `satp` write commits; the next fetch uses the
new value. Software still uses `SFENCE.VMA` where the specification requires
page-table-store ordering. `FENCE.I` does not substitute for `SFENCE.VMA`, and
`SFENCE.VMA` does not substitute for `FENCE.I` when instruction bytes change.

### 2.2 `mstatus` / `sstatus`

Required changes from the frozen Bare stage:

- SUM[18] becomes RW. It affects S-effective loads/stores to U pages and remains
  ineffective in Bare. It never permits S instruction fetch from a U page.
- MXR[19] becomes RW. For translated loads, MXR=1 permits R=1 or X=1; it has no
  effect on stores or instruction fetch and is ineffective in Bare.
- TVM[20] becomes an M-mode RW control. It intercepts S-mode `satp` accesses and
  `SFENCE.VMA`; it never affects M-mode execution of those operations.

Choice: all three reset zero. The resulting `sstatus` nonzero-capable read mask
is `0x00000003000c0122`; its write mask is `0x00000000000c0122`. The proposed
`mstatus` write mask becomes `0x00000000007e19aa`, retaining all frozen WARL
rules for MPP, fixed XLEN/endian fields, TW, TSR, and MPRV. Alias writes preserve
hidden M fields. SUM/MXR changes affect later permission checks immediately and
require no `SFENCE.VMA`.

Choice: `medeleg` gains writable page-fault bits 12, 13, and 15. Its new writable
mask is `0x000000000000b3ff`; all frozen delegation behavior for causes 0..9 is
unchanged. This is the only delegation change in this package.

The environment-configuration stubs also require an explicit transition:

- Required: `menvcfg.FIOM` (0x30a bit 0) and `senvcfg.FIOM` (0x10a bit 0)
  become RW rather than remaining all-zero stubs now that `satp.MODE` is not
  read-only Bare. `menvcfg.FIOM` applies to modes below M and `senvcfg.FIOM`
  applies to U; if either applicable control is one, the standard I/O-fence
  implication includes memory. Both reset zero. The fully serialized v1 memory
  path already satisfies either ordering, but CSR storage/readback is required.
- Choice/simplification: Svpbmt and Svadu are absent, so `menvcfg.PBMTE` and
  `menvcfg.ADUE` remain read-only zero. ADUE=0 selects the Svade behavior in
  section 7. All other unsupported environment-extension fields remain zero.

## 3. Effective privilege and translation activation

Let `P` be current architectural privilege. Define the effective privilege of
an explicit data access as:

`D_eff = (P == M && mstatus.MPRV == 1) ? mstatus.MPP : P`.

MPRV never affects instruction fetch, CSR authorization, trap origin, interrupt
routing, or the current privilege state. The translation/permission decision is:

| Access | Condition | Address treatment and PTE privilege check |
|---|---|---|
| Instruction fetch, P=M | Always | Bypass translation; PC is physical; MPRV ignored |
| Instruction fetch, P=S/U | MODE=Bare | Bypass translation; PC is physical |
| Instruction fetch, P=S/U | MODE=Sv39 | Translate PC; check PTE using current S/U privilege |
| Load/store, D_eff=M | Always | Bypass translation; effective address is physical |
| Load/store, D_eff=S/U | MODE=Bare | Bypass translation; effective address is physical |
| Load/store, D_eff=S/U | MODE=Sv39 | Translate effective address; check PTE using D_eff |

Required: an M-mode load/store with MPRV=1 and MPP=S/U is therefore translated
under Sv39. SUM applies when `D_eff=S`, including MPRV+MPP=S; MXR applies to every
translated load. An MPRV-generated exception still originates in M and can never
be delegated downward. Page-table reads are implicit physical S-mode accesses,
use fixed little-endian SBE=0, are never recursively translated, and would be
subject to PMP/PMA checks; v1 implements no PMP entries but does enforce the
physical-memory placement policy in section 10.

## 4. Sv39 virtual and physical address formation

Required: a translated 64-bit virtual address is canonical exactly when bits
63:39 are all copies of bit 38. A noncanonical translated instruction, load, or
store address raises the corresponding instruction/load/store page fault
(cause 12/13/15). The destination xTVAL is the original full 64-bit virtual
address. No PTW request or final physical access is issued.

Required decomposition:

- page offset = VA[11:0]
- VPN[0] = VA[20:12], VPN[1] = VA[29:21], VPN[2] = VA[38:30]
- PTE PPN[0] = PTE[18:10] (9 bits)
- PTE PPN[1] = PTE[27:19] (9 bits)
- PTE PPN[2] = PTE[53:28] (26 bits)

Each page table contains 512 naturally aligned 8-byte PTEs in one naturally
aligned 4 KiB physical page. The root physical address is `satp.PPN << 12`.
At level `i`, the PTE address is `table_base + VPN[i]*8`. Address arithmetic is
performed at full 56-bit Sv39 physical width and never wraps through a narrower
implementation address.

## 5. PTE format and walk algorithm

Required Sv39 PTE fields:

| Bits | Field | v1 treatment |
|---|---|---|
| 0 | V | Valid |
| 1,2,3 | R,W,X | Read, write, execute permissions and leaf selection |
| 4 | U | User-page permission |
| 5 | G | Global mapping; accepted, propagated through non-leaves |
| 6,7 | A,D | Accessed and dirty; Svade policy in section 7 |
| 9:8 | RSW | Ignored and preserved by software; never interpreted by hardware |
| 53:10 | PPN | Next table or leaf physical page number |
| 63 | N | Must be zero because Svnapot is absent |
| 62:61 | PBMT | Must be zero because Svpbmt is absent |
| 60:54 | Reserved | Must be zero |

The non-speculative walker starts at level 2 and performs this sequence:

1. Reject a noncanonical VA with the original access-type page fault.
2. Read exactly one naturally aligned 64-bit PTE from the computed physical
   address. A physical/PMA/bus failure here becomes the original access-type
   access fault, not a page fault.
3. Raise the original access-type page fault if V=0, R=0/W=1, or any unsupported
   reserved/N/PBMT encoding is nonzero.
4. If R=0 and X=0, treat the PTE as a pointer. For a pointer PTE, U, A, and D
   must all be zero; otherwise raise a page fault. G may be set and propagates
   global status to all leaves below. If already at level 0, raise a page fault;
   otherwise set the table base to `PTE.PPN << 12`, decrement the level, and
   repeat from step 2.
5. Otherwise the PTE is a leaf. Check superpage alignment, U/S privilege,
   R/W/X permission, and A/D in that order. Any failure is the original
   access-type page fault.
6. Form the physical address and issue the original access. A final physical
   response/request error remains the original access-type access fault.

Required leaf sizes and PA construction:

| Leaf level | Page size | Alignment check | Final PA page-number fields |
|---|---:|---|---|
| 0 | 4 KiB | none beyond PTE/page alignment | `{PTE.PPN[2], PTE.PPN[1], PTE.PPN[0]}` |
| 1 | 2 MiB | PTE.PPN[0] must be zero | `{PTE.PPN[2], PTE.PPN[1], VPN[0]}` |
| 2 | 1 GiB | PTE.PPN[1:0] must be zero | `{PTE.PPN[2], VPN[1], VPN[0]}` |

The original VA[11:0] is appended in every case. A misaligned superpage raises
a page fault; it must not be rounded, truncated, or treated as a pointer. The
leaf's containing level inherently establishes virtual superpage alignment.

Simplification: current instruction accesses are aligned 4 bytes and current
data accesses are naturally aligned powers of two no wider than 8 bytes. They
therefore cannot cross a 4 KiB page boundary. V1 translates exactly one page per
architectural access. Any later support for misaligned splitting, wider accesses,
or vector accesses must separately define partial-fault and multi-page behavior.

## 6. Permission checks

Permission checks occur only after a valid aligned leaf is found and before any
final physical access. They are independent of physical access permission/error
checks. Let `E` be current privilege for fetch or `D_eff` for data.

Required privilege/U check:

| E / access | PTE.U=0 | PTE.U=1 |
|---|---|---|
| U fetch/load/store | page fault | continue |
| S fetch | continue | page fault regardless of SUM |
| S load/store, SUM=0 | continue | page fault |
| S load/store, SUM=1 | continue | continue |

Required R/W/X check after the U check:

- instruction fetch succeeds only with X=1;
- load succeeds with R=1, or with MXR=1 and X=1;
- store succeeds only with W=1;
- R=0/W=1 was already rejected as a reserved PTE encoding.

MXR never turns readable data into executable data, and SUM never affects
instruction fetch. The current core has no AMO/LR/SC instruction. When AMOs are
introduced later they must use write permission and report store/AMO page fault
(cause 15); this package does not silently add them.

## 7. Accessed/dirty-bit policy

Simplification and explicit architectural choice: v1 implements the Svade
fault-on-clear scheme and performs no hardware PTE writes.

- Any leaf access with A=0 raises the original access-type page fault.
- A store additionally requires D=1; D=0 raises store page fault.
- Loads and fetches do not require D=1.
- Hardware never sets or clears A or D.

This policy avoids inventing an atomic read-modify-write facility on the current
memory interface and keeps the PTW read-only. Software must install A/D=1 or
handle the page fault and update the PTE explicitly. The eventual advertised ISA
string/platform description must declare the Svade behavior; this document does
not implement ISA discovery or firmware. A later switch to hardware A/D updates
is a separate architecture change requiring atomic whole-PTE compare/update,
ordering before the triggering memory access, exact D updates, PMA support, and
multihart analysis.

## 8. Fault classification, priority, and precision

### 8.1 Causes and trap data

| Original operation | Translation/PTE/permission/A-D failure | PTW/final physical failure |
|---|---|---|
| Instruction fetch | cause 12, instruction page fault | cause 1, instruction access fault |
| Load | cause 13, load page fault | cause 5, load access fault |
| Store | cause 15, store/AMO page fault | cause 7, store/AMO access fault |

Choice: xTVAL is always informative. For every page fault and for any access
fault while translation is active—including a PTW read failure—it is the
original full virtual address of the instruction or explicit data access, never
the PTE physical address or translated physical address. In Bare/bypass mode,
existing access faults continue to report the effective physical address.
xEPC is the faulting instruction's virtual PC.

The existing delegation mechanism is reused without modification: an exception
routes to S exactly when architectural origin is not M and `medeleg[cause]=1`;
otherwise it routes to M. Page-fault delegation bits are 12/13/15. Causes are
not renumbered and there is no MMU-local trap bank. MPRV changes data translation
but not architectural origin, so M-origin page/access faults always enter M.

### 8.2 Priority

Required/project-selected priority, highest first for relevant implemented
events:

1. For an instruction fetch, the first page fault or access fault encountered
   during translation; then final physical instruction access fault. Only after
   successful fetch can illegal instruction, ECALL, EBREAK, or execution faults
   from that instruction be known. Existing taken-control-flow misalignment is
   raised by the branch/jump instruction without translating its bad target.
2. For an explicit data access, retain the frozen project choice that natural
   address misalignment (cause 4/6) is checked before translation, page/access
   checks, or a physical request. Then use the first translation page/access
   fault encountered; then a final physical access fault.
3. A known synchronous exception for the active instruction wins over an
   eligible interrupt. A legal nonfaulting instruction may be interrupted only
   at the existing precise instruction boundary.

Choice preserving current timing: an instruction walk may be preempted by an
eligible interrupt before a translation fault is known. Its accepted PTW load
must then be drained/discarded and cannot later create a trap. Once a decoded LSU
instruction has issued into data translation, the walk and final physical access
remain noninterruptible; a resulting synchronous fault wins, and a pending
interrupt is reconsidered at the next boundary.

Every failed translation has exactly one terminal architectural outcome. It
must not issue the final fetch/load/store, write a destination register, update
an ordinary CSR, publish a commit/FENCE.I event, or partially expose store data.
Trap-bank/status updates are the only architectural changes. PTW reads and
independent timer/pending-input changes are not retirement side effects.

## 9. `SFENCE.VMA`

Required legality at this stage: legal in M; legal in S when TVM=0; illegal in S
when TVM=1; illegal in U. M execution ignores TVM. An illegal instance raises
cause 2 and has no fence/invalidation effect. Its rs1 and rs2 are source-register
identifiers; their runtime values select virtual-address and ASID scope under the
architectural definition. A noncanonical rs1 value never causes an exception.

Required architectural scope:

- rs1=x0, rs2=x0: all addresses and address spaces, including global mappings;
- rs1=x0, rs2!=x0: named ASID, excluding global mappings;
- rs1!=x0, rs2=x0: named virtual mapping in all address spaces, including global;
- rs1!=x0, rs2!=x0: named virtual mapping and ASID, excluding global mappings.

It orders earlier page-table stores already visible to this hart before matching
implicit page-table accesses of later instructions and invalidates matching
local address-translation-cache state. It is not a global memory fence and is
local to this hart.

Simplification: with ASIDLEN=0 and no TLB/PTE cache, every legal `SFENCE.VMA`
over-fences as a global operation regardless of rs1/rs2 values. Over-fencing is
permitted. It waits for any prior explicit store to reach the current platform's
local visibility/completion point, ensures there is no older PTW request or stale
response, clears all transient walk state, and only then retires. Subsequent
fetch/data walks begin afterward. Invalid rs1 and ignored high rs2 bits do not
trap. The current store request handshake is defined as the local visibility
point; if a future buffered memory system accepts stores before visibility, it
must add a completion/fence mechanism before reusing this rule.

An interrupt may preempt an uncommitted `SFENCE.VMA`; in that case no fence event
occurs and the instruction is refetched after xRET. A committed fence executes
exactly once. Changing `satp`, SUM, or MXR does not require the instruction, but
software must use it to synchronize relevant page-table-memory updates.

## 10. Correctness-first translation microarchitecture

Choice/simplification: v1 has no I-TLB, D-TLB, shared TLB, PTE cache, negative
cache, walk cache, or speculative translation. Every active translated access
walks memory. There is one shared PTW and at most one accepted translation/walk
at a time. The owner record contains at least:

- client kind: instruction, load, or store;
- original 64-bit VA and faulting virtual PC;
- architectural origin privilege and effective access privilege;
- captured `satp` MODE/PPN, SUM, and MXR values;
- level, current table base/PTE address, and accumulated G state;
- explicit-access size/data/destination metadata needed after translation;
- response lifecycle state, including discard ownership.

These values are captured when the translation is accepted and remain stable
through backpressure. Later CSR or privilege changes cannot reinterpret a walk.
There is no legitimate simultaneous I and D translation in the current core:
fetch is stopped during an LSU operation. The arbiter nevertheless gives an
existing data owner priority; otherwise data wins a simultaneous new request and
instruction waits. Assertions must make accidental dual acceptance impossible.

PTW arbitration and lifecycle:

1. Canonicality and data alignment are checked before allocating a walk.
2. The owner retains each physical PTE-read request until request handshake and
   accepts exactly one response before advancing.
3. No second physical PTW load or final access is issued until the first response
   has been consumed and validated.
4. An instruction redirect/interrupt cancels its architectural translation. If
   no PTE request was accepted, it is dropped immediately. If a response is owed,
   the PTW enters DISCARD, accepts that response without interpreting it, and
   only then permits the redirected fetch to allocate a new walk.
5. An issued data translation is not redirect-cancelled; trap/interrupt entry
   waits for its terminal success/fault under the existing LSU rule.
6. Reset clears architectural owner/state and translation state. Because ports
   are untagged, the physical response producer must cancel pre-reset outstanding
   instruction and RAM/PTW loads as required by the existing fetch/LSU contracts.
   The integration also drains any response visible during reset/no-owner, but
   that defensive drain cannot distinguish a response that reappears after a new
   post-reset request; producer cancellation remains mandatory.
7. A committed `satp` write or `SFENCE.VMA` occurs only with no active old walk.
   `SFENCE.VMA` clears transient state; `satp` supplies the next walk's snapshot.

The no-TLB choice makes stale-translation invalidation structurally simple but
is intentionally slow. Adding TLBs later must preserve these request, fault,
flush, and ownership semantics and is a separately reviewed optimization.

## 11. PTW and physical memory/SoC interface contract

Required: PTE reads are aligned 8-byte physical loads and return one indivisible
64-bit little-endian PTE. Two 32-bit reads are not allowed. Under the Svade
choice the PTW never stores. A PTE read may be delayed/backpressured just like a
normal RAM load; request fields stay stable while stalled, and response valid,
data, and error stay stable until accepted. Every accepted PTE read completes
through one response, including errors. A same-cycle response is backpressured
until registered owner state can identify it, matching the current RAM rule.

Choice: page tables may reside only in ordinary, idempotent RAM that supports
aligned 64-bit reads. They may not reside in CLINT or another MMIO window. A PTW
physical address selecting CLINT/MMIO, or receiving an unmapped/RAM error, is a
PMA-like PTW access failure and becomes an access fault of the original
instruction/load/store. The PTW never performs CLINT side effects. Final
translated explicit accesses may target RAM or CLINT normally; PTE permissions
are checked before SoC decode, and current CLINT width/alignment/error rules then
apply as physical access rules.

The current external payload widths and valid/ready rules are sufficient for a
serialized PTW, so transaction IDs are not required in v1. The current internal
ownership topology is not sufficient unchanged. Implementation will require a
controlled extension that:

- translates core virtual fetch/data addresses before existing physical ports;
- arbitrates PTW reads with final explicit data requests on the physical data
  path and records PTW versus explicit response ownership;
- marks PTW requests so platform decode rejects MMIO page-table placement;
- returns translation-fault class plus original VA/PC to core trap arbitration,
  rather than mislabeling every MMU failure as the existing bus access fault;
- retains original VA metadata while only physical addresses reach RAM/CLINT;
- preserves the existing request-error-at-store-handshake and
  response-completed-load contracts for final explicit accesses.

Recommended placement is an MMU wrapper between core virtual clients and the
current physical fetch/data platform ports, plus a data-side physical arbiter
with owners `{NONE, LSU_RAM, LSU_CLINT, PTW_RAM}`. Stores create no response
owner. The exact module boundary is
not architectural, but the ownership and fault metadata are. Accepted untagged
responses may be drained but never reassigned to a different owner.

## 12. Compatibility-risk audit

The implementation must deliberately replace these frozen Bare assumptions:

| Current assumption | Sv39-stage requirement |
|---|---|
| `satp` always reads zero; every write stays Bare | MODE 0/8 WARL, 44-bit PPN, ASIDLEN=0 |
| SUM/MXR/TVM are RO0 | They become RW with the behavior in section 2 |
| `menvcfg`/`senvcfg` are all-zero stubs | Add RW FIOM; keep absent-extension PBMTE/ADUE and other fields zero |
| `SFENCE.VMA` is always illegal | Privilege/TVM-gated, commit-qualified global over-fence |
| `medeleg` mask is 0x3ff | Add causes 12/13/15: mask 0xb3ff |
| Fetch address and fetch-fault tval are the same physical value | Preserve virtual PC; send translated PA; report original VA |
| LSU effective address is also the SoC physical address | Capture VA/effective privilege, translate, then issue PA |
| Only causes 1/5/7 represent memory failures | Add page faults 12/13/15 and distinguish PTW physical failures |
| Misalignment is followed directly by physical access | Keep early misalignment, then canonicality/walk/permission |
| SoC data owner is only RAM or CLINT | Add serialized PTW ownership/arbitration and MMIO rejection |
| Instruction producer reset cancellation is sufficient | Apply cancellation to PTW/RAM loads too; retain discard state for redirects |
| No page-table-store ordering event exists | Legal `SFENCE.VMA` coordinates I/D implicit reads with prior stores |

Additional risks: using translated PA as xTVAL would be architecturally wrong;
allowing CSR/status changes to alter an in-flight walk would violate precision;
letting PTW reads reach CLINT could create hidden device side effects; treating a
PTW bus error as a page fault would misclassify the exception; and allowing a
discarded instruction walk to fill state or trap would break redirect ownership.
No address may be truncated to the small current RAM image.

## 13. Proposed RTL decomposition (not authorization to implement)

1. **CSR/status extension:** real `satp`, RW SUM/MXR/TVM, and expanded medeleg.
2. **Translation request front ends:** retain virtual fetch PC and LSU effective
   address plus privilege/access metadata; bypass M/Bare accesses.
3. **Sv39 PTW:** canonicality, three-level PTE parser, superpage assembly,
   permissions, Svade A/D checks, and typed fault result.
4. **Physical data arbiter/owner tracker:** serialize PTW reads and final LSU
   traffic, keep CLINT decode explicit, and drain cancelled responses.
5. **Fetch/LSU completion adapters:** deliver physical results while preserving
   original VA/PC for precise commit/fault behavior.
6. **Fence controller:** commit-qualified `SFENCE.VMA`, global transient-state
   invalidation, and ordering against prior stores/subsequent walks.
7. **Assertions/trace hooks:** owner exclusivity, stable stalled fields, one
   response per accepted load, no final request after translation failure, and
   virtual-address fault metadata.

These may be combined for Slice-0 RTL, but their logical responsibilities and
verification observation points must remain separable. No TLB module belongs to
v1.

## 14. Verification contract

No tests are added by this document task. Before implementation freeze, directed
simulation must cover at least:

### 14.1 Architectural behavior

- all existing Bare M/S/U, interrupt, fetch, LSU, CLINT, and bare-metal tests
  with MODE=0 and the new writable status fields reset zero;
- `satp` reset, Bare coercion, Sv39 PPN readback, ASIDLEN=0, unsupported-MODE
  whole-write suppression, M/S/TVM/U access legality, and commit suppression;
- SUM/MXR/TVM and both FIOM fields' reset, privilege, alias, WARL/readback, and
  side-effect suppression behavior; PBMTE/ADUE read-only-zero behavior;
- valid 4 KiB mappings requiring level-2, level-1, and level-0 PTE reads;
- valid 2 MiB and 1 GiB leaves, PA construction at offset/VPN boundaries, and
  malformed superpages with each forbidden low PPN bit;
- low and high canonical ranges plus both noncanonical boundaries for fetch,
  load, and store, with exact cause/xEPC/xTVAL;
- V=0, R=0/W=1, reserved 63:54 bits, pointer U/A/D misuse, level-0 pointer, and
  malformed leaf cases at every reachable level;
- fetch X, load R, load MXR+X, store W, execute-only, read-only, U=0/U=1,
  S fetch from U page, S SUM=0/1 data, and U accesses;
- M physical bypass, MPRV=0, MPRV+MPP=M bypass, and MPRV+MPP=S/U translated
  loads/stores with SUM/MXR and M-origin nondelegated faults;
- A=0 for all access types, D=0 for store, D=0 for load/fetch success, and proof
  that the PTW emits no PTE writes;
- instruction/load/store page faults delegated and nondelegated through the
  existing trap banks; page-fault medeleg alias/write behavior;
- PTW bus error at every level, disallowed PTW CLINT/MMIO address, and final
  physical access errors, all with access-fault cause and original virtual tval;
- early data misalignment versus would-be page/access fault; fetch translation
  fault before decode; eligible interrupt versus known translation fault;
- faulting load destination preservation, faulting store non-visibility, no
  commit/FENCE.I/CSR side effect, and exact faulting virtual instruction label.

### 14.2 Ordering and lifecycle

- every legal `SFENCE.VMA` rs1/rs2 encoding, M/S/U and TVM legality,
  noncanonical rs1 no-trap behavior, commit qualification, and all-forms global
  over-fence implementation;
- page-table store followed by `SFENCE.VMA` followed by I-side and D-side walks
  observing the new PTE; `satp` Bare↔Sv39 and PPN transitions;
- ASID write/read behavior and rs2 high-bit ignoring for ASIDLEN=0;
- delayed/backpressured PTE responses, stable requests/responses, same-cycle
  response, PTE error data nonzero, and alternating PTW/final/CLINT ownership;
- interrupt/redirect during each walk level before and after request acceptance,
  response discard before redirected fetch, and no stale trap/fill;
- interrupt pending throughout a data walk/final access, synchronous-fault
  priority, then interrupt delivery at the next precise boundary;
- reset at every PTW state, producer cancellation, defensive stale drain, and no
  pre-reset response attached to a post-reset owner.

### 14.3 High-value formal properties

- At most one translation/physical-response owner is live; an accepted response
  is consumed only by that owner and exactly once.
- A final physical access implies canonical VA, a valid leaf, successful
  alignment/U/RWX/A-D checks, and PA equal to the Sv39 composition formula.
- Any terminal translation fault implies no final request, no architectural
  destination/store/ordinary-CSR effect, and cause/tval matching original type/VA.
- No PTW request targets MMIO and no PTW store is ever generated in Svade v1.
- Stalled request fields and unaccepted response fields are stable.
- Redirected/reset-generation instruction walks cannot commit, trap, or satisfy
  a later fetch; data walks remain noninterruptible once accepted.
- A committed `SFENCE.VMA` separates all older relevant store handshakes from all
  newer implicit PTE reads, and a preempted fence has no effect.
- Bare bypass is observationally equivalent to the frozen physical-address path.

Formal proofs must state environment assumptions: eventual response for every
accepted load, response stability until acceptance, store-handshake visibility,
and reset cancellation on untagged producers. Bounded proof without these
assumptions is not a liveness claim.

## 15. Review gates and unresolved questions

No ratified-Sv39 semantic question is knowingly left unresolved in this draft.
Independent review must nevertheless approve these project choices before RTL:

1. Svade fault-on-clear A/D behavior instead of hardware A/D updates.
2. ASIDLEN=0 and global over-fencing for every `SFENCE.VMA`.
3. No translation caches and one non-speculative serialized walker.
4. All 44 PPN bits accepted, with platform errors rather than truncation for
   unimplemented physical regions.
5. Page tables restricted to 64-bit-readable idempotent RAM; PTW MMIO rejected.
6. Existing store request handshake as the local visibility point required by
   the fence rule, plus reset cancellation as an external producer obligation.

Two platform/completeness items remain deliberately outside this package, not
ambiguous RTL behavior: the eventual ISA/Svade discovery string and SBI/Linux
software contract, and a later physical protection/PMA/PMP policy suitable for
untrusted lower modes. If either is pulled into the first implementation, this
contract must be revised and reviewed before code begins.
