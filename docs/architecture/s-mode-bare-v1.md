# S-mode Bare architectural contract — v1

Status: Reviewed, accepted, and frozen architectural contract. Implemented in
Slice-0 core RTL and verified across unit, integrated, and bare-metal regression
suites. This document defines the architectural specification for S-mode Bare
privilege, exception/interrupt delegation, trap CSR banks, and privileged instructions,
establishing the baseline prior to a future Sv39 translation milestone.

## Authority and scope

Normative reference: RISC-V ISA manual release **20260120**, Machine-Level ISA
**1.13**, Supervisor-Level ISA **1.13**, and Zicsr **2.0**. This reuses the release
already referenced by `docs/requirements/slice-0.md`.

- [M: Machine-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html)
- [S: Supervisor-Level ISA](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html)
- [C: CSR addressing and access conventions](https://docs.riscv.org/reference/isa/v20260120/priv/priv-csrs.html)
- [Z: Zicsr instructions](https://docs.riscv.org/reference/isa/v20260120/unpriv/zicsr.html)

Architectural descriptions below adapt these RISC-V International specifications,
licensed [CC BY 4.0](https://github.com/riscv/riscv-isa-manual/blob/main/LICENSE).
The selections, masks, staging boundaries, and review gates are Fursoy proposals,
not additions to the standard. **Required** denotes a specification obligation;
**Choice** denotes a proposed project selection within permitted behavior.
References M/S/C/Z in sections refer to the sources above and named CSR sections.

Choice: RV64, little endian, IALIGN=32, one hart, one instruction in execution,
one outstanding LSU transaction, no speculative architectural side effects.
No H, AIA, Sstc, double-trap extensions, debug triggers, U-mode interrupts,
PMP implementation, translation, page tables, TLB, PLIC, cache, or multihart work
belongs to this milestone. Existing integer and CSR instructions remain the base.
This is a staged privilege contract, not a complete RVA23 or Linux boot claim.

## 1. Architectural state and transitions

Required: introduce actual current privilege state, distinct from saved xPP:
`U=00`, `S=01`, `M=11`. Encoding `10` is unsupported; H/virtualization state
does not exist. S support includes U support. CSR writes to MPP/SPP do not change
current privilege. Ordinary jumps, loads, stores, FENCE, and CSR instructions
cannot change current privilege. [M: misa; privilege and interrupt-enable stack]

Required: reset enters M. Choice: retain reset PC `0x80000000`; reset MPP=M,
SPP=U, all xIE/xPIE and writable status controls zero, delegation/interrupt
enables/software pending bits zero, both trap CSR banks zero. External pending
inputs reflect their producer levels, not fictitious reset-cleared pending bits.
With fixed SXL/UXL below, reset `mstatus=0x0000000a00001800` and
`sstatus=0x0000000200000000`. These intentionally differ from the M-only image.

The only privilege changes are reset, trap entry, and successful xRET:

| Event | Origin | Destination |
|---|---|---|
| Nondelegated exception or eligible M-target interrupt | M/S/U | M |
| Delegated exception or eligible S-target interrupt | S/U | S |
| MRET | M | saved MPP: M/S/U |
| SRET | M, or S with TSR=0 | saved SPP: S/U |

No trap moves execution downward. M-origin exceptions always stay in M even
when the corresponding delegation bit is set. U never receives a trap directly.
SRET in M is legal regardless of TSR and can return to S/U; it uses the S bank.
No hidden check for a matching previous trap is imposed on xRET. [M: trap
delegation, trap-return instructions; S: sstatus]

## 2. CSR access and atomicity

Required access predicate: valid supported encoding, implemented CSR, current
privilege at least `csr_address[9:8]`, no applicable intercept, and no attempted
write to a read-only CSR (`csr_address[11:10]=11` or additional CSR-specific
read-only restriction). An encoding for an unimplemented CSR stays illegal even
if its privilege bits appear accessible. Numeric comparison alone does not make
unsupported H CSRs legal. Access failure raises cause 2, with the faulting PC and
instruction in the destination trap bank; no explicit CSR or destination-register
write occurs. Read-only *fields inside an RW CSR* ignore writes without making
the whole CSR instruction illegal. [C; Z]

Required Zicsr rules retained from the frozen fix:

- CSRRW/CSRRWI always have write intent; rd=x0 suppresses their CSR read.
- CSRRS/CSRRC always read; write intent is encoded rs1!=x0, even if its value is zero.
- CSRRSI/CSRRCI always read; write intent is encoded zimm!=0.
- rd=x0 alone does not suppress CSRRS/CSRRC reads or writes.
- funct3=100 is illegal. The old CSR value returned to rd precedes that
  instruction's write. Privilege/RO checks precede all architectural effects.

Choice: register-file writes, CSR writes, PC changes, and privilege changes share
one architectural commit decision. Decode/RMW signals are proposals only.
A faulting or interrupt-preempted CSR instruction cannot modify either alias or
backing state. Trap CSR/status updates are the sole permitted implicit changes
on the trap edge. Independent timer increments and interrupt producer changes
are not instruction side effects and need not stop.

Additional access gates and base CSR inventory needed once lower modes exist:

- Base machine information registers (normative requirement):
  - `mhartid` (0xf14): read-only 64-bit, hardwired to 0 (hart 0). Writes raise cause 2. M-mode only.
  - `mvendorid` (0xf11), `marchid` (0xf12), `mimpid` (0xf13): read-only 32/64-bit, hardwired to 0 (non-commercial / unimplemented ID per spec). Writes raise cause 2. M-mode only.
  - `misa` (0x301): read/write address, M-mode only. Hardwired to read-only zero (writes ignored without error, WARL), signalling to software per spec that `misa` is not implemented and extensions are discovered via platform metadata.
- Environment configuration registers (v1.12/v1.13 software compatibility stubs):
  - `menvcfg` (0x30a): M-mode only. All bits WARL-zero (reads return 0, writes ignored) as no optional environment extensions (Zicbo*, pointer masking) are implemented in this milestone.
  - `senvcfg` (0x10a): S-mode accessible, illegal in U-mode. All bits WARL-zero (reads return 0, writes ignored).
- Counter exposure and access gates:
  - `time` (0xc01): deliberately deferred in this Bare milestone. Access raises illegal-instruction exception (cause 2). Software reads time directly from CLINT MMIO (`0x0200_bff8`) or M-mode firmware emulates it upon trap.
  - Introduce `mcounteren` (0x306) and `scounteren` (0x106). Choice: only CY bit 0 writable, other fields zero; both reset zero. Existing `cycle` (0xc00) remains read-only. S reads require mcounteren.CY; U reads require both CY bits. M reads do not require either. These controls gate access, not counting. Unimplemented counter CSRs (including `time`) continue to trap even if software writes their enable bits. [M/S: counter-enable]
- While `satp.MODE` is read-only Bare, `mstatus.TVM` is read-only zero; TVM interception of `satp` is inactive. S-mode reads/writes of `satp` access the Bare WARL register (returning 0), while U-mode accesses raise cause 2 due to privilege gating.

## 3. Status fields and aliases

Required xIE/xPIE/xPP semantics follow the privilege stack rules. Choice: the
following is the complete implemented status-field policy for this Bare stage;
other absent-extension/reserved fields read zero and ignore writes.

| mstatus field | Bits | Proposed legal values / behavior |
|---|---|---|
| SIE, MIE | 1, 3 | RW booleans |
| SPIE, MPIE | 5, 7 | RW booleans |
| SPP | 8 | RW: 0=U, 1=S |
| MPP | 12:11 | WARL: 0=U, 1=S, 3=M; unsupported 2 coerces to M |
| MPRV | 17 | RW; effective data privilege is (MPRV && current_priv == M) ? MPP : current_priv |
| SUM | 18 | Read-only zero: required while satp.MODE is fixed Bare |
| MXR | 19 | Read-only zero: required while satp.MODE is fixed Bare |
| TVM | 20 | Read-only zero: required while satp.MODE is fixed Bare |
| TW, TSR | 21, 22 | RW booleans: TW controls S-mode WFI intercept; TSR controls S-mode SRET intercept |
| UXL, SXL | 33:32, 35:34 | WARL fixed 2 (64-bit), writes ignored |
| UBE, SBE, MBE | 6, 36, 37 | WARL fixed zero (little endian) |
| FS, VS, XS, SD | 14:13, 10:9, 16:15, 63 | Zero; corresponding context extensions absent |
| MDT, SDT, other extension controls | respective standard positions | Zero; extensions not advertised |

MPRV modifies the effective privilege mode at which loads and stores execute, but
is effective only while the current privilege mode is M. When current privilege
is S or U, MPRV is ignored and memory accesses execute at the current privilege
mode: `effective_priv = (mstatus.MPRV && current_priv == M) ? mstatus.MPP : current_priv`.
MPRV never changes current privilege, CSR authorization, interrupt routing, or
instruction fetch privilege. Capture data effective privilege with an LSU request
for the later protection/translation interface; Bare memory currently imposes no
PMP or page permissions. This is not isolation between M/S/U. The full write
mask for `mstatus` is `0x00000000006219aa` (bits 1, 3, 5, 7, 8, 12:11, 17, 21, 22). [M: mstatus]

`sstatus` (0x100) is an alias, not independent storage. Its standard architectural
view includes SIE, SPIE, SPP, UBE, VS, FS, XS, SUM, MXR, UXL, SD; absent or
read-only fields above read zero. In this stage its valid architectural field read mask is
`(3<<32) | (1<<8) | (1<<5) | (1<<1)` = `0x0000000300000122`
(with UXL[33:32] fixed to 2, the maximum readable value is `0x0000000200000122`);
its write mask excludes UXL and is `0x0000000000000122` (bits 1, 5, 8). Writes preserve every
hidden M field, including MIE/MPIE/MPP/MPRV/TW/TSR/SXL. M accesses through
the sstatus address use the same restricted view. [S: sstatus]

## 4. Trap CSR banks and delegation

Choice: all bank registers below reset zero. Addresses and required function
follow M/S trap CSR definitions; WARL selections preserve Slice-0 alignment.

| CSR | Address | Read/write contract |
|---|---|---|
| medeleg | 0x302 | RW mask `0x3ff`: exception causes 0..9; all other bits zero |
| mideleg | 0x303 | RW mask `0x222`: SSI=1, STI=5, SEI=9; other bits zero |
| stvec | 0x105 | WARL BASE[63:2], MODE=0/1; reserved modes coerce to Direct |
| sscratch | 0x140 | Full 64-bit RW |
| sepc | 0x141 | WARL 64-bit address, bits 1:0 zero (IALIGN=32) |
| scause | 0x142 | Bit 63 interrupt flag, remaining bits cause; retain written bits |
| stval | 0x143 | Full 64-bit RW; informative trap values below |

Keep mtvec/mscratch/mepc/mcause/mtval at 0x305/0x340/0x341/0x342/0x343.
Both tvec banks allow four-byte BASE alignment in either mode. Both epc banks
retain all upper bits in Bare, including addresses outside mapped RAM. Hardware
trap writes use identical cause/value conventions for the selected bank; software
writes to cause/value registers do not create or acknowledge interrupts.
Retaining arbitrary cause writes is a project choice for the WLRL cause field.

Choice: delegation is fully software programmable within these masks, never
hardwired one. Bit 9 of medeleg (S-mode ECALL) is physically writable in the
0x3ff mask, but normative platform/SBI convention mandates that firmware keep
medeleg[9] = 0 so that S-mode ECALLs (SBI calls) trap to M-mode firmware rather
than looping back into S-mode. U ECALL is cause 8, S ECALL 9, M ECALL 11.
Required: medeleg[11] is zero. Choice: page-fault bits 12/13/15 remain zero until
translation exists; the later Sv39 proposal must explicitly extend the mask
(candidate `0xb3ff`). Do not generate page faults or advertise Sv39 now.

Exceptions route to S exactly when `origin != M && medeleg[cause]`; otherwise
they route to M. Global interrupt-enable bits do not mask synchronous exceptions.
Use current architectural origin, not MPRV effective data privilege, for routing.
Delegation changes the destination, never renumbers the cause. [M: delegation]

## 5. Atomic trap entry and return

Let P be pre-trap current privilege, fault_pc the instruction PC for a synchronous
exception, and next_pc the next uncommitted instruction for an interrupt.

| Operation | Atomic architectural update |
|---|---|
| Trap to M from M/S/U | mepc=event PC; mcause/event flag and mtval=event data; MPIE=old MIE; MIE=0; MPP=P; privilege=M; redirect to mtvec |
| Trap to S from S/U | sepc=event PC; scause/event flag and stval=event data; SPIE=old SIE; SIE=0; SPP=(P==S); privilege=S; redirect to stvec |
| MRET in M | Snapshot y=old MPP; privilege=y; PC=mepc; MIE=old MPIE; MPIE=1; MPP=U; clear MPRV if y!=M |
| SRET permitted in M/S | Snapshot y=(old SPP ? S : U); privilege=y; PC=sepc; SIE=old SPIE; SPIE=1; SPP=U; clear MPRV |

These stack/return changes are required, not software configuration choices.
Trap to S preserves the M bank and MIE/MPIE/MPP; trap to M preserves the S bank
and SIE/SPIE/SPP. Trap entry does not clear pending bits, delegation, or MPRV.
SRET preserves the M interrupt stack; MRET preserves the S interrupt stack.
SSCRATCH/MSCRATCH never change implicitly. [M: privilege stack/delegation; S: sstatus]

For either destination: Direct uses BASE; Vectored uses BASE+4*cause only for
interrupts, and BASE for every synchronous exception. ECALL/EBREAK do not retire;
EPC identifies that instruction, not PC+4. Choice: event tval is zero for ECALL,
EBREAK and interrupts; zero-extended instruction for illegal instructions;
faulting fetch address for fetch access fault; target address for a taken
misaligned jump/branch; effective data address for LSU faults. An invalid
instruction response contributes no decoded instruction bits or side effects.

## 6. Interrupt pending state, aliases, eligibility and priority

Choice: six supported causes {1,3,5,7,9,11}; mie writable mask `0xaaa`.
Machine sources remain CLINT MSIP/MTIP and the existing MEIP input. New supervisor
pending state is software-injected by M firmware; no new controller is required.

| mip field | Origin / CSR write behavior | sip behavior when delegated |
|---|---|---|
| MSIP, MTIP, MEIP | Existing producer levels; read-only fields | Always zero with proposed mideleg mask |
| SSIP | Software RW latch, reset 0 | RW alias |
| STIP | Software RW latch, reset 0; no Sstc/stimecmp | Read-only alias |
| SEIP | Software RW latch B, reset 0; read value B OR external S signal E | Read-only alias |

Choice: E is tied zero in this stage. Preserve the architectural split: if E is
introduced later, a CSR read returns B|E but SEIP RMW uses B alone; never latch E
as software pending state. M software can set/clear all three supervisor latches
even if not delegated. A trap does not automatically acknowledge any source.
STIP/SEIP are cleared through M firmware services; delegated SSIP can also be
cleared through sip. [M: mip/mie; S: sip/sie]

`sie` (0x104) reads `mie & mideleg & 0x222`; writes/RMW affect only those selected
backing enable bits and preserve all hidden bits. `sip` (0x144) reads
`mip & mideleg & 0x222`; its write mask is `mideleg & 0x2`. These are dynamic
aliases: clearing delegation hides state without clearing backing state, and
restoring delegation reveals it again. Writes to read-only fields of these RW
registers are ignored, not illegal CSR writes. Thus the M-only policy that any
write intent to mip traps must change when this contract is implemented.

For each supported bit i, let pending_enabled = mip[i] AND mie[i]. Required
eligibility, using current privilege P:

| Destination | Eligibility in addition to pending_enabled |
|---|---|
| M | mideleg[i]=0 AND (P<M OR (P=M AND MIE=1)) |
| S | mideleg[i]=1 AND (P=U OR (P=S AND SIE=1)) |

MIE cannot mask M-target interrupts while executing S/U. SIE cannot mask
S-target interrupts while executing U. An S-target interrupt stays pending but
cannot be taken while executing M; it does not fall back to M. A nondelegated
supervisor-numbered interrupt targets M. Exception delegation and interrupt
delegation are independent. [M/S: interrupt eligibility]

Required arbitration: eligible M-target interrupts before eligible S-target
interrupts. Within M destination use MEI > MSI > MTI > SEI > SSI > STI; within S
use SEI > SSI > STI. Filter eligibility and destination before selecting priority.
All six are level-sensitive. Reevaluate immediately after committing xRET or a
write to status/enables/pending/delegation, before another instruction retires.
Do not reinterpret an already completed trap using newly written delegation.

## 7. Precise boundaries and exception priority

Choice preserving Slice-0: reset cancels execution; otherwise an already-known
synchronous exception for the active instruction wins over eligible interrupts,
and an eligible interrupt wins over normal retirement of a ready nonfaulting
instruction. This relative synchronous/interrupt boundary policy is a project
selection; it is not a claim that an interrupt must wait for an unreturned fetch
to reveal a possible future exception.

An issued LSU transaction remains noninterruptible. A load response error or
store request error produces its synchronous trap first. A successful LSU
completion retires once; an interrupt can then name the following instruction.
A waiting instruction fetch can be preempted; its eventual response (including
an error) belongs to the discarded fetch and must not trap in the new context.
Retain the documented producer cancellation requirement at reset. Capture
instruction PC, origin privilege, and data effective privilege for the transaction
so stalls cannot change fault ownership. xRET changes fetch context atomically.

Required synchronous ordering from M's exception-priority table, restricted to
implemented causes: fetch access fault (1) before decode faults; illegal
instruction/privileged-access failure (2); taken control-flow misalignment (0);
ECALL (8/9/11); EBREAK (3); LSU misalignment (4/6); LSU access fault (5/7).
Mutually exclusive instruction classes do not create simultaneous candidates.
Choice: misaligned data accesses fault before bus/protection/translation checks,
as allowed by the specification. No memory request is issued for them. Future
Sv39 must insert the specified translation-fault positions without changing
the chosen data-misalignment policy. No trigger breakpoint priority is implied
because triggers are absent.

Privilege failure on a CSR or xRET is an ordinary cause-2 exception and itself
uses exception delegation. A failed SRET does not partially pop the S stack.
An interrupt that preempts a CSR write observes old status/delegation and saves
that CSR instruction's PC; after return it may execute once. If a legal CSR
write newly enables an interrupt, the write commits first and the new interrupt
saves the following PC. Every entry selects exactly one destination bank and
performs no ordinary destination-register/store/CSR commit for the victim.

## 8. Privileged instructions and initial satp

| Instruction/access | Proposed allowed behavior; otherwise cause 2 |
|---|---|
| MRET | M only; semantics in section 5 |
| SRET | M, or S with TSR=0; always illegal in U |
| satp read/write | M, S (legal Bare access); always illegal in U |
| SFENCE.VMA | Required: illegal-instruction exception (cause 2) in all modes while satp.MODE is read-only Bare |
| WFI | Required: U always illegal. M: legal no-op. S: legal no-op if TW=0, immediate illegal (cause 2) if TW=1 |
| ECALL | Legal instruction in all three modes, causes 11/9/8 respectively |
| EBREAK | Cause 3 in all modes; no debug entry implemented |
| H, SINVAL.VMA, unsupported SYSTEM encodings | Illegal; no extension silently advertised |

TW and TSR are machine-controlled status bits, not visible via sstatus. SRET in M
ignores TSR. WFI in M ignores TW. WFI in U always raises an illegal-instruction
exception (cause 2) as required by the specification. In S-mode, WFI executes as a
legal no-op when TW=0, and immediately raises cause 2 when TW=1; no sleep engine
is required.

SFENCE.VMA is defined by the normative Supervisor ISA (Section 4.2.1) to raise an
illegal-instruction exception (cause 2) in all modes when page-based virtual memory is
not supported (i.e. satp.MODE is read-only zero). This strictly matches ratified
specification requirements and Spike reference behavior. When Sv39 translation is
introduced in a later milestone, SFENCE.VMA will become legal in M and S (gated by TVM=0).

`satp` (0x180) is an RV64 RW CSR with WARL fields MODE[63:60], ASID[59:44],
PPN[43:0]. In this Bare milestone, its only supported state is zero: MODE=Bare,
ASIDLEN=0, PPN=0, reset zero. Reads in M and S return zero; writing MODE=0 with
remaining fields zero selects Bare. An unsupported MODE, including Sv39=8, ignores
the entire write as required. For the specification's UNSPECIFIED Bare/nonzero-payload
case, deterministically retain zero and Bare. S accesses are legal (TVM is read-only
zero in Bare), while U accesses raise cause 2 due to CSR privilege gating.

Bare uses physical addresses without Sv39 canonical-address checks. Existing
RAM/MMIO decode and physical access errors still apply. No S/U isolation exists
without a separate protection mechanism. Sv39 must later define physical address
width, implemented PPN/ASID bits, SUM behavior, translation permissions under
MPRV/MXR, page-fault metadata, SFENCE ordering, and permission-cache invalidation;
none is implemented or validated by this package. [S: satp]

## 9. Compatibility and decisions before implementation

The current core has no privilege register, hardwires trap MPP=M and post-MRET
MPP=M, gates every interrupt on MIE, has no S aliases/delegation, and rejects all
mip writes. Those behaviors are correct only for its frozen M-only subset.
Future S-mode work must explicitly version the contract rather than reuse its
full-value reset/MRET assertions as unchanged acceptance criteria.

Additional migration risks: ECALL is currently always cause 11; CSR address
privilege bits are not checked; the M bank currently receives every trap;
read/RMW currently share one old-value path (SEIP requires a distinct writable
view); alias writes can overwrite hidden M bits if treated as full-register
writes; changes to the interrupt mask must not acknowledge pending sources.
Fetch-fault suppression, encoded-rs1 write intent, response ownership, and
single-commit rules remain required invariants.

Review gates (open, not authority to begin implementation):

1. Accept this staged M/S/U + Bare scope and the deliberate absence of memory isolation.
   All physical mappings, including CLINT, remain reachable from lower modes
   unless a separately approved access policy is introduced. This is suitable
   for controlled privilege tests, not adversarial user programs.
2. Approve delegation masks 0x3ff/0x222 and software-only S pending sources.
   Standard firmware/SBI convention mandates leaving medeleg[9] = 0 to route
   S ECALLs to M services; no SBI implementation is included in hardware.
3. Confirm the base CSR inventory resolved in this contract:
   - Normative base registers: mhartid (0), mvendorid/marchid/mimpid (0), misa (WARL 0).
   - Environment configuration stubs: menvcfg (0x30a) and senvcfg (0x10a) as WARL-zero stubs.
   - Counter controls: mcounteren/scounteren CY bit 0; time CSR (0xc01) is deliberately
     deferred in this Bare stage (trapping to M-mode for emulation or CLINT MMIO access).
4. Confirm ratified status and privileged instruction behavior in Bare:
   - SUM, MXR, and TVM are read-only zero in Bare.
   - MPRV effective privilege applies only while current privilege is M.
   - TW and TSR intercepts are active; WFI in U-mode unconditionally raises cause 2.
   - SFENCE.VMA unconditionally raises cause 2 while satp.MODE is read-only zero,
     strictly conforming to normative Supervisor ISA Section 4.2.1 and Spike.

No ambiguity remains in the proposed routing equations or state transitions;
the open items are acceptance of the staged platform and its completeness/ABI
boundary. Any rejected choice requires a contract revision before RTL starts.

## 10. Later acceptance evidence (definition only)

The future implementation review should require a privilege-by-cause delegation
matrix, MRET/SRET stack checks for every allowed origin/target, CSR minimum-mode
and alias preservation checks, eligible interrupts across all modes/global-enable
settings, illegal CSR/xRET side-effect suppression, and stalled fetch/LSU trap
ownership across transitions. Include hidden pending state when delegation flips,
SEIP read versus writable RMW state, satp unsupported-MODE writes, TVM/TW/TSR,
and cycle access gates. These are review obligations, not tests added or executed
by this documentation task.
