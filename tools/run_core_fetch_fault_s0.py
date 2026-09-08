"""Build and run precise instruction-fetch access-fault verification."""
from datetime import datetime,timezone
import hashlib,json,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];BUILD=ROOT/"build/core_fetch_fault_s0"
TB=ROOT/"verification/core_fetch_fault_s0_tb.cpp";REPORT=ROOT/"results/core-fetch-fault-s0.json"
RTL=[ROOT/"rtl/core/fursoy_s0_fetch.sv",ROOT/"rtl/core/fursoy_s0_int_alu.sv",
ROOT/"rtl/core/fursoy_s0_control.sv",ROOT/"rtl/core/fursoy_s0_lsu_decode.sv",
ROOT/"rtl/core/fursoy_s0_lsu_port.sv",ROOT/"rtl/core/fursoy_s0_csr.sv",ROOT/"rtl/core/fursoy_s0_mmu.sv",ROOT/"rtl/core/fursoy_s0_core.sv"]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 r={"status":"fail","scope":"precise instruction-fetch access fault", "observed_at_utc":datetime.now(timezone.utc).isoformat(),"source_sha256":{str(p.relative_to(ROOT)):sha(p) for p in [*RTL,TB,Path(__file__).resolve()]}}
 try:
  BUILD.mkdir(parents=True,exist_ok=True);cmd=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_core","-GRESET_MTVEC=64'h0000000080000100","--Mdir",str(BUILD),*map(str,RTL),str(TB)]
  with (BUILD/"build.log").open("w",encoding="utf-8") as log:b=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120)
  if b.returncode:raise RuntimeError(f"build failed: {BUILD/'build.log'}")
  s=subprocess.run([str(BUILD/"Vfursoy_s0_core")],cwd=ROOT,capture_output=True,text=True,timeout=20)
  if s.returncode:raise RuntimeError("simulation failed:\n"+s.stdout+s.stderr)
  r.update(status="pass",build_command=cmd,simulation=json.loads(s.stdout));print("Slice-0 precise instruction-fetch access fault: pass")
 except Exception as e:r["error"]=str(e);print(f"ERROR: {e}",file=sys.stderr)
 REPORT.parent.mkdir(parents=True,exist_ok=True);REPORT.write_text(json.dumps(r,indent=2)+"\n",encoding="utf-8");return 0 if r["status"]=="pass" else 1
if __name__=="__main__":sys.exit(main())
