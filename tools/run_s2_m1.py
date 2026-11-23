#!/usr/bin/env python3
"""Build and run Fursoy Slice-2 Milestone S2-M1 (N=2 and N=4 Multi-Hart Bring-Up) Verification Suite."""

from __future__ import annotations

import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from s2_verilator_lib import (  # noqa: E402
    SOC_SV,
    compute_rtl_sha256,
    ensure_soc_lib,
    get_build_jobs,
    get_verilator_threads,
    link_verilator_tb,
    run_cmd,
)

BUILD_ROOT = ROOT / "build/s2_m1"
REPORT = ROOT / "results/s2-m1-closeout.json"
ASM_SRC = ROOT / "software/baremetal/s2_m1_smp_smoke.S"
LINK_LD = ROOT / "software/baremetal/s2_link.ld"
TB_CPP = ROOT / "verification/s2_m1_tb.cpp"


def run_config(num_harts: int) -> dict:
    cfg_dir = BUILD_ROOT / f"n{num_harts}"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    elf_path = cfg_dir / f"s2_m1_n{num_harts}.elf"

    print(f"--- [S2-M1 N={num_harts}] Verilator Lint ---")
    lint_cmd = [
        "verilator", "--lint-only", "--assert", "-Wall",
        "-Irtl/core", "-Irtl/platform",
        f"-GNUM_HARTS={num_harts}",
        "--top-module", "fursoy_s2_soc",
        str(SOC_SV),
    ]
    rc, out = run_cmd(lint_cmd)
    if rc != 0:
        print(out, file=sys.stderr)
        raise RuntimeError(f"Verilator lint failed for NUM_HARTS={num_harts}")
    print(f"[S2-M1 N={num_harts}] Lint PASS (0 warnings, 0 errors)")

    print(f"--- [S2-M1 N={num_harts}] Compiling Baremetal SMP Smoke ELF ---")
    gcc_cmd = [
        "riscv64-unknown-elf-gcc",
        "-O2",
        "-march=rv64ima_zicsr_zifencei",
        "-mabi=lp64",
        "-mcmodel=medany",
        "-mno-relax",
        "-nostdlib",
        "-nostartfiles",
        "-Wl,--no-relax",
        "-Wl,--build-id=none",
        f"-DNUM_HARTS={num_harts}",
        "-T", str(LINK_LD),
        str(ASM_SRC),
        "-o", str(elf_path),
    ]
    rc, out = run_cmd(gcc_cmd)
    if rc != 0:
        print(out, file=sys.stderr)
        raise RuntimeError(f"GCC build failed for NUM_HARTS={num_harts}")

    jobs = get_build_jobs()
    threads = get_verilator_threads()
    print(f"--- [S2-M1 N={num_harts}] Building/Linking Verilator Sim (jobs={jobs}, threads={threads}) ---")
    soc_mdir, soc_lib, global_objs, soc_s, rebuilt = ensure_soc_lib(
        num_harts, jobs=jobs, threads=threads, log_path=cfg_dir / "build.log"
    )
    sim_bin, link_s = link_verilator_tb(
        num_harts, TB_CPP, soc_mdir, soc_lib, global_objs,
        cfg_dir / f"Vs2_m1_n{num_harts}_t{threads}", threads,
    )
    build_s = soc_s + link_s
    tag = "fresh" if rebuilt else "cached_soc"

    print(f"--- [S2-M1 N={num_harts}] Executing Simulation (soc={soc_s:.2f}s[{tag}], link={link_s:.2f}s) ---")
    t_sim0 = time.monotonic()
    rc, sim_out = run_cmd([str(sim_bin), str(elf_path), "300000"])
    sim_s = time.monotonic() - t_sim0
    (cfg_dir / "sim.log").write_text(sim_out, encoding="utf-8")
    print(sim_out)

    json_start = sim_out.rfind("{\n  \"status\":")
    tb_data = json.loads(sim_out[json_start:]) if json_start != -1 else {"status": "fail"}
    if rc != 0 or tb_data.get("status") != "pass":
        raise RuntimeError(f"Simulation failed for NUM_HARTS={num_harts}")
    cyc = tb_data.get("cycles", 0)
    rate = (cyc / sim_s) if sim_s > 0 else 0.0
    print(f"[S2-M1 N={num_harts} PERF] build={build_s:.2f}s ({tag}) sim={sim_s:.2f}s cycles={cyc} rate={rate:.1f} cyc/s (jobs={jobs}, threads={threads})")
    return tb_data


def main() -> int:
    t0 = time.time()
    BUILD_ROOT.mkdir(parents=True, exist_ok=True)
    results = {}
    overall_pass = True

    for n in (2, 4):
        try:
            results[f"n{n}"] = run_config(n)
        except Exception as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            results[f"n{n}"] = {"status": "fail", "error": str(exc)}
            overall_pass = False

    report = {
        "milestone": "S2-M1",
        "status": "PASS" if overall_pass else "FAIL",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - t0, 2),
        "rtl_sha256": compute_rtl_sha256(),
        "configs": results,
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Results written to: {REPORT.relative_to(ROOT)}")
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
