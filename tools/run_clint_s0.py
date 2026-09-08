"""Build and run the single-hart CLINT-style adapter test."""
from datetime import datetime, timezone
import hashlib, json, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/platform/fursoy_s0_clint.sv"
TB = ROOT / "verification/clint_s0_tb.cpp"
BUILD = ROOT / "build/clint_s0"
REPORT = ROOT / "results/clint-s0.json"

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    report = {"status":"fail", "scope":"single-hart CLINT-style MMIO adapter; no core or PLIC integration",
              "observed_at_utc":datetime.now(timezone.utc).isoformat(),
              "source_sha256":{str(p.relative_to(ROOT)):sha(p) for p in (RTL, TB, Path(__file__).resolve())}}
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        command=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_clint","--Mdir",str(BUILD),str(RTL),str(TB)]
        with (BUILD/"build.log").open("w",encoding="utf-8") as log:
            build=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120,check=False)
        if build.returncode: raise RuntimeError(f"Build failed: {BUILD/'build.log'}")
        sim=subprocess.run([str(BUILD/"Vfursoy_s0_clint")],cwd=ROOT,capture_output=True,text=True,timeout=20,check=False)
        if sim.returncode: raise RuntimeError(f"Simulation failed: {sim.stdout}\n{sim.stderr}")
        report.update(status="pass",build_command=command,simulation=json.loads(sim.stdout))
        print("Slice-0 CLINT-style platform adapter: pass")
    except Exception as error:
        report["error"]=str(error); print(f"ERROR: {error}",file=sys.stderr)
    REPORT.parent.mkdir(parents=True,exist_ok=True); REPORT.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    return 0 if report["status"]=="pass" else 1
if __name__ == "__main__": sys.exit(main())
