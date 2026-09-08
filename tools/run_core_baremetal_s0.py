"""Build and run bare-metal ELF suite on the Slice-0 RTL core."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUILD_DIR = ROOT / "build/core_baremetal_s0"
BAREMETAL_DIR = ROOT / "build/baremetal"
REPORT_PATH = ROOT / "results/core-baremetal-s0.json"
PROBE_PROVENANCE_PATH = ROOT / "results/probe-provenance.json"
TB_SOURCE = ROOT / "verification/core_baremetal_s0_tb.cpp"

RTL_SOURCES = [
    ROOT / "rtl/core/fursoy_s0_fetch.sv",
    ROOT / "rtl/core/fursoy_s0_int_alu.sv",
    ROOT / "rtl/core/fursoy_s0_control.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_decode.sv",
    ROOT / "rtl/core/fursoy_s0_lsu_port.sv",
    ROOT / "rtl/core/fursoy_s0_csr.sv",
    ROOT / "rtl/core/fursoy_s0_mmu.sv",
    ROOT / "rtl/core/fursoy_s0_core.sv",
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ensure_fresh_elfs():
    build_json_path = ROOT / "results/baremetal-build.json"
    smoke_elf = BAREMETAL_DIR / "smoke.elf"

    rebuild_needed = not build_json_path.exists() or not smoke_elf.exists()
    if not rebuild_needed:
        try:
            build = json.loads(build_json_path.read_text(encoding="utf-8"))
            if build.get("status") != "build_verified":
                rebuild_needed = True
            elif sha256(smoke_elf) != build.get("elf_sha256"):
                rebuild_needed = True
            else:
                for path_str, digest in build.get("source_sha256", {}).items():
                    src_path = ROOT / path_str
                    if not src_path.exists() or sha256(src_path) != digest:
                        rebuild_needed = True
                        break
        except Exception:
            rebuild_needed = True

    if rebuild_needed:
        proc = subprocess.run([sys.executable, str(ROOT / "tools/build_baremetal.py")],
                              cwd=ROOT, capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"build_baremetal.py failed:\n{proc.stdout}\n{proc.stderr}")
        build = json.loads(build_json_path.read_text(encoding="utf-8"))

    if sha256(smoke_elf) != build["elf_sha256"]:
        raise RuntimeError("smoke.elf hash does not match baremetal-build.json")
    for path_str, digest in build["source_sha256"].items():
        if sha256(ROOT / path_str) != digest:
            raise RuntimeError(f"Stale ELF after source change: {path_str}")

    probe_pc = build["elf"]["symbols"]["ecall_probe"]
    tohost_sd_pc = 0x80000070  # "sd t1, 0(t0)" at end of _start

    def patch_elf(name, address, replacement):
        data = bytearray(smoke_elf.read_bytes())
        for segment in build["elf"]["load_segments"]:
            relative = address - segment["address"]
            if 0 <= relative and relative + len(replacement) <= segment["filesz"]:
                offset = segment["offset"] + relative
                data[offset:offset + len(replacement)] = replacement
                target = BAREMETAL_DIR / f"{name}.elf"
                target.write_bytes(data)
                return target
        raise RuntimeError(f"Mutation target is not initialized ELF memory: {name}")

    # Derive baseline mutation ELFs
    patch_elf("unexpected_trap", probe_pc, bytes.fromhex("73001000"))
    patch_elf("bad_signature", 0x80010010, bytes(8))
    patch_elf("hang", probe_pc, bytes.fromhex("6f000000"))

    # Derive focused rejection regression ELFs
    patch_elf("invalid_tohost_width", tohost_sd_pc, bytes.fromhex("23a06200"))     # sw t1, 0(t0)
    patch_elf("out_of_range_data", probe_pc, bytes.fromhex("83320000"))            # ld t0, 0(zero)
    patch_elf("overflow_address_data", probe_pc, bytes.fromhex("930280ff03b30200")) # addi t0,x0,-8; ld t1,0(t0)
    patch_elf("out_of_range_fetch", probe_pc, bytes.fromhex("67000000"))           # jalr zero, 0(zero)

    # Hash-based provenance for separately compiled probe ELFs
    probe_provenance = {}
    if PROBE_PROVENANCE_PATH.exists():
        try:
            probe_provenance = json.loads(PROBE_PROVENANCE_PATH.read_text(encoding="utf-8"))
        except Exception:
            probe_provenance = {}

    probe_sources = [
        ("csr_write_probe", [ROOT / "software/baremetal/start.S", ROOT / "software/baremetal/csr_write_probe.S", ROOT / "software/baremetal/link.ld"], [ROOT / "software/baremetal/start.S", ROOT / "software/baremetal/csr_write_probe.S"]),
        ("illegal_probe", [ROOT / "software/baremetal/start.S", ROOT / "software/baremetal/illegal_probe.S", ROOT / "software/baremetal/link.ld"], [ROOT / "software/baremetal/start.S", ROOT / "software/baremetal/illegal_probe.S"]),
        ("reset_probe", [ROOT / "software/baremetal/reset_probe.S", ROOT / "software/baremetal/link.ld"], [ROOT / "software/baremetal/reset_probe.S"]),
    ]
    link_ld = ROOT / "software/baremetal/link.ld"

    flags = [
        "-march=rv64i_zicsr_zifencei", "-mabi=lp64", "-mcmodel=medany", "-mno-relax",
        "-msmall-data-limit=0", "-ffreestanding", "-fno-builtin", "-fno-pic", "-fno-pie",
        "-fno-stack-protector", "-fno-asynchronous-unwind-tables", "-nostdlib",
        "-nostartfiles", "-O2", "-Wall", "-Wextra", "-Werror", "-Wl,--no-relax",
        "-Wl,--build-id=none", "-Wl,--fatal-warnings",
        "-T", str(link_ld)
    ]

    updated_provenance = False
    for name, tracked_sources, compile_inputs in probe_sources:
        target_elf = BAREMETAL_DIR / f"{name}.elf"
        sources_dict = {
            str(src.relative_to(ROOT)): sha256(src)
            for src in tracked_sources
        }

        rec = probe_provenance.get(name)
        rebuild_probe = (
            not target_elf.exists()
            or not rec
            or rec.get("sources") != sources_dict
            or sha256(target_elf) != rec.get("elf_sha256")
        )

        if rebuild_probe:
            cmd = ["riscv64-unknown-elf-gcc", *flags, *map(str, compile_inputs), "-o", str(target_elf)]
            res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
            if res.returncode != 0:
                raise RuntimeError(f"Failed to build probe ELF {name}:\n{res.stderr}")
            probe_provenance[name] = {
                "sources": sources_dict,
                "elf_sha256": sha256(target_elf)
            }
            updated_provenance = True

    if updated_provenance or not PROBE_PROVENANCE_PATH.exists():
        PROBE_PROVENANCE_PATH.parent.mkdir(parents=True, exist_ok=True)
        PROBE_PROVENANCE_PATH.write_text(json.dumps(probe_provenance, indent=2) + "\n", encoding="utf-8")

    return build, probe_provenance


def main():
    report = {
        "status": "fail",
        "scope": "DUT execution of bare-metal ELFs with memory adapter",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {
            str(p.relative_to(ROOT)): sha256(p)
            for p in [*RTL_SOURCES, TB_SOURCE, Path(__file__).resolve()]
        },
        "cases": []
    }

    try:
        # 1. Establish ELF freshness & build derived/probe ELFs
        build, probe_prov = ensure_fresh_elfs()
        report["elf_provenance"] = {
            "smoke_elf_sha256": build["elf_sha256"],
            "compiler": build.get("compiler", "unknown"),
            "probes": {k: v["elf_sha256"] for k, v in probe_prov.items()}
        }

        # 2. Compile DUT testbench with Verilator
        BUILD_DIR.mkdir(parents=True, exist_ok=True)
        verilator_cmd = [
            "verilator", "--cc", "--exe", "--build", "--assert", "-Wall", "-j", "2",
            "--top-module", "fursoy_s0_core",
            "--Mdir", str(BUILD_DIR),
            *map(str, RTL_SOURCES),
            str(TB_SOURCE)
        ]
        build_log = BUILD_DIR / "build.log"
        with build_log.open("w", encoding="utf-8") as f:
            proc = subprocess.run(verilator_cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT,
                                  timeout=120, check=False)
        if proc.returncode != 0:
            raise RuntimeError(f"Verilator build failed, see {build_log}")

        dut_exe = BUILD_DIR / "Vfursoy_s0_core"
        report["build_command"] = verilator_cmd

        # 3. Test cases definition with strict validator functions
        def check_smoke(res):
            if not res.get("tohost_seen"):
                raise ValueError("smoke: tohost write not seen")
            if res.get("tohost") != 1:
                raise ValueError(f"smoke: expected tohost=1, got {res.get('tohost')}")
            sig = [int(w, 16) for w in res["signature"]]
            expected_sig = [0x465552534f593031, 1, 1, 0, 11, 0x80000040, 0, 1]
            if sig != expected_sig:
                raise ValueError(f"smoke: signature mismatch: observed {sig}, expected {expected_sig}")
            if res.get("traps") != 1:
                raise ValueError(f"smoke: expected 1 trap, got {res.get('traps')}")
            if res.get("last_trap_cause") != 11 or res.get("last_trap_pc") != "0x80000040":
                raise ValueError(f"smoke: trap metadata mismatch: cause={res.get('last_trap_cause')} pc={res.get('last_trap_pc')}")
            if res.get("status") != "pass":
                raise ValueError("smoke: expected pass status")
            return True

        def check_unexpected_trap(res):
            if not res.get("tohost_seen"):
                raise ValueError("unexpected_trap: tohost write not seen")
            if res.get("tohost") != 3:
                raise ValueError(f"unexpected_trap: expected tohost=3, got {res.get('tohost')}")
            if res.get("traps") != 1 or res.get("last_trap_cause") != 3:
                raise ValueError(f"unexpected_trap: expected 1 trap with cause=3, got traps={res.get('traps')} cause={res.get('last_trap_cause')}")
            sig = [int(w, 16) for w in res["signature"]]
            expected_sig = [0x465552534f593031, 1, 2, 100, 3, 0x80000040, 0, 0]
            if sig != expected_sig:
                raise ValueError(f"unexpected_trap: signature mismatch: observed {sig}, expected {expected_sig}")
            if res.get("status") != "fail":
                raise ValueError("unexpected_trap: expected fail status on reported trap failure")
            return True

        def check_bad_sig(res):
            if not res.get("tohost_seen"):
                raise ValueError("bad_signature: tohost write not seen (execution aborted prematurely)")
            if res.get("tohost") != 1:
                raise ValueError(f"bad_signature: expected tohost=1, got {res.get('tohost')}")
            if res.get("traps") != 1 or res.get("last_trap_cause") != 11:
                raise ValueError(f"bad_signature: unexpected trap behavior: traps={res.get('traps')} cause={res.get('last_trap_cause')}")
            sig = [int(w, 16) for w in res["signature"]]
            if sig[0] != 0:
                raise ValueError(f"bad_signature: expected corrupted magic 0, got {hex(sig[0])}")
            expected_tail = [1, 1, 0, 11, 0x80000040, 0, 1]
            if sig[1:] != expected_tail:
                raise ValueError(f"bad_signature: signature tail corrupted: observed {sig[1:]}, expected {expected_tail}")
            if res.get("status") != "fail":
                raise ValueError("bad_signature: scoreboard failed to reject corrupted signature magic")
            return True

        def check_hang(res):
            if res.get("tohost_seen"):
                raise ValueError("hang: expected timeout, but tohost write occurred")
            if res.get("cycles") != 500:
                raise ValueError(f"hang: expected to terminate at cycle limit 500, got {res.get('cycles')}")
            if res.get("traps") != 0:
                raise ValueError(f"hang: expected 0 traps before hang, got {res.get('traps')}")
            if res.get("status") != "fail":
                raise ValueError("hang: expected fail status on timeout")
            return True

        def check_csr_write(res):
            if not res.get("tohost_seen"):
                raise ValueError("csr_write_probe: tohost write not seen")
            if res.get("tohost") != 3:
                raise ValueError(f"csr_write_probe: expected tohost=3, got {res.get('tohost')}")
            if res.get("traps") != 2 or res.get("last_trap_cause") != 2:
                raise ValueError(f"csr_write_probe: expected 2 traps with cause=2, got traps={res.get('traps')} cause={res.get('last_trap_cause')}")
            sig = [int(w, 16) for w in res["signature"]]
            expected_sig = [0x465552534f593031, 1, 2, 100, 2, 0x800000f0, 0xc0001073, 1]
            if sig != expected_sig:
                raise ValueError(f"csr_write_probe: full signature mismatch: observed {sig}, expected {expected_sig}")
            if res.get("last_trap_pc") != "0x800000f0":
                raise ValueError(f"csr_write_probe: last trap PC mismatch: {res.get('last_trap_pc')}")
            if res.get("status") != "fail":
                raise ValueError("csr_write_probe: expected fail status")
            return True

        def check_illegal(res):
            if not res.get("tohost_seen"):
                raise ValueError("illegal_probe: tohost write not seen")
            if res.get("tohost") != 3:
                raise ValueError(f"illegal_probe: expected tohost=3, got {res.get('tohost')}")
            if res.get("traps") != 2 or res.get("last_trap_cause") != 2:
                raise ValueError(f"illegal_probe: expected 2 traps with cause=2, got traps={res.get('traps')} cause={res.get('last_trap_cause')}")
            sig = [int(w, 16) for w in res["signature"]]
            expected_sig = [0x465552534f593031, 1, 2, 100, 2, 0x800000f0, 0xffffffff, 1]
            if sig != expected_sig:
                raise ValueError(f"illegal_probe: full signature mismatch: observed {sig}, expected {expected_sig}")
            if res.get("last_trap_pc") != "0x800000f0":
                raise ValueError(f"illegal_probe: last trap PC mismatch: {res.get('last_trap_pc')}")
            if res.get("status") != "fail":
                raise ValueError("illegal_probe: expected fail status")
            return True

        def check_reset(res):
            if not res.get("tohost_seen"):
                raise ValueError("reset_probe: tohost write not seen")
            if res.get("tohost") != 1:
                raise ValueError(f"reset_probe: expected tohost=1, got {res.get('tohost')}")
            if res.get("traps") != 0:
                raise ValueError(f"reset_probe: expected 0 traps, got {res.get('traps')}")
            sig = [int(w, 16) for w in res["signature"]]
            expected_head = [0x465552534f593031, 1, 1]
            if sig[:3] != expected_head:
                raise ValueError(f"reset_probe: header mismatch: {sig[:3]}")
            if (sig[3] & 0x1888) != 0x1800:
                raise ValueError(f"reset_probe: mstatus mismatch: {hex(sig[3])}")
            if sig[4:] != [0, 0, 0, 0]:
                raise ValueError(f"reset_probe: CSR non-zero fields: {sig[4:]}")
            if res.get("status") != "pass":
                raise ValueError("reset_probe: expected pass status")
            return True

        def check_invalid_tohost_width(res):
            if res.get("status") != "error":
                raise ValueError(f"invalid_tohost_width: expected error status, got {res.get('status')}")
            err = res.get("error", "")
            if "Invalid tohost write" not in err or "size=2" not in err:
                raise ValueError(f"invalid_tohost_width: unexpected error message: {err}")
            return True

        def check_out_of_range_data(res):
            if res.get("status") != "error":
                raise ValueError(f"out_of_range_data: expected error status, got {res.get('status')}")
            err = res.get("error", "")
            if "Out-of-range or unaligned data read" not in err or "0x0" not in err:
                raise ValueError(f"out_of_range_data: unexpected error message: {err}")
            return True

        def check_overflow_address_data(res):
            if res.get("status") != "error":
                raise ValueError(f"overflow_address_data: expected error status, got {res.get('status')}")
            err = res.get("error", "")
            if "Out-of-range or unaligned data read" not in err or "0xfffffffffffffff8" not in err:
                raise ValueError(f"overflow_address_data: unexpected error message: {err}")
            return True

        def check_out_of_range_fetch(res):
            if res.get("status") != "error":
                raise ValueError(f"out_of_range_fetch: expected error status, got {res.get('status')}")
            err = res.get("error", "")
            if "Out-of-range or unaligned instruction fetch" not in err or "0x0" not in err:
                raise ValueError(f"out_of_range_fetch: unexpected error message: {err}")
            return True

        cases = [
            ("smoke", BAREMETAL_DIR / "smoke.elf", 50000, check_smoke),
            ("unexpected_trap", BAREMETAL_DIR / "unexpected_trap.elf", 50000, check_unexpected_trap),
            ("bad_signature", BAREMETAL_DIR / "bad_signature.elf", 50000, check_bad_sig),
            ("hang", BAREMETAL_DIR / "hang.elf", 500, check_hang),
            ("csr_write_probe", BAREMETAL_DIR / "csr_write_probe.elf", 50000, check_csr_write),
            ("illegal_probe", BAREMETAL_DIR / "illegal_probe.elf", 50000, check_illegal),
            ("reset_probe", BAREMETAL_DIR / "reset_probe.elf", 50000, check_reset),
            ("invalid_tohost_width", BAREMETAL_DIR / "invalid_tohost_width.elf", 50000, check_invalid_tohost_width),
            ("out_of_range_data", BAREMETAL_DIR / "out_of_range_data.elf", 50000, check_out_of_range_data),
            ("overflow_address_data", BAREMETAL_DIR / "overflow_address_data.elf", 50000, check_overflow_address_data),
            ("out_of_range_fetch", BAREMETAL_DIR / "out_of_range_fetch.elf", 50000, check_out_of_range_fetch),
        ]

        for name, elf, cycles, validator in cases:
            if not elf.exists():
                raise RuntimeError(f"Missing ELF binary: {elf}")
            sim_proc = subprocess.run([str(dut_exe), str(elf), str(cycles)],
                                      cwd=ROOT, capture_output=True, text=True, timeout=30)
            try:
                res = json.loads(sim_proc.stdout)
            except json.JSONDecodeError as err:
                raise RuntimeError(f"Failed to parse DUT output for {name}: {sim_proc.stdout}\n{sim_proc.stderr}") from err

            matched = False
            try:
                matched = validator(res)
            except ValueError as val_err:
                res["validation_error"] = str(val_err)

            case_record = {
                "name": name,
                "elf_sha256": sha256(elf),
                "simulation": res,
                "matched": matched
            }
            report["cases"].append(case_record)
            if not matched:
                raise RuntimeError(f"Case {name} failed validation: {res.get('validation_error', res)}")
            print(f"  {name}: pass (cycles={res.get('cycles')}, commits={res.get('commits')}, status={res.get('status')})")

        report["status"] = "pass"
        print(f"Slice-0 core bare-metal ELF DUT: pass (all {len(cases)} programs verified)")

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
