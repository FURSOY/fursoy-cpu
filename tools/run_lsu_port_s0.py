"""Build and run one-outstanding LSU port handshake test."""
from pathlib import Path
from datetime import datetime,timezone
import subprocess,json,hashlib,sys
R=Path(__file__).resolve().parents[1];S=R/"rtl/core/fursoy_s0_lsu_port.sv";T=R/"verification/lsu_port_s0_tb.cpp";B=R/"build/lsu_port_s0";O=R/"results/lsu-port-s0.json"
def main():
 x={"status":"fail","scope":"DUT LSU port; no core integration","observed_at_utc":datetime.now(timezone.utc).isoformat(),"source_sha256":{str(p.relative_to(R)):hashlib.sha256(p.read_bytes()).hexdigest()for p in(S,T,Path(__file__).resolve())}}
 try:
  B.mkdir(parents=True,exist_ok=True);q=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_lsu_port","--Mdir",str(B),str(S),str(T)]
  with(B/"build.log").open("w")as l:z=subprocess.run(q,cwd=R,stdout=l,stderr=subprocess.STDOUT,timeout=120,check=False)
  if z.returncode:raise RuntimeError(f"Build failed: {B/'build.log'}")
  z=subprocess.run([str(B/"Vfursoy_s0_lsu_port")],cwd=R,capture_output=True,text=True,timeout=20,check=False)
  if z.returncode:raise RuntimeError(f"Simulation failed: {z.stderr.strip()}")
  x.update({"status":"pass","build_command":q,"simulation":json.loads(z.stdout)});print("Slice-0 LSU port DUT: pass")
 except(Exception)as e:x["error"]=str(e);print(str(e),file=sys.stderr)
 O.parent.mkdir(parents=True,exist_ok=True);O.write_text(json.dumps(x,indent=2)+"\n");return 0 if x["status"]=="pass"else 1
if __name__=="__main__":sys.exit(main())
