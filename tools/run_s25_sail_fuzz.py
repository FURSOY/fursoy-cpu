#!/usr/bin/env python3
"""
Fursoy S2.5-M2a Multi-Seed >=100k-Instruction Sail-RISC-V Lockstep Fuzzer.

Generates constrained-random RV64IMAFD + Zba + Zbb ELF programs across 20
independent logged seeds (retiring >= 5,500 instructions per seed, >= 110,000
total retired instructions) and verifies every single commit and synchronous
trap 1-to-1 against `sail-riscv v0.16`:
  - PC, GPR writeback, full 64-bit FPR writeback (including SP NaN-boxing)
  - fflags, frm, mstatus, satp
  - Synchronous traps (ecall, illegal instruction, misaligned load/store:
    mcause, mepc, mtval, mstatus, post_priv)

Exercises genuine OoO stress: dense RAW/WAW/WAR chains, 2W superscalar bursts,
back-to-back MUL/DIV/FMA/FDIV/FSQRT, all 5 IEEE-754 rounding modes + dynamic
frm, store-to-load forwarding & 4 KiB-strided L1D conflict evictions, RV64A
LR/SC + AMO, data-dependent branches & loops inducing BPU mispredict flushes,
and jal/jalr leaf calls.

Writes structured proof metrics to results/s25-sail-fuzz.json.
"""

from __future__ import annotations

import json
import random
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

from run_s1_sail_cosim import (
    BUILD_DIR as SAIL_BUILD_DIR,
    COMMON_HTIF_MACROS,
    LINKER_SCRIPT,
    SAIL_BIN,
    SAIL_CFG,
    TB_CPP,
    build_verilator_tb,
    compare_traces,
    get_symbol_address,
    parse_elf_segments,
    parse_sail_trace,
)
from s1_rtl_manifest import CORE_RTL, ROOT
from s2_verilator_lib import compute_rtl_sha256, get_build_jobs

BUILD_DIR = ROOT / "build/s25_sail_fuzz"
REPORT_PATH = ROOT / "results/s25-sail-fuzz.json"

NUM_SEEDS = 20
BASE_SEED = 0x2502A001
BLOCKS_PER_SEED = 95

# Active register pools (reserve x1=ra, x2=sp [scratch base], x3=loop_ctr, x4=helper_tmp)
GPRS = [f"x{i}" for i in range(5, 32)]
FPRS = [f"f{i}" for i in range(0, 32)]
RMS = ["rne", "rtz", "rdn", "rup", "rmm", "dyn"]

ALU_RR = [
    "add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
    "addw", "subw", "sllw", "srlw", "sraw",
]
ALU_RI = ["addi", "slti", "sltiu", "xori", "ori", "andi", "addiw"]
SHIFT_I64 = ["slli", "srli", "srai", "rori"]
SHIFT_I32 = ["slliw", "srliw", "sraiw", "roriw"]
MULDIV_RR = [
    "mul", "mulh", "mulhsu", "mulhu", "mulw",
    "div", "divu", "rem", "remu", "divw", "divuw", "remw", "remuw",
]
ZBA_RR = ["add.uw", "sh1add", "sh1add.uw", "sh2add", "sh2add.uw", "sh3add", "sh3add.uw"]
ZBB_RR = ["andn", "orn", "xnor", "max", "maxu", "min", "minu", "rol", "rolw", "ror", "rorw"]
ZBB_U = ["clz", "clzw", "ctz", "ctzw", "cpop", "cpopw", "sext.b", "sext.h", "zext.h", "orc.b", "rev8"]
AMO_OPS = [
    "amoswap.w", "amoadd.w", "amoxor.w", "amoand.w", "amoor.w",
    "amomin.w", "amomax.w", "amominu.w", "amomaxu.w",
    "amoswap.d", "amoadd.d", "amoxor.d", "amoand.d", "amoor.d",
    "amomin.d", "amomax.d", "amominu.d", "amomaxu.d",
]


def _pick_reg(rng: random.Random, pool: list[str], hot: list[str], hot_prob: float = 0.55) -> str:
    if hot and rng.random() < hot_prob:
        return rng.choice(hot)
    return rng.choice(pool)


def _rand_fp64_bits(rng: random.Random) -> int:
    cat = rng.randrange(12)
    sign = rng.randrange(2) << 63
    if cat == 0:
        return sign  # +-0.0
    if cat == 1:
        return sign | (0x7FF << 52)  # +-Inf
    if cat == 2:
        return 0x7FF8000000000000  # qNaN
    if cat == 3:
        return sign | rng.randint(1, (1 << 52) - 1)  # subnormal
    if cat == 4:
        return sign | (rng.randint(1018, 1028) << 52) | rng.randrange(1 << 52)  # near 1.0
    if cat == 5:
        return sign | (rng.randint(1, 5) << 52) | rng.randrange(1 << 52)  # tiny normal
    if cat == 6:
        return sign | (rng.randint(2041, 2046) << 52) | rng.randrange(1 << 52)  # huge normal
    return sign | (rng.randint(960, 1088) << 52) | rng.randrange(1 << 52)


def _rand_fp32_bits(rng: random.Random) -> int:
    cat = rng.randrange(12)
    sign = rng.randrange(2) << 31
    if cat == 0:
        return sign
    if cat == 1:
        return sign | (0xFF << 23)
    if cat == 2:
        return 0x7FC00000
    if cat == 3:
        return sign | rng.randint(1, 0x007FFFFF)
    if cat == 4:
        return sign | (rng.randint(123, 132) << 23) | rng.randrange(1 << 23)
    if cat == 5:
        return sign | (rng.randint(1, 4) << 23) | rng.randrange(1 << 23)
    if cat == 6:
        return sign | (rng.randint(250, 254) << 23) | rng.randrange(1 << 23)
    return sign | (rng.randint(100, 155) << 23) | rng.randrange(1 << 23)


def generate_fuzz_program(seed: int) -> str:
    rng = random.Random(seed)
    lines: list[str] = [
        COMMON_HTIF_MACROS,
        ".section .text.init",
        ".globl _start",
        "_start:",
        "    # Configure M-mode trap handler and enable FS=01 (mstatus = 0x3800)",
        "    la   t0, fuzz_trap_handler",
        "    csrw mtvec, t0",
        "    li   t0, 0x00003800",
        "    csrw mstatus, t0",
        "    csrw fcsr, zero",
        "    la   sp, fuzz_scratch",
        "    li   x4, 0",
    ]

    # Seed initial GPRs & FPRs with rich corners + random values
    interesting_gprs = [
        0, 1, -1, 0x7FFFFFFF, -0x80000000,
        0x7FFFFFFFFFFFFFFF, -0x8000000000000000,
        0x00000000FFFFFFFF, -0x100000000,
        0x5555555555555555, -0x5555555555555556,
    ]
    for idx, reg in enumerate(GPRS):
        val = interesting_gprs[idx] if idx < len(interesting_gprs) else rng.getrandbits(64)
        lines.append(f"    li   {reg}, 0x{val & 0xFFFFFFFFFFFFFFFF:016x}")

    lines.append("    la   t0, fuzz_fp_init")
    for idx, freg in enumerate(FPRS):
        if idx % 2 == 0:
            lines.append(f"    fld  {freg}, {idx * 8}(t0)")
        else:
            lines.append(f"    flw  {freg}, {idx * 8}(t0)")

    # Generate randomized hot blocks with dense OoO hazards, loops, branches, mem, atomics, FP, traps
    for blk in range(BLOCKS_PER_SEED):
        hot_g = rng.sample(GPRS, 5)
        hot_f = rng.sample(FPRS, 5)
        is_loop = (blk % 6 == 2)
        is_fwd_br = (blk % 5 == 1) and not is_loop
        lbl_top = f"blk_{blk}_top"
        lbl_skip = f"blk_{blk}_skip"

        if is_loop:
            iters = rng.randint(4, 9)
            lines.append(f"    li   x3, {iters}")
            lines.append(f"{lbl_top}:")
        elif is_fwd_br:
            ra = _pick_reg(rng, GPRS, hot_g)
            rb = _pick_reg(rng, GPRS, hot_g)
            br_op = rng.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            lines.append(f"    {br_op} {ra}, {rb}, {lbl_skip}")

        n_ops = rng.randint(18, 28) if is_loop else rng.randint(24, 38)
        for _ in range(n_ops):
            roll = rng.randrange(100)
            if roll < 22:
                # RV64I ALU / shifts
                sub = rng.randrange(4)
                rd = _pick_reg(rng, GPRS, hot_g)
                rs1 = _pick_reg(rng, GPRS, hot_g)
                if sub == 0:
                    rs2 = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    {rng.choice(ALU_RR)} {rd}, {rs1}, {rs2}")
                elif sub == 1:
                    imm = rng.randint(-2048, 2047)
                    lines.append(f"    {rng.choice(ALU_RI)} {rd}, {rs1}, {imm}")
                elif sub == 2:
                    sh = rng.randint(0, 63)
                    lines.append(f"    {rng.choice(SHIFT_I64)} {rd}, {rs1}, {sh}")
                else:
                    sh = rng.randint(0, 31)
                    lines.append(f"    {rng.choice(SHIFT_I32)} {rd}, {rs1}, {sh}")
            elif roll < 36:
                # Zba / Zbb
                sub = rng.randrange(4)
                rd = _pick_reg(rng, GPRS, hot_g)
                rs1 = _pick_reg(rng, GPRS, hot_g)
                if sub == 0:
                    rs2 = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    {rng.choice(ZBA_RR)} {rd}, {rs1}, {rs2}")
                elif sub == 1:
                    rs2 = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    {rng.choice(ZBB_RR)} {rd}, {rs1}, {rs2}")
                elif sub == 2:
                    lines.append(f"    {rng.choice(ZBB_U)} {rd}, {rs1}")
                else:
                    sh = rng.randint(0, 63)
                    lines.append(f"    slli.uw {rd}, {rs1}, {sh}")
            elif roll < 47:
                # RV64M MUL / DIV / REM (with occasional corner injection)
                rd = _pick_reg(rng, GPRS, hot_g)
                rs1 = _pick_reg(rng, GPRS, hot_g)
                rs2 = _pick_reg(rng, GPRS, hot_g)
                if rng.randrange(12) == 0:
                    lines.append(f"    li   {rs2}, {rng.choice([0, -1, 1, 7])}")
                lines.append(f"    {rng.choice(MULDIV_RR)} {rd}, {rs1}, {rs2}")
            elif roll < 64:
                # Memory: store-to-load forwarding + 4 KiB-strided L1D conflict evictions
                sub = rng.randrange(5)
                if sub == 0:
                    # Aligned store + dependent load to overlapping address (forwarding!)
                    off = rng.choice([0, 8, 16, 24, 32, 40, 48, 56, 64, 128, 256, 512])
                    rs = _pick_reg(rng, GPRS, hot_g)
                    rd = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    sd   {rs}, {off}(sp)")
                    ld_op, sub_off = rng.choice([
                        ("ld", 0), ("lw", 0), ("lwu", 4), ("lh", 2), ("lhu", 6), ("lb", 1), ("lbu", 7)
                    ])
                    lines.append(f"    {ld_op}  {rd}, {off + sub_off}(sp)")
                elif sub == 1:
                    # Subword store followed by wider/narrower load
                    off = rng.choice([0, 8, 16, 24, 32, 48, 64, 96])
                    rs = _pick_reg(rng, GPRS, hot_g)
                    rd = _pick_reg(rng, GPRS, hot_g)
                    st_op, st_sub = rng.choice([("sb", 3), ("sh", 2), ("sw", 4), ("sw", 0)])
                    lines.append(f"    {st_op}  {rs}, {off + st_sub}(sp)")
                    lines.append(f"    ld   {rd}, {off}(sp)")
                elif sub == 2:
                    # 4 KiB-strided conflict access across 5 ways in same L1D set (forces evictions!)
                    set_off = rng.choice([0, 64, 128, 192])
                    way_stride = rng.choice([0, 4096, 8192, 12288, 16384])
                    rs = _pick_reg(rng, GPRS, hot_g)
                    rd = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    li   x4, {way_stride + set_off}")
                    lines.append("    add  x4, sp, x4")
                    lines.append(f"    sd   {rs}, 0(x4)")
                    lines.append(f"    ld   {rd}, 0(x4)")
                elif sub == 3:
                    # FP load/store (NaN-boxing on flw!)
                    off = rng.choice([0, 8, 16, 24, 32, 40, 48, 56])
                    fs = _pick_reg(rng, FPRS, hot_f)
                    fd = _pick_reg(rng, FPRS, hot_f)
                    if rng.randrange(2) == 0:
                        lines.append(f"    fsd  {fs}, {off}(sp)")
                        lines.append(f"    fld  {fd}, {off}(sp)")
                    else:
                        lines.append(f"    fsw  {fs}, {off}(sp)")
                        lines.append(f"    flw  {fd}, {off}(sp)")
                else:
                    # Random aligned scalar load/store
                    op, align = rng.choice([
                        ("lb", 1), ("lbu", 1), ("lh", 2), ("lhu", 2),
                        ("lw", 4), ("lwu", 4), ("ld", 8),
                        ("sb", 1), ("sh", 2), ("sw", 4), ("sd", 8),
                    ])
                    off = rng.randrange(0, 1024, align)
                    r = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    {op}  {r}, {off}(sp)")
            elif roll < 72:
                # RV64A Atomics (LR/SC + AMO + FENCE)
                off = rng.choice([0, 8, 16, 24, 64, 128, 256])
                lines.append(f"    addi x4, sp, {off}")
                sub = rng.randrange(3)
                if sub == 0:
                    rd = _pick_reg(rng, GPRS, hot_g)
                    rs = _pick_reg(rng, GPRS, hot_g)
                    lines.append(f"    {rng.choice(AMO_OPS)} {rd}, {rs}, (x4)")
                elif sub == 1:
                    rd1 = _pick_reg(rng, GPRS, hot_g)
                    rd2 = _pick_reg(rng, GPRS, hot_g)
                    rs = _pick_reg(rng, GPRS, hot_g)
                    if rng.randrange(2) == 0:
                        lines.append(f"    lr.d {rd1}, (x4)")
                        lines.append(f"    sc.d {rd2}, {rs}, (x4)")
                    else:
                        lines.append(f"    lr.w {rd1}, (x4)")
                        lines.append(f"    sc.w {rd2}, {rs}, (x4)")
                else:
                    lines.append("    fence rw, rw")
            elif roll < 96:
                # RV64FD Floating-Point (FMA, FDIV, FSQRT, FCONV, CMP, SGNJ, MIN/MAX, CLASS, FMV, dynamic frm)
                sub = rng.randrange(9)
                fd = _pick_reg(rng, FPRS, hot_f)
                f1 = _pick_reg(rng, FPRS, hot_f)
                f2 = _pick_reg(rng, FPRS, hot_f)
                f3 = _pick_reg(rng, FPRS, hot_f)
                rm = rng.choice(RMS)
                if sub == 0:
                    op = rng.choice(["fadd.s", "fsub.s", "fmul.s", "fadd.d", "fsub.d", "fmul.d"])
                    lines.append(f"    {op} {fd}, {f1}, {f2}, {rm}")
                elif sub == 1:
                    op = rng.choice(["fmadd.s", "fmsub.s", "fnmadd.s", "fnmsub.s", "fmadd.d", "fmsub.d", "fnmadd.d", "fnmsub.d"])
                    lines.append(f"    {op} {fd}, {f1}, {f2}, {f3}, {rm}")
                elif sub == 2:
                    op = rng.choice(["fdiv.s", "fdiv.d", "fsqrt.s", "fsqrt.d"])
                    if "sqrt" in op:
                        lines.append(f"    {op} {fd}, {f1}, {rm}")
                    else:
                        lines.append(f"    {op} {fd}, {f1}, {f2}, {rm}")
                elif sub == 3:
                    op = rng.choice(["fsgnj.s", "fsgnjn.s", "fsgnjx.s", "fmin.s", "fmax.s",
                                     "fsgnj.d", "fsgnjn.d", "fsgnjx.d", "fmin.d", "fmax.d"])
                    lines.append(f"    {op} {fd}, {f1}, {f2}")
                elif sub == 4:
                    rd = _pick_reg(rng, GPRS, hot_g)
                    op = rng.choice(["feq.s", "flt.s", "fle.s", "feq.d", "flt.d", "fle.d"])
                    lines.append(f"    {op} {rd}, {f1}, {f2}")
                elif sub == 5:
                    rd = _pick_reg(rng, GPRS, hot_g)
                    op = rng.choice(["fcvt.w.s", "fcvt.wu.s", "fcvt.l.s", "fcvt.lu.s",
                                     "fcvt.w.d", "fcvt.wu.d", "fcvt.l.d", "fcvt.lu.d"])
                    lines.append(f"    {op} {rd}, {f1}, {rm}")
                elif sub == 6:
                    rs = _pick_reg(rng, GPRS, hot_g)
                    op = rng.choice(["fcvt.s.w", "fcvt.s.wu", "fcvt.s.l", "fcvt.s.lu",
                                     "fcvt.d.w", "fcvt.d.wu", "fcvt.d.l", "fcvt.d.lu"])
                    if op in ("fcvt.d.w", "fcvt.d.wu"):
                        lines.append(f"    {op} {fd}, {rs}")
                    else:
                        lines.append(f"    {op} {fd}, {rs}, {rm}")
                elif sub == 7:
                    choice = rng.randrange(5)
                    if choice == 0:
                        lines.append(f"    fcvt.s.d {fd}, {f1}, {rm}")
                    elif choice == 1:
                        lines.append(f"    fcvt.d.s {fd}, {f1}")
                    elif choice == 2:
                        rd = _pick_reg(rng, GPRS, hot_g)
                        lines.append(f"    {rng.choice(['fclass.s', 'fclass.d', 'fmv.x.w', 'fmv.x.d'])} {rd}, {f1}")
                    elif choice == 3:
                        rs = _pick_reg(rng, GPRS, hot_g)
                        lines.append(f"    {rng.choice(['fmv.w.x', 'fmv.d.x'])} {fd}, {rs}")
                    else:
                        # Update dynamic frm & read/clear fflags
                        new_frm = rng.randrange(5)
                        lines.append(f"    csrr x4, fflags")
                        lines.append(f"    li   x4, {new_frm}")
                        lines.append("    csrw frm, x4")
                        lines.append("    csrw fflags, zero")
                else:
                    # Periodic reload of fresh corner FP bits so values don't saturate to NaN/Inf forever
                    off = rng.randrange(0, 32) * 8
                    lines.append("    la   x4, fuzz_fp_init")
                    if rng.randrange(2) == 0:
                        lines.append(f"    fld  {fd}, {off}(x4)")
                    else:
                        lines.append(f"    flw  {fd}, {off}(x4)")
            else:
                # Call leaf helper via jal / jalr
                if rng.randrange(2) == 0:
                    lines.append("    jal  ra, fuzz_leaf_helper")
                else:
                    lines.append("    la   x4, fuzz_leaf_helper")
                    lines.append("    jalr ra, 0(x4)")

        if is_loop:
            lines.append("    addi x3, x3, -1")
            lines.append(f"    bnez x3, {lbl_top}")
        elif is_fwd_br:
            lines.append(f"{lbl_skip}:")

        # Periodic controlled synchronous traps (ecall, illegal insn, misaligned lw/sw)
        if blk % 15 == 7:
            lines.append("    ecall")
        elif blk % 15 == 11:
            lines.append("    .word 0xffffffff")
        elif blk % 15 == 14:
            rd = _pick_reg(rng, GPRS, hot_g)
            rs = _pick_reg(rng, GPRS, hot_g)
            lines.append(f"    lw   {rd}, 2(sp)")
            lines.append(f"    sw   {rs}, 1(sp)")

    lines.append("    HTIF_EXIT 0")
    lines.append("")
    lines.append(".align 4")
    lines.append("fuzz_leaf_helper:")
    lines.append("    add  x5, x5, x6")
    lines.append("    xor  x7, x7, x5")
    lines.append("    ret")
    lines.append("")
    lines.append(".align 4")
    lines.append("fuzz_trap_handler:")
    lines.append("    csrr x4, mepc")
    lines.append("    addi x4, x4, 4")
    lines.append("    csrw mepc, x4")
    lines.append("    mret")
    lines.append("")
    lines.append(".section .data")
    lines.append(".align 6")
    lines.append("fuzz_fp_init:")
    for i in range(32):
        if i % 2 == 0:
            bits = _rand_fp64_bits(rng)
        else:
            # Mix boxed and occasional unboxed 32-bit patterns
            lo = _rand_fp32_bits(rng)
            hi = 0xFFFFFFFF if (i % 6 != 5) else rng.getrandbits(32)
            bits = (hi << 32) | lo
        lines.append(f"    .quad 0x{bits:016x}")

    lines.append(".section .bss")
    lines.append(".align 12")
    lines.append("fuzz_scratch:")
    lines.append("    .zero 20480")
    return "\n".join(lines) + "\n"


def _ensure_verilator_tb() -> Path:
    exe = SAIL_BUILD_DIR / "obj_dir" / "Vfursoy_s1_core"
    if exe.exists():
        exe_mtime = exe.stat().st_mtime
        deps = [*CORE_RTL, TB_CPP]
        if all(p.exists() and p.stat().st_mtime <= exe_mtime for p in deps):
            print(f"[FUZZ] Reusing fresh Vfursoy_s1_core harness at {exe.relative_to(ROOT)}")
            return exe
    return build_verilator_tb()


def run_one_seed(seed: int, tb_exe_str: str, ld_path_str: str) -> dict:
    t0 = time.time()
    name = f"seed_{seed:08x}"
    seed_dir = BUILD_DIR / name
    seed_dir.mkdir(parents=True, exist_ok=True)
    asm_path = seed_dir / f"{name}.S"
    elf_path = seed_dir / f"{name}.elf"

    asm_path.write_text(generate_fuzz_program(seed), encoding="utf-8")

    gcc_cmd = [
        "riscv64-unknown-elf-gcc",
        "-march=rv64imafd_zba_zbb_zicsr_zifencei",
        "-mabi=lp64d",
        "-mcmodel=medany",
        "-mno-relax",
        "-nostdlib",
        "-nostartfiles",
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
        "-T",
        ld_path_str,
        str(asm_path),
        "-o",
        str(elf_path),
    ]
    r_gcc = subprocess.run(gcc_cmd, cwd=ROOT, capture_output=True, text=True)
    if r_gcc.returncode != 0:
        raise RuntimeError(f"GCC failed on {name}:\n{r_gcc.stdout}\n{r_gcc.stderr}")

    htif_pc = get_symbol_address(elf_path, "_htif_halt")
    segs = parse_elf_segments(elf_path, seed_dir, name)

    sail_log_path = seed_dir / f"{name}.sail.log"
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
    r_sail = subprocess.run(sail_cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
    if r_sail.returncode != 0 or "SUCCESS" not in (r_sail.stdout + r_sail.stderr):
        raise RuntimeError(f"Sail failed on {name} (rc={r_sail.returncode}):\n{r_sail.stdout}\n{r_sail.stderr}")

    fur_trace_path = seed_dir / f"{name}.fursoy.jsonl"
    tb_cmd = [
        tb_exe_str,
        "--trace-out",
        str(fur_trace_path),
        "--htif-pc",
        f"{htif_pc:x}",
        "--max-cycles",
        "1000000",
    ]
    for pa, sp in segs:
        tb_cmd.extend(["--seg", f"{pa:x}:{sp}"])
    r_tb = subprocess.run(tb_cmd, cwd=ROOT, capture_output=True, text=True, timeout=180)
    if r_tb.returncode != 0:
        raise RuntimeError(f"Fursoy TB failed on {name} (rc={r_tb.returncode}):\n{r_tb.stdout}\n{r_tb.stderr}")

    sail_steps = parse_sail_trace(sail_log_path.read_text(encoding="utf-8"))
    fur_events = [
        json.loads(line)
        for line in fur_trace_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    summary = compare_traces(name, sail_steps, fur_events)
    summary["seed"] = f"0x{seed:08x}"
    summary["elapsed_s"] = round(time.time() - t0, 2)

    # Clean large trace logs on pass to keep build/ disk usage light
    if summary["matched"]:
        sail_log_path.unlink(missing_ok=True)
        fur_trace_path.unlink(missing_ok=True)
    return summary


def main() -> int:
    t0 = time.time()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    ld_path = BUILD_DIR / "link.ld"
    ld_path.write_text(LINKER_SCRIPT, encoding="utf-8")

    tb_exe = _ensure_verilator_tb()
    seeds = [BASE_SEED + i for i in range(NUM_SEEDS)]
    workers = get_build_jobs()
    print(f"[FUZZ] Running {NUM_SEEDS} independent constrained-random RV64IMAFD+Zba+Zbb seeds (workers={workers})...")

    results_by_seed: dict[int, dict] = {}
    with ProcessPoolExecutor(max_workers=workers) as ex:
        fut_map = {ex.submit(run_one_seed, s, str(tb_exe), str(ld_path)): s for s in seeds}
        for fut in as_completed(fut_map):
            s = fut_map[fut]
            res = fut.result()
            results_by_seed[s] = res
            status = "PASS" if res["matched"] else "FAIL"
            detail = (
                f"{res['sail_steps']} insts (GPR={res['gprs_checked']}, FPR={res['fprs_checked']}, "
                f"Traps={res['traps_checked']}, 0 mismatches, {res['elapsed_s']}s)"
                if res["matched"]
                else res["mismatches"][0]
            )
            print(f"  [{status}] 0x{s:08x}: {detail}", flush=True)

    ordered = [results_by_seed[s] for s in seeds]
    total_steps = sum(r["sail_steps"] for r in ordered)
    total_gprs = sum(r["gprs_checked"] for r in ordered)
    total_fprs = sum(r["fprs_checked"] for r in ordered)
    total_traps = sum(r["traps_checked"] for r in ordered)
    total_mismatches = sum(len(r["mismatches"]) for r in ordered)
    all_passed = (total_mismatches == 0) and all(r["matched"] for r in ordered) and (total_steps >= 100000)

    sail_ver = subprocess.run([str(SAIL_BIN), "--version"], capture_output=True, text=True).stdout.strip()
    report = {
        "milestone": "S2.5-M2a",
        "status": "pass" if all_passed else "fail",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - t0, 2),
        "rtl_sha256": compute_rtl_sha256(),
        "sail_version": sail_ver,
        "isa_coverage": "RV64IMAFD + Zba + Zbb + Zicsr (GPR, 64-bit FPR w/ NaN-box, fflags/frm/mstatus, sync traps)",
        "summary": {
            "num_seeds": NUM_SEEDS,
            "seeds_passed": sum(1 for r in ordered if r["matched"]),
            "total_retired_instructions": total_steps,
            "total_gprs_checked": total_gprs,
            "total_fprs_checked": total_fprs,
            "total_traps_checked": total_traps,
            "total_mismatches": total_mismatches,
        },
        "seeds": ordered,
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print("\n" + "=" * 84)
    print(
        f"SAIL LOCKSTEP FUZZER RESULT: {'PASS' if all_passed else 'FAIL'} "
        f"({total_steps:,} retired insts, GPR={total_gprs:,}, FPR={total_fprs:,}, "
        f"Traps={total_traps:,}, mismatches={total_mismatches})"
    )
    print(f"Report written: {REPORT_PATH.relative_to(ROOT)} (elapsed {report['elapsed_seconds']}s)")
    print("=" * 84)
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
