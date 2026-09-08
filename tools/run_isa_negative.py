"""Run slice-0 illegal CSR/opcode probes in pinned Spike; no DUT claim."""

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


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def signature(text):
    lines = text.splitlines() if text else []
    if len(lines) != 8 or any(not re.fullmatch(r"[0-9a-fA-F]{16}", line) for line in lines):
        return None
    return [int(line, 16) for line in lines]


def build(name):
    elf = BUILD / f"{name}.elf"
    command = ["riscv64-unknown-elf-gcc", "-march=rv64i_zicsr_zifencei", "-mabi=lp64",
               "-mcmodel=medany", "-mno-relax", "-msmall-data-limit=0", "-ffreestanding",
               "-fno-builtin", "-fno-pic", "-fno-pie", "-fno-stack-protector",
               "-fno-asynchronous-unwind-tables", "-nostdlib", "-nostartfiles", "-O2",
               "-Wall", "-Wextra", "-Werror", "-Wl,--no-relax", "-Wl,--build-id=none",
               "-Wl,--fatal-warnings", "-T", str(SRC / "link.ld"), str(SRC / "start.S"),
               str(SRC / f"{name}.S"), "-o", str(elf)]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)
    (BUILD / f"{name}-build.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Build failed: {name}")
    output = subprocess.check_output(["riscv64-unknown-elf-objdump", "-d", str(elf)], text=True)
    match = re.search(r"^([0-9a-f]+) <" + re.escape(name) + r">:\n\s*[0-9a-f]+:\s*([0-9a-f]{8})", output, re.M)
    if not match:
        raise RuntimeError(f"Cannot locate probe instruction: {name}")
    symbols = subprocess.check_output(["riscv64-unknown-elf-nm", "-n", str(elf)], text=True)
    ecall = re.search(r"^([0-9a-f]+)\s+\w\s+ecall_probe$", symbols, re.M)
    if not ecall:
        raise RuntimeError("Cannot locate ECALL probe")
    return elf, int(match.group(1), 16), int(match.group(2), 16), int(ecall.group(1), 16), command


def main():
    report = {"status": "fail", "scope": "Pinned Spike reference; no Fursoy RTL execution",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(), "cases": []}
    try:
        spike = json.loads((ROOT / "results/spike-build.json").read_text())
        if spike.get("status") != "built" or sha(SPIKE) != spike["binary_sha256"]:
            raise RuntimeError("Pinned Spike provenance mismatch")
        for name, expected_kind in [("csr_write_probe", "illegal"), ("illegal_probe", "illegal"),
                                    ("csr_suppress_probe", "success"), ("fence_i_probe", "success")]:
            elf, pc, instruction, ecall, command = build(name)
            sig = BUILD / f"{name}.signature"
            sig.unlink(missing_ok=True)
            spike_command = [str(SPIKE), "--isa=RV64I_Zicsr_Zifencei", "--priv=m", "-m0x80000000:0x20000",
                             f"+signature={sig}", "+signature-granularity=8", str(elf)]
            process = subprocess.run(spike_command, cwd=ROOT, capture_output=True, text=True, timeout=10)
            text = sig.read_text(encoding="utf-8") if sig.exists() else ""
            observed = signature(text)
            # Startup has already handled exactly one ECALL before this probe.
            expected = ([0x465552534f593031, 1, 2, 100, 2, pc, instruction, 1]
                        if expected_kind == "illegal"
                        else [0x465552534f593031, 1, 1, 0, 11, ecall, 0, 1])
            expected_exit = 1 if expected_kind == "illegal" else 0
            match = process.returncode == expected_exit and observed == expected
            report["cases"].append({"name": name, "build_command": command, "spike_command": spike_command,
                                    "elf_sha256": sha(elf), "probe_pc": pc, "instruction": instruction,
                                    "returncode": process.returncode, "signature": observed,
                                    "expected": expected, "matched": match})
            print(f"{name}: {'pass' if match else 'fail'}", flush=True)
            if not match:
                raise RuntimeError(f"Unexpected result: {name}")
        report["status"] = "pass"
    except (OSError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    (ROOT / "results/isa-negative.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
