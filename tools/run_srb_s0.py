"""Build and run the focused Store Refill Buffer (SRB) v1 architectural verification suite."""
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
    ROOT / "rtl/core/fursoy_s0_sb.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
]
TB = ROOT / "verification/srb_s0_tb.cpp"
BUILD = ROOT / "build/srb_s0"
OUTPUT = ROOT / "results/srb-s0.json"

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    report = {
        "status": "fail",
        "scope": "Store Refill Buffer (SRB) v1 (single-entry non-blocking store refill buffer, atomic victim invalidation, static latched way, suspended SB drain, full-line RAW interlock, unconditional install priority, 30 scenarios)",
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

        try:
            z = subprocess.run([str(BUILD / "Vfursoy_s0_core")], cwd=ROOT, capture_output=True, text=True, timeout=15)
            if z.returncode:
                raise RuntimeError("simulation failed:\n" + z.stdout + z.stderr)
            report.update(status="pass", stdout=z.stdout.strip())
            print(z.stdout.strip())
        except subprocess.TimeoutExpired as te:
            out = ""
            if te.stdout:
                out += te.stdout if isinstance(te.stdout, str) else te.stdout.decode('utf-8', errors='replace')
            if te.stderr:
                out += te.stderr if isinstance(te.stderr, str) else te.stderr.decode('utf-8', errors='replace')
            raise RuntimeError(f"simulation timed out (15s):\n{out}")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(report, indent=2), encoding="utf-8")
    if report["status"] != "pass":
        sys.exit(1)

if __name__ == "__main__":
    main()
