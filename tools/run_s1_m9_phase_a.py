#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 9 Phase A (Asynchronous Interrupts & ROB Head Trap Arbitration) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

from s1_rtl_manifest import (
    CORE_RTL as ALL_RTL,
    ROOT,
    compute_manifest_sha256,
    sha256_file,
)

BUILD_DIR = ROOT / "build/s1_m9_phase_a"
REPORT = ROOT / "results/s1-m9-phase-a.json"
RTL_CORE = ROOT / "rtl/core/fursoy_s1_core.sv"
TB_CORE = ROOT / "verification/s1_m9_phase_a_tb.cpp"

SPEC_DOCUMENT = "docs/architecture/slice1-m9-soc-linux-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "bb353f632ec909b3270522e289d994cc90a34f18ab323705a9010e1070181347"


def run_cmd(cmd: list[str], cwd: Path | None = None) -> tuple[int, str]:
    res = subprocess.run(cmd, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return res.returncode, res.stdout


def main() -> int:
    start_time = time.time()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    manifest_sha = compute_manifest_sha256(ALL_RTL)
    print("=============================================================================")
    print("Fursoy Slice-1 Milestone 9 Phase A Verification Suite")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Production RTL manifest SHA-256 ({len(ALL_RTL)} files): {manifest_sha}")
    print("=============================================================================")

    # Step 1: Verilate and Build M9 Phase A Core Testbench
    print("\n[M9-PHASE-A] Compiling Vfursoy_s1_m9_phase_a with Verilator (-O3 -j4)...")
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
        "--top-module", "fursoy_s1_core",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR),
        str(RTL_CORE),
        str(TB_CORE),
        "-o", "Vfursoy_s1_m9_phase_a",
    ]
    rc, out = run_cmd(verilate_cmd)
    build_log = BUILD_DIR / "build.log"
    build_log.write_text(out, encoding="utf-8")

    if rc != 0:
        print("[M9-PHASE-A] Verilation/compilation failed:")
        print(out)
        return 1
    print("  [PASS] Executable built successfully.")

    # Step 2: Run Phase A Testbench
    print("\n[M9-PHASE-A] Running Vfursoy_s1_m9_phase_a...")
    bin_path = BUILD_DIR / "Vfursoy_s1_m9_phase_a"
    rc, out = run_cmd([str(bin_path)])
    sim_log = BUILD_DIR / "simulation.log"
    sim_log.write_text(out, encoding="utf-8")
    print(out)

    if rc != 0:
        print("[M9-PHASE-A] Testbench execution failed with non-zero exit code.")
        return 1

    # Step 3: Parse JSON Result Data
    json_match = re.search(r"--- BEGIN JSON RESULTS ---\s*(\{.*?\})\s*--- END JSON RESULTS ---", out, re.DOTALL)
    if not json_match:
        print("[M9-PHASE-A] Could not parse unit test JSON output.")
        return 1

    unit_results = json.loads(json_match.group(1))

    # Step 4: Assemble Final Report
    report_data = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "phase": "M9 Phase A: Asynchronous Interrupt Subsystem & Precise ROB Head Trap Arbitration",
        "production_rtl_manifest_sha256": manifest_sha,
        "spec_reference": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "unit_verification": {
            "phase": "Phase A",
            "total_properties": unit_results.get("total_properties", 0),
            "passed_properties_count": unit_results.get("passed_properties_count", 0),
            "status": unit_results.get("status", "unknown"),
            "randomized_torture_operations": unit_results.get("randomized_torture_operations", 0),
            "torture_seeds": unit_results.get("torture_seeds", []),
            "torture_mismatches": unit_results.get("torture_mismatches", 0),
            "properties": unit_results.get("properties", []),
        },
        "elapsed_seconds": round(time.time() - start_time, 2),
        "overall_status": "PASS" if unit_results.get("status") == "pass" and rc == 0 else "FAIL",
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report_data, indent=2) + "\n", encoding="utf-8")
    print(f"\n[M9-PHASE-A] Results saved to {REPORT}")
    print(f"[M9-PHASE-A] Overall Status: {report_data['overall_status']} in {report_data['elapsed_seconds']}s")
    return 0 if report_data["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
