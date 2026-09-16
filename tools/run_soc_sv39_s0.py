"""Verify that the platform rejects page-table walks into the CLINT MMIO window."""
from datetime import datetime,timezone
from pathlib import Path
import hashlib,json,subprocess,sys
R=Path(__file__).resolve().parents[1];S=[R/"rtl/core/fursoy_s0_l1i.sv",R/"rtl/core/fursoy_s0_int_alu.sv",R/"rtl/core/fursoy_s0_control.sv",R/"rtl/core/fursoy_s0_lsu_decode.sv",R/"rtl/core/fursoy_s0_lsu_port.sv",R/"rtl/core/fursoy_s0_csr.sv",R/"rtl/core/fursoy_s0_pmp_check.sv",R/"rtl/core/fursoy_s0_pmp.sv",R/"rtl/core/fursoy_s0_tlb.sv",R/"rtl/core/fursoy_s0_l1d.sv",R/"rtl/core/fursoy_s0_mmu.sv",R/"rtl/core/fursoy_s0_core.sv",R/"rtl/platform/fursoy_s0_clint.sv",R/"rtl/platform/fursoy_s0_plic.sv",R/"rtl/platform/fursoy_s0_uart.sv",R/"rtl/platform/fursoy_s0_soc.sv"]
T=R/"verification/soc_sv39_s0_tb.cpp";B=R/"build/soc_sv39_s0";O=R/"results/soc-sv39-s0.json"
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 r={"status":"fail","scope":"Sv39 RAM-only PTW platform rejection","observed_at_utc":datetime.now(timezone.utc).isoformat(),"source_sha256":{str(p.relative_to(R)):sha(p) for p in [*S,T,Path(__file__).resolve()]}}
 try:
  B.mkdir(parents=True,exist_ok=True);q=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_soc","-GRESET_MTVEC=64'h0000000080000300","--Mdir",str(B),*map(str,S),str(T)]
  with(B/"build.log").open("w",encoding="utf-8")as l:z=subprocess.run(q,cwd=R,stdout=l,stderr=subprocess.STDOUT,timeout=120)
  if z.returncode:raise RuntimeError(f"build failed: {B/'build.log'}")
  z=subprocess.run([str(B/"Vfursoy_s0_soc")],cwd=R,capture_output=True,text=True,timeout=30)
  if z.returncode:raise RuntimeError("simulation failed:\n"+z.stdout+z.stderr)
  r.update(status="pass",build_command=q,simulation=json.loads(z.stdout));print("Sv39 SoC PTW rejection DUT: pass")
 except Exception as e:r["error"]=str(e);print(f"ERROR: {e}",file=sys.stderr)
 O.parent.mkdir(parents=True,exist_ok=True);O.write_text(json.dumps(r,indent=2)+"\n",encoding="utf-8");return 0 if r["status"]=="pass" else 1
if __name__=="__main__":sys.exit(main())
