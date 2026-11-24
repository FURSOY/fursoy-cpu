#!/usr/bin/env python3
"""Fursoy Slice-2.5 Milestone S2.5-M3a Industry Benchmark Suite Runner.

Builds and executes four official unmodified industry benchmarks on final RTL:
  1. Official EEMBC CoreMark:
       - Single-core on fursoy_s1_soc (1-iter convergence check + 10-iter official
         run, exact CoreMark/MHz, IPC, and 8-bucket CPI with 0 conservation errors).
       - Multi-core SMP scaling on fursoy_s2_soc (N=1, 2, 4 concurrent contexts).
  2. Official Embench-IoT v2.0 (all 19 benchmarks, 0 exclusions):
       - Runs on fursoy_s1_soc with verify_benchmark() == 1, exact 8-bucket CPI
         (0 conservation errors), IPC, and official Embench-IoT Speed/MHz score.
  3. Official McCalpin STREAM (FP64 Copy/Scale/Add/Triad):
       - True multi-core OpenMP scaling on fursoy_s2_soc (N=1, 2, 4) with
         STREAM_ARRAY_SIZE=65536 (512 KiB/array, 1.5 MiB total = 6x 256 KiB L2),
         NTIMES=3, and McCalpin residual validation ("Solution Validates").
  4. Official Dhrystone 2.1:
       - Strict separate-TU compilation (dhry_1.o + dhry_2.o, no LTO), 2,000 runs
         on fursoy_s1_soc with exact output verification, DMIPS/MHz, and 8-bucket CPI.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import math
import os
import re
import resource
import shutil
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
    get_verilator_root,
    link_verilator_tb,
    run_cmd,
)

BUILD_DIR = ROOT / "build/benchmarks"
SRC_DIR = BUILD_DIR / "src"
ELF_DIR = BUILD_DIR / "elfs"
OBJ_DIR = BUILD_DIR / "objs"
BIN_DIR = BUILD_DIR / "bin"
S1_SOC_MDIR = BUILD_DIR / "s1_soc_lib"
DEFAULT_REPORT = ROOT / "results/s25-benchmarks.json"

BENCH_COMMON_DIR = ROOT / "software/benchmarks/common"
BENCH_INC_DIR = BENCH_COMMON_DIR / "include"
BENCH_LINK_LD = BENCH_COMMON_DIR / "bench_link.ld"
COREMARK_PORT_DIR = ROOT / "software/benchmarks/coremark"
EMBENCH_PORT_DIR = ROOT / "software/benchmarks/embench"

CPU_REF_MHZ = 500.0
DRAM_RD_LAT = 2
DRAM_WR_LAT = 1

UPSTREAM_REPOS = {
    "coremark": "https://github.com/eembc/coremark.git",
    "embench-iot": "https://github.com/embench/embench-iot.git",
    "STREAM": "https://github.com/jeffhammond/STREAM.git",
    "dhrystone": "https://github.com/Keith-S-Thompson/dhrystone.git",
}

DEFAULT_S2_THREADS = {1: 1, 2: 4, 4: 2}


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_gcc_info() -> dict[str, str]:
    rc1, v_linux = run_cmd(["riscv64-linux-gnu-gcc", "--version"], timeout_s=30)
    rc2, libgcc = run_cmd(
        [
            "riscv64-unknown-elf-gcc",
            "-march=rv64imafd_zba_zbb",
            "-mabi=lp64d",
            "-print-libgcc-file-name",
        ],
        timeout_s=30,
    )
    rc3, inc_dir = run_cmd(
        ["riscv64-linux-gnu-gcc", "-print-file-name=include"], timeout_s=30
    )
    if rc1 != 0 or rc2 != 0 or rc3 != 0:
        raise RuntimeError("Failed to query RISC-V GCC toolchain paths")
    return {
        "cc": "riscv64-linux-gnu-gcc",
        "cc_version": v_linux.splitlines()[0].strip(),
        "gcc_builtin_include": inc_dir.strip(),
        "libgcc_a": libgcc.strip(),
    }


def get_upstream_shas() -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    for name, url in UPSTREAM_REPOS.items():
        repo_dir = SRC_DIR / name
        if not repo_dir.exists():
            raise RuntimeError(f"Missing cloned upstream benchmark repo: {repo_dir}")
        rc, sha = run_cmd(["git", "-C", str(repo_dir), "rev-parse", "HEAD"], timeout_s=30)
        if rc != 0:
            raise RuntimeError(f"Failed to read git SHA for {repo_dir}")
        out[name] = {"url": url, "commit_sha": sha.strip()}
    return out


def base_cflags(tc: dict[str, str], opt: str = "-O3") -> list[str]:
    return [
        "-march=rv64imafd_zba_zbb",
        "-mabi=lp64d",
        "-mstrict-align",
        "-mcmodel=medany",
        "-ffreestanding",
        "-nostdinc",
        "-fno-pic",
        "-fno-pie",
        "-fno-stack-protector",
        "-fno-builtin",
        opt,
        f"-isystem{tc['gcc_builtin_include']}",
        f"-I{BENCH_INC_DIR}",
        f"-I{BENCH_COMMON_DIR}",
    ]


def verify_no_rvc(elf_path: Path) -> None:
    rc, hdr = run_cmd(["riscv64-unknown-elf-readelf", "-h", str(elf_path)], timeout_s=30)
    if rc != 0:
        raise RuntimeError(f"readelf failed on {elf_path}:\n{hdr}")
    for line in hdr.splitlines():
        if "Flags:" in line and "RVC" in line:
            raise RuntimeError(f"Forbidden RVC flag detected in {elf_path}: {line.strip()}")


def compile_tu(cc: str, flags: list[str], src: Path, obj: Path) -> None:
    obj.parent.mkdir(parents=True, exist_ok=True)
    cmd = [cc, *flags, "-c", str(src), "-o", str(obj)]
    rc, out = run_cmd(cmd, timeout_s=120)
    if rc != 0:
        raise RuntimeError(f"Compile failed ({src.name}):\n{' '.join(cmd)}\n{out}")


def link_elf(cc: str, tc: dict[str, str], objs: list[Path], elf: Path) -> None:
    elf.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        cc,
        "-march=rv64imafd_zba_zbb",
        "-mabi=lp64d",
        "-mcmodel=medany",
        "-nostdlib",
        "-static",
        "-no-pie",
        "-Wl,--build-id=none",
        f"-Wl,-T,{BENCH_LINK_LD}",
        *[str(o) for o in objs],
        tc["libgcc_a"],
        "-o",
        str(elf),
    ]
    rc, out = run_cmd(cmd, timeout_s=120)
    if rc != 0:
        raise RuntimeError(f"Link failed ({elf.name}):\n{' '.join(cmd)}\n{out}")
    verify_no_rvc(elf)


def ensure_s1_soc_bin(jobs: int) -> Path:
    """Build or reuse Vfursoy_s1_soc static lib and link Vs25_bench_s1."""
    rtl_sha = compute_rtl_sha256()
    meta_path = S1_SOC_MDIR / "s1_meta.json"
    lib_path = S1_SOC_MDIR / "Vfursoy_s1_soc__ALL.a"
    classes_mk = S1_SOC_MDIR / "Vfursoy_s1_soc_classes.mk"
    expected_meta = {"top": "fursoy_s1_soc", "rtl_sha256": rtl_sha}

    rebuilt = True
    if meta_path.exists() and lib_path.exists() and classes_mk.exists():
        try:
            if json.loads(meta_path.read_text(encoding="utf-8")) == expected_meta:
                rebuilt = False
        except (OSError, json.JSONDecodeError):
            rebuilt = True

    if rebuilt:
        shutil.rmtree(S1_SOC_MDIR, ignore_errors=True)
        S1_SOC_MDIR.mkdir(parents=True, exist_ok=True)
        v_cmd = [
            "verilator",
            "--cc",
            "--build",
            "-O3",
            "-j",
            str(jobs),
            "--assert",
            "-Wall",
            "-Wno-DECLFILENAME",
            "-Wno-fatal",
            "-Irtl/core",
            "-Irtl/platform",
            "--top-module",
            "fursoy_s1_soc",
            "-Mdir",
            str(S1_SOC_MDIR),
            "-CFLAGS",
            "-std=c++17 -O3",
            str(ROOT / "rtl/platform/fursoy_s1_soc.sv"),
        ]
        print(f"[S2.5-M3a] Building Vfursoy_s1_soc__ALL.a (jobs={jobs})...", flush=True)
        rc, out = run_cmd(v_cmd, timeout_s=3600)
        (BUILD_DIR / "s1_soc_build.log").write_text(out, encoding="utf-8")
        if rc != 0 or not lib_path.exists():
            raise RuntimeError(f"Vfursoy_s1_soc build failed:\n{out[-2500:]}")
        # Build global runtime objs
        mk_text = classes_mk.read_text(encoding="utf-8")
        g_objs: list[str] = []
        in_g = False
        for line in mk_text.splitlines():
            s = line.strip()
            if s.startswith("VM_GLOBAL_FAST") or s.startswith("VM_GLOBAL_SLOW"):
                in_g = s.endswith("\\")
                continue
            if in_g:
                tok = s.rstrip("\\").strip()
                if tok:
                    g_objs.append(f"{tok}.o")
                if not s.endswith("\\"):
                    in_g = False
        g_objs = g_objs or ["verilated.o", "verilated_threads.o"]
        rc, mk_out = run_cmd(
            ["make", "-C", str(S1_SOC_MDIR), "-f", "Vfursoy_s1_soc.mk", "-j", str(jobs), *g_objs],
            timeout_s=600,
        )
        if rc != 0:
            raise RuntimeError(f"Vfursoy_s1_soc runtime objs failed:\n{mk_out[-2000:]}")
        meta_path.write_text(json.dumps(expected_meta, indent=2) + "\n", encoding="utf-8")

    mk_text = classes_mk.read_text(encoding="utf-8")
    g_objs = []
    in_g = False
    for line in mk_text.splitlines():
        s = line.strip()
        if s.startswith("VM_GLOBAL_FAST") or s.startswith("VM_GLOBAL_SLOW"):
            in_g = s.endswith("\\")
            continue
        if in_g:
            tok = s.rstrip("\\").strip()
            if tok:
                g_objs.append(f"{tok}.o")
            if not s.endswith("\\"):
                in_g = False
    g_objs = g_objs or ["verilated.o", "verilated_threads.o"]

    BIN_DIR.mkdir(parents=True, exist_ok=True)
    exe = BIN_DIR / "Vs25_bench_s1"
    vroot = get_verilator_root()
    cmd = [
        "g++",
        "-std=c++17",
        "-O3",
        "-faligned-new",
        "-DVM_COVERAGE=0",
        "-DVM_SC=0",
        "-DVM_TRACE=0",
        "-DVM_TRACE_FST=0",
        "-DVM_TRACE_VCD=0",
        f"-I{S1_SOC_MDIR}",
        f"-I{vroot / 'include'}",
        f"-I{vroot / 'include' / 'vltstd'}",
        str(ROOT / "verification/s25_bench_s1_tb.cpp"),
        str(lib_path),
        *[str(S1_SOC_MDIR / o) for o in g_objs],
        "-pthread",
        "-lpthread",
        "-latomic",
        "-o",
        str(exe),
    ]
    rc, out = run_cmd(cmd, timeout_s=300)
    if rc != 0:
        raise RuntimeError(f"Link Vs25_bench_s1 failed:\n{out[-2000:]}")
    return exe


def ensure_s2_soc_bin(num_harts: int, threads: int, jobs: int) -> Path:
    soc_mdir, soc_lib, global_objs, _, _ = ensure_soc_lib(
        num_harts=num_harts,
        jobs=jobs,
        threads=threads,
        smp_coherence_en=1,
        log_path=BUILD_DIR / f"s2_soc_build_n{num_harts}_t{threads}.log",
    )
    exe = BIN_DIR / f"Vs25_bench_s2_n{num_harts}_t{threads}"
    link_verilator_tb(
        num_harts=num_harts,
        tb_cpp=ROOT / "verification/s25_bench_s2_tb.cpp",
        soc_mdir=soc_mdir,
        soc_lib=soc_lib,
        global_objs=global_objs,
        exe_path=exe,
        threads=threads,
        extra_include_dirs=[ROOT / "verification"],
    )
    return exe


def extract_json(stdout: str) -> dict[str, Any]:
    start = stdout.rfind("\n{")
    if start == -1:
        start = stdout.find("{")
    else:
        start += 1
    end = stdout.rfind("}")
    if start == -1 or end == -1 or end <= start:
        raise ValueError(f"Could not parse JSON from TB output:\n{stdout[-1500:]}")
    return json.loads(stdout[start : end + 1])


def run_tb(exe: Path, elf: Path, max_cycles: int, stream_stderr: bool = False) -> dict[str, Any]:
    cmd = [str(exe), str(elf), str(max_cycles), str(DRAM_RD_LAT), str(DRAM_WR_LAT)]
    t0 = time.monotonic()
    if stream_stderr:
        proc = subprocess.Popen(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            bufsize=1,
        )
        assert proc.stderr is not None and proc.stdout is not None
        stderr_lines: list[str] = []
        # Read stderr in real time while collecting stdout at end (stdout is only small final JSON)
        for line in proc.stderr:
            stderr_lines.append(line.rstrip("\n"))
            if "[UART" in line or "[PROGRESS" in line or "ERROR" in line:
                print(line.rstrip("\n"), flush=True)
        stdout_text = proc.stdout.read()
        rc = proc.wait()
        wall_s = time.monotonic() - t0
    else:
        res = subprocess.run(
            cmd,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            timeout=14400,
        )
        rc = res.returncode
        stdout_text = res.stdout
        wall_s = time.monotonic() - t0
        if rc != 0 and res.stderr:
            print(res.stderr[-1500:], flush=True)
    data = extract_json(stdout_text)
    data["runner_rc"] = rc
    data["runner_wall_seconds"] = round(wall_s, 3)
    return data


# ==============================================================================
# 1. CoreMark Compilation & Verification
# ==============================================================================
def build_coremark_elf(
    tc: dict[str, str],
    tag: str,
    iters: int,
    multithread: int,
) -> tuple[Path, list[str]]:
    cm_src = SRC_DIR / "coremark"
    odir = OBJ_DIR / f"coremark_{tag}"
    shutil.rmtree(odir, ignore_errors=True)
    odir.mkdir(parents=True, exist_ok=True)

    mem_method = "MEM_MALLOC" if multithread > 1 else "MEM_STACK"
    flags = [
        *base_cflags(tc, opt="-O3"),
        "-fno-common",
        "-funroll-loops",
        f"-I{COREMARK_PORT_DIR}",
        f"-I{cm_src}",
        "-DPERFORMANCE_RUN=1",
        f"-DITERATIONS={iters}",
        f"-DMULTITHREAD={multithread}",
        f"-DMEM_METHOD={mem_method}",
        f'-DCOMPILER_VERSION="{tc["cc_version"]}"',
        '-DCOMPILER_FLAGS="-march=rv64imafd_zba_zbb -mabi=lp64d -mstrict-align -O3 -funroll-loops"',
    ]
    tus = [
        BENCH_COMMON_DIR / "crt0.S",
        BENCH_COMMON_DIR / "bench_libc.c",
        COREMARK_PORT_DIR / "core_portme.c",
        cm_src / "core_list_join.c",
        cm_src / "core_main.c",
        cm_src / "core_matrix.c",
        cm_src / "core_state.c",
        cm_src / "core_util.c",
    ]
    objs: list[Path] = []
    for src in tus:
        obj = odir / f"{src.stem}.o"
        compile_tu(tc["cc"], flags, src, obj)
        objs.append(obj)
    elf = ELF_DIR / f"coremark_{tag}.elf"
    link_elf(tc["cc"], tc, objs, elf)
    return elf, flags


def parse_and_verify_coremark(tb_out: dict[str, Any], expected_contexts: int, expected_iters: int) -> dict[str, Any]:
    lines = tb_out.get("uart_lines", [])
    seedcrc = None
    crclist: dict[int, str] = {}
    crcmatrix: dict[int, str] = {}
    crcstate: dict[int, str] = {}
    crcfinal: dict[int, str] = {}
    crc_errors: list[str] = []
    cm_cycles = None
    cm_instret = None

    for ln in lines:
        m = re.match(r"\[COREMARK_CYCLES\] contexts=(\d+) iters=(\d+) cycles=(\d+) instret=(\d+)", ln)
        if m:
            cm_cycles = int(m.group(3))
            cm_instret = int(m.group(4))
        m = re.match(r"seedcrc\s*:\s*(0x[0-9a-fA-F]+)", ln)
        if m:
            seedcrc = m.group(1).lower()
        m = re.match(r"\[(\d+)\]crclist\s*:\s*(0x[0-9a-fA-F]+)", ln)
        if m:
            crclist[int(m.group(1))] = m.group(2).lower()
        m = re.match(r"\[(\d+)\]crcmatrix\s*:\s*(0x[0-9a-fA-F]+)", ln)
        if m:
            crcmatrix[int(m.group(1))] = m.group(2).lower()
        m = re.match(r"\[(\d+)\]crcstate\s*:\s*(0x[0-9a-fA-F]+)", ln)
        if m:
            crcstate[int(m.group(1))] = m.group(2).lower()
        m = re.match(r"\[(\d+)\]crcfinal\s*:\s*(0x[0-9a-fA-F]+)", ln)
        if m:
            crcfinal[int(m.group(1))] = m.group(2).lower()
        if "ERROR!" in ln and "Must execute for at least 10 secs" not in ln:
            crc_errors.append(ln)

    # Known 2K performance CRCs from official EEMBC core_main.c (known_id == 3)
    expected_seed = "0xe9f5"
    expected_list = "0xe714"
    expected_matrix = "0x1fd7"
    expected_state = "0x8e3a"

    crcs_ok = (
        seedcrc == expected_seed
        and len(crclist) == expected_contexts
        and len(crcmatrix) == expected_contexts
        and len(crcstate) == expected_contexts
        and len(crcfinal) == expected_contexts
        and all(v == expected_list for v in crclist.values())
        and all(v == expected_matrix for v in crcmatrix.values())
        and all(v == expected_state for v in crcstate.values())
        and len(set(crcfinal.values())) == 1
        and len(crc_errors) == 0
    )

    if tb_out.get("status") != "pass" or not crcs_ok or not cm_cycles:
        raise RuntimeError(
            f"CoreMark validation FAILED (contexts={expected_contexts}, iters={expected_iters}): "
            f"tb_status={tb_out.get('status')}, seedcrc={seedcrc}, crc_errors={crc_errors}, "
            f"crclist={crclist}, crcmatrix={crcmatrix}, crcstate={crcstate}, crcfinal={crcfinal}"
        )

    total_iters = expected_contexts * expected_iters
    cm_per_mhz = (total_iters * 1e6) / cm_cycles
    cm_500mhz = cm_per_mhz * CPU_REF_MHZ
    cycles_per_iter = cm_cycles / expected_iters
    res: dict[str, Any] = {
        "status": "pass",
        "soc": tb_out["soc"],
        "contexts": expected_contexts,
        "iterations_per_context": expected_iters,
        "total_iterations": total_iters,
        "cycles": cm_cycles,
        "cycles_per_iter": round(cycles_per_iter, 2),
        "coremark_per_mhz": round(cm_per_mhz, 4),
        "coremark_at_500mhz": round(cm_500mhz, 2),
        "seedcrc": seedcrc,
        "crclist": expected_list,
        "crcmatrix": expected_matrix,
        "crcstate": expected_state,
        "crcfinal": next(iter(crcfinal.values())),
        "crc_validated": True,
        "wall_seconds": tb_out["wall_seconds"],
        "total_sim_cycles": tb_out["total_cycles"],
    }
    if tb_out["soc"] == "fursoy_s1_soc":
        res["instret"] = cm_instret
        res["ipc"] = round(cm_instret / cm_cycles, 4)
        res["cpi_checks"] = tb_out["cpi_checks"]
        res["cpi_conservation_errors"] = tb_out["cpi_conservation_errors"]
        res["cpi_breakdown"] = tb_out["cpi_breakdown"]
        res["window_dram_reads"] = tb_out["window_dram_reads"]
        res["window_dram_writes"] = tb_out["window_dram_writes"]
    else:
        res["per_hart_commits"] = tb_out["per_hart_commits"]
        res["total_commits"] = tb_out["total_commits"]
        res["aggregate_ipc"] = round(tb_out["total_commits"] / tb_out["total_cycles"], 4)
        res["dram_reads"] = tb_out["dram_reads"]
        res["dram_writes"] = tb_out["dram_writes"]
    return res


# ==============================================================================
# 2. Dhrystone 2.1 Compilation & Verification (Strict Multi-TU, NO LTO)
# ==============================================================================
def build_dhrystone_elf(tc: dict[str, str], runs: int) -> tuple[Path, list[str]]:
    dh_src = SRC_DIR / "dhrystone/v2.1"
    odir = OBJ_DIR / f"dhrystone_{runs}"
    shutil.rmtree(odir, ignore_errors=True)
    odir.mkdir(parents=True, exist_ok=True)

    flags = [
        *base_cflags(tc, opt="-O2"),
        "-Wno-implicit-int",
        "-Wno-implicit-function-declaration",
        "-Wno-return-type",
        "-Wno-old-style-definition",
        "-Wno-pointer-to-int-cast",
        "-fno-inline-functions",
        f"-I{dh_src}",
        "-DMSC_CLOCK",
        "-DHZ=500000000",
        f"-DDHRY_RUNS={runs}",
    ]
    tus = [
        BENCH_COMMON_DIR / "crt0.S",
        BENCH_COMMON_DIR / "bench_libc.c",
        dh_src / "dhry_1.c",
        dh_src / "dhry_2.c",
    ]
    objs: list[Path] = []
    for src in tus:
        obj = odir / f"{src.stem}.o"
        compile_tu(tc["cc"], flags, src, obj)
        objs.append(obj)
    elf = ELF_DIR / f"dhrystone_{runs}.elf"
    link_elf(tc["cc"], tc, objs, elf)
    return elf, flags


def parse_and_verify_dhrystone(tb_out: dict[str, Any], expected_runs: int) -> dict[str, Any]:
    lines = tb_out.get("uart_lines", [])
    text = "\n".join(lines)
    m = re.search(r"\[DHRY_RESULT\] runs=(\d+) cycles=(\d+) instret=(\d+)", text)
    if not m:
        raise RuntimeError(f"Missing [DHRY_RESULT] line in Dhrystone output:\n{text[-1500:]}")
    runs = int(m.group(1))
    cycles = int(m.group(2))
    instret = int(m.group(3))

    expected_checks = [
        ("Int_Glob", r"Int_Glob:\s+5\b"),
        ("Bool_Glob", r"Bool_Glob:\s+1\b"),
        ("Ch_1_Glob", r"Ch_1_Glob:\s+A\b"),
        ("Ch_2_Glob", r"Ch_2_Glob:\s+B\b"),
        ("Arr_1_Glob[8]", r"Arr_1_Glob\[8\]:\s+7\b"),
        ("Arr_2_Glob[8][7]", rf"Arr_2_Glob\[8\]\[7\]:\s+{expected_runs + 10}\b"),
        ("Ptr_Glob.Int_Comp", r"Int_Comp:\s+17\b"),
        ("Next_Ptr_Glob.Int_Comp", r"Int_Comp:\s+18\b"),
        ("Int_1_Loc", r"Int_1_Loc:\s+5\b"),
        ("Int_2_Loc", r"Int_2_Loc:\s+13\b"),
        ("Int_3_Loc", r"Int_3_Loc:\s+7\b"),
        ("Enum_Loc", r"Enum_Loc:\s+1\b"),
        ("Str_1_Loc", r"Str_1_Loc:\s+DHRYSTONE PROGRAM, 1'ST STRING"),
        ("Str_2_Loc", r"Str_2_Loc:\s+DHRYSTONE PROGRAM, 2'ND STRING"),
    ]
    failed = [name for name, pat in expected_checks if not re.search(pat, text)]
    if tb_out.get("status") != "pass" or runs != expected_runs or failed:
        raise RuntimeError(
            f"Dhrystone 2.1 validation FAILED: status={tb_out.get('status')}, runs={runs}, failed_checks={failed}"
        )

    dhry_per_sec_per_mhz = (runs * 1e6) / cycles
    dmips_per_mhz = dhry_per_sec_per_mhz / 1757.0
    dmips_500mhz = dmips_per_mhz * CPU_REF_MHZ
    return {
        "status": "pass",
        "soc": tb_out["soc"],
        "runs": runs,
        "cycles": cycles,
        "instret": instret,
        "cycles_per_run": round(cycles / runs, 2),
        "ipc": round(instret / cycles, 4),
        "dhrystones_per_sec_at_500mhz": round(dhry_per_sec_per_mhz * CPU_REF_MHZ, 1),
        "dmips_per_mhz": round(dmips_per_mhz, 4),
        "dmips_at_500mhz": round(dmips_500mhz, 2),
        "output_checks_passed": len(expected_checks),
        "cpi_checks": tb_out["cpi_checks"],
        "cpi_conservation_errors": tb_out["cpi_conservation_errors"],
        "cpi_breakdown": tb_out["cpi_breakdown"],
        "wall_seconds": tb_out["wall_seconds"],
    }


# ==============================================================================
# 3. Embench-IoT (All 19 Official Benchmarks, 0 Exclusions)
# ==============================================================================
def discover_embench_benchmarks() -> list[str]:
    emb_src = SRC_DIR / "embench-iot/src"
    return sorted(p.name for p in emb_src.iterdir() if p.is_dir())


def build_embench_elf(tc: dict[str, str], bench: str, gsf: int = 1, warmup_heat: int = 1) -> tuple[Path, list[str]]:
    emb_root = SRC_DIR / "embench-iot"
    bench_dir = emb_root / "src" / bench
    odir = OBJ_DIR / f"embench_{bench}"
    shutil.rmtree(odir, ignore_errors=True)
    odir.mkdir(parents=True, exist_ok=True)

    flags = [
        *base_cflags(tc, opt="-O2"),
        f"-I{EMBENCH_PORT_DIR}",
        f"-I{emb_root / 'support'}",
        f"-I{bench_dir}",
        "-DHAVE_BOARDSUPPORT_H",
        f"-DCPU_MHZ=1",
        f"-DGLOBAL_SCALE_FACTOR={gsf}",
        f"-DWARMUP_HEAT={warmup_heat}",
    ]
    tus = [
        BENCH_COMMON_DIR / "crt0.S",
        BENCH_COMMON_DIR / "bench_libc.c",
        EMBENCH_PORT_DIR / "boardsupport.c",
        emb_root / "support/main.c",
        emb_root / "support/beebsc.c",
        *sorted(bench_dir.glob("*.c")),
    ]
    objs: list[Path] = []
    for idx, src in enumerate(tus):
        obj = odir / f"{idx:02d}_{src.stem}.o"
        compile_tu(tc["cc"], flags, src, obj)
        objs.append(obj)
    elf = ELF_DIR / f"embench_{bench}.elf"
    link_elf(tc["cc"], tc, objs, elf)
    return elf, flags


def run_single_embench(
    s1_exe: Path,
    elf: Path,
    bench: str,
    baseline_ms: float,
    gsf: int,
    max_cycles: int,
) -> tuple[str, dict[str, Any]]:
    tb_out = run_tb(s1_exe, elf, max_cycles=max_cycles, stream_stderr=False)
    lines = tb_out.get("uart_lines", [])
    text = "\n".join(lines)
    m = re.search(r"\[EMBENCH_RESULT\] gsf=(\d+) cycles=(\d+) instret=(\d+)", text)
    if tb_out.get("status") != "pass" or tb_out.get("exit_rc") != 0 or not m:
        raise RuntimeError(
            f"Embench-IoT benchmark '{bench}' FAILED: status={tb_out.get('status')}, "
            f"exit_rc={tb_out.get('exit_rc')}, seen_trap={tb_out.get('seen_trap')}, "
            f"cpi_errs={tb_out.get('cpi_conservation_errors')}, uart_tail={lines[-6:]}"
        )
    cycles = int(m.group(2))
    instret = int(m.group(3))
    ipc = instret / cycles
    # Official Embench-IoT v2.0 Speed/MHz relative to Cortex-M4 (baseline_ms * 1000 * gsf / cycles)
    speed_per_mhz = (baseline_ms * 1000.0 * gsf) / cycles
    speed_500mhz = speed_per_mhz * CPU_REF_MHZ
    entry = {
        "status": "pass",
        "verify_benchmark": 1,
        "gsf": gsf,
        "cycles": cycles,
        "instret": instret,
        "ipc": round(ipc, 4),
        "baseline_cortex_m4_16mhz_ms": baseline_ms,
        "speed_per_mhz_vs_m4": round(speed_per_mhz, 4),
        "speed_at_500mhz_vs_1mhz_m4": round(speed_500mhz, 2),
        "cpi_checks": tb_out["cpi_checks"],
        "cpi_conservation_errors": tb_out["cpi_conservation_errors"],
        "cpi_breakdown": tb_out["cpi_breakdown"],
        "window_dram_reads": tb_out["window_dram_reads"],
        "window_dram_writes": tb_out["window_dram_writes"],
        "wall_seconds": tb_out["wall_seconds"],
    }
    return bench, entry


# ==============================================================================
# 4. McCalpin FP64 STREAM (N=1, 2, 4 on fursoy_s2_soc via -fopenmp)
# ==============================================================================
def build_stream_elf(
    tc: dict[str, str],
    num_harts: int,
    array_size: int,
    offset: int,
    ntimes: int,
) -> tuple[Path, list[str]]:
    st_src = SRC_DIR / "STREAM/stream.c"
    odir = OBJ_DIR / f"stream_n{num_harts}"
    shutil.rmtree(odir, ignore_errors=True)
    odir.mkdir(parents=True, exist_ok=True)

    common_flags = [
        *base_cflags(tc, opt="-O3"),
        f"-DNUM_HARTS={num_harts}",
    ]
    stream_flags = [
        *common_flags,
        "-fopenmp",
        f"-DSTREAM_ARRAY_SIZE={array_size}",
        f"-DOFFSET={offset}",
        f"-DNTIMES={ntimes}",
    ]
    objs: list[Path] = []
    for src, fl in [
        (BENCH_COMMON_DIR / "crt0.S", common_flags),
        (BENCH_COMMON_DIR / "bench_libc.c", common_flags),
        (BENCH_COMMON_DIR / "gomp_shim.c", common_flags),
        (st_src, stream_flags),
    ]:
        obj = odir / f"{src.stem}.o"
        compile_tu(tc["cc"], fl, src, obj)
        objs.append(obj)
    elf = ELF_DIR / f"stream_n{num_harts}_sz{array_size}.elf"
    link_elf(tc["cc"], tc, objs, elf)
    return elf, stream_flags


def parse_and_verify_stream(
    tb_out: dict[str, Any],
    num_harts: int,
    array_size: int,
    offset: int,
    ntimes: int,
) -> dict[str, Any]:
    lines = tb_out.get("uart_lines", [])
    text = "\n".join(lines)
    validated = "Solution Validates: avg error less than" in text
    m_thr = re.search(r"Number of Threads counted = (\d+)", text)
    threads_counted = int(m_thr.group(1)) if m_thr else 0

    kernels: dict[str, dict[str, float]] = {}
    for kname in ("Copy", "Scale", "Add", "Triad"):
        mk = re.search(
            rf"{kname}:\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)", text
        )
        if mk:
            best_mbs = float(mk.group(1))
            kernels[kname] = {
                "best_rate_mb_s_at_500mhz": best_mbs,
                "best_bytes_per_cycle": round(best_mbs / CPU_REF_MHZ, 4),
                "avg_time_s": float(mk.group(2)),
                "min_time_s": float(mk.group(3)),
                "max_time_s": float(mk.group(4)),
            }

    if tb_out.get("status") != "pass" or not validated or threads_counted != num_harts or len(kernels) != 4:
        raise RuntimeError(
            f"STREAM N={num_harts} validation FAILED: status={tb_out.get('status')}, "
            f"validated={validated}, threads_counted={threads_counted}, kernels={list(kernels.keys())}"
        )

    total_bytes = 3 * array_size * 8
    return {
        "status": "pass",
        "soc": tb_out["soc"],
        "num_harts": num_harts,
        "threads_counted": threads_counted,
        "stream_array_size": array_size,
        "offset": offset,
        "ntimes": ntimes,
        "bytes_per_array": array_size * 8,
        "total_footprint_bytes": total_bytes,
        "total_footprint_mib": round(total_bytes / (1024.0 * 1024.0), 3),
        "l2_overflow_ratio": round(total_bytes / (256.0 * 1024.0), 2),
        "solution_validates": True,
        "kernels": kernels,
        "total_cycles": tb_out["total_cycles"],
        "total_commits": tb_out["total_commits"],
        "per_hart_commits": tb_out["per_hart_commits"],
        "aggregate_ipc": round(tb_out["total_commits"] / tb_out["total_cycles"], 4),
        "dram_reads": tb_out["dram_reads"],
        "dram_writes": tb_out["dram_writes"],
        "wall_seconds": tb_out["wall_seconds"],
    }


def geomean(vals: list[float]) -> float:
    return math.exp(sum(math.log(v) for v in vals) / len(vals))


def merge_benchmark_reports(paths: list[Path], out_report: Path) -> int:
    merged: dict[str, Any] = {}
    suites: dict[str, Any] = {}
    peak_rss = 0
    rtl_sha: str | None = None
    for p in paths:
        d = json.loads(p.read_text(encoding="utf-8"))
        cur_sha = d.get("rtl_sha256")
        if rtl_sha is None:
            rtl_sha = cur_sha
        elif cur_sha != rtl_sha:
            raise RuntimeError(f"RTL SHA mismatch across merged reports: {rtl_sha} vs {cur_sha} ({p})")
        if not merged:
            merged = {k: v for k, v in d.items() if k not in ("suites", "status", "peak_rss_kib", "generated_at_utc")}
        peak_rss = max(peak_rss, int(d.get("peak_rss_kib", 0)))
        for sk, sv in d.get("suites", {}).items():
            suites[sk] = sv

    live_sha = compute_rtl_sha256()
    if rtl_sha != live_sha:
        raise RuntimeError(f"Merged report RTL SHA {rtl_sha} != workspace RTL SHA {live_sha}")

    ordered_suites = {k: suites[k] for k in ("coremark", "embench_iot", "stream_fp64", "dhrystone_2_1") if k in suites}
    for k, v in suites.items():
        if k not in ordered_suites:
            ordered_suites[k] = v

    all_ok = len(ordered_suites) == 4 and all(v.get("status") == "pass" for v in ordered_suites.values())
    merged["generated_at_utc"] = utc_now_iso()
    merged["status"] = "pass" if all_ok else "fail"
    merged["peak_rss_kib"] = peak_rss
    merged["suites"] = ordered_suites

    out_report.parent.mkdir(parents=True, exist_ok=True)
    out_report.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    print(f"[S2.5-M3a] Merged {len(ordered_suites)} suites into {out_report}: status={merged['status']}", flush=True)
    return 0 if all_ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Run S2.5-M3a official industry benchmarks.")
    parser.add_argument(
        "--suites",
        nargs="+",
        choices=("coremark", "dhrystone", "embench", "stream", "all"),
        default=["all"],
    )
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--prebuild-only", action="store_true")
    parser.add_argument("--coremark-iters", type=int, default=10)
    parser.add_argument("--dhry-runs", type=int, default=2000)
    parser.add_argument("--embench-gsf", type=int, default=1)
    parser.add_argument("--embench-workers", type=int, default=6)
    parser.add_argument("--stream-array-size", type=int, default=65536)
    parser.add_argument("--stream-offset", type=int, default=8)
    parser.add_argument("--stream-ntimes", type=int, default=3)
    parser.add_argument("--jobs", type=int, default=None)
    parser.add_argument("--merge-reports", nargs="+", type=Path, default=None)
    parser.add_argument("--out-report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    if args.merge_reports:
        return merge_benchmark_reports(args.merge_reports, args.out_report)

    suites = (
        {"coremark", "dhrystone", "embench", "stream"}
        if "all" in args.suites
        else set(args.suites)
    )
    jobs = args.jobs if args.jobs is not None else get_build_jobs()
    tc = get_gcc_info()
    upstream = get_upstream_shas()
    rtl_sha = compute_rtl_sha256()

    print(f"[S2.5-M3a] RTL SHA-256: {rtl_sha}", flush=True)
    print(f"[S2.5-M3a] Toolchain: {tc['cc_version']} | libgcc: {tc['libgcc_a']}", flush=True)

    # 1. Compile all requested benchmark ELFs first (fast fail-fast + RVC check)
    cm_elfs: dict[str, tuple[Path, list[str]]] = {}
    if "coremark" in suites:
        print("[S2.5-M3a] Compiling CoreMark ELFs (S1 1-iter, S1 10-iter, S2 N=1/2/4)...", flush=True)
        cm_elfs["s1_1iter"] = build_coremark_elf(tc, "s1_i1", iters=1, multithread=1)
        cm_elfs["s1_main"] = build_coremark_elf(tc, f"s1_i{args.coremark_iters}", iters=args.coremark_iters, multithread=1)
        for nh in (1, 2, 4):
            cm_elfs[f"s2_n{nh}"] = build_coremark_elf(tc, f"s2_n{nh}_i{args.coremark_iters}", iters=args.coremark_iters, multithread=nh)

    dhry_elf: tuple[Path, list[str]] | None = None
    if "dhrystone" in suites:
        print(f"[S2.5-M3a] Compiling Dhrystone 2.1 ELF (runs={args.dhry_runs}, strict multi-TU)...", flush=True)
        dhry_elf = build_dhrystone_elf(tc, runs=args.dhry_runs)

    emb_benches: list[str] = []
    emb_elfs: dict[str, Path] = {}
    emb_flags_sample: list[str] = []
    if "embench" in suites:
        emb_benches = discover_embench_benchmarks()
        print(f"[S2.5-M3a] Compiling all {len(emb_benches)} Embench-IoT ELFs (gsf={args.embench_gsf})...", flush=True)
        for b in emb_benches:
            elf, fl = build_embench_elf(tc, b, gsf=args.embench_gsf, warmup_heat=1)
            emb_elfs[b] = elf
            emb_flags_sample = fl

    stream_elfs: dict[int, tuple[Path, list[str]]] = {}
    if "stream" in suites:
        print(f"[S2.5-M3a] Compiling McCalpin FP64 STREAM ELFs (N=1/2/4, size={args.stream_array_size}, ntimes={args.stream_ntimes})...", flush=True)
        for nh in (1, 2, 4):
            stream_elfs[nh] = build_stream_elf(
                tc,
                num_harts=nh,
                array_size=args.stream_array_size,
                offset=args.stream_offset,
                ntimes=args.stream_ntimes,
            )

    print("[S2.5-M3a] All requested ELFs compiled cleanly with 0 RVC instructions.", flush=True)
    if args.compile_only:
        return 0

    # 2. Build Verilator simulator binaries sequentially (never compete for RAM)
    s1_exe: Path | None = None
    s2_exes: dict[int, Path] = {}
    if suites & {"coremark", "dhrystone", "embench"}:
        s1_exe = ensure_s1_soc_bin(jobs=jobs)
        print(f"[S2.5-M3a] Ready S1 benchmark simulator: {s1_exe.relative_to(ROOT)}", flush=True)
    if suites & {"coremark", "stream"}:
        for nh in (1, 2, 4):
            th = DEFAULT_S2_THREADS[nh]
            s2_exes[nh] = ensure_s2_soc_bin(num_harts=nh, threads=th, jobs=jobs)
            print(f"[S2.5-M3a] Ready S2 benchmark simulator (N={nh}, T={th}): {s2_exes[nh].relative_to(ROOT)}", flush=True)

    if args.prebuild_only:
        return 0

    # Load existing report if running a subset so we can incrementally merge
    report: dict[str, Any] = {}
    if args.out_report.exists() and suites != {"coremark", "dhrystone", "embench", "stream"}:
        try:
            report = json.loads(args.out_report.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            report = {}

    report.update(
        {
            "milestone": "S2.5-M3a",
            "generated_at_utc": utc_now_iso(),
            "rtl_sha256": rtl_sha,
            "reference_freq_mhz": CPU_REF_MHZ,
            "dram_model": {
                "size_mib": 256,
                "bus_width_bits": 512,
                "read_latency_cycles": DRAM_RD_LAT,
                "write_latency_cycles": DRAM_WR_LAT,
                "note": "Matches Slice-2 Linux boot TB (s2_m5_linux_tb.cpp) DRAM read/write latency; L2=256 KiB inclusive on fursoy_s2_soc.",
            },
            "toolchain": {
                "cc": tc["cc"],
                "cc_version": tc["cc_version"],
                "libgcc_a": tc["libgcc_a"],
                "isa_march": "rv64imafd_zba_zbb",
                "abi": "lp64d",
                "strict_align": True,
                "strict_align_reason": "Zicclsm hardware misaligned load/store is not implemented in Slice-2 RTL.",
                "lto_enabled": False,
                "rvc_verified_absent": True,
            },
            "upstream_sources": upstream,
        }
    )
    report.setdefault("suites", {})

    # 3. Run Dhrystone 2.1 (fast ~2 min)
    if "dhrystone" in suites:
        assert s1_exe is not None and dhry_elf is not None
        print(f"\n[S2.5-M3a] === Running Dhrystone 2.1 ({args.dhry_runs} runs) on fursoy_s1_soc ===", flush=True)
        tb_out = run_tb(s1_exe, dhry_elf[0], max_cycles=20000000)
        dh_res = parse_and_verify_dhrystone(tb_out, expected_runs=args.dhry_runs)
        dh_res["cflags"] = dhry_elf[1]
        report["suites"]["dhrystone_2_1"] = dh_res
        print(
            f"[S2.5-M3a] Dhrystone 2.1 PASS: {dh_res['dmips_per_mhz']} DMIPS/MHz "
            f"({dh_res['dmips_at_500mhz']} DMIPS @ 500 MHz), IPC={dh_res['ipc']}, "
            f"cycles={dh_res['cycles']}, cpi_errs={dh_res['cpi_conservation_errors']}",
            flush=True,
        )

    # 4. Run CoreMark (S1 1-iter + 10-iter, S2 N=1/2/4)
    if "coremark" in suites:
        assert s1_exe is not None
        print(f"\n[S2.5-M3a] === Running CoreMark S1 (1-iter convergence + {args.coremark_iters}-iter) ===", flush=True)
        s1_1_out = run_tb(s1_exe, cm_elfs["s1_1iter"][0], max_cycles=10000000)
        s1_1_res = parse_and_verify_coremark(s1_1_out, expected_contexts=1, expected_iters=1)

        s1_main_out = run_tb(s1_exe, cm_elfs["s1_main"][0], max_cycles=50000000)
        s1_main_res = parse_and_verify_coremark(s1_main_out, expected_contexts=1, expected_iters=args.coremark_iters)
        conv_pct = abs(s1_main_res["cycles_per_iter"] - s1_1_res["cycles_per_iter"]) / s1_main_res["cycles_per_iter"] * 100.0
        print(
            f"[S2.5-M3a] CoreMark S1 PASS: {s1_main_res['coremark_per_mhz']} CoreMark/MHz "
            f"({s1_main_res['coremark_at_500mhz']} @ 500 MHz), IPC={s1_main_res['ipc']}, "
            f"cyc/iter={s1_main_res['cycles_per_iter']} (1-iter delta={conv_pct:.2f}%), "
            f"cpi_errs={s1_main_res['cpi_conservation_errors']}",
            flush=True,
        )

        print(f"\n[S2.5-M3a] === Running CoreMark SMP on fursoy_s2_soc (N=1, 2, 4; {args.coremark_iters} iters/ctx) ===", flush=True)
        smp_results: dict[str, Any] = {}
        # Run N=1 first, then N=2 and N=4 concurrently (4+2=6 threads on 8 physical cores!)
        n1_out = run_tb(s2_exes[1], cm_elfs["s2_n1"][0], max_cycles=50000000, stream_stderr=True)
        smp_results["n1"] = parse_and_verify_coremark(n1_out, expected_contexts=1, expected_iters=args.coremark_iters)

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
            f2 = ex.submit(run_tb, s2_exes[2], cm_elfs["s2_n2"][0], 50000000, True)
            f4 = ex.submit(run_tb, s2_exes[4], cm_elfs["s2_n4"][0], 50000000, True)
            smp_results["n2"] = parse_and_verify_coremark(f2.result(), expected_contexts=2, expected_iters=args.coremark_iters)
            smp_results["n4"] = parse_and_verify_coremark(f4.result(), expected_contexts=4, expected_iters=args.coremark_iters)

        base_cm = smp_results["n1"]["coremark_per_mhz"]
        scaling = {
            "n1_to_n2": round(smp_results["n2"]["coremark_per_mhz"] / base_cm, 4),
            "n1_to_n4": round(smp_results["n4"]["coremark_per_mhz"] / base_cm, 4),
        }
        print(
            f"[S2.5-M3a] CoreMark SMP PASS: N=1 {base_cm} | N=2 {smp_results['n2']['coremark_per_mhz']} ({scaling['n1_to_n2']}x) "
            f"| N=4 {smp_results['n4']['coremark_per_mhz']} ({scaling['n1_to_n4']}x) CoreMark/MHz",
            flush=True,
        )
        report["suites"]["coremark"] = {
            "status": "pass",
            "cflags": cm_elfs["s1_main"][1],
            "note": "Verilator cycle-accurate simulation runs 10 iterations/context with 1-iter convergence check (all official 2K performance CRCs 0xe9f5/0xe714/0x1fd7/0x8e3a validated).",
            "s1_convergence_1iter": s1_1_res,
            "s1_single_core": s1_main_res,
            "convergence_1iter_vs_10iter_pct": round(conv_pct, 3),
            "s2_smp": smp_results,
            "smp_scaling": scaling,
        }

    # 5. Run McCalpin FP64 STREAM (N=1, 2, 4 on fursoy_s2_soc)
    if "stream" in suites:
        print(
            f"\n[S2.5-M3a] === Running McCalpin FP64 STREAM on fursoy_s2_soc "
            f"(N=1, 2, 4; size={args.stream_array_size}, ntimes={args.stream_ntimes}) ===",
            flush=True,
        )
        st_results: dict[str, Any] = {}
        n1_out = run_tb(s2_exes[1], stream_elfs[1][0], max_cycles=100000000, stream_stderr=True)
        st_results["n1"] = parse_and_verify_stream(
            n1_out, 1, args.stream_array_size, args.stream_offset, args.stream_ntimes
        )
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
            f2 = ex.submit(run_tb, s2_exes[2], stream_elfs[2][0], 100000000, True)
            f4 = ex.submit(run_tb, s2_exes[4], stream_elfs[4][0], 100000000, True)
            st_results["n2"] = parse_and_verify_stream(
                f2.result(), 2, args.stream_array_size, args.stream_offset, args.stream_ntimes
            )
            st_results["n4"] = parse_and_verify_stream(
                f4.result(), 4, args.stream_array_size, args.stream_offset, args.stream_ntimes
            )

        st_scaling: dict[str, dict[str, float]] = {}
        for kname in ("Copy", "Scale", "Add", "Triad"):
            b1 = st_results["n1"]["kernels"][kname]["best_rate_mb_s_at_500mhz"]
            b2 = st_results["n2"]["kernels"][kname]["best_rate_mb_s_at_500mhz"]
            b4 = st_results["n4"]["kernels"][kname]["best_rate_mb_s_at_500mhz"]
            st_scaling[kname] = {
                "n1_to_n2": round(b2 / b1, 4) if b1 > 0 else 0.0,
                "n1_to_n4": round(b4 / b1, 4) if b1 > 0 else 0.0,
            }
        print(
            f"[S2.5-M3a] STREAM FP64 PASS (Triad @ 500 MHz): "
            f"N=1 {st_results['n1']['kernels']['Triad']['best_rate_mb_s_at_500mhz']} MB/s | "
            f"N=2 {st_results['n2']['kernels']['Triad']['best_rate_mb_s_at_500mhz']} MB/s ({st_scaling['Triad']['n1_to_n2']}x) | "
            f"N=4 {st_results['n4']['kernels']['Triad']['best_rate_mb_s_at_500mhz']} MB/s ({st_scaling['Triad']['n1_to_n4']}x)",
            flush=True,
        )
        report["suites"]["stream_fp64"] = {
            "status": "pass",
            "cflags": stream_elfs[1][1],
            "configs": st_results,
            "scaling": st_scaling,
        }

    # 6. Run Embench-IoT (All 19 benchmarks in parallel on fursoy_s1_soc)
    if "embench" in suites:
        assert s1_exe is not None
        baseline_map = json.loads(
            (SRC_DIR / "embench-iot/baseline-data/speed.json").read_text(encoding="utf-8")
        )
        print(
            f"\n[S2.5-M3a] === Running all {len(emb_benches)} Embench-IoT benchmarks "
            f"on fursoy_s1_soc (workers={args.embench_workers}, gsf={args.embench_gsf}) ===",
            flush=True,
        )
        emb_results: dict[str, Any] = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.embench_workers) as ex:
            futs = {
                ex.submit(
                    run_single_embench,
                    s1_exe,
                    emb_elfs[b],
                    b,
                    float(baseline_map[b]),
                    args.embench_gsf,
                    50000000,
                ): b
                for b in emb_benches
            }
            for fut in concurrent.futures.as_completed(futs):
                b, entry = fut.result()
                emb_results[b] = entry
                print(
                    f"  [EMBENCH {len(emb_results):02d}/{len(emb_benches)}] {b:15s} PASS | "
                    f"cycles={entry['cycles']:10d} ipc={entry['ipc']:.4f} "
                    f"speed/MHz={entry['speed_per_mhz_vs_m4']:.3f} cpi_errs={entry['cpi_conservation_errors']}",
                    flush=True,
                )

        ordered_emb = {k: emb_results[k] for k in sorted(emb_results.keys())}
        ipcs = [v["ipc"] for v in ordered_emb.values()]
        sp_mhz = [v["speed_per_mhz_vs_m4"] for v in ordered_emb.values()]
        sp_500 = [v["speed_at_500mhz_vs_1mhz_m4"] for v in ordered_emb.values()]
        total_cpi_errs = sum(v["cpi_conservation_errors"] for v in ordered_emb.values())
        report["suites"]["embench_iot"] = {
            "status": "pass",
            "benchmarks_total": len(ordered_emb),
            "benchmarks_passed": len(ordered_emb),
            "exclusions": 0,
            "gsf": args.embench_gsf,
            "warmup_heat": 1,
            "cflags": emb_flags_sample,
            "geomean_ipc": round(geomean(ipcs), 4),
            "geomean_speed_per_mhz_vs_cortex_m4": round(geomean(sp_mhz), 4),
            "geomean_speed_at_500mhz_vs_1mhz_m4": round(geomean(sp_500), 2),
            "total_cpi_conservation_errors": total_cpi_errs,
            "benchmarks": ordered_emb,
        }
        print(
            f"[S2.5-M3a] Embench-IoT PASS ({len(ordered_emb)}/{len(ordered_emb)}): "
            f"geomean IPC={report['suites']['embench_iot']['geomean_ipc']}, "
            f"geomean Speed/MHz vs Cortex-M4={report['suites']['embench_iot']['geomean_speed_per_mhz_vs_cortex_m4']}",
            flush=True,
        )

    all_ok = all(v.get("status") == "pass" for v in report["suites"].values())
    report["status"] = "pass" if (all_ok and len(report["suites"]) > 0) else "fail"
    report["peak_rss_kib"] = int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    args.out_report.parent.mkdir(parents=True, exist_ok=True)
    args.out_report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"\n[S2.5-M3a] Wrote {args.out_report}: status={report['status']}", flush=True)
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
