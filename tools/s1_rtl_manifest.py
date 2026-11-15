"""Centralized RTL file lists and manifest hashing for Fursoy Slice-1 runners."""

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

CORE_RTL: list[Path] = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_ks_adder.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_frat.sv",
    ROOT / "rtl/core/fursoy_s1_fprf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
    ROOT / "rtl/core/fursoy_s1_prf.sv",
    ROOT / "rtl/core/fursoy_s1_fprf.sv",
    ROOT / "rtl/core/fursoy_s1_vrf.sv",
    ROOT / "rtl/core/fursoy_s1_alu.sv",
    ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
    ROOT / "rtl/core/fursoy_s1_multiplier.sv",
    ROOT / "rtl/core/fursoy_s1_divider.sv",
    ROOT / "rtl/core/fursoy_s1_port1_buffers.sv",
    ROOT / "rtl/core/fursoy_s1_int_iq.sv",
    ROOT / "rtl/core/fursoy_s1_agu.sv",
    ROOT / "rtl/core/fursoy_s1_mem_iq.sv",
    ROOT / "rtl/core/fursoy_s1_trt.sv",
    ROOT / "rtl/core/fursoy_s1_lsu_queues.sv",
    ROOT / "rtl/core/fursoy_s1_l1d.sv",
    ROOT / "rtl/core/fursoy_s1_lsu.sv",
    ROOT / "rtl/core/fursoy_s1_fma.sv",
    ROOT / "rtl/core/fursoy_s1_fdiv.sv",
    ROOT / "rtl/core/fursoy_s1_fconv.sv",
    ROOT / "rtl/core/fursoy_s1_fp_iq.sv",
    ROOT / "rtl/core/fursoy_s1_vec_iq.sv",
    ROOT / "rtl/core/fursoy_s1_backend.sv",
    ROOT / "rtl/core/fursoy_s1_bpu.sv",
    ROOT / "rtl/core/fursoy_s1_ptw.sv",
    ROOT / "rtl/core/fursoy_s1_itlb.sv",
    ROOT / "rtl/core/fursoy_s1_l1i.sv",
    ROOT / "rtl/core/fursoy_s1_fetch_queue.sv",
    ROOT / "rtl/core/fursoy_s1_decode.sv",
    ROOT / "rtl/core/fursoy_s1_serialization.sv",
    ROOT / "rtl/core/fursoy_s1_csr.sv",
    ROOT / "rtl/core/fursoy_s1_hpm.sv",
    ROOT / "rtl/core/fursoy_s1_frontend.sv",
    ROOT / "rtl/core/fursoy_s1_core.sv",
]

# M6/M7 verification subset (core minus M8 FP/Vec compute modules)
_M8_ONLY_MODULES = {
    "fursoy_s1_fma.sv",
    "fursoy_s1_fdiv.sv",
    "fursoy_s1_fconv.sv",
    "fursoy_s1_fp_iq.sv",
    "fursoy_s1_vrf.sv",
    "fursoy_s1_vec_iq.sv",
}

M6_M7_CORE_RTL: list[Path] = [p for p in CORE_RTL if p.name not in _M8_ONLY_MODULES]

M3_CORE_RTL: list[Path] = [
    ROOT / "rtl/core/fursoy_s1_pkg.sv",
    ROOT / "rtl/core/fursoy_s1_ks_adder.sv",
    ROOT / "rtl/core/fursoy_s1_freelist.sv",
    ROOT / "rtl/core/fursoy_s1_rat.sv",
    ROOT / "rtl/core/fursoy_s1_prf_status.sv",
    ROOT / "rtl/core/fursoy_s1_rob.sv",
    ROOT / "rtl/core/fursoy_s1_substrate.sv",
    ROOT / "rtl/core/fursoy_s1_prf.sv",
    ROOT / "rtl/core/fursoy_s1_alu.sv",
    ROOT / "rtl/core/fursoy_s1_branch_unit.sv",
    ROOT / "rtl/core/fursoy_s1_multiplier.sv",
    ROOT / "rtl/core/fursoy_s1_divider.sv",
    ROOT / "rtl/core/fursoy_s1_port1_buffers.sv",
    ROOT / "rtl/core/fursoy_s1_int_iq.sv",
    ROOT / "rtl/core/fursoy_s1_mem_iq.sv",
    ROOT / "rtl/core/fursoy_s1_agu.sv",
    ROOT / "rtl/core/fursoy_s1_trt.sv",
    ROOT / "rtl/core/fursoy_s1_l1d.sv",
    ROOT / "rtl/core/fursoy_s1_lsu_queues.sv",
    ROOT / "rtl/core/fursoy_s1_lsu.sv",
    ROOT / "rtl/core/fursoy_s1_backend.sv",
    ROOT / "rtl/core/fursoy_s1_core.sv",
]

PLATFORM_RTL: list[Path] = [
    ROOT / "rtl/platform/fursoy_s0_clint.sv",
    ROOT / "rtl/platform/fursoy_s0_plic.sv",
    ROOT / "rtl/platform/fursoy_s0_uart.sv",
    ROOT / "rtl/platform/fursoy_s1_soc.sv",
]

SOC_RTL: list[Path] = CORE_RTL + PLATFORM_RTL


def sha256_file(path: Path) -> str:
    """Return the hex SHA-256 digest of a single file."""
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def compute_manifest_sha256(files: list[Path]) -> str:
    """Return the sorted filename+content SHA-256 digest matching closeout runners."""
    h = hashlib.sha256()
    for f in sorted(files, key=lambda p: p.name):
        h.update(f.name.encode("utf-8"))
        h.update(f.read_bytes())
    return h.hexdigest()


def compute_path_manifest_sha256(files: list[Path]) -> str:
    """Return the null-delimited relative-path+content SHA-256 digest used by lint/early runners."""
    h = hashlib.sha256()
    for p in sorted(files, key=lambda x: str(x.relative_to(ROOT))):
        h.update(str(p.relative_to(ROOT)).replace("\\", "/").encode("utf-8") + b"\0")
        h.update(p.read_bytes() + b"\0")
    return h.hexdigest()


HISTORICAL_ACCEPTED_RTL_MANIFEST_SHA256S: set[str] = {
    "65874197b14e386f80023e9419650d4ec180134d7db02937a7e6ca7dba0d1e42",  # M6 Closeout Freeze
    "8c53e566fa83df6d694a286982a2ccfc66050ea29cf0af56a9b5b2ff2d0f91e5",  # M7 Phase A Expansion
    "e4390576a7c65e4908b779fbcd60e127d7b0bd965d988093fd56c5143ca1eaf4",  # M7 Phase B Expansion
    "30e5f88882c78c413eee9aaa88527b42df402a3fc0ac682a74786d8d5fbf6003",  # M7 Phase D / M7 Closeout
    "03598b7836f34036b5f3ca4081a6cd438d1030fba140f43bd620d29b881da79b",  # M8 Phase A Final
    "4d6fc54a6efb0d0deb94d4416926bd769c0783871499075f5de434959206d7cb",  # M8 Closeout Freeze
    "8fd9aa9634cf71a8c00f49df0a0b8bbc1becdc2bcd441b4e486b33cfbac2430d",  # M8 Phase B Pre-remediation
    "cf08268b3b900a3233b35ddb6b4d10b3cb8aa988656f103aefcb717109b827d2",  # M8 Phase B Final
    "69a94959bb1a03684f35146a940b119b85cef3e365a695f67221b0c83acd6a2f",  # M8 Phase C Final
    "b5f823b9dcb8395127193852f6afcdf31518fbb4e9dd270d9e7c3920cdc0350f",  # M8 Phase D Final
    "c3cdd842b5373b1371dfaf33ac9da198d84eb3bf4783b104f90dc180d1604408",  # M8 Phase E Final
    "dd3d03b09557277172e8d1805fd139d58802a5b6fd873a908805e7c2f7615896",  # M9 Phase A (34-file)
    "e7ff340ce1cd422951fd24c45a537f280948eb7c1e9bb942120b4462a075546a",  # M9 Phase A (40-file)
    "128c675f924dc208bc73026b8263aab90583173855c87d47a316907c83460912",  # M9 Phase B (40-file)
    "e303802320fbbf21ed07872429bbbeb395a6c73995c96cdab95966198a8f7670",  # M9 Phase B (31-file)
    "e39bd500b2587dbc64351a9d5cfe115a602aed91cb5d2dac401739dd29f86100",  # M9 Phase D (40-file)
    "53741012bd63803978aca787b91780f4e3d3a3271ba3ecd808225575c1e0fa52",  # M9 Phase D (31-file)
    "7c7b86ccfce14735c8bdf985cf7c07682b36b41cbdd5eabd15c1b9a795883167",  # M9 Closeout (40-file)
    "ced10f73147edcafe442edf22406aa0a3eafd4dba013b6b8d45524d25c1acea3",  # M9 Closeout (31-file)
    "8297a6370982ee81b02177fdd88f060bae09f055034ed73aa414bcc99061f6d8",  # Stage 3 Pre-CSR-fix (40-file)
    "1487b2312db2996d3ef0fa384f304e610301641a315775460457ddcea86f5969",  # Stage 3 Pre-CSR-fix (34-file)
    "bf5e9b7bced04d4ad464144e959378a55166129cb0ab5986efc1d3ed58641291",  # Stage 3 Closure Final (40-file)
    "a8c15faf4692d45393e06ddb3bcb12b68d4a04f326a71c1de242627175c99ed2",  # Stage 3 Closure Final (34-file)
    "d14fc6aec206c120786f5865b60154a56efded9e8aae10c94fdb121166112420",  # Post-Issue #1/#2/#3 RTL Fixes (40-file)
    "9db77eb51a4ea1ee283e4e892bb233018c379ed4ee6308f0b70f1141f00bcc35",  # Post-Issue #1/#2/#3 RTL Fixes (34-file)
    "0729a82a815597a51578e67ee068241fd179e2ec59eba5e9d3e38806f4763600",  # Post-Issue #4 Fixes (40-file)
    "c3350da8f092bf4e449badb1c082b336aa0ff6a5266192a59b55a229fc57cc48",  # Post-Issue #4 Fixes (34-file)
    "46dffaacd8a27e4d8dd9d395fddfeac6fe3abbc8697eba3c0cd79c22978750d4",  # FCONV/FMA/FDIV Fix
    "77ef60fb0e250641aab40a3c03989678f799f409de3e13b2f2b2c52e94d2c3c3",  # Sail Cosim Closure (40-file)
    "49b14995cabfe11101f42122d70aeafe1e1851fdae848df57f2956dc9e9c7905",  # Sail Cosim Closure (34-file)
    "0889e47e98000b4c9f41e8a7d8682d26490bc34b5b9971a2c39db40249cc625b",  # Post-Review P1/P2 Fixes (40-file)
    "395f311c62d2ab545f2fe7646a1f7796de5ec48684ca71cf84e7ebe0c1dd6fb5",  # Post-Review P1/P2 Fixes (34-file)
}

ACCEPTED_RTL_MANIFEST_SHA256S: set[str] = HISTORICAL_ACCEPTED_RTL_MANIFEST_SHA256S | {
    compute_manifest_sha256(CORE_RTL),
    compute_manifest_sha256(M6_M7_CORE_RTL),
}
