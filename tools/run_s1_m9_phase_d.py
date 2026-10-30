#!/usr/bin/env python3
"""Build and run Fursoy Slice-1 Milestone 9 Phase D (Device Tree, SBI Firmware & Early Linux Kernel Handoff) Verification Suite."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build/s1_m9_phase_d"
REPORT = ROOT / "results/s1-m9-phase-d.json"
DTB_OUT = ROOT / "build/dts/fursoy_s1.dtb"
DTS_SRC = ROOT / "software/dts/fursoy_s1.dts"

FW_ELF = BUILD_DIR / "fursoy_s1_sbi.elf"
PAYLOAD_ELF = BUILD_DIR / "fursoy_s1_payload.elf"
TB_CPP = ROOT / "verification/s1_m9_phase_d_tb.cpp"

SPEC_DOCUMENT = "docs/architecture/slice1-m9-soc-linux-v1.md"
SPEC_VERSION = "1.1"
SPEC_SHA256 = "bb353f632ec909b3270522e289d994cc90a34f18ab323705a9010e1070181347"

CORE_RTL = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_frat.sv",
    ROOT / "rtl/core/fursoy_s1_fprf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
    ROOT / "rtl/core/fursoy_s1_prf.sv",
    ROOT / "rtl/core/fursoy_s1_fprf.sv",
    ROOT / "rtl/core/fursoy_s1_alu.sv",
    ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
    ROOT / "rtl/core/fursoy_s1_multiplier.sv",
    ROOT / "rtl/core/fursoy_s1_divider.sv",
    ROOT / "rtl/core/fursoy_s1_port1_buffers.sv",
    ROOT / "rtl/core/fursoy_s1_int_iq.sv",
    ROOT / "rtl/core/fursoy_s1_agu.sv",
    ROOT / "rtl/core/fursoy_s1_mem_iq.sv",
    ROOT / "rtl/core/fursoy_s1_trt.sv",
    ROOT / "rtl/core/fursoy_s1_lsu_queues.sv",
    ROOT / "rtl/core/fursoy_s1_l1d.sv",
    ROOT / "rtl/core/fursoy_s1_lsu.sv",
    ROOT / "rtl/core/fursoy_s1_fma.sv",
    ROOT / "rtl/core/fursoy_s1_fdiv.sv",
    ROOT / "rtl/core/fursoy_s1_fconv.sv",
    ROOT / "rtl/core/fursoy_s1_fp_iq.sv",
    ROOT / "rtl/core/fursoy_s1_vrf.sv",
    ROOT / "rtl/core/fursoy_s1_vec_iq.sv",
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

SOC_RTL = CORE_RTL + [
    ROOT / "rtl/platform/fursoy_s0_clint.sv",
    ROOT / "rtl/platform/fursoy_s0_plic.sv",
    ROOT / "rtl/platform/fursoy_s0_uart.sv",
    ROOT / "rtl/platform/fursoy_s1_soc.sv",
]

FW_SOURCES = [
    ROOT / "software/firmware/fursoy_s1_sbi.h",
    ROOT / "software/firmware/fursoy_s1_sbi_link.ld",
    ROOT / "software/firmware/fursoy_s1_sbi_entry.S",
    ROOT / "software/firmware/fursoy_s1_sbi_trap.S",
    ROOT / "software/firmware/fursoy_s1_sbi_core.c",
]

PAYLOAD_SOURCES = [
    ROOT / "software/firmware/fursoy_s1_payload_link.ld",
    ROOT / "software/firmware/fursoy_s1_payload_entry.S",
    ROOT / "software/firmware/fursoy_s1_payload.c",
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def compute_manifest_sha256(files: list[Path]) -> str:
    h = hashlib.sha256()
    for f in sorted(files, key=lambda p: p.name):
        h.update(f.name.encode("utf-8"))
        h.update(f.read_bytes())
    return h.hexdigest()


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
    print("Fursoy Slice-1 Milestone 9 Phase D Verification Suite")
    print(f"Specification: {SPEC_DOCUMENT} v{SPEC_VERSION}")
    print(f"Specification SHA-256: {SPEC_SHA256}")
    print(f"Core RTL Manifest SHA-256 (40 files): {core_manifest_sha}")
    print(f"SoC  RTL Manifest SHA-256 (44 files): {soc_manifest_sha}")
    print("=============================================================================")

    # 1. Compile DTB
    print("[1/5] Compiling Platform Device Tree (fursoy_s1.dts -> fursoy_s1.dtb)...")
    dtc_cmd = ["dtc", "-I", "dts", "-O", "dtb", "-o", str(DTB_OUT), str(DTS_SRC)]
    rc, out = run_cmd(dtc_cmd)
    if rc != 0:
        print(f"ERROR: Device Tree compilation failed:\n{out}", file=sys.stderr)
        return 1

    # 2. Compile Minimal SBI Firmware
    print("[2/5] Compiling Minimal SBI Firmware (fursoy_s1_sbi.elf)...")
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

    # 3. Compile S-Mode Payload
    print("[3/5] Compiling S-Mode Payload (fursoy_s1_payload.elf)...")
    payload_cmd = [
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
        "-T", str(ROOT / "software/firmware/fursoy_s1_payload_link.ld"),
        str(ROOT / "software/firmware/fursoy_s1_payload_entry.S"),
        str(ROOT / "software/firmware/fursoy_s1_payload.c"),
        "-lgcc",
        "-o", str(PAYLOAD_ELF),
    ]
    rc, out = run_cmd(payload_cmd)
    if rc != 0:
        print(f"ERROR: Payload compilation failed:\n{out}", file=sys.stderr)
        return 1

    halt_loop_pc = get_symbol_address(FW_ELF, "halt_loop")
    print(f"Resolved firmware halt_loop PC: 0x{halt_loop_pc:08x}")

    # 4. Build Verilator Simulation Model
    print("[4/5] Building Verilator Simulation Model (Vfursoy_s1_m9_phase_d)...")
    v_cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "-O3",
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
        "-o", "Vfursoy_s1_m9_phase_d",
    ]
    rc, out = run_cmd(v_cmd)
    build_log = BUILD_DIR / "build.log"
    build_log.write_text(out, encoding="utf-8")
    if rc != 0:
        print(f"ERROR: Verilator build failed:\n{out}", file=sys.stderr)
        return 1

    # 5. Execute Simulation Testbench
    print("[5/5] Executing Phase D Verification Testbench...")
    sim_bin = BUILD_DIR / "Vfursoy_s1_m9_phase_d"
    sim_cmd = [
        str(sim_bin),
        str(FW_ELF),
        str(PAYLOAD_ELF),
        str(DTB_OUT),
        f"0x{halt_loop_pc:x}",
        "300000",
    ]
    rc, sim_out = run_cmd(sim_cmd)
    print(sim_out)

    # Parse JSON report from simulation output
    json_start = sim_out.rfind("{\n  \"status\":")
    tb_data = {}
    if json_start != -1:
        try:
            tb_data = json.loads(sim_out[json_start:])
        except Exception as e:
            print(f"WARNING: Failed to parse testbench JSON: {e}", file=sys.stderr)

    passed = (rc == 0) and (tb_data.get("status") == "pass")
    elapsed = time.time() - start_time

    report_data = {
        "milestone": "Milestone 9",
        "phase": "Phase D",
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
            "payload_elf": sha256_file(PAYLOAD_ELF),
        },
        "simulation": tb_data,
        "properties_verified": [
            "PROP_M9_19",
            "PROP_M9_20",
            "PROP_M9_21",
            "PROP_M9_22",
            "PROP_M9_23",
            "PROP_M9_24",
            "PROP_M9_25",
            "PROP_M9_26",
        ],
    }

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report_data, indent=2) + "\n", encoding="utf-8")
    print(f"Results written to: {REPORT.relative_to(ROOT)}")

    if passed:
        print("=============================================================================")
        print("SLICE-1 MILESTONE 9 PHASE D VERIFICATION PASSED (8/8 Properties Clean)")
        print("=============================================================================")
        return 0
    else:
        print("=============================================================================")
        print("SLICE-1 MILESTONE 9 PHASE D VERIFICATION FAILED")
        print("=============================================================================")
        return 1


if __name__ == "__main__":
    sys.exit(main())
