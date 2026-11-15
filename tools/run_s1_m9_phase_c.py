#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 9 Phase C (SoC Interconnect & Peripherals Integration) Verification Suite."""
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time

from s1_rtl_manifest import (
    CORE_RTL,
    ROOT,
    SOC_RTL,
    compute_manifest_sha256,
)

BUILD_DIR = ROOT / "build/s1_m9_phase_c"
REPORT = ROOT / "results/s1-m9-phase-c.json"
RTL_SOC = ROOT / "rtl/platform/fursoy_s1_soc.sv"
TB_SOC = ROOT / "verification/s1_m9_phase_c_tb.cpp"

SPEC_DOCUMENT = "docs/architecture/slice1-m9-soc-linux-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "bb353f632ec909b3270522e289d994cc90a34f18ab323705a9010e1070181347"


def run_cmd(cmd: list[str], cwd: Path | None = None) -> tuple[int, str]:
    res = subprocess.run(cmd, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return res.returncode, res.stdout


def main() -> int:
    start_time = time.time()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    core_manifest_sha = compute_manifest_sha256(CORE_RTL)
    soc_manifest_sha = compute_manifest_sha256(SOC_RTL)
    print("=============================================================================")
    print("Fursoy Slice-1 Milestone 9 Phase C Verification Suite")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Predecessor Core RTL Manifest SHA-256 ({len(CORE_RTL)} files): {core_manifest_sha}")
    print(f"SoC Production RTL Manifest SHA-256 ({len(SOC_RTL)} files): {soc_manifest_sha}")
    print("=============================================================================")

    # Step 1: Verilate and Build M9 Phase C SoC Testbench
    print("\n[M9-PHASE-C] Compiling Vfursoy_s1_m9_phase_c with Verilator (-O3 -j4)...")
    verilate_cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "--assert",
        "-Wall",
        "-Wno-fatal",
        "-O3",
        "-j", "4",
        "--top-module", "fursoy_s1_soc",
        "-Irtl/core",
        "-Irtl/platform",
        "--Mdir", str(BUILD_DIR),
        str(RTL_SOC),
        str(TB_SOC),
        "-o", "Vfursoy_s1_m9_phase_c",
    ]
    rc, out = run_cmd(verilate_cmd)
    build_log = BUILD_DIR / "build.log"
    build_log.write_text(out, encoding="utf-8")

    if rc != 0:
        print("[M9-PHASE-C] Verilation/compilation failed:")
        print(out)
        return 1
    print("  [PASS] Executable built successfully.")

    # Step 2: Run Phase C Testbench
    print("\n[M9-PHASE-C] Running Vfursoy_s1_m9_phase_c...")
    bin_path = BUILD_DIR / "Vfursoy_s1_m9_phase_c"
    rc, out = run_cmd([str(bin_path)])
    sim_log = BUILD_DIR / "simulation.log"
    sim_log.write_text(out, encoding="utf-8")
    print(out)

    if rc != 0:
        print("[M9-PHASE-C] Testbench execution failed with non-zero exit code.")
        return 1

    # Step 3: Parse JSON Result Data
    json_match = re.search(r"--- BEGIN JSON RESULTS ---\s*(\{.*?\})\s*--- END JSON RESULTS ---", out, re.DOTALL)
    if not json_match:
        print("[M9-PHASE-C] Could not parse unit test JSON output.")
        return 1

    unit_results = json.loads(json_match.group(1))

    # Step 4: Assemble Final Report
    report_data = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "phase": "M9 Phase C: Slice-1 SoC Interconnect & Peripherals Integration",
        "predecessor_core_manifest_sha256": core_manifest_sha,
        "production_rtl_manifest_sha256": soc_manifest_sha,
        "spec_reference": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "unit_verification": {
            "phase": "Phase C",
            "total_properties": unit_results.get("total_properties", 0),
            "passed_properties_count": unit_results.get("passed_properties_count", 0),
            "status": unit_results.get("status", "unknown"),
            "randomized_torture_operations": unit_results.get("randomized_torture_operations", 0),
            "total_bus_transactions": unit_results.get("total_bus_transactions", 0),
            "torture_seeds": unit_results.get("torture_seeds", []),
            "torture_mismatches": unit_results.get("torture_mismatches", 0),
            "properties": unit_results.get("properties", []),
        },
        "elapsed_seconds": round(time.time() - start_time, 2),
        "overall_status": "PASS" if unit_results.get("status") == "pass" and rc == 0 else "FAIL",
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report_data, indent=2) + "\n", encoding="utf-8")
    print(f"\n[M9-PHASE-C] Results saved to {REPORT}")
    print(f"[M9-PHASE-C] Overall Status: {report_data['overall_status']} in {report_data['elapsed_seconds']}s")
    return 0 if report_data["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
