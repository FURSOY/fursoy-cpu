#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 7 Phase C (Multi-Ported LSQ & Store Forwarding) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build/s1_m7_phase_c"
REPORT = ROOT / "results/s1-m7-phase-c.json"
RTL_CORE = ROOT / "rtl/core/fursoy_s1_core.sv"
TB_CORE = ROOT / "verification/s1_m7_phase_c_tb.cpp"

SPEC_DOCUMENT = "docs/architecture/slice1-m7-multibank-l1d-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "c8ae7b5b19672db9dcacb3daa7113cb8251c7e14b857cc79f5aef3a6a91d79c9"

ALL_RTL = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
    ROOT / "rtl/core/fursoy_s1_prf.sv",
    ROOT / "rtl/core/fursoy_s1_alu.sv",
    ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
    ROOT / "rtl/core/fursoy_s1_multiplier.sv",
    ROOT / "rtl/core/fursoy_s1_divider.sv",
    ROOT / "rtl/core/fursoy_s1_port1_buffers.sv",
    ROOT / "rtl/core/fursoy_s1_int_iq.sv",
    ROOT / "rtl/core/fursoy_s1_mem_iq.sv",
    ROOT / "rtl/core/fursoy_s1_agu.sv",
    ROOT / "rtl/core/fursoy_s1_trt.sv",
    ROOT / "rtl/core/fursoy_s1_l1d.sv",
    ROOT / "rtl/core/fursoy_s1_lsu_queues.sv",
    ROOT / "rtl/core/fursoy_s1_lsu.sv",
    ROOT / "rtl/core/fursoy_s1_backend.sv",
    ROOT / "rtl/core/fursoy_s1_bpu.sv",
    ROOT / "rtl/core/fursoy_s1_ptw.sv",
    ROOT / "rtl/core/fursoy_s1_itlb.sv",
    ROOT / "rtl/core/fursoy_s1_l1i.sv",
    ROOT / "rtl/core/fursoy_s1_fetch_queue.sv",
    ROOT / "rtl/core/fursoy_s1_decode.sv",
    ROOT / "rtl/core/fursoy_s1_serialization.sv",
    ROOT / "rtl/core/fursoy_s1_csr.sv",
    ROOT / "rtl/core/fursoy_s1_hpm.sv",
    ROOT / "rtl/core/fursoy_s1_frontend.sv",
    ROOT / "rtl/core/fursoy_s1_core.sv",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def compute_manifest_sha256(files: list[Path]) -> str:
    h = hashlib.sha256()
    for f in sorted(files, key=lambda p: p.name):
        h.update(f.name.encode("utf-8"))
        h.update(f.read_bytes())
    return h.hexdigest()


def run_cmd(cmd: list[str], cwd: Path | None = None) -> tuple[int, str]:
    res = subprocess.run(cmd, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return res.returncode, res.stdout


def main() -> int:
    start_time = time.time()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    manifest_sha = compute_manifest_sha256(ALL_RTL)
    print("=============================================================================")
    print("Fursoy Slice-1 Milestone 7 Phase C Verification Suite")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Production RTL manifest SHA-256 (31 files): {manifest_sha}")
    print("=============================================================================")

    # Step 1: Verilate and Build M7 Phase C Core Testbench
    print("\n[M7-PHASE-C] Compiling Vfursoy_s1_m7_phase_c with Verilator (-O3 -j4)...")
    verilate_cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "--assert",
        "-Wall",
        "-O3",
        "-j", "4",
        "--top-module", "fursoy_s1_core",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR),
        str(RTL_CORE),
        str(TB_CORE),
        "-o", "Vfursoy_s1_m7_phase_c",
    ]
    rc, out = run_cmd(verilate_cmd)
    build_log = BUILD_DIR / "build.log"
    build_log.write_text(out, encoding="utf-8")

    if rc != 0:
        print("[M7-PHASE-C] Verilation/compilation failed:")
        print(out)
        return 1
    print("  [PASS] Executable built successfully.")

    # Step 2: Run Phase C Testbench
    print("\n[M7-PHASE-C] Running Vfursoy_s1_m7_phase_c...")
    bin_path = BUILD_DIR / "Vfursoy_s1_m7_phase_c"
    rc, out = run_cmd([str(bin_path)])
    sim_log = BUILD_DIR / "simulation.log"
    sim_log.write_text(out, encoding="utf-8")
    print(out)

    if rc != 0:
        print("[M7-PHASE-C] Testbench execution failed with non-zero exit code.")
        return 1

    # Step 3: Parse JSON Result Data
    json_match = re.search(r"--- BEGIN JSON RESULTS ---\s*(\{.*?\})\s*--- END JSON RESULTS ---", out, re.DOTALL)
    if not json_match:
        print("[M7-PHASE-C] Could not parse unit test JSON output.")
        return 1

    unit_results = json.loads(json_match.group(1))

    # Step 4: Assemble Final Report
    report_data = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "phase": "M7 Phase C: Multi-Ported LSQ & Store-to-Load Forwarding",
        "production_rtl_manifest_sha256": manifest_sha,
        "spec_reference": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "unit_verification": unit_results,
        "elapsed_seconds": round(time.time() - start_time, 2),
        "overall_status": "PASS" if unit_results.get("status") == "pass" else "FAIL",
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with open(REPORT, "w", encoding="utf-8") as f:
        json.dump(report_data, f, indent=2)

    print(f"\n[M7-PHASE-C] Results saved to {REPORT}")
    if report_data["overall_status"] == "PASS":
        print("[M7-PHASE-C] Phase C verification completed successfully (ALL PASS).")
        return 0
    else:
        print("[M7-PHASE-C] Phase C verification reported FAIL.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
