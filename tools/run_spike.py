"""Reference execution and negative cases; no CPU RTL or timing claims."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/baremetal"
SPIKE = ROOT / "build/spike-build/spike"


def classify(returncode, timed_out, text, expected):
    if timed_out:
        return "timeout"
    if text is None:
        return "missing_signature"
    lines = text.splitlines()
    if len(lines) != 8 or any(not re.fullmatch(r"[0-9a-fA-F]{16}", line) for line in lines):
        return "malformed_signature"
    words = [int(line, 16) for line in lines]
    if words != expected:
        return "signature_mismatch"
    return "pass" if returncode == 0 else "reported_failure"


def main():
    report = {"status": "fail", "scope": "Spike reference only; no DUT execution or PPA",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(), "cases": []}
    try:
        build = json.loads((ROOT / "results/baremetal-build.json").read_text())
        lock = json.loads((ROOT / "tools/spike-lock.json").read_text())
        spike_build = json.loads((ROOT / "results/spike-build.json").read_text())
        sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        if spike_build["status"] != "built" or spike_build["lock"] != lock or sha(SPIKE) != spike_build["binary_sha256"]:
            raise RuntimeError("Spike build provenance mismatch")
        elf = BUILD / "smoke.elf"
        if build["status"] != "build_verified" or sha(elf) != build["elf_sha256"]:
            raise RuntimeError("Rebuild the verified ELF first")
        for path, digest in build["source_sha256"].items():
            if sha(ROOT / path) != digest:
                raise RuntimeError(f"Stale ELF after source change: {path}")
        report.update(spike_commit=lock["commit"], spike_sha256=sha(SPIKE), elf_sha256=sha(elf),
                      runner_sha256=sha(Path(__file__).resolve()))
        probe = build["elf"]["symbols"]["ecall_probe"]
        expected = [0x465552534f593031, 1, 1, 0, 11, probe, 0, 1]
        # Pinned Spike ebreak.h reports the faulting PC in mtval.
        trap_failure = [0x465552534f593031, 1, 2, 100, 3, probe, probe, 0]
        def patched(name, address, replacement):
            data = bytearray(elf.read_bytes())
            for segment in build["elf"]["load_segments"]:
                relative = address - segment["address"]
                if 0 <= relative and relative + len(replacement) <= segment["filesz"]:
                    offset = segment["offset"] + relative
                    data[offset:offset + len(replacement)] = replacement
                    target = BUILD / f"{name}.elf"
                    target.write_bytes(data)
                    return target
            raise RuntimeError("Mutation target is not initialized ELF memory")
        cases = [
            ("success", elf, expected, "pass", 0, 10),
            ("unexpected_trap", patched("unexpected_trap", probe, bytes.fromhex("73001000")), trap_failure, "reported_failure", 1, 10),
            ("bad_signature", patched("bad_signature", 0x80010010, bytes(8)), expected, "signature_mismatch", 0, 10),
            ("hang", patched("hang", probe, bytes.fromhex("6f000000")), expected, "timeout", None, 2),
        ]
        for name, program, signature, want, want_code, seconds in cases:
            sigfile = BUILD / f"{name}.signature"
            # Only remove this runner's exact generated output, so stale success cannot pass.
            sigfile.unlink(missing_ok=True)
            command = [str(SPIKE), "--isa=RV64I_Zicsr_Zifencei", "--priv=m", "-m0x80000000:0x20000",
                       f"+signature={sigfile}", "+signature-granularity=8", str(program)]
            timeout, code = False, None
            with (BUILD / f"spike-{name}.log").open("w") as log:
                try:
                    result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                            timeout=seconds, check=False)
                    code = result.returncode
                except subprocess.TimeoutExpired:
                    timeout = True
            text = sigfile.read_text() if sigfile.exists() else None
            outcome = classify(code, timeout, text, signature)
            record = {"name": name, "command": command, "elf_sha256": sha(program),
                      "outcome": outcome, "expected": want, "returncode": code,
                      "signature": text, "matched": outcome == want and code == want_code}
            report["cases"].append(record)
            print(f"{name}: {outcome}", flush=True)
            if not record["matched"]:
                raise RuntimeError(f"Unexpected result for {name}; inspect build/baremetal/spike-{name}.log")
        report["status"] = "pass"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    target = ROOT / "results/spike-run.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
