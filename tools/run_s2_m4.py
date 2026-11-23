#!/usr/bin/env python3
"""Build and run Fursoy Slice-2 Milestone S2-M4:
  - Verilator -Wall lint checks (NUM_HARTS = 2 and 4)
  - Full 8-test RVWMO SMP Litmus Suite (N = 2 and 4, cycle-by-cycle SWMR scoreboard)
  - Randomized Multi-Hart Coherence Torture (>= 100k commits per config, SWMR scoreboard)
  - 500 MHz Nangate45 Physical Synthesis & OpenSTA Closure (tools/run_s2_synth.py)
Writes structured evidence to results/s2-m4-closeout.json.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from s2_verilator_lib import (  # noqa: E402
    SOC_SV,
    compute_rtl_sha256,
    ensure_soc_lib,
    get_build_jobs,
    get_verilator_threads,
    link_verilator_tb,
    run_cmd,
)

BUILD_ROOT = ROOT / "build/s2_m4"
REPORT_PATH = ROOT / "results/s2-m4-closeout.json"
SYNTH_REPORT_PATH = ROOT / "build/synth_s2/s2_synth_report.json"

LINK_LD = ROOT / "software/baremetal/s2_link.ld"

LITMUS_ASM = ROOT / "software/baremetal/s2_m4_litmus_test.S"
LITMUS_TB = ROOT / "verification/s2_m4_litmus_tb.cpp"

TORTURE_CRT = ROOT / "software/baremetal/s2_m4_torture_crt.S"
TORTURE_C = ROOT / "software/baremetal/s2_m4_torture.c"
TORTURE_TB = ROOT / "verification/s2_m4_torture_tb.cpp"


def extract_last_json(output: str) -> dict:
    m = re.search(r"\{\s*\n\s*\"status\":.*\}\s*$", output, flags=re.S)
    if m:
        return json.loads(m.group(0))
    idx = output.rfind("\n{\n")
    if idx != -1:
        return json.loads(output[idx + 1 :])
    idx = output.find("{")
    if idx != -1:
        return json.loads(output[idx:])
    raise RuntimeError(f"Could not parse JSON summary from output:\n{output[-1500:]}")


def run_config(num_harts: int) -> dict:
    cfg_dir = BUILD_ROOT / f"n{num_harts}"
    cfg_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n--- [S2-M4 N={num_harts}] Verilator -Wall Lint ---")
    lint_cmd = [
        "verilator",
        "--lint-only",
        "--assert",
        "-Wall",
        "-Irtl/core",
        "-Irtl/platform",
        f"-GNUM_HARTS={num_harts}",
        "--top-module",
        "fursoy_s2_soc",
        str(SOC_SV),
    ]
    rc, out = run_cmd(lint_cmd)
    if rc != 0:
        print(out, file=sys.stderr)
        raise RuntimeError(f"Verilator lint failed for NUM_HARTS={num_harts}")
    print(f"[S2-M4 N={num_harts}] Lint PASS (0 warnings, 0 errors)")

    # 1. Compile Litmus & Torture Baremetal ELFs
    litmus_elf = cfg_dir / f"s2_m4_litmus_n{num_harts}.elf"
    torture_elf = cfg_dir / f"s2_m4_torture_n{num_harts}.elf"

    print(f"--- [S2-M4 N={num_harts}] Compiling Litmus ELF ---")
    litmus_gcc = [
        "riscv64-unknown-elf-gcc",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-nostdlib",
        "-nostartfiles",
        "-ffreestanding",
        f"-DNUM_HARTS={num_harts}",
        "-T",
        str(LINK_LD),
        str(LITMUS_ASM),
        "-o",
        str(litmus_elf),
    ]
    rc, out = run_cmd(litmus_gcc)
    if rc != 0:
        print(out, file=sys.stderr)
        raise RuntimeError(f"Litmus ELF build failed for N={num_harts}")

    print(f"--- [S2-M4 N={num_harts}] Compiling Coherence Torture ELF ---")
    torture_gcc = [
        "riscv64-unknown-elf-gcc",
        "-O2",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-nostdlib",
        "-nostartfiles",
        "-ffreestanding",
        f"-DNUM_HARTS={num_harts}",
        "-T",
        str(LINK_LD),
        str(TORTURE_CRT),
        str(TORTURE_C),
        "-o",
        str(torture_elf),
    ]
    rc, out = run_cmd(torture_gcc)
    if rc != 0:
        print(out, file=sys.stderr)
        raise RuntimeError(f"Torture ELF build failed for N={num_harts}")

    # 2. Reuse single Verilated static library (Vfursoy_s2_soc__ALL.a) for both TBs
    jobs = get_build_jobs()
    threads = get_verilator_threads()
    print(f"--- [S2-M4 N={num_harts}] Ensuring Shared Verilator SoC Library (jobs={jobs}, threads={threads}) ---")
    soc_mdir, soc_lib, global_objs, soc_s, rebuilt = ensure_soc_lib(
        num_harts, jobs=jobs, threads=threads, log_path=cfg_dir / "soc_build.log"
    )
    tag = "fresh" if rebuilt else "cached_soc"
    print(f"[S2-M4 N={num_harts}] Shared Vfursoy_s2_soc__ALL.a ready ({soc_s:.2f}s, {tag})")

    # 3. Link & Run Litmus TB
    print(f"--- [S2-M4 N={num_harts}] Linking & Running 8-Test SMP Litmus Suite ---")
    litmus_exe, lit_link_s = link_verilator_tb(
        num_harts, LITMUS_TB, soc_mdir, soc_lib, global_objs,
        cfg_dir / f"Vs2_m4_litmus_n{num_harts}_t{threads}", threads,
        extra_include_dirs=[ROOT / "verification"],
    )
    t_lit0 = time.monotonic()
    rc, lit_out = run_cmd([str(litmus_exe), str(litmus_elf), "2500000"], timeout_s=3600)
    lit_sim_s = time.monotonic() - t_lit0
    if rc != 0:
        print(lit_out[-2500:], file=sys.stderr)
        raise RuntimeError(f"Litmus simulation failed for N={num_harts}")
    lit_json = extract_last_json(lit_out)
    lit_rate = (lit_json["cycles"] / lit_sim_s) if lit_sim_s > 0 else 0.0
    print(
        f"[LITMUS N={num_harts}] status={lit_json['status']} cycles={lit_json['cycles']} "
        f"link={lit_link_s:.2f}s sim={lit_sim_s:.2f}s rate={lit_rate:.1f} cyc/s "
        f"zero_forbidden={lit_json['zero_forbidden']} swmr={lit_json['swmr_violations']} "
        f"inc={lit_json['inclusion_violations']} data={lit_json['data_coherence_violations']}"
    )

    # 4. Link & Run Coherence Torture TB (reusing shared Vfursoy_s2_soc__ALL.a)
    print(f"--- [S2-M4 N={num_harts}] Linking & Running Coherence Torture Suite ---")
    torture_exe, tor_link_s = link_verilator_tb(
        num_harts, TORTURE_TB, soc_mdir, soc_lib, global_objs,
        cfg_dir / f"Vs2_m4_torture_n{num_harts}_t{threads}", threads,
        extra_include_dirs=[ROOT / "verification"],
    )
    t_tor0 = time.monotonic()
    rc, tor_out = run_cmd([str(torture_exe), str(torture_elf), "2500000"], timeout_s=3600)
    tor_sim_s = time.monotonic() - t_tor0
    if rc != 0:
        print(tor_out[-2500:], file=sys.stderr)
        raise RuntimeError(f"Torture simulation failed for N={num_harts}")
    tor_json = extract_last_json(tor_out)
    tor_rate = (tor_json["cycles"] / tor_sim_s) if tor_sim_s > 0 else 0.0
    print(
        f"[TORTURE N={num_harts}] status={tor_json['status']} cycles={tor_json['cycles']} "
        f"link={tor_link_s:.2f}s sim={tor_sim_s:.2f}s rate={tor_rate:.1f} cyc/s "
        f"total_commits={tor_json['total_commits']} swmr={tor_json['swmr_violations']} "
        f"inc={tor_json['inclusion_violations']} data={tor_json['data_coherence_violations']}"
    )

    passed = (
        lit_json.get("status") == "pass"
        and lit_json.get("all_tests_present") is True
        and lit_json.get("zero_forbidden") is True
        and lit_json.get("sb_ok") is True
        and tor_json.get("status") == "pass"
        and tor_json.get("min_commits_ok") is True
        and tor_json.get("all_harts_ok") is True
        and tor_json.get("watchdog_ok") is True
        and tor_json.get("sb_ok") is True
    )
    if not passed:
        raise RuntimeError(f"S2-M4 simulation gates did not pass for N={num_harts}")

    return {
        "num_harts": num_harts,
        "lint_passed": True,
        "litmus": lit_json,
        "torture": tor_json,
        "status": "pass",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Fursoy Slice-2 Milestone S2-M4 Unified Runner")
    parser.add_argument("--skip-synth", action="store_true", help="Read existing build/synth_s2/s2_synth_report.json instead of running synth")
    parser.add_argument("--force-synth", action="store_true", help="Re-run Nangate45 synthesis without --skip-fresh")
    args = parser.parse_args()

    t0 = time.time()
    configs = []
    for n in (2, 4):
        configs.append(run_config(n))

    print("\n--- [S2-M4] 500 MHz Nangate45 Physical Synthesis & OpenSTA Closure ---")
    synth_cmd = [sys.executable, str(ROOT / "tools/run_s2_synth.py")]
    if not args.skip_synth:
        synth_cmd.append("--run-synth")
        if not args.force_synth:
            synth_cmd.append("--skip-fresh")
    rc, synth_out = run_cmd(synth_cmd, timeout_s=5400)
    print(synth_out)
    if rc != 0:
        raise RuntimeError("500 MHz Nangate45 synthesis / STA gate failed")

    if not SYNTH_REPORT_PATH.exists():
        raise RuntimeError(f"Missing synthesis report at {SYNTH_REPORT_PATH}")
    synth_report = json.loads(SYNTH_REPORT_PATH.read_text())
    if not synth_report.get("all_gated_pass"):
        raise RuntimeError("s2_synth_report.json reported all_gated_pass != true")

    elapsed = round(time.time() - t0, 2)
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    summary = {
        "milestone": "S2-M4",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_sec": elapsed,
        "rtl_sha256": compute_rtl_sha256(),
        "status": "pass",
        "configs": configs,
        "synth_500mhz": {
            "target_clock_mhz": synth_report.get("target_clock_mhz"),
            "target_period_ns": synth_report.get("target_period_ns"),
            "all_slice2_pass": synth_report.get("all_slice2_pass"),
            "all_slice1_gated_pass": synth_report.get("all_slice1_gated_pass"),
            "all_logs_fresh": synth_report.get("all_logs_fresh"),
            "warning_1216_count": synth_report.get("warning_1216_count"),
            "warning_441_count": synth_report.get("warning_441_count"),
            "all_gated_pass": synth_report.get("all_gated_pass"),
            "slice2_blocks": synth_report.get("slice2_blocks"),
            "slice1_gated_blocks": synth_report.get("slice1_gated_blocks"),
        },
    }
    REPORT_PATH.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\n[S2-M4] ALL GATES PASSED in {elapsed}s -> {REPORT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
