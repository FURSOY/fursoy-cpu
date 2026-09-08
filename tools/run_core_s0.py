"""Build and run the first end-to-end Slice-0 core trace test."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = [ROOT / "rtl/core/fursoy_s0_fetch.sv", ROOT / "rtl/core/fursoy_s0_int_alu.sv", ROOT / "rtl/core/fursoy_s0_control.sv", ROOT / "rtl/core/fursoy_s0_lsu_decode.sv", ROOT / "rtl/core/fursoy_s0_lsu_port.sv", ROOT / "rtl/core/fursoy_s0_csr.sv", ROOT / "rtl/core/fursoy_s0_mmu.sv", ROOT / "rtl/core/fursoy_s0_core.sv"]
TB = ROOT / "verification/core_s0_tb.cpp"
BUILD = ROOT / "build/core_s0"
REPORT = ROOT / "results/core-s0.json"


def main():
    report = {"status": "fail", "scope": "DUT ALU-only in-order core; no memory/branch/CSR execution",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in [*RTL, TB, Path(__file__).resolve()]}}
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        command = ["verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
                   "--top-module", "fursoy_s0_core", "--Mdir", str(BUILD), *map(str, RTL), str(TB)]
        with (BUILD / "build.log").open("w", encoding="utf-8") as log:
            built = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120, check=False)
        if built.returncode:
            raise RuntimeError(f"Build failed: {BUILD / 'build.log'}")
        run = subprocess.run([str(BUILD / "Vfursoy_s0_core")], cwd=ROOT, capture_output=True, text=True, timeout=20, check=False)
        if run.returncode:
            raise RuntimeError(f"Simulation failed: {run.stderr.strip()}")
        source = RTL[-1].read_text(encoding="utf-8")
        original = "pc_q <= fetched_pc + 64'd4;"
        if source.count(original) < 1:
            raise RuntimeError("Mutation site changed; update sensitivity check")
        mutant = BUILD / "mutant" / RTL[-1].name
        mutant.parent.mkdir(parents=True, exist_ok=True)
        mutant.write_text(source.replace(original, "pc_q <= fetched_pc + 64'd8;", 1), encoding="utf-8")
        mutant_dir = BUILD / "mutant_build"
        mutant_command = ["verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
                          "--top-module", "fursoy_s0_core", "--Mdir", str(mutant_dir),
                          *map(str, RTL[:-1]), str(mutant), str(TB)]
        with (mutant_dir.parent / "mutant-build.log").open("w", encoding="utf-8") as log:
            built_mutant = subprocess.run(mutant_command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                          timeout=120, check=False)
        if built_mutant.returncode:
            raise RuntimeError("Mutant build failed")
        mutant_run = subprocess.run([str(mutant_dir / "Vfursoy_s0_core")], cwd=ROOT,
                                    capture_output=True, text=True, timeout=20, check=False)
        if mutant_run.returncode != 1 or "CORE_S0_MISMATCH" not in mutant_run.stderr:
            raise RuntimeError("PC increment mutation escaped the test")
        report.update({"build_command": command, "simulation": json.loads(run.stdout),
                       "mutation": "detected", "status": "pass"})
        print("Slice-0 in-order core DUT: pass; PC increment mutation: detected")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
