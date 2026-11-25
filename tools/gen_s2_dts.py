#!/usr/bin/env python3
"""Parameterized Multi-Hart Device Tree Generator for Fursoy Slice-2 SMP SoC (S2-M5)."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BOOTARGS = "console=ttyS0 earlycon=sbi root=/dev/ram0 rw rdinit=/init"


def render_dts(
    num_harts: int,
    bootargs: str = DEFAULT_BOOTARGS,
    timebase_hz: int = 10_000_000,
    dram_size: int = 0x1000_0000,
) -> str:
    if num_harts < 1 or num_harts > 8:
        raise ValueError(f"Unsupported num_harts={num_harts} (expected 1..8)")

    cpu_nodes: list[str] = []
    clint_irqs: list[str] = []
    plic_irqs: list[str] = []

    for h in range(num_harts):
        cpu_nodes.append(
            f"""        cpu@{h} {{
            device_type = "cpu";
            reg = <{h}>;
            status = "okay";
            compatible = "riscv";
            riscv,isa = "rv64imafd_zba_zbb_zicsr_zifencei";
            mmu-type = "riscv,sv39";

            i-cache-size = <16384>;
            i-cache-block-size = <64>;
            i-cache-sets = <64>;
            d-cache-size = <16384>;
            d-cache-block-size = <64>;
            d-cache-sets = <64>;

            cpu{h}_intc: interrupt-controller {{
                #interrupt-cells = <1>;
                compatible = "riscv,cpu-intc";
                interrupt-controller;
            }};
        }};"""
        )
        # CLINT: M-mode software (3) and M-mode timer (7)
        clint_irqs.append(f"&cpu{h}_intc 3 &cpu{h}_intc 7")
        # PLIC: Context 2*h = M-External (11), Context 2*h+1 = S-External (9)
        plic_irqs.append(f"&cpu{h}_intc 11 &cpu{h}_intc 9")

    cpus_block = "\n\n".join(cpu_nodes)
    clint_irq_str = " ".join(clint_irqs)
    plic_irq_str = " ".join(plic_irqs)
    dram_size_hi = (dram_size >> 32) & 0xFFFF_FFFF
    dram_size_lo = dram_size & 0xFFFF_FFFF

    return f"""/dts-v1/;

/ {{
    #address-cells = <2>;
    #size-cells = <2>;
    compatible = "fursoy,slice2-smp-soc", "fursoy,fursoy-s2";
    model = "Fursoy Slice-2 SMP RISC-V SoC ({num_harts}-Hart)";

    cpus {{
        #address-cells = <1>;
        #size-cells = <0>;
        timebase-frequency = <{timebase_hz}>;

{cpus_block}
    }};

    memory@80000000 {{
        device_type = "memory";
        reg = <0x0 0x80000000 0x{dram_size_hi:x} 0x{dram_size_lo:08x}>;
    }};

    reserved-memory {{
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;

        firmware_sbi@80000000 {{
            reg = <0x0 0x80000000 0x0 0x00200000>;
            no-map;
        }};
    }};

    soc {{
        #address-cells = <2>;
        #size-cells = <2>;
        compatible = "simple-bus";
        ranges;

        clint@2000000 {{
            compatible = "sifive,clint0", "riscv,clint0";
            reg = <0x0 0x02000000 0x0 0x00010000>;
            interrupts-extended = <{clint_irq_str}>;
        }};

        plic: plic@c000000 {{
            compatible = "sifive,plic-1.0.0", "riscv,plic0";
            reg = <0x0 0x0c000000 0x0 0x04000000>;
            #interrupt-cells = <1>;
            interrupt-controller;
            riscv,ndev = <31>;
            interrupts-extended = <{plic_irq_str}>;
        }};

        uart@10000000 {{
            compatible = "ns16550a";
            reg = <0x0 0x10000000 0x0 0x00001000>;
            interrupt-parent = <&plic>;
            interrupts = <1>;
            clock-frequency = <10000000>;
            current-speed = <115200>;
            reg-shift = <2>;
            reg-io-width = <4>;
        }};
    }};

    chosen {{
        bootargs = "{bootargs}";
        stdout-path = "/soc/uart@10000000:115200n8";
    }};
}};
"""


def compile_dtb(dts_path: Path, dtb_path: Path) -> None:
    dtb_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["dtc", "-I", "dts", "-O", "dtb", "-o", str(dtb_path), str(dts_path)]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"dtc failed for {dts_path}:\n{res.stdout}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate parameterized Fursoy Slice-2 SMP DTS/DTB")
    parser.add_argument("--num-harts", type=int, required=True, help="Number of RISC-V harts (e.g. 2 or 4)")
    parser.add_argument("--bootargs", default=DEFAULT_BOOTARGS, help="Kernel /chosen bootargs string")
    parser.add_argument("--timebase-hz", type=int, default=10_000_000, help="CLINT timebase frequency in Hz")
    parser.add_argument("--dram-size", type=lambda x: int(x, 0), default=0x1000_0000, help="DRAM size in bytes")
    parser.add_argument("--out-dts", type=Path, required=True, help="Output .dts path")
    parser.add_argument("--out-dtb", type=Path, default=None, help="Optional output .dtb path (compiled via dtc)")
    args = parser.parse_args()

    dts_text = render_dts(
        num_harts=args.num_harts,
        bootargs=args.bootargs,
        timebase_hz=args.timebase_hz,
        dram_size=args.dram_size,
    )
    args.out_dts.parent.mkdir(parents=True, exist_ok=True)
    args.out_dts.write_text(dts_text, encoding="utf-8")
    print(f"[DTS] Generated {args.out_dts} ({args.num_harts} harts, {len(dts_text)} bytes)")

    if args.out_dtb is not None:
        compile_dtb(args.out_dts, args.out_dtb)
        print(f"[DTB] Compiled  {args.out_dtb} ({args.out_dtb.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
