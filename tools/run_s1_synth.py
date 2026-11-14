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


def run_module_synth_and_sta(key, top, sv_path, source_sv_path, is_sequential):
    BUILD_SYNTH.mkdir(parents=True, exist_ok=True)
    CONSTR_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not CONSTR_PATH.exists():
        CONSTR_PATH.write_text("set_driving_cell BUF_X2\nset_load 2.0\n")

    sv2v_bin = shutil.which("sv2v") or "sv2v"
    pkg_path = ROOT / "rtl/core/fursoy_s1_pkg.sv"
    v_file = BUILD_SYNTH / f"{key}.v"
    net_file = BUILD_SYNTH / f"{key}_netlist.v"
    synth_log = BUILD_SYNTH / f"{key}_synth.log"
    sta_tcl = BUILD_SYNTH / f"{key}_sta.tcl"
    sta_log = BUILD_SYNTH / f"{key}_sta.log"
    meta_file = BUILD_SYNTH / f"{key}_meta.json"

    subprocess.run(
        [sv2v_bin, "-DSYNTHESIS", f"-I{ROOT / 'rtl/core'}", str(pkg_path), str(sv_path)],
        stdout=open(v_file, "w"),
        check=True,
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
    subprocess.run(["yosys", "-p", ys_cmd], stdout=open(synth_log, "w"), stderr=subprocess.STDOUT, check=True)

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
    subprocess.run([str(STA_BIN), "-exit", str(sta_tcl)], stdout=open(sta_log, "w"), stderr=subprocess.STDOUT, check=True)

    meta = {
        "key": key,
        "top": top,
        "sv_path": str(source_sv_path.relative_to(ROOT)),
        "sv_sha256": sha256_file(source_sv_path),
        "pkg_sha256": sha256_file(pkg_path),
        "generated_utc": datetime.now(timezone.utc).isoformat(),
    }
    meta_file.write_text(json.dumps(meta, indent=2) + "\n")


def parse_yosys_log(log_path):
    if not os.path.exists(log_path):
        return None
    content = Path(log_path).read_text(errors="ignore")

    cells_matches = re.findall(r"Number of cells:\s+(\d+)", content)
    cell_count = int(cells_matches[-1]) if cells_matches else None

    area_matches = re.findall(r"Chip area for module '.*':\s+([\d\.]+)", content)
    chip_area = float(area_matches[-1]) if area_matches else None

    dff_matches = re.findall(r"DFF[A-Z0-9_]*_X\d+\s+(\d+)", content)
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


def main():
    run_synth = "--run-synth" in sys.argv
    tools = check_toolchain()
    print("=" * 105)
    print("Fursoy Slice-1 Stage 1 Physical Synthesis & Static Timing Analysis (Nangate45 @ 500 MHz)")
    print("=" * 105)
    print(f"Yosys:    {tools['yosys']}")
    print(f"OpenSTA:  {tools['opensta']}")
    print(f"sv2v:     {tools['sv2v']}")
    print(f"Library:  {tools['liberty']}")
    print(f"ABC Flow: synth -top <mod> -noabc; dfflibmap; abc -D 1000 -constr tools/synth/abc.constr")
    print(f"Target:   500 MHz (clock period = 2.000 ns, NAND2_X1 area = {NAND2_AREA} um^2)")
    print("-" * 105)

    modules = [
        {
            "key": "branch_unit",
            "name": "fursoy_s1_branch_unit",
            "type": "Combinational",
            "sv_path": ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
            "description": "Branch Resolution Unit (Parallel Kogge-Stone adders + carry-free target match + prefix cmp)",
            "synth_log": BUILD_SYNTH / "branch_unit_synth.log",
            "sta_log": BUILD_SYNTH / "branch_unit_sta.log",
            "baseline_arrival_ns": 3.712,
            "baseline_wns_ns": -1.712,
            "bottleneck": "11-14 logic levels (down from 68): parallel prefix adders & carry-free target compare (MET +1.460 ns)",
        },
        {
            "key": "csr",
            "name": "fursoy_s1_csr",
            "type": "Sequential",
            "sv_path": ROOT / "rtl/core/fursoy_s1_csr.sv",
            "description": "CSR & Privileged Architecture Subsystem (M-mode / S-mode / U-mode)",
            "synth_log": BUILD_SYNTH / "csr_synth.log",
            "sta_log": BUILD_SYNTH / "csr_sta.log",
            "baseline_arrival_ns": 22.776,
            "baseline_wns_ns": -21.120,
            "bottleneck": "ABC buffer trees (BUF_X2/X4/X8) & gate sizing closed 510-load fanout (MET +0.204 ns, 0 TNS)",
        },
        {
            "key": "dtlb",
            "name": "fursoy_s1_dtlb",
            "type": "Sequential",
            "sv_path": ROOT / "rtl/core/fursoy_s1_lsu.sv",
            "description": "Architectural Sv39 Data TLB (64-entry base TLB + 8-entry superpage CAM)",
            "synth_log": BUILD_SYNTH / "dtlb_synth.log",
            "sta_log": BUILD_SYNTH / "dtlb_sta.log",
            "baseline_arrival_ns": 11.011,
            "baseline_wns_ns": -9.211,
            "bottleneck": "Decoupled registered Tree-PLRU update + ABC fanout buffering (MET +0.551 ns, 0 TNS)",
        },
        {
            "key": "itlb",
            "name": "fursoy_s1_itlb",
            "type": "Sequential",
            "sv_path": ROOT / "rtl/core/fursoy_s1_itlb.sv",
            "description": "Architectural Sv39 Instruction TLB (64-entry base TLB + superpage CAM)",
            "synth_log": BUILD_SYNTH / "itlb_synth.log",
            "sta_log": BUILD_SYNTH / "itlb_sta.log",
            "baseline_arrival_ns": 4.057,
            "baseline_wns_ns": -2.102,
            "bottleneck": "Decoupled registered Tree-PLRU update + ABC fanout buffering (MET +0.602 ns, 0 TNS)",
        },
        {
            "key": "agu",
            "name": "fursoy_s1_agu",
            "type": "Combinational",
            "sv_path": ROOT / "rtl/core/fursoy_s1_agu.sv",
            "description": "Port 2 Address Generation Unit (EA adder + alignment + byte mask)",
            "synth_log": BUILD_SYNTH / "agu_synth.log",
            "sta_log": BUILD_SYNTH / "agu_sta.log",
            "baseline_arrival_ns": 2.301,
            "baseline_wns_ns": -0.301,
            "bottleneck": "Timing-driven ABC sizing closed 64-bit EA adder at 500 MHz (MET +0.099 ns, 0 TNS)",
        },
        {
            "key": "ptw",
            "name": "fursoy_s1_ptw",
            "type": "Sequential",
            "sv_path": ROOT / "rtl/core/fursoy_s1_ptw.sv",
            "description": "Centralized Shared Sv39 Hardware Page Table Walker",
            "synth_log": BUILD_SYNTH / "ptw_synth.log",
            "sta_log": BUILD_SYNTH / "ptw_sta.log",
            "baseline_arrival_ns": 1.956,
            "baseline_wns_ns": 0.005,
            "bottleneck": "TIMING MET: WNS +1.013 ns, 0 TNS (100% timing closed at 500 MHz)",
        },
        {
            "key": "decode",
            "name": "fursoy_s1_decode",
            "type": "Combinational",
            "sv_path": ROOT / "rtl/core/fursoy_s1_decode.sv",
            "description": "2-Wide Parallel Instruction Decoder",
            "synth_log": BUILD_SYNTH / "decode_synth.log",
            "sta_log": BUILD_SYNTH / "decode_sta.log",
            "baseline_arrival_ns": 0.875,
            "baseline_wns_ns": 1.125,
            "bottleneck": "TIMING MET: 0.663 ns arrival, WNS +1.337 ns at 500 MHz",
        },
        {
            "key": "alu",
            "name": "fursoy_s1_alu",
            "type": "Combinational",
            "sv_path": ROOT / "rtl/core/fursoy_s1_alu.sv",
            "description": "64-bit Integer Execution Unit (RV64I + Zba + Zbb)",
            "synth_log": BUILD_SYNTH / "alu_synth.log",
            "sta_log": BUILD_SYNTH / "alu_sta.log",
            "baseline_arrival_ns": 3.823,
            "baseline_wns_ns": -1.823,
            "bottleneck": "64-bit Zbb/shift/arithmetic cone (TNS reduced from -116.48 ns to -14.17 ns)",
        },
    ]

    execution_mode = "fresh_run" if run_synth else "cached_logs"
    pkg_path = ROOT / "rtl/core/fursoy_s1_pkg.sv"
    pkg_sha256 = sha256_file(pkg_path)

    if run_synth:
        for m in modules:
            sv_path = m["sv_path"]
            if m["key"] == "dtlb":
                lsu_text = sv_path.read_text()
                s_idx = lsu_text.index("module fursoy_s1_dtlb")
                e_idx = lsu_text.index("endmodule", s_idx) + len("endmodule\n")
                tmp_sv = BUILD_SYNTH / "dtlb_extract.sv"
                tmp_sv.write_text(lsu_text[s_idx:e_idx])
                run_module_synth_and_sta(m["key"], m["name"], tmp_sv, sv_path, m["type"] == "Sequential")
                tmp_sv.unlink(missing_ok=True)
            else:
                run_module_synth_and_sta(m["key"], m["name"], sv_path, sv_path, m["type"] == "Sequential")

    print(f"Mode:     {execution_mode}")
    print("-" * 105)

    results = []
    total_cells = 0
    total_area = 0.0
    total_ge = 0.0
    total_dffs = 0
    complete_modules = 0
    stale_modules = []

    header = (
        f"{'Module Name':<23} {'Cells':<8} {'DFFs':<7} {'kGE':<8} "
        f"{'Base Arr':<10} {'Opt Arr':<10} {'Base WNS':<11} {'Opt WNS (500M)':<14}"
    )
    print(header)
    print("-" * 105)

    for m in modules:
        y_data = parse_yosys_log(m["synth_log"])
        s_data = parse_sta_log(m["sta_log"])

        sv_sha256 = sha256_file(m["sv_path"])
        meta_file = BUILD_SYNTH / f"{m['key']}_meta.json"
        recorded_sv_sha = None
        meta_fresh = False
        if meta_file.exists():
            try:
                meta = json.loads(meta_file.read_text())
                recorded_sv_sha = meta.get("sv_sha256")
                recorded_pkg_sha = meta.get("pkg_sha256")
                meta_fresh = (
                    isinstance(recorded_sv_sha, str)
                    and isinstance(recorded_pkg_sha, str)
                    and (recorded_sv_sha == sv_sha256)
                    and (recorded_pkg_sha == pkg_sha256)
                )
            except Exception:
                meta_fresh = False
        logs_fresh = (y_data is not None) and (s_data is not None) and meta_fresh
        if not logs_fresh:
            stale_modules.append(m["name"])

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

        base_arr = m["baseline_arrival_ns"]
        base_wns = m["baseline_wns_ns"]

        cell_str = str(cell_count) if cell_count is not None else "N/A"
        dff_str = str(dff_count) if dff_count is not None else "N/A"
        kge_str = f"{kge:.2f}" if kge is not None else "N/A"
        base_arr_str = f"{base_arr:.3f} ns"
        arrival_str = f"{arrival:.3f} ns" if arrival is not None else "N/A"
        base_wns_str = f"{base_wns:+.3f} ns"
        wns_str = f"{wns:+.3f} ns" if wns is not None else "N/A"

        if cell_count is not None:
            total_cells += cell_count
        if dff_count is not None:
            total_dffs += dff_count
        if area is not None:
            total_area += area
        if ge is not None:
            total_ge += ge

        print(
            f"{m['name']:<23} {cell_str:<8} {dff_str:<7} {kge_str:<8} "
            f"{base_arr_str:<10} {arrival_str:<10} {base_wns_str:<11} {wns_str:<14}"
        )

        results.append(
            {
                "name": m["name"],
                "type": m["type"],
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

    modules_meeting = sum(
        1 for r in results
        if r["wns_ns_at_500mhz"] is not None and r["wns_ns_at_500mhz"] >= 0.0
    )
    data_complete = (complete_modules == len(results))
    timing_closed = data_complete and (modules_meeting == len(results))
    all_logs_fresh = (len(stale_modules) == 0)

    print("-" * 105)
    if data_complete:
        print(
            f"{'TOTAL (8 Core Blocks)':<23} {total_cells:<8} {total_dffs:<7} {round(total_ge / 1000.0, 2):<8.2f} "
            f"(Total standard-cell area: {total_area:.1f} um^2)"
        )
    else:
        print(
            f"{'TOTAL (8 Core Blocks)':<23} {'INCOMP':<8} {'-':<7} {'-':<8} "
            f"(Incomplete synthesis/STA logs: {complete_modules}/{len(results)})"
        )
    print("=" * 105)

    report = {
        "title": "Fursoy Slice-1 Stage 1 Physical Synthesis & Timing Analysis",
        "execution_mode": execution_mode,
        "pkg_sha256": pkg_sha256,
        "library": {
            "name": "NangateOpenCellLibrary",
            "process_node": "45nm",
            "operating_condition": "Typical (1.10V, 25C)",
            "nand2_x1_area_um2": NAND2_AREA,
        },
        "toolchain": tools,
        "clock_constraint": {"frequency_mhz": 500.0, "period_ns": 2.0},
        "summary": {
            "total_cells": total_cells if data_complete else None,
            "total_dffs": total_dffs if data_complete else None,
            "total_area_um2": round(total_area, 2) if data_complete else None,
            "total_kge": round(total_ge / 1000.0, 2) if data_complete else None,
            "modules_meeting_500mhz": modules_meeting,
            "total_modules_evaluated": len(results),
            "modules_with_complete_data": complete_modules,
            "data_complete": data_complete,
            "timing_closed": timing_closed,
            "all_logs_fresh": all_logs_fresh,
            "stale_modules": stale_modules,
        },
        "modules": results,
    }

    BUILD_SYNTH.mkdir(parents=True, exist_ok=True)
    report_file = BUILD_SYNTH / "s1_synth_report.json"
    with open(report_file, "w") as f:
        json.dump(report, f, indent=2)

    if stale_modules:
        print(f"\n[WARN] Stale or unverified cached logs vs current RTL for: {', '.join(stale_modules)}")

    if data_complete and timing_closed and all_logs_fresh:
        print(f"\n[PASS] Physical Synthesis & Timing Report generated at: {report_file}")
    else:
        print(
            f"\n[FAIL] Synthesis/STA gate failed (data_complete={data_complete}, "
            f"timing_closed={timing_closed}, all_logs_fresh={all_logs_fresh}, "
            f"complete={complete_modules}/{len(results)}, "
            f"meeting_500mhz={modules_meeting}/{len(results)}). Report: {report_file}"
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
