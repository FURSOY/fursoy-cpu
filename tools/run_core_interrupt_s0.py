"""Build and run integrated interrupt handling, prioritization and masking tests."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build/core_interrupt_s0"
REPORT_PATH = ROOT / "results/core-interrupt-s0.json"
TB_SOURCE = ROOT / "verification/core_interrupt_s0_tb.cpp"

RTL_SOURCES = [
    ROOT / "rtl/core/fursoy_s0_fetch.sv",
    ROOT / "rtl/core/fursoy_s0_int_alu.sv",
    ROOT / "rtl/core/fursoy_s0_control.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_port.sv",
    ROOT / "rtl/core/fursoy_s0_csr.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    report = {
        "status": "fail",
        "scope": "DUT integrated interrupt pending, masking, prioritization, trap entry and mret",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {
            str(p.relative_to(ROOT)): sha256(p)
            for p in [*RTL_SOURCES, TB_SOURCE, Path(__file__).resolve()]
        }
    }

    try:
        BUILD_DIR.mkdir(parents=True, exist_ok=True)
        verilator_cmd = [
            "verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
            "--top-module", "fursoy_s0_core",
            "--Mdir", str(BUILD_DIR),
            *map(str, RTL_SOURCES),
            str(TB_SOURCE)
        ]
        build_log = BUILD_DIR / "build.log"
        with build_log.open("w", encoding="utf-8") as f:
            proc = subprocess.run(verilator_cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT,
                                  timeout=120, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"Verilator build failed, see {build_log}")

        dut_exe = BUILD_DIR / "Vfursoy_s0_core"
        report["build_command"] = verilator_cmd

        sim_proc = subprocess.run([str(dut_exe)], cwd=ROOT, capture_output=True, text=True, timeout=30)
        if sim_proc.returncode != 0:
            raise RuntimeError(f"Simulation failed:\n{sim_proc.stdout}\n{sim_proc.stderr}")

        res = json.loads(sim_proc.stdout)
        report.update(status="pass", simulation=res)
        print(f"Slice-0 core interrupt handling DUT: pass ({res.get('tests', 0)} scenarios verified)")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
