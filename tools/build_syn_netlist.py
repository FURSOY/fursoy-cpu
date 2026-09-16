#!/usr/bin/env python3
"""Build reproducible synthesized Verilog netlist from frozen 18-file Slice-0 production SoC RTL."""

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

RTL_MANIFEST_EXPECTED = "bd609b91e6471bb0abbb2c8c67dc1d9bdadc1f109a36d1488c1c21c88c1d43f2"
CORE_HASH_EXPECTED = "d343b180ba63c4e18fcd93d0fb52d8e0e6963df8f5454ef09218b646e23571ce"
SB_HASH_EXPECTED = "301a9f99c86811ef6d915e675588f648673b4920e420ecf4b841825dd4a20d38"

RTL_FILES = [
    ROOT / "rtl/core/fursoy_s0_l1i.sv",
    ROOT / "rtl/core/fursoy_s0_int_alu.sv",
    ROOT / "rtl/core/fursoy_s0_control.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_port.sv",
    ROOT / "rtl/core/fursoy_s0_csr.sv",
    ROOT / "rtl/core/fursoy_s0_pmp_check.sv",
    ROOT / "rtl/core/fursoy_s0_pmp.sv",
    ROOT / "rtl/core/fursoy_s0_tlb.sv",
    ROOT / "rtl/core/fursoy_s0_l1d.sv",
    ROOT / "rtl/core/fursoy_s0_sb.sv",
    ROOT / "rtl/core/fursoy_s0_bpu.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
    ROOT / "rtl/platform/fursoy_s0_clint.sv",
    ROOT / "rtl/platform/fursoy_s0_plic.sv",
    ROOT / "rtl/platform/fursoy_s0_uart.sv",
    ROOT / "rtl/platform/fursoy_s0_soc.sv",
]

def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def compute_manifest_sha(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode() + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()

def verify_hashes():
    core_h = sha256_file(ROOT / "rtl/core/fursoy_s0_core.sv")
    sb_h = sha256_file(ROOT / "rtl/core/fursoy_s0_sb.sv")
    man_h = compute_manifest_sha(RTL_FILES)

    if core_h != CORE_HASH_EXPECTED:
        raise ValueError(f"Core hash mismatch: {core_h} != {CORE_HASH_EXPECTED}")
    if sb_h != SB_HASH_EXPECTED:
        raise ValueError(f"SB hash mismatch: {sb_h} != {SB_HASH_EXPECTED}")
    if man_h != RTL_MANIFEST_EXPECTED:
        raise ValueError(f"Manifest hash mismatch: {man_h} != {RTL_MANIFEST_EXPECTED}")
    print("[NETLIST] Production RTL hashes verified (100% frozen).")

def generate_netlist():
    out_dir = ROOT / "build/syn"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_v = out_dir / "soc.v"

    # sv2v translation command
    # Modules included via `include inside core/mmu/pmp are automatically ingested
    # The top-level arguments supply the un-included compilation units
    cmd = [
        "sv2v",
        "-I.",
        "-Irtl/core",
        "-Irtl/platform",
        "-DSYNTHESIS",
        "rtl/core/fursoy_s0_int_alu.sv",
        "rtl/core/fursoy_s0_control.sv",
        "rtl/core/fursoy_s0_lsu_decode.sv",
        "rtl/core/fursoy_s0_lsu_port.sv",
        "rtl/core/fursoy_s0_csr.sv",
        "rtl/core/fursoy_s0_mmu.sv",
        "rtl/core/fursoy_s0_core.sv",
        "rtl/platform/fursoy_s0_clint.sv",
        "rtl/platform/fursoy_s0_plic.sv",
        "rtl/platform/fursoy_s0_uart.sv",
        "rtl/platform/fursoy_s0_soc.sv",
    ]

    print(f"[NETLIST] Running sv2v...")
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        print("[ERROR] sv2v failed:", res.stderr, file=sys.stderr)
        sys.exit(1)

    code = res.stdout

    # Strip simulation-only calls translated into $finish(1) or $display for synthesis compatibility
    code = re.sub(r'\$finish\s*\([^\)]*\)\s*;', ';', code)
    code = re.sub(r'\$display\s*\([^\)]*\)\s*;', ';', code)

    out_v.write_text(code, encoding="utf-8")
    print(f"[NETLIST] Wrote {len(code)} bytes to {out_v}")

    # Verify modules
    modules = re.findall(r'module\s+([a-zA-Z0-9_]+)\s*\(', code)
    print(f"[NETLIST] Found {len(modules)} modules in netlist:")
    for m in modules:
        print(f"  - {m}")
    expected_mods = {
        "fursoy_s0_int_alu", "fursoy_s0_control", "fursoy_s0_lsu_decode",
        "fursoy_s0_lsu_port", "fursoy_s0_csr", "fursoy_s0_pmp_check",
        "fursoy_s0_tlb", "fursoy_s0_mmu", "fursoy_s0_pmp",
        "fursoy_s0_l1i", "fursoy_s0_l1d", "fursoy_s0_sb",
        "fursoy_s0_bpu", "fursoy_s0_core", "fursoy_s0_clint",
        "fursoy_s0_plic", "fursoy_s0_uart", "fursoy_s0_soc"
    }
    missing = expected_mods - set(modules)
    if missing:
        raise ValueError(f"Missing modules in converted netlist: {missing}")
    print("[NETLIST] All 18 production SoC modules verified in netlist.")

if __name__ == "__main__":
    verify_hashes()
    generate_netlist()
