"""Build and run Fursoy Slice-1 Milestone 6 Phase A (TAGE-Lite Direction Predictor) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RTL_PKG = ROOT / "rtl/core/fursoy_s1_pkg.sv"
RTL_BPU = ROOT / "rtl/core/fursoy_s1_bpu.sv"
TB_TAGE_UNIT = ROOT / "verification/s1_m6_tage_unit_tb.cpp"
BUILD_DIR = ROOT / "build/s1_m6_tage_unit"
REPORT = ROOT / "results/s1-m6-phase-a.json"

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
    print(f"[M6-PHASE-A] Production RTL manifest SHA-256 (31 files): {manifest_sha}")

    # Step 1: Verilate TAGE Unit Testbench
    print("[M6-PHASE-A] Verilating TAGE-Lite Unit Testbench...")
    verilate_cmd = [
        "verilator",
        "--cc",
        "--exe",
        "-O2",
        "-Wall",
        "-Wno-fatal",
        "-Wno-DECLFILENAME",
        "-Wno-UNUSEDSIGNAL",
        "-Wno-UNDRIVEN",
        "-Wno-WIDTHEXPAND",
        "-Wno-WIDTHTRUNC",
        "-Wno-BLKSEQ",
        "--top-module", "fursoy_s1_bpu",
        f"-I{ROOT / 'rtl/core'}",
        "--Mdir", str(BUILD_DIR),
        "-o", "Vfursoy_s1_tage_unit",
        str(RTL_PKG),
        str(RTL_BPU),
        str(TB_TAGE_UNIT),
    ]
    rc, out = run_cmd(verilate_cmd)
    if rc != 0:
        print("[M6-PHASE-A] Verilation failed:")
        print(out)
        return 1

    # Step 2: Compile C++ Model
    print("[M6-PHASE-A] Compiling Vfursoy_s1_tage_unit binary...")
    make_cmd = [
        "make",
        "-C", str(BUILD_DIR),
        "-j4",
        "-f", "Vfursoy_s1_bpu.mk",
        "Vfursoy_s1_tage_unit",
    ]
    rc, out = run_cmd(make_cmd)
    if rc != 0:
        print("[M6-PHASE-A] Compilation failed:")
        print(out)
        return 1

    # Step 3: Run TAGE Unit Binary
    print("[M6-PHASE-A] Running TAGE-Lite Unit Testbench...")
    bin_path = BUILD_DIR / "Vfursoy_s1_tage_unit"
    rc, out = run_cmd([str(bin_path)])
    print(out)
    if rc != 0:
        print("[M6-PHASE-A] TAGE Unit Testbench execution failed.")
        return 1

    # Parse Unit Test Output
    json_match = re.search(r"--- BEGIN JSON UNIT RESULTS ---\s*(\{.*?\})\s*--- END JSON UNIT RESULTS ---", out, re.DOTALL)
    if not json_match:
        print("[M6-PHASE-A] Could not parse unit test JSON output.")
        return 1

    unit_results = json.loads(json_match.group(1))

    # Assemble Final Report
    report_data = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "phase": "M6 Phase A: TAGE-Lite Direction Predictor",
        "production_rtl_manifest_sha256": manifest_sha,
        "spec_reference": {
            "document": "docs/architecture/slice1-m6-frontend-opt-v1.md",
            "version": "1.1",
            "commit": "530e52ab91c5c180d8ce1d3f20bbef7060fbc9a1",
            "sha256": "cfe3b2f6f984e737848c9185c2c6d7602aef89f069e6331edc2153b7852549a9"
        },
        "unit_verification": unit_results,
        "elapsed_seconds": round(time.time() - start_time, 2),
        "overall_status": "PASS"
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    with open(REPORT, "w", encoding="utf-8") as f:
        json.dump(report_data, f, indent=2)

    print(f"[M6-PHASE-A] Results saved to {REPORT}")
    print("[M6-PHASE-A] Phase A verification completed successfully (ALL PASS).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
