"""Build and run the Fursoy Slice-1 Milestone 5 Phase B4 (Oldest-Ready Matrix Scheduling) Verification & Profiling Suite with Verilator."""
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL_PKG = ROOT / "rtl/core/fursoy_s1_pkg.sv"
RTL_INTIQ = ROOT / "rtl/core/fursoy_s1_int_iq.sv"
RTL_CORE = ROOT / "rtl/core/fursoy_s1_core.sv"

TB_INTIQ_UNIT = ROOT / "verification/s1_m5_b4_intiq_unit_tb.cpp"
BUILD_DIR_INTIQ = ROOT / "build/s1_m5_b4_intiq"

TB_CORE = ROOT / "verification/s1_m5_b4_tb.cpp"
BUILD_DIR_CORE = ROOT / "build/s1_m5_b4"

REPORT = ROOT / "results/s1-m5-b4.json"

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

# Primary Incremental Baseline: Immediate predecessor, Frozen Phase B3 (commit 4bd71cc1ae6b63dca268275d28bffbc6976bf9c8, results/s1-m5-b3.json)
PHASE_B3_PREDECESSOR = {
    "source_file": "results/s1-m5-b3.json",
    "commit": "4bd71cc1ae6b63dca268275d28bffbc6976bf9c8",
    "description": "Immediate predecessor baseline (Frozen Phase B3 MemIQ16)",
    "workloads": {
        "branch_torture": {"cycles": 1715, "instret": 450, "ipc": 0.2624, "intiq_full": 0, "intiq_empty": 1715, "port0_uops": 450},
        "pointer_chasing": {"cycles": 789, "instret": 193, "ipc": 0.2446, "intiq_full": 0, "intiq_empty": 789, "port0_uops": 129},
        "stream_memcpy": {"cycles": 467, "instret": 194, "ipc": 0.4154, "intiq_full": 0, "intiq_empty": 467, "port0_uops": 130},
        "int_dependency": {"cycles": 1753, "instret": 257, "ipc": 0.1466, "intiq_full": 0, "intiq_empty": 1721, "port0_uops": 257},
        "raw_stress": {"cycles": 434, "instret": 162, "ipc": 0.3733, "intiq_full": 0, "intiq_empty": 434, "port0_uops": 98},
    }
}

# Canonical Long-Term Baseline: Frozen Phase A (commit 2d22a9663c00d26dda49415c1ea12ead4c9ef5a9, results/s1-m5-phase-a.json)
PHASE_A_CANONICAL = {
    "source_file": "results/s1-m5-phase-a.json",
    "commit": "2d22a9663c00d26dda49415c1ea12ead4c9ef5a9",
    "description": "Canonical long-term baseline (Frozen Phase A)",
    "workloads": {
        "branch_torture": {"cycles": 1712, "instret": 450, "ipc": 0.2629},
        "pointer_chasing": {"cycles": 789, "instret": 193, "ipc": 0.2446},
        "stream_memcpy": {"cycles": 467, "instret": 194, "ipc": 0.4154},
        "int_dependency": {"cycles": 1753, "instret": 257, "ipc": 0.1466},
        "raw_stress": {"cycles": 434, "instret": 162, "ipc": 0.3733},
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

def get_event(events, key, default=0):
    if not isinstance(events, dict):
        return default
    if key in events:
        return events[key]
    key_lower = key.lower()
    for k, v in events.items():
        if k.lower() == key_lower:
            return v
    return default

def build_intiq_unit(report):
    BUILD_DIR_INTIQ.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_int_iq",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR_INTIQ),
        str(RTL_PKG), str(RTL_INTIQ), str(TB_INTIQ_UNIT),
        "-o", "Vfursoy_s1_intiq_unit"
    ]
    t0 = time.time()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    dt = time.time() - t0

    build_log = BUILD_DIR_INTIQ / "build.log"
    build_log.write_text(res.stdout + res.stderr, encoding="utf-8")

    report["build_intiq_unit"] = {
        "command": cmd,
        "exit_code": res.returncode,
        "duration_sec": round(dt, 2),
        "log": str(build_log.relative_to(ROOT)),
    }

    if res.returncode != 0:
        print("IntIQ unit build failed:", file=sys.stderr)
        print(res.stdout + res.stderr, file=sys.stderr)
        raise RuntimeError("Verilator build for IntIQ unit failed")

    return BUILD_DIR_INTIQ / "Vfursoy_s1_intiq_unit"

def build_core(report):
    BUILD_DIR_CORE.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_core",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR_CORE),
        str(RTL_CORE), str(TB_CORE),
        "-o", "Vfursoy_s1_core_b4"
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

    return BUILD_DIR_CORE / "Vfursoy_s1_core_b4"

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
        "suite": "fursoy_s1_m5_b4",
        "milestone": "Milestone 5 — Phase B4: Oldest-Ready Matrix Scheduling",
        "canonical_spec": "docs/architecture/slice1-m5-performance-v1.md (v1.2, Section 7.4)",
        "evidence_type": "b4_oldest_ready_intiq_unit_verification_and_workload_profiling",
        "unit_scenarios": 14,
        "randomized_torture_seeds": [42, 20260920, 20261009],
        "min_accepted_ops_contract": 25000,
        "core_scenarios": 5,
        "profiling_workloads": 5,
        "status": "fail",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "rtl_manifest_sha256": manifest_sha(ALL_RTL),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [*ALL_RTL, TB_INTIQ_UNIT, TB_CORE, Path(__file__).resolve()]},
        "verilator_version": subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip(),
        "g++_version": subprocess.run(["g++", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
    }

    try:
        # Step 1: Run dedicated IntIQ unit verification
        print(">>> [1/2] Building and running Oldest-Ready IntIQ Unit Verification Harness...")
        bin_intiq = build_intiq_unit(report)
        t0 = time.time()
        sim_intiq = subprocess.run([str(bin_intiq)], cwd=ROOT, capture_output=True, text=True)
        dt_intiq = time.time() - t0

        sim_intiq_log = BUILD_DIR_INTIQ / "simulation.log"
        sim_intiq_log.write_text(sim_intiq.stdout + sim_intiq.stderr, encoding="utf-8")

        seed_results = {}
        for line in sim_intiq.stdout.splitlines():
            m = re.match(r"seed_(\d+): iterations=(\d+) allocs=(\d+) issues=(\d+) ops=(\d+) mismatches=(\d+) watchdog=(\w+)", line)
            if m:
                s_id = int(m.group(1))
                seed_results[f"seed_{s_id}"] = {
                    "seed": s_id,
                    "attempted_iterations": int(m.group(2)),
                    "accepted_allocations": int(m.group(3)),
                    "accepted_issues": int(m.group(4)),
                    "accepted_operations": int(m.group(5)),
                    "mismatches": int(m.group(6)),
                    "watchdog_tripped": m.group(7) != "OK",
                }

        report["unit_verification"] = {
            "exit_code": sim_intiq.returncode,
            "duration_sec": round(dt_intiq, 2),
            "log": str(sim_intiq_log.relative_to(ROOT)),
            "stdout": sim_intiq.stdout,
            "randomized_seed_results": seed_results,
        }

        if sim_intiq.returncode != 0:
            print("IntIQ unit verification FAIL!", file=sys.stderr)
            print(sim_intiq.stdout + sim_intiq.stderr, file=sys.stderr)
            sys.exit(1)
        else:
            print(">>> Oldest-Ready IntIQ Unit Verification: 14/14 SCENARIOS PASS (seeds 42, 20260920, 20261009 >= 25k accepted ops each)")

        # Step 2: Run Core Integration & 5-Workload Profiling
        print(">>> [2/2] Building and running Core Oldest-Ready IntIQ Integration & Profiling...")
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
                "milestone": "Milestone 5 — Phase B3 (Frozen)",
                "source_artifact": "results/s1-m5-b3.json",
                "commit": "4bd71cc1ae6b63dca268275d28bffbc6976bf9c8",
                "role": "Primary incremental comparison baseline for Phase B4 (Oldest-Ready Matrix Scheduling)",
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
        deltas_vs_b3 = {}
        deltas_vs_a = {}
        if "profiles" in profile_data:
            for name, p in profile_data["profiles"].items():
                if name in PHASE_B3_PREDECESSOR["workloads"]:
                    b3 = PHASE_B3_PREDECESSOR["workloads"][name]
                    deltas_vs_b3[name] = {
                        "b4_cycles": p["cycles"],
                        "b3_cycles": b3["cycles"],
                        "cycle_delta_vs_b3": p["cycles"] - b3["cycles"],
                        "b4_instret": p["instret"],
                        "b3_instret": b3["instret"],
                        "b4_ipc": p["ipc"],
                        "b3_ipc": b3["ipc"],
                        "ipc_delta_vs_b3": round(p["ipc"] - b3["ipc"], 4),
                        "b4_intiq_full": get_event(p["events"], "0x15", 0),
                        "b3_intiq_full": b3["intiq_full"],
                        "b4_intiq_empty": get_event(p["events"], "0x21", 0),
                        "b3_intiq_empty": b3["intiq_empty"],
                        "b4_port0_uops": get_event(p["events"], "0x1b", 0),
                        "b3_port0_uops": b3["port0_uops"],
                    }
                if name in PHASE_A_CANONICAL["workloads"]:
                    a = PHASE_A_CANONICAL["workloads"][name]
                    deltas_vs_a[name] = {
                        "b4_cycles": p["cycles"],
                        "phase_a_cycles": a["cycles"],
                        "cycle_delta_vs_phase_a": p["cycles"] - a["cycles"],
                        "b4_instret": p["instret"],
                        "phase_a_instret": a["instret"],
                        "b4_ipc": p["ipc"],
                        "phase_a_ipc": a["ipc"],
                        "ipc_delta_vs_phase_a": round(p["ipc"] - a["ipc"], 4),
                        "b4_intiq_full": get_event(p["events"], "0x15", 0),
                        "b4_intiq_empty": get_event(p["events"], "0x21", 0),
                        "b4_port0_uops": get_event(p["events"], "0x1b", 0),
                    }

        report["deltas_vs_phase_b3_predecessor"] = deltas_vs_b3
        report["deltas_vs_phase_a_canonical"] = deltas_vs_a
        report["baseline_deltas"] = {
            "vs_phase_b3_predecessor": deltas_vs_b3,
            "vs_phase_a_canonical": deltas_vs_a,
        }

        report["status"] = "pass"
        print("\n=============================================================================")
        print("Fursoy Slice-1 M5 Phase B4 (Oldest-Ready Matrix Scheduling) Verification & Profiling: ALL PASS")
        print("=============================================================================")
        print("--- Comparison 1: Primary Incremental Deltas vs Phase B3 Predecessor (results/s1-m5-b3.json) ---")
        for name, d in deltas_vs_b3.items():
            print(f"Workload {name:16}: B4 {d['b4_cycles']} cyc (vs B3 {d['b3_cycles']} cyc, delta {d['cycle_delta_vs_b3']:+d}), B4 IPC {d['b4_ipc']:.4f} (vs B3 {d['b3_ipc']:.4f}, delta {d['ipc_delta_vs_b3']:+.4f})")
        print("\n--- Comparison 2: Canonical Deltas vs Phase A Baseline (results/s1-m5-phase-a.json) ---")
        for name, d in deltas_vs_a.items():
            print(f"Workload {name:16}: B4 {d['b4_cycles']} cyc (vs Phase-A {d['phase_a_cycles']} cyc, delta {d['cycle_delta_vs_phase_a']:+d}), B4 IPC {d['b4_ipc']:.4f} (vs Phase-A {d['phase_a_ipc']:.4f}, delta {d['ipc_delta_vs_phase_a']:+.4f})")
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
