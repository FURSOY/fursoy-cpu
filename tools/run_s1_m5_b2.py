"""Build and run the Fursoy Slice-1 Milestone 5 Phase B2 (FQ16) Verification & Profiling Suite with Verilator."""
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
RTL_FQ = ROOT / "rtl/core/fursoy_s1_fetch_queue.sv"

TB_FQ_UNIT = ROOT / "verification/s1_m5_b2_fq_unit_tb.cpp"
BUILD_DIR_FQ = ROOT / "build/s1_m5_b2_fq"

TB_CORE = ROOT / "verification/s1_m5_b2_tb.cpp"
BUILD_DIR_CORE = ROOT / "build/s1_m5_b2"

REPORT = ROOT / "results/s1-m5-b2.json"

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

# Primary Incremental Baseline: Immediate predecessor, Frozen Phase B1 (commit 25b23f4844b20a40475e744ba65929d39c35a596, results/s1-m5-b1.json)
PHASE_B1_PREDECESSOR = {
    "source_file": "results/s1-m5-b1.json",
    "commit": "25b23f4844b20a40475e744ba65929d39c35a596",
    "description": "Immediate predecessor baseline (Frozen Phase B1)",
    "workloads": {
        "branch_torture": {"cycles": 1715, "instret": 450, "ipc": 0.2624, "fq_full": 0, "fq_starved": 261},
        "pointer_chasing": {"cycles": 788, "instret": 193, "ipc": 0.2449, "fq_full": 16, "fq_starved": 131},
        "stream_memcpy": {"cycles": 466, "instret": 194, "ipc": 0.4163, "fq_full": 16, "fq_starved": 67},
        "int_dependency": {"cycles": 1753, "instret": 257, "ipc": 0.1466, "fq_full": 316, "fq_starved": 67},
        "raw_stress": {"cycles": 433, "instret": 162, "ipc": 0.3741, "fq_full": 16, "fq_starved": 67},
    }
}

# Canonical Long-Term Baseline: Frozen Phase A (commit 2d22a9663c00d26dda49415c1ea12ead4c9ef5a9, results/s1-m5-phase-a.json)
PHASE_A_CANONICAL = {
    "source_file": "results/s1-m5-phase-a.json",
    "commit": "2d22a9663c00d26dda49415c1ea12ead4c9ef5a9",
    "description": "Canonical long-term baseline (Frozen Phase A)",
    "workloads": {
        "branch_torture": {"cycles": 1712, "instret": 450, "ipc": 0.2629, "fq_full": 0, "fq_starved": 257},
        "pointer_chasing": {"cycles": 789, "instret": 193, "ipc": 0.2446, "fq_full": 15, "fq_starved": 128},
        "stream_memcpy": {"cycles": 467, "instret": 194, "ipc": 0.4154, "fq_full": 13, "fq_starved": 64},
        "int_dependency": {"cycles": 1753, "instret": 257, "ipc": 0.1466, "fq_full": 221, "fq_starved": 64},
        "raw_stress": {"cycles": 434, "instret": 162, "ipc": 0.3733, "fq_full": 13, "fq_starved": 64},
    }
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest_sha(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()

def check_duplicate_keys(pairs):
    res = {}
    for k, v in pairs:
        if k in res:
            raise ValueError(f"Duplicate key detected in JSON: {k}")
        res[k] = v
    return res

def build_fq_unit(report):
    BUILD_DIR_FQ.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_fetch_queue",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR_FQ),
        str(RTL_FQ), str(TB_FQ_UNIT),
        "-o", "Vfursoy_s1_fq_unit"
    ]
    t0 = time.time()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    dt = time.time() - t0

    build_log = BUILD_DIR_FQ / "build.log"
    build_log.write_text(res.stdout + res.stderr, encoding="utf-8")

    report["build_fq_unit"] = {
        "command": cmd,
        "exit_code": res.returncode,
        "duration_sec": round(dt, 2),
        "log": str(build_log.relative_to(ROOT)),
    }

    if res.returncode != 0:
        print("FQ unit build failed:", file=sys.stderr)
        print(res.stdout + res.stderr, file=sys.stderr)
        raise RuntimeError("Verilator build for FQ unit failed")

    return BUILD_DIR_FQ / "Vfursoy_s1_fq_unit"

def build_core(report):
    BUILD_DIR_CORE.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_core",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR_CORE),
        str(RTL_CORE), str(TB_CORE),
        "-o", "Vfursoy_s1_core_b2"
    ]
    t0 = time.time()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    dt = time.time() - t0

    build_log = BUILD_DIR_CORE / "build.log"
    build_log.write_text(res.stdout + res.stderr, encoding="utf-8")

    report["build_core"] = {
        "command": cmd,
        "exit_code": res.returncode,
        "duration_sec": round(dt, 2),
        "log": str(build_log.relative_to(ROOT)),
    }

    if res.returncode != 0:
        print("Core build failed:", file=sys.stderr)
        print(res.stdout + res.stderr, file=sys.stderr)
        raise RuntimeError("Verilator build for Core failed")

    return BUILD_DIR_CORE / "Vfursoy_s1_core_b2"

def extract_json_profile(stdout):
    match = re.search(r"--- BEGIN JSON PROFILE DATA ---\n(.*?)\n--- END JSON PROFILE DATA ---", stdout, re.DOTALL)
    if match:
        try:
            data = json.loads(match.group(1), object_pairs_hook=check_duplicate_keys)
            return data
        except Exception as e:
            return {"error": f"Failed to parse profile JSON: {e}"}
    return None

def main():
    report = {
        "suite": "fursoy_s1_m5_b2",
        "milestone": "Milestone 5 — Phase B2: Fetch Queue Capacity Expansion (FQ16)",
        "canonical_spec": "docs/architecture/slice1-m5-performance-v1.md (v1.2, Frozen Section 7.2)",
        "evidence_type": "b2_fq16_unit_verification_and_workload_profiling",
        "fq_depth": 16,
        "unit_scenarios": 13,
        "randomized_torture_ops": 50000,
        "core_scenarios": 5,
        "profiling_workloads": 5,
        "status": "fail",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "rtl_manifest_sha256": manifest_sha(ALL_RTL),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [*ALL_RTL, TB_FQ_UNIT, TB_CORE, Path(__file__).resolve()]},
        "verilator_version": subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip(),
        "g++_version": subprocess.run(["g++", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
    }

    try:
        # Step 1: Run dedicated FQ unit verification
        print(">>> [1/2] Building and running FQ16 Unit Verification Harness...")
        bin_fq = build_fq_unit(report)
        t0 = time.time()
        sim_fq = subprocess.run([str(bin_fq)], cwd=ROOT, capture_output=True, text=True)
        dt_fq = time.time() - t0

        sim_fq_log = BUILD_DIR_FQ / "simulation.log"
        sim_fq_log.write_text(sim_fq.stdout + sim_fq.stderr, encoding="utf-8")

        report["unit_verification"] = {
            "exit_code": sim_fq.returncode,
            "duration_sec": round(dt_fq, 2),
            "log": str(sim_fq_log.relative_to(ROOT)),
            "stdout": sim_fq.stdout,
        }

        if sim_fq.returncode != 0:
            print("FQ unit verification FAIL!", file=sys.stderr)
            print(sim_fq.stdout + sim_fq.stderr, file=sys.stderr)
            sys.exit(1)
        else:
            print(">>> FQ16 Unit Verification: 13/13 SCENARIOS PASS (including 50,000 ops torture)")

        # Step 2: Run Core Integration & 5-Workload Profiling
        print(">>> [2/2] Building and running Core FQ16 Integration & Profiling...")
        bin_core = build_core(report)
        t0 = time.time()
        sim_core = subprocess.run([str(bin_core)], cwd=ROOT, capture_output=True, text=True)
        dt_core = time.time() - t0

        sim_core_log = BUILD_DIR_CORE / "simulation.log"
        sim_core_log.write_text(sim_core.stdout + sim_core.stderr, encoding="utf-8")

        profile_data = extract_json_profile(sim_core.stdout)
        report["core_simulation"] = {
            "exit_code": sim_core.returncode,
            "duration_sec": round(dt_core, 2),
            "log": str(sim_core_log.relative_to(ROOT)),
            "profile_data": profile_data,
        }

        if sim_core.returncode != 0 or not profile_data or "error" in profile_data:
            print(f"Core simulation failed with exit code {sim_core.returncode}", file=sys.stderr)
            if profile_data and "error" in profile_data:
                print(f"Validation error: {profile_data['error']}", file=sys.stderr)
            print(sim_core.stdout + sim_core.stderr, file=sys.stderr)
            sys.exit(1)

        # Document baseline provenance explicitly
        report["baseline_provenance"] = {
            "primary_incremental_predecessor": {
                "milestone": "Milestone 5 — Phase B1 (Frozen)",
                "source_artifact": "results/s1-m5-b1.json",
                "commit": "25b23f4844b20a40475e744ba65929d39c35a596",
                "role": "Primary incremental comparison baseline for Phase B2 (FQ16)",
            },
            "canonical_long_term_baseline": {
                "milestone": "Milestone 5 — Phase A (Frozen)",
                "source_artifact": "results/s1-m5-phase-a.json",
                "commit": "2d22a9663c00d26dda49415c1ea12ead4c9ef5a9",
                "role": "Canonical long-term baseline reference across Milestone 5",
            },
            "scope_note": "Reference measurements on 5 synthetic microbenchmarks only; does not imply generalized performance claim.",
        }

        # Compute performance deltas against BOTH baselines
        deltas_vs_b1 = {}
        deltas_vs_a = {}
        if "profiles" in profile_data:
            for name, p in profile_data["profiles"].items():
                if name in PHASE_B1_PREDECESSOR["workloads"]:
                    b1 = PHASE_B1_PREDECESSOR["workloads"][name]
                    deltas_vs_b1[name] = {
                        "b2_cycles": p["cycles"],
                        "b1_cycles": b1["cycles"],
                        "cycle_delta_vs_b1": p["cycles"] - b1["cycles"],
                        "b2_instret": p["instret"],
                        "b1_instret": b1["instret"],
                        "b2_ipc": p["ipc"],
                        "b1_ipc": b1["ipc"],
                        "ipc_delta_vs_b1": round(p["ipc"] - b1["ipc"], 4),
                        "b2_fq_full": p["events"].get("0x05", 0),
                        "b1_fq_full": b1["fq_full"],
                        "b2_fq_starved": p["events"].get("0x04", 0),
                        "b1_fq_starved": b1["fq_starved"],
                        "b2_fe_uops": p["events"].get("0x03", 0),
                    }
                if name in PHASE_A_CANONICAL["workloads"]:
                    a = PHASE_A_CANONICAL["workloads"][name]
                    deltas_vs_a[name] = {
                        "b2_cycles": p["cycles"],
                        "phase_a_cycles": a["cycles"],
                        "cycle_delta_vs_phase_a": p["cycles"] - a["cycles"],
                        "b2_instret": p["instret"],
                        "phase_a_instret": a["instret"],
                        "b2_ipc": p["ipc"],
                        "phase_a_ipc": a["ipc"],
                        "ipc_delta_vs_phase_a": round(p["ipc"] - a["ipc"], 4),
                        "b2_fq_full": p["events"].get("0x05", 0),
                        "phase_a_fq_full": a["fq_full"],
                        "b2_fq_starved": p["events"].get("0x04", 0),
                        "phase_a_fq_starved": a["fq_starved"],
                        "b2_fe_uops": p["events"].get("0x03", 0),
                    }

        report["deltas_vs_phase_b1_predecessor"] = deltas_vs_b1
        report["deltas_vs_phase_a_canonical"] = deltas_vs_a
        report["baseline_deltas"] = {
            "vs_phase_b1_predecessor": deltas_vs_b1,
            "vs_phase_a_canonical": deltas_vs_a,
        }

        report["status"] = "pass"
        print("\n=============================================================================")
        print("Fursoy Slice-1 M5 Phase B2 (FQ16) Verification & Profiling: ALL PASS")
        print("=============================================================================")
        print("--- Comparison 1: Primary Incremental Deltas vs Phase B1 Predecessor (results/s1-m5-b1.json) ---")
        for name, d in deltas_vs_b1.items():
            print(f"Workload {name:16}: B2 {d['b2_cycles']} cyc (vs B1 {d['b1_cycles']} cyc, delta {d['cycle_delta_vs_b1']:+d}), B2 IPC {d['b2_ipc']:.4f} (vs B1 {d['b1_ipc']:.4f}, delta {d['ipc_delta_vs_b1']:+.4f})")
        print("\n--- Comparison 2: Canonical Deltas vs Phase A Baseline (results/s1-m5-phase-a.json) ---")
        for name, d in deltas_vs_a.items():
            print(f"Workload {name:16}: B2 {d['b2_cycles']} cyc (vs Phase-A {d['phase_a_cycles']} cyc, delta {d['cycle_delta_vs_phase_a']:+d}), B2 IPC {d['b2_ipc']:.4f} (vs Phase-A {d['phase_a_ipc']:.4f}, delta {d['ipc_delta_vs_phase_a']:+.4f})")
        print("\nNote: Five synthetic workloads are reference samples only; no generalized performance claims made.")

    except Exception as e:
        report["error"] = str(e)
        print(f"Error during run: {e}", file=sys.stderr)

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2), encoding="utf-8")

    if report["status"] != "pass":
        sys.exit(1)

if __name__ == "__main__":
    main()
