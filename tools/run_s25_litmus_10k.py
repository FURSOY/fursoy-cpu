#!/usr/bin/env python3
"""Fursoy Slice-2.5 Milestone S2.5-M2b: Contract-Scale RVWMO Litmus Verification Runner.

Compiles software/baremetal/s2_m4_litmus_test.S with -DLITMUS_ITERS=<N> (default 10000)
and executes the full 8-pattern RVWMO SMP litmus suite (MP + MP_CTRL, SB, LB, IRIW,
CoRR, CoWR, CoRW, CoWW) on N=2 and/or N=4 harts with 100% per-cycle S2SwmrScoreboard
enforcement (SWMR, metadata, inclusion, and data-coherence invariants).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import resource
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from s2_verilator_lib import (
    ROOT,
    compute_rtl_sha256,
    ensure_soc_lib,
    get_build_jobs,
    link_verilator_tb,
    run_cmd,
)

BUILD_DIR = ROOT / "build/s25_litmus_10k"
DEFAULT_REPORT = ROOT / "results/s25-litmus-10k.json"
REQUIRED_TESTS = ("MP", "SB", "LB", "IRIW", "CoRR", "CoWR", "CoRW", "CoWW")
DEFAULT_THREADS_BY_HARTS = {2: 4, 4: 2}


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_threads_for(num_harts: int, explicit_threads: int | None) -> int:
    if explicit_threads is not None and explicit_threads > 0:
        return explicit_threads
    env = os.environ.get("FURSOY_VERILATOR_THREADS")
    if env:
        try:
            val = int(env)
            if val > 0:
                return val
        except ValueError:
            pass
    return DEFAULT_THREADS_BY_HARTS.get(num_harts, 2)


def extract_last_json(output: str) -> dict[str, Any]:
    start = output.rfind("\n{")
    if start == -1:
        start = output.find("{")
    else:
        start += 1
    end = output.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError(f"Could not find JSON object in output:\n{output[-1500:]}")
    return json.loads(output[start : end + 1])


def read_proc_vmhwm_kib(pid: int) -> int | None:
    try:
        with open(f"/proc/{pid}/status", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmHWM:"):
                    parts = line.split()
                    if len(parts) >= 2:
                        return int(parts[1])
    except OSError:
        pass
    return None


def read_host_mem_info_kib() -> dict[str, int]:
    out: dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                for key in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
                    if line.startswith(f"{key}:"):
                        out[key] = int(line.split()[1])
    except OSError:
        pass
    if "SwapTotal" in out and "SwapFree" in out:
        out["SwapUsed"] = max(0, out["SwapTotal"] - out["SwapFree"])
    return out


def compile_litmus_elf(num_harts: int, iters: int) -> Path:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    elf = BUILD_DIR / f"s2_m4_litmus_n{num_harts}_i{iters}.elf"
    cmd = [
        "riscv64-unknown-elf-gcc",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-nostdlib",
        "-nostartfiles",
        "-ffreestanding",
        f"-DNUM_HARTS={num_harts}",
        f"-DLITMUS_ITERS={iters}",
        "-T",
        str(ROOT / "software/baremetal/s2_link.ld"),
        str(ROOT / "software/baremetal/s2_m4_litmus_test.S"),
        "-o",
        str(elf),
    ]
    rc, out = run_cmd(cmd, timeout_s=120)
    if rc != 0:
        raise RuntimeError(
            f"Litmus ELF build failed for N={num_harts}, iters={iters}:\n{out}"
        )
    return elf


def build_sim_binary(num_harts: int, threads: int, jobs: int) -> tuple[Path, float, float, bool]:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    soc_mdir, soc_lib, global_objs, soc_build_s, soc_rebuilt = ensure_soc_lib(
        num_harts=num_harts,
        jobs=jobs,
        threads=threads,
        smp_coherence_en=1,
        log_path=BUILD_DIR / f"soc_build_n{num_harts}_t{threads}.log",
    )
    exe = BUILD_DIR / f"Vs2_m4_litmus_n{num_harts}_t{threads}"
    _, link_s = link_verilator_tb(
        num_harts=num_harts,
        tb_cpp=ROOT / "verification/s2_m4_litmus_tb.cpp",
        soc_mdir=soc_mdir,
        soc_lib=soc_lib,
        global_objs=global_objs,
        exe_path=exe,
        threads=threads,
        extra_include_dirs=[ROOT / "verification"],
    )
    return exe, soc_build_s, link_s, soc_rebuilt


def run_single_config(
    num_harts: int,
    iters: int,
    max_cycles: int,
    threads: int,
    jobs: int,
    prebuild_only: bool,
) -> dict[str, Any]:
    print(
        f"[S2.5-M2b] Preparing N={num_harts} (iters={iters}, threads={threads}, jobs={jobs}, max_cycles={max_cycles})",
        flush=True,
    )
    elf = compile_litmus_elf(num_harts, iters)
    exe, soc_build_s, link_s, soc_rebuilt = build_sim_binary(num_harts, threads, jobs)
    print(
        f"[S2.5-M2b] Ready N={num_harts}: exe={exe.relative_to(ROOT)} elf={elf.relative_to(ROOT)} "
        f"soc_rebuilt={soc_rebuilt} soc_build_s={soc_build_s:.1f} link_s={link_s:.1f}",
        flush=True,
    )
    if prebuild_only:
        return {
            "num_harts": num_harts,
            "verilator_threads": threads,
            "iters_per_test": iters,
            "status": "prebuilt",
            "soc_rebuilt": soc_rebuilt,
            "soc_build_seconds": round(soc_build_s, 3),
            "link_seconds": round(link_s, 3),
            "binary": str(exe.relative_to(ROOT)),
            "elf": str(elf.relative_to(ROOT)),
        }

    started_at = utc_now_iso()
    t0 = time.monotonic()
    cmd = [str(exe), str(elf), str(max_cycles)]
    print(f"[S2.5-M2b] Launching N={num_harts}: {' '.join(cmd)}", flush=True)

    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        bufsize=1,
    )
    lines: list[str] = []
    uart_lines: list[str] = []
    peak_vmhwm_kib = 0

    assert proc.stdout is not None
    for raw_line in proc.stdout:
        line = raw_line.rstrip("\n")
        lines.append(line)
        if line.startswith("[UART] "):
            uart_lines.append(line[len("[UART] ") :])
        if (
            line.startswith("[UART] ")
            or line.startswith("[PROGRESS] ")
            or line.startswith("[SB ERROR]")
            or line.startswith("[WATCHDOG ERROR]")
        ):
            print(f"[N={num_harts}] {line}", flush=True)
        vmhwm = read_proc_vmhwm_kib(proc.pid)
        if vmhwm is not None and vmhwm > peak_vmhwm_kib:
            peak_vmhwm_kib = vmhwm

    rc = proc.wait()
    wall_s = time.monotonic() - t0
    finished_at = utc_now_iso()
    child_ru_maxrss_kib = int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    peak_rss_kib = peak_vmhwm_kib if peak_vmhwm_kib > 0 else child_ru_maxrss_kib
    host_mem = read_host_mem_info_kib()

    full_out = "\n".join(lines)
    sim_json = extract_last_json(full_out)

    cycles = int(sim_json.get("cycles", 0))
    per_hart_commits = [int(x) for x in sim_json.get("per_hart_commits", [])]
    total_commits = sum(per_hart_commits)
    agg_ipc = (total_commits / cycles) if cycles > 0 else 0.0
    cyc_per_s = (cycles / wall_s) if wall_s > 0 else 0.0

    litmus_tests = sim_json.get("litmus_tests", {})
    iters_ok = True
    forbidden_ok = True
    for name in REQUIRED_TESTS:
        entry = litmus_tests.get(name)
        if not isinstance(entry, dict):
            iters_ok = False
            forbidden_ok = False
            continue
        if int(entry.get("iters", 0)) != iters:
            iters_ok = False
        if int(entry.get("forbidden", -1)) != 0:
            forbidden_ok = False

    mp_ctrl_iters = int(sim_json.get("mp_ctrl_iters", 0))
    if mp_ctrl_iters != iters:
        iters_ok = False

    swmr_v = int(sim_json.get("swmr_violations", -1))
    meta_v = int(sim_json.get("metadata_violations", -1))
    incl_v = int(sim_json.get("inclusion_violations", -1))
    data_v = int(sim_json.get("data_coherence_violations", -1))
    sb_checks = int(sim_json.get("sb_cycle_checks", 0))
    sb_full_coverage = cycles > 0 and sb_checks == cycles

    passed = (
        rc == 0
        and sim_json.get("status") == "pass"
        and bool(sim_json.get("all_tests_present"))
        and bool(sim_json.get("zero_forbidden"))
        and bool(sim_json.get("all_harts_ok"))
        and bool(sim_json.get("sb_ok"))
        and not bool(sim_json.get("watchdog_stall", False))
        and iters_ok
        and forbidden_ok
        and swmr_v == 0
        and meta_v == 0
        and incl_v == 0
        and data_v == 0
        and sb_full_coverage
    )

    result = {
        "num_harts": num_harts,
        "verilator_threads": threads,
        "iters_per_test": iters,
        "max_cycles": max_cycles,
        "status": "pass" if passed else "fail",
        "exit_code": rc,
        "started_at_utc": started_at,
        "finished_at_utc": finished_at,
        "soc_rebuilt": soc_rebuilt,
        "soc_build_seconds": round(soc_build_s, 3),
        "link_seconds": round(link_s, 3),
        "wall_seconds": round(wall_s, 3),
        "cycles": cycles,
        "cycles_per_second": round(cyc_per_s, 2),
        "peak_rss_kib": peak_rss_kib,
        "host_mem_end_kib": host_mem,
        "total_commits": total_commits,
        "aggregate_ipc": round(agg_ipc, 4),
        "per_hart_commits": per_hart_commits,
        "all_tests_present": bool(sim_json.get("all_tests_present")),
        "zero_forbidden": bool(sim_json.get("zero_forbidden")) and forbidden_ok,
        "iters_verified": iters_ok,
        "all_harts_ok": bool(sim_json.get("all_harts_ok")),
        "sb_ok": bool(sim_json.get("sb_ok")),
        "sb_full_cycle_coverage": sb_full_coverage,
        "watchdog_stall": bool(sim_json.get("watchdog_stall", False)),
        "swmr_violations": swmr_v,
        "metadata_violations": meta_v,
        "inclusion_violations": incl_v,
        "data_coherence_violations": data_v,
        "sb_cycle_checks": sb_checks,
        "mp_ctrl_iters": mp_ctrl_iters,
        "mp_ctrl_reordered": int(sim_json.get("mp_ctrl_reordered", 0)),
        "mp_ctrl_seen11": int(sim_json.get("mp_ctrl_seen11", 0)),
        "litmus_tests": litmus_tests,
        "uart_lines": uart_lines,
        "command": cmd,
    }
    print(
        f"[S2.5-M2b] Finished N={num_harts}: status={result['status']} cycles={cycles} "
        f"wall_s={wall_s:.1f} cyc/s={cyc_per_s:.1f} ipc={agg_ipc:.4f} peak_rss_mib={peak_rss_kib / 1024.0:.1f}",
        flush=True,
    )
    return result


def build_combined_report(
    configs: dict[str, dict[str, Any]],
    rtl_sha256: str,
    iters: int,
    max_cycles: int,
    prebuild_only: bool = False,
) -> dict[str, Any]:
    if prebuild_only:
        overall = "prebuilt"
    else:
        overall = (
            "pass"
            if configs and all(cfg.get("status") == "pass" for cfg in configs.values())
            else "fail"
        )
    return {
        "milestone": "S2.5-M2b",
        "suite": "rvwmo_litmus_10k",
        "contract_ref": "docs/architecture/slice2-smp-v1.md §6.1-§6.2",
        "generated_at_utc": utc_now_iso(),
        "rtl_sha256": rtl_sha256,
        "iters_per_test": iters,
        "max_cycles": max_cycles,
        "patterns": list(REQUIRED_TESTS),
        "scoreboard_mode": "per_cycle_100pct",
        "status": overall,
        "configs": configs,
    }


def merge_reports(paths: list[Path], out_report: Path) -> int:
    merged_configs: dict[str, dict[str, Any]] = {}
    rtl_sha: str | None = None
    iters: int | None = None
    max_cycles: int = 0
    for p in paths:
        data = json.loads(p.read_text(encoding="utf-8"))
        cur_sha = data.get("rtl_sha256")
        cur_iters = int(data.get("iters_per_test", 0))
        if rtl_sha is None:
            rtl_sha = cur_sha
        elif cur_sha != rtl_sha:
            raise RuntimeError(f"RTL SHA mismatch across merged reports: {rtl_sha} vs {cur_sha} ({p})")
        if iters is None:
            iters = cur_iters
        elif cur_iters != iters:
            raise RuntimeError(f"iters_per_test mismatch across merged reports: {iters} vs {cur_iters} ({p})")
        max_cycles = max(max_cycles, int(data.get("max_cycles", 0)))
        for k, v in data.get("configs", {}).items():
            merged_configs[k] = v

    if rtl_sha is None or iters is None:
        raise RuntimeError("No valid configs found in --merge-reports inputs")

    cur_live_sha = compute_rtl_sha256()
    if rtl_sha != cur_live_sha:
        raise RuntimeError(f"Merged report RTL SHA {rtl_sha} does not match current workspace RTL {cur_live_sha}")

    ordered = {k: merged_configs[k] for k in sorted(merged_configs.keys())}
    report = build_combined_report(ordered, rtl_sha, iters, max_cycles)
    out_report.parent.mkdir(parents=True, exist_ok=True)
    out_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"[S2.5-M2b] Merged {len(ordered)} configs into {out_report}: status={report['status']}", flush=True)
    return 0 if report["status"] == "pass" else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Run contract-scale S2.5-M2b RVWMO litmus verification.")
    parser.add_argument("--num-harts", choices=("2", "4", "all"), default="all")
    parser.add_argument("--iters", type=int, default=10000)
    parser.add_argument("--max-cycles", type=int, default=150000000)
    parser.add_argument("--threads", type=int, default=None, help="Verilator thread count override (default: N=2->4, N=4->2)")
    parser.add_argument("--jobs", type=int, default=None, help="Parallel build jobs for Verilator SoC build")
    parser.add_argument("--prebuild-only", action="store_true", help="Only compile ELFs, SoC libs, and testbench binaries")
    parser.add_argument("--out-report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--merge-reports", nargs="+", type=Path, default=None, help="Merge per-config JSON reports into --out-report")
    args = parser.parse_args()

    if args.merge_reports:
        return merge_reports(args.merge_reports, args.out_report)

    rtl_sha = compute_rtl_sha256()
    jobs = args.jobs if args.jobs is not None else get_build_jobs()
    harts_list = [2, 4] if args.num_harts == "all" else [int(args.num_harts)]

    configs: dict[str, dict[str, Any]] = {}
    for n in harts_list:
        threads = default_threads_for(n, args.threads)
        configs[f"n{n}"] = run_single_config(
            num_harts=n,
            iters=args.iters,
            max_cycles=args.max_cycles,
            threads=threads,
            jobs=jobs,
            prebuild_only=args.prebuild_only,
        )

    report = build_combined_report(
        configs=configs,
        rtl_sha256=rtl_sha,
        iters=args.iters,
        max_cycles=args.max_cycles,
        prebuild_only=args.prebuild_only,
    )
    if not args.prebuild_only:
        args.out_report.parent.mkdir(parents=True, exist_ok=True)
        args.out_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"[S2.5-M2b] Wrote report {args.out_report}: status={report['status']}", flush=True)
    return 0 if report["status"] in ("pass", "prebuilt") else 1


if __name__ == "__main__":
    sys.exit(main())
