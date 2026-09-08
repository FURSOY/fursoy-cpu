"""Build the pinned Spike snapshot locally. Never runs sudo or changes PATH."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "tools/spike-lock.json"
SOURCE = ROOT / "build/spike-src"
BUILD = ROOT / "build/spike-build"


def main():
    lock = json.loads(LOCK.read_text())
    BUILD.mkdir(parents=True, exist_ok=True)
    report = {"status": "fail", "lock": lock, "observed_at_utc": datetime.now(timezone.utc).isoformat()}
    try:
        if not SOURCE.exists():
            subprocess.run(["git", "clone", "--no-checkout", lock["repository"], str(SOURCE)], check=True)
        subprocess.run(["git", "-C", str(SOURCE), "checkout", "--detach", lock["commit"]], check=True)
        dirty = subprocess.check_output(["git", "-C", str(SOURCE), "status", "--porcelain"], text=True)
        if dirty.strip():
            raise RuntimeError("Spike source is modified; refusing an untracked build")
        head = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
        if head != lock["commit"]:
            raise RuntimeError("Spike revision mismatch")
        for name, command in [("configure", [str(SOURCE / "configure"), *lock["configure"]]),
                              ("make", ["make", f"-j{lock['jobs']}", "spike"])]:
            print(f"Spike {name}: started", flush=True)
            with (BUILD / f"{name}.log").open("w") as log:
                subprocess.run(command, cwd=BUILD, stdout=log, stderr=subprocess.STDOUT, check=True)
        binary = BUILD / "spike"
        report.update(status="built", binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        print("Pinned Spike built: build/spike-build/spike", flush=True)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(f"Spike setup failed; inspect {BUILD}/configure.log and make.log", file=sys.stderr)
    target = ROOT / "results/spike-build.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["status"] == "built" else 1


if __name__ == "__main__":
    sys.exit(main())
