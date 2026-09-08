"""Build and check the FIFO pilot with Verilator; Linux/WSL only."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/common/fursoy_fifo.sv"
TB = ROOT / "verification/fifo_tb.cpp"
BUILD = ROOT / "build/fifo"
REPORT = ROOT / "results/fifo.json"


def run(command, log, timeout):
    with log.open("w", encoding="utf-8") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                timeout=timeout, check=False)
    return result.returncode, log.read_text(encoding="utf-8", errors="replace")


def build(width, depth, source, name, report):
    directory = BUILD / name
    directory.mkdir(parents=True, exist_ok=True)
    command = ["verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
               "--top-module", "fursoy_fifo", "--Mdir", str(directory),
               f"-GWIDTH={width}", f"-GDEPTH={depth}",
               "-CFLAGS", f"-DFIFO_WIDTH={width} -DFIFO_DEPTH={depth}", str(source), str(TB)]
    code, _ = run(command, directory / "build.log", 240)
    report["builds"].append({"name": name, "command": command, "exit_code": code,
                             "log": str((directory / "build.log").relative_to(ROOT))})
    if code:
        raise RuntimeError(f"Build failed: {directory / 'build.log'}")
    return directory / "Vfursoy_fifo"


def main():
    report = {"status": "fail", "observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "builds": [], "runs": [], "mutation": {"status": "not_run"},
              "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [RTL, TB, Path(__file__).resolve()]}}
    try:
        report["verilator"] = subprocess.check_output(["verilator", "--version"], text=True).strip()
        report["g++"] = subprocess.check_output(["g++", "--version"], text=True).splitlines()[0]
        for width, depth in [(8, 1), (32, 3), (8, 8), (32, 8)]:
            name = f"w{width}_d{depth}"
            executable = build(width, depth, RTL, name, report)
            for seed in [1, 42, 20260906]:
                code, output = run([str(executable), str(seed)], executable.parent / f"seed-{seed}.log", 30)
                if code:
                    raise RuntimeError(f"Simulation failed: {name}, seed {seed}: {output[-1500:]}")
                record = json.loads(output)
                if record["status"] != "pass":
                    raise RuntimeError("Simulation did not report pass")
                report["runs"].append({"width": width, "depth": depth, **record})
            print(f"{name}: 3 seeds passed", flush=True)
        mutant_dir = BUILD / "mutant_source"
        mutant_dir.mkdir(parents=True, exist_ok=True)
        mutant = mutant_dir / RTL.name
        source = RTL.read_text()
        original = "mem[write_ptr] <= in_data_i;"
        if source.count(original) != 1:
            raise RuntimeError("Mutation site changed; update sensitivity check")
        mutant.write_text(source.replace(original, "mem[write_ptr] <= in_data_i ^ WIDTH'(1);"))
        executable = build(32, 3, mutant, "mutant_w32_d3", report)
        code, output = run([str(executable), "1"], executable.parent / "mutation.log", 30)
        if code != 1 or "FIFO_MISMATCH" not in output or "check=data" not in output:
            raise RuntimeError("Data corruption was not detected by the scoreboard")
        report["mutation"] = {"status": "detected", "exit_code": code, "output": output.strip()}
        report["status"] = "pass"
        print("RTL data-corruption mutation: detected", flush=True)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    finally:
        REPORT.parent.mkdir(parents=True, exist_ok=True)
        REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
