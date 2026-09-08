"""Build and run the focused PLIC architectural testbench."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/platform/fursoy_s0_plic.sv"
TB = ROOT / "verification/plic_s0_tb.cpp"
BUILD = ROOT / "build/plic_s0"
REPORT = ROOT / "results/plic-s0.json"

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    report = {
        "status": "fail",
        "scope": "Fursoy CPU PLIC v1 focused architectural verification suite",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in (RTL, TB, Path(__file__).resolve())}
    }
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        command = [
            "verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
            "--top-module", "fursoy_s0_plic",
            "--Mdir", str(BUILD),
            str(RTL), str(TB)
        ]
        with (BUILD / "build.log").open("w", encoding="utf-8") as log:
            build = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=120, check=False)
        if build.returncode:
            raise RuntimeError(f"Build failed: {BUILD / 'build.log'}")

        sim = subprocess.run(
            [str(BUILD / "Vfursoy_s0_plic")],
            cwd=ROOT, capture_output=True, text=True, timeout=30, check=False
        )
        if sim.returncode:
            raise RuntimeError(f"Simulation failed:\n{sim.stdout}\n{sim.stderr}")

        sim_json = json.loads(sim.stdout)
        report.update(status="pass", build_command=command, simulation=sim_json)
        print(f"PLIC v1 focused architectural suite: pass ({sim_json.get('scenarios', 0)} scenarios, {sim_json.get('cycles', 0)} cycles)")
    except Exception as error:
        report["error"] = str(error)
        print(f"ERROR: {error}", file=sys.stderr)

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
