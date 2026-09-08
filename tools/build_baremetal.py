"""Build and structurally inspect the slice-0 ELF. Does not execute RISC-V code."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "software/baremetal"
BUILD = ROOT / "build/baremetal"
GCC = "riscv64-unknown-elf-gcc"


def call(command, logfile):
    process = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=60)
    output = process.stdout + process.stderr
    logfile.write_text(output, encoding="utf-8")
    return process.returncode, output


def inspect_elf(path, symbols):
    blob = path.read_bytes()
    if blob[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("Expected little-endian ELF64")
    header = struct.unpack_from("<HHIQQQIHHHHHH", blob, 16)
    kind, machine, _, entry, phoff, _, flags, _, phsize, phnum, *_ = header
    if kind != 2 or machine != 243 or entry != 0x80000000 or flags != 0:
        raise ValueError("Wrong ELF target/entry/flags")
    if phsize != 56:
        raise ValueError("Unexpected program-header size")
    expected = {"_start": 0x80000000, "tohost": 0x80010000,
                "fromhost": 0x80010008, "signature": 0x80010010,
                "__stack_top": 0x80020000}
    for name, address in expected.items():
        if symbols.get(name) != address:
            raise ValueError(f"Wrong symbol address: {name}")
    loads = []
    for i in range(phnum):
        ptype, pflags, offset, vaddr, paddr, filesz, memsz, align = struct.unpack_from(
            "<IIQQQQQQ", blob, phoff + i * phsize)
        if ptype != 1:
            continue
        if (filesz > memsz or offset + filesz > len(blob) or vaddr != paddr
                or vaddr < 0x80000000 or vaddr + memsz > 0x80020000
                or pflags not in {5, 6}):
            raise ValueError("Invalid LOAD segment bounds/permissions")
        if align > 1 and (align & (align - 1) or (vaddr - offset) % align):
            raise ValueError("Invalid LOAD alignment")
        loads.append({"address": vaddr, "filesz": filesz, "memsz": memsz,
                      "flags": pflags, "offset": offset})
    if len(loads) != 3:
        raise ValueError("Expected three LOAD segments")
    ordered = sorted(loads, key=lambda segment: segment["address"])
    if any(a["address"] + a["memsz"] > b["address"] for a, b in zip(ordered, ordered[1:])):
        raise ValueError("Overlapping LOAD segments")
    def memory_bytes(address, size):
        for segment in loads:
            relative = address - segment["address"]
            if 0 <= relative and relative + size <= segment["filesz"]:
                return blob[segment["offset"] + relative:segment["offset"] + relative + size]
        raise ValueError("Expected initialized bytes missing")
    if memory_bytes(symbols["ecall_probe"], 4) != b"\x73\x00\x00\x00":
        raise ValueError("ECALL probe encoding mismatch")
    initial = struct.unpack("<10Q", memory_bytes(0x80010000, 80))
    if initial != (0, 0, 0x465552534f593031, 1, 0, 0, 0, 0, 0, 0):
        raise ValueError("Mailbox initial state mismatch")
    if not 0x80011000 <= symbols["__bss_start"] <= symbols["__bss_end"] <= 0x8001f000:
        raise ValueError("BSS overlaps reserved stack")
    return {"entry": entry, "load_segments": loads, "symbols": symbols}


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    report = {"status": "fail", "execution": "not_run",
              "observed_at_utc": datetime.now(timezone.utc).isoformat(),
              "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [SOURCE / "start.S", SOURCE / "smoke.c", SOURCE / "link.ld",
                                          Path(__file__).resolve()]}}
    try:
        report["compiler"] = subprocess.check_output([GCC, "--version"], text=True).splitlines()[0]
        flags = ["-march=rv64i_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany", "-mno-relax",
                 "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-pic", "-fno-pie",
                 "-fno-stack-protector", "-fno-asynchronous-unwind-tables", "-nostdlib", "-nostartfiles",
                 "-O2", "-Wall", "-Wextra", "-Werror", "-Wl,--no-relax", "-Wl,--build-id=none",
                 "-Wl,--fatal-warnings", "-T", str(SOURCE / "link.ld")]
        elf = BUILD / "smoke.elf"
        command = [GCC, *flags, str(SOURCE / "start.S"), str(SOURCE / "smoke.c"),
                   "-Wl,-Map," + str(BUILD / "smoke.map"), "-o", str(elf)]
        report["command"] = command
        code, output = call(command, BUILD / "build.log")
        if code:
            raise RuntimeError(output)
        code, output = call(["riscv64-unknown-elf-nm", "-n", str(elf)], BUILD / "symbols.log")
        if code:
            raise RuntimeError(output)
        symbols = {parts[2]: int(parts[0], 16) for line in output.splitlines()
                   if len(parts := line.split()) == 3}
        report["elf"] = inspect_elf(elf, symbols)
        report["elf_sha256"] = hashlib.sha256(elf.read_bytes()).hexdigest()
        for tool, args, name in [("readelf", ["-h", "-l", "-A"], "elf.log"),
                                 ("objdump", ["-d", "-M", "no-aliases"], "disassembly.log")]:
            code, output = call(["riscv64-unknown-elf-" + tool, *args, str(elf)], BUILD / name)
            if code:
                raise RuntimeError(output)
        oversized = BUILD / "oversized.S"
        oversized.write_text('.section .bss\n.balign 8\n.space 131072\n', encoding="utf-8")
        code, output = call([GCC, *flags, str(SOURCE / "start.S"), str(SOURCE / "smoke.c"),
                             str(oversized), "-o", str(BUILD / "oversized.elf")], BUILD / "negative-link.log")
        if code == 0 or "data overlaps stack reserve" not in output:
            raise RuntimeError("Linker did not reject deliberate stack overlap")
        report["negative_link"] = {"status": "rejected", "exit_code": code,
                                   "reason": "data overlaps stack reserve"}
        report["status"] = "build_verified"
        print("ELF build/layout checks passed; deliberate stack overlap rejected. Execution NOT run.")
    except (OSError, ValueError, KeyError, struct.error, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
    target = ROOT / "results/baremetal-build.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "build_verified" else 1


if __name__ == "__main__":
    sys.exit(main())
