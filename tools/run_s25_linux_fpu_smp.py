#!/usr/bin/env python3
"""Fursoy Slice-2.5 Milestone S2.5-M3b: Mainline Linux 6.6.50 CONFIG_SMP=y + CONFIG_FPU=y
Multi-Hart Preemption & FP Context-Switch Verification Runner.

Reuses tools/run_s2_m5.py & tools/s2_verilator_lib.py without touching frozen
results/s2-m5-closeout.json, verifies:
  - DTB riscv,isa == "rv64imafd_zba_zbb_zicsr_zifencei" via dtc -I dtb -O dts
  - CONFIG_FPU=y, CONFIG_SMP=y, CONFIG_NR_CPUS=4, !CONFIG_RISCV_ISA_C, !CONFIG_RISCV_ISA_V
  - Zero RVC instructions in rebuilt vmlinux and static s2_smp_test
  - Full N=2 (T=4) & N=4 (T=2) SMP Linux boots with oversubscribed FPU preemption
    ([SMP_FPU_PREEMPT_PASS] across f0..f31 & all 5 IEEE-754 frm rounding modes)
Writes verified evidence to results/s25-linux-fpu-smp.json.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import resource
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from gen_s2_dts import DEFAULT_BOOTARGS  # noqa: E402
from run_s2_m5 import (  # noqa: E402
    LINUX_SMP_DIR,
    LINUX_SMP_IMAGE,
    TB_CPP,
    build_dtb,
    build_sbi_firmware,
    ensure_smp_kernel,
    sha256_file,
)
from s2_verilator_lib import (  # noqa: E402
    compute_rtl_sha256,
    ensure_soc_lib,
    get_build_jobs,
    link_verilator_tb,
    run_cmd,
)

BUILD_DIR = ROOT / "build/s25_linux_fpu_smp"
DEFAULT_REPORT = ROOT / "results/s25-linux-fpu-smp.json"
SAIL_PRECHECK_JSON = BUILD_DIR / "sail_precheck/verified_result.json"
S2_SMP_TEST_BIN = ROOT / "build/s2_m5/s2_smp_test"
EXPECTED_DTB_ISA = "rv64imafd_zba_zbb_zicsr_zifencei"
DEFAULT_THREADS = {2: 4, 4: 2}


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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


def read_host_mem_kib() -> dict[str, int]:
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


def verify_elf_no_rvc(elf_path: Path, label: str) -> dict[str, Any]:
    if not elf_path.exists():
        raise RuntimeError(f"Missing ELF for RVC check ({label}): {elf_path}")
    rc, hdr = run_cmd(["riscv64-linux-gnu-readelf", "-h", "-A", str(elf_path)], timeout_s=60)
    if rc != 0:
        raise RuntimeError(f"readelf failed on {elf_path}:\n{hdr}")
    flags_line = ""
    arch_line = ""
    for line in hdr.splitlines():
        if "Flags:" in line:
            flags_line = line.strip()
            parts = line.split("Flags:")[-1].strip().split()
            if int(parts[0], 16) & 0x1:
                raise RuntimeError(f"{label} ({elf_path}) has EF_RISCV_RVC set: {flags_line}")
        if "Tag_RISCV_arch:" in line:
            arch_line = line.strip()
    return {
        "path": str(elf_path.relative_to(ROOT)),
        "sha256": sha256_file(elf_path),
        "elf_flags": flags_line,
        "riscv_arch_tag": arch_line,
        "rvc_absent": True,
    }


def verify_dtb_isa(dtb_path: Path, expected_cpus: int) -> dict[str, Any]:
    rc, dts_out = run_cmd(["dtc", "-I", "dtb", "-O", "dts", str(dtb_path)], timeout_s=30)
    if rc != 0:
        raise RuntimeError(f"dtc decompile failed for {dtb_path}:\n{dts_out}")
    isas = re.findall(r'riscv,isa\s*=\s*"([^"]+)"', dts_out)
    if len(isas) != expected_cpus or any(x != EXPECTED_DTB_ISA for x in isas):
        raise RuntimeError(
            f"DTB ISA mismatch in {dtb_path}: expected {expected_cpus}x {EXPECTED_DTB_ISA!r}, got {isas}"
        )
    return {
        "dtb_path": str(dtb_path.relative_to(ROOT)),
        "dtb_sha256": sha256_file(dtb_path),
        "cpu_nodes": len(isas),
        "riscv_isa": EXPECTED_DTB_ISA,
    }


def verify_kernel_config() -> dict[str, Any]:
    cfg_path = LINUX_SMP_DIR / ".config"
    txt = cfg_path.read_text(encoding="utf-8")
    checks = {
        "CONFIG_SMP": "CONFIG_SMP=y" in txt,
        "CONFIG_NR_CPUS_4": "CONFIG_NR_CPUS=4" in txt,
        "CONFIG_FPU": "CONFIG_FPU=y" in txt,
        "CONFIG_RISCV_ISA_C_disabled": "CONFIG_RISCV_ISA_C=y" not in txt,
        "CONFIG_RISCV_ISA_V_disabled": "CONFIG_RISCV_ISA_V=y" not in txt,
        "CONFIG_INITRAMFS_COMPRESSION_NONE": "CONFIG_INITRAMFS_COMPRESSION_NONE=y" in txt,
    }
    bad = [k for k, v in checks.items() if not v]
    if bad:
        raise RuntimeError(f"Linux .config failed required S2.5-M3b checks: {bad}")
    return checks


def extract_last_json(output: str) -> dict[str, Any]:
    m = re.search(r"\{\s*\n\s*\"status\":.*\}\s*$", output, flags=re.S)
    if m:
        return json.loads(m.group(0))
    start = output.rfind("\n{")
    if start == -1:
        start = output.find("{")
    else:
        start += 1
    end = output.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError(f"No JSON object found in TB output:\n{output[-1500:]}")
    return json.loads(output[start : end + 1])


def run_linux_config(
    num_harts: int,
    threads: int,
    max_cycles: int,
    jobs: int,
    kernel_img: Path,
    build_only: bool,
) -> dict[str, Any]:
    cfg_dir = BUILD_DIR / f"n{num_harts}"
    cfg_dir.mkdir(parents=True, exist_ok=True)

    _, dtb_path = build_dtb(num_harts, DEFAULT_BOOTARGS)
    dtb_info = verify_dtb_isa(dtb_path, expected_cpus=num_harts)
    sbi_elf = build_sbi_firmware(num_harts, cfg_dir / f"fursoy_s2_sbi_n{num_harts}.elf")

    soc_mdir, soc_lib, global_objs, soc_s, rebuilt = ensure_soc_lib(
        num_harts=num_harts,
        jobs=jobs,
        threads=threads,
        smp_coherence_en=1,
        log_path=cfg_dir / f"soc_build_n{num_harts}_t{threads}.log",
    )
    exe_path, link_s = link_verilator_tb(
        num_harts=num_harts,
        tb_cpp=TB_CPP,
        soc_mdir=soc_mdir,
        soc_lib=soc_lib,
        global_objs=global_objs,
        exe_path=cfg_dir / f"Vs25_linux_fpu_n{num_harts}_t{threads}",
        threads=threads,
    )
    print(
        f"[S2.5-M3b N={num_harts}] Ready: exe={exe_path.name} soc_rebuilt={rebuilt} "
        f"soc_s={soc_s:.1f} link_s={link_s:.1f} dtb_isa={dtb_info['riscv_isa']}",
        flush=True,
    )
    if build_only:
        return {
            "num_harts": num_harts,
            "verilator_threads": threads,
            "status": "built",
            "dtb": dtb_info,
            "sbi_sha256": sha256_file(sbi_elf),
            "binary": str(exe_path.relative_to(ROOT)),
        }

    console_log = cfg_dir / f"console_n{num_harts}.log"
    cmd = [
        str(exe_path),
        str(sbi_elf),
        str(kernel_img),
        str(dtb_path),
        str(max_cycles),
        str(console_log),
    ]
    print(f"[S2.5-M3b N={num_harts}] Launching: {' '.join(cmd)}", flush=True)
    started_at = utc_now_iso()
    t0 = time.monotonic()

    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
        bufsize=1,
    )
    assert proc.stdout is not None and proc.stderr is not None

    # Stream stderr progress lines live while reading stdout in a helper thread
    import threading

    stdout_chunks: list[str] = []

    def _read_stdout() -> None:
        assert proc.stdout is not None
        for ln in proc.stdout:
            stdout_chunks.append(ln)
            s = ln.rstrip("\n")
            if any(
                tok in s
                for tok in (
                    "Linux version",
                    "Brought up ",
                    "Run /init",
                    "[SMP_",
                    "[MEM_STRESS_",
                    "FURSOY_USERSPACE_",
                    "[S2_M5_LINUX_",
                    "Kernel panic",
                    "Oops:",
                    "unhandled signal",
                    "SIGILL",
                )
            ):
                print(f"[N={num_harts} UART] {s}", flush=True)

    th_out = threading.Thread(target=_read_stdout, daemon=True)
    th_out.start()

    peak_vmhwm_kib = 0
    for err_ln in proc.stderr:
        s = err_ln.rstrip("\n")
        if "[S2-M5 TB]" in s or "ERROR" in s or "WATCHDOG" in s:
            # Print every 1M cycles or non-periodic event to keep logs concise
            m_c = re.search(r"cyc=(\d+)", s)
            if not m_c or (int(m_c.group(1)) % 1000000 == 0):
                print(f"[N={num_harts} TB] {s}", flush=True)
        vm = read_proc_vmhwm_kib(proc.pid)
        if vm is not None and vm > peak_vmhwm_kib:
            peak_vmhwm_kib = vm

    th_out.join()
    rc = proc.wait()
    wall_s = time.monotonic() - t0
    finished_at = utc_now_iso()
    child_rss = int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    peak_rss_kib = peak_vmhwm_kib if peak_vmhwm_kib > 0 else child_rss
    host_mem = read_host_mem_kib()

    full_stdout = "".join(stdout_chunks)
    tb_json = extract_last_json(full_stdout)
    con_text = console_log.read_text(encoding="utf-8", errors="replace") if console_log.exists() else full_stdout

    # Check all 10 required markers (existing 8 S2-M5 markers + [SMP_ISA_PASS] + [SMP_FPU_PREEMPT_PASS])
    markers = {
        "brought_up_cpus": f"Brought up 1 node, {num_harts} CPUs" in con_text,
        "smp_cpuinfo_pass": f"[SMP_CPUINFO_PASS] online={num_harts}" in con_text,
        "smp_isa_pass": "[SMP_ISA_PASS]" in con_text,
        "smp_affinity_pass": "[SMP_AFFINITY_PASS]" in con_text,
        "smp_pthreads_pass": f"[SMP_PTHREADS_PASS] cpus={num_harts}" in con_text,
        "smp_fpu_preempt_pass": "[SMP_FPU_PREEMPT_PASS]" in con_text,
        "mem_stress_pass": "[MEM_STRESS_PASS]" in con_text,
        "smp_busybox_pass": "[SMP_BUSYBOX_PASS]" in con_text,
        "fursoy_userspace_pass": "FURSOY_USERSPACE_PASS" in con_text,
        "s2_m5_linux_all_pass": f"[S2_M5_LINUX_ALL_PASS] online={num_harts}" in con_text,
    }

    fatal_patterns = {
        "kernel_panic": bool(tb_json.get("seen_kernel_panic")) or ("Kernel panic" in con_text),
        "oops_or_bug": bool(tb_json.get("seen_oops")) or ("Oops:" in con_text) or ("Unable to handle kernel" in con_text),
        "rcu_stall": bool(tb_json.get("seen_rcu_stall")) or ("rcu_sched self-detected stall" in con_text),
        "sbi_trap": bool(tb_json.get("seen_sbi_trap")) or ("!SBI!" in con_text),
        "userspace_fail": bool(tb_json.get("seen_userspace_fail")) or ("FURSOY_USERSPACE_FAIL" in con_text) or ("[SMP_TEST_FAIL]" in con_text),
        "unhandled_signal": bool(re.search(r"unhandled signal|SIGILL|SIGSEGV|Illegal instruction|Segmentation fault", con_text)),
        "watchdog_triggered": bool(tb_json.get("watchdog_triggered")),
    }

    fpu_metrics: dict[str, Any] = {}
    m_fpu = re.search(
        r"\[SMP_FPU_PREEMPT_PASS\] threads=(\d+) cpus=(\d+) rounds=(\d+) migrations=(\d+) regs_checked=(\d+) frm_modes=(\d+)",
        con_text,
    )
    if m_fpu:
        fpu_metrics = {
            "threads": int(m_fpu.group(1)),
            "cpus": int(m_fpu.group(2)),
            "rounds": int(m_fpu.group(3)),
            "migrations": int(m_fpu.group(4)),
            "regs_checked": int(m_fpu.group(5)),
            "frm_modes": int(m_fpu.group(6)),
        }

    m_isa = re.search(r"\[SMP_ISA_PASS\]\s*(.+)", con_text)
    cpuinfo_isa = m_isa.group(1).strip() if m_isa else ""
    m_uname = re.search(r"(Linux .* 6\.6\.50 .*)", con_text)
    uname_line = m_uname.group(1).strip() if m_uname else ""

    cycles = int(tb_json.get("cycles", 0))
    per_hart_commits = [int(x) for x in tb_json.get("per_hart_commits", [])]
    per_hart_smode = [int(x) for x in tb_json.get("per_hart_smode_commits", [])]
    per_hart_umode = [int(x) for x in tb_json.get("per_hart_umode_commits", [])]
    total_commits = sum(per_hart_commits)
    agg_ipc = (total_commits / cycles) if cycles > 0 else 0.0
    cyc_per_s = (cycles / wall_s) if wall_s > 0 else 0.0

    all_markers_ok = all(markers.values())
    no_fatals = not any(fatal_patterns.values())
    all_harts_active = (
        len(per_hart_commits) == num_harts
        and all(c > 0 for c in per_hart_commits)
        and all(u > 0 for u in per_hart_umode)
    )
    fpu_metrics_ok = (
        bool(fpu_metrics)
        and fpu_metrics["threads"] == 2 * num_harts
        and fpu_metrics["cpus"] == num_harts
        and fpu_metrics["migrations"] == fpu_metrics["threads"] * fpu_metrics["rounds"]
        and fpu_metrics["frm_modes"] == 5
    )

    passed = (rc == 0) and tb_json.get("status") == "pass" and all_markers_ok and no_fatals and all_harts_active and fpu_metrics_ok

    res = {
        "num_harts": num_harts,
        "verilator_threads": threads,
        "status": "pass" if passed else "fail",
        "exit_code": rc,
        "started_at_utc": started_at,
        "finished_at_utc": finished_at,
        "wall_seconds": round(wall_s, 3),
        "cycles": cycles,
        "cycles_per_second": round(cyc_per_s, 2),
        "peak_rss_kib": peak_rss_kib,
        "host_mem_end_kib": host_mem,
        "total_commits": total_commits,
        "aggregate_ipc": round(agg_ipc, 4),
        "per_hart_commits": per_hart_commits,
        "per_hart_smode_commits": per_hart_smode,
        "per_hart_umode_commits": per_hart_umode,
        "uart_bytes": int(tb_json.get("uart_bytes", 0)),
        "dtb": dtb_info,
        "sbi_sha256": sha256_file(sbi_elf),
        "cpuinfo_isa": cpuinfo_isa,
        "uname": uname_line,
        "fpu_preempt_metrics": fpu_metrics,
        "markers": markers,
        "fatals": fatal_patterns,
        "console_log": str(console_log.relative_to(ROOT)),
    }
    print(
        f"[S2.5-M3b N={num_harts}] Finished: status={res['status']} cycles={cycles} "
        f"wall_s={wall_s:.1f} cyc/s={cyc_per_s:.1f} ipc={agg_ipc:.4f} "
        f"peak_rss_mib={peak_rss_kib / 1024.0:.1f} fpu={fpu_metrics}",
        flush=True,
    )
    return res


def merge_reports(paths: list[Path], out_report: Path) -> int:
    merged: dict[str, Any] = {}
    configs: dict[str, Any] = {}
    rtl_sha: str | None = None
    for p in paths:
        d = json.loads(p.read_text(encoding="utf-8"))
        cur_sha = d.get("rtl_sha256")
        if rtl_sha is None:
            rtl_sha = cur_sha
        elif cur_sha != rtl_sha:
            raise RuntimeError(f"RTL SHA mismatch across merged reports: {rtl_sha} vs {cur_sha}")
        if not merged:
            merged = {k: v for k, v in d.items() if k not in ("configs", "status", "generated_at_utc")}
        for k, v in d.get("configs", {}).items():
            configs[k] = v

    live_sha = compute_rtl_sha256()
    if rtl_sha != live_sha:
        raise RuntimeError(f"Merged report RTL SHA {rtl_sha} != workspace RTL SHA {live_sha}")

    ordered = {k: configs[k] for k in sorted(configs.keys())}
    all_ok = ("n2" in ordered and "n4" in ordered) and all(c.get("status") == "pass" for c in ordered.values())
    merged["generated_at_utc"] = utc_now_iso()
    merged["status"] = "pass" if all_ok else "fail"
    merged["configs"] = ordered
    out_report.parent.mkdir(parents=True, exist_ok=True)
    out_report.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    print(f"[S2.5-M3b] Merged {len(ordered)} configs into {out_report}: status={merged['status']}", flush=True)
    return 0 if all_ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Run S2.5-M3b Linux CONFIG_SMP=y + CONFIG_FPU=y validation.")
    parser.add_argument("--num-harts", choices=("2", "4", "all"), default="all")
    parser.add_argument("--threads", type=int, default=None)
    parser.add_argument("--max-cycles", type=int, default=200000000)
    parser.add_argument("--jobs", type=int, default=None)
    parser.add_argument("--rebuild-kernel", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--out-report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--merge-reports", nargs="+", type=Path, default=None)
    args = parser.parse_args()

    if args.merge_reports:
        return merge_reports(args.merge_reports, args.out_report)

    rtl_sha = compute_rtl_sha256()
    jobs = args.jobs if args.jobs is not None else get_build_jobs()

    kernel_img = ensure_smp_kernel(rebuild=args.rebuild_kernel)
    kcfg = verify_kernel_config()
    vmlinux_chk = verify_elf_no_rvc(LINUX_SMP_DIR / "vmlinux", "vmlinux")
    smp_bin_chk = verify_elf_no_rvc(S2_SMP_TEST_BIN, "s2_smp_test")
    sail_precheck = (
        json.loads(SAIL_PRECHECK_JSON.read_text(encoding="utf-8"))
        if SAIL_PRECHECK_JSON.exists()
        else None
    )

    harts_list = [2, 4] if args.num_harts == "all" else [int(args.num_harts)]
    configs: dict[str, Any] = {}
    for nh in harts_list:
        th = args.threads if args.threads is not None else DEFAULT_THREADS[nh]
        configs[f"n{nh}"] = run_linux_config(
            num_harts=nh,
            threads=th,
            max_cycles=args.max_cycles,
            jobs=jobs,
            kernel_img=kernel_img,
            build_only=args.build_only,
        )

    if args.build_only:
        print("[S2.5-M3b] Build-only complete (vmlinux & s2_smp_test 0 RVC, DTB rv64imafd verified).", flush=True)
        return 0

    all_ok = all(c.get("status") == "pass" for c in configs.values())
    report = {
        "milestone": "S2.5-M3b",
        "suite": "linux_6_6_50_smp_fpu_preempt",
        "generated_at_utc": utc_now_iso(),
        "rtl_sha256": rtl_sha,
        "kernel_version": "6.6.50",
        "kernel_image_sha256": sha256_file(kernel_img),
        "kernel_config_checks": kcfg,
        "rvc_checks": {
            "vmlinux": vmlinux_chk,
            "s2_smp_test": smp_bin_chk,
        },
        "sail_smode_fpu_precheck": sail_precheck,
        "status": "pass" if all_ok else "fail",
        "configs": configs,
    }
    args.out_report.parent.mkdir(parents=True, exist_ok=True)
    args.out_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"[S2.5-M3b] Wrote {args.out_report}: status={report['status']}", flush=True)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
