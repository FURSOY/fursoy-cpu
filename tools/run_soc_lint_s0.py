"""Run and record the dedicated full Slice-0 SoC RTL lint."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "results/soc-lint-s0.json"
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

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def manifest_sha(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()

def main():
    cmd = ["verilator", "--lint-only", "--assert", "-Wall", "-Irtl/core", "-Irtl/platform",
           "--top-module", "fursoy_s0_soc", *map(str, RTL)]
    run = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    report = {
        "status": "pass" if run.returncode == 0 else "fail",
        "scope": "full Fursoy Slice-0 production SoC RTL",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "command": cmd,
        "verilator_version": subprocess.run(["verilator", "--version"], capture_output=True, text=True).stdout.strip(),
        "rtl_manifest_sha256": manifest_sha(RTL),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in RTL},
        "stdout": run.stdout,
        "stderr": run.stderr,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if run.returncode:
        print(run.stdout + run.stderr, file=sys.stderr)
    else:
        print("Full Slice-0 SoC RTL lint: PASS")
    return run.returncode

if __name__ == "__main__":
    sys.exit(main())
