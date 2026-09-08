"""Build and verify the canonical Device Tree (DTS/DTB) for Fursoy Slice-0."""
from datetime import datetime, timezone
import hashlib, json, re, struct, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/dts"
REPORT = ROOT / "results/dt-s0.json"
DTS_FILE = ROOT / "software/dts/fursoy_s0.dts"
DTB_FILE = BUILD / "fursoy_s0.dtb"

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "fail",
        "scope": "canonical DTS/DTB structural verification (25 checks)",
        "observed_at_utc": datetime.now(timezone.utc).isoformat(),
        "source_sha256": {
            str(DTS_FILE.relative_to(ROOT)): sha(DTS_FILE),
            str(Path(__file__).resolve().relative_to(ROOT)): sha(Path(__file__).resolve()),
        },
        "checks": {},
    }

    checks = {}

    try:
        # Check 1: DTS compiles successfully with dtc
        compile_cmd = ["dtc", "-I", "dts", "-O", "dtb", "-o", str(DTB_FILE), str(DTS_FILE)]
        comp = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True, text=True, timeout=30)
        checks["01_dts_compiles"] = (comp.returncode == 0)
        if comp.returncode != 0:
            raise RuntimeError(f"dtc compilation failed:\n{comp.stderr}")

        report["dtb_sha256"] = sha(DTB_FILE)
        dtb_bytes = DTB_FILE.read_bytes()
        dtb_size = len(dtb_bytes)

        # Check 2: DTB decompiles/parses cleanly
        decomp_cmd = ["dtc", "-I", "dtb", "-O", "dts", str(DTB_FILE)]
        decomp = subprocess.run(decomp_cmd, cwd=ROOT, capture_output=True, text=True, timeout=30)
        checks["02_dtb_decompiles"] = (decomp.returncode == 0)
        if decomp.returncode != 0:
            raise RuntimeError(f"dtc decompilation failed:\n{decomp.stderr}")

        dts_text = decomp.stdout

        # FDT binary header validation
        magic, totalsize, off_struct, off_strings, off_rsvmap, version, last_comp_version, boot_cpuid = struct.unpack(">8I", dtb_bytes[:32])
        header_valid = (magic == 0xd00dfeed) and (totalsize == dtb_size) and (boot_cpuid == 0)

        # Check 3: Root compatible exact
        # In decompiled output, strings in property lists are separated by null bytes \0
        root_compat_ok = bool(re.search(r'compatible = "fursoy,slice0-soc\\0fursoy,fursoy-s0";', dts_text))
        checks["03_root_compatible_exact"] = root_compat_ok

        # Check 4: One hart, Hart 0 only
        # Look for cpu@0 and ensure no other cpu@ nodes exist
        cpu_nodes = re.findall(r'cpu@[0-9a-fA-F]+', dts_text)
        checks["04_one_hart_0_only"] = (cpu_nodes == ["cpu@0"])

        # Check 5: ISA string exact
        checks["05_isa_string_exact"] = bool(re.search(r'riscv,isa = "rv64ima_zicsr_zifencei";', dts_text))

        # Check 6: riscv,isa-extensions exact
        checks["06_isa_extensions_exact"] = bool(re.search(r'riscv,isa-extensions = "i\\0m\\0a\\0zicsr\\0zifencei";', dts_text))

        # Check 7: Sv39 declaration
        checks["07_mmu_type_sv39"] = bool(re.search(r'mmu-type = "riscv,sv39";', dts_text))

        # Check 8: 10 MHz timebase frequency
        # 10,000,000 in hex is 0x989680
        checks["08_timebase_10mhz"] = bool(re.search(r'timebase-frequency = <0x989680>;', dts_text))

        # Check 9: Memory base 0x80000000
        # Check 10: Memory size 256 MiB (0x10000000)
        checks["09_memory_base_0x80000000"] = bool(re.search(r'memory@80000000\s*\{[^}]*reg = <0x00 0x80000000 0x00 0x10000000>;', dts_text))
        checks["10_memory_size_256mib"] = checks["09_memory_base_0x80000000"]

        # Check 11: Reserved firmware base 0x80000000, size 2 MiB (0x00200000)
        checks["11_firmware_reserved_base_size"] = bool(re.search(r'firmware_sbi@80000000\s*\{[^}]*reg = <0x00 0x80000000 0x00 0x200000>;', dts_text))

        # Check 12: Firmware region has no-map
        checks["12_firmware_has_nomap"] = bool(re.search(r'firmware_sbi@80000000\s*\{[^}]*no-map;', dts_text))

        # Check 13: No active CLINT node exists
        checks["13_no_active_clint_node"] = not bool(re.search(r'clint@[0-9a-fA-F]+', dts_text))

        # Check 14: No riscv,clint0
        checks["14_no_riscv_clint0"] = ("riscv,clint0" not in dts_text)

        # Check 15: No sifive,clint0
        checks["15_no_sifive_clint0"] = ("sifive,clint0" not in dts_text)

        # Check 16: PLIC base 0x0C000000 and aperture 4 MiB (0x00400000)
        checks["16_plic_base_aperture"] = bool(re.search(r'plic@c000000\s*\{[^}]*reg = <0x00 0xc000000 0x00 0x400000>;', dts_text))

        # Check 17: PLIC source count exact (31 sources -> 0x1f)
        checks["17_plic_source_count_31"] = bool(re.search(r'riscv,ndev = <0x1f>;', dts_text))

        # Check 18: PLIC S-context binding correct (cpu0_intc 11 M, 9 S)
        # In decompiled output, phandle 0x01 is cpu0_intc: interrupts-extended = <0x01 0x0b 0x01 0x09>;
        checks["18_plic_s_context_binding"] = bool(re.search(r'interrupts-extended = <0x01 0x0b 0x01 0x09>;', dts_text))

        # Check 19: UART base 0x10000000 and aperture 4 KiB (0x00001000)
        checks["19_uart_base_aperture"] = bool(re.search(r'serial@10000000\s*\{[^}]*reg = <0x00 0x10000000 0x00 0x1000>;', dts_text))

        # Check 20: UART reg-shift = 2
        checks["20_uart_reg_shift_2"] = bool(re.search(r'reg-shift = <0x02>;', dts_text))

        # Check 21: UART reg-io-width = 4
        checks["21_uart_reg_io_width_4"] = bool(re.search(r'reg-io-width = <0x04>;', dts_text))

        # Check 22: UART interrupt = PLIC Source 1
        checks["22_uart_interrupt_source_1"] = bool(re.search(r'serial@10000000\s*\{[^}]*interrupts = <0x01>;', dts_text))

        # Check 23: stdout-path resolves to UART
        checks["23_stdout_path_resolves_to_uart"] = bool(re.search(r'stdout-path = "/soc/serial@10000000:115200n8";', dts_text))

        # Check 24: No riscv-virtio compatible
        checks["24_no_riscv_virtio"] = ("riscv-virtio" not in dts_text)

        # Check 25: DTB fits safely at 0x82000000 without overlapping firmware (0x8000_0000..0x801F_FFFF) or kernel (0x8020_0000..0x81FF_FFFF)
        dtb_load_addr = 0x82000000
        dtb_end_addr = dtb_load_addr + dtb_size
        checks["25_dtb_safe_placement_no_overlap"] = (
            header_valid and
            (dtb_load_addr >= 0x82000000) and
            (dtb_end_addr <= 0x82100000) and # 1 MiB DTB aperture limit
            (dtb_size < 65536)
        )

        all_passed = all(checks.values()) and (len(checks) == 25)
        report["checks"] = checks
        report["dtb_size_bytes"] = dtb_size
        report["fdt_header"] = {
            "magic": hex(magic),
            "totalsize": totalsize,
            "boot_cpuid_phys": boot_cpuid,
            "version": version,
        }

        if all_passed:
            report["status"] = "pass"
            print("Canonical DTS/DTB verification: pass (25/25 checks)")
        else:
            failed = [k for k, v in checks.items() if not v]
            report["status"] = "fail"
            report["failed_checks"] = failed
            print(f"FAIL: {len(failed)} checks failed: {failed}", file=sys.stderr)

    except Exception as e:
        report["error"] = str(e)
        print(f"ERROR: {e}", file=sys.stderr)

    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if report["status"] == "pass" else 1

if __name__ == "__main__":
    sys.exit(main())
