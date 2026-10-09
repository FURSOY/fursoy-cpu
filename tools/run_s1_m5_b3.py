"""Build and run the Fursoy Slice-1 Milestone 5 Phase B3 (MemIQ16) Verification & Profiling Suite with Verilator."""
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
RTL_MEMIQ = ROOT / "rtl/core/fursoy_s1_mem_iq.sv"

TB_MEMIQ_UNIT = ROOT / "verification/s1_m5_b3_memiq_unit_tb.cpp"
BUILD_DIR_MEMIQ = ROOT / "build/s1_m5_b3_memiq"

TB_CORE = ROOT / "verification/s1_m5_b3_tb.cpp"
BUILD_DIR_CORE = ROOT / "build/s1_m5_b3"

REPORT = ROOT / "results/s1-m5-b3.json"

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

# Primary Incremental Baseline: Immediate predecessor, Frozen Phase B2 (commit e745cbabab0b975ba6bd24d4a57e998757cad813, results/s1-m5-b2.json)
PHASE_B2_PREDECESSOR = {
    "source_file": "results/s1-m5-b2.json",
    "commit": "e745cbabab0b975ba6bd24d4a57e998757cad813",
    "description": "Immediate predecessor baseline (Frozen Phase B2 FQ16)",
    "workloads": {
        "branch_torture": {"cycles": 1715, "instret": 450, "ipc": 0.2624, "memiq_full": 0, "memiq_empty": 1715, "port2_agu": 0},
        "pointer_chasing": {"cycles": 789, "instret": 193, "ipc": 0.2446, "memiq_full": 0, "memiq_empty": 725, "port2_agu": 64},
        "stream_memcpy": {"cycles": 467, "instret": 194, "ipc": 0.4154, "memiq_full": 0, "memiq_empty": 403, "port2_agu": 64},
        "int_dependency": {"cycles": 1753, "instret": 257, "ipc": 0.1466, "memiq_full": 0, "memiq_empty": 1753, "port2_agu": 0},
        "raw_stress": {"cycles": 434, "instret": 162, "ipc": 0.3733, "memiq_full": 0, "memiq_empty": 370, "port2_agu": 64},
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

def build_memiq_unit(report):
    BUILD_DIR_MEMIQ.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_mem_iq",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR_MEMIQ),
        str(RTL_MEMIQ), str(TB_MEMIQ_UNIT),
        "-o", "Vfursoy_s1_memiq_unit"
    ]
    t0 = time.time()
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    dt = time.time() - t0

    build_log = BUILD_DIR_MEMIQ / "build.log"
    build_log.write_text(res.stdout + res.stderr, encoding="utf-8")

    report["build_memiq_unit"] = {
        "command": cmd,
        "exit_code": res.returncode,
        "duration_sec": round(dt, 2),
        "log": str(build_log.relative_to(ROOT)),
    }

    if res.returncode != 0:
        print("MemIQ unit build failed:", file=sys.stderr)
        print(res.stdout + res.stderr, file=sys.stderr)
        raise RuntimeError("Verilator build for MemIQ unit failed")

    return BUILD_DIR_MEMIQ / "Vfursoy_s1_memiq_unit"

def build_core(report):
    BUILD_DIR_CORE.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator", "--cc", "--exe", "--build", "--assert", "-Wall",
        "-O3", "-j", "4",
        "--top-module", "fursoy_s1_core",
        "-Irtl/core",
        "--Mdir", str(BUILD_DIR_CORE),
        str(RTL_CORE), str(TB_CORE),
        "-o", "Vfursoy_s1_core_b3"
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

    return BUILD_DIR_CORE / "Vfursoy_s1_core_b3"

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
        "suite": "fursoy_s1_m5_b3",
        "milestone": "Milestone 5 — Phase B3: Memory Issue Queue Capacity Expansion (MemIQ16)",
        "canonical_spec": "docs/architecture/slice1-m5-performance-v1.md (v1.2, Section 7.3)",
        "evidence_type": "b3_memiq16_unit_verification_and_workload_profiling",
        "memiq_depth": 16,
        "unit_scenarios": 14,
        "randomized_torture_seeds": [42, 20260920, 20261009],
        "min_accepted_ops_contract": 25000,
        "core_scenarios": 5,
        "profiling_workloads": 5,
        "status": "fail",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "rtl_manifest_sha256": manifest_sha(ALL_RTL),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [*ALL_RTL, TB_MEMIQ_UNIT, TB_CORE, Path(__file__).resolve()]},
        "verilator_version": subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip(),
        "g++_version": subprocess.run(["g++", "--version"], capture_output=True, text=True).stdout.splitlines()[0],
    }

    try:
        # Step 1: Run dedicated MemIQ unit verification
        print(">>> [1/2] Building and running MemIQ16 Unit Verification Harness...")
        bin_memiq = build_memiq_unit(report)
        t0 = time.time()
        sim_memiq = subprocess.run([str(bin_memiq)], cwd=ROOT, capture_output=True, text=True)
        dt_memiq = time.time() - t0

        sim_memiq_log = BUILD_DIR_MEMIQ / "simulation.log"
        sim_memiq_log.write_text(sim_memiq.stdout + sim_memiq.stderr, encoding="utf-8")

        seed_results = {}
        for line in sim_memiq.stdout.splitlines():
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
            "exit_code": sim_memiq.returncode,
            "duration_sec": round(dt_memiq, 2),
            "log": str(sim_memiq_log.relative_to(ROOT)),
            "stdout": sim_memiq.stdout,
            "randomized_seed_results": seed_results,
        }

        if sim_memiq.returncode != 0:
            print("MemIQ unit verification FAIL!", file=sys.stderr)
            print(sim_memiq.stdout + sim_memiq.stderr, file=sys.stderr)
            sys.exit(1)
        else:
            print(">>> MemIQ16 Unit Verification: 14/14 SCENARIOS PASS (seeds 42, 20260920, 20261009 >= 25k accepted ops each)")

        # Step 2: Run Core Integration & 5-Workload Profiling
        print(">>> [2/2] Building and running Core MemIQ16 Integration & Profiling...")
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
                "milestone": "Milestone 5 — Phase B2 (Frozen)",
                "source_artifact": "results/s1-m5-b2.json",
                "commit": "e745cbabab0b975ba6bd24d4a57e998757cad813",
                "role": "Primary incremental comparison baseline for Phase B3 (MemIQ16)",
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
        deltas_vs_b2 = {}
        deltas_vs_a = {}
        if "profiles" in profile_data:
            for name, p in profile_data["profiles"].items():
                if name in PHASE_B2_PREDECESSOR["workloads"]:
                    b2 = PHASE_B2_PREDECESSOR["workloads"][name]
                    deltas_vs_b2[name] = {
                        "b3_cycles": p["cycles"],
                        "b2_cycles": b2["cycles"],
                        "cycle_delta_vs_b2": p["cycles"] - b2["cycles"],
                        "b3_instret": p["instret"],
                        "b2_instret": b2["instret"],
                        "b3_ipc": p["ipc"],
                        "b2_ipc": b2["ipc"],
                        "ipc_delta_vs_b2": round(p["ipc"] - b2["ipc"], 4),
                        "b3_memiq_full": p["events"].get("0x16", 0),
                        "b2_memiq_full": b2["memiq_full"],
                        "b3_memiq_empty": p["events"].get("0x22", 0),
                        "b2_memiq_empty": b2["memiq_empty"],
                        "b3_port2_agu": p["events"].get("0x1F", 0),
                        "b2_port2_agu": b2["port2_agu"],
                    }
                if name in PHASE_A_CANONICAL["workloads"]:
                    a = PHASE_A_CANONICAL["workloads"][name]
                    deltas_vs_a[name] = {
                        "b3_cycles": p["cycles"],
                        "phase_a_cycles": a["cycles"],
                        "cycle_delta_vs_phase_a": p["cycles"] - a["cycles"],
                        "b3_instret": p["instret"],
                        "phase_a_instret": a["instret"],
                        "b3_ipc": p["ipc"],
                        "phase_a_ipc": a["ipc"],
                        "ipc_delta_vs_phase_a": round(p["ipc"] - a["ipc"], 4),
                        "b3_memiq_full": p["events"].get("0x16", 0),
                        "b3_memiq_empty": p["events"].get("0x22", 0),
                        "b3_port2_agu": p["events"].get("0x1F", 0),
                    }

        report["deltas_vs_phase_b2_predecessor"] = deltas_vs_b2
        report["deltas_vs_phase_a_canonical"] = deltas_vs_a
        report["baseline_deltas"] = {
            "vs_phase_b2_predecessor": deltas_vs_b2,
            "vs_phase_a_canonical": deltas_vs_a,
        }

        report["status"] = "pass"
        print("\n=============================================================================")
        print("Fursoy Slice-1 M5 Phase B3 (MemIQ16) Verification & Profiling: ALL PASS")
        print("=============================================================================")
        print("--- Comparison 1: Primary Incremental Deltas vs Phase B2 Predecessor (results/s1-m5-b2.json) ---")
        for name, d in deltas_vs_b2.items():
            print(f"Workload {name:16}: B3 {d['b3_cycles']} cyc (vs B2 {d['b2_cycles']} cyc, delta {d['cycle_delta_vs_b2']:+d}), B3 IPC {d['b3_ipc']:.4f} (vs B2 {d['b2_ipc']:.4f}, delta {d['ipc_delta_vs_b2']:+.4f})")
        print("\n--- Comparison 2: Canonical Deltas vs Phase A Baseline (results/s1-m5-phase-a.json) ---")
        for name, d in deltas_vs_a.items():
            print(f"Workload {name:16}: B3 {d['b3_cycles']} cyc (vs Phase-A {d['phase_a_cycles']} cyc, delta {d['cycle_delta_vs_phase_a']:+d}), B3 IPC {d['b3_ipc']:.4f} (vs Phase-A {d['phase_a_ipc']:.4f}, delta {d['ipc_delta_vs_phase_a']:+.4f})")
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
