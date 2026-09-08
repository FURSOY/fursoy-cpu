"""Build and run the focused correctness-first Sv39 translation/PTW tests."""
from datetime import datetime, timezone
from pathlib import Path
import hashlib, json, subprocess, sys
R=Path(__file__).resolve().parents[1];S=R/"rtl/core/fursoy_s0_mmu.sv";T=R/"verification/sv39_mmu_s0_tb.cpp"
B=R/"build/sv39_mmu_s0";O=R/"results/sv39-mmu-s0.json"
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 r={"status":"fail","scope":"Sv39 translation, serialized PTW, fault taxonomy, cancellation and store retirement", "observed_at_utc":datetime.now(timezone.utc).isoformat(),"source_sha256":{str(p.relative_to(R)):sha(p) for p in [S,T,Path(__file__).resolve()]}}
 try:
  B.mkdir(parents=True,exist_ok=True);q=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_mmu","--Mdir",str(B),str(S),str(T)]
  with (B/"build.log").open("w",encoding="utf-8") as l:z=subprocess.run(q,cwd=R,stdout=l,stderr=subprocess.STDOUT,timeout=120)
  if z.returncode:raise RuntimeError(f"build failed: {B/'build.log'}")
  z=subprocess.run([str(B/"Vfursoy_s0_mmu")],cwd=R,capture_output=True,text=True,timeout=30)
  if z.returncode:raise RuntimeError("simulation failed:\n"+z.stdout+z.stderr)
  r.update(status="pass",build_command=q,simulation=json.loads(z.stdout));print("Sv39 MMU/PTW DUT: pass")
 except Exception as e:r["error"]=str(e);print(f"ERROR: {e}",file=sys.stderr)
 O.parent.mkdir(parents=True,exist_ok=True);O.write_text(json.dumps(r,indent=2)+"\n",encoding="utf-8");return 0 if r["status"]=="pass" else 1
if __name__=="__main__":sys.exit(main())
