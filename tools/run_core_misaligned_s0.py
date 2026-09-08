"""Build and run core load/store-address-misaligned trap tests."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = [ROOT / "rtl/core/fursoy_s0_fetch.sv", ROOT / "rtl/core/fursoy_s0_int_alu.sv",
       ROOT / "rtl/core/fursoy_s0_control.sv", ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
       ROOT / "rtl/core/fursoy_s0_lsu_port.sv", ROOT / "rtl/core/fursoy_s0_csr.sv",
       ROOT / "rtl/core/fursoy_s0_mmu.sv",
       ROOT / "rtl/core/fursoy_s0_core.sv"]
TB = ROOT / "verification/core_misaligned_s0_tb.cpp"
BUILD = ROOT / "build/core_misaligned_s0"
REPORT = ROOT / "results/core-misaligned-s0.json"

def main():
    report = {"status": "fail", "scope": "DUT misaligned LW/SW trap integration",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [*RTL, TB, Path(__file__).resolve()]}}
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        command = ["verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
                   "--top-module", "fursoy_s0_core", "--Mdir", str(BUILD), *map(str, RTL), str(TB)]
        with (BUILD / "build.log").open("w", encoding="utf-8") as log:
            built = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   timeout=120, check=False)
        if built.returncode:
            raise RuntimeError(f"Build failed: {BUILD / 'build.log'}")
        run = subprocess.run([str(BUILD / "Vfursoy_s0_core")], cwd=ROOT,
                             capture_output=True, text=True, timeout=20, check=False)
        if run.returncode:
            raise RuntimeError(f"Simulation failed: {run.stderr.strip()}")
        report.update({"status": "pass", "build_command": command, "simulation": json.loads(run.stdout)})
        print("Slice-0 core misaligned load/store traps: pass")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
