#!/usr/bin/env python3
"""
Fursoy S2.5-M2a Official RISCOF (riscv-arch-test) Compliance Runner.

Runs official riscv-arch-test suites via RISCOF against:
  - DUT: Fursoy Slice-1/2 RTL (`fursoy_s1_core` via Verilator `verification/s25_riscof_tb.cpp`)
  - REF: Prebuilt `sail-riscv v0.16` (`tools/sail/bin/bin/sail_riscv_sim`)

Enabled official suites (matching Fursoy's claimed scalar + Sv39 ISA):
  I, M, A, F, D, B (Zba + Zbb only), Zifencei, hints, privilege (non-C), vm_sv39

Excluded non-implemented suites are explicitly logged with technical reasons in
results/s25-riscof.json. All third-party tools/repos live under gitignored
build/riscof_env/.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from s1_rtl_manifest import CORE_RTL, ROOT
from s2_verilator_lib import compute_rtl_sha256, get_build_jobs

RISCOF_ENV = ROOT / "build/riscof_env"
VENV_BIN = RISCOF_ENV / "venv/bin"
RISCOF_BIN = VENV_BIN / "riscof"
ARCH_TEST_DIR = RISCOF_ENV / "riscv-arch-test"
ARCH_SUITE_ROOT = ARCH_TEST_DIR / "riscv-test-suite/rv64i_m"
ARCH_ENV_DIR = ARCH_TEST_DIR / "riscv-test-suite/env"

SAIL_BIN = ROOT / "tools/sail/bin/bin/sail_riscv_sim"
SAIL_BASE_CFG = ROOT / "tools/sail/fursoy_s1_sail_config.json"
DUT_TB_CPP = ROOT / "verification/s25_riscof_tb.cpp"
DUT_BUILD_DIR = ROOT / "build/s25_riscof"
REPORT_PATH = ROOT / "results/s25-riscof.json"

ENABLED_SUITES = [
    "I",
    "M",
    "A",
    "F",
    "D",
    "B",
    "Zifencei",
    "hints",
    "privilege",
    "vm_sv39",
]

EXCLUDED_SUITES_JUSTIFICATION = {
    "C": "RVC 16-bit compressed instructions not implemented (deferred to Slice-3+)",
    "D_Zcd": "Requires C/Zcd compressed FP instructions (not implemented)",
    "D_Zfa": "Zfa additional FP instructions not implemented",
    "F_Zfa": "Zfa additional FP instructions not implemented",
    "Zfh": "Half-precision FP (Zfh/Zfhmin) not implemented",
    "Zfinx": "FP-in-GPR (Zfinx) mutually exclusive with F",
    "Zdinx": "FP-in-GPR (Zdinx) mutually exclusive with D",
    "Zhinx": "FP-in-GPR (Zhinx) not implemented",
    "Zicond": "Zicond conditional ops not implemented",
    "Zimop": "Zimop may-be-operations not implemented",
    "Zcmop": "Zcmop compressed may-be-operations not implemented",
    "Zacas": "Zacas atomic compare-and-swap not implemented",
    "CMO": "Zicbom/Zicboz cache management ops not implemented (deferred to Slice-3+)",
    "K": "Scalar cryptography (Zk*) not implemented",
    "P_unratified": "Unratified P-extension packed SIMD not implemented",
    "Svadu": "Hardware PTE A/D update (Svadu) not implemented; Fursoy implements Svade (fault on A=0/D=0)",
    "pmp": "Programmable PMP CSRs not implemented on fursoy_s1_core (deferred to Slice-3+)",
    "vm_pmp": "Requires programmable PMP CSRs (deferred to Slice-3+)",
    "vm_sv48": "Sv48 4-level paging not implemented (Fursoy implements Bare + Sv39)",
    "vm_sv57": "Sv57 5-level paging not implemented (Fursoy implements Bare + Sv39)",
}

MODEL_TEST_H = r"""#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#define RVMODEL_HALT                                              \
  fence rw, rw;                                                   \
  li x1, 1;                                                       \
  .global write_tohost;                                           \
  write_tohost:                                                   \
    sw x1, tohost, t5;                                            \
    j write_tohost;

#define RVMODEL_BOOT

#define RVMODEL_DATA_BEGIN                                        \
  RVMODEL_DATA_SECTION                                            \
  .align 4;                                                       \
  .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                          \
  .align 4; .global end_signature; end_signature:

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif // _COMPLIANCE_MODEL_H
"""

LINK_LD = r"""OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .data.string : { *(.data.string) }
  .bss : { *(.bss) }
  _end = .;
}
"""

FURSOY_ISA_YAML = """hart_ids: [0]
hart0:
  ISA: RV64IMAFDSUZicsr_Zifencei_Zba_Zbb
  physical_addr_sz: 56
  User_Spec_Version: '2.3'
  Privilege_Spec_Version: '1.11'
  hw_data_misaligned_support: false
  supported_xlen: [64]
  misa:
    reset-val: 0x8000000000141129
    rv64:
      accessible: true
      mxl:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              - mxl[1:0] in [0x2]
            wr_illegal:
              - Unchanged
      extensions:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              - extensions[25:0] bitmask [0x0141129, 0x0000000]
            wr_illegal:
              - Unchanged
  satp:
    reset-val: 0x0
    rv64:
      accessible: true
      mode:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              - mode[3:0] in [0x0, 0x8]
            wr_illegal:
              - Unchanged
      asid:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              - asid[15:0] in [0x0:0xffff]
            wr_illegal:
              - Unchanged
      ppn:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              - ppn[43:0] in [0x0:0xfffffffffff]
            wr_illegal:
              - Unchanged
"""

FURSOY_PLATFORM_YAML = """mtime:
  implemented: true
  address: 0x0200bff8
mtimecmp:
  implemented: true
  address: 0x02004000
nmi:
  label: nmi_vector
reset:
  label: reset_vector
"""

FURSOY_RUN_HELPER = r'''#!/usr/bin/env python3
"""Helper invoked by riscof_fursoy Makefile to run one ELF on Verilator DUT."""
import struct, subprocess, sys
from pathlib import Path

def get_sym(elf: Path, sym: str) -> int:
    res = subprocess.run(["riscv64-unknown-elf-nm", "-n", str(elf)], capture_output=True, text=True, check=True)
    for line in res.stdout.splitlines():
        p = line.split()
        if len(p) == 3 and p[2] == sym:
            return int(p[0], 16)
    raise RuntimeError(f"Symbol {sym} not found in {elf}")

def extract_segs(elf: Path, out_dir: Path) -> list[tuple[int, Path]]:
    data = elf.read_bytes()
    e_phoff, = struct.unpack_from("<Q", data, 32)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, _flags, p_offset, _vaddr, p_paddr, p_filesz, p_memsz, _align = struct.unpack_from("<IIQQQQQQ", data, off)
        if p_type == 1 and p_memsz > 0:
            buf = bytearray(data[p_offset : p_offset + p_filesz])
            if p_memsz > p_filesz:
                buf.extend(b"\x00" * (p_memsz - p_filesz))
            sp = out_dir / f"dut_seg{i}.bin"
            sp.write_bytes(buf)
            segs.append((p_paddr, sp))
    return segs

def main() -> int:
    tb_exe = Path(sys.argv[1])
    elf = Path(sys.argv[2])
    sig_out = Path(sys.argv[3])
    gran = sys.argv[4]
    work = elf.parent

    halt_pc = get_sym(elf, "write_tohost")
    sig_begin = get_sym(elf, "begin_signature")
    sig_end = get_sym(elf, "end_signature")
    segs = extract_segs(elf, work)

    cmd = [
        str(tb_exe),
        "--sig-out", str(sig_out),
        "--halt-pc", f"{halt_pc:x}",
        "--sig-begin", f"{sig_begin:x}",
        "--sig-end", f"{sig_end:x}",
        "--sig-gran", gran,
        "--max-cycles", "2500000",
    ]
    for pa, sp in segs:
        cmd.extend(["--seg", f"{pa:x}:{sp}"])
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        return r.returncode
    return 0

if __name__ == "__main__":
    sys.exit(main())
'''

RISCOF_FURSOY_PLUGIN = r'''import os
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

class fursoy(pluginTemplate):
    __model__ = "fursoy_s1_core"
    __version__ = "s2.5-m2a"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        self.num_jobs = str(config.get('jobs', '4'))
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        self.tb_exe = os.path.abspath(config['tb_exe'])
        self.helper_py = os.path.abspath(config['helper_py'])

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.compile_cmd = (
            'riscv64-unknown-elf-gcc -march=rv64imafd_zicsr_zifencei_zba_zbb '
            '-mabi=lp64d -static -mcmodel=medany -mno-relax -Wl,--no-relax '
            '-fvisibility=hidden -nostdlib -nostartfiles '
            '-T ' + self.pluginpath + '/env/link.ld '
            '-I ' + self.pluginpath + '/env/ '
            '-I ' + archtest_env
        )

    def build(self, isa_yaml, platform_yaml):
        pass

    def runTests(self, testList):
        mk_path = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(mk_path):
            os.remove(mk_path)
        make = utils.makeUtil(makefilePath=mk_path)
        make.makeCommand = 'make -k -j' + self.num_jobs
        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            elf = 'dut.elf'
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            macros = ' '.join(['-D' + m for m in testentry['macros']])
            cmd = (
                f'@cd {test_dir}; '
                f'{self.compile_cmd} {test} -o {elf} {macros}; '
                f'python3 {self.helper_py} {self.tb_exe} {elf} {sig_file} 4'
            )
            make.add_target(cmd)
        make.execute_all(self.work_dir)
'''

RISCOF_SAIL_PLUGIN = r'''import os
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

class sail_cSim(pluginTemplate):
    __model__ = "sail_riscv_sim"
    __version__ = "0.16"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        self.num_jobs = str(config.get('jobs', '4'))
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.sail_bin = os.path.abspath(config['sail_bin'])
        self.sail_cfg = os.path.abspath(config['sail_cfg'])

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.compile_cmd = (
            'riscv64-unknown-elf-gcc -march=rv64imafd_zicsr_zifencei_zba_zbb '
            '-mabi=lp64d -static -mcmodel=medany -mno-relax -Wl,--no-relax '
            '-fvisibility=hidden -nostdlib -nostartfiles '
            '-T ' + self.pluginpath + '/env/link.ld '
            '-I ' + self.pluginpath + '/env/ '
            '-I ' + archtest_env
        )

    def build(self, isa_yaml, platform_yaml):
        pass

    def runTests(self, testList, cgf_file=None):
        mk_path = os.path.join(self.work_dir, "Makefile." + self.name[:-1])
        if os.path.exists(mk_path):
            os.remove(mk_path)
        make = utils.makeUtil(makefilePath=mk_path)
        make.makeCommand = 'make -k -j' + self.num_jobs
        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            elf = 'ref.elf'
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")
            macros = ' '.join(['-D' + m for m in testentry['macros']])
            cmd = (
                f'@cd {test_dir}; '
                f'{self.compile_cmd} {test} -o {elf} {macros}; '
                f'{self.sail_bin} --config {self.sail_cfg} --signature-granularity 4 '
                f'--test-signature {sig_file} {elf} > ref.log 2>&1'
            )
            make.add_target(cmd)
        make.execute_all(self.work_dir)
'''


def build_dut_tb() -> Path:
    DUT_BUILD_DIR.mkdir(parents=True, exist_ok=True)
    obj_dir = DUT_BUILD_DIR / "obj_dir"
    exe = obj_dir / "Vfursoy_s1_core"
    deps = [*CORE_RTL, DUT_TB_CPP]
    if exe.exists():
        mtime = exe.stat().st_mtime
        if all(p.exists() and p.stat().st_mtime <= mtime for p in deps):
            print(f"[RISCOF] Reusing fresh Verilator DUT harness: {exe.relative_to(ROOT)}")
            return exe

    jobs = get_build_jobs()
    cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "-j",
        str(jobs),
        "-Wno-UNOPTFLAT",
        "-Wno-WIDTH",
        "-Wno-CASEINCOMPLETE",
        "--x-assign",
        "0",
        "--x-initial",
        "0",
        "-CFLAGS",
        "-O3",
        "-Irtl/core",
        "--top-module",
        "fursoy_s1_core",
        "--Mdir",
        str(obj_dir),
        *map(str, CORE_RTL),
        str(DUT_TB_CPP),
    ]
    print(f"[RISCOF] Building Verilator DUT harness Vfursoy_s1_core (-O3 -j{jobs})...")
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Verilator build failed:\n{res.stdout}\n{res.stderr}")
    return exe


def write_sail_riscof_config(out_path: Path) -> None:
    cfg = json.loads(SAIL_BASE_CFG.read_text(encoding="utf-8"))
    # Align Sail config strictly with Fursoy's implemented M/S/U + Sv39 + Svade + non-H + non-C ISA
    cfg["base"]["medeleg"]["delegatable_bits"]["value"] = "0x0000_0000_0000_b3ff"
    cfg["base"]["mideleg"]["delegatable_bits"]["value"] = "0x0000_0000_0000_0222"
    cfg["base"]["xtval_nonzero"]["software_breakpoint"] = False
    exts = cfg["extensions"]
    for name in (
        "H", "Sdtrig",
        "Sha", "Shcounterenw", "Shvsatpa", "Shvstvala", "Shvstvecd", "Shgatpa", "Shtvala",
        "Svadu", "Svpbmt", "Svnapot", "Svrsw60t59b", "Sv48", "Sv57", "Zicclsm",
        "Zbs", "Zbc", "Zicond", "Zfa", "Zfh", "Zfhmin", "Zfbfmin",
        "Zvfh", "Zvfhmin", "Zvfbfmin", "Zvfbfwma",
    ):
        if name in exts and isinstance(exts[name], dict) and "supported" in exts[name]:
            exts[name]["supported"] = False
    exts["Stateen"]["Smstateen"]["supported"] = False
    exts["Stateen"]["Ssstateen"]["supported"] = False
    exts["Stateen"]["mstateen0"]["CONTEXT"] = "CSRBit_ReadOnlyZero"
    exts["Svade"]["supported"] = True
    exts["Sv39"]["supported"] = True
    exts["Svbare"]["supported"] = True
    out_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")

    chk = subprocess.run([str(SAIL_BIN), "--config", str(out_path), "--validate-config"], capture_output=True, text=True)
    if chk.returncode != 0:
        raise RuntimeError(f"Sail config validation failed:\n{chk.stdout}\n{chk.stderr}")


def setup_plugins_and_suite(tb_exe: Path) -> tuple[Path, Path, Path]:
    plugins_dir = RISCOF_ENV / "plugins"
    dut_dir = plugins_dir / "fursoy"
    ref_dir = plugins_dir / "sail_cSim"
    for d in (dut_dir / "env", ref_dir / "env"):
        d.mkdir(parents=True, exist_ok=True)

    (dut_dir / "env/model_test.h").write_text(MODEL_TEST_H, encoding="utf-8")
    (dut_dir / "env/link.ld").write_text(LINK_LD, encoding="utf-8")
    (ref_dir / "env/model_test.h").write_text(MODEL_TEST_H, encoding="utf-8")
    (ref_dir / "env/link.ld").write_text(LINK_LD, encoding="utf-8")

    (dut_dir / "fursoy_isa.yaml").write_text(FURSOY_ISA_YAML, encoding="utf-8")
    (dut_dir / "fursoy_platform.yaml").write_text(FURSOY_PLATFORM_YAML, encoding="utf-8")
    helper_py = dut_dir / "run_dut_elf.py"
    helper_py.write_text(FURSOY_RUN_HELPER, encoding="utf-8")
    (dut_dir / "riscof_fursoy.py").write_text(RISCOF_FURSOY_PLUGIN, encoding="utf-8")

    sail_cfg = ref_dir / "fursoy_riscof_sail_config.json"
    write_sail_riscof_config(sail_cfg)
    (ref_dir / "__init__.py").write_text("", encoding="utf-8")
    (ref_dir / "riscof_sail_cSim.py").write_text(RISCOF_SAIL_PLUGIN, encoding="utf-8")

    jobs = get_build_jobs()
    cfg_ini = plugins_dir / "config.ini"
    cfg_ini.write_text(
        f"""[RISCOF]
ReferencePlugin=sail_cSim
ReferencePluginPath={ref_dir}
DUTPlugin=fursoy
DUTPluginPath={dut_dir}

[fursoy]
pluginpath={dut_dir}
ispec={dut_dir}/fursoy_isa.yaml
pspec={dut_dir}/fursoy_platform.yaml
tb_exe={tb_exe}
helper_py={helper_py}
jobs={jobs}

[sail_cSim]
pluginpath={ref_dir}
sail_bin={SAIL_BIN}
sail_cfg={sail_cfg}
jobs={jobs}
""",
        encoding="utf-8",
    )

    enabled_suite_dir = RISCOF_ENV / "enabled_suite"
    if enabled_suite_dir.exists():
        shutil.rmtree(enabled_suite_dir)
    enabled_suite_dir.mkdir(parents=True, exist_ok=True)
    for s in ENABLED_SUITES:
        src = ARCH_SUITE_ROOT / s
        if not src.exists():
            raise RuntimeError(f"Expected riscv-arch-test suite missing: {src}")
        shutil.copytree(src, enabled_suite_dir / s)

    work_dir = RISCOF_ENV / "work"
    return cfg_ini, enabled_suite_dir, work_dir


def parse_signature_results(work_dir: Path) -> tuple[dict[str, dict], list[dict], list[str]]:
    import yaml  # local venv or system

    tl_path = work_dir / "test_list.yaml"
    tl = yaml.safe_load(tl_path.read_text(encoding="utf-8"))
    per_suite: dict[str, dict] = {}
    failures: list[dict] = []

    for test_rel, entry in sorted(tl.items()):
        parts = Path(test_rel).parts
        # Path inside enabled_suite/<suite>/src/<test>.S
        suite_name = "unknown"
        for idx, tok in enumerate(parts):
            if tok == "enabled_suite" and idx + 1 < len(parts):
                suite_name = parts[idx + 1]
                break
        if suite_name not in per_suite:
            per_suite[suite_name] = {"passed": 0, "failed": 0, "total": 0}
        per_suite[suite_name]["total"] += 1

        wdir = Path(entry["work_dir"])
        dut_sig = wdir / "dut/DUT-fursoy_s1_core.signature"
        ref_sig = wdir / "ref/Reference-sail_riscv_sim.signature"
        ok = False
        reason = ""
        if not dut_sig.exists():
            reason = "missing DUT signature"
        elif not ref_sig.exists():
            reason = "missing REF signature"
        else:
            d_lines = [l.strip().lower() for l in dut_sig.read_text().splitlines() if l.strip()]
            r_lines = [l.strip().lower() for l in ref_sig.read_text().splitlines() if l.strip()]
            if len(d_lines) == 0:
                reason = "empty DUT signature"
            elif d_lines != r_lines:
                first_diff = next((i for i, (a, b) in enumerate(zip(d_lines, r_lines)) if a != b), min(len(d_lines), len(r_lines)))
                reason = (
                    f"signature mismatch at line {first_diff} "
                    f"(len dut={len(d_lines)} ref={len(r_lines)}): "
                    f"dut={d_lines[first_diff] if first_diff < len(d_lines) else 'EOF'} "
                    f"ref={r_lines[first_diff] if first_diff < len(r_lines) else 'EOF'}"
                )
            else:
                ok = True

        if ok:
            per_suite[suite_name]["passed"] += 1
        else:
            per_suite[suite_name]["failed"] += 1
            failures.append({"suite": suite_name, "test": Path(test_rel).name, "reason": reason, "work_dir": str(wdir)})

    # Also compute excluded tests inside enabled suites (e.g., Zbs/Zbc inside B, C tests inside privilege)
    selected_names = {Path(k).name for k in tl.keys()}
    excluded_within_enabled: list[str] = []
    for s in ENABLED_SUITES:
        for p in sorted((ARCH_SUITE_ROOT / s / "src").glob("*.S")):
            if p.name not in selected_names:
                excluded_within_enabled.append(f"{s}/{p.name}")

    return per_suite, failures, excluded_within_enabled


def main() -> int:
    t0 = time.time()
    if not RISCOF_BIN.exists() or not ARCH_SUITE_ROOT.exists():
        print("ERROR: RISCOF environment not initialized under build/riscof_env/", file=sys.stderr)
        return 1

    tb_exe = build_dut_tb()
    cfg_ini, enabled_suite_dir, work_dir = setup_plugins_and_suite(tb_exe)
    if work_dir.exists():
        shutil.rmtree(work_dir)

    print("[RISCOF] Running official RISCOF compliance suite (DUT=fursoy_s1_core vs REF=sail-riscv v0.16)...")
    cmd = [
        str(RISCOF_BIN),
        "run",
        f"--config={cfg_ini}",
        f"--suite={enabled_suite_dir}",
        f"--env={ARCH_ENV_DIR}",
        f"--work-dir={work_dir}",
        "--no-browser",
    ]
    res = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    log_path = RISCOF_ENV / "riscof_run.log"
    log_path.write_text(res.stdout + "\n" + res.stderr, encoding="utf-8")

    # Parse signatures using venv python if needed (fallback to pyyaml already available)
    sys.path.insert(0, str(RISCOF_ENV / "venv/lib/python3.12/site-packages"))
    per_suite, failures, excluded_within_enabled = parse_signature_results(work_dir)

    total_tests = sum(v["total"] for v in per_suite.values())
    total_passed = sum(v["passed"] for v in per_suite.values())
    total_failed = sum(v["failed"] for v in per_suite.values())

    riscof_ver = subprocess.run([str(RISCOF_BIN), "--version"], capture_output=True, text=True).stdout.strip()
    arch_sha = subprocess.run(
        ["git", "-C", str(ARCH_TEST_DIR), "rev-parse", "HEAD"], capture_output=True, text=True
    ).stdout.strip()
    arch_desc = subprocess.run(
        ["git", "-C", str(ARCH_TEST_DIR), "describe", "--tags", "--always"], capture_output=True, text=True
    ).stdout.strip()
    sail_ver = subprocess.run([str(SAIL_BIN), "--version"], capture_output=True, text=True).stdout.strip()

    excluded_suites_counts = {}
    for s, reason in EXCLUDED_SUITES_JUSTIFICATION.items():
        d = ARCH_SUITE_ROOT / s / "src"
        cnt = len(list(d.glob("*.S"))) if d.exists() else 0
        excluded_suites_counts[s] = {"test_count": cnt, "reason": reason}

    overall_pass = (res.returncode == 0) and (total_failed == 0) and (total_tests > 0)
    report = {
        "milestone": "S2.5-M2a",
        "status": "pass" if overall_pass else "fail",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "elapsed_seconds": round(time.time() - t0, 2),
        "rtl_sha256": compute_rtl_sha256(),
        "versions": {
            "riscof": riscof_ver,
            "riscv_arch_test_commit": arch_sha,
            "riscv_arch_test_tag": arch_desc,
            "sail_riscv": sail_ver,
        },
        "isa_string": "RV64IMAFDSUZicsr_Zifencei_Zba_Zbb",
        "hw_data_misaligned_support": False,
        "riscof_exit_code": res.returncode,
        "summary": {
            "total_tests": total_tests,
            "passed": total_passed,
            "failed": total_failed,
            "pass_rate_pct": round(100.0 * total_passed / total_tests, 2) if total_tests else 0.0,
        },
        "per_suite": per_suite,
        "failures": failures,
        "excluded_suites": excluded_suites_counts,
        "excluded_within_enabled_suites": {
            "count": len(excluded_within_enabled),
            "reason": "Automatically filtered by riscof/riscv-config for non-implemented sub-extensions (Zbs/Zbc inside B; C-extension misaligned tests inside privilege)",
            "tests": excluded_within_enabled,
        },
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print("\n" + "=" * 80)
    print(f"RISCOF COMPLIANCE SUMMARY ({total_passed}/{total_tests} PASS, {total_failed} FAIL, rc={res.returncode})")
    print("=" * 80)
    for s in ENABLED_SUITES:
        st = per_suite.get(s, {"passed": 0, "failed": 0, "total": 0})
        print(f"  {s:14s}: {st['passed']:3d} / {st['total']:3d} PASS ({st['failed']} fail)")
    if failures:
        print("\nFAILURES:")
        for f in failures[:30]:
            print(f"  [FAIL] {f['suite']}/{f['test']}: {f['reason']}")
    print(f"\nReport written: {REPORT_PATH.relative_to(ROOT)} (elapsed {report['elapsed_seconds']}s)")
    return 0 if overall_pass else 1


if __name__ == "__main__":
    sys.exit(main())
