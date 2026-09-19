"""Run and record full Fursoy Slice-1 RTL lint with Verilator."""
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "results/s1-lint.json"

RTL_FILES = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
    ROOT / "rtl/core/fursoy_s1_prf.sv",
    ROOT / "rtl/core/fursoy_s1_alu.sv",
    ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
    ROOT / "rtl/core/fursoy_s1_multiplier.sv",
    ROOT / "rtl/core/fursoy_s1_divider.sv",
    ROOT / "rtl/core/fursoy_s1_port1_buffers.sv",
    ROOT / "rtl/core/fursoy_s1_int_iq.sv",
    ROOT / "rtl/core/fursoy_s1_agu.sv",
    ROOT / "rtl/core/fursoy_s1_mem_iq.sv",
    ROOT / "rtl/core/fursoy_s1_trt.sv",
    ROOT / "rtl/core/fursoy_s1_lsu_queues.sv",
    ROOT / "rtl/core/fursoy_s1_l1d.sv",
    ROOT / "rtl/core/fursoy_s1_lsu.sv",
    ROOT / "rtl/core/fursoy_s1_backend.sv",
    ROOT / "rtl/core/fursoy_s1_core.sv",
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest_sha(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()

def main():
    cmd = [
        "verilator", "--lint-only", "--assert", "-Wall",
        "-Irtl/core", "--top-module", "fursoy_s1_core",
        *map(str, RTL_FILES)
    ]
    run = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)

    report = {
        "status": "pass" if run.returncode == 0 else "fail",
        "scope": "Fursoy Slice-1 Milestone 2 Core RTL (Substrate + Backend)",
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
