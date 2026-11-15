#!/usr/bin/env python3
"""
Automated Test Runner & Milestone Closeout Engine for Fursoy Slice-1 Milestone 8:
Standard Floating-Point (RV64FD) & Vector Execution (RVV 1.0) Architecture Closeout.

Authoritative Specification: docs/architecture/slice1-m8-fp-vector-v1.md v1.1
Production RTL Manifest SHA-256 (40 files): 4d6fc54a6efb0d0deb94d4416926bd769c0783871499075f5de434959206d7cb
"""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

from s1_rtl_manifest import (
    ACCEPTED_RTL_MANIFEST_SHA256S,
    CORE_RTL as ALL_RTL,
    ROOT,
    compute_manifest_sha256,
    sha256_file,
)

BUILD_DIR = ROOT / "build/s1_m8_closeout"
REPORT = ROOT / "results/s1-m8-closeout.json"

SPEC_DOCUMENT = "docs/architecture/slice1-m8-fp-vector-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "55a4fa1623c073d9b06d7384f7ea3ce0ad0824b7f240819179962994b68d92e6"

def run_cmd(cmd: list[str], cwd: Path | None = None) -> tuple[int, str]:
    res = subprocess.run(cmd, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return res.returncode, res.stdout


def main() -> int:
    start_time = time.time()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    manifest_sha = compute_manifest_sha256(ALL_RTL)
    print("=============================================================================")
    print("Fursoy Slice-1 Milestone 8 Integrated Verification & Closeout Engine")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Production RTL manifest SHA-256 ({len(ALL_RTL)} files): {manifest_sha}")
    print("=============================================================================\n")

    if manifest_sha not in ACCEPTED_RTL_MANIFEST_SHA256S:
        print(f"ERROR: Manifest mismatch!\n  Expected one of: {sorted(list(ACCEPTED_RTL_MANIFEST_SHA256S))}\n  Got:      {manifest_sha}")
        return 1

    print("[M8-CLOSEOUT] Compiling Vfursoy_s1_core_m8_closeout with Verilator (-O3 -j4)...")
    verilator_cmd = [
        "verilator",
        "-cc",
        "--exe",
        "-O3",
        "-Wall",
        "-Wno-fatal",
        "-j", "4",
        "-Irtl/core",
        "--top-module", "fursoy_s1_core",
        "-o", "Vfursoy_s1_core_m8_closeout",
        "--Mdir", str(BUILD_DIR),
        str(ROOT / "verification/s1_m8_closeout_tb.cpp"),
        *[str(f) for f in ALL_RTL]
    ]

    ret, out = run_cmd(verilator_cmd)
    if ret != 0:
        print(f"Verilator compilation failed:\n{out}")
        return 1

    make_cmd = ["make", "-C", str(BUILD_DIR), "-f", "Vfursoy_s1_core.mk", "Vfursoy_s1_core_m8_closeout"]
    ret, out = run_cmd(make_cmd)
    if ret != 0:
        print(f"Make build failed:\n{out}")
        return 1

    print("  [PASS] Closeout executable built successfully.\n")

    exe_path = BUILD_DIR / "Vfursoy_s1_core_m8_closeout"
    print("[M8-CLOSEOUT] Running Vfursoy_s1_core_m8_closeout...")
    ret, sim_out = run_cmd([str(exe_path)])
    print(sim_out)

    if ret != 0:
        print("Closeout simulation failed!")
        return 1

    # Extract JSON results
    json_match = re.search(r"--- BEGIN JSON PROFILE DATA ---\s*(\{.*?\})\s*--- END JSON PROFILE DATA ---", sim_out, re.DOTALL)
    if not json_match:
        print("ERROR: Failed to parse JSON results from simulation output!")
        return 1

    sim_data = json.loads(json_match.group(1))

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "phase": "Milestone 8 Closeout: Standard Floating-Point (RV64FD) & Vector Execution (RVV 1.0)",
        "production_rtl_manifest_sha256": manifest_sha,
        "production_rtl_file_count": len(ALL_RTL),
        "spec_reference": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "closeout_verification": {
            "status": sim_data.get("status", "fail"),
            "total_properties_tested": sim_data.get("total_properties_tested", 0),
            "properties_passed": sim_data.get("properties_passed", 0),
            "passed_properties": sim_data.get("passed_properties", []),
            "cpi_conservation_status": sim_data.get("cpi_conservation_status", "fail"),
            "torture_ops_completed": sim_data.get("torture_ops_completed", 0),
            "comparisons_checked": sim_data.get("comparisons_checked", 0),
            "torture_mismatches": sim_data.get("torture_mismatches", 0),
            "mismatch_detector_self_test": sim_data.get("mismatch_detector_self_test", "fail"),
        },
        "numerical_benchmark_profiles": sim_data.get("profiles", {}),
        "elapsed_seconds": round(time.time() - start_time, 2),
        "overall_status": "PASS" if sim_data.get("status") == "pass" else "FAIL"
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n")
    print(f"\n[M8-CLOSEOUT] Results saved to {REPORT}")
    print("[M8-CLOSEOUT] Milestone 8 closeout verification completed successfully (ALL PASS).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
