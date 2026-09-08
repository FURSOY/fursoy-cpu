"""Build and test the Slice-0 Zicsr decode/RMW block."""
from datetime import datetime,timezone
from pathlib import Path
import hashlib,json,subprocess,sys
R=Path(__file__).resolve().parents[1];S=R/"rtl/core/fursoy_s0_csr.sv";T=R/"verification/csr_s0_tb.cpp";B=R/"build/csr_s0";O=R/"results/csr-s0.json"
def main():
 x={"status":"fail","scope":"DUT Zicsr decode and RMW calculation","observed_at_utc":datetime.now(timezone.utc).isoformat(),"source_sha256":{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest()for p in(S,T,Path(__file__).resolve())}}
 try:
  B.mkdir(parents=True,exist_ok=True);q=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_csr","--Mdir",str(B),str(S),str(T)]
  with(B/"build.log").open("w",encoding="utf-8")as l:z=subprocess.run(q,cwd=R,stdout=l,stderr=subprocess.STDOUT,timeout=120,check=False)
  if z.returncode:raise RuntimeError(f"Build failed: {B/'build.log'}")
  z=subprocess.run([str(B/"Vfursoy_s0_csr")],cwd=R,capture_output=True,text=True,timeout=20,check=False)
  if z.returncode:raise RuntimeError(f"Simulation failed: {z.stderr.strip()}")
  x.update({"status":"pass","build_command":q,"simulation":json.loads(z.stdout)});print("Slice-0 Zicsr DUT: pass")
 except(Exception)as e:x["error"]=str(e);print(str(e),file=sys.stderr)
 O.parent.mkdir(parents=True,exist_ok=True);O.write_text(json.dumps(x,indent=2)+"\n",encoding="utf-8");return 0 if x["status"]=="pass"else 1
if __name__=="__main__":sys.exit(main())
