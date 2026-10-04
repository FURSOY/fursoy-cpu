"""Build and run the Fursoy Slice-1 Milestone 5 Phase B1 Verification & Profiling Suite with Verilator."""
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_CORE = ROOT / "rtl/core/fursoy_s1_core.sv"
TB = ROOT / "verification/s1_m5_b1_tb.cpp"
BUILD_DIR = ROOT / "build/s1_m5_b1"
REPORT = ROOT / "results/s1-m5-b1.json"

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

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest_sha(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()

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

def check_duplicate_keys(pairs):
    res = {}
    for k, v in pairs:
        if k in res:
            raise ValueError(f"Duplicate key detected in JSON: {k}")
        res[k] = v
    return res

def validate_profile_results(data):
    if not isinstance(data, dict):
        raise ValueError("Profile data must be a dictionary")

    # Validate directed test counts and status
    if data.get("directed_tests") != 40 or data.get("directed_sub_scenarios") != 40:
        raise ValueError(f"Unexpected directed test count: {data.get('directed_tests')}/{data.get('directed_sub_scenarios')}")
    if data.get("directed_status") != "pass" or data.get("cpi_conservation_status") != "pass":
        raise ValueError("Directed or CPI conservation status is not 'pass'")

    # Validate randomized stress verification
    rand_stress = data.get("randomized_adversarial_stress")
    if not rand_stress or not isinstance(rand_stress, dict):
        raise ValueError("Missing 'randomized_adversarial_stress' section")

    for seed_key in ["seed_42", "seed_20260920"]:
        if seed_key not in rand_stress:
            raise ValueError(f"Missing {seed_key} in randomized_adversarial_stress")
        st = rand_stress[seed_key]
        if st.get("accepted_operations", 0) < 25000:
            raise ValueError(f"{seed_key} accepted ops < 25000: {st.get('accepted_operations')}")
        if st.get("mismatches", -1) != 0:
            raise ValueError(f"{seed_key} has mismatches: {st.get('mismatches')}")
        if st.get("watchdog_trips", -1) != 0:
            raise ValueError(f"{seed_key} has watchdog trips: {st.get('watchdog_trips')}")

    # Validate profiles
    expected_profiles = ["branch_torture", "pointer_chasing", "stream_memcpy", "int_dependency", "raw_stress"]
    profiles = data.get("profiles", {})
    if len(profiles) != 5:
        raise ValueError(f"Expected exactly 5 profiles, got {len(profiles)}")
    for name in expected_profiles:
        if name not in profiles:
            raise ValueError(f"Missing profile for workload: {name}")
        p = profiles[name]
        cycles = p.get("cycles", 0)
        cpi = p.get("cpi_breakdown", {})
        expected_cats = [
            "C_serialize", "C_br_recover", "C_productive", "C_mem_stall",
            "C_be_rename", "C_be_sched", "C_fe_starve", "C_idle_other"
        ]
        if len(cpi) != 8:
            raise ValueError(f"Profile {name} CPI breakdown must have exactly 8 categories")
        cpi_sum = 0
        for cat in expected_cats:
            if cat not in cpi:
                raise ValueError(f"Profile {name} missing CPI category {cat}")
            cpi_sum += cpi[cat]
        if cpi_sum != cycles:
            raise ValueError(f"Profile {name} CPI sum ({cpi_sum}) != cycles ({cycles})")

        # Validate 48 unique keys 0x01..0x30
        events = p.get("events", {})
        if len(events) != 48:
            raise ValueError(f"Profile {name} must have exactly 48 events, got {len(events)}")
        for ev in range(1, 49):
            expected_key = f"0x{ev:02x}"
            if expected_key not in events:
                raise ValueError(f"Profile {name} missing event key {expected_key}")

def extract_json_profile(stdout):
    match = re.search(r"--- BEGIN JSON PROFILE DATA ---\n(.*?)\n--- END JSON PROFILE DATA ---", stdout, re.DOTALL)
    if match:
        try:
            data = json.loads(match.group(1), object_pairs_hook=check_duplicate_keys)
            validate_profile_results(data)
            return data
        except Exception as e:
            return {"error": f"Failed to parse/validate profile JSON: {e}"}
    return None

def main():
    report = {
        "suite": "fursoy_s1_m5_b1",
        "milestone": "Milestone 5 — Phase B1: Speculative Load Disambiguation, Violation Detection & Replay",
        "canonical_spec": "docs/architecture/slice1-m5-performance-v1.md (v1.2, Frozen)",
        "evidence_type": "b1_directed_verification_and_workload_profiling",
        "directed_tests": 40,
        "profiling_workloads": 5,
        "status": "fail",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "rtl_manifest_sha256": manifest_sha(ALL_RTL),
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

        profile_data = extract_json_profile(sim.stdout)
        report["simulation"] = {
            "exit_code": sim.returncode,
            "duration_sec": round(dt, 2),
            "log": str(sim_log.relative_to(ROOT)),
            "profile_data": profile_data,
        }

        if sim.returncode == 0 and profile_data and "error" not in profile_data:
            report["status"] = "pass"
            print("Fursoy Slice-1 M5 Phase B1 Suite PASS")
        else:
            print(f"Simulation failed with returncode {sim.returncode}", file=sys.stderr)
            if profile_data and "error" in profile_data:
                print(f"Validation error: {profile_data['error']}", file=sys.stderr)
            print(sim.stdout + sim.stderr, file=sys.stderr)

    except Exception as e:
        report["error"] = str(e)
        print(f"Error during run: {e}", file=sys.stderr)

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")

    if report["status"] != "pass":
        sys.exit(1)

if __name__ == "__main__":
    main()
