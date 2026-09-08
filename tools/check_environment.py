"""Read-only tool probes; a report is evidence, not a dependency lockfile."""

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
from datetime import datetime, timezone


PROFILES = {
    "bootstrap": ["python3", "git", "gcc", "g++", "make"],
    "rtl": ["python3", "g++", "make", "verilator"],
    "isa": ["riscv64-unknown-elf-gcc", "spike"],
    "physical": ["yosys", "openroad"],
}
COMMANDS = {
    name: [name, "--version"]
    for name in {tool for profile in PROFILES.values() for tool in profile}
}
COMMANDS.update({"spike": ["spike", "--help"], "yosys": ["yosys", "-V"]})


def probe(argv, timeout=10):
    executable = shutil.which(argv[0])
    if executable is None:
        return {"status": "missing", "command": argv}
    result = {"command": argv, "path": executable}
    try:
        process = subprocess.run(
            [executable, *argv[1:]], capture_output=True, text=True,
            errors="replace", timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired:
        return {**result, "status": "timeout"}
    except OSError as error:
        return {**result, "status": "error", "error": str(error)}
    return {
        **result,
        "status": "ok" if process.returncode == 0 else "error",
        "exit_code": process.returncode,
        "stdout": process.stdout[:4096].strip(),
        "stderr": process.stderr[:4096].strip(),
    }


def profile_status(results, required):
    return "ready" if all(results[name]["status"] == "ok" for name in required) else "not_ready"


def collect():
    results = {name: probe(COMMANDS[name]) for name in sorted(COMMANDS)}
    meminfo = Path("/proc/meminfo")
    memory = {}
    if meminfo.exists():
        for line in meminfo.read_text().splitlines():
            key, value = line.split(":", 1)
            if key in {"MemTotal", "SwapTotal"}:
                memory[key + "_bytes"] = int(value.split()[0]) * 1024
    return {
        "schema_version": 1,
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": {
            "system": platform.system(), "release": platform.release(),
            "machine": platform.machine(), "logical_cpus": os.cpu_count(),
            "probe_python": sys.version.split()[0], **memory,
        },
        "tools": results,
        "profiles": {name: profile_status(results, required) for name, required in PROFILES.items()},
        "scope": "Executable discovery and version/help invocation only; no compile, ISA or RTL validation.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write the observed inventory as JSON")
    parser.add_argument("--require", choices=PROFILES, action="append", default=[])
    args = parser.parse_args()
    report = collect()
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for name, result in report["tools"].items():
        print(f"{name}: {result['status']}")
    for name, status in report["profiles"].items():
        print(f"profile/{name}: {status}")
    return 0 if all(report["profiles"][name] == "ready" for name in args.require) else 1


if __name__ == "__main__":
    sys.exit(main())
