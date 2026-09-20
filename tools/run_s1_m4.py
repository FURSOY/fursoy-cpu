"""Build and run the dedicated Fursoy Slice-1 Milestone 4 Frontend test suite with Verilator."""
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_CORE = ROOT / "rtl/core/fursoy_s1_core.sv"
TB = ROOT / "verification/s1_m4_tb.cpp"
BUILD_DIR = ROOT / "build/s1_m4"
REPORT = ROOT / "results/s1-m4.json"

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
    ROOT / "rtl/core/fursoy_s1_frontend.sv",
    ROOT / "rtl/core/fursoy_s1_core.sv",
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def build(report):
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_core",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR),
        str(RTL_CORE), str(TB)
    ]
    t0 = time.time()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    dt = time.time() - t0

    build_log = BUILD_DIR / "build.log"
    build_log.write_text(res.stdout + res.stderr, encoding="utf-8")

    report["build"] = {
        "command": cmd,
        "exit_code": res.returncode,
        "duration_sec": round(dt, 2),
        "log": str(build_log.relative_to(ROOT)),
    }

    if res.returncode != 0:
        print("Build failed:", file=sys.stderr)
        print(res.stdout + res.stderr, file=sys.stderr)
        raise RuntimeError("Verilator build failed")

    return BUILD_DIR / "Vfursoy_s1_core"

def main():
    report = {
        "suite": "fursoy_s1_m4_frontend",
        "milestone": "Milestone 4 — High-Performance Instruction Frontend Subsystem (BTB + Gshare + RAS + L1I + ITLB + PTW + Decode + FENCE.I)",
        "evidence_type": "directed_unit_and_randomized_adversarial_stress_with_invariant_checking",
        "directed_tests": 48,
        "stress_operations": 50000,
        "status": "fail",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [*ALL_RTL, TB, Path(__file__).resolve()]},
        "verilator_version": subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip(),
        "g++_version": subprocess.run(["g++", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
    }

    try:
        binary = build(report)
        t0 = time.time()
        sim = subprocess.run([str(binary)], cwd=ROOT, capture_output=True, text=True)
        dt = time.time() - t0

        sim_log = BUILD_DIR / "simulation.log"
        sim_log.write_text(sim.stdout + sim.stderr, encoding="utf-8")

        report["simulation"] = {
            "exit_code": sim.returncode,
            "duration_sec": round(dt, 2),
            "stdout": sim.stdout,
            "stderr": sim.stderr,
        }

        print(sim.stdout)
        if sim.stderr:
            print(sim.stderr, file=sys.stderr)

        if sim.returncode != 0 or "VERIFICATION RESULT: ALL TESTS PASSED" not in sim.stdout:
            raise RuntimeError("Simulation failed or assertion triggered")

        report["status"] = "pass"
        print(f"\nFursoy Slice-1 Milestone 4 Frontend Verification: PASS in {round(dt, 2)}s")

    except Exception as e:
        report["error"] = str(e)
        print(f"\nVerification ERROR: {e}", file=sys.stderr)

    finally:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
