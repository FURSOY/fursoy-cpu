#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 9 Phase B (Uncached MMIO Pipeline & LSU Bypass) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build/s1_m9_phase_b"
REPORT = ROOT / "results/s1-m9-phase-b.json"
RTL_CORE = ROOT / "rtl/core/fursoy_s1_core.sv"
TB_CORE = ROOT / "verification/s1_m9_phase_b_tb.cpp"

SPEC_DOCUMENT = "docs/architecture/slice1-m9-soc-linux-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "bb353f632ec909b3270522e289d994cc90a34f18ab323705a9010e1070181347"

ALL_RTL = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_frat.sv",
    ROOT / "rtl/core/fursoy_s1_fprf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
    ROOT / "rtl/core/fursoy_s1_prf.sv",
    ROOT / "rtl/core/fursoy_s1_fprf.sv",
    ROOT / "rtl/core/fursoy_s1_alu.sv",
    ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
    ROOT / "rtl/core/fursoy_s1_multiplier.sv",
    ROOT / "rtl/core/fursoy_s1_divider.sv",
    ROOT / "rtl/core/fursoy_s1_port1_buffers.sv",
    ROOT / "rtl/core/fursoy_s1_int_iq.sv",
    ROOT / "rtl/core/fursoy_s1_agu.sv",
    ROOT / "rtl/core/fursoy_s1_mem_iq.sv",
    ROOT / "rtl/core/fursoy_s1_trt.sv",
    ROOT / "rtl/core/fursoy_s1_lsu_queues.sv",
    ROOT / "rtl/core/fursoy_s1_l1d.sv",
    ROOT / "rtl/core/fursoy_s1_lsu.sv",
    ROOT / "rtl/core/fursoy_s1_fma.sv",
    ROOT / "rtl/core/fursoy_s1_fdiv.sv",
    ROOT / "rtl/core/fursoy_s1_fconv.sv",
    ROOT / "rtl/core/fursoy_s1_fp_iq.sv",
    ROOT / "rtl/core/fursoy_s1_vrf.sv",
    ROOT / "rtl/core/fursoy_s1_vec_iq.sv",
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
    print("Fursoy Slice-1 Milestone 9 Phase B Verification Suite")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Production RTL manifest SHA-256 ({len(ALL_RTL)} files): {manifest_sha}")
    print("=============================================================================")

    # Step 1: Verilate and Build M9 Phase B Core Testbench
    print("\n[M9-PHASE-B] Compiling Vfursoy_s1_m9_phase_b with Verilator (-O3 -j4)...")
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
        "-o", "Vfursoy_s1_m9_phase_b",
    ]
    rc, out = run_cmd(verilate_cmd)
    build_log = BUILD_DIR / "build.log"
    build_log.write_text(out, encoding="utf-8")

    if rc != 0:
        print("[M9-PHASE-B] Verilation/compilation failed:")
        print(out)
        return 1
    print("  [PASS] Executable built successfully.")

    # Step 2: Run Phase B Testbench
    print("\n[M9-PHASE-B] Running Vfursoy_s1_m9_phase_b...")
    bin_path = BUILD_DIR / "Vfursoy_s1_m9_phase_b"
    rc, out = run_cmd([str(bin_path)])
    sim_log = BUILD_DIR / "simulation.log"
    sim_log.write_text(out, encoding="utf-8")
    print(out)

    if rc != 0:
        print("[M9-PHASE-B] Testbench execution failed with non-zero exit code.")
        return 1

    # Step 3: Parse JSON Result Data
    json_match = re.search(r"--- BEGIN JSON RESULTS ---\s*(\{.*?\})\s*--- END JSON RESULTS ---", out, re.DOTALL)
    if not json_match:
        print("[M9-PHASE-B] Could not parse unit test JSON output.")
        return 1

    unit_results = json.loads(json_match.group(1))

    # Step 4: Assemble Final Report
    report_data = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "phase": "M9 Phase B: Uncached MMIO Pipeline & LSU Bypass Channel",
        "production_rtl_manifest_sha256": manifest_sha,
        "spec_reference": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "unit_verification": {
            "phase": "Phase B",
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
    print(f"\n[M9-PHASE-B] Results saved to {REPORT}")
    print(f"[M9-PHASE-B] Overall Status: {report_data['overall_status']} in {report_data['elapsed_seconds']}s")
    return 0 if report_data["overall_status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
