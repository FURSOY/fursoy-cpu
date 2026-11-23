#!/usr/bin/env python3
"""
Fursoy S2.5-M1b Synthesizable Arithmetic Hardening Verification & STA Runner.

Verifies the three S2.5-M1b arithmetic units:
  1. rtl/core/fursoy_s1_fdiv.sv       (Iterative Radix-4 restoring FDIV/FSQRT)
  2. rtl/core/fursoy_s1_vec_div.sv    (Iterative Radix-4 restoring RVV VDIV/VDIVU)
  3. rtl/core/fursoy_s1_multiplier.sv (3-stage pipelined 65x65 Booth+Wallace+KS)

Gates enforced:
  1. Static RTL audit: 0 behavioral '/' or '%' operators and 0 unrolled isqrt
     loops in fursoy_s1_fdiv.sv, fursoy_s1_multiplier.sv, fursoy_s1_vec_div.sv,
     and VEC_VDIV/VEC_VDIVU arms in fursoy_s1_core.sv.
  2. Yosys (Nangate45) + OpenSTA (500 MHz / 2.000 ns) proof: 0 '$div' and
     0 '$mod' cells (pre-ABC and mapped) and WNS >= 0.000 ns, TNS == 0.000 ns.
  3. Expanded sail-riscv v0.16 lockstep differential co-simulation across
     directed + seeded randomized FDIV/FSQRT, MUL*, and VDIV* workloads
     (0 mismatches required).

Outputs structured proof metrics to results/s25-m1b-arith.json.
"""

from __future__ import annotations

import json
import random
import re
import struct
import subprocess
import sys
import time
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
from s2_verilator_lib import compute_rtl_sha256

BUILD_DIR = ROOT / "build/s25_m1b_arith"
SYNTH_DIR = ROOT / "build/s25_m1b_synth"
REPORT_PATH = ROOT / "results/s25-m1b-arith.json"

LIB_PATH = ROOT / "tools/synth/lib/NangateOpenCellLibrary_typical.lib"
STA_BIN = ROOT / "tools/synth/bin/sta"
NAND2_AREA = 0.798
ABC_SCRIPT = "+strash;balance;&get,-n;&nf,{D};&put;buffer,-N,32,-S,90;upsize,{D};stime,-p"


def strip_sv_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def run_static_audit() -> dict:
    """Prove zero behavioral '/' or '%' operators and zero unrolled isqrt loops."""
    targets = [
        ("rtl/core/fursoy_s1_fdiv.sv", None),
        ("rtl/core/fursoy_s1_vec_div.sv", None),
        ("rtl/core/fursoy_s1_multiplier.sv", None),
        ("rtl/core/fursoy_s1_core.sv", ("VEC_VDIV", "VEC_VREM")),
    ]
    findings: list[str] = []
    checked: list[dict] = []

    for rel, window in targets:
        raw = (ROOT / rel).read_text(encoding="utf-8")
        if window is not None:
            start_tok, end_tok = window
            idx_s = raw.find(f"{start_tok}:")
            if idx_s < 0:
                idx_s = raw.find(start_tok)
            idx_e = raw.find(f"{end_tok}:", idx_s + 1) if idx_s >= 0 else -1
            snippet = raw[idx_s : idx_e if idx_e > idx_s else idx_s + 1200] if idx_s >= 0 else ""
            code = strip_sv_comments(snippet)
        else:
            code = strip_sv_comments(raw)

        # Ignore compiler directives/includes/strings when searching for '/' or '%'
        code_no_str = re.sub(r'"[^"]*"', '""', code)
        div_hits = re.findall(r"(?<![/\*])/(?![/\*])", code_no_str)
        mod_hits = re.findall(r"(?<!%)%(?!%)", code_no_str)
        isqrt_hits = re.findall(r"\bisqrt_(?:sp|dp)\b", code_no_str)

        if div_hits:
            findings.append(f"{rel}: found {len(div_hits)} behavioral '/' operator(s)")
        if mod_hits:
            findings.append(f"{rel}: found {len(mod_hits)} behavioral '%' operator(s)")
        if isqrt_hits:
            findings.append(f"{rel}: found unrolled isqrt helper(s): {isqrt_hits}")

        checked.append(
            {
                "file": rel,
                "scope": "full" if window is None else f"{window[0]}..{window[1]}",
                "slash_ops": len(div_hits),
                "mod_ops": len(mod_hits),
                "unrolled_isqrt": len(isqrt_hits),
            }
        )

    return {
        "passed": len(findings) == 0,
        "findings": findings,
        "files": checked,
    }


def run_synth_and_sta() -> dict:
    """Run canonical Yosys + OpenSTA (Nangate45, 500 MHz / 2.000 ns) on the 3 units."""
    SYNTH_DIR.mkdir(parents=True, exist_ok=True)
    constr_path = SYNTH_DIR / "abc.constr"
    constr_path.write_text("set_driving_cell BUF_X2\nset_load 2.0\n", encoding="utf-8")

    modules = [
        (
            "fursoy_s1_fdiv",
            [
                "rtl/core/fursoy_s1_pkg.sv",
                "rtl/core/fursoy_s1_ks_adder.sv",
                "rtl/core/fursoy_s1_fdiv.sv",
            ],
            "Iterative Parallel Radix-4 Restoring IEEE-754 FDIV/FSQRT (SP 17c / DP 31c)",
        ),
        (
            "fursoy_s1_vec_div",
            [
                "rtl/core/fursoy_s1_ks_adder.sv",
                "rtl/core/fursoy_s1_vec_div.sv",
            ],
            "Iterative Parallel Radix-4 Restoring RVV Element Divider (SEW=8/16/32/64)",
        ),
        (
            "fursoy_s1_multiplier",
            [
                "rtl/core/fursoy_s1_pkg.sv",
                "rtl/core/fursoy_s1_ks_adder.sv",
                "rtl/core/fursoy_s1_multiplier.sv",
            ],
            "3-Stage Pipelined 65x65 Signed Radix-4 Booth + 8-Level Wallace CSA + KS CPA",
        ),
    ]

    results = {}
    all_met = True

    for top, files, desc in modules:
        v_path = SYNTH_DIR / f"{top}.v"
        net_path = SYNTH_DIR / f"{top}_netlist.v"
        sta_tcl = SYNTH_DIR / f"{top}_sta.tcl"

        r_sv2v = subprocess.run(
            ["sv2v", "-DSYNTHESIS", "-I", "rtl/core", *files, "-w", str(v_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if r_sv2v.returncode != 0:
            raise RuntimeError(f"sv2v failed for {top}:\n{r_sv2v.stdout}\n{r_sv2v.stderr}")

        ys_cmd = (
            f"read_liberty -lib {LIB_PATH}; "
            f"read_verilog -defer {v_path}; "
            f"hierarchy -check -top {top}; "
            f"synth -top {top} -noabc; "
            f"stat; "
            f"dfflibmap -liberty {LIB_PATH}; "
            f"abc -D 1000 -constr {constr_path} -liberty {LIB_PATH} -script {ABC_SCRIPT}; "
            f"opt_clean -purge; "
            f"write_verilog -noattr -noexpr {net_path}; "
            f"stat -liberty {LIB_PATH}"
        )
        r_ys = subprocess.run(
            ["yosys", "-p", ys_cmd],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=360,
        )
        (SYNTH_DIR / f"{top}_synth.log").write_text(r_ys.stdout + r_ys.stderr, encoding="utf-8")
        if r_ys.returncode != 0:
            raise RuntimeError(f"yosys failed for {top}:\n{r_ys.stdout[-2000:]}\n{r_ys.stderr}")

        log = r_ys.stdout
        div_cells = len(re.findall(r"\$div\b", log))
        mod_cells = len(re.findall(r"\$mod\b", log))
        stat_sec = log.split("=== design hierarchy ===")[-1] if "=== design hierarchy ===" in log else log
        cell_count = int(re.findall(r"Number of cells:\s+(\d+)", stat_sec)[-1])
        dff_count = sum(int(x) for x in re.findall(r"DFF[A-Z0-9_]*_X\d+\s+(\d+)", stat_sec))
        area_um2 = float(re.findall(r"Chip area for (?:top )?module '.*':\s+([\d.]+)", stat_sec)[-1])
        kge = round(area_um2 / NAND2_AREA / 1000.0, 2)

        sta_tcl.write_text(
            f"read_liberty {LIB_PATH}\n"
            f"read_verilog {net_path}\n"
            f"link_design {top}\n"
            f"create_clock -name clk -period 2.0 [get_ports clk_i]\n"
            f"set_clock_uncertainty 0.05 [get_clocks clk]\n"
            f"set_input_delay -clock clk 0.2 [all_inputs -no_clocks]\n"
            f"set_output_delay -clock clk 0.2 [all_outputs]\n"
            f"report_checks -path_delay max -fields {{slew cap input_pins fanout}} -digits 3\n"
            f"report_wns\n"
            f"report_tns\n"
            f"exit\n",
            encoding="utf-8",
        )
        r_sta = subprocess.run(
            [str(STA_BIN), "-no_init", "-exit", str(sta_tcl)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=120,
        )
        (SYNTH_DIR / f"{top}_sta.log").write_text(r_sta.stdout + r_sta.stderr, encoding="utf-8")
        if r_sta.returncode != 0:
            raise RuntimeError(f"OpenSTA failed for {top}:\n{r_sta.stdout}\n{r_sta.stderr}")

        arr_ns = float(re.search(r"^\s*([\d.]+)\s+data arrival time", r_sta.stdout, re.M).group(1))
        m_slk = re.search(r"([-\d.]+)\s+slack \((MET|VIOLATED)\)", r_sta.stdout)
        slack_ns = float(m_slk.group(1))
        status = m_slk.group(2)
        wns_ns = float(re.search(r"wns max\s+([-\d.]+)", r_sta.stdout).group(1))
        tns_ns = float(re.search(r"tns max\s+([-\d.]+)", r_sta.stdout).group(1))
        fmax_mhz = round(1000.0 / (2.000 - slack_ns), 1)

        passed = (div_cells == 0) and (mod_cells == 0) and (slack_ns >= 0.0) and (tns_ns == 0.0)
        if not passed:
            all_met = False

        results[top] = {
            "description": desc,
            "yosys_div_cells": div_cells,
            "yosys_mod_cells": mod_cells,
            "cells": cell_count,
            "dffs": dff_count,
            "area_um2": round(area_um2, 2),
            "kge": kge,
            "target_period_ns": 2.0,
            "max_delay_ns": round(arr_ns, 3),
            "slack_ns": round(slack_ns, 3),
            "wns_ns": round(wns_ns, 3),
            "tns_ns": round(tns_ns, 3),
            "fmax_mhz": fmax_mhz,
            "timing_status": status,
            "passed": passed,
        }
        print(
            f"  [STA] {top:22s}: $div={div_cells} $mod={mod_cells} "
            f"cells={cell_count:6d} dffs={dff_count:4d} {kge:5.2f} kGE "
            f"arr={arr_ns:.3f}ns slack={slack_ns:+.3f}ns ({status}) "
            f"TNS={tns_ns:+.3f}ns Fmax={fmax_mhz:.1f} MHz"
        )

    return {"passed": all_met, "modules": results}


# -----------------------------------------------------------------------------
# Expanded Sail-RISC-V Lockstep Arithmetic Workload Generators
# -----------------------------------------------------------------------------
def _li64(reg: str, val: int) -> str:
    return f"    li   {reg}, 0x{val & 0xFFFFFFFFFFFFFFFF:016x}"


def _enable_fp_and_vec() -> str:
    return r"""    # Set MPP=11 (M-mode), FS=01 (bits 14:13), VS=01 (bits 10:9) in mstatus
    li   t0, 0x00003a00
    csrw mstatus, t0
    csrw fcsr, zero
"""


def gen_fdiv_fsqrt_directed() -> str:
    lines = [
        COMMON_HTIF_MACROS,
        ".section .text.init",
        ".globl _start",
        "_start:",
        _enable_fp_and_vec(),
    ]

    # 1. Special values & IEEE-754 flags (SP & DP)
    sp_specials = [
        ("pzero", 0x00000000),
        ("nzero", 0x80000000),
        ("pinf",  0x7F800000),
        ("ninf",  0xFF800000),
        ("pone",  0x3F800000),
        ("none",  0xBF800000),
        ("ptwo",  0x40000000),
        ("qnan",  0x7FC00000),
        ("snan",  0x7F800001),
        ("minsub",0x00000001),
        ("maxsub",0x007FFFFF),
        ("minnrm",0x00800000),
        ("maxfin",0x7F7FFFFF),
        ("tiny_n",0x00FFFFFF),  # exact tie for after-rounding tininess when / 2.0
        ("half",  0x3F000000),
        ("four",  0x40800000),
    ]
    sp_map = {k: v for k, v in sp_specials}

    def emit_sp_div(a_hex: int, b_hex: int, rm: str = "rne"):
        lines.append("    csrw fflags, zero")
        lines.append(f"    li   t0, 0x{a_hex:08x}")
        lines.append(f"    li   t1, 0x{b_hex:08x}")
        lines.append("    fmv.w.x f1, t0")
        lines.append("    fmv.w.x f2, t1")
        lines.append(f"    fdiv.s  f3, f1, f2, {rm}")
        lines.append("    csrr t2, fflags")

    def emit_sp_sqrt(a_hex: int, rm: str = "rne"):
        lines.append("    csrw fflags, zero")
        lines.append(f"    li   t0, 0x{a_hex:08x}")
        lines.append("    fmv.w.x f1, t0")
        lines.append(f"    fsqrt.s f3, f1, {rm}")
        lines.append("    csrr t2, fflags")

    # Directed SP special matrix (including Inf/0 -> 0 flags!)
    sp_div_pairs = [
        (sp_map["pinf"], sp_map["pzero"]),
        (sp_map["ninf"], sp_map["nzero"]),
        (sp_map["pinf"], sp_map["nzero"]),
        (sp_map["pzero"], sp_map["pzero"]),
        (sp_map["pinf"], sp_map["pinf"]),
        (sp_map["pinf"], sp_map["ninf"]),
        (sp_map["pone"], sp_map["pzero"]),
        (sp_map["none"], sp_map["pzero"]),
        (sp_map["pone"], sp_map["nzero"]),
        (sp_map["pzero"], sp_map["pone"]),
        (sp_map["nzero"], sp_map["pone"]),
        (sp_map["pone"], sp_map["pinf"]),
        (sp_map["pone"], sp_map["ninf"]),
        (sp_map["qnan"], sp_map["pone"]),
        (sp_map["pone"], sp_map["qnan"]),
        (sp_map["snan"], sp_map["pone"]),
        (sp_map["pone"], sp_map["snan"]),
        (sp_map["snan"], sp_map["pzero"]),
        # Subnormals
        (sp_map["minsub"], sp_map["minsub"]),
        (sp_map["maxsub"], sp_map["minsub"]),
        (sp_map["minsub"], sp_map["maxsub"]),
        (sp_map["maxsub"], sp_map["ptwo"]),
        (sp_map["minnrm"], sp_map["ptwo"]),
        (sp_map["minnrm"], 0x3F800001),
    ]
    for a, b in sp_div_pairs:
        emit_sp_div(a, b, "rne")

    # SP After-rounding tininess & overflow & underflow-to-zero across ALL 5 rounding modes
    for rm in ("rne", "rtz", "rdn", "rup", "rmm"):
        # Exact tie at subnormal/normal boundary: 0x00FFFFFF / 2.0
        emit_sp_div(sp_map["tiny_n"], sp_map["ptwo"], rm)
        emit_sp_div(sp_map["tiny_n"] | 0x80000000, sp_map["ptwo"], rm)
        # Overflow to Inf vs max_fin
        emit_sp_div(sp_map["maxfin"], sp_map["half"], rm)
        emit_sp_div(sp_map["maxfin"] | 0x80000000, sp_map["half"], rm)
        # Underflow to 0 vs min_sub
        emit_sp_div(sp_map["minsub"], sp_map["four"], rm)
        emit_sp_div(sp_map["minsub"] | 0x80000000, sp_map["four"], rm)
        # Exact halfway tie in normal range: (2^24 + 1) / 2.0? Use 3.0 / 2.0 exact and 0x3F800001 / 2.0?
        # 1.0 / 3.0, -1.0 / 3.0, 0x40800001 / 2.0 -> exact halfway tie when dividing odd mantissa?
        # Wait: normal mantissa has 24 bits; 0x3F800001 / 2.0 is exact (just decrements exp!).
        # Exact halfway tie for FDIV: (2^24 + 1) / 2^(something)? For 25-bit quotient = 1.xxxx...1000..:
        # Take (2^23 + 1) / 3 -> non-terminating; exact halfway tie:
        # 1 + 2^-24 is NOT representable; (1 + 2^-23) / (1 + 2^-1) = ...
        # Exact halfway tie in SP: a = 0x3F800003 (1 + 3*2^-23), b = 0x40400000 (3.0)? No.
        # Exact halfway tie: a = 0x3F800001 (1 + 2^-23), b = 0x40000000 is exact.
        # For a/b = (2^24 + 2k + 1) / 2^25 -> e.g., a = 1 + 2^-23 (0x3F800001) -> no, divisor 2^n is exact.
        # Divisor = 2^k * 5 -> never terminates; divisor = 2^k only terminates.
        # WAIT: a/b CAN hit exact halfway tie when a is subnormal or result is subnormal!
        # E.g. 0x00800001 / 2.0 = 0x00400000.5 -> EXACT HALFWAY TIE!
        emit_sp_div(0x00800001, sp_map["ptwo"], rm)
        emit_sp_div(0x00800003, sp_map["ptwo"], rm)
        emit_sp_div(0x80800001, sp_map["ptwo"], rm)
        emit_sp_div(0x3F800000, 0x40400000, rm)  # 1.0 / 3.0
        emit_sp_div(0xBF800000, 0x40400000, rm)  # -1.0 / 3.0
        emit_sp_sqrt(0x40000000, rm)             # sqrt(2.0)
        emit_sp_sqrt(0x40400000, rm)             # sqrt(3.0)
        emit_sp_sqrt(sp_map["minsub"], rm)
        emit_sp_sqrt(sp_map["maxsub"], rm)
        emit_sp_sqrt(sp_map["maxfin"], rm)

    # Directed SP FSQRT specials
    for a in (sp_map["pzero"], sp_map["nzero"], sp_map["pinf"], sp_map["ninf"],
              sp_map["none"], sp_map["qnan"], sp_map["snan"], sp_map["pone"],
              0x40800000, 0x41100000, sp_map["minnrm"]):
        emit_sp_sqrt(a, "rne")

    # Unboxed SP inputs (upper 32 bits != 0xFFFF_FFFF -> treated as canonical qNaN, NO NV!)
    lines.append("    csrw fflags, zero")
    lines.append(_li64("t0", 0x000000003F800000))  # unboxed 1.0f
    lines.append(_li64("t1", 0xFFFFFFFF40000000))  # boxed 2.0f
    lines.append("    fmv.d.x f1, t0")
    lines.append("    fmv.d.x f2, t1")
    lines.append("    fdiv.s  f3, f1, f2")
    lines.append("    fsqrt.s f4, f1")
    lines.append("    csrr t2, fflags")

    # Dynamic frm test via csrw frm
    for frm_val in range(5):
        lines.append(f"    li   t0, {frm_val}")
        lines.append("    csrw frm, t0")
        lines.append("    csrw fflags, zero")
        lines.append("    li   t1, 0x3F800000")
        lines.append("    li   t2, 0x40400000")
        lines.append("    fmv.w.x f1, t1")
        lines.append("    fmv.w.x f2, t2")
        lines.append("    fdiv.s  f3, f1, f2, dyn")
        lines.append("    fsqrt.s f4, f2, dyn")
        lines.append("    csrr t3, fflags")
    lines.append("    csrw frm, zero")

    # 2. Directed DP special matrix + subnormals + after-rounding tininess + all 5 rounding modes
    dp_pzero  = 0x0000000000000000
    dp_nzero  = 0x8000000000000000
    dp_pinf   = 0x7FF0000000000000
    dp_ninf   = 0xFFF0000000000000
    dp_pone   = 0x3FF0000000000000
    dp_none   = 0xBFF0000000000000
    dp_ptwo   = 0x4000000000000000
    dp_half   = 0x3FE0000000000000
    dp_four   = 0x4010000000000000
    dp_qnan   = 0x7FF8000000000000
    dp_snan   = 0x7FF0000000000001
    dp_minsub = 0x0000000000000001
    dp_maxsub = 0x000FFFFFFFFFFFFF
    dp_minnrm = 0x0010000000000000
    dp_maxfin = 0x7FEFFFFFFFFFFFFF
    dp_tiny_n = 0x001FFFFFFFFFFFFF  # exact halfway tie at DP subnormal/normal boundary when / 2.0

    def emit_dp_div(a_hex: int, b_hex: int, rm: str = "rne"):
        lines.append("    csrw fflags, zero")
        lines.append(_li64("t0", a_hex))
        lines.append(_li64("t1", b_hex))
        lines.append("    fmv.d.x f1, t0")
        lines.append("    fmv.d.x f2, t1")
        lines.append(f"    fdiv.d  f3, f1, f2, {rm}")
        lines.append("    csrr t2, fflags")

    def emit_dp_sqrt(a_hex: int, rm: str = "rne"):
        lines.append("    csrw fflags, zero")
        lines.append(_li64("t0", a_hex))
        lines.append("    fmv.d.x f1, t0")
        lines.append(f"    fsqrt.d f3, f1, {rm}")
        lines.append("    csrr t2, fflags")

    for a, b in [
        (dp_pinf, dp_pzero), (dp_ninf, dp_nzero), (dp_pzero, dp_pzero),
        (dp_pinf, dp_pinf), (dp_pone, dp_pzero), (dp_none, dp_nzero),
        (dp_pzero, dp_pone), (dp_pone, dp_pinf), (dp_qnan, dp_pone),
        (dp_snan, dp_pone), (dp_minsub, dp_minsub), (dp_maxsub, dp_minsub),
        (dp_minsub, dp_maxsub), (dp_minnrm, 0x3FF0000000000001),
    ]:
        emit_dp_div(a, b, "rne")

    for rm in ("rne", "rtz", "rdn", "rup", "rmm"):
        emit_dp_div(dp_tiny_n, dp_ptwo, rm)
        emit_dp_div(dp_tiny_n | (1 << 63), dp_ptwo, rm)
        emit_dp_div(0x0010000000000001, dp_ptwo, rm)  # exact halfway tie (even LSB)
        emit_dp_div(0x0010000000000003, dp_ptwo, rm)  # exact halfway tie (odd LSB)
        emit_dp_div(dp_maxfin, dp_half, rm)
        emit_dp_div(dp_maxfin | (1 << 63), dp_half, rm)
        emit_dp_div(dp_minsub, dp_four, rm)
        emit_dp_div(dp_minsub | (1 << 63), dp_four, rm)
        emit_dp_div(dp_pone, 0x4008000000000000, rm)  # 1.0 / 3.0
        emit_dp_sqrt(dp_ptwo, rm)
        emit_dp_sqrt(0x4008000000000000, rm)          # sqrt(3.0)
        emit_dp_sqrt(dp_minsub, rm)
        emit_dp_sqrt(dp_maxsub, rm)
        emit_dp_sqrt(dp_maxfin, rm)

    for a in (dp_pzero, dp_nzero, dp_pinf, dp_ninf, dp_none, dp_qnan, dp_snan, dp_pone, dp_four, dp_minnrm):
        emit_dp_sqrt(a, "rne")

    # 3. Back-to-back FDIV/FSQRT + RAW dependent FMA + speculative branch-mispredict squash
    lines.append(r"""
    # Back-to-back FDIV/FSQRT + RAW dependency
    csrw fflags, zero
    li   t0, 0x4059000000000000  # 100.0
    li   t1, 0x401C000000000000  # 7.0
    fmv.d.x f10, t0
    fmv.d.x f11, t1
    fdiv.d  f12, f10, f11
    fsqrt.d f13, f12
    fdiv.d  f14, f13, f11
    fmadd.d f15, f14, f11, f10

    # Speculative branch-mispredict squash while FDIV/FSQRT is in flight
    li   s0, 0
    li   s1, 6
1:
    addi s0, s0, 1
    andi s2, s0, 1
    beqz s2, 2f
    fdiv.d  f16, f10, f11
    fsqrt.d f17, f10
    j    3f
2:
    fdiv.s  f18, f1, f2
    fsqrt.s f19, f1
3:
    bne  s0, s1, 1b

    HTIF_EXIT 0
""")
    return "\n".join(lines)


def gen_fdiv_fsqrt_rand() -> str:
    rng = random.Random(0x2501B001)
    rms = ["rne", "rtz", "rdn", "rup", "rmm"]
    lines = [
        COMMON_HTIF_MACROS,
        ".section .text.init",
        ".globl _start",
        "_start:",
        _enable_fp_and_vec(),
    ]

    def rand_sp(allow_neg: bool = True) -> int:
        cat = rng.randrange(10)
        sign = (rng.randrange(2) << 31) if allow_neg else 0
        if cat == 0:
            # Subnormal
            return sign | rng.randint(1, 0x007FFFFF)
        if cat == 1:
            # Tiny normal (exp 1..4)
            return sign | (rng.randint(1, 4) << 23) | rng.randrange(1 << 23)
        if cat == 2:
            # Huge normal (exp 250..254)
            return sign | (rng.randint(250, 254) << 23) | rng.randrange(1 << 23)
        # General normal
        return sign | (rng.randint(1, 254) << 23) | rng.randrange(1 << 23)

    def rand_dp(allow_neg: bool = True) -> int:
        cat = rng.randrange(10)
        sign = (rng.randrange(2) << 63) if allow_neg else 0
        if cat == 0:
            return sign | rng.randint(1, (1 << 52) - 1)
        if cat == 1:
            return sign | (rng.randint(1, 4) << 52) | rng.randrange(1 << 52)
        if cat == 2:
            return sign | (rng.randint(2042, 2046) << 52) | rng.randrange(1 << 52)
        return sign | (rng.randint(1, 2046) << 52) | rng.randrange(1 << 52)

    # 50 randomized fdiv.s, 40 fsqrt.s, 50 fdiv.d, 40 fsqrt.d = 180 randomized ops
    for i in range(50):
        a = rand_sp(True)
        b = rand_sp(True)
        rm = rms[i % 5]
        lines.append("    csrw fflags, zero")
        lines.append(f"    li   t0, 0x{a:08x}")
        lines.append(f"    li   t1, 0x{b:08x}")
        lines.append("    fmv.w.x f1, t0")
        lines.append("    fmv.w.x f2, t1")
        lines.append(f"    fdiv.s  f3, f1, f2, {rm}")

    for i in range(40):
        a = rand_sp(allow_neg=(i % 8 == 0))
        rm = rms[i % 5]
        lines.append("    csrw fflags, zero")
        lines.append(f"    li   t0, 0x{a:08x}")
        lines.append("    fmv.w.x f1, t0")
        lines.append(f"    fsqrt.s f3, f1, {rm}")

    for i in range(50):
        a = rand_dp(True)
        b = rand_dp(True)
        rm = rms[i % 5]
        lines.append("    csrw fflags, zero")
        lines.append(_li64("t0", a))
        lines.append(_li64("t1", b))
        lines.append("    fmv.d.x f1, t0")
        lines.append("    fmv.d.x f2, t1")
        lines.append(f"    fdiv.d  f3, f1, f2, {rm}")

    for i in range(40):
        a = rand_dp(allow_neg=(i % 8 == 0))
        rm = rms[i % 5]
        lines.append("    csrw fflags, zero")
        lines.append(_li64("t0", a))
        lines.append("    fmv.d.x f1, t0")
        lines.append(f"    fsqrt.d f3, f1, {rm}")

    lines.append("    HTIF_EXIT 0")
    return "\n".join(lines)


def gen_mul_pipelined() -> str:
    rng = random.Random(0x2501B002)
    lines = [
        COMMON_HTIF_MACROS,
        ".section .text.init",
        ".globl _start",
        "_start:",
    ]

    extremes = [
        0x0000000000000000,
        0x0000000000000001,
        0xFFFFFFFFFFFFFFFF,
        0x8000000000000000,
        0x7FFFFFFFFFFFFFFF,
        0x0000000080000000,
        0x000000007FFFFFFF,
        0xFFFFFFFF80000000,
        0x00000000FFFFFFFF,
        0xFFFFFFFF00000000,
    ]

    # Directed extremes across all 5 RV64M multiply ops (back-to-back pipeline saturation!)
    for idx in range(len(extremes)):
        a = extremes[idx]
        b = extremes[(idx * 3 + 1) % len(extremes)]
        lines.append(_li64("a0", a))
        lines.append(_li64("a1", b))
        lines.append("    mul    t0, a0, a1")
        lines.append("    mulh   t1, a0, a1")
        lines.append("    mulhsu t2, a0, a1")
        lines.append("    mulhu  t3, a0, a1")
        lines.append("    mulw   t4, a0, a1")

    # 35 seeded randomized operand pairs x 5 ops = 175 randomized multiply ops
    for _ in range(35):
        a = rng.getrandbits(64)
        b = rng.getrandbits(64)
        lines.append(_li64("a0", a))
        lines.append(_li64("a1", b))
        lines.append("    mul    t0, a0, a1")
        lines.append("    mulh   t1, a0, a1")
        lines.append("    mulhsu t2, a0, a1")
        lines.append("    mulhu  t3, a0, a1")
        lines.append("    mulw   t4, a0, a1")

    # RAW dependency chain + alternating branch-mispredict squash while S1/S2/S3 are full
    lines.append(r"""
    li   a0, 0x123456789ABCDEF1
    li   a1, -0x0FEDCBA987654321
    mul    s0, a0, a1
    mulh   s1, s0, a1
    mulhsu s2, s1, s0
    mulhu  s3, s2, s1
    mulw   s4, s3, s2

    li   s5, 0
    li   s6, 12
1:
    addi s5, s5, 1
    andi s7, s5, 1
    mul    t0, a0, a1
    mulh   t1, a0, a1
    beqz s7, 2f
    mulhsu t2, t0, t1
    mulhu  t3, t1, a0
    j    3f
2:
    mulw   t4, t0, t1
    mul    t5, t1, a1
3:
    add  a0, a0, t0
    bne  s5, s6, 1b

    HTIF_EXIT 0
""")
    return "\n".join(lines)


def gen_vdiv_rvv() -> str:
    rng = random.Random(0x2501B003)

    # Build deterministic data tables for SEW=8 (32B), SEW=16 (32B), SEW=32 (64B for LMUL=2), SEW=64 (64B for LMUL=2)
    b8_a = [0, 1, 127, 128, 255, 200, 50, 128, 128, 0x80, 0x7F, 0x01, 0xFF, 0x55, 0xAA, 0x99] + [rng.randrange(256) for _ in range(16)]
    b8_b = [1, 0, 255, 255, 0,   7,   251, 1,  0,   0xFF, 0xFE, 0x02, 0xFF, 0x03, 0xFD, 0x11] + [rng.randrange(256) for _ in range(16)]

    b16_a = [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x8000, 0x8000, 12345] + [rng.randrange(65536) for _ in range(8)]
    b16_b = [1, 0, 0xFFFF, 0xFFFF, 0,      1,      0,      0xFF00] + [rng.randrange(65536) for _ in range(8)]

    b32_a = [0, 1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x80000000, 0x80000000, 0xDEADBEEF] + [rng.randrange(1 << 32) for _ in range(8)]
    b32_b = [1, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0,          1,          0,          0xFFFFF001] + [rng.randrange(1 << 32) for _ in range(8)]

    b64_a = [
        0,
        1,
        0x7FFFFFFFFFFFFFFF,
        0x8000000000000000,
        0xFFFFFFFFFFFFFFFF,
        0x8000000000000000,
        0x8000000000000000,
        rng.getrandbits(64),
    ]
    b64_b = [
        1,
        0,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0,
        1,
        0,
        rng.getrandbits(64) | 1,
    ]

    def fmt_bytes(vals: list[int]) -> str:
        return "    .byte " + ", ".join(f"0x{v & 0xFF:02x}" for v in vals)

    def fmt_halves(vals: list[int]) -> str:
        return "    .half " + ", ".join(f"0x{v & 0xFFFF:04x}" for v in vals)

    def fmt_words(vals: list[int]) -> str:
        return "    .word " + ", ".join(f"0x{v & 0xFFFFFFFF:08x}" for v in vals)

    def fmt_quads(vals: list[int]) -> str:
        return "    .quad " + ", ".join(f"0x{v & 0xFFFFFFFFFFFFFFFF:016x}" for v in vals)

    asm = COMMON_HTIF_MACROS + _enable_fp_and_vec()
    code = f"""{COMMON_HTIF_MACROS}
.section .text.init
.globl _start
_start:
{_enable_fp_and_vec()}
    # Preload mask pattern in v0 (alternating / varied bits: 0xA55A_3C96)
    vsetivli t0, 8, e32, m1, ta, ma
    la   s0, v_mask
    vle32.v v0, (s0)

    # ------------------------------------------------------------------
    # 1. SEW=8, LMUL=1 (VL=32): vdiv.vv, vdivu.vv, vdiv.vx, vdivu.vx + masked + tail + vstart
    # ------------------------------------------------------------------
    li   a0, 32
    vsetvli t0, a0, e8, m1, ta, ma
    la   s1, d8_a
    la   s2, d8_b
    vle8.v  v2, (s1)
    vle8.v  v3, (s2)
    vdiv.vv  v4, v2, v3
    vdivu.vv v5, v2, v3
    li   t1, -1
    vdiv.vx  v6, v2, t1
    li   t2, 0
    vdivu.vx v7, v2, t2
    li   t3, 7
    vdiv.vx  v8, v2, t3
    # Masked + mu + tu with vl=20 (< 32)
    vsetivli t0, 20, e8, m1, tu, mu
    vmv.v.i  v9, 13
    vdiv.vv  v9, v2, v3, v0.t
    vmv.v.i  v10, 11
    vdivu.vv v10, v2, v3, v0.t
    # Non-zero vstart
    li   t4, 5
    csrw vstart, t4
    vdiv.vv  v9, v2, v3

    # ------------------------------------------------------------------
    # 2. SEW=16, LMUL=1 (VL=16): unmasked + masked + div-by-0 + INT16_MIN/-1
    # ------------------------------------------------------------------
    vsetivli t0, 16, e16, m1, ta, ma
    la   s1, d16_a
    la   s2, d16_b
    vle16.v  v2, (s1)
    vle16.v  v3, (s2)
    vdiv.vv  v4, v2, v3
    vdivu.vv v5, v2, v3
    li   t1, -1
    vdiv.vx  v6, v2, t1
    vdivu.vx v7, v2, zero
    vsetivli t0, 11, e16, m1, tu, mu
    vmv.v.i  v8, 9
    vdiv.vv  v8, v2, v3, v0.t
    vdivu.vv v9, v2, v3, v0.t

    # ------------------------------------------------------------------
    # 3. SEW=32, LMUL=2 (VL=16): multi-reg vector group + masked + vstart
    # ------------------------------------------------------------------
    vsetivli t0, 16, e32, m2, ta, ma
    la   s1, d32_a
    la   s2, d32_b
    vle32.v  v2, (s1)
    vle32.v  v4, (s2)
    vdiv.vv  v6, v2, v4
    vdivu.vv v8, v2, v4
    li   t1, -1
    vdiv.vx  v10, v2, t1
    vdivu.vx v12, v2, zero
    vsetivli t0, 13, e32, m2, tu, mu
    vmv.v.i  v14, 5
    vdiv.vv  v14, v2, v4, v0.t
    li   t4, 3
    csrw vstart, t4
    vdivu.vv v14, v2, v4

    # ------------------------------------------------------------------
    # 4. SEW=64, LMUL=2 (VL=8): 64-bit extremes + randomized + masked
    # ------------------------------------------------------------------
    vsetivli t0, 8, e64, m2, ta, ma
    la   s1, d64_a
    la   s2, d64_b
    vle64.v  v2, (s1)
    vle64.v  v4, (s2)
    vdiv.vv  v6, v2, v4
    vdivu.vv v8, v2, v4
    li   t1, -1
    vdiv.vx  v10, v2, t1
    li   t2, 0
    vdivu.vx v12, v2, t2
    vsetivli t0, 6, e64, m2, tu, mu
    vmv.v.i  v14, 3
    vdiv.vv  v14, v2, v4, v0.t

    # ------------------------------------------------------------------
    # 5. Branch-mispredict loop exercising vdiv across taken/not-taken paths
    # ------------------------------------------------------------------
    vsetivli t0, 4, e64, m1, ta, ma
    li   s5, 0
    li   s6, 6
1:
    addi s5, s5, 1
    andi s7, s5, 1
    beqz s7, 2f
    vdiv.vv  v16, v2, v4
    j    3f
2:
    vdivu.vv v17, v2, v4
3:
    bne  s5, s6, 1b

    HTIF_EXIT 0

.section .data
.align 6
v_mask:
    .word 0xA55A3C96, 0x5AA5C369, 0xF0F00F0F, 0x3333CCCC
    .word 0xA55A3C96, 0x5AA5C369, 0xF0F00F0F, 0x3333CCCC
.align 6
d8_a:
{fmt_bytes(b8_a)}
.align 6
d8_b:
{fmt_bytes(b8_b)}
.align 6
d16_a:
{fmt_halves(b16_a)}
.align 6
d16_b:
{fmt_halves(b16_b)}
.align 6
d32_a:
{fmt_words(b32_a)}
.align 6
d32_b:
{fmt_words(b32_b)}
.align 6
d64_a:
{fmt_quads(b64_a)}
.align 6
d64_b:
{fmt_quads(b64_b)}
"""
    return code


def _ensure_verilator_tb() -> Path:
    exe = SAIL_BUILD_DIR / "obj_dir" / "Vfursoy_s1_core"
    if exe.exists():
        exe_mtime = exe.stat().st_mtime
        deps = [*CORE_RTL, TB_CPP]
        if all(p.exists() and p.stat().st_mtime <= exe_mtime for p in deps):
            print(f"  [SAIL] Reusing fresh Vfursoy_s1_core harness at {exe.relative_to(ROOT)}")
            return exe
    return build_verilator_tb()


def run_expanded_sail_cosim() -> dict:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    ld_path = BUILD_DIR / "link.ld"
    ld_path.write_text(LINKER_SCRIPT, encoding="utf-8")

    tb_exe = _ensure_verilator_tb()
    workloads = {
        "s25_fdiv_fsqrt_directed": gen_fdiv_fsqrt_directed(),
        "s25_fdiv_fsqrt_rand": gen_fdiv_fsqrt_rand(),
        "s25_mul_pipelined": gen_mul_pipelined(),
        "s25_vdiv_rvv": gen_vdiv_rvv(),
    }

    summaries = []
    all_passed = True
    total_steps = 0
    total_gprs = 0
    total_fprs = 0
    total_vrfs = 0

    for name, src in workloads.items():
        print(f"  [SAIL] Running expanded arithmetic suite '{name}'...")
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
        sail_res = subprocess.run(sail_cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
        if sail_res.returncode != 0 or "SUCCESS" not in (sail_res.stdout + sail_res.stderr):
            raise RuntimeError(
                f"Sail failed on {name} (rc={sail_res.returncode}):\n{sail_res.stdout}\n{sail_res.stderr}"
            )

        fur_trace_path = BUILD_DIR / f"{name}.fursoy.jsonl"
        tb_cmd = [
            str(tb_exe),
            "--trace-out",
            str(fur_trace_path),
            "--htif-pc",
            f"{htif_pc:x}",
            "--max-cycles",
            "500000",
        ]
        for paddr, seg_path in segs:
            tb_cmd.extend(["--seg", f"{paddr:x}:{seg_path}"])
        tb_res = subprocess.run(tb_cmd, cwd=ROOT, capture_output=True, text=True, timeout=180)
        if tb_res.returncode != 0:
            raise RuntimeError(
                f"Fursoy TB failed on {name} (rc={tb_res.returncode}):\n{tb_res.stdout}\n{tb_res.stderr}"
            )

        sail_steps = parse_sail_trace(sail_log_path.read_text(encoding="utf-8"))
        fur_events = [
            json.loads(line)
            for line in fur_trace_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        summary = compare_traces(name, sail_steps, fur_events)
        summaries.append(summary)
        total_steps += summary["sail_steps"]
        total_gprs += summary["gprs_checked"]
        total_fprs += summary["fprs_checked"]
        total_vrfs += summary["vrfs_checked"]
        if summary["matched"]:
            print(
                f"    [PASS] {name}: {summary['sail_steps']} steps matched 1-to-1 "
                f"(GPR={summary['gprs_checked']}, FPR={summary['fprs_checked']}, "
                f"VRF={summary['vrfs_checked']}, Traps={summary['traps_checked']}, 0 mismatches)"
            )
        else:
            all_passed = False
            print(f"    [FAIL] {name}: {summary['mismatches'][0]}")

    return {
        "passed": all_passed,
        "sail_version": subprocess.run(
            [str(SAIL_BIN), "--version"], capture_output=True, text=True
        ).stdout.strip(),
        "total_steps": total_steps,
        "total_gprs_checked": total_gprs,
        "total_fprs_checked": total_fprs,
        "total_vrfs_checked": total_vrfs,
        "total_mismatches": sum(len(s["mismatches"]) for s in summaries),
        "workloads": summaries,
    }


def main() -> int:
    t0 = time.time()
    print("=" * 88)
    print("Fursoy S2.5-M1b Synthesizable Arithmetic Verification & OpenSTA Proof Runner")
    print("=" * 88)

    print("\n[1/3] Static RTL Audit (0 behavioral '/' or '%', 0 unrolled isqrt)...")
    static_res = run_static_audit()
    if static_res["passed"]:
        print("  [PASS] Static RTL audit clean across fdiv, vec_div, multiplier, and core VEC_VDIV")
    else:
        print(f"  [FAIL] Static audit findings: {static_res['findings']}")

    print("\n[2/3] Yosys (Nangate45) + OpenSTA (500 MHz / 2.000 ns) Proof...")
    sta_res = run_synth_and_sta()

    print("\n[3/3] Expanded sail-riscv v0.16 Differential Co-Simulation...")
    sail_res = run_expanded_sail_cosim()

    overall_pass = static_res["passed"] and sta_res["passed"] and sail_res["passed"]
    report = {
        "milestone": "S2.5-M1b",
        "status": "pass" if overall_pass else "fail",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - t0, 2),
        "rtl_sha256": compute_rtl_sha256(),
        "static_audit": static_res,
        "synth_sta_nangate45_500mhz": sta_res,
        "sail_cosim_expanded": sail_res,
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print("\n" + "=" * 88)
    print(f"S2.5-M1b RESULT: {'PASS' if overall_pass else 'FAIL'} -> {REPORT_PATH.relative_to(ROOT)}")
    print(f"RTL SHA-256: {report['rtl_sha256']}")
    print("=" * 88)
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
