#!/usr/bin/env python3
"""
Fursoy Slice-2 Physical Logic Synthesis & Static Timing Analysis (STA)
Evaluates standard cell area and 500 MHz (period = 2.000 ns) timing on Nangate45
(45nm, 1.10V, 25C) for:
  - All 8 Slice-1 gated core blocks (per docs/architecture/slice2-smp-v1.md Section 5)
  - All 6 Slice-2 / coherence-enabled blocks:
      fursoy_s2_clint, fursoy_s2_plic, fursoy_s2_mmio_xbar,
      fursoy_s2_l2, fursoy_s2_coherence_mgr, fursoy_s1_l1d (SMP_COHERENCE_EN=1)
During synthesis/OpenSTA, large SRAM bit-arrays (L1D bank_data and L2 data_arr)
are abstracted via `FURSOY_SYNTH_SRAM_BB` blackboxes backed by Liberty timing
arcs in `tools/synth/lib/fursoy_sram_macros.lib` (0.350 ns L1D / 0.400 ns L2
read-out, 0.150 ns setup / 0.050 ns hold) so Yosys/ABC and OpenSTA constrain
control, tag CAM, PLRU, MSHR, WBB, and downstream SRAM read-out paths cleanly.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB_PATH = (
    Path(os.environ["FURSOY_LIBERTY"])
    if os.environ.get("FURSOY_LIBERTY")
    else (ROOT / "tools/synth/lib/NangateOpenCellLibrary_typical.lib")
)
SRAM_LIB_PATH = ROOT / "tools/synth/lib/fursoy_sram_macros.lib"
CONSTR_PATH = ROOT / "tools/synth/abc.constr"
_LOCAL_STA_WRAPPER = ROOT / "tools/synth/bin/sta"
_LOCAL_STA_REAL = ROOT / "build/tools_pkg/openroad_root/usr/bin/sta"
STA_BIN = Path(
    shutil.which("sta")
    or shutil.which("opensta")
    or (str(_LOCAL_STA_WRAPPER) if (_LOCAL_STA_WRAPPER.exists() and _LOCAL_STA_REAL.exists()) else "sta")
)
BUILD_SYNTH_S1 = ROOT / "build/synth"
BUILD_SYNTH_S2 = ROOT / "build/synth_s2"

NAND2_AREA = 0.798  # um^2 in Nangate45


def check_toolchain():
    tools = {}
    for name, cmd in [
        ("yosys", ["yosys", "-V"]),
        ("opensta", [str(STA_BIN), "-version"]),
        ("sv2v", [shutil.which("sv2v") or "sv2v", "--version"]),
    ]:
        try:
            tools[name] = subprocess.check_output(cmd, text=True).strip()
        except Exception as exc:
            tools[name] = f"Missing: {exc}"
    if LIB_PATH.exists():
        tools["liberty"] = f"Nangate45 Typical (size={LIB_PATH.stat().st_size} bytes)"
    else:
        tools["liberty"] = "Missing"
    return tools


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def combo_sha(paths):
    h = hashlib.sha256()
    for p in paths:
        h.update(str(p.relative_to(ROOT)).encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()


def normalize_comb_sensitivity(v_text: str) -> str:
    """Replace sv2v explicit sensitivity lists on combinational always blocks with always @(*)."""
    out = []
    for line in v_text.splitlines():
        if line.lstrip().startswith("always @(") and "posedge" not in line and "negedge" not in line:
            line = re.sub(r"always @\(.*?\)", "always @(*)", line)
        out.append(line)
    return "\n".join(out) + "\n"


def generate_sram_macro_lib_text() -> str:
    """Deterministically generate Liberty timing stubs for abstracted Slice-2 SRAM macros (P1-1)."""
    def _bit_list(name: str, width: int) -> str:
        return " ".join(f"{name}[{i}]" for i in range(width))

    def _comb_timing(rel_pins: str, delay_ns: str) -> list[str]:
        return [
            "      timing () {",
            f'        related_pin : "{rel_pins}";',
            "        timing_sense : non_unate;",
            "        timing_type : combinational;",
            f'        cell_rise (sram_delay_2x2) {{ values ("{delay_ns}, {delay_ns}", "{delay_ns}, {delay_ns}"); }}',
            f'        cell_fall (sram_delay_2x2) {{ values ("{delay_ns}, {delay_ns}", "{delay_ns}, {delay_ns}"); }}',
            '        rise_transition (sram_delay_2x2) { values ("0.025, 0.025", "0.025, 0.025"); }',
            '        fall_transition (sram_delay_2x2) { values ("0.025, 0.025", "0.025, 0.025"); }',
            "      }",
        ]

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
            '        rise_constraint (sram_constr_1x1) { values ("0.150"); }',
            '        fall_constraint (sram_constr_1x1) { values ("0.150"); }',
            "      }",
            "      timing () {",
            '        related_pin : "clk_i";',
            "        timing_type : hold_rising;",
            '        rise_constraint (sram_constr_1x1) { values ("0.050"); }',
            '        fall_constraint (sram_constr_1x1) { values ("0.050"); }',
            "      }",
            "    }",
        ])
        return lines

    def _comb_input_bus(name: str, width: int) -> list[str]:
        return [
            f"    bus ({name}) {{",
            f"      bus_type : bus{width};",
            "      direction : input;",
            "      capacitance : 2.0;",
            "    }",
        ]

    def _comb_output_bus(name: str, width: int, rels: list[tuple[str, int]], delay_ns: str) -> list[str]:
        lines = [
            f"    bus ({name}) {{",
            f"      bus_type : bus{width};",
            "      direction : output;",
            "      max_capacitance : 100.0;",
        ]
        for rname, rwidth in rels:
            lines.extend(_comb_timing(_bit_list(rname, rwidth), delay_ns))
        lines.append("    }")
        return lines

    lines = [
        "/* Fursoy Slice-2 Liberty Timing Stubs for Abstracted SRAM Macros (45nm Typical 1.10V 25C) */",
        "library (fursoy_sram_macros) {",
        "  technology (cmos);",
        "  delay_model : table_lookup;",
        '  time_unit : "1ns";',
        '  leakage_power_unit : "1nW";',
        '  voltage_unit : "1V";',
        '  current_unit : "1mA";',
        '  pulling_resistance_unit : "1kohm";',
        "  capacitive_load_unit (1,ff);",
        "",
        "  nom_process : 1.00;",
        "  nom_temperature : 25.00;",
        "  nom_voltage : 1.10;",
        "",
        "  operating_conditions (typical) {",
        "    process : 1.00;",
        "    voltage : 1.10;",
        "    temperature : 25.00;",
        "  }",
        "  default_operating_conditions : typical;",
        "",
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
        "",
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
        "",
    ]
    for w in (2, 3, 6, 8, 9, 64, 256, 512, 4096):
        lines.extend([
            f"  type (bus{w}) {{",
            "    base_type : array;",
            "    data_type : bit;",
            f"    bit_width : {w};",
            f"    bit_from : {w - 1};",
            "    bit_to : 0;",
            "    downto : true;",
            "  }",
        ])

    # Cell 1: fursoy_s1_l1d_bank_sram
    lines.extend([
        "  cell (fursoy_s1_l1d_bank_sram) {",
        "    dont_use : true;",
        "    dont_touch : true;",
        "    area : 45000.0;",
        "    pin (clk_i) {",
        "      direction : input;",
        "      clock : true;",
        "      capacitance : 5.0;",
        "    }",
    ])
    for pfx in ("rd_snoop", "rd_vic0", "rd_vic1"):
        lines.extend(_comb_input_bus(f"{pfx}_set_i", 6))
        lines.extend(_comb_input_bus(f"{pfx}_way_i", 2))
        lines.extend(_comb_output_bus(f"{pfx}_line_o", 512, [(f"{pfx}_set_i", 6), (f"{pfx}_way_i", 2)], "0.350"))
    for pfx in ("rd_ptw", "rd_l0", "rd_l1"):
        lines.extend(_comb_input_bus(f"{pfx}_bank_i", 3))
        lines.extend(_comb_input_bus(f"{pfx}_set_i", 6))
        lines.extend(_comb_input_bus(f"{pfx}_way_i", 2))
        lines.extend(
            _comb_output_bus(
                f"{pfx}_dw_o",
                64,
                [(f"{pfx}_bank_i", 3), (f"{pfx}_set_i", 6), (f"{pfx}_way_i", 2)],
                "0.350",
            )
        )
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

    # Cell 2: fursoy_s2_l2_data_sram
    lines.extend([
        "  cell (fursoy_s2_l2_data_sram) {",
        "    dont_use : true;",
        "    dont_touch : true;",
        "    area : 280000.0;",
        "    pin (clk_i) {",
        "      direction : input;",
        "      clock : true;",
        "      capacitance : 10.0;",
        "    }",
    ])
    lines.extend(_comb_input_bus("lu_set_i", 9))
    lines.extend(_comb_output_bus("lu_set_data_o", 4096, [("lu_set_i", 9)], "0.400"))
    for u in ("upd0", "upd1"):
        lines.extend(_sync_input(f"{u}_wen_i", None))
        lines.extend(_sync_input(f"{u}_set_i", 9))
        lines.extend(_sync_input(f"{u}_way_i", 3))
        lines.extend(_sync_input(f"{u}_data_i", 512))
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def ensure_sram_macro_lib() -> Path:
    """Create or refresh tools/synth/lib/fursoy_sram_macros.lib deterministically."""
    SRAM_LIB_PATH.parent.mkdir(parents=True, exist_ok=True)
    expected = generate_sram_macro_lib_text()
    if not SRAM_LIB_PATH.exists() or SRAM_LIB_PATH.read_text(encoding="utf-8") != expected:
        SRAM_LIB_PATH.write_text(expected, encoding="utf-8")
    return SRAM_LIB_PATH


def sta_warning_counts(log_path: Path) -> tuple[int, int]:
    if not log_path.exists():
        return (0, 0)
    txt = log_path.read_text(errors="ignore")
    return (len(re.findall(r"Warning 1216\b", txt)), len(re.findall(r"Warning 441\b", txt)))


def render_synth_verilog(mod: dict, timeout_s: int = 360) -> str:
    sv2v_bin = shutil.which("sv2v") or "sv2v"
    sv_cmd = [
        sv2v_bin,
        "-DSYNTHESIS",
        f"-I{ROOT / 'rtl/core'}",
        f"-I{ROOT / 'rtl/platform'}",
    ]
    if mod.get("sram_bb", False):
        sv_cmd.append("-DFURSOY_SYNTH_SRAM_BB")
    sv_cmd.extend(str(p) for p in mod["sv_inputs"])
    res = subprocess.run(sv_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True, timeout=timeout_s)
    return normalize_comb_sensitivity(res.stdout)


def parse_yosys_log(log_path: Path):
    if not log_path.exists():
        return None
    content = log_path.read_text(errors="ignore")
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


def parse_sta_log(log_path: Path):
    if not log_path.exists():
        return None
    content = log_path.read_text(errors="ignore")

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


def run_s2_module_synth_and_sta(mod: dict, timeout_s: int = 360) -> bool:
    BUILD_SYNTH_S2.mkdir(parents=True, exist_ok=True)
    CONSTR_PATH.parent.mkdir(parents=True, exist_ok=True)
    if not CONSTR_PATH.exists():
        CONSTR_PATH.write_text("set_driving_cell BUF_X2\nset_load 2.0\n")
    ensure_sram_macro_lib()

    key = mod["key"]
    top = mod["name"]
    v_file = BUILD_SYNTH_S2 / f"{key}.v"
    net_file = BUILD_SYNTH_S2 / f"{key}_netlist.v"
    synth_log = mod["synth_log"]
    sta_tcl = BUILD_SYNTH_S2 / f"{key}_sta.tcl"
    sta_log = mod["sta_log"]
    meta_file = BUILD_SYNTH_S2 / f"{key}_meta.json"

    timed_out_stage = None
    error_msg = None
    synth_v_sha = None

    try:
        synth_v_text = render_synth_verilog(mod, timeout_s=timeout_s)
        synth_v_sha = hashlib.sha256(synth_v_text.encode("utf-8")).hexdigest()

        # Check if Yosys netlist is already byte-identical for the synthesized Verilog
        # (Yosys does not read fursoy_sram_macros.lib, so STA-only refresh is exact
        # when only `ifndef SYNTHESIS` code or fursoy_sram_macros.lib changed).
        can_reuse_netlist = False
        if v_file.exists() and net_file.exists() and synth_log.exists() and meta_file.exists():
            try:
                old_meta = json.loads(meta_file.read_text())
                if (
                    old_meta.get("status") == "ok"
                    and old_meta.get("params", {}) == mod.get("params", {})
                    and bool(old_meta.get("sram_bb", False)) == bool(mod.get("sram_bb", False))
                    and old_meta.get("abc_script") == mod.get("abc_script")
                    and old_meta.get("abc_delay_ps", 1000) == mod.get("abc_delay_ps", 1000)
                    and v_file.read_text(encoding="utf-8") == synth_v_text
                ):
                    can_reuse_netlist = True
            except Exception:
                can_reuse_netlist = False

        if not can_reuse_netlist:
            v_file.write_text(synth_v_text, encoding="utf-8")
            chparam_str = ""
            if mod.get("params"):
                pset = " ".join(f"-set {k} {v}" for k, v in mod["params"].items())
                chparam_str = f"chparam {pset} {top}; "

            noshare = " -noshare" if mod.get("noshare", False) else ""
            abc_script = mod.get("abc_script")
            abc_script_arg = f" -script {abc_script}" if abc_script else ""
            abc_delay_ps = mod.get("abc_delay_ps", 1000)
            ys_cmd = (
                f"read_liberty -lib {LIB_PATH}; "
                f"read_verilog -defer {v_file}; "
                f"{chparam_str}"
                f"hierarchy -check -top {top}; "
                f"synth -top {top} -noabc{noshare}; "
                f"dfflibmap -liberty {LIB_PATH}; "
                f"abc -D {abc_delay_ps} -constr {CONSTR_PATH} -liberty {LIB_PATH}{abc_script_arg}; "
                f"opt_clean -purge; "
                f"write_verilog -noattr -noexpr {net_file}; "
                f"stat -liberty {LIB_PATH}"
            )
            with open(synth_log, "w") as sl:
                subprocess.run(["yosys", "-p", ys_cmd], stdout=sl, stderr=subprocess.STDOUT, check=True, timeout=timeout_s)
        else:
            print(f"        (sv2v -DSYNTHESIS byte-identical; reusing {net_file.name} and refreshing OpenSTA)", flush=True)

        sram_lib_tcl = f"read_liberty {SRAM_LIB_PATH}\n" if mod.get("sram_bb", False) else ""
        extra_tcl = mod.get("extra_sta_tcl", "")
        tcl = f"""read_liberty {LIB_PATH}
{sram_lib_tcl}read_verilog {net_file}
link_design {top}
create_clock -name clk -period 2.0 [get_ports clk_i]
set_clock_uncertainty 0.05 [get_clocks clk]
set_input_delay -clock clk 0.2 [all_inputs -no_clocks]
set_output_delay -clock clk 0.2 [all_outputs]
{extra_tcl}
report_checks -path_delay max -fields {{slew cap input_pins fanout}} -digits 3
report_wns
report_tns
exit
"""
        sta_tcl.write_text(tcl)
        with open(sta_log, "w") as stl:
            subprocess.run([str(STA_BIN), "-no_init", "-exit", str(sta_tcl)], stdout=stl, stderr=subprocess.STDOUT, check=True, timeout=timeout_s)
    except subprocess.TimeoutExpired as exc:
        cmd_str = " ".join(str(x) for x in exc.cmd) if isinstance(exc.cmd, (list, tuple)) else str(exc.cmd)
        if "sv2v" in cmd_str:
            timed_out_stage = "sv2v"
        elif "yosys" in cmd_str:
            timed_out_stage = "yosys"
        else:
            timed_out_stage = "opensta"
        error_msg = f"Timed out in {timed_out_stage} after {timeout_s}s"
        if timed_out_stage in ("sv2v", "yosys"):
            sta_log.unlink(missing_ok=True)
    except subprocess.CalledProcessError as exc:
        timed_out_stage = "error"
        error_msg = f"Command failed with exit code {exc.returncode}"

    meta = {
        "key": key,
        "top": top,
        "params": mod.get("params", {}),
        "sram_bb": mod.get("sram_bb", False),
        "sram_lib_sha256": sha256_file(SRAM_LIB_PATH) if (mod.get("sram_bb", False) and SRAM_LIB_PATH.exists()) else None,
        "abc_script": mod.get("abc_script"),
        "abc_delay_ps": mod.get("abc_delay_ps", 1000),
        "inputs_sha256": combo_sha(mod["sv_inputs"]),
        "synth_v_sha256": synth_v_sha,
        "status": "ok" if error_msg is None else ("timeout" if timed_out_stage in ("sv2v", "yosys", "opensta") else "error"),
        "error": error_msg,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
    }
    meta_file.write_text(json.dumps(meta, indent=2) + "\n")
    return error_msg is None


def is_s2_meta_fresh(mod: dict) -> bool:
    meta_file = BUILD_SYNTH_S2 / f"{mod['key']}_meta.json"
    if not meta_file.exists() or not mod["synth_log"].exists() or not mod["sta_log"].exists():
        return False
    try:
        meta = json.loads(meta_file.read_text())
        exp_sram_sha = sha256_file(SRAM_LIB_PATH) if (mod.get("sram_bb", False) and SRAM_LIB_PATH.exists()) else None
        w1216, w441 = sta_warning_counts(mod["sta_log"])
        if w1216 > 0 or w441 > 0:
            return False
        inputs_ok = meta.get("inputs_sha256") == combo_sha(mod["sv_inputs"])
        if not inputs_ok and meta.get("synth_v_sha256"):
            synth_v_text = render_synth_verilog(mod)
            inputs_ok = meta.get("synth_v_sha256") == hashlib.sha256(synth_v_text.encode("utf-8")).hexdigest()
        return (
            meta.get("status") == "ok"
            and inputs_ok
            and meta.get("params", {}) == mod.get("params", {})
            and bool(meta.get("sram_bb", False)) == bool(mod.get("sram_bb", False))
            and meta.get("sram_lib_sha256") == exp_sram_sha
            and meta.get("abc_script") == mod.get("abc_script")
            and meta.get("abc_delay_ps", 1000) == mod.get("abc_delay_ps", 1000)
        )
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description="Fursoy Slice-2 Nangate45 500 MHz Physical Synthesis & STA")
    parser.add_argument("--run-synth", action="store_true", help="Run sv2v + Yosys + OpenSTA")
    parser.add_argument("--skip-fresh", action="store_true", help="Skip Slice-2 modules whose source hashes match fresh metadata")
    parser.add_argument("--only", default="", help="Comma-separated Slice-2 module keys to synthesize")
    parser.add_argument("--timeout", type=int, default=2400, help="Per-tool timeout in seconds (default: 2400)")
    parser.add_argument("--skip-s1", action="store_true", help="Skip Slice-1 gated blocks verification")
    args = parser.parse_args()

    only_filter = {tok.strip() for tok in args.only.split(",") if tok.strip()}
    ensure_sram_macro_lib()
    tools = check_toolchain()

    pkg_sv = ROOT / "rtl/core/fursoy_s1_pkg.sv"
    l2_sv = ROOT / "rtl/platform/fursoy_s2_l2.sv"

    s2_modules = [
        {
            "key": "s2_clint",
            "name": "fursoy_s2_clint",
            "sv_inputs": [ROOT / "rtl/platform/fursoy_s2_clint.sv"],
            "params": {"NUM_HARTS": 4},
            "sram_bb": False,
            "noshare": False,
            "synth_log": BUILD_SYNTH_S2 / "s2_clint_synth.log",
            "sta_log": BUILD_SYNTH_S2 / "s2_clint_sta.log",
            "description": "4-Hart CLINT Timer & Software Interrupt Controller",
        },
        {
            "key": "s2_plic",
            "name": "fursoy_s2_plic",
            "sv_inputs": [ROOT / "rtl/platform/fursoy_s2_plic.sv"],
            "params": {"NUM_HARTS": 4},
            "sram_bb": False,
            "noshare": False,
            "synth_log": BUILD_SYNTH_S2 / "s2_plic_synth.log",
            "sta_log": BUILD_SYNTH_S2 / "s2_plic_sta.log",
            "description": "8-Context PLIC (Binary Priority Reduction Tree)",
        },
        {
            "key": "s2_mmio_xbar",
            "name": "fursoy_s2_mmio_xbar",
            "sv_inputs": [ROOT / "rtl/platform/fursoy_s2_mmio_xbar.sv"],
            "params": {"NUM_HARTS": 4},
            "sram_bb": False,
            "noshare": False,
            "synth_log": BUILD_SYNTH_S2 / "s2_mmio_xbar_synth.log",
            "sta_log": BUILD_SYNTH_S2 / "s2_mmio_xbar_sta.log",
            "description": "4-Hart Registered MMIO Crossbar & Peripheral Decoder",
        },
        {
            "key": "s2_l2",
            "name": "fursoy_s2_l2",
            "sv_inputs": [l2_sv],
            "params": {"NUM_HARTS": 4, "L2_SETS": 512},
            "sram_bb": True,
            "noshare": False,
            "abc_script": "+strash;balance;&get,-n;&nf,{D};&put;buffer,-N,32,-S,90;upsize,{D};stime,-p",
            "synth_log": BUILD_SYNTH_S2 / "s2_l2_synth.log",
            "sta_log": BUILD_SYNTH_S2 / "s2_l2_sta.log",
            "description": "Shared 8-Way Inclusive L2 Directory/Tag/PLRU (512 sets) + SRAM Blackbox (.lib)",
        },
        {
            "key": "s2_coherence_mgr",
            "name": "fursoy_s2_coherence_mgr",
            "sv_inputs": [pkg_sv, l2_sv, ROOT / "rtl/platform/fursoy_s2_coherence_mgr.sv"],
            "params": {"NUM_HARTS": 4, "L2_SETS": 512},
            "sram_bb": True,
            "noshare": False,
            "abc_script": "+strash;balance;&get,-n;&nf,{D};&put;buffer,-N,32,-S,90;upsize,{D};stime,-p",
            "synth_log": BUILD_SYNTH_S2 / "s2_coherence_mgr_synth.log",
            "sta_log": BUILD_SYNTH_S2 / "s2_coherence_mgr_sta.log",
            "description": "4-Hart Directory Coherence Manager (C0/C1/C2 + DIR_MSHRs + L2 512 sets)",
        },
        {
            "key": "s2_l1d",
            "name": "fursoy_s1_l1d",
            "sv_inputs": [pkg_sv, ROOT / "rtl/core/fursoy_s1_l1d.sv"],
            "params": {"SMP_COHERENCE_EN": 1, "L1D_SETS_PARAM": 64},
            "sram_bb": True,
            "noshare": True,
            "abc_script": "+strash;balance;&get,-n;&dch,-f;&nf,{D};&put;buffer,-N,32,-S,90;upsize,{D};stime,-p",
            "synth_log": BUILD_SYNTH_S2 / "s2_l1d_synth.log",
            "sta_log": BUILD_SYNTH_S2 / "s2_l1d_sta.log",
            "description": "Coherent L1D Controller (SMP_COHERENCE_EN=1, 64 sets, 2-Stage Snoop, SC/AMO + SRAM .lib)",
        },
    ]

    print("=" * 112)
    print("Fursoy Slice-2 Nangate45 Physical Synthesis & Static Timing Analysis (500 MHz / 2.000 ns)")
    print("=" * 112)
    print(f"Yosys:    {tools['yosys']}")
    print(f"OpenSTA:  {tools['opensta']}")
    print(f"sv2v:     {tools['sv2v']}")
    print(f"Library:  {tools['liberty']}")
    print("-" * 112)

    if args.run_synth:
        for mod in s2_modules:
            if only_filter and mod["key"] not in only_filter and mod["name"] not in only_filter:
                continue
            if args.skip_fresh and is_s2_meta_fresh(mod):
                print(f"[SKIP]  {mod['name']} ({mod['key']}) -- fresh SHA-256")
                continue
            print(f"[SYNTH] {mod['name']} ({mod['key']}, params={mod['params']}, sram_bb={mod['sram_bb']})...", flush=True)
            ok = run_s2_module_synth_and_sta(mod, timeout_s=args.timeout)
            print(f"        -> {'OK' if ok else 'FAIL'}", flush=True)

    # Also ensure Slice-1 gated blocks are checked/fresh via tools/run_s1_synth.py
    s1_report_data = None
    s1_ok = True
    if not args.skip_s1 and not only_filter:
        s1_cmd = [sys.executable, str(ROOT / "tools/run_s1_synth.py")]
        if args.run_synth:
            s1_cmd.extend(["--run-synth", "--skip-fresh", "--only", "branch_unit,csr,dtlb,itlb,agu,ptw,decode,alu"])
        print("\n[SLICE-1] Verifying 8 Slice-1 gated core blocks via tools/run_s1_synth.py...", flush=True)
        s1_res = subprocess.run(s1_cmd, capture_output=True, text=True)
        if s1_res.returncode != 0:
            s1_ok = False
            print(s1_res.stdout[-1500:])
            print(s1_res.stderr[-1000:])
        s1_json_path = BUILD_SYNTH_S1 / "s1_synth_report.json"
        if s1_json_path.exists():
            s1_report_data = json.loads(s1_json_path.read_text())

    print("\n" + f"{'Module':<24} | {'Params':<28} | {'Area (um2)':<11} | {'kGE':<7} | {'Cells':<7} | {'DFFs':<6} | {'Arrival':<8} | {'WNS':<8} | {'TNS':<8} | {'Gate'}")
    print("-" * 124)

    all_s2_pass = True
    all_s2_fresh = True
    total_w1216 = 0
    total_w441 = 0
    s2_results = []
    for mod in s2_modules:
        if only_filter and mod["key"] not in only_filter and mod["name"] not in only_filter:
            continue
        y = parse_yosys_log(mod["synth_log"]) or {}
        st = parse_sta_log(mod["sta_log"]) or {}
        fresh = is_s2_meta_fresh(mod)
        w1216, w441 = sta_warning_counts(mod["sta_log"])
        total_w1216 += w1216
        total_w441 += w441
        if not fresh:
            all_s2_fresh = False
        wns = st.get("wns_ns")
        tns = st.get("tns_ns")
        arr = st.get("max_delay_ns")
        area = y.get("chip_area_um2")
        kge = (area / NAND2_AREA / 1000.0) if area is not None else None
        met = (wns is not None) and (wns >= 0.0) and (tns is not None) and (tns >= 0.0) and fresh and (w1216 == 0) and (w441 == 0)
        if not met:
            all_s2_pass = False
        param_txt = ",".join(f"{k}={v}" for k, v in mod["params"].items())
        print(
            f"{mod['name']:<24} | {param_txt:<28} | "
            f"{(f'{area:.1f}' if area is not None else 'N/A'):<11} | "
            f"{(f'{kge:.1f}' if kge is not None else 'N/A'):<7} | "
            f"{(str(y.get('cell_count')) if y.get('cell_count') is not None else 'N/A'):<7} | "
            f"{(str(y.get('dff_count')) if y.get('dff_count') is not None else 'N/A'):<6} | "
            f"{(f'{arr:.3f}' if arr is not None else 'N/A'):<8} | "
            f"{(f'{wns:+.3f}' if wns is not None else 'N/A'):<8} | "
            f"{(f'{tns:+.3f}' if tns is not None else 'N/A'):<8} | "
            f"{'PASS' if met else 'FAIL'}"
        )
        s2_results.append({
            "key": mod["key"],
            "name": mod["name"],
            "description": mod["description"],
            "params": mod["params"],
            "sram_bb": mod["sram_bb"],
            "logs_fresh": fresh,
            "warning_1216_count": w1216,
            "warning_441_count": w441,
            "yosys": y,
            "sta": st,
            "timing_met": met,
        })

    s1_gated_results = []
    if s1_report_data:
        for row in s1_report_data.get("modules", []):
            if row.get("gate"):
                s1_met = (
                    row.get("status") == "met"
                    and bool(row.get("data_complete", False))
                    and bool(row.get("logs_fresh", False))
                )
                s1_gated_results.append({
                    "name": row.get("name"),
                    "yosys": {
                        "cell_count": row.get("cell_count"),
                        "dff_count": row.get("dff_count"),
                        "chip_area_um2": row.get("area_um2"),
                        "gate_equivalent_ge": row.get("kge") * 1000.0 if row.get("kge") is not None else None,
                    },
                    "sta": {
                        "wns_ns": row.get("wns_ns_at_500mhz"),
                        "tns_ns": row.get("tns_ns_at_500mhz"),
                        "max_delay_ns": row.get("max_delay_ns"),
                    },
                    "timing_met": s1_met,
                })

    s1_summary = s1_report_data.get("summary", {}) if s1_report_data else {}
    all_s1_pass = (
        s1_ok
        and len(s1_gated_results) == 8
        and bool(s1_summary.get("gate_timing_closed", False))
        and bool(s1_summary.get("gate_all_logs_fresh", False))
        and all(r.get("timing_met") for r in s1_gated_results)
    )

    all_logs_fresh = all_s2_fresh and (True if (args.skip_s1 or only_filter) else bool(s1_summary.get("gate_all_logs_fresh", False)))
    report = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "target_clock_mhz": 500.0,
        "target_period_ns": 2.0,
        "nand2_area_um2": NAND2_AREA,
        "sram_lib_sha256": sha256_file(SRAM_LIB_PATH),
        "toolchain": tools,
        "slice2_blocks": s2_results,
        "slice1_gated_blocks": s1_gated_results,
        "all_slice2_pass": all_s2_pass,
        "all_slice1_gated_pass": all_s1_pass,
        "all_logs_fresh": all_logs_fresh,
        "warning_1216_count": total_w1216,
        "warning_441_count": total_w441,
    }
    report["all_gated_pass"] = report["all_slice2_pass"] and report["all_slice1_gated_pass"] and report["all_logs_fresh"] and (total_w1216 == 0) and (total_w441 == 0)
    BUILD_SYNTH_S2.mkdir(parents=True, exist_ok=True)
    report_path = BUILD_SYNTH_S2 / "s2_synth_report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(f"\nReport written to {report_path}")
    print(f"Logs Fresh: {report['all_logs_fresh']} | Warning 1216: {total_w1216} | Warning 441: {total_w441}")
    print(f"Overall 500 MHz Gate: {'PASS' if report['all_gated_pass'] else 'FAIL'}")
    sys.exit(0 if report["all_gated_pass"] else 1)


if __name__ == "__main__":
    main()
