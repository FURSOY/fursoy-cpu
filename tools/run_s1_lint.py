"""Run and record full Fursoy Slice-1 RTL lint with Verilator."""
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from s1_rtl_manifest import (
    ROOT,
    SOC_RTL,
    compute_path_manifest_sha256 as manifest_sha,
    sha256_file as sha,
)

OUTPUT = ROOT / "results/s1-lint.json"
RTL_FILES = SOC_RTL

def main():
    cmd = [
        "verilator", "--lint-only", "--assert", "-Wall",
        "-Irtl/core", "-Irtl/platform", "--top-module", "fursoy_s1_soc",
        *map(str, RTL_FILES)
    ]
    run = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)

    report = {
        "status": "pass" if run.returncode == 0 else "fail",
        "scope": "Fursoy Slice-1 Core + Platform SoC RTL (41 core + 4 platform files, Phase 1 Timing & Telemetry Hygiene)",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "command": cmd,
        "verilator_version": subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip(),
        "rtl_manifest_sha256": manifest_sha(RTL_FILES),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in RTL_FILES},
        "stdout": run.stdout,
        "stderr": run.stderr,
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    if run.returncode != 0:
        print("Slice-1 RTL lint FAIL:", file=sys.stderr)
        print(run.stdout + run.stderr, file=sys.stderr)
        return 1

    print("Slice-1 RTL lint: PASS (0 warnings, 0 errors)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
