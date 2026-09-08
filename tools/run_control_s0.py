"""Build and run RV64I branch/jump control decode tests."""
from datetime import datetime, timezone
import hashlib, json
from pathlib import Path
import subprocess, sys
ROOT = Path(__file__).resolve().parents[1]
RTL, TB = ROOT / "rtl/core/fursoy_s0_control.sv", ROOT / "verification/control_s0_tb.cpp"
BUILD, REPORT = ROOT / "build/control_s0", ROOT / "results/control-s0.json"
def main():
    report = {"status":"fail", "scope":"DUT RV64I branch/jump decode only", "observed_at_utc":datetime.now(timezone.utc).isoformat(), "source_sha256":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (RTL,TB,Path(__file__).resolve())}}
    try:
        BUILD.mkdir(parents=True, exist_ok=True)
        cmd=["verilator","--cc","--exe","--build","--assert","-Wall","-j","2","--top-module","fursoy_s0_control","--Mdir",str(BUILD),str(RTL),str(TB)]
        with (BUILD/"build.log").open("w",encoding="utf-8") as log: built=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=120,check=False)
        if built.returncode: raise RuntimeError(f"Build failed: {BUILD/'build.log'}")
        run=subprocess.run([str(BUILD/"Vfursoy_s0_control")],cwd=ROOT,capture_output=True,text=True,timeout=20,check=False)
        if run.returncode: raise RuntimeError(f"Simulation failed: {run.stderr.strip()}")
        report.update({"build_command":cmd,"simulation":json.loads(run.stdout),"status":"pass"}); print("Slice-0 control DUT: pass")
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as error: report["error"]=str(error); print(str(error),file=sys.stderr)
    REPORT.parent.mkdir(parents=True,exist_ok=True); REPORT.write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    return 0 if report["status"]=="pass" else 1
if __name__ == "__main__": sys.exit(main())
