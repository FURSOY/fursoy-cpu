"""Record and check selected reset CSR fields in pinned Spike."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "software/baremetal"
BUILD = ROOT / "build/baremetal"
SPIKE = ROOT / "build/spike-build/spike"


def words(text):
    lines = text.splitlines() if text else []
    if len(lines) != 8 or any(not re.fullmatch(r"[0-9a-fA-F]{16}", line) for line in lines):
        return None
    return [int(line, 16) for line in lines]


def main():
    report = {"status": "fail", "scope": "Pinned Spike reset model; no Fursoy RTL reset claim",
              "observed_at_utc": datetime.now(timezone.utc).isoformat()}
    try:
        spike = json.loads((ROOT / "results/spike-build.json").read_text())
        binary_hash = hashlib.sha256(SPIKE.read_bytes()).hexdigest()
        if spike.get("status") != "built" or binary_hash != spike["binary_sha256"]:
            raise RuntimeError("Pinned Spike provenance mismatch")
        elf = BUILD / "reset_probe.elf"
        command = ["riscv64-unknown-elf-gcc", "-march=rv64i_zicsr_zifencei", "-mabi=lp64",
                   "-mcmodel=medany", "-mno-relax", "-msmall-data-limit=0", "-nostdlib",
                   "-nostartfiles", "-Wl,--no-relax", "-Wl,--build-id=none", "-Wl,--fatal-warnings",
                   "-T", str(SRC / "link.ld"), str(SRC / "reset_probe.S"), "-o", str(elf)]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
        (BUILD / "reset_probe-build.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode:
            raise RuntimeError("Reset probe build failed")
        sig = BUILD / "reset_probe.signature"
        sig.unlink(missing_ok=True)
        spike_command = [str(SPIKE), "--isa=RV64I_Zicsr_Zifencei", "--priv=m", "-m0x80000000:0x20000",
                         f"+signature={sig}", "+signature-granularity=8", str(elf)]
        result = subprocess.run(spike_command, cwd=ROOT, capture_output=True, text=True, timeout=10)
        observed = words(sig.read_text(encoding="utf-8") if sig.exists() else "")
        valid = (observed is not None and result.returncode == 0 and observed[:3] == [0x465552534f593031, 1, 1]
                 and (observed[3] & 0x1888) == 0x1800
                 and observed[4:] == [0, 0, 0, 0])
        report.update(build_command=command, spike_command=spike_command,
                      elf_sha256=hashlib.sha256(elf.read_bytes()).hexdigest(),
                      spike_sha256=binary_hash, signature=observed, matched=valid)
        if not valid:
            raise RuntimeError("Reset CSR signature mismatch")
        report["status"] = "pass"
        print("reset_probe: pass")
    except (OSError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    (ROOT / "results/reset-probe.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
