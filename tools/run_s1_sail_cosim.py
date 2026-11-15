#!/usr/bin/env python3
"""
Fursoy Slice-1 Differential Co-Simulation Runner (vs. sail-riscv Golden Model).

Compiles self-contained RV64IMAFDV + Zba + Zbb + Sv39 + Trap ELF programs,
runs them on the official prebuilt sail-riscv golden simulator and on
Fursoy Slice-1 RTL (`fursoy_s1_core` with `frontend_en_i = 1`), and compares
every single retired instruction commit and synchronous trap 1-to-1.
"""

from __future__ import annotations

import json
import re
import struct
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from s1_rtl_manifest import CORE_RTL, ROOT

BUILD_DIR = ROOT / "build/s1_sail_cosim"
REPORT = ROOT / "results/s1-sail-cosim.json"

SAIL_BIN = ROOT / "tools/sail/bin/bin/sail_riscv_sim"
SAIL_CFG = ROOT / "tools/sail/fursoy_s1_sail_config.json"
TB_CPP = ROOT / "verification/s1_sail_cosim_tb.cpp"

LINKER_SCRIPT = r"""
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x80000000;
  .text : ALIGN(4) { *(.text.init) *(.text .text.*) }
  .rodata : ALIGN(16) { *(.rodata .rodata.*) }
  .data : ALIGN(64) { *(.data .data.*) }
  .tohost : ALIGN(64) {
    tohost = .;
    QUAD(0);
    . = ALIGN(64);
    fromhost = .;
    QUAD(0);
  }
  .bss : ALIGN(64) {
    *(.bss .bss.*)
    *(COMMON)
  }
}
"""

COMMON_HTIF_MACROS = r"""
.macro HTIF_EXIT code
    li   t0, ((\code << 1) | 1)
    j    _htif_halt_fn
.endm

.section .text.htif
.globl _htif_halt_fn
.globl _htif_halt
_htif_halt_fn:
    la   t1, tohost
_htif_halt:
    sd   t0, 0(t1)
99: j    99b
"""

WORKLOADS: dict[str, str] = {
    "01_rv64im_zba_zbb": COMMON_HTIF_MACROS + r"""
.section .text.init
.globl _start
_start:
    # RV64I base arithmetic, shifts, comparisons, branches, JAL/JALR
    li   x1, 0x123456789abcdef0
    li   x2, -42
    add  x3, x1, x2
    sub  x4, x1, x2
    slt  x5, x2, x1
    sltu x6, x2, x1
    xor  x7, x1, x2
    or   x8, x1, x2
    and  x9, x1, x2
    slli x10, x1, 7
    srli x11, x1, 7
    srai x12, x1, 7
    addw x13, x1, x2
    subw x14, x1, x2
    sllw x15, x1, x2
    srlw x16, x1, x2
    sraw x17, x1, x2

    # M extension (including negative operands, div-by-zero, INT64_MIN / -1)
    li   a0, -1234567
    li   a1, 7654321
    mul    a2, a0, a1
    mulh   a3, a0, a1
    mulhu  a4, a0, a1
    mulhsu a5, a0, a1
    div    a6, a1, a0
    divu   a7, a1, a0
    rem    t0, a1, a0
    remu   t1, a1, a0
    li   t2, 0
    div    t3, a1, t2
    rem    t4, a1, t2
    li   t5, 1
    slli t5, t5, 63        # INT64_MIN
    li   t6, -1
    div  s0, t5, t6
    rem  s1, t5, t6
    mulw s2, a0, a1
    divw s3, a1, a0
    divuw s4, a1, a0
    remw s5, a1, a0
    remuw s6, a1, a0

    # Zba extension
    sh1add    s7, a0, a1
    sh2add    s8, a0, a1
    sh3add    s9, a0, a1
    add.uw    s10, a0, a1
    sh1add.uw s11, a0, a1
    sh2add.uw t3, a0, a1
    sh3add.uw t4, a0, a1
    slli.uw   t5, a0, 12

    # Zbb extension (all RV64 + W forms)
    andn   t0, a0, a1
    orn    t1, a0, a1
    xnor   t2, a0, a1
    clz    t3, x1
    clzw   t4, x1
    ctz    t5, x1
    ctzw   t6, x1
    cpop   a2, x1
    cpopw  a3, x1
    max    a4, a0, a1
    maxu   a5, a0, a1
    min    a6, a0, a1
    minu   a7, a0, a1
    sext.b s0, x1
    sext.h s1, x1
    zext.h s2, x1
    rol    s3, x1, x2
    rolw   s4, x1, x2
    ror    s5, x1, x2
    rorw   s6, x1, x2
    rori   s7, x1, 29
    roriw  s8, x1, 17
    orc.b  s9, x1
    rev8   s10, x1

    # Loads / Stores / Loop / JALR
    la   t0, scratch_buf
    sd   s10, 0(t0)
    sw   s9, 8(t0)
    sh   s8, 12(t0)
    sb   s7, 14(t0)
    fence rw, rw
    ld   t1, 0(t0)
    lw   t2, 8(t0)
    lwu  t3, 8(t0)
    lh   t4, 12(t0)
    lhu  t5, 12(t0)
    lb   t6, 14(t0)
    lbu  a0, 14(t0)

    li   a1, 0
    li   a2, 16
loop_sum:
    add  a1, a1, a2
    addi a2, a2, -1
    bnez a2, loop_sum

    jal  ra, helper_fn
    fence.i
    HTIF_EXIT 0

helper_fn:
    addi sp, sp, 0
    add  a1, a1, a0
    ret

.section .data
scratch_buf:
    .zero 64
""",

    "02_rv64fd_fp": COMMON_HTIF_MACROS + r"""
.section .text.init
.globl _start
_start:
    la   t0, fp_trap_handler
    csrw mtvec, t0

    # 1. Verify mstatus.FS == 0 triggers Illegal Instruction trap (Cause 2)
    fadd.d f0, f0, f0

    # Back from trap with FS == 01 (Initial). Verify non-canonical Zbb funct7=0x10 also traps!
    .word 0x203110b3     # opcode=OP (0x33), funct3=1 (SLL/ROL?), funct7=0x10 -> Illegal!

    # 2. Load operands & exercise IEEE-754 double & single ops, FMA, FDIV, FSQRT
    li     a0, 100
    li     a1, 3
    fcvt.d.l f1, a0
    fcvt.d.l f2, a1
    fadd.d f3, f1, f2
    fsub.d f4, f1, f2
    fmul.d f5, f1, f2
    fdiv.d f6, f1, f2          # Sets NX flag (100 / 3)
    fsqrt.d f7, f1             # sqrt(100) = 10.0

    fmadd.d  f8, f3, f4, f5
    fmsub.d  f9, f3, f4, f5
    fnmadd.d f10, f3, f4, f5
    fnmsub.d f11, f3, f4, f5

    # Rounding modes (RTZ=1, RDN=2, RUP=3, RMM=4)
    fcvt.l.d s0, f6, rtz
    fcvt.l.d s1, f6, rdn
    fcvt.l.d s2, f6, rup
    fcvt.l.d s3, f6, rmm

    # Single-precision + NaN-boxing load/store
    fcvt.s.d f12, f6
    la       t1, fp_buf
    fsw      f12, 0(t1)
    flw      f13, 0(t1)
    fcvt.d.s f14, f13
    fsd      f8, 8(t1)
    fld      f15, 8(t1)

    # Comparisons, sign injection, min/max, class, move-to-int
    feq.d   s4, f14, f14
    flt.d   s5, f2, f1
    fle.d   s6, f7, f1
    fsgnj.d  f16, f1, f2
    fsgnjn.d f17, f1, f2
    fsgnjx.d f18, f1, f17
    fmin.d  f19, f17, f1
    fmax.d  f20, f17, f1
    fclass.d s7, f17
    fmv.x.d s8, f8
    fmv.d.x f21, s8

    #DZ and NV exception flags
    fcvt.d.l f22, zero
    fdiv.d   f23, f2, f22      # 3.0 / 0.0 -> +inf, sets DZ
    fdiv.d   f24, f22, f22     # 0.0 / 0.0 -> qNaN, sets NV
    fsqrt.d  f25, f17          # sqrt(-100.0) -> qNaN, sets NV

    # Back-to-back csrw frm + dynamic rounding fadd.s / fcvt.w.s serialization (Fix 1)
    li       t3, 0x3fc00000    # 1.5f
    fmv.w.x  f26, t3
    li       t3, 0x3f800000    # 1.0f
    fmv.w.x  f27, t3
    li       t3, 0x33800000    # 2^-24 (0.5 ULP at 1.0f)
    fmv.w.x  f28, t3
    csrw     frm, 1            # RTZ
    fadd.s   f29, f27, f28, dyn
    fcvt.w.s a0, f26, dyn      # 1.5 -> 1 (RTZ)
    csrw     frm, 3            # RUP
    fadd.s   f30, f27, f28, dyn
    fcvt.w.s a1, f26, dyn      # 1.5 -> 2 (RUP)
    csrw     frm, 2            # RDN
    fcvt.w.s a2, f26, dyn      # 1.5 -> 1 (RDN)
    csrw     frm, 0            # Restore RNE

    csrr   s9, fflags
    csrr   s10, mstatus
    HTIF_EXIT 0

.align 4
fp_trap_handler:
    csrr   t1, mcause
    li     t2, 2
    bne    t1, t2, trap_fail
    csrr   t0, mepc
    addi   t0, t0, 4
    csrw   mepc, t0
    li     t3, 0x2000          # Set mstatus.FS = 01 (bits [14:13]) in MPP/current? No, enable in mstatus directly via FS!
    csrs   mstatus, t3
    mret
trap_fail:
    HTIF_EXIT 1

.section .data
fp_buf:
    .zero 64
""",

    "03_rvv_vector": COMMON_HTIF_MACROS + r"""
.section .text.init
.globl _start
_start:
    la   t0, vec_trap_handler
    csrw mtvec, t0

    # 1. Verify mstatus.VS == 0 triggers Illegal Instruction trap (Cause 2)
    vsetivli t0, 4, e32, m1, ta, ma

    # Back from trap with VS == 01 (Initial)
    # 2. Vector configuration & loads/stores/ALU/reduction/slide/mask
    li   a0, 8
    vsetvli t1, a0, e32, m1, ta, ma
    la   s0, vec_src_a
    la   s1, vec_src_b
    la   s2, vec_dst
    vle32.v v1, (s0)
    vle32.v v2, (s1)

    vadd.vv v3, v1, v2
    vsub.vv v4, v1, v2
    li      t2, 5
    vadd.vx v5, v3, t2
    vadd.vi v6, v4, 3
    vmul.vv v7, v1, v2
    vdivu.vv v8, v1, v2
    vminu.vv v9, v1, v2
    vmax.vv  v10, v1, v2
    vsll.vv  v11, v2, v2
    vsra.vv  v12, v1, v2

    # Mask comparison & masked vadd (using v0.t)
    vmseq.vv v0, v1, v2
    vmv.v.v  v13, v3
    vadd.vv  v13, v1, v1, v0.t

    # Reduction & slides
    vmv.v.i  v14, 0
    vredsum.vs v15, v3, v14
    vslideup.vi v16, v1, 2
    vslidedown.vi v17, v1, 2

    vse32.v  v13, (s2)

    # Strided load/store (stride = 8 bytes -> 4 elements fit in VL=4)
    vsetivli t3, 4, e32, m1, ta, ma
    li       t4, 8
    vlse32.v v18, (s0), t4
    vsse32.v v18, (s2), t4

    # Fault-Only-First (vle32ff.v) right at DRAM end boundary (0x8FFF_FFF8)
    # Elements 0, 1 reside in DRAM; element 2 crosses into unmapped 0x9000_0000 -> vl truncates to 2
    li       t5, 0x90000
    slli     t5, t5, 12
    addi     t5, t5, -8        # 0x0000_0000_8FFF_FFF8
    li       t6, 0xAA000011
    sw       t6, 0(t5)
    li       t6, 0xBB000022
    sw       t6, 4(t5)
    vsetivli t3, 8, e32, m1, ta, ma
    vle32ff.v v19, (t5)
    csrr     a2, vl
    csrr     a3, vtype

    # RVV 1.0 s6.2 vsetvli/vsetvl (rs1==x0, rd==x0) VLMAX preservation & vill rule (Fix 2)
    li       t0, 3
    vsetvli  t1, t0, e32, m1, ta, ma   # VLMAX = 8, vl = 3
    vsetvli  zero, zero, e16, mf2, ta, ma  # VLMAX = 8 (unchanged): keeps vl = 3, vill = 0
    csrr     a5, vl
    csrr     a6, vtype
    li       t2, 0x10                  # e32, m1 (VLMAX = 8 unchanged)
    vsetvl   zero, zero, t2
    csrr     a7, vl
    csrr     s3, vtype
    vsetvli  zero, zero, e32, m2, ta, ma   # VLMAX = 16 != 8: must set vill=1, vl=0!
    csrr     s4, vl
    csrr     s5, vtype
    vsetvli  zero, zero, e32, m1, ta, ma   # While vill==1: must remain vill=1, vl=0!
    csrr     s6, vl
    csrr     s7, vtype
    vsetivli t3, 4, e32, m1, ta, ma        # Restore valid vtype

    csrr     a4, mstatus
    HTIF_EXIT 0

.align 4
vec_trap_handler:
    csrr   t1, mcause
    li     t2, 2
    bne    t1, t2, vtrap_fail
    csrr   t0, mepc
    addi   t0, t0, 4
    csrw   mepc, t0
    li     t3, 0x200           # mstatus.VS = 01 (bits [10:9])
    csrs   mstatus, t3
    mret
vtrap_fail:
    HTIF_EXIT 1

.section .data
.align 6
vec_src_a:
    .word 100, 200, 300, 400, 500, 600, 700, 800
vec_src_b:
    .word 1, 200, 3, 400, 5, 2, 7, 3
vec_dst:
    .zero 64
""",

    "04_sv39_mmu_traps": COMMON_HTIF_MACROS + r"""
.section .text.init
.globl _start
_start:
    la   t0, m_trap_handler
    csrw mtvec, t0
    la   t0, s_trap_handler
    csrw stvec, t0          # Direct mode (MODE=0)
    li   t0, (1 << 15) | (1 << 4)
    csrw medeleg, t0        # Delegate Store Page Fault (15) & Load Misaligned (4) to S-mode

    # Build 3-level Sv39 page tables at 4 KiB-aligned pt_root / pt_mid / pt_leaf
    # We map two 1 GiB/2 MiB paths cleanly using 4 KiB pages:
    # 1) VA 0x8000_0000 .. 0x8000_FFFF -> PA 0x8000_0000 .. (Identity code/data/tohost, V|R|W|X|A|D)
    #    VPN[2] for 0x8000_0000 = 2, VPN[1] = 0, VPN[0] = 0..15
    # 2) VA 0x4000_0000 -> PA 0x8002_0000 (RW Data page, V|R|W|A|D)
    # 3) VA 0x4000_2000 -> PA 0x8002_2000 (RO Data page, V|R|A|D -> store causes Cause 15!)
    #    VPN[2] for 0x4000_0000 = 1, VPN[1] = 0, VPN[0] = 0 and 2

    la   s0, pt_root
    la   s1, pt_mid_80
    la   s2, pt_leaf_80
    la   s3, pt_mid_40
    la   s4, pt_leaf_40

    # pt_root[2] -> pt_mid_80 (Non-leaf V=1)
    srli t0, s1, 12
    slli t0, t0, 10
    ori  t0, t0, 0x1
    sd   t0, (2*8)(s0)

    # pt_root[1] -> pt_mid_40 (Non-leaf V=1)
    srli t0, s3, 12
    slli t0, t0, 10
    ori  t0, t0, 0x1
    sd   t0, (1*8)(s0)

    # pt_mid_80[0] -> pt_leaf_80 (Non-leaf V=1)
    srli t0, s2, 12
    slli t0, t0, 10
    ori  t0, t0, 0x1
    sd   t0, 0(s1)

    # pt_mid_40[0] -> pt_leaf_40 (Non-leaf V=1)
    srli t0, s4, 12
    slli t0, t0, 10
    ori  t0, t0, 0x1
    sd   t0, 0(s3)

    # Populate pt_leaf_80[0..15] -> identity 0x80000000 + i*0x1000, flags = DAGUXWRV = 0xCF (D=1,A=1,G=0,U=0,X=1,W=1,R=1,V=1 -> 0xCF)
    li   t1, 0
    li   t2, 16
    li   t3, 0x80000000
id_map_loop:
    slli t4, t1, 12
    add  t5, t3, t4
    srli t5, t5, 12
    slli t5, t5, 10
    ori  t5, t5, 0xCF
    slli t6, t1, 3
    add  t6, s2, t6
    sd   t5, 0(t6)
    addi t1, t1, 1
    blt  t1, t2, id_map_loop

    # pt_leaf_40[0]: VA 0x4000_0000 -> PA page_rw, flags = 0xC7 (D|A|W|R|V)
    la   t0, page_rw
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, 0xC7
    sd   t0, (0*8)(s4)

    # pt_leaf_40[2]: VA 0x4000_2000 -> PA page_ro, flags = 0xC3 (D|A|R|V, NO W!)
    la   t0, page_ro
    srli t0, t0, 12
    slli t0, t0, 10
    ori  t0, t0, 0xC3
    sd   t0, (2*8)(s4)

    # Enable Sv39 satp = (8 << 60) | (pt_root >> 12)
    srli t0, s0, 12
    li   t1, 8
    slli t1, t1, 60
    or   t0, t0, t1
    fence rw, rw
    csrw satp, t0
    sfence.vma zero, zero

    # Drop M-mode -> S-mode via mret (MPP = 01 at bits [12:11])
    li   t0, (3 << 11)
    csrc mstatus, t0
    li   t0, (1 << 11)
    csrs mstatus, t0
    la   t0, s_mode_entry
    csrw mepc, t0
    mret

s_mode_entry:
    # Translated load/store at mapped VA 0x4000_0000
    li   a0, 0x40000000 >> 12
    slli a0, a0, 12
    li   t1, 0x1122334455667788
    sd   t1, 0(a0)
    ld   a1, 0(a0)

    # Translated read from RO page VA 0x4000_2000 (succeeds)
    li   a2, (0x40002000 >> 12)
    slli a2, a2, 12
    ld   a3, 0(a2)

    # Trigger Delegated S-mode Store Page Fault (Cause 15) with stvec Direct (MODE=0)
    sd   t1, 8(a2)

    # Switch stvec to Vectored (MODE=1): synchronous exceptions MUST still vector to BASE!
    la   t0, s_trap_handler
    ori  t0, t0, 1
    csrw stvec, t0

    # Trigger Delegated S-mode Load Address Misaligned (Cause 4) with stvec Vectored (MODE=1)
    ld   a4, 1(a0)

    # Trigger non-delegated S-mode ECALL (Cause 9) -> M-mode returns us to M-mode
    ecall

back_in_m_mode:
    csrw satp, zero
    sfence.vma zero, zero
    # Verify M-mode non-delegated trap mtval (Load Misaligned Cause 4)
    la   t0, page_rw
    ld   a6, 1(t0)
    # Verify physical write via virtual address actually landed in DRAM page_rw
    la   t0, page_rw
    ld   a5, 0(t0)
    li   t1, 0x1122334455667788
    bne  a5, t1, fail_sv39
    HTIF_EXIT 0

fail_sv39:
    HTIF_EXIT 1

.align 4
s_trap_handler:
    csrr t0, scause
    csrr t1, sepc
    csrr t2, stval
    addi t1, t1, 4
    csrw sepc, t1
    sret

.align 4
m_trap_handler:
    csrr t0, mcause
    csrr t1, mepc
    csrr t2, mtval
    addi t1, t1, 4
    csrw mepc, t1
    li   t3, 9               # S-mode ECALL? Switch MPP to M-mode (3) on return!
    bne  t0, t3, 1f
    li   t4, (3 << 11)
    csrs mstatus, t4
1:  mret

.section .data
.align 12
pt_root:    .zero 4096
pt_mid_80:  .zero 4096
pt_leaf_80: .zero 4096
pt_mid_40:  .zero 4096
pt_leaf_40: .zero 4096
page_rw:    .zero 4096
page_ro:
    .dword 0xdeadbeefcafebabe
    .zero 4088
""",
}

SAIL_STEP_RE = re.compile(r"^\[(\d+)\]\s+\[(?:H?)([MSU])\]:\s+0x([0-9A-Fa-f]+)\s+\(0x([0-9A-Fa-f]+)\)\s+(.*)$")
SAIL_GPR_RE = re.compile(r"^x(\d+)\s+<-\s+0x([0-9A-Fa-f]+)$")
SAIL_FPR_RE = re.compile(r"^f(\d+)\s+<-\s+0x([0-9A-Fa-f]+)$")
SAIL_VRF_RE = re.compile(r"^v(\d+)\s+<-\s+0x([0-9A-Fa-f]+)$")
SAIL_CSR_RE = re.compile(r"^CSR\s+(\w+)\s+\(0x([0-9A-Fa-f]+)\)\s+<-\s+0x([0-9A-Fa-f]+)$")
SAIL_EXC_RE = re.compile(r"^handling\s+exc#(\S+)\s+at\s+priv\s+(?:H?)([MSU])")


def parse_elf_segments(elf_path: Path, out_dir: Path, prefix: str) -> list[tuple[int, Path]]:
    data = elf_path.read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise RuntimeError(f"Expected 64-bit ELF: {elf_path}")
    e_phoff, = struct.unpack_from("<Q", data, 32)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    segments: list[tuple[int, Path]] = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, _p_flags, p_offset, _p_vaddr, p_paddr, p_filesz, p_memsz, _p_align = struct.unpack_from(
            "<IIQQQQQQ", data, off
        )
        if p_type == 1 and p_memsz > 0:
            seg_bytes = bytearray(data[p_offset : p_offset + p_filesz])
            if p_memsz > p_filesz:
                seg_bytes.extend(b"\x00" * (p_memsz - p_filesz))
            seg_path = out_dir / f"{prefix}_seg{i}.bin"
            seg_path.write_bytes(seg_bytes)
            segments.append((p_paddr, seg_path))
    return segments


def get_symbol_address(elf_path: Path, symbol_name: str) -> int:
    res = subprocess.run(
        ["riscv64-unknown-elf-nm", "-n", str(elf_path)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == symbol_name:
            return int(parts[0], 16)
    raise RuntimeError(f"Symbol {symbol_name} not found in {elf_path}")


def priv_str_to_int(p: str) -> int:
    return {"U": 0, "S": 1, "M": 3}[p]


def parse_sail_trace(log_text: str) -> list[dict]:
    steps: list[dict] = []
    cur: dict | None = None
    state = {
        "fflags": 0,
        "vl": 0,
        "vtype": 0x8000000000000000,
        "satp": 0,
        "mcause": 0,
        "mepc": 0,
        "mtval": 0,
        "scause": 0,
        "sepc": 0,
        "stval": 0,
    }
    for raw in log_text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = SAIL_STEP_RE.match(line)
        if m:
            if cur is not None:
                steps.append(cur)
            cur = {
                "step": int(m.group(1)),
                "priv": priv_str_to_int(m.group(2)),
                "pc": int(m.group(3), 16),
                "insn": int(m.group(4), 16),
                "disasm": m.group(5).strip(),
                "gpr_writes": [],
                "fpr_writes": [],
                "vrf_writes": [],
                "trapped": False,
                "exc_name": None,
                "exc_priv": None,
                "csr_state": dict(state),
            }
            continue

        if cur is None:
            # Capture reset CSR writes if any before step [0]
            cm = SAIL_CSR_RE.match(line)
            if cm:
                name = cm.group(1)
                val = int(cm.group(3), 16)
                if name in state:
                    state[name] = val
                elif name == "fcsr":
                    state["fflags"] = val & 0x1F
            continue

        if (gm := SAIL_GPR_RE.match(line)):
            cur["gpr_writes"].append((int(gm.group(1)), int(gm.group(2), 16)))
        elif (fm := SAIL_FPR_RE.match(line)):
            cur["fpr_writes"].append((int(fm.group(1)), int(fm.group(2), 16)))
        elif (vm := SAIL_VRF_RE.match(line)):
            cur["vrf_writes"].append((int(vm.group(1)), vm.group(2).lower().zfill(64)))
        elif (em := SAIL_EXC_RE.match(line)):
            cur["trapped"] = True
            cur["exc_name"] = em.group(1)
            cur["exc_priv"] = priv_str_to_int(em.group(2))
        elif (cm := SAIL_CSR_RE.match(line)):
            name = cm.group(1)
            val = int(cm.group(3), 16)
            if name in state:
                state[name] = val
            elif name == "fcsr":
                state["fflags"] = val & 0x1F
            cur["csr_state"] = dict(state)

    if cur is not None:
        steps.append(cur)
    return steps


def build_verilator_tb() -> Path:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    obj_dir = BUILD_DIR / "obj_dir"
    exe = obj_dir / "Vfursoy_s1_core"
    cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "-j",
        "4",
        "-Wno-UNOPTFLAT",
        "-Wno-WIDTH",
        "-Wno-CASEINCOMPLETE",
        "--x-assign",
        "0",
        "--x-initial",
        "0",
        "-CFLAGS",
        "-O3",
        "-Irtl/core",
        "--top-module",
        "fursoy_s1_core",
        "--Mdir",
        str(obj_dir),
        *map(str, CORE_RTL),
        str(TB_CPP),
    ]
    print("[SAIL-COSIM] Compiling Vfursoy_s1_core differential harness with Verilator (-O3 -j4)...")
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Verilator build failed:\n{res.stdout}\n{res.stderr}")
    return exe


def compare_traces(name: str, sail_steps: list[dict], fursoy_events: list[dict]) -> dict:
    if not sail_steps:
        raise RuntimeError(f"[{name}] Sail produced 0 traced instructions!")
    if len(fursoy_events) < len(sail_steps):
        raise RuntimeError(
            f"[{name}] Fursoy retired {len(fursoy_events)} events < Sail {len(sail_steps)} steps!"
        )

    mismatches: list[str] = []
    traps_checked = 0
    gprs_checked = 0
    fprs_checked = 0
    vrfs_checked = 0

    for idx, s in enumerate(sail_steps):
        f = fursoy_events[idx]
        f_pc = int(f["pc"], 16)
        if f_pc != s["pc"]:
            mismatches.append(
                f"step {idx} ({s['disasm']}): PC mismatch sail=0x{s['pc']:x} vs fursoy=0x{f_pc:x}"
            )
            break

        if s["trapped"]:
            if f["type"] != "trap":
                mismatches.append(
                    f"step {idx} ({s['disasm']}) at 0x{s['pc']:x}: Sail trapped ({s['exc_name']}) but Fursoy retired!"
                )
                break
            traps_checked += 1
            exp_priv = s["exc_priv"]
            if exp_priv is not None and f.get("post_priv") != exp_priv:
                mismatches.append(
                    f"step {idx} trap priv mismatch at 0x{s['pc']:x}: "
                    f"sail_priv={exp_priv} vs fursoy_post_priv={f.get('post_priv')}"
                )
                break
            if exp_priv == 1:
                sail_scause = s["csr_state"]["scause"]
                sail_sepc = s["csr_state"]["sepc"]
                fur_scause = int(f["scause"], 16)
                fur_sepc = int(f["sepc"], 16)
                if fur_scause != sail_scause or fur_sepc != sail_sepc:
                    mismatches.append(
                        f"step {idx} delegated S-mode trap CSR mismatch at 0x{s['pc']:x}: "
                        f"sail(scause=0x{sail_scause:x}, sepc=0x{sail_sepc:x}) vs "
                        f"fursoy(scause=0x{fur_scause:x}, sepc=0x{fur_sepc:x})"
                    )
                    break
                if fur_scause in (4, 6, 13, 15):
                    sail_stval = s["csr_state"]["stval"]
                    fur_stval = int(f["stval"], 16)
                    if fur_stval != sail_stval:
                        mismatches.append(
                            f"step {idx} delegated S-mode trap stval mismatch (cause={fur_scause}): "
                            f"sail=0x{sail_stval:x} vs fursoy=0x{fur_stval:x}"
                        )
                        break
            else:
                sail_mcause = s["csr_state"]["mcause"]
                sail_mepc = s["csr_state"]["mepc"]
                fur_mcause = int(f["mcause"], 16)
                fur_mepc = int(f["mepc"], 16)
                if fur_mcause != sail_mcause or fur_mepc != sail_mepc:
                    mismatches.append(
                        f"step {idx} trap CSR mismatch at 0x{s['pc']:x}: "
                        f"sail(mcause=0x{sail_mcause:x}, mepc=0x{sail_mepc:x}) vs "
                        f"fursoy(mcause=0x{fur_mcause:x}, mepc=0x{fur_mepc:x})"
                    )
                    break
                # Check mtval for memory faults (causes 4, 6, 13, 15)
                if fur_mcause in (4, 6, 13, 15):
                    sail_mtval = s["csr_state"]["mtval"]
                    fur_mtval = int(f["mtval"], 16)
                    if fur_mtval != sail_mtval:
                        mismatches.append(
                            f"step {idx} trap mtval mismatch (cause={fur_mcause}): "
                            f"sail=0x{sail_mtval:x} vs fursoy=0x{fur_mtval:x}"
                        )
                        break
            continue

        if f["type"] != "retire":
            mismatches.append(
                f"step {idx} ({s['disasm']}) at 0x{s['pc']:x}: Sail retired but Fursoy trapped cause={f['cause']}!"
            )
            break

        # Destination writeback comparison
        if s["gpr_writes"]:
            exp_rd, exp_val = s["gpr_writes"][-1]
            if exp_rd != 0:
                if f["rd"] != exp_rd or f["fp_dest"] != 0 or f["vec_dest"] != 0:
                    mismatches.append(
                        f"step {idx} ({s['disasm']}): dest mismatch sail x{exp_rd} vs "
                        f"fursoy(rd={f['rd']}, fp={f['fp_dest']}, vec={f['vec_dest']})"
                    )
                    break
                got_val = int(f["gpr"], 16)
                if got_val != exp_val:
                    mismatches.append(
                        f"step {idx} ({s['disasm']}) x{exp_rd} mismatch: sail=0x{exp_val:016x} vs fursoy=0x{got_val:016x}"
                    )
                    break
                gprs_checked += 1

        if s["fpr_writes"]:
            exp_fd, exp_val = s["fpr_writes"][-1]
            if f["rd"] != exp_fd or f["fp_dest"] != 1:
                mismatches.append(
                    f"step {idx} ({s['disasm']}): FP dest mismatch sail f{exp_fd} vs fursoy(rd={f['rd']}, fp={f['fp_dest']})"
                )
                break
            got_val = int(f["fpr"], 16)
            if got_val != exp_val:
                mismatches.append(
                    f"step {idx} ({s['disasm']}) f{exp_fd} mismatch: sail=0x{exp_val:016x} vs fursoy=0x{got_val:016x}"
                )
                break
            fprs_checked += 1

        if s["vrf_writes"]:
            exp_vd, exp_hex = s["vrf_writes"][-1]
            got_vd = f.get("vd", f["rd"])
            if got_vd != exp_vd or f["vec_dest"] != 1:
                mismatches.append(
                    f"step {idx} ({s['disasm']}): VRF dest mismatch sail v{exp_vd} vs fursoy(vd={got_vd}, vec={f['vec_dest']})"
                )
                break
            got_hex = f["vrf"].lower().removeprefix("0x").zfill(64)
            if got_hex != exp_hex:
                mismatches.append(
                    f"step {idx} ({s['disasm']}) v{exp_vd} mismatch:\n  sail  =0x{exp_hex}\n  fursoy=0x{got_hex}"
                )
                break
            vrfs_checked += 1

        # End-of-commit-cycle architectural CSR consistency checks (slot_last handles 2-wide concurrent commits)
        if f.get("slot_last", 1) == 1:
            if f["fflags"] != s["csr_state"]["fflags"]:
                mismatches.append(
                    f"step {idx} ({s['disasm']}) fflags mismatch: sail=0x{s['csr_state']['fflags']:x} vs fursoy=0x{f['fflags']:x}"
                )
                break
            if f["vl"] != s["csr_state"]["vl"]:
                mismatches.append(
                    f"step {idx} ({s['disasm']}) vl mismatch: sail={s['csr_state']['vl']} vs fursoy={f['vl']}"
                )
                break
            if int(f["vtype"], 16) != s["csr_state"]["vtype"]:
                mismatches.append(
                    f"step {idx} ({s['disasm']}) vtype mismatch: sail=0x{s['csr_state']['vtype']:x} vs fursoy={f['vtype']}"
                )
                break
            if int(f["satp"], 16) != s["csr_state"]["satp"]:
                mismatches.append(
                    f"step {idx} ({s['disasm']}) satp mismatch: sail=0x{s['csr_state']['satp']:x} vs fursoy={f['satp']}"
                )
                break

    return {
        "name": name,
        "matched": len(mismatches) == 0,
        "sail_steps": len(sail_steps),
        "fursoy_events": len(fursoy_events),
        "gprs_checked": gprs_checked,
        "fprs_checked": fprs_checked,
        "vrfs_checked": vrfs_checked,
        "traps_checked": traps_checked,
        "mismatches": mismatches,
    }


def main() -> int:
    start = time.time()
    if not SAIL_BIN.exists():
        print(f"ERROR: Missing sail_riscv_sim at {SAIL_BIN}", file=sys.stderr)
        return 1
    if not SAIL_CFG.exists():
        print(f"ERROR: Missing Fursoy Sail config at {SAIL_CFG}", file=sys.stderr)
        return 1

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    ld_path = BUILD_DIR / "link.ld"
    ld_path.write_text(LINKER_SCRIPT, encoding="utf-8")

    tb_exe = build_verilator_tb()
    results = []
    all_passed = True

    for name, src in WORKLOADS.items():
        print(f"\n[SAIL-COSIM] Running differential suite '{name}'...")
        asm_path = BUILD_DIR / f"{name}.S"
        elf_path = BUILD_DIR / f"{name}.elf"
        asm_path.write_text(src, encoding="utf-8")

        gcc_cmd = [
            "riscv64-unknown-elf-gcc",
            "-march=rv64imafdv_zba_zbb_zicsr_zifencei",
            "-mabi=lp64d",
            "-mcmodel=medany",
            "-mno-relax",
            "-nostdlib",
            "-nostartfiles",
            "-Wl,--no-relax",
            "-Wl,--build-id=none",
            "-T",
            str(ld_path),
            str(asm_path),
            "-o",
            str(elf_path),
        ]
        res = subprocess.run(gcc_cmd, cwd=ROOT, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"GCC failed on {name}:\n{res.stdout}\n{res.stderr}")

        htif_pc = get_symbol_address(elf_path, "_htif_halt")
        segs = parse_elf_segments(elf_path, BUILD_DIR, name)

        # 1. Run Sail Golden Reference
        sail_log_path = BUILD_DIR / f"{name}.sail.log"
        sail_cmd = [
            str(SAIL_BIN),
            "--config",
            str(SAIL_CFG),
            "--trace-instr",
            "--trace-arch-regs",
            "--trace-csr",
            "--trace-exception",
            "--trace-output",
            str(sail_log_path),
            str(elf_path),
        ]
        sail_res = subprocess.run(sail_cmd, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if sail_res.returncode != 0:
            raise RuntimeError(
                f"Sail simulation failed (rc={sail_res.returncode}) on {name}:\n{sail_res.stdout}\n{sail_res.stderr}"
            )
        if "SUCCESS" not in (sail_res.stdout + sail_res.stderr):
            raise RuntimeError(f"Sail test '{name}' did not exit with HTIF SUCCESS:\n{sail_res.stdout}\n{sail_res.stderr}")

        # 2. Run Fursoy Slice-1 RTL
        fur_trace_path = BUILD_DIR / f"{name}.fursoy.jsonl"
        tb_cmd = [str(tb_exe), "--trace-out", str(fur_trace_path), "--htif-pc", f"{htif_pc:x}", "--max-cycles", "200000"]
        for paddr, seg_path in segs:
            tb_cmd.extend(["--seg", f"{paddr:x}:{seg_path}"])
        tb_res = subprocess.run(tb_cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
        if tb_res.returncode != 0:
            raise RuntimeError(
                f"Fursoy cosim TB failed (rc={tb_res.returncode}) on {name}:\n{tb_res.stdout}\n{tb_res.stderr}"
            )

        sail_steps = parse_sail_trace(sail_log_path.read_text(encoding="utf-8"))
        fur_events = [
            json.loads(line)
            for line in fur_trace_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        summary = compare_traces(name, sail_steps, fur_events)
        results.append(summary)
        if summary["matched"]:
            print(
                f"  [PASS] {name}: {summary['sail_steps']} instructions matched 1-to-1 "
                f"(GPR={summary['gprs_checked']}, FPR={summary['fprs_checked']}, "
                f"VRF={summary['vrfs_checked']}, Traps={summary['traps_checked']}, 0 mismatches)"
            )
        else:
            all_passed = False
            print(f"  [FAIL] {name}: {summary['mismatches'][0]}")

    report = {
        "status": "pass" if all_passed else "fail",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - start, 2),
        "sail_version": subprocess.run([str(SAIL_BIN), "--version"], capture_output=True, text=True).stdout.strip(),
        "workloads": results,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if all_passed:
        print("\n=============================================================================")
        print("SAIL-RISCV DIFFERENTIAL CO-SIMULATION PASSED (0 MISMATCHES)")
        print("=============================================================================")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
