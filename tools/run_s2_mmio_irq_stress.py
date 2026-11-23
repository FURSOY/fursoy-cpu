#!/usr/bin/env python3
"""Directed P0-1 SMP Stress Test Runner:
Uncached MMIO (UART THR stores + PLIC Claim/Complete cycles) under relentless
high-frequency M-mode MSIP bombardment from Hart 1.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from s2_verilator_lib import (  # noqa: E402
    compute_rtl_sha256,
    ensure_soc_lib,
    get_build_jobs,
    get_verilator_threads,
    link_verilator_tb,
    run_cmd,
)

BUILD_ROOT = ROOT / "build/s2_mmio_irq_stress"
ASM_SRC = ROOT / "software/baremetal/s2_mmio_irq_stress.S"
LINK_LD = ROOT / "software/baremetal/s2_link.ld"
TB_CPP = ROOT / "verification/s2_mmio_irq_stress_tb.cpp"


def main() -> int:
    t0 = time.monotonic()
    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    elf_path = BUILD_ROOT / "s2_mmio_irq_stress.elf"

    asm_cmd = [
        "riscv64-unknown-elf-gcc",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-nostdlib",
        "-nostartfiles",
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
        "-Wl,--section-start=.smode=0x80200000",
        "-T",
        str(LINK_LD),
        str(ASM_SRC),
        "-o",
        str(elf_path),
    ]
    rc, out = run_cmd(asm_cmd, timeout_s=120)
    if rc != 0:
        print(out, file=sys.stderr)
        raise RuntimeError("Failed to assemble s2_mmio_irq_stress.S")

    jobs = get_build_jobs()
    threads = get_verilator_threads()
    soc_mdir, soc_lib, global_objs, soc_s, rebuilt = ensure_soc_lib(
        2, jobs=jobs, threads=threads, log_path=BUILD_ROOT / "soc_build.log"
    )
    sim_bin, link_s = link_verilator_tb(
        2,
        TB_CPP,
        soc_mdir,
        soc_lib,
        global_objs,
        BUILD_ROOT / f"Vs2_mmio_irq_stress_n2_t{threads}",
        threads,
        extra_include_dirs=[ROOT / "verification"],
    )
    tag = "fresh" if rebuilt else "cached_soc"
    print(f"[MMIO-IRQ-STRESS] Built/Linked in {soc_s + link_s:.2f}s (soc={soc_s:.2f}s [{tag}], link={link_s:.2f}s)")

    rc, sim_out = run_cmd([str(sim_bin), str(elf_path), "300000"], timeout_s=300)
    (BUILD_ROOT / "sim.log").write_text(sim_out, encoding="utf-8")
    print(sim_out)

    j_start = sim_out.rfind('{\n  "status":')
    data = json.loads(sim_out[j_start:]) if j_start != -1 else {"status": "fail"}
    data["rtl_sha256"] = compute_rtl_sha256()
    data["elapsed_s"] = round(time.monotonic() - t0, 2)
    (BUILD_ROOT / "report.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    if rc != 0 or data.get("status") != "pass":
        raise RuntimeError("Directed MMIO-vs-IRQ stress test FAILED!")
    print(f"[MMIO-IRQ-STRESS] PASS in {data['elapsed_s']}s (rtl_sha256={data['rtl_sha256']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
