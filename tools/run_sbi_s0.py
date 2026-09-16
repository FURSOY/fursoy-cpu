"""Build and run the focused 40-scenario verification suite for Fursoy Minimal SBI Firmware."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/sbi_s0"
REPORT = ROOT / "results/sbi-s0.json"
TB = ROOT / "verification/sbi_s0_tb.cpp"

FW_SOURCES = [
    ROOT / "software/firmware/link.ld",
    ROOT / "software/firmware/entry.S",
    ROOT / "software/firmware/sbi_trap.S",
    ROOT / "software/firmware/sbi_core.c",
    ROOT / "software/firmware/sbi.h",
]

PAYLOAD_SOURCES = [
    ROOT / "software/firmware/s_payload_link.ld",
    ROOT / "software/firmware/s_payload_entry.S",
    ROOT / "software/firmware/s_payload.c",
]

PANIC_SOURCES = [
    ROOT / "software/firmware/panic_probe.S",
]

DTS_SOURCES = [
    ROOT / "software/dts/fursoy_s0.dts",
]

RTL = [
    ROOT / "rtl/core/fursoy_s0_l1i.sv",
    ROOT / "rtl/core/fursoy_s0_int_alu.sv",
    ROOT / "rtl/core/fursoy_s0_control.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_port.sv",
    ROOT / "rtl/core/fursoy_s0_csr.sv",
    ROOT / "rtl/core/fursoy_s0_pmp_check.sv",
    ROOT / "rtl/core/fursoy_s0_pmp.sv",
    ROOT / "rtl/core/fursoy_s0_tlb.sv",
    ROOT / "rtl/core/fursoy_s0_l1d.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
    ROOT / "rtl/platform/fursoy_s0_clint.sv",
    ROOT / "rtl/platform/fursoy_s0_plic.sv",
    ROOT / "rtl/platform/fursoy_s0_uart.sv",
    ROOT / "rtl/platform/fursoy_s0_soc.sv",
]

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def get_symbol(elf, name):
    nm = subprocess.run(["riscv64-unknown-elf-nm", "-n", str(elf)], cwd=ROOT, capture_output=True, text=True, timeout=20)
    if nm.returncode:
        raise RuntimeError("nm failed on " + str(elf) + ":\n" + nm.stderr)
    for line in nm.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == name:
            return int(parts[0], 16)
    raise RuntimeError(f"Symbol {name} not found in {elf}")

def main():
    files = [*RTL, *FW_SOURCES, *PAYLOAD_SOURCES, *PANIC_SOURCES, *DTS_SOURCES, TB, Path(__file__).resolve()]
    report = {
        "status": "fail",
        "scope": "minimal SBI firmware v1 focused verification (40 scenarios)",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in files},
    }

    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        fw_elf = BUILD / "sbi_firmware.elf"
        payload_elf = BUILD / "s_payload.elf"
        panic_elf = BUILD / "panic_probe.elf"
        dtb_file = ROOT / "build/dts/fursoy_s0.dtb"
        dtb_src = ROOT / "software/dts/fursoy_s0.dts"

        # 0. Compile Canonical DTB
        dtb_file.parent.mkdir(parents=True, exist_ok=True)
        b_dtb = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb_file), str(dtb_src)],
                               cwd=ROOT, capture_output=True, text=True, timeout=30)
        if b_dtb.returncode:
            raise RuntimeError("DTB build failed:\n" + b_dtb.stderr)

        # 1. Compile SBI Firmware
        gcc_fw = [
            "riscv64-unknown-elf-gcc", "-march=rv64ima_zicsr_zifencei", "-mabi=lp64",
            "-mcmodel=medany", "-mno-relax", "-nostdlib", "-nostartfiles", "-Wl,--no-relax",
            "-Wl,--build-id=none", "-T", str(ROOT / "software/firmware/link.ld"),
            str(ROOT / "software/firmware/entry.S"),
            str(ROOT / "software/firmware/sbi_trap.S"),
            str(ROOT / "software/firmware/sbi_core.c"),
            "-o", str(fw_elf),
        ]
        b = subprocess.run(gcc_fw, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if b.returncode:
            raise RuntimeError("Firmware build failed:\n" + b.stdout + b.stderr)

        # 2. Compile S-Mode Verification Payload
        gcc_payload = [
            "riscv64-unknown-elf-gcc", "-march=rv64ima_zicsr_zifencei", "-mabi=lp64",
            "-mcmodel=medany", "-mno-relax", "-nostdlib", "-nostartfiles", "-Wl,--no-relax",
            "-Wl,--build-id=none", "-T", str(ROOT / "software/firmware/s_payload_link.ld"),
            str(ROOT / "software/firmware/s_payload_entry.S"),
            str(ROOT / "software/firmware/s_payload.c"),
            "-o", str(payload_elf),
        ]
        b = subprocess.run(gcc_payload, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if b.returncode:
            raise RuntimeError("Payload build failed:\n" + b.stdout + b.stderr)

        # 3. Compile Panic Probe for Scenario 39
        gcc_panic = [
            "riscv64-unknown-elf-gcc", "-march=rv64ima_zicsr_zifencei", "-mabi=lp64",
            "-mcmodel=medany", "-mno-relax", "-nostdlib", "-nostartfiles", "-Wl,--no-relax",
            "-Wl,--build-id=none", "-T", str(ROOT / "software/firmware/link.ld"),
            str(ROOT / "software/firmware/panic_probe.S"),
            str(ROOT / "software/firmware/sbi_trap.S"),
            str(ROOT / "software/firmware/sbi_core.c"),
            "-o", str(panic_elf),
        ]
        b = subprocess.run(gcc_panic, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if b.returncode:
            raise RuntimeError("Panic probe build failed:\n" + b.stdout + b.stderr)

        # 4. Resolve symbols
        halt_loop_pc = hex(get_symbol(fw_elf, "halt_loop"))
        sbi_trap_entry_pc = hex(get_symbol(fw_elf, "sbi_trap_entry"))
        panic_halt_loop_pc = hex(get_symbol(panic_elf, "halt_loop"))

        # 5. Build Verilator Simulation
        v_cmd = [
            "verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
            "--top-module", "fursoy_s0_soc", "--Mdir", str(BUILD / "obj"),
            *map(str, RTL), str(TB),
        ]
        with (BUILD / "build.log").open("w", encoding="utf-8") as log:
            b = subprocess.run(v_cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120)
        if b.returncode:
            raise RuntimeError(f"Verilator build failed: {BUILD / 'build.log'}")

        # 6. Execute Simulation
        sim_cmd = [
            str(BUILD / "obj/Vfursoy_s0_soc"),
            str(fw_elf), str(payload_elf), str(panic_elf),
            halt_loop_pc, sbi_trap_entry_pc, panic_halt_loop_pc,
            str(dtb_file),
        ]
        sim = subprocess.run(sim_cmd, cwd=ROOT, capture_output=True, text=True, timeout=60)
        if sim.returncode:
            raise RuntimeError("Simulation failed:\n" + sim.stdout + sim.stderr)

        res = json.loads(sim.stdout)
        report.update(
            status="pass",
            firmware_sha256=sha(fw_elf),
            payload_sha256=sha(payload_elf),
            panic_probe_sha256=sha(panic_elf),
            dtb_sha256=sha(dtb_file),
            dtb_load_addr="0x82000000",
            simulation=res,
        )
        print(f"Minimal SBI firmware package DUT: pass ({res['scenarios_passed']}/40 scenarios, DTB loaded at 0x82000000)")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
