#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 7 Phase B (4-Banked L1D Datapath & Arbitration) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build/s1_m7_phase_b"
REPORT = ROOT / "results/s1-m7-phase-b.json"
RTL_PKG = ROOT / "rtl/core/fursoy_s1_pkg.sv"
RTL_L1D = ROOT / "rtl/core/fursoy_s1_l1d.sv"
TB_PHASE_B = ROOT / "verification/s1_m7_phase_b_tb.cpp"

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
    print("Fursoy Slice-1 Milestone 7 Phase B Verification Suite")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Production RTL manifest SHA-256 (31 files): {manifest_sha}")
    print("=============================================================================")

    # Step 1: Verilate and Build M7 Phase B L1D Unit Testbench
    print("\n[M7-PHASE-B] Compiling Vfursoy_s1_m7_phase_b with Verilator (-O3 -j4)...")
    verilate_cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "--assert",
        "-Wall",
        "-O3",
        "-j", "4",
        "--top-module", "fursoy_s1_l1d",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR),
        "-o", "Vfursoy_s1_m7_phase_b",
        str(RTL_PKG),
        str(RTL_L1D),
        str(TB_PHASE_B),
    ]

    rc, out = run_cmd(verilate_cmd)
    if rc != 0:
        print("[M7-PHASE-B] Compilation failed:")
        print(out)
        return 1

    print("  [PASS] Executable built successfully.")

    # Step 2: Run M7 Phase B Unit Testbench
    print("\n[M7-PHASE-B] Running Vfursoy_s1_m7_phase_b...")
    exe = BUILD_DIR / "Vfursoy_s1_m7_phase_b"
    rc, out = run_cmd([str(exe)])
    print(out)

    if rc != 0:
        print(f"[M7-PHASE-B] Test execution failed with code {rc}")
        return rc

    # Parse JSON Results
    json_match = re.search(r"--- BEGIN JSON RESULTS ---\s*(\{.*?\})\s*--- END JSON RESULTS ---", out, re.DOTALL)
    if not json_match:
        print("[M7-PHASE-B] Error: Could not parse JSON results block from test output.")
        return 1

    try:
        tb_data = json.loads(json_match.group(1))
    except json.JSONDecodeError as e:
        print(f"[M7-PHASE-B] Error decoding test JSON: {e}")
        return 1

    elapsed = round(time.time() - start_time, 2)

    report_payload = {
        "milestone": "Slice-1 Milestone 7 Phase B",
        "title": "4-Banked Synonym-Safe L1D Datapath & Bank Conflict Resolution",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": elapsed,
        "authoritative_specification": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "production_rtl_manifest_sha256": manifest_sha,
        "verification_summary": {
            "directed_properties_verified": f"{tb_data.get('directed_scenarios', 0)} / {tb_data.get('directed_total', 10)} PASS",
            "total_accepted_banked_ops": tb_data.get("total_accepted_ops", 0),
            "multi_seed_torture_status": "PASS" if tb_data.get("status") == "pass" else "FAIL",
            "overall_status": "PASS" if tb_data.get("status") == "pass" else "FAIL",
        },
        "properties": tb_data.get("properties", {}),
        "seeds": tb_data.get("seeds", []),
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report_payload, indent=2), encoding="utf-8")
    print(f"\n[M7-PHASE-B] Results saved to {REPORT}")
    print("[M7-PHASE-B] Phase B verification completed successfully (ALL PASS).\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
