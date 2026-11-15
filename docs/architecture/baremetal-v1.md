# Bare-Metal Test Platform v1

This memory map belongs to the bare-metal test environment; it is not the final SoC memory map or silicon reset vector.
Single hart, M-mode, little-endian RV64I_Zicsr_Zifencei. The loader places ELF `PT_LOAD` segments and zeros the `memsz - filesz` delta for BSS; startup code also clears BSS.
Program entry address is `0x80000000`. If the reference platform uses a reset ROM, it jumps to this entry point.

| Address | Purpose |
|---|---|
| `0x80000000`–`0x8000ffff` | Code and read-only data; ELF RX segment |
| `0x80010000` | 64-bit `tohost` |
| `0x80010008` | 64-bit `fromhost`, initialized to `0` |
| `0x80010010`–`0x8001004f` | Eight 64-bit result slots |
| `0x80011000` and above | Data/BSS; ELF RW segment |
| `0x8001f000`–`0x8001ffff` | 4 KiB stack reservation; initial `SP = 0x80020000` |

ELF permissions do not automatically configure M-mode memory protection. The initial environment allows access to this RAM; PMP/MMIO and real platform protection are verified separately.

The result slots in order are: `magic = 0x465552534f593031`, `version = 1`, `status`, `test_id`, `mcause`, `mepc`, `mtval`, and `expected_trap_count`. Status codes: `0` = running, `1` = pass, `2` = fail.
`tohost = 1` indicates pass and `tohost = 3` indicates failure; conformance is also cross-checked with the Spike adapter. Both the mailbox result and signature are checked together. Timeouts, silence, or spin-park loops do not count as a pass.

Pass signature: `status = 1`, `test_id = 0`, `mcause = 11`, `mepc = ecall_probe`, `mtval = 0`, `trap_count = 1`. Returning from `ECALL` is expected at `mepc + 4`. Any different trap or repeated `ECALL` fails with `test_id = 100`. The handler is not a general OS trap handler: it may only clobber temporary registers at this single `ECALL` probe site; all other traps are terminal failures. C test IDs: `1` = BSS, `2` = sum, `3` = trap count.

Build flags: `-march=rv64i_zicsr_zifencei -mabi=lp64 -mcmodel=medany`, relaxation and PIC disabled; no libc/startup. Linker assertions reject code/mailbox and data/stack overlaps. See [GNU ld](https://sourceware.org/binutils/docs/ld/Scripts.html).

This program is not an ISA compliance suite. It validates the same ELF and signature first on the reference simulator and then on the DUT.
