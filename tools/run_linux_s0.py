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
    ROOT / "rtl/core/fursoy_s0_sb.sv",
    ROOT / "rtl/core/fursoy_s0_bpu.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
    ROOT / "rtl/platform/fursoy_s0_clint.sv",
    ROOT / "rtl/platform/fursoy_s0_plic.sv",
    ROOT / "rtl/platform/fursoy_s0_uart.sv",
    ROOT / "rtl/platform/fursoy_s0_soc.sv",
]

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def manifest_sha(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()

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
        kernel_dir = ROOT / "build/linux-6.6.50"
        config_file = ROOT / "software/linux/fursoy_s0_defconfig"
        busybox_bin = ROOT / "build/busybox/busybox-1.36.1/busybox"
        mem_stress_src = ROOT / "software/initramfs/mem_stress.c"
        mem_stress_bin = ROOT / "build/initramfs_root/bin/mem_stress"
        init_script = ROOT / "software/initramfs/init.sh"
        initramfs_cpio = ROOT / "build/initramfs.cpio"
        rootfs = ROOT / "build/initramfs_root"

        # 1. Rebuild DTB if needed
        dtb_file.parent.mkdir(parents=True, exist_ok=True)
        b_dtb = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb_file), str(dtb_src)],
                               cwd=ROOT, capture_output=True, text=True, timeout=30)
        if b_dtb.returncode:
            raise RuntimeError("DTB compilation failed:\n" + b_dtb.stderr)

        # 2. Build SBI Firmware if needed
        if not fw_elf.exists():
            subprocess.run(["python3", "tools/run_sbi_s0.py"], cwd=ROOT, check=True, timeout=120)

        # 3. Check / Build BusyBox if needed
        if not busybox_bin.exists():
            print("[RUNNER] Building BusyBox 1.36.1...")
            subprocess.run(["bash", str(ROOT / "scratch/build_busybox.sh")], cwd=ROOT, check=True, timeout=300)

        # 4. Assemble rootfs and generate initramfs.cpio if needed
        rebuild_cpio = False
        if not initramfs_cpio.exists() or not mem_stress_bin.exists():
            rebuild_cpio = True
        elif mem_stress_src.stat().st_mtime > mem_stress_bin.stat().st_mtime:
            rebuild_cpio = True
        elif init_script.stat().st_mtime > initramfs_cpio.stat().st_mtime:
            rebuild_cpio = True

        if rebuild_cpio:
            print("[RUNNER] Assembling initramfs rootfs and generating cpio archive...")
            subprocess.run(["bash", str(ROOT / "scratch/prepare_initramfs.sh")], cwd=ROOT, check=True, timeout=120)

        # Ensure usr/initramfs_data.cpio is present and up to date in kernel tree
        kernel_cpio = kernel_dir / "usr/initramfs_data.cpio"
        if not kernel_cpio.exists() or initramfs_cpio.stat().st_mtime > kernel_cpio.stat().st_mtime:
            import shutil
            shutil.copy2(str(initramfs_cpio), str(kernel_cpio))

        # 5. Check / Rebuild Kernel Image
        if not kernel_img.exists() or kernel_cpio.stat().st_mtime > kernel_img.stat().st_mtime:
            print("[RUNNER] Rebuilding Linux kernel Image with embedded initramfs...")
            k_cmd = ["make", "-C", str(kernel_dir), "ARCH=riscv", "CROSS_COMPILE=riscv64-linux-gnu-", "-j4", "Image"]
            k_run = subprocess.run(k_cmd, cwd=ROOT, capture_output=True, text=True, timeout=300)
            if k_run.returncode:
                raise RuntimeError("Kernel build failed:\n" + k_run.stderr)

        # Record hashes and provenance
        report["source_sha256"] = {
            "firmware_elf": sha(fw_elf),
            "dtb": sha(dtb_file),
            "kernel_image": sha(kernel_img),
            "defconfig": sha(config_file),
            "initramfs_cpio": sha(initramfs_cpio),
            "busybox_bin": sha(busybox_bin),
            "mem_stress_bin": sha(mem_stress_bin),
            "init_script": sha(init_script),
        }
        report["rtl_source_sha256"] = {str(p.relative_to(ROOT)): sha(p) for p in RTL}
        report["rtl_manifest_sha256"] = manifest_sha(RTL)
        report["busybox_version"] = "1.36.1"

        # 6. Build Verilator Simulation executable
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

        # 7. Execute Simulation
        max_cycles = sys.argv[1] if len(sys.argv) > 1 else "210000000"
        sim_cmd = [
            str(BUILD / "obj/Vfursoy_s0_soc"),
            str(fw_elf), str(kernel_img), str(dtb_file), max_cycles,
        ]
        print(f"[RUNNER] Launching Linux BusyBox userspace simulation (max_cycles={max_cycles})...")

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
                report["cycles"] = tb_report.get("cycles")
                report["commits"] = tb_report.get("commits")
                report["timer_interrupts"] = tb_report.get("mtip_count")
                report["seen_userspace_begin"] = tb_report.get("seen_userspace_begin", False)
                report["seen_userspace_pass"] = tb_report.get("seen_userspace_pass", False)
                report["seen_userspace_fail"] = tb_report.get("seen_userspace_fail", False)
                if tb_report.get("status") in ["pass", "earlycon_pass", "userspace_fail", "init_reached"]:
                    report["status"] = tb_report["status"]
            except Exception as e:
                report["json_parse_error"] = str(e)

        if "Kernel panic" in full_output:
            report["status"] = "panic"
            report["fatal_halt"] = True
        else:
            report["fatal_halt"] = False

        if "FURSOY_USERSPACE_PASS" in full_output and "FURSOY_USERSPACE_FAIL" not in full_output and report["status"] != "panic":
            report["status"] = "pass"
            print("\n========================================================")
            print("[RUNNER] SUCCESS: Linux BusyBox userspace smoke & memory suite PASSED!")
            print("========================================================")
        elif "FURSOY_USERSPACE_FAIL" in full_output:
            report["status"] = "fail"
            print("\n[RUNNER] FAILURE: Userspace smoke test failed.")

        print(f"\n[RUNNER] Simulation exited. Status: {report['status']}")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
