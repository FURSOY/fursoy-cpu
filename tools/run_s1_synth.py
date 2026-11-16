#!/usr/bin/env python3
"""
Fursoy Slice-1 Physical Logic Synthesis & Static Timing Analysis (STA)
Evaluates standard cell area and timing on Nangate45 (45nm, 1.10V, 25C).
Target Clock: 500 MHz (period 2.0 ns).
Gate Equivalent (GE): Area / 0.798 um^2 (NAND2_X1).
Stage 1 Timing & Critical Path Optimizations:
  - Parallel prefix Kogge-Stone adders & carry-free target equality in fursoy_s1_branch_unit
  - Decoupled registered Tree-PLRU hit updates in fursoy_s1_dtlb & fursoy_s1_itlb
  - Timing-driven ABC synthesis & fanout buffering (synth -noabc + abc -D 1000 -constr abc.constr)
"""

import argparse
import os
import re
import sys
import json
import hashlib
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB_PATH = Path(os.environ["FURSOY_LIBERTY"]) if os.environ.get("FURSOY_LIBERTY") else (ROOT / "tools/synth/lib/NangateOpenCellLibrary_typical.lib")
CONSTR_PATH = ROOT / "tools/synth/abc.constr"
_LOCAL_STA_WRAPPER = ROOT / "tools/synth/bin/sta"
_LOCAL_STA_REAL = ROOT / "build/tools_pkg/openroad_root/usr/bin/sta"
STA_BIN = Path(
    shutil.which("sta")
    or shutil.which("opensta")
    or (str(_LOCAL_STA_WRAPPER) if (_LOCAL_STA_WRAPPER.exists() and _LOCAL_STA_REAL.exists()) else "sta")
)
BUILD_SYNTH = ROOT / "build/synth"

NAND2_AREA = 0.798  # um^2 in Nangate45


def check_toolchain():
    tools = {}
    try:
        out = subprocess.check_output(["yosys", "-V"], text=True).strip()
        tools["yosys"] = out
    except Exception as e:
        tools["yosys"] = f"Missing: {e}"

    try:
        out = subprocess.check_output([str(STA_BIN), "-version"], text=True).strip()
        tools["opensta"] = out
    except Exception as e:
        tools["opensta"] = f"Missing: {e}"

    try:
        sv2v_bin = shutil.which("sv2v") or "sv2v"
        out = subprocess.check_output([sv2v_bin, "--version"], text=True).strip()
        tools["sv2v"] = out
    except Exception as e:
        tools["sv2v"] = f"Missing: {e}"

    if LIB_PATH.exists():
        tools["liberty"] = f"Nangate45 Typical (size={LIB_PATH.stat().st_size} bytes)"
    else:
        tools["liberty"] = "Missing"

    return tools


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def run_module_synth_and_sta(key, top, sv_path, source_sv_path, is_sequential, timeout_s=90):
    BUILD_SYNTH.mkdir(parents=True, exist_ok=True)
    CONSTR_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not CONSTR_PATH.exists():
        CONSTR_PATH.write_text("set_driving_cell BUF_X2\nset_load 2.0\n")

    sv2v_bin = shutil.which("sv2v") or "sv2v"
    pkg_path = ROOT / "rtl/core/fursoy_s1_pkg.sv"
    ks_path = ROOT / "rtl/core/fursoy_s1_ks_adder.sv"
    v_file = BUILD_SYNTH / f"{key}.v"
    net_file = BUILD_SYNTH / f"{key}_netlist.v"
    synth_log = BUILD_SYNTH / f"{key}_synth.log"
    sta_tcl = BUILD_SYNTH / f"{key}_sta.tcl"
    sta_log = BUILD_SYNTH / f"{key}_sta.log"
    meta_file = BUILD_SYNTH / f"{key}_meta.json"

    timed_out_stage = None
    error_msg = None

    try:
        with open(v_file, "w") as vf:
            subprocess.run(
                [sv2v_bin, "-DSYNTHESIS", f"-I{ROOT / 'rtl/core'}", str(pkg_path), str(sv_path)],
                stdout=vf,
                check=True,
                timeout=timeout_s,
            )

        ys_cmd = (
            f"read_liberty -lib {LIB_PATH}; "
            f"read_verilog {v_file}; "
            f"synth -top {top} -noabc; "
            f"dfflibmap -liberty {LIB_PATH}; "
            f"abc -D 1000 -constr {CONSTR_PATH} -liberty {LIB_PATH}; "
            f"opt_clean -purge; "
            f"write_verilog -noattr -noexpr {net_file}; "
            f"stat -liberty {LIB_PATH}"
        )
        with open(synth_log, "w") as sl:
            subprocess.run(
                ["yosys", "-p", ys_cmd],
                stdout=sl,
                stderr=subprocess.STDOUT,
                check=True,
                timeout=timeout_s,
            )

        if is_sequential:
            tcl = f"""read_liberty {LIB_PATH}
read_verilog {net_file}
link_design {top}
create_clock -name clk -period 2.0 [get_ports clk_i]
set_input_delay -clock clk 0.2 [all_inputs]
set_output_delay -clock clk 0.2 [all_outputs]
report_checks -path_delay max -fields {{slew cap input_pins nets fanout}} -digits 3
report_wns
report_tns
exit
"""
        else:
            tcl = f"""read_liberty {LIB_PATH}
read_verilog {net_file}
link_design {top}
create_clock -name vclk -period 2.0
set_input_delay -clock vclk 0.0 [all_inputs]
set_output_delay -clock vclk 0.0 [all_outputs]
report_checks -path_delay max -fields {{slew cap input_pins nets fanout}} -digits 3
report_wns
report_tns
exit
"""
        sta_tcl.write_text(tcl)
        with open(sta_log, "w") as stl:
            subprocess.run(
                [str(STA_BIN), "-exit", str(sta_tcl)],
                stdout=stl,
                stderr=subprocess.STDOUT,
                check=True,
                timeout=timeout_s,
            )
    except subprocess.TimeoutExpired as exc:
        cmd_str = " ".join(str(x) for x in exc.cmd) if isinstance(exc.cmd, (list, tuple)) else str(exc.cmd)
        if "sv2v" in cmd_str:
            timed_out_stage = "sv2v"
        elif "yosys" in cmd_str:
            timed_out_stage = "yosys"
        else:
            timed_out_stage = "opensta"
        error_msg = f"Timed out in {timed_out_stage} after {timeout_s}s"
        # Ensure stale STA/synth logs from earlier runs cannot masquerade as current results.
        if timed_out_stage in ("sv2v", "yosys"):
            sta_log.unlink(missing_ok=True)
    except subprocess.CalledProcessError as exc:
        timed_out_stage = "error"
        error_msg = f"Command failed with exit code {exc.returncode}"

    meta = {
        "key": key,
        "top": top,
        "sv_path": str(source_sv_path.relative_to(ROOT)),
        "sv_sha256": sha256_file(source_sv_path),
        "pkg_sha256": sha256_file(pkg_path),
        "ks_adder_sha256": sha256_file(ks_path) if ks_path.exists() else None,
        "status": "ok" if error_msg is None else ("timeout" if timed_out_stage in ("sv2v", "yosys", "opensta") else "error"),
        "timed_out": timed_out_stage in ("sv2v", "yosys", "opensta"),
        "timed_out_stage": timed_out_stage if timed_out_stage in ("sv2v", "yosys", "opensta") else None,
        "timeout_sec": timeout_s,
        "error": error_msg,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
    }
    meta_file.write_text(json.dumps(meta, indent=2) + "\n")
    return error_msg is None


def parse_yosys_log(log_path):
    if not os.path.exists(log_path):
        return None
    content = Path(log_path).read_text(errors="ignore")
    stat_section = content.split("=== design hierarchy ===")[-1] if "=== design hierarchy ===" in content else content

    cells_matches = re.findall(r"Number of cells:\s+(\d+)", stat_section)
    cell_count = int(cells_matches[-1]) if cells_matches else None

    area_matches = re.findall(r"Chip area for (?:top )?module '.*':\s+([\d\.]+)", stat_section)
    chip_area = float(area_matches[-1]) if area_matches else None

    dff_matches = re.findall(r"DFF[A-Z0-9_]*_X\d+\s+(\d+)", stat_section)
    dff_count = sum(int(x) for x in dff_matches) if cell_count is not None else None

    return {
        "cell_count": cell_count,
        "dff_count": dff_count,
        "chip_area_um2": chip_area,
        "gate_equivalent_ge": round(chip_area / NAND2_AREA, 1) if chip_area is not None else None,
    }


def parse_sta_log(log_path):
    if not os.path.exists(log_path):
        return None
    content = Path(log_path).read_text(errors="ignore")

    slack_matches = re.findall(r"([-\d\.]+)\s+slack \((?:MET|VIOLATED)\)", content)
    wns_matches = re.findall(r"(?:worst slack|wns) (?:max)?\s+([-\d\.]+)", content)
    if slack_matches:
        wns = float(slack_matches[-1])
    elif wns_matches:
        wns = float(wns_matches[-1])
    else:
        wns = None

    tns_matches = re.findall(r"tns (?:max)?\s+([-\d\.]+)", content)
    tns = float(tns_matches[-1]) if tns_matches else None

    delay_matches = re.findall(r"^\s*([\d\.]+)\s+data arrival time", content, re.MULTILINE)
    data_arrival = float(delay_matches[-1]) if delay_matches else None

    sp_matches = re.findall(r"Startpoint:\s+([^\n\r]+)", content)
    startpoint = sp_matches[-1].strip() if sp_matches else None

    ep_matches = re.findall(r"Endpoint:\s+([^\n\r]+)", content)
    endpoint = ep_matches[-1].strip() if ep_matches else None

    return {
        "wns_ns": wns,
        "tns_ns": tns,
        "max_delay_ns": data_arrival,
        "startpoint": startpoint,
        "endpoint": endpoint,
    }


def is_module_meta_fresh(key, sv_sha256, pkg_sha256, ks_adder_sha256):
    meta_file = BUILD_SYNTH / f"{key}_meta.json"
    if not meta_file.exists():
        return False, None, {}
    try:
        meta = json.loads(meta_file.read_text())
        recorded_sv_sha = meta.get("sv_sha256")
        recorded_pkg_sha = meta.get("pkg_sha256")
        recorded_ks_sha = meta.get("ks_adder_sha256")
        ks_ok = (ks_adder_sha256 is None) or (recorded_ks_sha == ks_adder_sha256)
        fresh = (
            isinstance(recorded_sv_sha, str)
            and isinstance(recorded_pkg_sha, str)
            and (recorded_sv_sha == sv_sha256)
            and (recorded_pkg_sha == pkg_sha256)
            and ks_ok
        )
        return fresh, recorded_sv_sha, meta
    except Exception:
        return False, None, {}


def main():
    parser = argparse.ArgumentParser(description="Fursoy Slice-1 Nangate45 Physical Synthesis & STA")
    parser.add_argument("--run-synth", action="store_true", help="Run sv2v + Yosys + OpenSTA")
    parser.add_argument("--skip-fresh", action="store_true", help="When --run-synth is set, skip modules with fresh hashes")
    parser.add_argument("--only", default="", help="Comma-separated module keys or names to synthesize when --run-synth is set")
    parser.add_argument("--gate-timeout", type=int, default=300, help="Per-tool timeout in seconds for gated blocks (default: 300)")
    parser.add_argument("--synth-timeout", type=int, default=120, help="Per-tool timeout in seconds for visibility blocks (default: 120)")
    args = parser.parse_args()

    run_synth = args.run_synth
    only_filter = {tok.strip() for tok in args.only.split(",") if tok.strip()}
    tools = check_toolchain()
    print("=" * 112)
    print("Fursoy Slice-1 Stage 1 Physical Synthesis & Static Timing Analysis (Nangate45 @ 500 MHz)")
    print("=" * 112)
    print(f"Yosys:    {tools['yosys']}")
    print(f"OpenSTA:  {tools['opensta']}")
    print(f"sv2v:     {tools['sv2v']}")
    print(f"Library:  {tools['liberty']}")
    print(f"ABC Flow: synth -top <mod> -noabc; dfflibmap; abc -D 1000 -constr tools/synth/abc.constr")
    print(f"Target:   500 MHz (clock period = 2.000 ns, NAND2_X1 area = {NAND2_AREA} um^2)")
    print("-" * 112)

    modules = [
        {
            "key": "branch_unit",
            "name": "fursoy_s1_branch_unit",
            "type": "Combinational",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
            "description": "Branch Resolution Unit (Shared Kogge-Stone adders + carry-free target match + prefix cmp)",
            "synth_log": BUILD_SYNTH / "branch_unit_synth.log",
            "sta_log": BUILD_SYNTH / "branch_unit_sta.log",
            "baseline_arrival_ns": 3.712,
            "baseline_wns_ns": -1.712,
            "bottleneck": "11-14 logic levels: shared Kogge-Stone adders & carry-free target compare (MET 500 MHz)",
        },
        {
            "key": "csr",
            "name": "fursoy_s1_csr",
            "type": "Sequential",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_csr.sv",
            "description": "CSR & Privileged Architecture Subsystem (M-mode / S-mode / U-mode)",
            "synth_log": BUILD_SYNTH / "csr_synth.log",
            "sta_log": BUILD_SYNTH / "csr_sta.log",
            "baseline_arrival_ns": 22.776,
            "baseline_wns_ns": -21.120,
            "bottleneck": "Registered mstatus_q + shared KS PC+4 precompute + flattened sys_illegal (MET 500 MHz)",
        },
        {
            "key": "dtlb",
            "name": "fursoy_s1_dtlb",
            "type": "Sequential",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_dtlb.sv",
            "description": "Architectural Sv39 Data TLB (64-entry base TLB + 8-entry superpage CAM)",
            "synth_log": BUILD_SYNTH / "dtlb_synth.log",
            "sta_log": BUILD_SYNTH / "dtlb_sta.log",
            "baseline_arrival_ns": 11.011,
            "baseline_wns_ns": -9.211,
            "bottleneck": "Decoupled registered Tree-PLRU update + ABC fanout buffering (MET 500 MHz)",
        },
        {
            "key": "itlb",
            "name": "fursoy_s1_itlb",
            "type": "Sequential",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_itlb.sv",
            "description": "Architectural Sv39 Instruction TLB (64-entry base TLB + superpage CAM)",
            "synth_log": BUILD_SYNTH / "itlb_synth.log",
            "sta_log": BUILD_SYNTH / "itlb_sta.log",
            "baseline_arrival_ns": 4.057,
            "baseline_wns_ns": -2.102,
            "bottleneck": "Decoupled registered Tree-PLRU update + ABC fanout buffering (MET 500 MHz)",
        },
        {
            "key": "agu",
            "name": "fursoy_s1_agu",
            "type": "Combinational",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_agu.sv",
            "description": "Address Generation Unit (Shared Kogge-Stone EA adder + alignment + byte mask)",
            "synth_log": BUILD_SYNTH / "agu_synth.log",
            "sta_log": BUILD_SYNTH / "agu_sta.log",
            "baseline_arrival_ns": 2.301,
            "baseline_wns_ns": -0.301,
            "bottleneck": "Shared 64-bit Kogge-Stone EA adder replaces behavioral carry chain (MET 500 MHz)",
        },
        {
            "key": "ptw",
            "name": "fursoy_s1_ptw",
            "type": "Sequential",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_ptw.sv",
            "description": "Centralized Shared Sv39 Hardware Page Table Walker",
            "synth_log": BUILD_SYNTH / "ptw_synth.log",
            "sta_log": BUILD_SYNTH / "ptw_sta.log",
            "baseline_arrival_ns": 1.956,
            "baseline_wns_ns": 0.005,
            "bottleneck": "TIMING MET at 500 MHz",
        },
        {
            "key": "decode",
            "name": "fursoy_s1_decode",
            "type": "Combinational",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_decode.sv",
            "description": "2-Wide Parallel Instruction Decoder",
            "synth_log": BUILD_SYNTH / "decode_synth.log",
            "sta_log": BUILD_SYNTH / "decode_sta.log",
            "baseline_arrival_ns": 0.875,
            "baseline_wns_ns": 1.125,
            "bottleneck": "TIMING MET at 500 MHz",
        },
        {
            "key": "alu",
            "name": "fursoy_s1_alu",
            "type": "Combinational",
            "gate": True,
            "sv_path": ROOT / "rtl/core/fursoy_s1_alu.sv",
            "description": "64-bit Integer Execution Unit (RV64I + Zba + Zbb + Shared KS Adder)",
            "synth_log": BUILD_SYNTH / "alu_synth.log",
            "sta_log": BUILD_SYNTH / "alu_sta.log",
            "baseline_arrival_ns": 3.823,
            "baseline_wns_ns": -1.823,
            "bottleneck": "Shared 64-bit Kogge-Stone adder + Zbb/shift cone (MET 500 MHz)",
        },
        {
            "key": "fma",
            "name": "fursoy_s1_fma",
            "type": "Sequential",
            "gate": False,
            "sv_path": ROOT / "rtl/core/fursoy_s1_fma.sv",
            "description": "IEEE-754 Pipelined FP32/FP64 FMA Unit",
            "synth_log": BUILD_SYNTH / "fma_synth.log",
            "sta_log": BUILD_SYNTH / "fma_sta.log",
            "baseline_arrival_ns": None,
            "baseline_wns_ns": None,
            "bottleneck": "Phase 1 expanded synthesis visibility (Nangate45 @ 500 MHz)",
        },
        {
            "key": "fconv",
            "name": "fursoy_s1_fconv",
            "type": "Sequential",
            "gate": False,
            "sv_path": ROOT / "rtl/core/fursoy_s1_fconv.sv",
            "description": "FP Move / Convert / Compare / Classify Unit",
            "synth_log": BUILD_SYNTH / "fconv_synth.log",
            "sta_log": BUILD_SYNTH / "fconv_sta.log",
            "baseline_arrival_ns": None,
            "baseline_wns_ns": None,
            "bottleneck": "Phase 1 expanded synthesis visibility (Nangate45 @ 500 MHz)",
        },
        {
            "key": "fdiv",
            "name": "fursoy_s1_fdiv",
            "type": "Sequential",
            "gate": False,
            "sv_path": ROOT / "rtl/core/fursoy_s1_fdiv.sv",
            "description": "Iterative Radix-4 SRT FDIV / FSQRT Unit",
            "synth_log": BUILD_SYNTH / "fdiv_synth.log",
            "sta_log": BUILD_SYNTH / "fdiv_sta.log",
            "baseline_arrival_ns": None,
            "baseline_wns_ns": None,
            "bottleneck": "Phase 1 expanded synthesis visibility (110b combinational isqrt/div unroll)",
        },
        {
            "key": "l1d",
            "name": "fursoy_s1_l1d",
            "type": "Sequential",
            "gate": False,
            "sv_path": ROOT / "rtl/core/fursoy_s1_l1d.sv",
            "description": "16 KiB 4-Way Multi-Bank L1 Data Cache + MSHR/WBB",
            "synth_log": BUILD_SYNTH / "l1d_synth.log",
            "sta_log": BUILD_SYNTH / "l1d_sta.log",
            "baseline_arrival_ns": None,
            "baseline_wns_ns": None,
            "bottleneck": "Phase 1 expanded synthesis visibility (131k-bit flop-array flattening)",
        },
        {
            "key": "int_iq",
            "name": "fursoy_s1_int_iq",
            "type": "Sequential",
            "gate": False,
            "sv_path": ROOT / "rtl/core/fursoy_s1_int_iq.sv",
            "description": "32-Entry Out-of-Order Integer Issue Queue",
            "synth_log": BUILD_SYNTH / "int_iq_synth.log",
            "sta_log": BUILD_SYNTH / "int_iq_sta.log",
            "baseline_arrival_ns": None,
            "baseline_wns_ns": None,
            "bottleneck": "Phase 1 expanded synthesis visibility (32x379b age-matrix ABC timeout)",
        },
        {
            "key": "bpu",
            "name": "fursoy_s1_bpu",
            "type": "Sequential",
            "gate": False,
            "sv_path": ROOT / "rtl/core/fursoy_s1_bpu.sv",
            "description": "TAGE-Lite + 512B BTB + Compact-Checkpoint 16-Entry RAS",
            "synth_log": BUILD_SYNTH / "bpu_synth.log",
            "sta_log": BUILD_SYNTH / "bpu_sta.log",
            "baseline_arrival_ns": None,
            "baseline_wns_ns": None,
            "bottleneck": "Phase 1 expanded synthesis visibility (~80k-bit TAGE/BTB flop-array flattening)",
        },
    ]

    execution_mode = "fresh_run" if run_synth else "cached_logs"
    pkg_path = ROOT / "rtl/core/fursoy_s1_pkg.sv"
    ks_path = ROOT / "rtl/core/fursoy_s1_ks_adder.sv"
    pkg_sha256 = sha256_file(pkg_path)
    ks_adder_sha256 = sha256_file(ks_path) if ks_path.exists() else None

    if run_synth:
        for m in modules:
            if only_filter and (m["key"] not in only_filter) and (m["name"] not in only_filter):
                continue
            sv_path = m["sv_path"]
            sv_sha256 = sha256_file(sv_path)
            if args.skip_fresh:
                y_cached = parse_yosys_log(m["synth_log"])
                s_cached = parse_sta_log(m["sta_log"])
                meta_fresh, _, meta_obj = is_module_meta_fresh(m["key"], sv_sha256, pkg_sha256, ks_adder_sha256)
                if meta_fresh and (
                    (y_cached is not None and s_cached is not None) or meta_obj.get("status") == "timeout"
                ):
                    print(f"[SKIP] {m['name']} already fresh in cache ({meta_obj.get('status', 'ok')})")
                    continue

            mod_timeout = args.gate_timeout if m["gate"] else args.synth_timeout
            print(f"[SYNTH] Running {m['name']} (scope={'gate' if m['gate'] else 'visibility'}, timeout={mod_timeout}s)...")
            run_module_synth_and_sta(
                m["key"], m["name"], sv_path, sv_path, m["type"] == "Sequential", timeout_s=mod_timeout
            )

    print(f"Mode:     {execution_mode}")
    print("-" * 112)

    results = []
    gate_cells = 0
    gate_area = 0.0
    gate_ge = 0.0
    gate_dffs = 0
    gate_complete_modules = 0
    gate_total_modules = sum(1 for m in modules if m["gate"])
    gate_stale_modules = []
    complete_modules = 0
    stale_modules = []
    timed_out_modules = []

    header = (
        f"{'Module Name':<23} {'Scope':<6} {'Cells':<8} {'DFFs':<7} {'kGE':<8} "
        f"{'Base Arr':<10} {'Opt Arr':<10} {'Base WNS':<11} {'Opt WNS (500M)':<14}"
    )
    print(header)
    print("-" * 112)

    for m in modules:
        y_data = parse_yosys_log(m["synth_log"])
        s_data = parse_sta_log(m["sta_log"])

        sv_sha256 = sha256_file(m["sv_path"])
        meta_fresh, recorded_sv_sha, meta_obj = is_module_meta_fresh(
            m["key"], sv_sha256, pkg_sha256, ks_adder_sha256
        )
        is_timeout = meta_fresh and (meta_obj.get("status") == "timeout")
        logs_fresh = ((y_data is not None) and (s_data is not None) and meta_fresh) or is_timeout
        if not logs_fresh:
            stale_modules.append(m["name"])
            if m["gate"]:
                gate_stale_modules.append(m["name"])
        if is_timeout:
            timed_out_modules.append(m["name"])

        cell_count = y_data.get("cell_count") if y_data else None
        dff_count = y_data.get("dff_count") if y_data else None
        area = y_data.get("chip_area_um2") if y_data else None
        ge = y_data.get("gate_equivalent_ge") if y_data else None
        kge = round(ge / 1000.0, 2) if ge is not None else None

        arrival = s_data.get("max_delay_ns") if s_data else None
        wns = s_data.get("wns_ns") if s_data else None
        tns = s_data.get("tns_ns") if s_data else None

        module_complete = all(
            v is not None for v in (cell_count, dff_count, area, ge, kge, arrival, wns, tns)
        )
        if module_complete:
            complete_modules += 1
            if m["gate"]:
                gate_complete_modules += 1
                gate_cells += cell_count
                gate_dffs += dff_count
                gate_area += area
                gate_ge += ge

        base_arr = m["baseline_arrival_ns"]
        base_wns = m["baseline_wns_ns"]

        scope_str = "GATE" if m["gate"] else "VIS"
        cell_str = str(cell_count) if cell_count is not None else ("TIMEOUT" if is_timeout else "N/A")
        dff_str = str(dff_count) if dff_count is not None else "-"
        kge_str = f"{kge:.2f}" if kge is not None else "-"
        base_arr_str = f"{base_arr:.3f} ns" if base_arr is not None else "N/A"
        arrival_str = f"{arrival:.3f} ns" if arrival is not None else ("TIMEOUT" if is_timeout else "N/A")
        base_wns_str = f"{base_wns:+.3f} ns" if base_wns is not None else "N/A"
        wns_str = f"{wns:+.3f} ns" if wns is not None else ("TIMEOUT" if is_timeout else "N/A")

        print(
            f"{m['name']:<23} {scope_str:<6} {cell_str:<8} {dff_str:<7} {kge_str:<8} "
            f"{base_arr_str:<10} {arrival_str:<10} {base_wns_str:<11} {wns_str:<14}"
        )

        mod_status = (
            "timeout"
            if is_timeout
            else ("met" if (module_complete and wns >= 0.0) else ("violated" if module_complete else "missing"))
        )

        results.append(
            {
                "name": m["name"],
                "type": m["type"],
                "gate": m["gate"],
                "status": mod_status,
                "timed_out_stage": meta_obj.get("timed_out_stage") if is_timeout else None,
                "description": m["description"],
                "sv_path": str(m["sv_path"].relative_to(ROOT)),
                "sv_sha256": sv_sha256,
                "recorded_sv_sha256": recorded_sv_sha,
                "logs_fresh": logs_fresh,
                "data_complete": module_complete,
                "cell_count": cell_count,
                "dff_count": dff_count,
                "area_um2": area,
                "kge": kge,
                "baseline_arrival_ns": base_arr,
                "max_delay_ns": arrival,
                "baseline_wns_ns_at_500mhz": base_wns,
                "wns_ns_at_500mhz": wns,
                "tns_ns_at_500mhz": tns,
                "critical_path": {
                    "startpoint": s_data.get("startpoint") if s_data else None,
                    "endpoint": s_data.get("endpoint") if s_data else None,
                    "bottleneck": m["bottleneck"],
                },
            }
        )

    gate_modules_meeting = sum(
        1
        for r in results
        if r["gate"] and r["wns_ns_at_500mhz"] is not None and r["wns_ns_at_500mhz"] >= 0.0
    )
    all_modules_meeting = sum(
        1 for r in results if r["wns_ns_at_500mhz"] is not None and r["wns_ns_at_500mhz"] >= 0.0
    )
    gate_data_complete = (gate_complete_modules == gate_total_modules)
    gate_timing_closed = gate_data_complete and (gate_modules_meeting == gate_total_modules)
    gate_logs_fresh = (len(gate_stale_modules) == 0)

    total_label = f"GATE TOTAL ({gate_total_modules} Blocks)"
    print("-" * 112)
    if gate_data_complete:
        print(
            f"{total_label:<23} {'GATE':<6} {gate_cells:<8} {gate_dffs:<7} {round(gate_ge / 1000.0, 2):<8.2f} "
            f"(Gate area: {gate_area:.1f} um^2; All blocks: {complete_modules}/{len(results)} complete, "
            f"{len(timed_out_modules)} timed out)"
        )
    else:
        print(
            f"{total_label:<23} {'GATE':<6} {'INCOMP':<8} {'-':<7} {'-':<8} "
            f"(Incomplete gated logs: {gate_complete_modules}/{gate_total_modules})"
        )
    print("=" * 112)

    report = {
        "title": "Fursoy Slice-1 Stage 1 Physical Synthesis & Timing Analysis",
        "execution_mode": execution_mode,
        "pkg_sha256": pkg_sha256,
        "ks_adder_sha256": ks_adder_sha256,
        "library": {
            "name": "NangateOpenCellLibrary",
            "process_node": "45nm",
            "operating_condition": "Typical (1.10V, 25C)",
            "nand2_x1_area_um2": NAND2_AREA,
        },
        "toolchain": tools,
        "clock_constraint": {"frequency_mhz": 500.0, "period_ns": 2.0},
        "summary": {
            "total_cells": gate_cells if gate_data_complete else None,
            "total_dffs": gate_dffs if gate_data_complete else None,
            "total_area_um2": round(gate_area, 2) if gate_data_complete else None,
            "total_kge": round(gate_ge / 1000.0, 2) if gate_data_complete else None,
            "gate_modules_meeting_500mhz": gate_modules_meeting,
            "gate_modules_evaluated": gate_total_modules,
            "gate_modules_with_complete_data": gate_complete_modules,
            "gate_data_complete": gate_data_complete,
            "gate_timing_closed": gate_timing_closed,
            "gate_all_logs_fresh": gate_logs_fresh,
            "modules_meeting_500mhz": all_modules_meeting,
            "total_modules_evaluated": len(results),
            "modules_with_complete_data": complete_modules,
            "timed_out_modules": timed_out_modules,
            "data_complete": gate_data_complete,
            "timing_closed": gate_timing_closed,
            "all_logs_fresh": (len(stale_modules) == 0),
            "stale_modules": stale_modules,
        },
        "modules": results,
    }

    BUILD_SYNTH.mkdir(parents=True, exist_ok=True)
    report_file = BUILD_SYNTH / "s1_synth_report.json"
    with open(report_file, "w") as f:
        json.dump(report, f, indent=2)

    if gate_stale_modules:
        print(f"\n[WARN] Stale or unverified cached gated logs vs current RTL for: {', '.join(gate_stale_modules)}")
    if timed_out_modules:
        print(f"[INFO] Visibility blocks exceeding {args.synth_timeout}s timeout: {', '.join(timed_out_modules)}")

    if gate_data_complete and gate_timing_closed and gate_logs_fresh:
        print(f"\n[PASS] Physical Synthesis & Timing Report generated at: {report_file}")
    else:
        print(
            f"\n[FAIL] Gated Synthesis/STA failed (data_complete={gate_data_complete}, "
            f"timing_closed={gate_timing_closed}, all_logs_fresh={gate_logs_fresh}, "
            f"gate_complete={gate_complete_modules}/{gate_total_modules}, "
            f"gate_meeting_500mhz={gate_modules_meeting}/{gate_total_modules}). Report: {report_file}"
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
