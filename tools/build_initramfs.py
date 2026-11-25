#!/usr/bin/env python3
"""Build minimal BusyBox initramfs archive for Fursoy Slice-0 (--mode s0) or Slice-2 SMP (--mode s2)."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOTFS = ROOT / "build/initramfs_root"
KERNEL_DIR = ROOT / "build/linux-6.6.50"
GEN_CPIO = KERNEL_DIR / "usr/gen_init_cpio"
CPIO_OUT = ROOT / "build/initramfs.cpio"
LIST_FILE = ROOT / "build/initramfs_list.txt"

MUSL_URL = "https://deb.debian.org/debian/pool/main/m/musl/musl_1.2.5.orig.tar.gz"
MUSL_TARBALL = ROOT / "build/musl-1.2.5.tar.gz"
MUSL_SRC_DIR = ROOT / "build/musl-1.2.5"
MUSL_PREFIX = ROOT / "build/musl-rv64ima"

S2_CPIO_OUT = ROOT / "build/initramfs_s2.cpio"
S2_SMP_TEST_SRC = ROOT / "software/initramfs/s2_smp_test.c"
S2_SMP_TEST_BIN = ROOT / "build/s2_m5/s2_smp_test"
S2_INIT_SH = ROOT / "software/initramfs/init_s2.sh"


def parse_newc_cpio(cpio_bytes: bytes) -> list[dict]:
    """Parse an SVR4 newc ('070701') cpio archive in pure Python."""
    entries: list[dict] = []
    off = 0
    n = len(cpio_bytes)
    while off + 110 <= n:
        magic = cpio_bytes[off : off + 6]
        if magic != b"070701":
            raise RuntimeError(f"Unsupported cpio magic {magic!r} at offset {off}")
        mode = int(cpio_bytes[off + 14 : off + 22], 16)
        uid = int(cpio_bytes[off + 22 : off + 30], 16)
        gid = int(cpio_bytes[off + 30 : off + 38], 16)
        nlink = int(cpio_bytes[off + 38 : off + 46], 16)
        mtime = int(cpio_bytes[off + 46 : off + 54], 16)
        filesize = int(cpio_bytes[off + 54 : off + 62], 16)
        rmajor = int(cpio_bytes[off + 78 : off + 86], 16)
        rminor = int(cpio_bytes[off + 86 : off + 94], 16)
        namesize = int(cpio_bytes[off + 94 : off + 102], 16)
        name = cpio_bytes[off + 110 : off + 110 + namesize - 1].decode("utf-8")
        off = (off + 110 + namesize + 3) & ~3
        if name == "TRAILER!!!":
            break
        payload = cpio_bytes[off : off + filesize]
        off = (off + filesize + 3) & ~3
        entries.append(
            {
                "name": name.lstrip("/"),
                "mode": mode,
                "uid": uid,
                "gid": gid,
                "nlink": nlink,
                "mtime": mtime,
                "rmajor": rmajor,
                "rminor": rminor,
                "data": payload,
            }
        )
    return entries


def encode_newc_cpio(entries: list[dict]) -> bytes:
    """Serialize entries into an SVR4 newc ('070701') cpio archive in pure Python."""
    chunks: list[bytes] = []
    ino = 1
    for e in entries:
        name_b = e["name"].encode("utf-8") + b"\x00"
        data_b = e.get("data", b"")
        nlink = e.get("nlink", 2 if stat.S_ISDIR(e["mode"]) else 1)
        hdr = (
            f"070701"
            f"{ino:08x}"
            f"{e['mode']:08x}"
            f"{e.get('uid', 0):08x}"
            f"{e.get('gid', 0):08x}"
            f"{nlink:08x}"
            f"{e.get('mtime', 0):08x}"
            f"{len(data_b):08x}"
            f"{0:08x}{0:08x}"
            f"{e.get('rmajor', 0):08x}"
            f"{e.get('rminor', 0):08x}"
            f"{len(name_b):08x}"
            f"{0:08x}"
        ).encode("ascii")
        chunks.append(hdr)
        chunks.append(name_b)
        pad_n = (-(110 + len(name_b))) & 3
        if pad_n:
            chunks.append(b"\x00" * pad_n)
        if data_b:
            chunks.append(data_b)
            pad_d = (-len(data_b)) & 3
            if pad_d:
                chunks.append(b"\x00" * pad_d)
        ino += 1

    trailer_name = b"TRAILER!!!\x00"
    trailer_hdr = (
        f"070701{0:08x}{0:08x}{0:08x}{0:08x}{1:08x}{0:08x}{0:08x}"
        f"{0:08x}{0:08x}{0:08x}{0:08x}{len(trailer_name):08x}{0:08x}"
    ).encode("ascii")
    chunks.append(trailer_hdr)
    chunks.append(trailer_name)
    pad_t = (-(110 + len(trailer_name))) & 3
    if pad_t:
        chunks.append(b"\x00" * pad_t)
    raw = b"".join(chunks)
    # Pad archive end to 512-byte cpio block boundary
    rem = (-len(raw)) & 511
    if rem:
        raw += b"\x00" * rem
    return raw


def ensure_musl_rv64ima() -> Path:
    """Build a non-RVC (rv64ima / lp64) musl-1.2.5 sysroot for static SMP userspace binaries."""
    musl_gcc = MUSL_PREFIX / "bin/musl-gcc"
    libc_a = MUSL_PREFIX / "lib/libc.a"
    if musl_gcc.exists() and libc_a.exists():
        return musl_gcc

    MUSL_TARBALL.parent.mkdir(parents=True, exist_ok=True)
    if not MUSL_TARBALL.exists():
        print(f"[INITRAMFS-S2] Downloading musl-1.2.5 from {MUSL_URL}...")
        urllib.request.urlretrieve(MUSL_URL, MUSL_TARBALL)

    if not MUSL_SRC_DIR.exists():
        print(f"[INITRAMFS-S2] Extracting {MUSL_TARBALL.name}...")
        subprocess.run(["tar", "-xzf", str(MUSL_TARBALL), "-C", str(ROOT / "build")], check=True)

    print(f"[INITRAMFS-S2] Building rv64ima/lp64 musl-1.2.5 into {MUSL_PREFIX}...")
    build_dir = ROOT / "build/musl-rv64ima-obj"
    shutil.rmtree(build_dir, ignore_errors=True)
    build_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["CC"] = "riscv64-unknown-elf-gcc"
    env["CFLAGS"] = "-march=rv64ima -mabi=lp64 -O2"
    env["LDFLAGS"] = "-march=rv64ima -mabi=lp64"

    jobs = str(min(6, os.cpu_count() or 1))
    subprocess.run(
        [
            str(MUSL_SRC_DIR / "configure"),
            "--host=riscv64-linux-gnu",
            f"--prefix={MUSL_PREFIX}",
            "--disable-shared",
        ],
        cwd=build_dir,
        env=env,
        check=True,
    )
    subprocess.run(["make", f"-j{jobs}"], cwd=build_dir, env=env, check=True)
    subprocess.run(["make", "install"], cwd=build_dir, env=env, check=True)
    if not musl_gcc.exists():
        raise RuntimeError(f"Expected musl-gcc wrapper at {musl_gcc}")
    return musl_gcc


def compile_s2_smp_test() -> Path:
    """Compile software/initramfs/s2_smp_test.c as static RV64IMA (non-RVC) binary with pthreads."""
    ensure_musl_rv64ima()
    S2_SMP_TEST_BIN.parent.mkdir(parents=True, exist_ok=True)
    gcc_inc = subprocess.run(
        ["riscv64-unknown-elf-gcc", "-print-file-name=include"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    musl_lib = MUSL_PREFIX / "lib"

    cmd = [
        "riscv64-unknown-elf-gcc",
        "-std=c11",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-march=rv64imafd_zba_zbb",
        "-mabi=lp64",
        "-mstrict-align",
        "-D_REENTRANT",
        "-nostdinc",
        "-isystem", str(MUSL_PREFIX / "include"),
        "-isystem", gcc_inc,
        "-nostdlib",
        "-static",
        str(musl_lib / "crt1.o"),
        str(musl_lib / "crti.o"),
        str(S2_SMP_TEST_SRC),
        f"-L{musl_lib}",
        "-Wl,--start-group",
        "-lc",
        "-lgcc",
        "-Wl,--end-group",
        str(musl_lib / "crtn.o"),
        "-o",
        str(S2_SMP_TEST_BIN),
    ]
    print(f"[INITRAMFS-S2] Compiling {S2_SMP_TEST_SRC.relative_to(ROOT)} (static rv64ima + pthreads)...")
    res = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"Failed to compile s2_smp_test.c:\n{res.stdout}")

    # Verify zero RVC compressed instructions (ELF Flags must not have EF_RISCV_RVC=0x1)
    rd = subprocess.run(
        ["riscv64-linux-gnu-readelf", "-h", "-A", str(S2_SMP_TEST_BIN)],
        capture_output=True,
        text=True,
        check=True,
    )
    for line in rd.stdout.splitlines():
        if "Flags:" in line:
            parts = line.split("Flags:")[-1].strip().split()
            flags_val = int(parts[0], 16)
            if flags_val & 0x1:
                raise RuntimeError(f"s2_smp_test binary contains RVC instructions ({line.strip()})")
        if "Tag_RISCV_arch:" in line:
            print(f"[INITRAMFS-S2] Verified s2_smp_test ISA: {line.strip()}")
    return S2_SMP_TEST_BIN


def build_s0() -> None:
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

    for dirpath, _dirnames, filenames in os.walk(ROOTFS):
        rel_dir = os.path.relpath(dirpath, ROOTFS)
        if rel_dir != ".":
            norm_dir = "/" + rel_dir.replace("\\", "/")
            lines.append(f"dir {norm_dir} 0755 0 0")
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

    with open(CPIO_OUT, "wb") as out_f:
        subprocess.run([str(GEN_CPIO), str(LIST_FILE)], cwd=ROOT, stdout=out_f, check=True)
    print(f"[INITRAMFS] Generated {CPIO_OUT} ({CPIO_OUT.stat().st_size} bytes)")

    k_dest = KERNEL_DIR / "usr/initramfs_data.cpio"
    if k_dest.parent.exists():
        k_dest.write_bytes(CPIO_OUT.read_bytes())
        print(f"[INITRAMFS] Updated {k_dest}")


def build_s2(out_cpio: Path, kernel_dir: Path | None) -> Path:
    if not CPIO_OUT.exists():
        raise RuntimeError(
            f"Base Slice-1 BusyBox archive {CPIO_OUT} not found. "
            "Provide build/initramfs.cpio containing static RV64IMA BusyBox."
        )

    smp_bin = compile_s2_smp_test()
    base_entries = parse_newc_cpio(CPIO_OUT.read_bytes())

    # Curated BusyBox applet symlinks required by init_s2.sh and SMP regression checks
    # (trims ~380 unused applet symlinks so uncompressed populate_rootfs() completes rapidly)
    keep_applets = {
        "sh", "mount", "umount", "echo", "cat", "grep", "wc", "head", "tail",
        "uname", "ls", "mkdir", "rmdir", "rm", "cp", "mv", "touch", "dd",
        "sleep", "poweroff", "tr", "awk", "sed", "cut", "sort", "uniq",
        "nproc", "taskset", "test", "[", "expr", "seq", "true", "false",
        "kill", "ps", "dmesg", "free", "pwd", "id", "env", "md5sum", "sha256sum",
    }

    # Replace /init with init_s2.sh and inject /bin/s2_smp_test while preserving BusyBox,
    # mem_stress, directories, device nodes, and curated BusyBox symlinks.
    filtered: list[dict] = []
    seen_names: set[str] = set()
    for e in base_entries:
        name = e["name"]
        if name in ("init", "bin/s2_smp_test") or name in seen_names:
            continue
        if stat.S_ISLNK(e["mode"]):
            applet = name.rsplit("/", 1)[-1]
            if applet not in keep_applets:
                continue
        filtered.append(e)
        seen_names.add(name)

    if "bin" not in seen_names:
        filtered.append({"name": "bin", "mode": stat.S_IFDIR | 0o755, "nlink": 2, "data": b""})

    filtered.append(
        {
            "name": "init",
            "mode": stat.S_IFREG | 0o755,
            "nlink": 1,
            "data": S2_INIT_SH.read_bytes(),
        }
    )
    filtered.append(
        {
            "name": "bin/s2_smp_test",
            "mode": stat.S_IFREG | 0o755,
            "nlink": 1,
            "data": smp_bin.read_bytes(),
        }
    )

    out_cpio.parent.mkdir(parents=True, exist_ok=True)
    archive = encode_newc_cpio(filtered)
    out_cpio.write_bytes(archive)
    print(f"[INITRAMFS-S2] Generated {out_cpio} ({len(filtered)} entries, {len(archive)} bytes)")

    if kernel_dir is not None and (kernel_dir / "usr").exists():
        k_dest = kernel_dir / "usr/initramfs_data.cpio"
        k_dest.write_bytes(archive)
        print(f"[INITRAMFS-S2] Updated {k_dest}")
    return out_cpio


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Fursoy initramfs archive (s0 or s2 SMP)")
    parser.add_argument("--mode", choices=("s0", "s2"), default="s0", help="Initramfs profile")
    parser.add_argument("--out", type=Path, default=None, help="Output cpio path (s2 mode)")
    parser.add_argument("--kernel-dir", type=Path, default=ROOT / "build/linux-6.6.50-smp", help="Optional kernel dir to copy usr/initramfs_data.cpio into")
    args = parser.parse_args()

    if args.mode == "s0":
        build_s0()
    else:
        build_s2(args.out or S2_CPIO_OUT, args.kernel_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
