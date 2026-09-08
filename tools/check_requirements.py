"""Check requirements bookkeeping, not ISA conformance."""

import csv
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / "docs/requirements"


def validate(rows, inventory):
    errors, seen, covered = [], set(), set()
    for row in rows:
        key = row.get("id", "")
        if not key or key in seen:
            errors.append(f"Duplicate or empty ID: {key}")
        seen.add(key)
        for field in ["features", "block", "verification"]:
            if not row.get(field, "").strip():
                errors.append(f"{key}: empty {field}")
        if row.get("source") not in {"profile", "unpriv", "priv", "project"}:
            errors.append(f"{key}: unknown source")
        if row.get("gate") not in {"G4", "G5", "G7"}:
            errors.append(f"{key}: unknown gate")
        if row.get("status") not in {"planned", "implemented", "verified"}:
            errors.append(f"{key}: unknown status")
        if row.get("status") == "verified" and not row.get("evidence", "").strip():
            errors.append(f"{key}: verified without evidence")
        covered.update(row.get("features", "").split(";"))
    required = set()
    for group in ["mandatory_user", "mandatory_supervisor_additions", "sha_members"]:
        values = inventory[group]
        if not values or len(values) != len(set(values)):
            errors.append(f"Invalid inventory group: {group}")
        required.update(values)
    for feature in sorted(required - covered):
        errors.append(f"Unmapped mandatory feature: {feature}")
    return errors


def load():
    with (DIRECTORY / "isa-platform.csv").open(encoding="utf-8", newline="") as stream:
        rows = list(csv.DictReader(stream))
    inventory = json.loads((DIRECTORY / "rva23-inventory.json").read_text(encoding="utf-8"))
    return rows, inventory


def main():
    rows, inventory = load()
    errors = validate(rows, inventory)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Requirements bookkeeping OK: {len(rows)} rows; "
          f"{sum(row['status'] == 'verified' for row in rows)} verified.")
    print("This is NOT a CPU compliance result; source review and implementation tests remain open.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
