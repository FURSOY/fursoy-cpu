#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 9 Closeout (Full Linux Kernel Boot, BusyBox Userspace & Gate G5 Sign-off) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

from s1_rtl_manifest import (
    CORE_RTL,
    ROOT,
    SOC_RTL,
    compute_manifest_sha256,
    sha256_file,
)

BUILD_DIR = ROOT / "build/s1_m9_closeout"
REPORT = ROOT / "results/s1-m9-closeout.json"
DTB_OUT = ROOT / "build/dts/fursoy_s1.dtb"
DTS_SRC = ROOT / "software/dts/fursoy_s1.dts"

FW_ELF = BUILD_DIR / "fursoy_s1_sbi.elf"
KERNEL_IMG = ROOT / "build/linux-6.6.50/arch/riscv/boot/Image"
TB_CPP = ROOT / "verification/s1_m9_closeout_tb.cpp"

SPEC_DOCUMENT = "docs/architecture/slice1-m9-soc-linux-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "bb353f632ec909b3270522e289d994cc90a34f18ab323705a9010e1070181347"

FW_SOURCES = [
    ROOT / "software/firmware/fursoy_s1_sbi.h",
    ROOT / "software/firmware/fursoy_s1_sbi_link.ld",
    ROOT / "software/firmware/fursoy_s1_sbi_entry.S",
    ROOT / "software/firmware/fursoy_s1_sbi_trap.S",
    ROOT / "software/firmware/fursoy_s1_sbi_core.c",
]


def get_symbol_address(elf_path: Path, symbol_name: str) -> int:
    nm = subprocess.run(
        ["riscv64-unknown-elf-nm", "-n", str(elf_path)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=20,
    )
    if nm.returncode != 0:
        raise RuntimeError(f"nm failed on {elf_path}:\n{nm.stderr}")
    for line in nm.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == symbol_name:
            return int(parts[0], 16)
    raise RuntimeError(f"Symbol {symbol_name} not found in {elf_path}")


def run_cmd(cmd: list[str], cwd: Path | None = None) -> tuple[int, str]:
    res = subprocess.run(cmd, cwd=cwd or ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    return res.returncode, res.stdout


def main() -> int:
    start_time = time.time()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    DTB_OUT.parent.mkdir(parents=True, exist_ok=True)

    core_manifest_sha = compute_manifest_sha256(CORE_RTL)
    soc_manifest_sha = compute_manifest_sha256(SOC_RTL)

    print("=============================================================================")
    print("Fursoy Slice-1 Milestone 9 Closeout Verification Suite")
    print("Gate G5: Full Single-Core Linux-Bootable Processor Sign-off")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Specification SHA-256: {SPEC_SHA256}")
    print(f"Core RTL Manifest SHA-256 ({len(CORE_RTL)} files): {core_manifest_sha}")
    print(f"SoC  RTL Manifest SHA-256 ({len(SOC_RTL)} files): {soc_manifest_sha}")
    if core_manifest_sha not in ACCEPTED_RTL_MANIFEST_SHA256S:
        print(f"ERROR: Core RTL manifest {core_manifest_sha} not in ACCEPTED_RTL_MANIFEST_SHA256S!", file=sys.stderr)
        return 1
    print("=============================================================================")

    # 1. Compile DTB
    print("[1/4] Compiling Platform Device Tree (fursoy_s1.dts -> fursoy_s1.dtb)...")
    dtc_cmd = ["dtc", "-I", "dts", "-O", "dtb", "-o", str(DTB_OUT), str(DTS_SRC)]
    rc, out = run_cmd(dtc_cmd)
    if rc != 0:
        print(f"ERROR: Device Tree compilation failed:\n{out}", file=sys.stderr)
        return 1

    # 2. Compile Minimal SBI Firmware
    print("[2/4] Compiling Minimal SBI Firmware (fursoy_s1_sbi.elf)...")
    fw_cmd = [
        "riscv64-unknown-elf-gcc",
        "-O2",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-mno-relax",
        "-fno-builtin",
        "-nostdlib",
        "-nostartfiles",
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
        "-T", str(ROOT / "software/firmware/fursoy_s1_sbi_link.ld"),
        str(ROOT / "software/firmware/fursoy_s1_sbi_entry.S"),
        str(ROOT / "software/firmware/fursoy_s1_sbi_trap.S"),
        str(ROOT / "software/firmware/fursoy_s1_sbi_core.c"),
        "-lgcc",
        "-o", str(FW_ELF),
    ]
    rc, out = run_cmd(fw_cmd)
    if rc != 0:
        print(f"ERROR: Firmware compilation failed:\n{out}", file=sys.stderr)
        return 1

    halt_loop_pc = get_symbol_address(FW_ELF, "halt_loop")
    print(f"Resolved firmware halt_loop PC: 0x{halt_loop_pc:08x}")

    # Verify Linux kernel image
    if not KERNEL_IMG.exists():
        print(f"ERROR: Kernel image not found at {KERNEL_IMG}", file=sys.stderr)
        return 1
    print(f"Verified Linux Kernel Image: {KERNEL_IMG.stat().st_size} bytes (SHA-256: {sha256_file(KERNEL_IMG)[:16]}...)")

    # 3. Build Verilator Simulation Model
    print("[3/4] Building Verilator Simulation Model (Vfursoy_s1_m9_closeout)...")
    v_cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "-O3",
        "-CFLAGS", "-O3",
        "--assert",
        "-Wall",
        "-Wno-fatal",
        "-j", "4",
        "--top-module", "fursoy_s1_soc",
        "-Irtl/core",
        "-Irtl/platform",
        "--Mdir", str(BUILD_DIR),
        str(ROOT / "rtl/platform/fursoy_s1_soc.sv"),
        str(TB_CPP),
        "-o", "Vfursoy_s1_m9_closeout",
    ]
    rc, out = run_cmd(v_cmd)
    build_log = BUILD_DIR / "build.log"
    build_log.write_text(out, encoding="utf-8")
    if rc != 0:
        print(f"ERROR: Verilator build failed:\n{out}", file=sys.stderr)
        return 1

    # 4. Execute Simulation Testbench
    max_cycles = sys.argv[1] if len(sys.argv) > 1 else "150000000"
    console_log = BUILD_DIR / "linux_boot.log"
    print(f"[4/4] Executing Milestone 9 Closeout Verification Testbench (max_cycles={max_cycles})...")
    sim_bin = BUILD_DIR / "Vfursoy_s1_m9_closeout"
    sim_cmd = [
        str(sim_bin),
        str(FW_ELF),
        str(KERNEL_IMG),
        str(DTB_OUT),
        f"0x{halt_loop_pc:x}",
        str(max_cycles),
        str(console_log),
    ]

    # Run simulation with real-time stdout streaming
    p = subprocess.Popen(sim_cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    stdout_lines = []
    while True:
        line = p.stdout.readline()
        if not line and p.poll() is not None:
            break
        if line:
            sys.stdout.write(line)
            sys.stdout.flush()
            stdout_lines.append(line)
    p.wait()
    sim_out = "".join(stdout_lines)

    # Parse JSON report from simulation output
    json_start = sim_out.rfind("{\n  \"status\":")
    tb_data = {}
    if json_start != -1:
        try:
            tb_data = json.loads(sim_out[json_start:])
        except Exception as e:
            print(f"WARNING: Failed to parse testbench JSON: {e}", file=sys.stderr)

    passed = (p.returncode == 0) and (tb_data.get("status") == "pass")
    elapsed = time.time() - start_time

    report_data = {
        "milestone": "Milestone 9 Closeout",
        "gate": "Gate G5: Full Single-Core Linux-Bootable Processor",
        "status": "PASS" if passed else "FAIL",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(elapsed, 2),
        "spec_authority": {
            "document": SPEC_DOCUMENT,
            "version": SPEC_VERSION,
            "sha256": SPEC_SHA256,
        },
        "manifests": {
            "core_rtl_manifest_sha256": core_manifest_sha,
            "soc_rtl_manifest_sha256": soc_manifest_sha,
        },
        "binaries_sha256": {
            "dtb": sha256_file(DTB_OUT),
            "firmware_elf": sha256_file(FW_ELF),
            "kernel_image": sha256_file(KERNEL_IMG),
        },
        "simulation": tb_data,
        "properties_verified": [
            "PROP_M9_27",
            "PROP_M9_28",
            "PROP_M9_29",
            "PROP_M9_30",
        ],
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report_data, indent=2) + "\n", encoding="utf-8")
    print(f"Results written to: {REPORT.relative_to(ROOT)}")

    if passed:
        print("=============================================================================")
        print("SLICE-1 MILESTONE 9 CLOSEOUT VERIFICATION PASSED (Gate G5 Signed Off)")
        print("All Properties PROP_M9_27 through PROP_M9_30 Strictly Verified")
        print("=============================================================================")
        return 0
    else:
        print("=============================================================================")
        print("SLICE-1 MILESTONE 9 CLOSEOUT VERIFICATION FAILED")
        print("=============================================================================")
        return 1


if __name__ == "__main__":
    sys.exit(main())
