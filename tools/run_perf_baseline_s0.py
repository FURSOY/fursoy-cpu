"""Build and run the Pre-Optimization Performance Baseline suite on Fursoy Slice-0."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/perf_baseline_s0"
REPORT = ROOT / "results/perf-l1d-er-s0.json"
LOG_FILE = ROOT / "results/perf_l1d_er.log"
BASELINE_LOG_FILE = ROOT / "results/perf_l1d_er_ab_baseline.log"
TB = ROOT / "verification/perf_baseline_s0_tb.cpp"

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
        "scope": "L1D Load Critical-Word Early Restart (L1D-ER v1) performance profiling (Fursoy Slice-0)",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "provenance": {},
    }

    try:
        fw_elf = ROOT / "build/sbi_s0/sbi_firmware.elf"
        dtb_file = ROOT / "build/dts/fursoy_s0.dtb"
        dtb_src = ROOT / "software/dts/fursoy_s0.dts"
        kernel_img = ROOT / "build/linux-6.6.50/arch/riscv/boot/Image"
        config_file = ROOT / "software/linux/fursoy_s0_defconfig"
        init_bin = ROOT / "build/initramfs/init"
        init_src = ROOT / "software/initramfs/init.c"

        # 1. Compile userspace init if needed
        init_bin.parent.mkdir(parents=True, exist_ok=True)
        if not init_bin.exists() or init_src.stat().st_mtime > init_bin.stat().st_mtime:
            print("[RUNNER] Compiling userspace init workload...")
            subprocess.run([
                "riscv64-linux-gnu-gcc", "-O2", "-static", "-nostdlib",
                "-march=rv64ima", "-mabi=lp64", "-fno-builtin",
                str(init_src), "-o", str(init_bin)
            ], cwd=ROOT, check=True)

        # 2. Rebuild DTB if needed
        dtb_file.parent.mkdir(parents=True, exist_ok=True)
        b_dtb = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb_file), str(dtb_src)],
                               cwd=ROOT, capture_output=True, text=True, timeout=30)
        if b_dtb.returncode:
            raise RuntimeError("DTB compilation failed:\n" + b_dtb.stderr)

        # 3. Build SBI Firmware if needed
        if not fw_elf.exists():
            subprocess.run(["python3", "tools/run_sbi_s0.py"], cwd=ROOT, check=True, timeout=120)

        # 4. Check Kernel Image
        if not kernel_img.exists():
            raise RuntimeError(f"Kernel Image not found at {kernel_img}. Please build kernel first.")

        # Query Git commit hash
        try:
            git_commit = subprocess.run(["git", "rev-parse", "HEAD"],
                                        cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        except Exception:
            git_commit = "unknown"

        # Query tool versions
        verilator_ver = subprocess.run(["verilator", "--version"],
                                       capture_output=True, text=True).stdout.strip()
        gcc_ver = subprocess.run(["riscv64-linux-gnu-gcc", "--version"],
                                 capture_output=True, text=True).stdout.splitlines()[0]

        # Record provenance
        report["provenance"] = {
            "git_commit": git_commit,
            "linux_version": "6.6.50",
            "kernel_image_sha256": sha(kernel_img),
            "defconfig_sha256": sha(config_file),
            "firmware_elf_sha256": sha(fw_elf),
            "dtb_sha256": sha(dtb_file),
            "workload_init_sha256": sha(init_bin),
            "verilator_version": verilator_ver,
            "toolchain_version": gcc_ver,
            "rtl_source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in RTL},
            "rtl_manifest_sha256": manifest_sha(RTL),
            "testbench_sha256": sha(TB),
            "runner_sha256": sha(Path(__file__).resolve()),
            "memory_timing_model": "same compiled testbench instance and fixed configuration for both A/B runs",
        }

        # 5. Build Verilator Simulation executable
        v_cmd = [
            "verilator", "--cc", "--exe", "--build", "-O3", "--assert", "-Wall", "-j", "4",
            "--top-module", "fursoy_s0_soc", "--Mdir", str(BUILD / "obj"),
            *map(str, RTL), str(TB),
        ]
        print("[RUNNER] Building Verilator performance simulation model...")
        with (BUILD / "verilator_build.log").open("w", encoding="utf-8") as log:
            b_v = subprocess.run(v_cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        if b_v.returncode:
            raise RuntimeError(f"Verilator build failed. Check {BUILD / 'verilator_build.log'}")

        # 6. Execute an identical-artifact/configuration A/B pair using one
        # compiled model. The only difference is the synthesis-excluded ER
        # enable control inside the testbench.
        max_cycles = sys.argv[1] if len(sys.argv) > 1 else "220000000"
        def execute(label, disable_er, log_path):
            import threading
            sim_cmd = [
                str(BUILD / "obj/Vfursoy_s0_soc"),
                str(fw_elf), str(kernel_img), str(dtb_file), max_cycles,
                "1" if disable_er else "0",
            ]
            print(f"[RUNNER] Launching {label} simulation (max_cycles={max_cycles})...")
            log = log_path.open("w", encoding="utf-8")
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
            log.close()
            if p.returncode:
                raise RuntimeError(f"{label} simulation exited {p.returncode}")
            full_output = "".join(stdout_lines)
            marker = "--- PERF JSON REPORT ---"
            idx = full_output.find(marker)
            if idx < 0:
                raise RuntimeError(f"{label} JSON marker missing")
            data = json.loads(full_output[idx + len(marker):].strip())
            if data.get("status") != "pass":
                raise RuntimeError(f"{label} workload failed")
            return data, full_output[-4000:]

        baseline_data, baseline_tail = execute("L1D-ER-disabled A/B baseline", True, BASELINE_LOG_FILE)
        enabled_data, enabled_tail = execute("L1D-ER-enabled candidate", False, LOG_FILE)
        b = baseline_data["full_execution"]
        n = enabled_data["full_execution"]
        cycle_delta = int(n["total_cycles"]) - int(b["total_cycles"])
        report.update(
            status="pass",
            baseline_results=baseline_data,
            benchmark_results=enabled_data,
            console_output_tail=enabled_tail,
            baseline_console_output_tail=baseline_tail,
            comparison={
                "artifact_identity": "exact_match",
                "same_compiled_simulator": True,
                "only_control_difference": "synthesis-excluded verification_disable_er",
                "baseline_cycles": b["total_cycles"],
                "baseline_commits": b["committed_instructions"],
                "baseline_ipc": b["ipc"],
                "baseline_cpi": b["cpi"],
                "l1d_er_cycles": n["total_cycles"],
                "l1d_er_commits": n["committed_instructions"],
                "l1d_er_ipc": n["ipc"],
                "l1d_er_cpi": n["cpi"],
                "cycle_delta": cycle_delta,
                "cycles_saved": -cycle_delta,
                "cycle_change_pct": 100.0 * cycle_delta / float(b["total_cycles"]),
                "baseline_mtip_count": b["platform_events"]["mtip_count"],
                "l1d_er_mtip_count": n["platform_events"]["mtip_count"],
                "mtip_count_delta": int(n["platform_events"]["mtip_count"]) - int(b["platform_events"]["mtip_count"]),
                "er_events": n["l1d"]["l1d_er_events"],
                "gross_potential_cycles": n["l1d"]["l1d_er_saved_cycles_total"],
                "average_potential_cycles_per_event": (float(n["l1d"]["l1d_er_saved_cycles_total"]) /
                                                       float(n["l1d"]["l1d_er_events"])) if n["l1d"]["l1d_er_events"] else 0.0,
            },
        )
        print(f"\n[RUNNER] Identical-artifact A/B completed. Cycles saved: {-cycle_delta}")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
