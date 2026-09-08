"""Check slice-0 contract bookkeeping; does not execute or verify hardware."""

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "docs/requirements/slice-0.md"
REQUIRED = [
    "`0x8000_0000`", "M-mode", "`mstatus`", "`mie`", "`mtvec`", "`mepc`", "`mcause`", "`mtval`",
    "CSRRW", "CSRRS", "CSRRC", "ECALL", "MRET", "FENCE.I", "`mcause=2`", "S0-BOOT", "S0-ECALL",
    "S0-MEM", "S0-CSR", "S0-ILL", "S0-FI", "Spike geçti; DUT planned",
]


def validate(text):
    return [f"Missing slice-0 contract marker: {marker}" for marker in REQUIRED if marker not in text]


def main():
    errors = validate(PATH.read_text(encoding="utf-8"))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Slice-0 contract bookkeeping OK; hardware verification remains planned.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
