"""Build and run the Linux boot integration suite on Fursoy Slice-0."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/linux_boot"
REPORT = ROOT / "results/linux-s0.json"
LOG_FILE = ROOT / "results/linux_boot.log"
TB = ROOT / "verification/linux_s0_tb.cpp"

RTL = [
    ROOT / "rtl/core/fursoy_s0_fetch.sv",
    ROOT / "rtl/core/fursoy_s0_int_alu.sv",
    ROOT / "rtl/core/fursoy_s0_control.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_port.sv",
    ROOT / "rtl/core/fursoy_s0_csr.sv",
    ROOT / "rtl/core/fursoy_s0_pmp_check.sv",
    ROOT / "rtl/core/fursoy_s0_pmp.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
    ROOT / "rtl/platform/fursoy_s0_clint.sv",
    ROOT / "rtl/platform/fursoy_s0_plic.sv",
    ROOT / "rtl/platform/fursoy_s0_uart.sv",
    ROOT / "rtl/platform/fursoy_s0_soc.sv",
]

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    report = {
        "status": "fail",
        "scope": "minimal Linux boot integration (Fursoy Slice-0)",
        "linux_version": "6.6.50",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {},
    }

    try:
        fw_elf = ROOT / "build/sbi_s0/sbi_firmware.elf"
        dtb_file = ROOT / "build/dts/fursoy_s0.dtb"
        dtb_src = ROOT / "software/dts/fursoy_s0.dts"
        kernel_img = ROOT / "build/linux-6.6.50/arch/riscv/boot/Image"
        config_file = ROOT / "software/linux/fursoy_s0_defconfig"

        # 1. Rebuild DTB if needed
        dtb_file.parent.mkdir(parents=True, exist_ok=True)
        b_dtb = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb_file), str(dtb_src)],
                               cwd=ROOT, capture_output=True, text=True, timeout=30)
        if b_dtb.returncode:
            raise RuntimeError("DTB compilation failed:\n" + b_dtb.stderr)

        # 2. Build SBI Firmware if needed
        if not fw_elf.exists():
            subprocess.run(["python3", "tools/run_sbi_s0.py"], cwd=ROOT, check=True, timeout=120)

        # 3. Check Kernel Image
        if not kernel_img.exists():
            raise RuntimeError(f"Kernel Image not found at {kernel_img}. Please build kernel first.")

        # Record hashes
        report["source_sha256"] = {
            "firmware_elf": sha(fw_elf),
            "dtb": sha(dtb_file),
            "kernel_image": sha(kernel_img),
            "defconfig": sha(config_file),
        }

        # 4. Build Verilator Simulation executable
        v_cmd = [
            "verilator", "--cc", "--exe", "--build", "-O3", "--assert", "-Wall", "-j", "4",
            "--top-module", "fursoy_s0_soc", "--Mdir", str(BUILD / "obj"),
            *map(str, RTL), str(TB),
        ]
        print("[RUNNER] Building Verilator simulation model...")
        with (BUILD / "verilator_build.log").open("w", encoding="utf-8") as log:
            b_v = subprocess.run(v_cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if b_v.returncode:
            raise RuntimeError(f"Verilator build failed. Check {BUILD / 'verilator_build.log'}")

        # 5. Execute Simulation
        max_cycles = sys.argv[1] if len(sys.argv) > 1 else "15000000"
        sim_cmd = [
            str(BUILD / "obj/Vfursoy_s0_soc"),
            str(fw_elf), str(kernel_img), str(dtb_file), max_cycles,
        ]
        print(f"[RUNNER] Launching Linux boot simulation (max_cycles={max_cycles})...")

        with LOG_FILE.open("w", encoding="utf-8") as log:
            import threading
            p = subprocess.Popen(sim_cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            stdout_lines = []
            stderr_lines = []

            def read_err():
                for eline in iter(p.stderr.readline, ""):
                    stderr_lines.append(eline)
                    sys.stderr.write(eline)
                    sys.stderr.flush()

            t_err = threading.Thread(target=read_err, daemon=True)
            t_err.start()

            while True:
                line = p.stdout.readline()
                if not line and p.poll() is not None:
                    break
                if line:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    log.write(line)
                    stdout_lines.append(line)
            p.wait()
            t_err.join(timeout=5)
            stderr_out = "".join(stderr_lines)
            log.write("\n--- STDERR ---\n" + stderr_out)

        full_output = "".join(stdout_lines)
        report["console_output"] = full_output
        report["stderr"] = stderr_out

        # Parse JSON block from stdout
        json_start = full_output.rfind("{\n  \"status\":")
        if json_start != -1:
            try:
                tb_report = json.loads(full_output[json_start:])
                report["tb_report"] = tb_report
                if tb_report.get("status") in ["pass", "earlycon_pass"]:
                    report["status"] = tb_report["status"]
            except Exception as e:
                report["json_parse_error"] = str(e)

        if "Kernel panic" in full_output:
            report["status"] = "panic"
        elif "[INIT]" in full_output or "Userspace active" in full_output:
            report["status"] = "pass"
            print("\n[RUNNER] SUCCESS: Linux boot reached userspace (/init)!")

        print(f"\n[RUNNER] Simulation exited. Status: {report['status']}")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
