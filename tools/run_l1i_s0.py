"""Build and run the focused L1 Instruction Cache (L1I) v1 architectural verification suite."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib, json, subprocess, sys

ROOT = Path(__file__).resolve().parents[1]
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
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
]
TB = ROOT / "verification/l1i_s0_tb.cpp"
BUILD = ROOT / "build/l1i_s0"
OUTPUT = ROOT / "results/l1i-s0.json"

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    report = {
        "status": "fail",
        "scope": "L1 Instruction Cache (L1I) v1 (16 KiB 4-way 64B line, Tree-PLRU, 8-beat refill, stale suppression, FENCE.I, PMP, VIPT, 1-cycle hit)",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in [*RTL, TB, Path(__file__).resolve()]}
    }
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        v_cmd = [
            "verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "4",
            "-Irtl/core", "-Irtl/platform",
            "--top-module", "fursoy_s0_core", "--Mdir", str(BUILD),
            *map(str, RTL), str(TB)
        ]
        with (BUILD / "build.log").open("w", encoding="utf-8") as l:
            z = subprocess.run(v_cmd, cwd=ROOT, stdout=l, stderr=subprocess.STDOUT, timeout=180)
        if z.returncode:
            raise RuntimeError(f"build failed: {BUILD / 'build.log'}")

        z = subprocess.run([str(BUILD / "Vfursoy_s0_core")], cwd=ROOT, capture_output=True, text=True, timeout=60)
        if z.returncode:
            raise RuntimeError("simulation failed:\n" + z.stdout + z.stderr)

        report.update(status="pass", stdout=z.stdout.strip())
        print(z.stdout.strip())

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
