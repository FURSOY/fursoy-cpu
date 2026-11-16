# Fursoy Slice-1 Core Architecture Specification v1

- **Document ID:** `docs/architecture/slice1-core-v1.md`
- **Status:** CANONICAL SEMANTIC ARCHITECTURE v1.1 (Synced to Post-Phase-3 Production RTL `bab4ceb`)
- **Target Core:** Fursoy Slice-1 (Single-Hart, 2-Wide Fetch/Decode/Retire, 5-Port Scalar OoO + OoO Vector Execution, `RV64IMAFDV + Zba + Zbb + Zicsr + Zifencei`, Sv39)
- **Predecessor Reference:** Fursoy Slice-0 (Frozen Baseline)

---

## 1. Architectural Scope & Design Discipline

Fursoy Slice-1 is a 64-bit single-core RISC-V out-of-order processor designed for Linux execution with an extensible external cache-coherence boundary.

The Slice-1 microarchitecture addresses the structural bottlenecks measured in Slice-0:
1. **Decoupled 2-Wide Superscalar OoO Execution**: Replaces the monolithic 2-stage (Fetch | Execute) in-order pipeline with a decoupled frontend (`F0`–`F4`), 2-wide decode/rename/dispatch, **5 decoupled scalar execution ports** (`IntIQ32` → `P0/P1`, `MemIQ32` → `P2/P3`, `FPIQ16` → `P4`), an **out-of-order Vector subsystem** (`fursoy_s1_vrat` + `fursoy_s1_vec_iq` `VIQ8` + dual-lane 128-bit SIMD beats + ROB-head vector memory over `64 × 256-bit` VRF), and 2-wide in-order retirement from `ROB128`.
2. **Non-Blocking Multi-Banked Memory**: Replaces the single-outstanding Store Refill Buffer (SRB) with a non-blocking, 8-bank (`PA[5:3]`) L1 data cache featuring true 3-bit Tree-PLRU replacement, 4 MSHRs, and a 2-entry dirty-victim Writeback Buffer (WBB).
3. **500 MHz Datapath & Split Translation Closure**: Uses shared 64-bit Kogge-Stone parallel-prefix adders (`fursoy_s1_ks_adder`) across ALU, Branch Unit, AGU, CSR, and 2-stage pipelined `fursoy_s1_fconv`, iterative Radix-4 dividers/sqrt, and standalone split 64-entry Base + 8-entry Superpage ITLB (`fursoy_s1_itlb`) and dual-port DTLB (`fursoy_s1_dtlb`) with decoupled Tree-PLRU updates.

---

## 2. Semantic Architecture & Pipeline Contracts

The following structures and policies define the canonical Slice-1 behavioral contracts implemented in RTL.

### 2.1 Multi-Stage Pipeline Topology & Bandwidth

The implemented pipeline is structured across explicit frontend, rename/issue, execution, and retirement stages:

```text
F0 (GenPC) -> F1 (ReqMem) -> F2 (RspMem) -> F3 (Align/JAL) -> F4 (FetchQ16) -> D0 (Decode)
  -> RN (Int/FP/Vec Rename) -> DS (ROB128 + IQs) -> IS (IntIQ32 / MemIQ32 / FPIQ16 / VIQ8)
  -> RF (IntPRF160 / FPRF64 / VRF64) -> EX (Ports 0-4 + Vector) -> WB -> CMT (ROB128 Retire)
```

```text
+===================================================================================================+
|                        FURSOY SLICE-1 PRODUCTION PIPELINE STAGE MAP                               |
+===================================================================================================+

  Frontend: [ F0 GenPC ] -> [ F1 ReqMem ] -> [ F2 RspMem ] -> [ F3 Align ] -> [ F4 FetchQ16 ] -> [ D0 Decode ]
            Redirect arb     ITLB lookup     L1I way select   64b block       16-ent FIFO        2-Wide decode
            & next-PC+4      & BPU query     TAGE/BTB/IBP/    & early JAL     w/ 32-slot         (FS/VS/TW/frm/
                                             RAS + F2 skid    redirect        indexed RAS id     vtype traps)

  Backend:  [ RN Rename ] -> [ DS Dispatch ] -> [ IS Issue ] -> [ RF RegRead ] -> [ EX Execute ] -> [ WB / CMT ]
            2W Int SRAT      2W into ROB128     <=5 scalar      PRF 160x64b       P0: ALU0/BR/CSR  M1/EX WB tag
            2W FP FRAT       & IQs (Int32,      + OoO VIQ8      FPRF 64x64b       P1: ALU1/MUL/DIV check + ROB128
            1W Vec VRAT       Mem32, FP16,      arbitration     VRF 64x256b       P2/P3: AGU0/1    2W in-order
            16 checkpoints    VIQ8)                             (4R+1W banked)    P4: FMA/FDIV/FCV retire + flush
                                                                                  Vec: 128b SIMD
```

- **Fetch Stages (`F0`–`F4`)**:
  - `F0` (`GenPC`): Deterministic redirect priority arbiter and sequential PC+8 / odd-slot PC+4 generation.
  - `F1` (`ReqMem`): Virtual instruction address issue, Sv39 ITLB lookup (`fursoy_s1_itlb`), and parallel BPU lookup (`fursoy_s1_bpu`).
  - `F2` (`RspMem`): Non-blocking L1I cache tag/data read (`fursoy_s1_l1i`, 2 I-MSHRs), TAGE-Lite / BTB / IBP / RAS prediction evaluation, and synchronous `F2` skid buffer.
  - `F3` (`Align`): 64-bit fetch block extraction (two 32-bit instructions; no compressed `C` extension), odd-slot (`PC[2] == 1`) masking, and gated early unconditional `JAL` redirect with `INDEXED_RAS_CHKPT` rewind.
  - `F4` (`FetchQueue`): 16-entry decoupled FIFO (`FETCH_QUEUE_DEPTH = 16`) carrying pre-branch history and `ras_chkpt_id` metadata to `D0`.
- **Decode & Rename (`D0` / `RN` / `DS`)**:
  - `D0` (`fursoy_s1_decode`): 2-wide parallel combinational decoder with fetch-exception bypass and decode-time checks for `mstatus.FS`, `mstatus.VS`, `mstatus.TW`, `fcsr.frm >= 5` on dynamic FP RM, `SFENCE.VMA` flags, and `vtype`/`calc_vec_emul_info` legality.
  - `RN` / `DS`: 2-wide integer/FP allocation and serialized vector allocation (`vec_dispatch_ready[1] = 1'b0`, preserving scalar+vector dual-issue) across **16 branch checkpoints** (`NUM_CHECKPOINTS = 16`, `CHKPT_IDX_W = 4`), populating `ROB128` (`entries_q[rob_idx].inst` retained for cause-2 `mtval`/`stval` capture) and the four issue queues.
- **Execution Issue & Writeback (`IS` / `RF` / `EX` / `WB`)**:
  - **Port 0 (`IntIQ32`)**: `ALU0` (`1c`, `fursoy_s1_ks_adder`) + Branch Resolution Unit (`1c` KS target & carry-free match, max 1 branch/cycle) + `System/CSR` + `int2fp` dispatch (backpressured by `fconv_fprf_busy`).
  - **Port 1 (`IntIQ32`)**: `ALU1` (`1c` via `alu1_fifo`) + 3-stage Pipelined Multiplier + Iterative Radix-4 Divider (`~34c`).
  - **Port 2 (`MemIQ32` / `AGU0`)**: Shared-KS `fursoy_s1_agu` for Loads, Stores, AMOs, `LR`/`SC`, and `FENCE`/`FENCE.I`.
  - **Port 3 (`MemIQ32` / `AGU1`)**: Second AGU for Loads only (enabling 2 loads/cycle or 1 load + 1 store AGU/cycle across 8 L1D banks).
  - **Port 4 (`FPIQ16`)**: Scalar FP `FMA` (`3c` FP32 / `4c` FP64) + non-blocking Radix-4 `FDIV/FSQRT` (`12–28c`) + 2-stage pipelined `fursoy_s1_fconv` (`16`-entry `f2i_fifo` / `fprf_fifo`).
  - **Vector Pipe (`VIQ8` + `u_vrat` + `u_vrf`)**: Out-of-order vector ALU/mask/slide/reduction issue (`VIQ8`) and ROB-head serialized vector loads/stores (unit-stride, strided, indexed `vluxei`/`vsoxei`, fault-only-first `vleff`) executing 128-bit dual-lane SIMD beats and element-wise ops over the 4-bank `64 × 256b` 4R+1W `VRF`.
- **Commit (`CMT`)**: 2 uops / cycle retired in strict program order from the `ROB128` head, pushing BPU commit training records into `fursoy_s1_bpu`.

---

### 2.2 Register Renaming & Physical Register Files (Int / FP / Vector)

#### 2.2.1 Unified PRF, FPRF, and Bitmap-Renamed VRF
- **Integer PRF**: `160` entries (`p0..p159`, `64`-bit), paired with `ROB_DEPTH = 128`. Register `p0` is hardwired `64'd0`, permanently ready, and never allocated from the Free List (`32` ARAT + `128` Free List = `160`, guaranteeing Free List cannot exhaust before ROB128 fills).
- **Floating-Point PRF**: `64` entries (`fp0..fp63`, `64`-bit), `32` architectural + `32` Free List (`FL_FP_DEPTH = 32`), with dedicated `FRAT` (`SRAT_FP`/`ARAT_FP`) and `f0..f31` all dynamically writable (no hardwired zero).
- **Vector Register File & VRAT (`fursoy_s1_vrf` + `fursoy_s1_vrat`)**:
  - `VRF_NUM_PREGS = 64` physical vector registers × `256` bits (`4 × 64b` banks, `4R + 1W` ports including `raddr3_v_i` for `old_vd` tail/mask merging).
  - Architectural vectors `v0..v31` initialize mapped to `p0..p31`; speculative destinations allocate `p32..p63` from a **32-bit bitmap freelist** (`fl_free_q[31:0]`) via parallel-prefix popcount (`bit_rank`), allocating `1..8` registers (`LMUL` / `EMUL = 1, 2, 4, 8`) per instruction.
  - Because free bitmap bits need not be contiguous, `fursoy_s1_vrat` outputs explicit per-group physical map arrays (`alloc_vd_map_o[0..7]`, `alloc_old_vd_map_o[0..7]`, `alloc_vs1_map_o[0..7]`, `alloc_vs2_map_o[0..7]`) indexed directly by sub-register offset in `VIQ8` and execution beats.

#### 2.2.2 Scalar Register Lifecycle & Ownership Invariants
```text
Free List --(Rename)--> P_new (Speculative Live) --(Execute)--> P_new (Ready)
  --(Commit)--> ARAT[rd] := P_new  ==>  displaced P_old freed immediately (or VRF bitmap bit set on commit)
```
For all non-`p0` integer physical registers `p` in `{p1..p159}`:
- `P_committed = Range(ARAT) \ {p0}`
- `P_displaced = { u.P_old | u in ROB_active, u.rd != x0, u.P_old != p0 }`
- `P_spec      = { u.P_new | u in ROB_active, u.rd != x0 }`
- `P_free      = FreeList`

**Normative Invariants**:
1. **Mutual Exclusion**: `P_committed`, `P_displaced`, `P_spec`, and `P_free` are pairwise disjoint, and their union equals `{p1..p159}`.
2. **Safety**: No physical register present in any Free List appears in ARAT, any valid SRAT/FRAT/VRAT checkpoint, or any active ROB destination field.
3. **Uniqueness & Conservation**: Each valid destination-producing ROB entry owns exactly one allocated `P_new` (or `vd_ngroups` vector bits in VRAT) until commit or squash, and displaced architectural mappings are freed exactly once on commit.

#### 2.2.3 Recovery Semantics & Branch Checkpointing
1. **Branch Misprediction Recovery (`16` Checkpoints)**:
   - Rename allocates one of `NUM_CHECKPOINTS = 16` snapshots per branch/speculative `JALR`, simultaneously capturing integer `SRAT`, FP `FRAT`, vector `VRAT` `srat_q`/`fl_free_q`, BPU `GHR`/folded CSRs, and `INDEXED_RAS_CHKPT` RAS ID.
   - On Port 0 mispredict recovery, rename stalls, `SRAT`/`FRAT`/`VRAT`/BPU restore from checkpoint `k`, younger ops in ROB, IQs (`IntIQ`, `MemIQ`, `FPIQ`, `VIQ8`), LQ, SQ, and Fetch Queue are squashed, and the ROB recovery walker reclaims `P_new` at 2 registers/cycle while `fursoy_s1_vrat` reclaims squashed `vd_map` bits from its 128-entry ROB metadata table. `P_old` of squashed entries is **never** reclaimed.
   - `vec_vstart_inflight_q` tracks `vec_vstart_rob_idx_q` so `int_recover_valid` clears the non-zero `vstart` dispatch lock only if the in-flight `vstart != 0` vector op is younger than the mispredicted branch.
2. **Full Architectural Flush (Traps, Interrupts & System Redirects)**:
   - All speculative in-flight entries are invalidated; `SRAT ← ARAT`, `FRAT ← ARAT_FP`, `VRAT` rebuilds `fl_free_q` from `arat_q` in 1 cycle, and Free Lists reconstruct deterministically.
   - `fursoy_s1_bpu` restores `ghr_q ← arch_ghr_q`, `csr_q ← arch_csr_q`, `ras_tos_q ← arch_ras_tos_q`, `ras_depth_q ← arch_ras_depth_q`, and preserves the full `16`-entry `arch_ras_array_q` across non-branch traps rather than zeroing call-stack history.

---

### 2.3 Branch Prediction & Vector Synchronization
- **BPU (`fursoy_s1_bpu.sv`)**: Combines a 512-entry 2-way BTB, 30,208-bit 5-table TAGE-Lite (`L = 4/12/36/108`, 108-bit GHR), **64-entry tagged Indirect Branch Predictor (`IBP`)**, and 16-entry coroutine-aware RAS (`INDEXED_RAS_CHKPT = 32`, slots `1..31`, slot `0` reserved post-flush/reset baseline). BTB, TAGE, and IBP tables train strictly at ROB commit through a commit-training FIFO with periodic 256K u-bit reset.
- **Port 1 Arbitration**: Lossless holding arbiter (`Divider > Multiplier > ALU1` priority via `alu1_fifo`) guarantees zero dropped completions across variable-latency `MUL` (3c) and `DIV` (8–34c).
- **Vector `vstart` & `vtype` Serialization**: `vset*` and `vstart` CSR writes serialize via full pipeline flush so `decode` (`vtype_i`) and dispatch observe exact `vtype` and `vstart` state; vector completion clears `vstart_q <= 64'd0` upon architectural vector retirement.

---

### 2.4 Memory Subsystem, MMU & Sv39 Rules
- **Conservative Speculative Load Issue**: Loads may issue speculatively past older stores only when cacheable/non-MMIO and `replay_safe == 0`. `LR.W/D` serializes at `rob_head_i` (`fursoy_s1_lsu_queues.sv:707`); `AMO` and `SC.W/D` execute strictly non-speculatively at ROB head with an empty Store Queue.
- **Store-to-Load Forwarding**: `16`-entry LQ and `16`-entry SQ perform CAM matching (`PA[55:3]`); exact and contained older store matches forward in 1 cycle, while partial overlap or unresolved data stalls until SQ drain.
- **Non-Blocking 8-Bank L1D (`fursoy_s1_l1d.sv`)**: `16 KiB` 4-way (`64` sets × `64 B`, `4 KiB/way` VIPT synonym-safe), 8 banks (`PA[5:3]`), **true 3-bit Tree-PLRU** per set, `4` MSHRs, `2` WBBs, and protocol-neutral external snoop ports (`SNOOP_INV`, `SNOOP_READ`, `SNOOP_CLEAN_INV`) plus 1-cycle non-destructive PTW snoop read.
- **Split Sv39 ITLB / DTLB & Shared PTW**: Parallel 64-entry 4-way Base TLB (Tree-PLRU) + 8-entry 2 MiB/1 GiB Superpage CAM with 16-bit ASID matching (`satp[59:44]`) and `global_map` preservation during `rs2 != x0` `SFENCE.VMA`. `fursoy_s1_ptw` raises page faults on reserved PTE bits `[63:54] != 0` and non-leaf `U/A/D != 0`, and evaluates data walks using `walk_priv = (priv_mode == M && mstatus.MPRV) ? mstatus.MPP : priv_mode`.

---

### 2.5 Implemented ISA Scope & Privilege Compliance
- **ISA**: `RV64IMAFDV + Zba + Zbb + Zicsr + Zifencei` under `Sv39` (`16`-bit ASID). `C` (Compressed), `H` (Hypervisor), and `Zicbo*` are excluded.
- **Illegal-Instruction Precision**: `mtval`/`stval` captures zero-extended `{32'd0, inst}` on `cause 2` traps (`fursoy_s1_rob.sv`); `decode` and `csr` trap `mstatus.FS == 0`, `mstatus.VS == 0`, `mstatus.TW` (`WFI` in S-mode), `TVM`/`TSR`, dynamic FP `rm == 7` when `frm >= 5`, and invalid `vtype`/EMUL/group-alignment/`v0`-overlap RVV encodings (`calc_vec_emul_info`).
- **Platform Peripherals**: Unified `CLINT` load/store response (`rsp_valid_q`/`rsp_error_q`), `16550 UART` aligned 1B/2B/4B MMIO (`0x00..0x1C` at 4B stride), and preemptible `PLIC` (`in_service_q[31:1]`).

---

## 3. Master Parameter Table

| Parameter / Subsystem | Implemented RTL Value | Classification |
|---|---|---|
| **Fetch / Decode / Rename / Retire Width** | `64b` (2 × 32b insns) / `2W` / `2W` / `2W` | **FROZEN — NUMERIC PARAMETER** |
| **Execution Issue Ports** | `P0` (`ALU0/BR/CSR/I2F`), `P1` (`ALU1/MUL/DIV`), `P2` (`AGU0`), `P3` (`AGU1`), `P4` (`FMA/FDIV/FCONV`) + `VIQ8` (`Vec`) | **FROZEN — NUMERIC PARAMETER** |
| **ROB Capacity** | `128` entries (`ROB_DEPTH = 128`, 4-bit epochs) | **FROZEN — NUMERIC PARAMETER** |
| **Integer PRF / FP PRF** | `160 × 64b` (`32` arch + `128` FL) / `64 × 64b` (`32` arch + `32` FL) | **FROZEN — NUMERIC PARAMETER** |
| **Vector RF & Renamer** | `64 × 256b` 4-bank 4R+1W `VRF` (`p0..p31` arch, `p32..p63` bitmap FL via `fursoy_s1_vrat`) | **FROZEN — NUMERIC PARAMETER** |
| **Branch Checkpoints** | `16` checkpoints (`NUM_CHECKPOINTS = 16`, `CHKPT_IDX_W = 4`) | **FROZEN — NUMERIC PARAMETER** |
| **Issue Queues** | `IntIQ = 32`, `MemIQ = 32`, `FPIQ = 16`, `VIQ8 = 8`, `FetchQ = 16` | **FROZEN — NUMERIC PARAMETER** |
| **LSU / Cache Trackers** | `LQ = 16`, `SQ = 16`, `TRT = 32`, `ITRT = 2`, `L1D MSHR = 4`, `WBB = 2`, `L1I MSHR = 2` | **FROZEN — NUMERIC PARAMETER** |
| **L1I & L1D Geometry** | `16 KiB` 4-way VIPT (`64 × 64 B`, `4 KiB/way`), 8-bank L1D (`PA[5:3]`), 3-bit Tree-PLRU | **FROZEN — GEOMETRY CONTRACT** |
| **Sv39 ITLB / DTLB** | `64`-entry 4-way Base (Tree-PLRU) + `8`-entry Superpage CAM, `16`-bit ASID | **FROZEN — NUMERIC PARAMETER** |
| **Branch Predictor** | `512`-ent 2W BTB + `30,208b` TAGE-Lite (`108b` GHR) + `64`-ent tagged `IBP` + `16`-RAS (`INDEXED_RAS_CHKPT=32`) | **FROZEN — IMPLEMENTED PARAMETER** |
| **Shared Datapath Primitive** | `fursoy_s1_ks_adder` (64-bit Kogge-Stone across ALU, Branch Unit, AGU, CSR, FCONV) | **IMPLEMENTED PRIMITIVE** |

---

## 4. Physical Synthesis & Macro-Area Scope (Nangate 45nm @ 500 MHz)

`tools/run_s1_synth.py --run-synth` evaluates standalone standard-cell timing via `sv2v v0.0.13` → `Yosys 0.33` → `OpenSTA 3.1.0` against Nangate45 Typical (`1.10V, 25C`, `2.000 ns` target):
- **Gated Closure (`8 / 8 MET`, `225.77 kGE`, `TNS = 0.00 ns`)**: Covers combinational and register-bounded logic blocks (`agu`, `branch_unit`, `ptw`, `decode`, `alu`, `csr`, `itlb`, `dtlb`), plus expanded visibility on 2-stage pipelined `fursoy_s1_fconv` (`46.83 kGE`, `+0.009 ns` WNS, closing `9 / 16` evaluated modules at 500 MHz).
- **Why SRAM-Macro & Queue-Matrix Blocks Are Excluded from Macro-Area Comparisons**: Blocks dominated by dense storage arrays or large associative age matrices (`fursoy_s1_l1i`, `fursoy_s1_l1d`, `fursoy_s1_int_iq`, `fursoy_s1_lsu_queues`, `fursoy_s1_vrat`, `fursoy_s1_vec_iq`, `fursoy_s1_bpu`) as well as wide combinational FP trees (`fursoy_s1_fma`, `fursoy_s1_fdiv`) hit standard-cell flattening/ABC timeouts when synthesized without SRAM black-boxes or macro compilers. Similarly, `fursoy_s1_dtlb` (`99.87 kGE`, `6,515` DFFs) and `fursoy_s1_itlb` (`77.52 kGE`, `6,304` DFFs) currently map as discrete standard-cell flip-flop arrays; their reported area reflects flop-based prototyping rather than compiled CAM/SRAM macro density.
