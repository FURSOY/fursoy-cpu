#!/usr/bin/env python3
"""Build minimal BusyBox initramfs archive for Fursoy Slice-0."""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOTFS = ROOT / "build/initramfs_root"
KERNEL_DIR = ROOT / "build/linux-6.6.50"
GEN_CPIO = KERNEL_DIR / "usr/gen_init_cpio"
CPIO_OUT = ROOT / "build/initramfs.cpio"
LIST_FILE = ROOT / "build/initramfs_list.txt"

def main():
    if not ROOTFS.exists():
        raise RuntimeError(f"Rootfs directory {ROOTFS} not found. Run prepare_initramfs first.")

    lines = [
        "# Device nodes",
        "dir /dev 0755 0 0",
        "nod /dev/console 0600 0 0 c 5 1",
        "nod /dev/null 0666 0 0 c 1 3",
        "nod /dev/zero 0666 0 0 c 1 5",
        "nod /dev/tty 0666 0 0 c 5 0",
        "nod /dev/ttyS0 0660 0 0 c 4 64",
    ]

    # Walk ROOTFS
    for dirpath, dirnames, filenames in os.walk(ROOTFS):
        rel_dir = os.path.relpath(dirpath, ROOTFS)
        if rel_dir != ".":
            norm_dir = "/" + rel_dir.replace("\\", "/")
            lines.append(f"dir {norm_dir} 0755 0 0")
        
        # Files and symlinks
        for name in filenames:
            full_path = os.path.join(dirpath, name)
            rel_file = "/" + os.path.relpath(full_path, ROOTFS).replace("\\", "/")
            if os.path.islink(full_path):
                target = os.readlink(full_path)
                lines.append(f"slink {rel_file} {target} 0777 0 0")
            elif os.path.isfile(full_path):
                mode = "0755" if os.access(full_path, os.X_OK) else "0644"
                lines.append(f"file {rel_file} {full_path} {mode} 0 0")

    LIST_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"[INITRAMFS] Wrote {len(lines)} entries to {LIST_FILE}")

    # Run gen_init_cpio
    with open(CPIO_OUT, "wb") as out_f:
        cmd = [str(GEN_CPIO), str(LIST_FILE)]
        subprocess.run(cmd, cwd=ROOT, stdout=out_f, check=True)

    print(f"[INITRAMFS] Generated {CPIO_OUT} ({CPIO_OUT.stat().st_size} bytes)")

    # Copy to kernel tree
    k_dest = KERNEL_DIR / "usr/initramfs_data.cpio"
    k_dest.write_bytes(CPIO_OUT.read_bytes())
    print(f"[INITRAMFS] Updated {k_dest}")

if __name__ == "__main__":
    main()
