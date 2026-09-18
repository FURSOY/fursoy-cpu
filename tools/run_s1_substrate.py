"""Build and run the dedicated Fursoy Slice-1 Substrate test suite with Verilator."""
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_SUBSTRATE = ROOT / "rtl/core/fursoy_s1_substrate.sv"
TB = ROOT / "verification/s1_substrate_tb.cpp"
BUILD_DIR = ROOT / "build/s1_substrate"
REPORT = ROOT / "results/s1-substrate.json"

ALL_RTL = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def build(report):
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_substrate",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR),
        str(RTL_SUBSTRATE), str(TB)
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

    return BUILD_DIR / "Vfursoy_s1_substrate"

def main():
    report = {
        "suite": "fursoy_s1_substrate",
        "milestone": "Milestone 1 — Rename + PRF Metadata + Free List + ROB + Recovery Substrate",
        "evidence_type": "directed_unit_and_randomized_adversarial_stress_with_invariant_checking",
        "directed_tests": 28,
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
        print(f"\nFursoy Slice-1 Substrate Verification: PASS in {round(dt, 2)}s")

    except Exception as e:
        report["error"] = str(e)
        print(f"\nVerification ERROR: {e}", file=sys.stderr)

    finally:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
