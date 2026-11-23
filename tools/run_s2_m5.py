#!/usr/bin/env python3
"""Fursoy Slice-2 Milestone S2-M5: Parameterized Multi-Hart DTB, SMP Linux 6.6.50
Build, Initramfs Assembly, and Verilator SMP Linux Boot Runner.

Supports:
  --build-only          Build DTB, SBI firmware, SMP initramfs, SMP Linux Image, and link TB(s) without running.
  --smoke-cycles <C>    Run a fast smoke boot of C cycles (verifies SBI handoff + Linux banner, 0 panics).
  --num-harts 2,4       Comma-separated hart counts to build/run (default: 2,4).
  --max-cycles <C>      Cycle cap for full closeout boot (default: 150000000).
  --rebuild-kernel      Force Linux 6.6.50 SMP kernel re-config & rebuild.
  --kernel-image <path> Override path to prebuilt SMP Linux Image.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from gen_s2_dts import DEFAULT_BOOTARGS, compile_dtb, render_dts  # noqa: E402
from s2_verilator_lib import (  # noqa: E402
    compute_rtl_sha256,
    ensure_soc_lib,
    get_build_jobs,
    get_verilator_threads,
    link_verilator_tb,
    run_cmd,
)

BUILD_ROOT = ROOT / "build/s2_m5"
DTS_DIR = ROOT / "build/dts"
FW_DIR = ROOT / "software/firmware"
SBI_SRCS = [
    FW_DIR / "fursoy_s2_sbi_entry.S",
    FW_DIR / "fursoy_s2_sbi_trap.S",
    FW_DIR / "fursoy_s2_sbi_core.c",
]
SBI_LD = FW_DIR / "fursoy_s2_sbi_link.ld"

LINUX_VER = "6.6.50"
LINUX_URL = f"https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-{LINUX_VER}.tar.xz"
LINUX_TARBALL = ROOT / f"build/linux-{LINUX_VER}.tar.xz"
LINUX_SMP_DIR = ROOT / f"build/linux-{LINUX_VER}-smp"
LINUX_SMP_IMAGE = LINUX_SMP_DIR / "arch/riscv/boot/Image"
DEFCONFIG_SRC = ROOT / "software/linux/fursoy_s2_defconfig"
PATCH_MISALIGNED = ROOT / "software/linux/patches/0001-riscv-cpufeature-misaligned-unsupported.patch"
INITRAMFS_S2_CPIO = ROOT / "build/initramfs_s2.cpio"
TB_CPP = ROOT / "verification/s2_m5_linux_tb.cpp"

CLOSEOUT_REPORT = ROOT / "results/s2-m5-closeout.json"
SMOKE_REPORT = BUILD_ROOT / "smoke-report.json"


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_smp_initramfs() -> Path:
    cmd = [
        sys.executable,
        str(ROOT / "tools/build_initramfs.py"),
        "--mode",
        "s2",
        "--out",
        str(INITRAMFS_S2_CPIO),
        "--kernel-dir",
        str(LINUX_SMP_DIR),
    ]
    res = subprocess.run(cmd, cwd=ROOT)
    if res.returncode != 0 or not INITRAMFS_S2_CPIO.exists():
        raise RuntimeError("Failed to build Slice-2 SMP initramfs archive")
    return INITRAMFS_S2_CPIO


def ensure_smp_kernel(rebuild: bool = False) -> Path:
    initramfs = ensure_smp_initramfs()

    meta_path = LINUX_SMP_DIR / ".fursoy_s2_meta.json"
    expected_meta = {
        "defconfig_sha256": sha256_file(DEFCONFIG_SRC),
        "patch_sha256": sha256_file(PATCH_MISALIGNED),
        "initramfs_sha256": sha256_file(initramfs),
    }

    if not rebuild and LINUX_SMP_IMAGE.exists() and meta_path.exists():
        try:
            if json.loads(meta_path.read_text(encoding="utf-8")) == expected_meta:
                print(f"[KERNEL-S2] Reusing fresh SMP Image: {LINUX_SMP_IMAGE} ({LINUX_SMP_IMAGE.stat().st_size} bytes)")
                return LINUX_SMP_IMAGE
        except (OSError, json.JSONDecodeError):
            pass

    if not (LINUX_SMP_DIR / "Makefile").exists():
        LINUX_TARBALL.parent.mkdir(parents=True, exist_ok=True)
        if not LINUX_TARBALL.exists():
            print(f"[KERNEL-S2] Downloading Linux {LINUX_VER} from {LINUX_URL}...")
            urllib.request.urlretrieve(LINUX_URL, LINUX_TARBALL)
        print(f"[KERNEL-S2] Extracting {LINUX_TARBALL.name} into {LINUX_SMP_DIR}...")
        LINUX_SMP_DIR.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["tar", "-xJf", str(LINUX_TARBALL), "--strip-components=1", "-C", str(LINUX_SMP_DIR)],
            check=True,
        )

    # Apply Fursoy misaligned-access trap-only patch idempotently
    cpufeat = LINUX_SMP_DIR / "arch/riscv/kernel/cpufeature.c"
    if "RISCV_HWPROBE_MISALIGNED_UNSUPPORTED" not in cpufeat.read_text(encoding="utf-8"):
        print(f"[KERNEL-S2] Applying {PATCH_MISALIGNED.name}...")
        subprocess.run(["patch", "-p1", "-i", str(PATCH_MISALIGNED)], cwd=LINUX_SMP_DIR, check=True)

    # Embed SMP initramfs archive
    k_cpio = LINUX_SMP_DIR / "usr/initramfs_data.cpio"
    k_cpio.write_bytes(initramfs.read_bytes())

    # Configure using fursoy_s2_defconfig
    cfg_dst = LINUX_SMP_DIR / ".config"
    cfg_dst.write_bytes(DEFCONFIG_SRC.read_bytes())
    jobs = get_build_jobs()
    env = os.environ.copy()
    env["ARCH"] = "riscv"
    env["CROSS_COMPILE"] = "riscv64-linux-gnu-"

    print("[KERNEL-S2] Running make olddefconfig...")
    subprocess.run(["make", "olddefconfig"], cwd=LINUX_SMP_DIR, env=env, check=True)

    # Verify critical SMP / non-C / earlycon options survived olddefconfig
    cfg_txt = cfg_dst.read_text(encoding="utf-8")
    for req in (
        "CONFIG_SMP=y",
        "CONFIG_NR_CPUS=4",
        "CONFIG_RISCV_SBI=y",
        "CONFIG_SIFIVE_PLIC=y",
        "CONFIG_SERIAL_EARLYCON_RISCV_SBI=y",
    ):
        if req not in cfg_txt:
            raise RuntimeError(f"Kernel .config missing required option: {req}")
    if "CONFIG_RISCV_ISA_C=y" in cfg_txt:
        raise RuntimeError("Kernel .config unexpectedly enabled CONFIG_RISCV_ISA_C=y")

    print(f"[KERNEL-S2] Building Linux {LINUX_VER} SMP Image (-j{jobs})...")
    t0 = time.monotonic()
    subprocess.run(["make", f"-j{jobs}", "Image"], cwd=LINUX_SMP_DIR, env=env, check=True)
    dt = time.monotonic() - t0
    if not LINUX_SMP_IMAGE.exists():
        raise RuntimeError(f"Kernel build succeeded but {LINUX_SMP_IMAGE} is missing")

    meta_path.write_text(json.dumps(expected_meta, indent=2) + "\n", encoding="utf-8")
    print(f"[KERNEL-S2] Built {LINUX_SMP_IMAGE} ({LINUX_SMP_IMAGE.stat().st_size} bytes) in {dt:.1f}s")
    return LINUX_SMP_IMAGE


def build_sbi_firmware(num_harts: int, out_elf: Path) -> Path:
    out_elf.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "riscv64-unknown-elf-gcc",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-mno-relax",
        "-nostdlib",
        "-nostartfiles",
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
        f"-DFURSOY_NUM_HARTS={num_harts}",
        f"-I{FW_DIR}",
        "-T",
        str(SBI_LD),
        *[str(s) for s in SBI_SRCS],
        "-o",
        str(out_elf),
    ]
    rc, out = run_cmd(cmd, timeout_s=120)
    if rc != 0:
        raise RuntimeError(f"SBI firmware build failed for N={num_harts}:\n{out}")
    return out_elf


def build_dtb(num_harts: int, bootargs: str) -> tuple[Path, Path]:
    dts_path = DTS_DIR / f"fursoy_s2_n{num_harts}.dts"
    dtb_path = DTS_DIR / f"fursoy_s2_n{num_harts}.dtb"
    dts_path.parent.mkdir(parents=True, exist_ok=True)
    dts_path.write_text(render_dts(num_harts=num_harts, bootargs=bootargs), encoding="utf-8")
    compile_dtb(dts_path, dtb_path)
    return dts_path, dtb_path


def run_config(
    num_harts: int,
    kernel_img: Path,
    bootargs: str,
    build_only: bool,
    smoke_cycles: int | None,
    max_cycles: int,
) -> dict:
    cfg_dir = BUILD_ROOT / f"n{num_harts}"
    cfg_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n=== [S2-M5 N={num_harts}] Building DTB, SBI Firmware & Linking Testbench ===")
    dts_path, dtb_path = build_dtb(num_harts, bootargs)
    print(f"[S2-M5 N={num_harts}] DTB: {dtb_path} ({dtb_path.stat().st_size} bytes)")

    sbi_elf = build_sbi_firmware(num_harts, cfg_dir / f"fursoy_s2_sbi_n{num_harts}.elf")
    print(f"[S2-M5 N={num_harts}] SBI: {sbi_elf} ({sbi_elf.stat().st_size} bytes)")

    jobs = get_build_jobs()
    # Respect explicit FURSOY_VERILATOR_THREADS; otherwise pick optimal thread count per N
    if os.environ.get("FURSOY_VERILATOR_THREADS"):
        threads = get_verilator_threads()
    else:
        threads = 4 if num_harts == 2 else 2

    soc_mdir, soc_lib, global_objs, soc_s, rebuilt = ensure_soc_lib(
        num_harts, jobs=jobs, threads=threads, log_path=cfg_dir / "soc_build.log"
    )
    tag = "fresh" if rebuilt else "cached_soc"
    exe_path, link_s = link_verilator_tb(
        num_harts,
        TB_CPP,
        soc_mdir,
        soc_lib,
        global_objs,
        cfg_dir / f"Vs2_m5_linux_n{num_harts}_t{threads}",
        threads,
    )
    print(
        f"[S2-M5 N={num_harts}] Linked {exe_path.name} in {link_s:.2f}s "
        f"(soc={soc_s:.2f}s [{tag}], jobs={jobs}, threads={threads})"
    )

    cfg_meta = {
        "num_harts": num_harts,
        "threads": threads,
        "soc_build_sec": round(soc_s, 2),
        "link_sec": round(link_s, 2),
        "dtb_path": str(dtb_path.relative_to(ROOT)),
        "dtb_sha256": sha256_file(dtb_path),
        "sbi_sha256": sha256_file(sbi_elf),
        "kernel_sha256": sha256_file(kernel_img),
    }

    if build_only:
        cfg_meta["status"] = "built"
        return cfg_meta

    is_smoke = smoke_cycles is not None
    run_cycles = smoke_cycles if is_smoke else max_cycles
    console_log = cfg_dir / ("smoke_console.log" if is_smoke else "linux_console.log")

    sim_cmd = [
        str(exe_path),
        str(sbi_elf),
        str(kernel_img),
        str(dtb_path),
        str(run_cycles),
        str(console_log),
        "1" if is_smoke else "0",
    ]
    print(f"--- [S2-M5 N={num_harts}] Launching SMP Linux Boot ({'smoke' if is_smoke else 'full'}, max_cycles={run_cycles}) ---")
    p = subprocess.Popen(sim_cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    out_lines: list[str] = []
    assert p.stdout is not None
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        out_lines.append(line)
    rc = p.wait()
    sim_out = "".join(out_lines)

    j_start = sim_out.rfind('{\n  "status":')
    tb_data = json.loads(sim_out[j_start:]) if j_start != -1 else {"status": "fail"}
    cfg_meta["simulation"] = tb_data
    cfg_meta["status"] = "pass" if (rc == 0 and tb_data.get("status") == "pass") else "fail"
    if cfg_meta["status"] != "pass":
        raise RuntimeError(f"S2-M5 {'smoke' if is_smoke else 'full'} boot FAILED for N={num_harts}")
    return cfg_meta


def main() -> int:
    parser = argparse.ArgumentParser(description="Fursoy Slice-2 Milestone S2-M5 SMP Linux Boot Runner")
    parser.add_argument("--build-only", action="store_true", help="Build artifacts and link TBs without running simulation")
    parser.add_argument("--smoke-cycles", type=int, default=None, help="Run fast smoke boot of C cycles (e.g. 500000)")
    parser.add_argument("--max-cycles", type=int, default=150_000_000, help="Max cycles for full closeout boot")
    parser.add_argument("--num-harts", default="2,4", help="Comma-separated hart counts (default: 2,4)")
    parser.add_argument("--bootargs", default=DEFAULT_BOOTARGS, help="Kernel /chosen bootargs")
    parser.add_argument("--kernel-image", type=Path, default=None, help="Override path to prebuilt SMP Linux Image")
    parser.add_argument("--rebuild-kernel", action="store_true", help="Force rebuild of Linux 6.6.50 SMP Image")
    parser.add_argument("--out-report", type=Path, default=None, help="Override output JSON report path")
    args = parser.parse_args()

    harts_list = [int(x.strip()) for x in args.num_harts.split(",") if x.strip()]
    t0 = time.monotonic()

    if args.kernel_image is not None:
        kernel_img = args.kernel_image.resolve()
        if not kernel_img.exists():
            raise RuntimeError(f"Specified --kernel-image not found: {kernel_img}")
    else:
        kernel_img = ensure_smp_kernel(rebuild=args.rebuild_kernel)

    configs: dict[str, dict] = {}
    for n in harts_list:
        configs[f"n{n}"] = run_config(
            num_harts=n,
            kernel_img=kernel_img,
            bootargs=args.bootargs,
            build_only=args.build_only,
            smoke_cycles=args.smoke_cycles,
            max_cycles=args.max_cycles,
        )

    elapsed = round(time.monotonic() - t0, 2)
    mode = "build_only" if args.build_only else ("smoke" if args.smoke_cycles is not None else "full")
    report = {
        "milestone": "S2-M5",
        "mode": mode,
        "status": "pass",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_sec": elapsed,
        "rtl_sha256": compute_rtl_sha256(),
        "linux_version": LINUX_VER,
        "kernel_image": str(kernel_img),
        "kernel_sha256": sha256_file(kernel_img),
        "configs": configs,
    }

    if args.out_report is not None:
        report_path = args.out_report if args.out_report.is_absolute() else (ROOT / args.out_report)
    else:
        report_path = SMOKE_REPORT if (args.build_only or args.smoke_cycles is not None) else CLOSEOUT_REPORT
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"\n[S2-M5] {mode.upper()} PASSED in {elapsed}s -> {report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
