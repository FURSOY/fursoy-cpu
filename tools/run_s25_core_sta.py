#!/usr/bin/env python3
"""Fursoy Slice-2.5 Milestone S2.5-M4: Honest Core-Wide OpenSTA Characterization
& Synchronous SRAM Macro Sensitivity Sweep (ZERO RTL EDITS).

1. Runs canonical sv2v -> Yosys (Nangate45) -> OpenSTA (500 MHz / 2.000 ns,
   0.05 ns clock uncertainty, 0.20 ns input/output delay, 0 false/multicycle
   paths, 0 Warning 1216 / 0 Warning 441) strictly sequentially across ALL
   previously uncharacterized OoO core leaf modules (15 primary OoO compute/
   memory/rename/queue blocks + 10 remaining leaf control/rename/support blocks).
2. Runs a synchronous SRAM macro sensitivity sweep (tCQ = 0.60, 0.80, 1.00 ns;
   tSetup = 0.20 ns; rising_edge clk_i -> Q arcs, 0 Warning 1216/441) on the
   existing synthesized netlists for fursoy_s1_l1d, fursoy_s2_l2, and
   fursoy_s2_coherence_mgr without modifying tools/run_s2_synth.py's gate.
3. Consolidates all 25 newly characterized core blocks, 14 existing gated
   Slice-1/2 blocks, 3 S2.5-M1b arithmetic blocks, and 5 documented structural
   hierarchy wrappers into results/s25-core-sta.json.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import resource
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from run_s2_synth import (  # noqa: E402
    BUILD_SYNTH_S2,
    CONSTR_PATH,
    LIB_PATH,
    NAND2_AREA,
    STA_BIN,
    check_toolchain,
    normalize_comb_sensitivity,
    parse_sta_log,
    parse_yosys_log,
    sha256_file,
    sta_warning_counts,
)
from s2_verilator_lib import compute_rtl_sha256  # noqa: E402

BUILD_DIR = ROOT / "build/s25_core_sta"
DEFAULT_REPORT = ROOT / "results/s25-core-sta.json"
S2_SYNTH_REPORT = BUILD_SYNTH_S2 / "s2_synth_report.json"
S1_SYNTH_REPORT = ROOT / "build/synth/s1_synth_report.json"
M1B_REPORT = ROOT / "results/s25-m1b-arith.json"

TARGET_PERIOD_NS = 2.0
CLK_UNCERTAINTY_NS = 0.05
IO_DELAY_NS = 0.20

# 15 primary previously-uncharacterized OoO core blocks + 10 remaining leaf blocks
CORE_CHAR_MODULES: list[dict[str, Any]] = [
    # Primary 15 OoO blocks (parameterized per rtl/core/fursoy_s1_pkg.sv)
    {"name": "fursoy_s1_rob", "group": "primary_ooo", "desc": "128-Entry Reorder Buffer (2-wide alloc/retire, 16-checkpoint recovery)"},
    {"name": "fursoy_s1_prf", "group": "primary_ooo", "desc": "160-Entry x 64b Integer Physical Register File (flop-array RTL)"},
    {"name": "fursoy_s1_fprf", "group": "primary_ooo", "desc": "64-Entry x 64b Floating-Point Physical Register File (flop-array RTL)"},
    {"name": "fursoy_s1_int_iq", "group": "primary_ooo", "desc": "32-Entry Integer Issue Queue (age-ordered dual-port wakeup/select)"},
    {"name": "fursoy_s1_mem_iq", "group": "primary_ooo", "desc": "32-Entry Memory Issue Queue (AGU/Load/Store dispatch)"},
    {"name": "fursoy_s1_fp_iq", "group": "primary_ooo", "desc": "16-Entry Floating-Point Issue Queue (FMA/FDIV/FCONV dispatch)"},
    {"name": "fursoy_s1_lsu_queues", "group": "primary_ooo", "desc": "16-Entry Load Queue + 16-Entry Store Queue + Forward/Snoop/MMIO"},
    {"name": "fursoy_s1_bpu", "group": "primary_ooo", "desc": "Branch Prediction Unit (512-entry BTB + 108b-GHR TAGE-Lite + 16-entry RAS)"},
    {"name": "fursoy_s1_divider", "group": "primary_ooo", "desc": "Iterative 64-bit Integer Divider (RV64M DIV/REM)"},
    {"name": "fursoy_s1_fma", "group": "primary_ooo", "desc": "IEEE-754 Single/Double Fused Multiply-Add Pipeline (SP 3c / DP 4c)"},
    {"name": "fursoy_s1_fconv", "group": "primary_ooo", "desc": "IEEE-754 FP Compare, Min/Max, Sign-Inject, Move & Convert Unit"},
    {"name": "fursoy_s1_l1i", "group": "primary_ooo", "desc": "16 KiB 4-Way Set-Associative Instruction Cache (flop-array RTL)"},
    {"name": "fursoy_s1_vrf", "group": "primary_ooo", "desc": "64-Entry x 256b Vector Register File (VLEN=256, 4x64b banks, flop-array RTL)"},
    {"name": "fursoy_s1_vrat", "group": "primary_ooo", "desc": "Vector Register Alias Table + Bitmap Freelist + 16 Checkpoints"},
    {"name": "fursoy_s1_vec_iq", "group": "primary_ooo", "desc": "8-Entry Decoupled Vector Issue Queue"},
    # 10 remaining leaf core control/rename/support blocks (for 100% CORE_RTL leaf coverage)
    {"name": "fursoy_s1_freelist", "group": "leaf_support", "desc": "Integer Physical Register Freelist (128-entry, 16 checkpoints)"},
    {"name": "fursoy_s1_rat", "group": "leaf_support", "desc": "Integer Register Alias Table (SRAT/ARAT + 16 checkpoints)"},
    {"name": "fursoy_s1_prf_status", "group": "leaf_support", "desc": "160-Entry Integer PRF Ready/Scoreboard Bitvector"},
    {"name": "fursoy_s1_frat", "group": "leaf_support", "desc": "FP Register Alias Table + 32-Entry FP Freelist + 16 Checkpoints"},
    {"name": "fursoy_s1_fprf_status", "group": "leaf_support", "desc": "64-Entry FP PRF Ready/Scoreboard Bitvector"},
    {"name": "fursoy_s1_port1_buffers", "group": "leaf_support", "desc": "Port-1 Multiply/Divide Result & Arbitration Buffers"},
    {"name": "fursoy_s1_trt", "group": "leaf_support", "desc": "32-Entry Load/Store Address Translation Request Tracker"},
    {"name": "fursoy_s1_fetch_queue", "group": "leaf_support", "desc": "Decoupled Instruction Fetch Queue"},
    {"name": "fursoy_s1_serialization", "group": "leaf_support", "desc": "System/CSR/Fence Serialization Control FSM"},
    {"name": "fursoy_s1_hpm", "group": "leaf_support", "desc": "Hardware Performance Monitor + 8-Bucket Single-Owner CPI Engine"},
]

HIERARCHY_WRAPPERS = [
    {"name": "fursoy_s1_substrate", "role": "Structural wrapper: freelist + rat + prf_status + frat + fprf_status + rob"},
    {"name": "fursoy_s1_lsu", "role": "Structural wrapper: agu + trt + dtlb + lsu_queues + l1d"},
    {"name": "fursoy_s1_backend", "role": "Structural wrapper: int_iq + mem_iq + fp_iq + alu + branch_unit + multiplier + divider + port1_buffers + fma + fdiv + fconv + lsu"},
    {"name": "fursoy_s1_frontend", "role": "Structural wrapper: bpu + itlb + l1i + fetch_queue + decode"},
    {"name": "fursoy_s1_core", "role": "Top-level core wrapper: frontend + substrate + prf + fprf + vrf + vrat + vec_iq + vec_div + backend + ptw + csr + hpm + serialization + inline vector ALU"},
]

SYNC_SRAM_TCQS_NS = [0.60, 0.80, 1.00]
SYNC_SRAM_SETUP_NS = 0.20
SYNC_SRAM_HOLD_NS = 0.05


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def est_fmax_from_wns(wns_ns: float | None, period_ns: float = TARGET_PERIOD_NS) -> float | None:
    if wns_ns is None:
        return None
    eff_period = period_ns - wns_ns
    if eff_period <= 0.0:
        return None
    return round(1000.0 / eff_period, 1)


def read_proc_vmhwm_kib(pid: int) -> int | None:
    try:
        with open(f"/proc/{pid}/status", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        return int(parts[1])
    except OSError:
        pass
    return None


def run_monitored(cmd: list[str], log_path: Path, timeout_s: int, max_log_bytes: int = 256 * 1024 * 1024) -> tuple[int, bool, float, int]:
    """Run subprocess redirecting stdout+stderr to log_path, monitoring peak RSS and log bloat."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    peak_kib = 0
    timed_out = False
    with log_path.open("w", encoding="utf-8") as lf:
        proc = subprocess.Popen(cmd, cwd=ROOT, stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
        while True:
            rc = proc.poll()
            vm = read_proc_vmhwm_kib(proc.pid)
            if vm is not None and vm > peak_kib:
                peak_kib = vm
            if rc is not None:
                break
            log_too_big = False
            try:
                if log_path.stat().st_size > max_log_bytes:
                    log_too_big = True
            except OSError:
                pass
            if time.monotonic() - t0 > timeout_s or log_too_big:
                timed_out = True
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
                rc = -9
                break
            time.sleep(0.25)
    return int(rc), timed_out, round(time.monotonic() - t0, 2), peak_kib


def run_single_core_module(mod: dict[str, Any], timeout_s: int, skip_fresh: bool, primary_timeout_s: int = 0) -> dict[str, Any]:
    name = mod["name"]
    sv_path = ROOT / "rtl/core" / f"{name}.sv"
    pkg_path = ROOT / "rtl/core/fursoy_s1_pkg.sv"
    ks_path = ROOT / "rtl/core/fursoy_s1_ks_adder.sv"
    mdir = BUILD_DIR / "modules" / name
    mdir.mkdir(parents=True, exist_ok=True)

    v_file = mdir / f"{name}.v"
    net_file = mdir / f"{name}_netlist.v"
    synth_log = mdir / f"{name}_synth.log"
    sta_tcl = mdir / f"{name}_sta.tcl"
    sta_log = mdir / f"{name}_sta.log"
    meta_file = mdir / f"{name}_meta.json"

    sv_sha = sha256_file(sv_path)
    pkg_sha = sha256_file(pkg_path)
    ks_sha = sha256_file(ks_path)

    if skip_fresh and meta_file.exists() and synth_log.exists() and sta_log.exists():
        try:
            old = json.loads(meta_file.read_text(encoding="utf-8"))
            if (
                old.get("sv_sha256") == sv_sha
                and old.get("pkg_sha256") == pkg_sha
                and old.get("ks_sha256") == ks_sha
                and old.get("status") == "ok"
            ):
                print(f"  [SKIP-FRESH] {name:24s} mode={old.get('mapping_mode')} wns={old.get('sta', {}).get('wns_ns')}", flush=True)
                return old
        except Exception:
            pass

    if not CONSTR_PATH.exists():
        CONSTR_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONSTR_PATH.write_text("set_driving_cell BUF_X2\nset_load 2.0\n", encoding="utf-8")

    # 1. sv2v conversion
    sv2v_bin = shutil.which("sv2v") or "sv2v"
    sv_inputs = [str(pkg_path), str(sv_path)]
    sv_res = subprocess.run(
        [sv2v_bin, "-DSYNTHESIS", f"-I{ROOT / 'rtl/core'}", *sv_inputs],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=180,
    )
    if sv_res.returncode != 0:
        raise RuntimeError(f"sv2v failed for {name}:\n{sv_res.stderr}")
    v_file.write_text(normalize_comb_sensitivity(sv_res.stdout), encoding="utf-8")

    # 2. Yosys + ABC:
    #    - Attempt 1 (primary): canonical read_verilog + synth -noabc + abc -D 1000
    #    - Attempt 2 (fallback on timeout/log-bloat/error): read_verilog -mem2reg + explicit
    #      hierarchy/proc -noprune/memory_map/techmap/dfflibmap + abc -D 1000
    #      (functionally identical standard-cell flop synthesis; avoids Yosys 0.33 exponential
    #      proc_prune / memory_share / opt_expr blowup on wide unpacked struct/table arrays)
    #    - Attempt 3 (only if Attempt 2 reached ABC and hit ABC timeout or buffer-fanout bug):
    #      same structural flow with abc -fast (without -D 1000 buffer pass)
    mem2reg_pre_abc = (
        f"read_liberty -lib {LIB_PATH}; "
        f"read_verilog -mem2reg {v_file}; "
        f"hierarchy -check -top {name}; "
        f"proc_clean; proc_rmdead; proc_init; proc_arst; proc_rom; "
        f"proc_mux; proc_dlatch; proc_dff; proc_memwr; proc_clean; opt_clean; "
        f"memory -nomap; opt_clean; memory_map; opt_clean; "
        f"techmap; opt_clean; "
        f"dfflibmap -liberty {LIB_PATH}; "
    )
    attempts = [
        (
            "abc_d1000",
            f"read_liberty -lib {LIB_PATH}; "
            f"read_verilog {v_file}; "
            f"synth -top {name} -noabc; "
            f"dfflibmap -liberty {LIB_PATH}; "
            f"abc -D 1000 -constr {CONSTR_PATH} -liberty {LIB_PATH}; "
            f"opt_clean -purge; "
            f"write_verilog -noattr -noexpr {net_file}; "
            f"stat -liberty {LIB_PATH}",
        ),
        (
            "abc_fast_nomem2reg",
            f"read_liberty -lib {LIB_PATH}; "
            f"read_verilog {v_file}; "
            f"synth -top {name} -noabc -noshare; "
            f"dfflibmap -liberty {LIB_PATH}; "
            f"abc -fast -constr {CONSTR_PATH} -liberty {LIB_PATH}; "
            f"opt_clean -purge; "
            f"write_verilog -noattr -noexpr {net_file}; "
            f"stat -liberty {LIB_PATH}",
        ),
        (
            "mem2reg_abc_d1000",
            mem2reg_pre_abc
            + f"abc -D 1000 -constr {CONSTR_PATH} -liberty {LIB_PATH}; "
            f"opt_clean -purge; "
            f"write_verilog -noattr -noexpr {net_file}; "
            f"stat -liberty {LIB_PATH}",
        ),
        (
            "mem2reg_abc_fast",
            mem2reg_pre_abc
            + f"abc -fast -constr {CONSTR_PATH} -liberty {LIB_PATH}; "
            f"opt_clean -purge; "
            f"write_verilog -noattr -noexpr {net_file}; "
            f"stat -liberty {LIB_PATH}",
        ),
    ]

    mapping_mode = attempts[0][0]
    rc, timed_out, synth_s, peak_kib = -1, False, 0.0, 0
    p_to = primary_timeout_s if primary_timeout_s > 0 else timeout_s
    for idx, (mode_name, ys_script) in enumerate(attempts):
        if net_file.exists():
            net_file.unlink()
        mapping_mode = mode_name
        tag = "[SYNTH]" if idx == 0 else "[FALLBACK]"
        cur_to = p_to if idx == 0 else timeout_s
        print(f"  {tag:10s} {name:24s} ({mode_name}, timeout={cur_to}s)...", flush=True)
        rc, timed_out, synth_s, attempt_rss = run_monitored(["yosys", "-p", ys_script], synth_log, timeout_s=cur_to)
        peak_kib = max(peak_kib, attempt_rss)
        if not timed_out and rc == 0 and net_file.exists():
            break
        reason = "timed out / log cap" if timed_out else f"failed rc={rc}"
        print(f"  [RETRY]    {name:24s} {mode_name} {reason} ({synth_s}s)", flush=True)
        if idx == 2:
            # Only attempt mem2reg_abc_fast if mem2reg_abc_d1000 actually got to ABC
            log_tail = synth_log.read_text(errors="ignore")[-200000:] if synth_log.exists() else ""
            if "Executing ABC pass" not in log_tail and "Executing ABC " not in log_tail:
                print(f"  [SKIP-FB4] {name:24s} did not reach ABC in mem2reg_abc_d1000; skipping mem2reg_abc_fast", flush=True)
                break

    if timed_out or rc != 0 or not net_file.exists():
        res = {
            "name": name,
            "group": mod["group"],
            "description": mod["desc"],
            "sv_path": str(sv_path.relative_to(ROOT)),
            "sv_sha256": sv_sha,
            "pkg_sha256": pkg_sha,
            "ks_sha256": ks_sha,
            "status": "timeout" if timed_out else "error",
            "mapping_mode": mapping_mode,
            "synth_seconds": synth_s,
            "peak_rss_kib": peak_kib,
            "error": f"Yosys {'timed out' if timed_out else f'failed rc={rc}'} in {mapping_mode}",
            "generated_utc": utc_now_iso(),
        }
        meta_file.write_text(json.dumps(res, indent=2) + "\n", encoding="utf-8")
        print(f"  [WARN]  {name:24s} -> {res['status']} ({res['error']})", flush=True)
        return res

    yosys_stats = parse_yosys_log(synth_log)

    # Check zero behavioral $div/$mod cells
    synth_txt = synth_log.read_text(errors="ignore")
    div_cells = len(re.findall(r"\$div\b", synth_txt))
    mod_cells = len(re.findall(r"\$mod\b", synth_txt))

    # 3. OpenSTA (canonical 500 MHz / 2.000 ns, 0.05 ns uncertainty, 0.20 ns I/O delay, 0 false/multicycle paths)
    tcl = f"""read_liberty {LIB_PATH}
read_verilog {net_file}
link_design {name}
create_clock -name clk -period {TARGET_PERIOD_NS} [get_ports clk_i]
set_clock_uncertainty {CLK_UNCERTAINTY_NS} [get_clocks clk]
set_input_delay -clock clk {IO_DELAY_NS} [all_inputs -no_clocks]
set_output_delay -clock clk {IO_DELAY_NS} [all_outputs]
report_checks -path_delay max -fields {{slew cap input_pins fanout}} -digits 3
report_wns
report_tns
exit
"""
    sta_tcl.write_text(tcl, encoding="utf-8")
    sta_rc, sta_to, sta_s, sta_rss = run_monitored([str(STA_BIN), "-no_init", "-exit", str(sta_tcl)], sta_log, timeout_s=300)
    peak_kib = max(peak_kib, sta_rss)
    if sta_to or sta_rc != 0:
        raise RuntimeError(f"OpenSTA failed for {name} (rc={sta_rc}, timeout={sta_to})")

    sta_stats = parse_sta_log(sta_log)
    w1216, w441 = sta_warning_counts(sta_log)
    wns = sta_stats["wns_ns"] if sta_stats else None
    est_fmax = est_fmax_from_wns(wns)
    timing_met = (wns is not None) and (wns >= 0.0) and ((sta_stats["tns_ns"] or 0.0) >= 0.0)

    res = {
        "name": name,
        "group": mod["group"],
        "description": mod["desc"],
        "sv_path": str(sv_path.relative_to(ROOT)),
        "sv_sha256": sv_sha,
        "pkg_sha256": pkg_sha,
        "ks_sha256": ks_sha,
        "status": "ok",
        "mapping_mode": mapping_mode,
        "synth_seconds": synth_s,
        "sta_seconds": sta_s,
        "peak_rss_kib": peak_kib,
        "yosys_div_cells": div_cells,
        "yosys_mod_cells": mod_cells,
        "warning_1216_count": w1216,
        "warning_441_count": w441,
        "yosys": yosys_stats,
        "sta": sta_stats,
        "est_fmax_mhz": est_fmax,
        "timing_met_500mhz": timing_met,
        "generated_utc": utc_now_iso(),
    }
    meta_file.write_text(json.dumps(res, indent=2) + "\n", encoding="utf-8")
    kge = (yosys_stats["gate_equivalent_ge"] / 1000.0) if (yosys_stats and yosys_stats["gate_equivalent_ge"] is not None) else 0.0
    print(
        f"  [DONE]  {name:24s} | {mapping_mode:9s} | kGE={kge:7.2f} | DFFs={yosys_stats['dff_count']:6d} | "
        f"arr={sta_stats['max_delay_ns']:6.3f}ns | WNS={wns:+7.3f}ns | Fmax={est_fmax:6.1f}MHz | W1216={w1216} W441={w441}",
        flush=True,
    )
    return res


def generate_sync_sram_lib(tcq_ns: float, setup_ns: float = SYNC_SRAM_SETUP_NS, hold_ns: float = SYNC_SRAM_HOLD_NS) -> str:
    """Generate realistic synchronous SRAM macro Liberty model (rising_edge clk_i -> Q)."""
    tcq_s = f"{tcq_ns:.3f}"
    su_s = f"{setup_ns:.3f}"
    hd_s = f"{hold_ns:.3f}"

    def _sync_input(name: str, width: int | None) -> list[str]:
        hdr = f"    pin ({name}) {{" if width is None else f"    bus ({name}) {{"
        lines = [hdr]
        if width is not None:
            lines.append(f"      bus_type : bus{width};")
        lines.extend([
            "      direction : input;",
            "      capacitance : 2.0;",
            "      timing () {",
            '        related_pin : "clk_i";',
            "        timing_type : setup_rising;",
            f'        rise_constraint (sram_constr_1x1) {{ values ("{su_s}"); }}',
            f'        fall_constraint (sram_constr_1x1) {{ values ("{su_s}"); }}',
            "      }",
            "      timing () {",
            '        related_pin : "clk_i";',
            "        timing_type : hold_rising;",
            f'        rise_constraint (sram_constr_1x1) {{ values ("{hd_s}"); }}',
            f'        fall_constraint (sram_constr_1x1) {{ values ("{hd_s}"); }}',
            "      }",
            "    }",
        ])
        return lines

    def _sync_output_bus(name: str, width: int) -> list[str]:
        return [
            f"    bus ({name}) {{",
            f"      bus_type : bus{width};",
            "      direction : output;",
            "      max_capacitance : 100.0;",
            "      timing () {",
            '        related_pin : "clk_i";',
            "        timing_type : rising_edge;",
            "        timing_sense : non_unate;",
            f'        cell_rise (sram_delay_2x2) {{ values ("{tcq_s}, {tcq_s}", "{tcq_s}, {tcq_s}"); }}',
            f'        cell_fall (sram_delay_2x2) {{ values ("{tcq_s}, {tcq_s}", "{tcq_s}, {tcq_s}"); }}',
            '        rise_transition (sram_delay_2x2) { values ("0.030, 0.030", "0.030, 0.030"); }',
            '        fall_transition (sram_delay_2x2) { values ("0.030, 0.030", "0.030, 0.030"); }',
            "      }",
            "    }",
        ]

    lines = [
        f"/* Fursoy S2.5-M4 Synchronous SRAM Sensitivity Liberty (tCQ={tcq_s}ns, tSetup={su_s}ns, tHold={hd_s}ns) */",
        f"library (fursoy_sram_sync_{int(round(tcq_ns * 1000))}ps) {{",
        "  technology (cmos);",
        "  delay_model : table_lookup;",
        '  time_unit : "1ns";',
        '  leakage_power_unit : "1nW";',
        '  voltage_unit : "1V";',
        '  current_unit : "1mA";',
        '  pulling_resistance_unit : "1kohm";',
        "  capacitive_load_unit (1,ff);",
        "  nom_process : 1.00;",
        "  nom_temperature : 25.00;",
        "  nom_voltage : 1.10;",
        "  operating_conditions (typical) { process : 1.00; voltage : 1.10; temperature : 25.00; }",
        "  default_operating_conditions : typical;",
        "  slew_lower_threshold_pct_fall : 30.00;",
        "  slew_lower_threshold_pct_rise : 30.00;",
        "  slew_upper_threshold_pct_fall : 70.00;",
        "  slew_upper_threshold_pct_rise : 70.00;",
        "  slew_derate_from_library : 1.00;",
        "  input_threshold_pct_fall : 50.00;",
        "  input_threshold_pct_rise : 50.00;",
        "  output_threshold_pct_fall : 50.00;",
        "  output_threshold_pct_rise : 50.00;",
        "  default_input_pin_cap : 2.00;",
        "  default_output_pin_cap : 0.00;",
        "  default_fanout_load : 1.00;",
        "  default_max_transition : 0.25;",
        "  lu_table_template (sram_delay_2x2) {",
        "    variable_1 : input_net_transition;",
        "    variable_2 : total_output_net_capacitance;",
        '    index_1 ("0.005, 0.150");',
        '    index_2 ("1.0, 40.0");',
        "  }",
        "  lu_table_template (sram_constr_1x1) {",
        "    variable_1 : constrained_pin_transition;",
        '    index_1 ("0.050");',
        "  }",
    ]
    for w in (2, 3, 6, 8, 9, 64, 256, 512, 4096):
        lines.extend([
            f"  type (bus{w}) {{ base_type : array; data_type : bit; bit_width : {w}; bit_from : {w - 1}; bit_to : 0; downto : true; }}",
        ])

    # Cell 1: fursoy_s1_l1d_bank_sram (synchronous read & write)
    lines.extend([
        "  cell (fursoy_s1_l1d_bank_sram) {",
        "    dont_use : true;",
        "    dont_touch : true;",
        "    area : 45000.0;",
        "    pin (clk_i) { direction : input; clock : true; capacitance : 5.0; }",
    ])
    for pfx in ("rd_snoop", "rd_vic0", "rd_vic1"):
        lines.extend(_sync_input(f"{pfx}_set_i", 6))
        lines.extend(_sync_input(f"{pfx}_way_i", 2))
        lines.extend(_sync_output_bus(f"{pfx}_line_o", 512))
    for pfx in ("rd_ptw", "rd_l0", "rd_l1"):
        lines.extend(_sync_input(f"{pfx}_bank_i", 3))
        lines.extend(_sync_input(f"{pfx}_set_i", 6))
        lines.extend(_sync_input(f"{pfx}_way_i", 2))
        lines.extend(_sync_output_bus(f"{pfx}_dw_o", 64))
    for b in ("wr_b0", "wr_b1"):
        lines.extend(_sync_input(f"{b}_en_i", None))
        lines.extend(_sync_input(f"{b}_set_i", 6))
        lines.extend(_sync_input(f"{b}_way_i", 2))
        lines.extend(_sync_input(f"{b}_data_i", 256))
    lines.extend(_sync_input("wr_dw_en_i", None))
    lines.extend(_sync_input("wr_dw_bank_i", 3))
    lines.extend(_sync_input("wr_dw_set_i", 6))
    lines.extend(_sync_input("wr_dw_way_i", 2))
    lines.extend(_sync_input("wr_dw_mask_i", 8))
    lines.extend(_sync_input("wr_dw_data_i", 64))
    lines.append("  }")

    # Cell 2: fursoy_s2_l2_data_sram (synchronous read & write)
    lines.extend([
        "  cell (fursoy_s2_l2_data_sram) {",
        "    dont_use : true;",
        "    dont_touch : true;",
        "    area : 280000.0;",
        "    pin (clk_i) { direction : input; clock : true; capacitance : 10.0; }",
    ])
    lines.extend(_sync_input("lu_set_i", 9))
    lines.extend(_sync_output_bus("lu_set_data_o", 4096))
    for u in ("upd0", "upd1"):
        lines.extend(_sync_input(f"{u}_wen_i", None))
        lines.extend(_sync_input(f"{u}_set_i", 9))
        lines.extend(_sync_input(f"{u}_way_i", 3))
        lines.extend(_sync_input(f"{u}_data_i", 512))
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def parse_sram_subpath(text: str, marker: str) -> dict[str, Any] | None:
    idx = text.find(marker)
    if idx < 0:
        return None
    sub = text[idx:]
    nxt = sub.find("=== SRAM_", len(marker))
    if nxt > 0:
        sub = sub[:nxt]
    m_sp = re.search(r"^Startpoint:\s*(.+)$", sub, re.M)
    m_ep = re.search(r"^Endpoint:\s*(.+)$", sub, re.M)
    m_arr = re.search(r"^\s*([+-]?\d+\.\d+)\s+data arrival time$", sub, re.M)
    m_slk = re.search(r"^\s*([+-]?\d+\.\d+)\s+slack\s+\((MET|VIOLATED)\)$", sub, re.M)
    if not m_slk:
        return None
    return {
        "startpoint": m_sp.group(1).strip() if m_sp else None,
        "endpoint": m_ep.group(1).strip() if m_ep else None,
        "arrival_ns": float(m_arr.group(1)) if m_arr else None,
        "slack_ns": float(m_slk.group(1)),
        "status": m_slk.group(2),
    }


def run_sync_sram_sensitivity() -> dict[str, Any]:
    """Sweep synchronous SRAM tCQ = 0.60, 0.80, 1.00 ns on existing synthesized S2 netlists."""
    sdir = BUILD_DIR / "sram_sensitivity"
    sdir.mkdir(parents=True, exist_ok=True)
    targets = [
        {"key": "s2_l1d", "top": "fursoy_s1_l1d", "netlist": BUILD_SYNTH_S2 / "s2_l1d_netlist.v", "sram_inst": "u_bank_sram"},
        {"key": "s2_l2", "top": "fursoy_s2_l2", "netlist": BUILD_SYNTH_S2 / "s2_l2_netlist.v", "sram_inst": "u_data_sram"},
        {"key": "s2_coherence_mgr", "top": "fursoy_s2_coherence_mgr", "netlist": BUILD_SYNTH_S2 / "s2_coherence_mgr_netlist.v", "sram_inst": "u_l2/u_data_sram"},
    ]
    for t in targets:
        if not t["netlist"].exists():
            raise RuntimeError(f"Missing pre-synthesized netlist for SRAM sensitivity: {t['netlist']}")

    results: dict[str, Any] = {}
    for tcq in SYNC_SRAM_TCQS_NS:
        tag = f"tcq_{int(round(tcq * 1000))}ps"
        lib_file = sdir / f"sram_sync_{tag}.lib"
        lib_file.write_text(generate_sync_sram_lib(tcq), encoding="utf-8")
        results[tag] = {"tcq_ns": tcq, "tsetup_ns": SYNC_SRAM_SETUP_NS, "thold_ns": SYNC_SRAM_HOLD_NS, "modules": {}}

        for t in targets:
            tcl_file = sdir / f"{t['key']}_{tag}.tcl"
            log_file = sdir / f"{t['key']}_{tag}.log"
            tcl = f"""read_liberty {LIB_PATH}
read_liberty {lib_file}
read_verilog {t['netlist']}
link_design {t['top']}
create_clock -name clk -period {TARGET_PERIOD_NS} [get_ports clk_i]
set_clock_uncertainty {CLK_UNCERTAINTY_NS} [get_clocks clk]
set_input_delay -clock clk {IO_DELAY_NS} [all_inputs -no_clocks]
set_output_delay -clock clk {IO_DELAY_NS} [all_outputs]
report_checks -path_delay max -fields {{slew cap input_pins fanout}} -digits 3
report_wns
report_tns
puts "=== SRAM_LAUNCH ==="
report_checks -from [get_cells {t['sram_inst']}] -path_delay max -digits 3
puts "=== SRAM_CAPTURE ==="
report_checks -to [get_cells {t['sram_inst']}] -path_delay max -digits 3
exit
"""
            tcl_file.write_text(tcl, encoding="utf-8")
            print(f"  [SRAM-SENS] {t['top']:24s} @ tCQ={tcq:.2f}ns (tSetup={SYNC_SRAM_SETUP_NS:.2f}ns)...", flush=True)
            rc, to, sec, _ = run_monitored([str(STA_BIN), "-no_init", "-exit", str(tcl_file)], log_file, timeout_s=300)
            if to or rc != 0:
                raise RuntimeError(f"SRAM sensitivity OpenSTA failed on {t['top']} @ {tag}")
            log_txt = log_file.read_text(encoding="utf-8", errors="ignore")
            block_only_log = sdir / f"{t['key']}_{tag}_block.log"
            block_only_log.write_text(log_txt.split("=== SRAM_LAUNCH ===")[0], encoding="utf-8")
            sta = parse_sta_log(block_only_log)
            w1216, w441 = sta_warning_counts(log_file)
            wns = sta["wns_ns"]
            fmax = est_fmax_from_wns(wns)
            sram_launch = parse_sram_subpath(log_txt, "=== SRAM_LAUNCH ===")
            sram_capture = parse_sram_subpath(log_txt, "=== SRAM_CAPTURE ===")
            results[tag]["modules"][t["top"]] = {
                "sta_seconds": sec,
                "max_delay_ns": sta["max_delay_ns"],
                "wns_ns": wns,
                "tns_ns": sta["tns_ns"],
                "est_fmax_mhz": fmax,
                "timing_met_500mhz": (wns is not None and wns >= 0.0),
                "startpoint": sta["startpoint"],
                "endpoint": sta["endpoint"],
                "sram_launch_path": sram_launch,
                "sram_capture_path": sram_capture,
                "warning_1216_count": w1216,
                "warning_441_count": w441,
            }
            sl_slk = sram_launch["slack_ns"] if sram_launch else None
            sc_slk = sram_capture["slack_ns"] if sram_capture else None
            print(
                f"    -> block WNS={wns:+.3f}ns Fmax={fmax:.1f}MHz | sram_launch_slk={sl_slk}ns sram_capture_slk={sc_slk}ns | W1216={w1216} W441={w441}",
                flush=True,
            )
    return results


def load_existing_gated_and_m1b() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    s2_rep = json.loads(S2_SYNTH_REPORT.read_text(encoding="utf-8"))
    s1_rep = json.loads(S1_SYNTH_REPORT.read_text(encoding="utf-8"))
    m1b_rep = json.loads(M1B_REPORT.read_text(encoding="utf-8"))

    s1_gated: list[dict[str, Any]] = []
    for m in s1_rep.get("modules", []):
        if not m.get("gate"):
            continue
        wns = m["wns_ns_at_500mhz"]
        cp = m.get("critical_path") or {}
        s1_gated.append({
            "name": m["name"],
            "source": "s1_gated_8",
            "type": m.get("type"),
            "cells": m["cell_count"],
            "dffs": m["dff_count"],
            "area_um2": round(m["area_um2"], 2),
            "kge": round(m["kge"], 2),
            "max_delay_ns": m["max_delay_ns"],
            "wns_ns": wns,
            "tns_ns": m["tns_ns_at_500mhz"],
            "est_fmax_mhz": est_fmax_from_wns(wns),
            "timing_met_500mhz": m.get("status") == "met",
            "startpoint": cp.get("startpoint"),
            "endpoint": cp.get("endpoint"),
        })

    s2_gated: list[dict[str, Any]] = []
    l2_kge = l2_dffs = cmgr_kge = cmgr_dffs = 0.0
    for m in s2_rep.get("slice2_blocks", []):
        wns = m["sta"]["wns_ns"]
        kge = round(m["yosys"]["gate_equivalent_ge"] / 1000.0, 2)
        dffs = m["yosys"]["dff_count"]
        if m["name"] == "fursoy_s2_l2":
            l2_kge, l2_dffs = kge, dffs
        elif m["name"] == "fursoy_s2_coherence_mgr":
            cmgr_kge, cmgr_dffs = kge, dffs
        s2_gated.append({
            "name": m["name"],
            "source": "s2_gated_6",
            "params": m.get("params", {}),
            "sram_bb": m.get("sram_bb", False),
            "cells": m["yosys"]["cell_count"],
            "dffs": dffs,
            "area_um2": round(m["yosys"]["chip_area_um2"], 2),
            "kge": kge,
            "max_delay_ns": m["sta"]["max_delay_ns"],
            "wns_ns": wns,
            "tns_ns": m["sta"]["tns_ns"],
            "est_fmax_mhz": est_fmax_from_wns(wns),
            "timing_met_500mhz": m.get("timing_met", False),
            "startpoint": m["sta"].get("startpoint"),
            "endpoint": m["sta"].get("endpoint"),
            "warning_1216_count": m.get("warning_1216_count", 0),
            "warning_441_count": m.get("warning_441_count", 0),
        })

    m1b_blocks: list[dict[str, Any]] = []
    for name, m in m1b_rep.get("synth_sta_nangate45_500mhz", {}).get("modules", {}).items():
        m1b_blocks.append({
            "name": name,
            "source": "s25_m1b_arith_3",
            "cells": m["cells"],
            "dffs": m["dffs"],
            "area_um2": m["area_um2"],
            "kge": m["kge"],
            "max_delay_ns": m["max_delay_ns"],
            "wns_ns": m["slack_ns"],
            "tns_ns": m["tns_ns"],
            "est_fmax_mhz": m["fmax_mhz"],
            "timing_met_500mhz": m["passed"],
        })

    cmgr_decomp = {
        "fursoy_s2_coherence_mgr_inclusive_of_l2_kge": cmgr_kge,
        "fursoy_s2_coherence_mgr_inclusive_of_l2_dffs": int(cmgr_dffs),
        "fursoy_s2_l2_kge": l2_kge,
        "fursoy_s2_l2_dffs": int(l2_dffs),
        "standalone_coherence_logic_kge": round(cmgr_kge - l2_kge, 2),
        "standalone_coherence_logic_dffs": int(cmgr_dffs - l2_dffs),
        "note": "fursoy_s2_coherence_mgr instantiates fursoy_s2_l2 internally; standalone coherence logic = inclusive minus L2.",
    }
    return s1_gated, s2_gated, m1b_blocks, cmgr_decomp


def main() -> int:
    parser = argparse.ArgumentParser(description="Run S2.5-M4 Core-Wide OpenSTA & Synchronous SRAM Sensitivity.")
    parser.add_argument("--only", default="", help="Comma-separated module names to synthesize")
    parser.add_argument("--skip-fresh", action="store_true", help="Reuse fresh per-module results")
    parser.add_argument("--skip-sram-sweep", action="store_true")
    parser.add_argument("--timeout", type=int, default=600, help="Per-attempt Yosys timeout in seconds (default: 600)")
    parser.add_argument("--primary-timeout", type=int, default=0, help="Optional shorter timeout for Attempt 1 (default: same as --timeout)")
    parser.add_argument("--out-report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    rtl_sha = compute_rtl_sha256()
    tc = check_toolchain()
    only_set = {x.strip() for x in args.only.split(",") if x.strip()}

    print(f"[S2.5-M4] RTL SHA-256: {rtl_sha}", flush=True)
    print(f"[S2.5-M4] Toolchain: {tc['yosys']} | OpenSTA {tc['opensta']} | {tc['sv2v']}", flush=True)

    # 1. Synthesize & characterize all uncharacterized core modules strictly sequentially
    char_results: list[dict[str, Any]] = []
    for mod in CORE_CHAR_MODULES:
        if only_set and mod["name"] not in only_set:
            # Load existing meta if present when assembling partial runs
            mf = BUILD_DIR / "modules" / mod["name"] / f"{mod['name']}_meta.json"
            if mf.exists():
                char_results.append(json.loads(mf.read_text(encoding="utf-8")))
            continue
        char_results.append(
            run_single_core_module(mod, timeout_s=args.timeout, skip_fresh=args.skip_fresh, primary_timeout_s=args.primary_timeout)
        )

    # 2. Synchronous SRAM macro sensitivity sweep
    sram_sweep = {} if args.skip_sram_sweep else run_sync_sram_sensitivity()

    # 3. Consolidate existing 14 gated + 3 M1b + 25 newly characterized core blocks
    s1_gated, s2_gated, m1b_blocks, cmgr_decomp = load_existing_gated_and_m1b()

    # Compute honest core-wide summary & Fmax walls
    ok_char = [m for m in char_results if m.get("status") == "ok"]
    timeouts = [m["name"] for m in char_results if m.get("status") != "ok"]
    total_w1216 = sum(m.get("warning_1216_count", 0) for m in ok_char)
    total_w441 = sum(m.get("warning_441_count", 0) for m in ok_char)
    for tag_data in sram_sweep.values():
        for m in tag_data.get("modules", {}).values():
            total_w1216 += m.get("warning_1216_count", 0)
            total_w441 += m.get("warning_441_count", 0)

    # Whole single-core leaf bottom-up sum (8 S1 gated + 1 L1D + 3 M1b + 25 newly characterized = 37 leaf core blocks)
    l1d_entry = next(m for m in s2_gated if m["name"] == "fursoy_s1_l1d")
    all_core_leaves: list[dict[str, Any]] = []
    for m in s1_gated:
        all_core_leaves.append({"name": m["name"], "kge": m["kge"], "dffs": m["dffs"], "wns_ns": m["wns_ns"], "est_fmax_mhz": m["est_fmax_mhz"], "source": m["source"]})
    all_core_leaves.append({"name": l1d_entry["name"], "kge": l1d_entry["kge"], "dffs": l1d_entry["dffs"], "wns_ns": l1d_entry["wns_ns"], "est_fmax_mhz": l1d_entry["est_fmax_mhz"], "source": l1d_entry["source"]})
    for m in m1b_blocks:
        all_core_leaves.append({"name": m["name"], "kge": m["kge"], "dffs": m["dffs"], "wns_ns": m["wns_ns"], "est_fmax_mhz": m["est_fmax_mhz"], "source": m["source"]})
    for m in ok_char:
        all_core_leaves.append({
            "name": m["name"],
            "kge": round(m["yosys"]["gate_equivalent_ge"] / 1000.0, 2),
            "dffs": m["yosys"]["dff_count"],
            "wns_ns": m["sta"]["wns_ns"],
            "est_fmax_mhz": m["est_fmax_mhz"],
            "source": f"s25_m4_{m['group']}",
            "mapping_mode": m["mapping_mode"],
        })

    fmax_ranked = sorted(
        [x for x in all_core_leaves if x.get("est_fmax_mhz") is not None],
        key=lambda x: x["est_fmax_mhz"],
    )
    met_500 = [x["name"] for x in all_core_leaves if x["wns_ns"] is not None and x["wns_ns"] >= 0.0]
    violated_500 = [x["name"] for x in all_core_leaves if x["wns_ns"] is not None and x["wns_ns"] < 0.0]

    report = {
        "milestone": "S2.5-M4",
        "generated_at_utc": utc_now_iso(),
        "rtl_sha256": rtl_sha,
        "rtl_edits": 0,
        "toolchain": tc,
        "constraints": {
            "target_clock_mhz": 500.0,
            "target_period_ns": TARGET_PERIOD_NS,
            "clock_uncertainty_ns": CLK_UNCERTAINTY_NS,
            "input_delay_ns": IO_DELAY_NS,
            "output_delay_ns": IO_DELAY_NS,
            "nand2_area_um2": NAND2_AREA,
            "false_paths": 0,
            "multicycle_paths": 0,
        },
        "warnings_audit": {
            "total_warning_1216": total_w1216,
            "total_warning_441": total_w441,
            "clean": (total_w1216 == 0 and total_w441 == 0),
        },
        "summary": {
            "newly_characterized_requested": len(CORE_CHAR_MODULES),
            "newly_characterized_ok": len(ok_char),
            "newly_characterized_failed_or_timeout": timeouts,
            "total_core_leaf_blocks_characterized": len(all_core_leaves),
            "core_blocks_meeting_500mhz": len(met_500),
            "core_blocks_violating_500mhz": len(violated_500),
            "worst_core_block": fmax_ranked[0] if fmax_ranked else None,
            "top_10_fmax_walls": fmax_ranked[:10],
            "bottom_up_single_core_leaf_kge": round(sum(x["kge"] for x in all_core_leaves), 2),
            "bottom_up_single_core_leaf_dffs": int(sum(x["dffs"] for x in all_core_leaves)),
            "note_area": "Bottom-up leaf sum excludes inter-module glue logic in structural wrappers (fursoy_s1_core inline RVV integer ALU) and represents flop-array RTL for L1I/BPU/VRF/PRF/FPRF (L1D data SRAM blackboxed).",
        },
        "coherence_mgr_area_decomposition": cmgr_decomp,
        "newly_characterized_core_blocks": char_results,
        "existing_gated_s1_blocks": s1_gated,
        "existing_gated_s2_blocks": s2_gated,
        "existing_s25_m1b_arith_blocks": m1b_blocks,
        "sync_sram_sensitivity_sweep": sram_sweep,
        "hierarchy_wrappers_accounted": HIERARCHY_WRAPPERS,
        "peak_rss_kib": int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss),
        "status": "pass" if (len(timeouts) == 0 and total_w1216 == 0 and total_w441 == 0) else "complete_with_findings",
    }

    args.out_report.parent.mkdir(parents=True, exist_ok=True)
    args.out_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"\n[S2.5-M4] Wrote {args.out_report}: ok={len(ok_char)}/{len(CORE_CHAR_MODULES)}, "
        f"core_leaves={len(all_core_leaves)}, met_500MHz={len(met_500)}, violated_500MHz={len(violated_500)}, "
        f"W1216={total_w1216}, W441={total_w441}",
        flush=True,
    )
    if fmax_ranked:
        print(
            f"[S2.5-M4] Worst core Fmax wall: {fmax_ranked[0]['name']} "
            f"(WNS={fmax_ranked[0]['wns_ns']:+.3f}ns, Est. Fmax={fmax_ranked[0]['est_fmax_mhz']} MHz)",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
