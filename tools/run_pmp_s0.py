"""Build and run the focused PMP verification suite."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RTL = [
    ROOT / "rtl/core/fursoy_s0_l1i.sv",
    ROOT / "rtl/core/fursoy_s0_int_alu.sv",
    ROOT / "rtl/core/fursoy_s0_control.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_port.sv",
    ROOT / "rtl/core/fursoy_s0_csr.sv",
    ROOT / "rtl/core/fursoy_s0_tlb.sv",
    ROOT / "rtl/core/fursoy_s0_l1d.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
]
EXTRA_SOURCES = [
    ROOT / "rtl/core/fursoy_s0_pmp_check.sv",
    ROOT / "rtl/core/fursoy_s0_pmp.sv",
]
TB = ROOT / "verification/pmp_s0_tb.cpp"
BUILD = ROOT / "build/pmp_s0"
REPORT = ROOT / "results/pmp-s0.json"


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    report = {
        "status": "fail",
        "scope": "focused PMP CSR, WARL, lock, checker, Bare/Sv39 MMU, PTW and store suppression verification",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {
            str(path.relative_to(ROOT)): sha(path)
            for path in [*RTL, *EXTRA_SOURCES, TB, Path(__file__).resolve()]
        },
    }
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        command = [
            "verilator",
            "--cc",
            "--exe",
            "--build",
            "--assert",
            "-Wall",
            "-j",
            "2",
            "--top-module",
            "fursoy_s0_core",
            "-GRESET_MTVEC=64'h0000000080000300",
            "--Mdir",
            str(BUILD),
            *map(str, RTL),
            str(TB),
        ]
        with (BUILD / "build.log").open("w", encoding="utf-8") as log:
            built = subprocess.run(
                command,
                cwd=ROOT,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=120,
                check=False,
            )
        if built.returncode:
            raise RuntimeError(f"Build failed: {BUILD / 'build.log'}")
        run = subprocess.run(
            [str(BUILD / "Vfursoy_s0_core")],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if run.returncode:
            raise RuntimeError(f"simulation failed:\n{run.stdout}\n{run.stderr}")
        report.update(
            status="pass",
            build_command=command,
            simulation=json.loads(run.stdout),
        )
        print("Focused PMP verification DUT: pass")
    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
