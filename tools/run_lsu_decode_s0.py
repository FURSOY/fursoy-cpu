"""Build and run the RV64I LSU decode test."""
from datetime import datetime,timezone
import hashlib,json
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[1]; RTL=ROOT/"rtl/core/fursoy_s0_lsu_decode.sv"; TB=ROOT/"verification/lsu_decode_s0_tb.cpp"; BUILD=ROOT/"build/lsu_decode_s0"; REPORT=ROOT/"results/lsu-decode-s0.json"
def main():
 r={"status":"fail","scope":"DUT LSU decode only; no memory transaction","observed_at_utc":datetime.now(timezone.utc).isoformat(),"source_sha256":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (RTL,TB,Path(__file__).resolve())}}
 try:
  BUILD.mkdir(parents=True,exist_ok=True); c=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_lsu_decode","--Mdir",str(BUILD),str(RTL),str(TB)]
  with (BUILD/"build.log").open("w",encoding="utf-8") as l:b=subprocess.run(c,cwd=ROOT,stdout=l,stderr=subprocess.STDOUT,timeout=120,check=False)
  if b.returncode:raise RuntimeError(f"Build failed: {BUILD/'build.log'}")
  x=subprocess.run([str(BUILD/"Vfursoy_s0_lsu_decode")],cwd=ROOT,capture_output=True,text=True,timeout=20,check=False)
  if x.returncode:raise RuntimeError(f"Simulation failed: {x.stderr.strip()}")
  r.update({"build_command":c,"simulation":json.loads(x.stdout),"status":"pass"});print("Slice-0 LSU decode DUT: pass")
 except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as x:r["error"]=str(x);print(str(x),file=sys.stderr)
 REPORT.parent.mkdir(parents=True,exist_ok=True);REPORT.write_text(json.dumps(r,indent=2)+"\n",encoding="utf-8");return 0 if r["status"]=="pass" else 1
if __name__=="__main__":sys.exit(main())
