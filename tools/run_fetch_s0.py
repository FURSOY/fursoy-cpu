"""Build and run the Slice-0 reset/fetch DUT test with Verilator."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/core/fursoy_s0_fetch.sv"
TB = ROOT / "verification/fetch_s0_tb.cpp"
BUILD = ROOT / "build/fetch_s0"
REPORT = ROOT / "results/fetch-s0.json"


def main():
    report = {"status": "fail", "scope": "DUT fetch transport only; no ISA retirement",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (RTL, TB, Path(__file__).resolve())}}
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        build_command = ["verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
                         "--top-module", "fursoy_s0_fetch", "--Mdir", str(BUILD), str(RTL), str(TB)]
        log = BUILD / "build.log"
        with log.open("w", encoding="utf-8") as output:
            built = subprocess.run(build_command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                   timeout=120, check=False)
        if built.returncode:
            raise RuntimeError(f"Build failed: {log}")
        executable = BUILD / "Vfursoy_s0_fetch"
        run = subprocess.run([str(executable)], cwd=ROOT, capture_output=True, text=True, timeout=20, check=False)
        if run.returncode:
            raise RuntimeError(f"Simulation failed: {run.stderr.strip()}")
        result = json.loads(run.stdout)
        if result.get("status") != "pass":
            raise RuntimeError("Simulation did not report pass")
        report.update({"build_command": build_command, "simulation": result, "status": "pass"})
        print("Slice-0 fetch DUT: pass")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
