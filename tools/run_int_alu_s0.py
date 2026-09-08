"""Build, test and mutation-check the Slice-0 RV64I integer ALU DUT block."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/core/fursoy_s0_int_alu.sv"
TB = ROOT / "verification/int_alu_s0_tb.cpp"
BUILD = ROOT / "build/int_alu_s0"
REPORT = ROOT / "results/int-alu-s0.json"


def build(source, directory):
    directory.mkdir(parents=True, exist_ok=True)
    command = ["verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
               "--top-module", "fursoy_s0_int_alu", "--Mdir", str(directory), str(source), str(TB)]
    with (directory / "build.log").open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                timeout=120, check=False)
    if result.returncode:
        raise RuntimeError(f"Build failed: {directory / 'build.log'}")
    return command, directory / "Vfursoy_s0_int_alu"


def execute(executable):
    result = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True, timeout=20, check=False)
    return result.returncode, result.stdout, result.stderr


def main():
    report = {"status": "fail", "scope": "DUT integer ALU only; no pipeline or trap CSR",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (RTL, TB, Path(__file__).resolve())}}
    try:
        command, executable = build(RTL, BUILD / "dut")
        code, stdout, stderr = execute(executable)
        if code or json.loads(stdout).get("status") != "pass":
            raise RuntimeError(f"DUT simulation failed: {stderr.strip()}")
        original = "rd_data_o = rs1_i + immediate_i;"
        source = RTL.read_text(encoding="utf-8")
        if source.count(original) != 1:
            raise RuntimeError("Mutation site changed; update sensitivity check")
        mutant = BUILD / "mutant" / RTL.name
        mutant.parent.mkdir(parents=True, exist_ok=True)
        mutant.write_text(source.replace(original, "rd_data_o = rs1_i - immediate_i;"), encoding="utf-8")
        _, mutant_executable = build(mutant, BUILD / "mutant_build")
        mutant_code, mutant_stdout, mutant_stderr = execute(mutant_executable)
        if mutant_code != 1 or "INT_ALU_S0_MISMATCH" not in mutant_stderr:
            raise RuntimeError("ADDI arithmetic mutation escaped the test")
        report.update({"build_command": command, "simulation": json.loads(stdout),
                       "mutation": "detected", "status": "pass"})
        print("Slice-0 integer ALU DUT: pass; ADDI mutation: detected")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
