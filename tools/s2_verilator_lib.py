#!/usr/bin/env python3
"""Shared Verilator SoC static-library builder & runtime config helpers for Slice-2 suites.

Supports:
  - FURSOY_JOBS: parallel build jobs (defaults to min(6, cpu_count) on < 24 GiB hosts,
                 os.cpu_count() on >= 24 GiB hosts).
  - FURSOY_VERILATOR_THREADS: Verilator simulation threads (defaults to 1; passes
                              --threads <T> when T > 1).
  - FURSOY_REBUILD_SOC=1: force clean rebuild of the shared Vfursoy_s2_soc__ALL.a archive.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOC_SV = ROOT / "rtl/platform/fursoy_s2_soc.sv"
SOC_LIB_ROOT = ROOT / "build/s2_soc_lib"


def run_cmd(cmd: list[str], timeout_s: int = 3600) -> tuple[int, str]:
    res = subprocess.run(
        cmd,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
        timeout=timeout_s,
    )
    return res.returncode, res.stdout


def get_total_ram_gib() -> float:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) / (1024.0 * 1024.0)
    except OSError:
        pass
    return 16.0


def get_build_jobs() -> int:
    env = os.environ.get("FURSOY_JOBS")
    if env:
        try:
            val = int(env)
            if val > 0:
                return val
        except ValueError:
            pass
    cpus = os.cpu_count() or 1
    return min(6, cpus) if get_total_ram_gib() < 24.0 else cpus


def get_verilator_threads() -> int:
    env = os.environ.get("FURSOY_VERILATOR_THREADS")
    if env:
        try:
            val = int(env)
            if val > 0:
                return val
        except ValueError:
            pass
    return 1


def get_verilator_root() -> Path:
    rc, out = run_cmd(["verilator", "--getenv", "VERILATOR_ROOT"], timeout_s=30)
    if rc == 0 and out.strip():
        return Path(out.strip().splitlines()[-1])
    return Path("/usr/share/verilator")


def compute_rtl_sha256() -> str:
    h = hashlib.sha256()
    files: list[Path] = []
    for sub in ("rtl/common", "rtl/core", "rtl/platform"):
        d = ROOT / sub
        if d.exists():
            files.extend(sorted(d.glob("*.sv")))
    for p in files:
        h.update(str(p.relative_to(ROOT)).encode("utf-8"))
        h.update(b"\0")
        h.update(p.read_bytes())
        h.update(b"\0")
    return h.hexdigest()


def _parse_global_objs(classes_mk_path: Path) -> list[str]:
    classes_mk = classes_mk_path.read_text(encoding="utf-8")
    global_objs: list[str] = []
    in_global = False
    for line in classes_mk.splitlines():
        s = line.strip()
        if s.startswith("VM_GLOBAL_FAST") or s.startswith("VM_GLOBAL_SLOW"):
            in_global = s.endswith("\\")
            continue
        if in_global:
            tok = s.rstrip("\\").strip()
            if tok:
                global_objs.append(f"{tok}.o")
            if not s.endswith("\\"):
                in_global = False
    return global_objs or ["verilated.o", "verilated_threads.o"]


def ensure_soc_lib(
    num_harts: int,
    jobs: int | None = None,
    threads: int | None = None,
    smp_coherence_en: int = 1,
    log_path: Path | None = None,
) -> tuple[Path, Path, list[Path], float, bool]:
    """Ensure Vfursoy_s2_soc__ALL.a and Verilator runtime objects exist and match current RTL.

    Returns (soc_mdir, lib_path, global_obj_paths, build_seconds, was_rebuilt).
    """
    jobs = jobs if jobs is not None else get_build_jobs()
    threads = threads if threads is not None else get_verilator_threads()
    soc_mdir = SOC_LIB_ROOT / f"n{num_harts}_coh{smp_coherence_en}_t{threads}"
    meta_path = soc_mdir / "soc_meta.json"
    lib_path = soc_mdir / "Vfursoy_s2_soc__ALL.a"
    classes_mk = soc_mdir / "Vfursoy_s2_soc_classes.mk"

    rtl_sha = compute_rtl_sha256()
    expected_meta = {
        "num_harts": num_harts,
        "smp_coherence_en": smp_coherence_en,
        "threads": threads,
        "rtl_sha256": rtl_sha,
    }
    force_rebuild = os.environ.get("FURSOY_REBUILD_SOC", "0") == "1"

    if not force_rebuild and meta_path.exists() and lib_path.exists() and classes_mk.exists():
        try:
            cur_meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if cur_meta == expected_meta:
                g_objs = [soc_mdir / o for o in _parse_global_objs(classes_mk)]
                if all(p.exists() for p in g_objs):
                    return soc_mdir, lib_path, g_objs, 0.0, False
        except (OSError, json.JSONDecodeError):
            pass

    shutil.rmtree(soc_mdir, ignore_errors=True)
    soc_mdir.mkdir(parents=True, exist_ok=True)

    t0 = time.monotonic()
    v_cmd = [
        "verilator",
        "--cc",
        "--build",
        "-O3",
        "-j",
        str(jobs),
        *(["--threads", str(threads)] if threads > 1 else []),
        "--assert",
        "-Wall",
        "-Wno-DECLFILENAME",
        "-Wno-fatal",
        "-Irtl/core",
        "-Irtl/platform",
        f"-GNUM_HARTS={num_harts}",
        f"-GSMP_COHERENCE_EN=1'b{smp_coherence_en}",
        "--top-module",
        "fursoy_s2_soc",
        "-Mdir",
        str(soc_mdir),
        "-CFLAGS",
        "-std=c++17 -O3",
        str(SOC_SV),
    ]
    rc, out = run_cmd(v_cmd, timeout_s=3600)
    if log_path is not None:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text(out, encoding="utf-8")
    if rc != 0 or not lib_path.exists():
        raise RuntimeError(f"Verilator SoC library build failed for N={num_harts}:\n{out[-2500:]}")

    global_objs = _parse_global_objs(classes_mk)
    mk_cmd = ["make", "-C", str(soc_mdir), "-f", "Vfursoy_s2_soc.mk", "-j", str(jobs), *global_objs]
    rc, mk_out = run_cmd(mk_cmd, timeout_s=600)
    if log_path is not None:
        log_path.write_text(out + "\n" + mk_out, encoding="utf-8")
    if rc != 0:
        raise RuntimeError(f"Verilator runtime object build failed for N={num_harts}:\n{mk_out[-2500:]}")

    build_s = time.monotonic() - t0
    meta_path.write_text(json.dumps(expected_meta, indent=2) + "\n", encoding="utf-8")
    return soc_mdir, lib_path, [soc_mdir / o for o in global_objs], build_s, True


def link_verilator_tb(
    num_harts: int,
    tb_cpp: Path,
    soc_mdir: Path,
    soc_lib: Path,
    global_objs: list[Path],
    exe_path: Path,
    threads: int,
    extra_include_dirs: list[Path] | None = None,
) -> tuple[Path, float]:
    exe_path.parent.mkdir(parents=True, exist_ok=True)
    vroot = get_verilator_root()
    inc_flags = [f"-I{soc_mdir}", f"-I{vroot / 'include'}", f"-I{vroot / 'include' / 'vltstd'}"]
    for d in extra_include_dirs or []:
        inc_flags.append(f"-I{d}")

    t0 = time.monotonic()
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
        f"-DNUM_HARTS={num_harts}",
        *(["-DVL_THREADED=1"] if threads > 1 else []),
        *inc_flags,
        str(tb_cpp),
        str(soc_lib),
        *[str(o) for o in global_objs],
        "-pthread",
        "-lpthread",
        "-latomic",
        "-o",
        str(exe_path),
    ]
    rc, out = run_cmd(cmd, timeout_s=600)
    link_s = time.monotonic() - t0
    if rc != 0:
        raise RuntimeError(f"Testbench link failed for {tb_cpp.name} N={num_harts}:\n{out[-2500:]}")
    return exe_path, link_s
