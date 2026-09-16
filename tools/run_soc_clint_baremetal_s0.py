"""Build and run the core/RAM/CLINT architectural MMIO integration probe."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/"build/soc_clint_baremetal_s0"
REPORT=ROOT/"results/soc-clint-baremetal-s0.json"
SOURCE=ROOT/"software/baremetal/clint_irq_probe.S"
LINK=ROOT/"software/baremetal/link.ld"
TB=ROOT/"verification/soc_clint_baremetal_s0_tb.cpp"
RTL=[ROOT/"rtl/core/fursoy_s0_l1i.sv",ROOT/"rtl/core/fursoy_s0_int_alu.sv",
     ROOT/"rtl/core/fursoy_s0_control.sv",ROOT/"rtl/core/fursoy_s0_lsu_decode.sv",
     ROOT/"rtl/core/fursoy_s0_lsu_port.sv",ROOT/"rtl/core/fursoy_s0_csr.sv",
     ROOT/"rtl/core/fursoy_s0_pmp_check.sv",ROOT/"rtl/core/fursoy_s0_pmp.sv",
     ROOT/"rtl/core/fursoy_s0_tlb.sv",ROOT/"rtl/core/fursoy_s0_l1d.sv",ROOT/"rtl/core/fursoy_s0_mmu.sv",
     ROOT/"rtl/core/fursoy_s0_core.sv",ROOT/"rtl/platform/fursoy_s0_clint.sv",
     ROOT/"rtl/platform/fursoy_s0_plic.sv",ROOT/"rtl/platform/fursoy_s0_uart.sv",ROOT/"rtl/platform/fursoy_s0_soc.sv"]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    files=[*RTL,SOURCE,LINK,TB,Path(__file__).resolve()]
    report={"status":"fail","scope":"single-hart CPU RAM/CLINT MMIO integration",
            "observed_at_utc":datetime.now(timezone.utc).isoformat(),
            "source_sha256":{str(p.relative_to(ROOT)):sha(p) for p in files}}
    try:
        BUILD.mkdir(parents=True,exist_ok=True);elf=BUILD/"clint_irq_probe.elf"
        gcc=["riscv64-unknown-elf-gcc","-march=rv64i_zicsr_zifencei","-mabi=lp64",
             "-mcmodel=medany","-mno-relax","-nostdlib","-nostartfiles","-Wl,--no-relax",
             "-Wl,--build-id=none","-T",str(LINK),str(SOURCE),"-o",str(elf)]
        b=subprocess.run(gcc,cwd=ROOT,capture_output=True,text=True,timeout=60)
        if b.returncode:raise RuntimeError("ELF build failed:\n"+b.stdout+b.stderr)
        nm=subprocess.run(["riscv64-unknown-elf-nm","-n",str(elf)],cwd=ROOT,capture_output=True,text=True,timeout=20)
        if nm.returncode:raise RuntimeError("nm failed:\n"+nm.stderr)
        symbols={parts[2]:int(parts[0],16) for line in nm.stdout.splitlines() if len(parts:=line.split())==3}
        fault_names=["bad_store","fault_width_load","fault_align_load","fault_with_pending_irq","ram_error_load"]
        fault_args=[hex(symbols[name]) for name in fault_names]
        cmd=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2",
             "--top-module","fursoy_s0_soc","--Mdir",str(BUILD/"obj"),
             *map(str,RTL),str(TB)]
        with (BUILD/"build.log").open("w",encoding="utf-8") as log:
            b=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120)
        if b.returncode:raise RuntimeError(f"Verilator build failed: {BUILD/'build.log'}")
        sim=subprocess.run([str(BUILD/"obj/Vfursoy_s0_soc"),str(elf),*fault_args],cwd=ROOT,capture_output=True,text=True,timeout=30)
        if sim.returncode:raise RuntimeError("simulation failed:\n"+sim.stdout+sim.stderr)
        report.update(status="pass",elf_sha256=sha(elf),fault_symbols={n:symbols[n] for n in fault_names},
                      build_command=cmd,simulation=json.loads(sim.stdout))
        print("Slice-0 core/RAM/CLINT bare-metal integration: pass")
    except Exception as e:
        report["error"]=str(e);print(f"ERROR: {e}",file=sys.stderr)
    REPORT.parent.mkdir(parents=True,exist_ok=True);REPORT.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    return 0 if report["status"]=="pass" else 1
if __name__=="__main__":sys.exit(main())
