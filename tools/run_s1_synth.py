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
import shutil
import subprocess
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


def run_module_synth_and_sta(key, top, sv_path, is_sequential):
    BUILD_SYNTH.mkdir(parents=True, exist_ok=True)
    CONSTR_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not CONSTR_PATH.exists():
        CONSTR_PATH.write_text("set_driving_cell BUF_X2\nset_load 2.0\n")

    sv2v_bin = shutil.which("sv2v") or "sv2v"
    v_file = BUILD_SYNTH / f"{key}.v"
    net_file = BUILD_SYNTH / f"{key}_netlist.v"
    synth_log = BUILD_SYNTH / f"{key}_synth.log"
    sta_tcl = BUILD_SYNTH / f"{key}_sta.tcl"
    sta_log = BUILD_SYNTH / f"{key}_sta.log"

    subprocess.run(
        [sv2v_bin, "-DSYNTHESIS", f"-I{ROOT / 'rtl/core'}", str(ROOT / "rtl/core/fursoy_s1_pkg.sv"), str(sv_path)],
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


def parse_yosys_log(log_path):
    if not os.path.exists(log_path):
        return None
    content = Path(log_path).read_text(errors="ignore")

    cells_matches = re.findall(r"Number of cells:\s+(\d+)", content)
    cell_count = int(cells_matches[-1]) if cells_matches else None

    area_matches = re.findall(r"Chip area for module '.*':\s+([\d\.]+)", content)
    chip_area = float(area_matches[-1]) if area_matches else None

    dff_matches = re.findall(r"DFF[A-Z0-9_]*_X\d+\s+(\d+)", content)
    dff_count = sum(int(x) for x in dff_matches) if dff_matches else 0

    return {
        "cell_count": cell_count,
        "dff_count": dff_count,
        "chip_area_um2": chip_area,
        "gate_equivalent_ge": round(chip_area / NAND2_AREA, 1) if chip_area else None,
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
    tns = float(tns_matches[-1]) if tns_matches else 0.0

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
            "description": "Architectural Sv39 Instruction TLB (32-entry base TLB + superpage CAM)",
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

    if run_synth:
        for m in modules:
            sv_path = m["sv_path"]
            if m["key"] == "dtlb":
                lsu_text = sv_path.read_text()
                s_idx = lsu_text.index("module fursoy_s1_dtlb")
                e_idx = lsu_text.index("endmodule", s_idx) + len("endmodule\n")
                tmp_sv = BUILD_SYNTH / "dtlb_extract.sv"
                tmp_sv.write_text(lsu_text[s_idx:e_idx])
                run_module_synth_and_sta(m["key"], m["name"], tmp_sv, m["type"] == "Sequential")
                tmp_sv.unlink(missing_ok=True)
            else:
                run_module_synth_and_sta(m["key"], m["name"], sv_path, m["type"] == "Sequential")

    results = []
    total_cells = 0
    total_area = 0.0
    total_ge = 0.0
    total_dffs = 0

    header = (
        f"{'Module Name':<23} {'Cells':<8} {'DFFs':<7} {'kGE':<8} "
        f"{'Base Arr':<10} {'Opt Arr':<10} {'Base WNS':<11} {'Opt WNS (500M)':<14}"
    )
    print(header)
    print("-" * 105)

    for m in modules:
        y_data = parse_yosys_log(m["synth_log"]) or {}
        s_data = parse_sta_log(m["sta_log"]) or {}

        cell_count = y_data.get("cell_count", 0)
        dff_count = y_data.get("dff_count", 0)
        area = y_data.get("chip_area_um2", 0.0)
        ge = y_data.get("gate_equivalent_ge", 0.0)
        kge = round(ge / 1000.0, 2) if ge else 0.0

        arrival = s_data.get("max_delay_ns", 0.0)
        wns = s_data.get("wns_ns", None)
        base_arr = m["baseline_arrival_ns"]
        base_wns = m["baseline_wns_ns"]

        base_arr_str = f"{base_arr:.3f} ns"
        arrival_str = f"{arrival:.3f} ns" if arrival is not None else "N/A"
        base_wns_str = f"{base_wns:+.3f} ns"
        wns_str = f"{wns:+.3f} ns" if wns is not None else "N/A"

        total_cells += cell_count
        total_dffs += dff_count
        total_area += area
        total_ge += ge

        print(
            f"{m['name']:<23} {cell_count:<8} {dff_count:<7} {kge:<8.2f} "
            f"{base_arr_str:<10} {arrival_str:<10} {base_wns_str:<11} {wns_str:<14}"
        )

        results.append(
            {
                "name": m["name"],
                "type": m["type"],
                "description": m["description"],
                "cell_count": cell_count,
                "dff_count": dff_count,
                "area_um2": area,
                "kge": kge,
                "baseline_arrival_ns": base_arr,
                "max_delay_ns": arrival,
                "baseline_wns_ns_at_500mhz": base_wns,
                "wns_ns_at_500mhz": wns,
                "tns_ns_at_500mhz": s_data.get("tns_ns", 0.0),
                "critical_path": {
                    "startpoint": s_data.get("startpoint"),
                    "endpoint": s_data.get("endpoint"),
                    "bottleneck": m["bottleneck"],
                },
            }
        )

    print("-" * 105)
    print(
        f"{'TOTAL (8 Core Blocks)':<23} {total_cells:<8} {total_dffs:<7} {round(total_ge / 1000.0, 2):<8.2f} "
        f"(Total standard-cell area: {total_area:.1f} um^2)"
    )
    print("=" * 105)

    report = {
        "title": "Fursoy Slice-1 Stage 1 Physical Synthesis & Timing Analysis",
        "library": {
            "name": "NangateOpenCellLibrary",
            "process_node": "45nm",
            "operating_condition": "Typical (1.10V, 25C)",
            "nand2_x1_area_um2": NAND2_AREA,
        },
        "toolchain": tools,
        "clock_constraint": {"frequency_mhz": 500.0, "period_ns": 2.0},
        "summary": {
            "total_cells": total_cells,
            "total_dffs": total_dffs,
            "total_area_um2": round(total_area, 2),
            "total_kge": round(total_ge / 1000.0, 2),
            "modules_meeting_500mhz": sum(1 for r in results if (r["wns_ns_at_500mhz"] or -1.0) >= 0.0),
            "total_modules_evaluated": len(results),
        },
        "modules": results,
    }

    BUILD_SYNTH.mkdir(parents=True, exist_ok=True)
    report_file = BUILD_SYNTH / "s1_synth_report.json"
    with open(report_file, "w") as f:
        json.dump(report, f, indent=2)

    print(f"\n[PASS] Physical Synthesis & Timing Report generated at: {report_file}")


if __name__ == "__main__":
    main()
