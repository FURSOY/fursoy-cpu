# Platform Boot & Minimal SBI Architecture Contract — Accepted and Frozen v1

Status: Platform/SBI v1 architecture: independently reviewed — ACCEPT AND FREEZE.  
This contract defines the minimal, deterministic platform specification required to boot a standard
RV64 Linux kernel on the single-hart Fursoy RV64 platform (Slice-0).

The independently accepted and frozen privilege baseline (`s-mode-bare-v1.md`), Sv39 MMU architecture
(`sv39-mmu-v1.md`), PMP architecture (`pmp-v1.md`), PLIC architecture (`plic-v1.md`), and RV64A atomic
extension (`rv64a-v1.md`) serve as the normative compatibility baseline.

---

## 1. Scope and Architectural Authority

### 1.1 Normative References

The normative authority for the platform boot and SBI architecture defined in this document comprises:

1. **RISC-V Supervisor Binary Interface Specification (SBI)**, Version 2.0 (Ratified).
2. **RISC-V Instruction Set Manual, Volume II: Privileged Architecture**, Document Version 20260120
   (Machine-Level ISA 1.13 and Supervisor-Level ISA 1.13).
3. **RISC-V Linux Boot Protocol**, Linux Kernel Documentation (`Documentation/arch/riscv/boot.rst`).
4. **Devicetree Specification**, Release 0.4.

Provisions throughout this document are categorized as:
* **Required**: Mandatory behavior per RISC-V SBI, Privileged ISA, or Linux ABI standards.
* **Choice**: A specific design decision for the Fursoy platform among legal architectural options.
* **Simplification**: A minimal, correctness-first restriction for Slice-0 single-hart boot that
  preserves a clean path for future multicore server expansion.

### 1.2 Boundary and Roadmap

| Dimension | Standard RV64 Linux Platform | Fursoy v1 Choice (Slice-0) | Deferred Multicore / Server Scaling |
|---|---|---|---|
| **Hart Count** | 1 to 128+ harts | **Single hart (Hart 0)** | 4 to 8 harts (ADR-001) |
| **ISA Baseline** | RV64GC (or RVA20/RVA22) | **RV64IMA + Zicsr + Zifencei** | RV64GC / RVA23 profile |
| **Firmware Medium** | SPI Flash / Mask ROM / DRAM | **Direct RAM execution at `0x8000_0000`** | Dedicated Mask ROM / SPI boot flash |
| **SBI Standard** | SBI v2.0+ (OpenSBI full) | **Minimal SBI v2.0 subset (Base, TIME, SRST, DBCN)** | Full OpenSBI with HSM, IPI, PMU, SUSP |
| **Console Device** | 16550A / DesignWare / SBI console | **Lite-16550A MMIO + SBI DBCN proxy** | High-performance 16550A with DMA / FIFOs |
| **Timer Device** | CLINT / ACLINT / Sstc | **CLINT via SBI Timer extension** | Sstc / ACLINT per-hart timers |
| **Paging** | Sv39 / Sv48 / Sv57 | **Sv39 (Bare handoff)** | Sv39 / Sv48 / Sv57 |
| **Boot Arguments** | DTB / ACPI | **Flattened Device Tree (DTB) in RAM** | ACPI + DTB support |

**Explicitly Out of Scope (Non-Goals for v1)**:
* Multi-hart boot, Hart State Management (HSM) extension, and Inter-Processor Interrupts (IPI).
* ACPI tables and UEFI firmware.
* RISC-V AIA (APLIC/IMSIC).
* PCIe root complex, NVMe, and virtio bus devices.
* TLB caches, hardware page-table walker caches, and data/instruction caches.
* Floating point (F/D/C extensions) hardware.

---

## 2. Physical Memory Map

### 2.1 Non-Overlapping Physical Address Space

The physical address space for Fursoy Slice-0 is partitioned into non-overlapping regions.
DRAM preserves the existing verified base address of `0x8000_0000`.

| Physical Address Range | Size | Region Name | Access Privileges | Description / Ownership |
|---|---|---|---|---|
| `0x0001_0000` – `0x0001_FFFF` | 64 KiB | **Boot ROM (Reserved)** | M-mode (RO) | Reserved future Boot ROM (currently unmapped; not active) |
| `0x0200_0000` – `0x0200_FFFF` | 64 KiB | **CLINT MMIO** | M-mode only (RW) | Core-local interruptor (`mtime`, `mtimecmp`, `msip`) |
| `0x0C00_0000` – `0x0C3F_FFFF` | 4 MiB | **PLIC MMIO** | M-mode / S-mode (RW) | 31-source external interrupt controller |
| `0x1000_0000` – `0x1000_0FFF` | 4 KiB | **UART MMIO** | M-mode / S-mode (RW) | Lite-16550A serial console peripheral |
| `0x8000_0000` – `0x801F_FFFF` | 2 MiB | **Firmware / SBI RAM** | M-mode only (RWX) | Fursoy minimal M-mode SBI runtime & stack |
| `0x8020_0000` – `0x81FF_FFFF` | 30 MiB | **Linux Kernel Image** | S-mode / U-mode (RWX) | Linux kernel code (`_start` at `0x8020_0000`) |
| `0x8200_0000` – `0x820F_FFFF` | 1 MiB | **Device Tree (DTB)** | S-mode / U-mode (RO) | Flattened Device Tree binary payload |
| `0x8210_0000` – `0x8FFF_FFFF` | 223 MiB | **Linux System DRAM** | S-mode / U-mode (RWX) | Free memory for OS page tables, slab, user space |

### 2.2 Rationale and Reserved Gaps

1. **Boot ROM Role Clarification (P2-3)**:
   - In the current Slice-0 RTL baseline, the hardware reset PC is `0x8000_0000`.
   - Firmware is preloaded directly into RAM at `0x8000_0000`.
   - The address range `0x0001_0000..0x0001_FFFF` is designated strictly as a reserved future allocation for an on-chip mask ROM or FPGA first-stage bootloader; in the current Slice-0 interconnect it is unmapped. It is not part of the active Slice-0 simulation or bring-up boot path.
2. **Firmware RAM (`0x8000_0000` – `0x801F_FFFF`)**:
   - Matches standard OpenSBI 2 MiB alignment and size convention.
   - Protected from S-mode access via PMP Entry 0 (NAPOT 2 MiB, no permissions).
3. **Linux Load Address (`0x8020_0000`)**:
   - Canonical entry address for 64-bit RISC-V Linux kernels (`DRAM_BASE + 2 MiB`).
   - S-mode enters execution at `0x8020_0000` with 2 MiB alignment.
4. **DTB Placement (`0x8200_0000`)**:
   - Located at a fixed 32 MiB offset above DRAM base.
   - Sits above typical uncompressed kernel images (typically 12–20 MiB for minimal kernels), preventing kernel self-extraction from clobbering the DTB.
5. **Reserved Address Holes**:
   - All addresses not explicitly allocated above (e.g. `0x1000_1000` to `0x7FFF_FFFF`) are unmapped holes.
   - Interconnect decodes unmapped accesses as bus errors, resulting in load access faults (cause 5), store access faults (cause 7), or instruction access faults (cause 1).
   - PTW memory accesses to CLINT, PLIC, UART, or unmapped holes are strictly rejected (`reject_ptw_mmio`), preventing page-table walker deadlocks.

---

## 3. Reset and Boot Flow

### 3.1 Initial Hardware Reset State

1. **Privilege Mode**: Hart 0 resets in Machine mode (`priv_mode = 2'b11`).
2. **Reset PC**: Hardware starts execution at `0x0000_0000_8000_0000` (preserving existing Slice-0 default).
3. **Architectural Registers at Reset**:
   - Register `x0` is hardwired zero.
   - Registers `x1` through `x31` have architecturally undefined initial values. Firmware must not rely on GPR values at entry.
   - `mstatus` resets to `0x0000_0000_0000_1800` (`MPP = 2'b11`, `MIE = 0`, `MPIE = 0`).
   - `mie` resets to `0`.
   - `satp` resets to `0` (Bare translation mode).
   - `mcause`, `mepc`, `mtval` reset to `0`.
   - PMP configuration registers (`pmpcfg0`, `pmpcfg2`, `pmpaddr0..15`) reset to `0` (all entries disabled, default deny for S/U-mode).

### 3.2 Firmware Execution Medium

**Choice**: For Slice-0 simulation and initial FPGA bring-up, firmware executes directly from RAM at `0x8000_0000`.
- The simulation environment / testbench loads a unified binary or pre-initialized RAM image containing:
  1. Fursoy Minimal SBI firmware at `0x8000_0000`.
  2. Linux kernel image (`Image`) at `0x8020_0000`.
  3. Pre-compiled Flattened Device Tree (`fursoy.dtb`) at `0x8200_0000`.
- No intermediate bootloader (e.g. U-Boot) is required for the minimal boot smoke path.

---

## 4. Machine-Mode Firmware Responsibilities

Before handing off control to S-mode, the M-mode firmware must perform the following deterministic initialization:

### 4.1 Machine CSR Setup
1. **Machine Trap Vector (`mtvec`)**:
   - Set to the firmware's M-mode exception handler (`mtvec = &sbi_trap_entry`).
   - Mode set to `2'b00` (Direct mode, 4-byte aligned).
2. **Machine Environment Configuration (`menvcfg`)**:
   - Initialized to `0` (or `64'h1` if `FIOM` is implemented).
3. **Counter Enable (`mcounteren`)**:
   - Set to `0x0000_0007` (enabling S/U-mode access to `cycle`, `time`, and `instret`).

### 4.2 Trap and Interrupt Delegation
1. **Exception Delegation (`medeleg`)**:
   - M-mode delegates all standard supervisor exceptions to S-mode:
     - Bit 0: Instruction address misaligned
     - Bit 1: Instruction access fault
     - Bit 2: Illegal instruction
     - Bit 3: Breakpoint
     - Bit 4: Load address misaligned
     - Bit 5: Load access fault
     - Bit 6: Store/AMO address misaligned
     - Bit 7: Store/AMO access fault
     - Bit 8: Environment call from U-mode
     - Bit 12: Instruction page fault
     - Bit 13: Load page fault
     - Bit 15: Store/AMO page fault
   - **Crucial Rule**: Bit 9 (`Environment call from S-mode`) is **NOT** delegated (`medeleg[9] = 0`). S-mode ECALL instructions must trap to M-mode to invoke SBI services.
2. **Interrupt Delegation (`mideleg`)**:
   - Bit 1 (`SSIP`): Delegated (`mideleg[1] = 1`).
   - Bit 5 (`STIP`): Delegated (`mideleg[5] = 1`).
   - Bit 9 (`SEIP`): Delegated (`mideleg[9] = 1`).
   - Machine interrupts (`MSIP` bit 3, `MTIP` bit 7, `MEIP` bit 11) are **NOT** delegated (`mideleg[3, 7, 11] = 0`).

### 4.3 PMP Security Configuration
Firmware programs PMP registers to enforce the supervisor memory isolation policy (detailed in Section 11):
- Entry 0: NAPOT 2 MiB at `0x8000_0000` with `R=0, W=0, X=0` (locks firmware memory from S-mode).
- Entry 1: NAPOT 256 MiB at `0x8000_0000` with `R=1, W=1, X=1` (grants S-mode full access to DRAM).
- Entry 2: NAPOT 4 MiB at `0x0C00_0000` with `R=1, W=1, X=0` (grants S-mode PLIC access).
- Entry 3: NAPOT 4 KiB at `0x1000_0000` with `R=1, W=1, X=0` (grants S-mode UART access).

### 4.4 Timer Initialization
- Set CLINT `mtimecmp` to `-1ULL` (`0xFFFF_FFFF_FFFF_FFFF`) to prevent spurious reset timer interrupts.
- Clear `mip.STIP` (`stip_q <= 0`).
- Enable Machine Timer Interrupt in M-mode (`mie.MTIE = 1`).

### 4.5 S-Mode Handoff Transition
Firmware prepares the architectural registers for S-mode entry:
- Set `mstatus.MPP = 2'b01` (Supervisor mode).
- Set `mstatus.MPIE = 0` (Supervisor interrupts disabled upon entry).
- Set `mstatus.MIE = 1` (Machine interrupts remain active to service M-mode timer traps).
- Set `mepc = 0x8020_0000` (Linux kernel entry point).
- Set `a0 = 0` (Hart ID 0).
- Set `a1 = 0x0000_0000_8200_0000` (DTB physical address).
- Zero remaining general-purpose registers (`x1..x9`, `x12..x31`).
- Execute `FENCE rw, rw` followed by `FENCE.I` to serialize memory and instruction pipelines.
- Execute `mret` to jump to the Linux kernel in S-mode.

---

## 5. Linux Boot ABI

The S-mode handoff adheres strictly to the official RISC-V Linux Boot ABI:

1. **Hart ID (`a0`)**: Must contain the current hardware thread ID (`0` for Slice-0).
2. **Device Tree Pointer (`a1`)**: Must contain the 64-bit physical address of the device tree blob (`0x0000_0000_8200_0000`), naturally aligned on an 8-byte boundary.
3. **Paging Mode**: `satp = 0` (Bare mode). Virtual memory is disabled at entry; Linux configures Sv39 page tables internally during early boot (`setup_vm`).
4. **Interrupt State**:
   - `sstatus.SIE = 0` (supervisor interrupts disabled).
   - `sie = 0` (all supervisor interrupt enables cleared).
   - `sip = 0` (no pending supervisor interrupts).
5. **Instruction Coherence**: All kernel instructions and device tree data loaded prior to handoff are guaranteed visible to instruction fetch via preceding `FENCE.I`.

---

## 6. Minimal SBI Interface

The Fursoy Minimal SBI implementation follows the **RISC-V SBI Specification v2.0**.

### 6.1 Calling Convention
- S-mode invokes SBI functions via the `ecall` instruction.
- **Input Registers**:
  - `a7`: Extension ID (EID)
  - `a6`: Function ID (FID)
  - `a0`–`a5`: Function arguments
- **Output Registers (`struct sbiret`)**:
  - `a0`: Error code (`sbiret.error`)
  - `a1`: Return value (`sbiret.value`)
- All other S-mode registers (`sp`, `gp`, `tp`, `s0`–`s11`, `t0`–`t6`) are strictly preserved across SBI calls.

### 6.2 Standard Error Codes
| Constant | Value | Description |
|---|---|---|
| `SBI_SUCCESS` | `0` | Completed successfully |
| `SBI_ERR_FAILED` | `-1` | Operation failed |
| `SBI_ERR_NOT_SUPPORTED` | `-2` | Extension or function not supported |
| `SBI_ERR_INVALID_PARAM` | `-3` | Invalid parameter |
| `SBI_ERR_DENIED` | `-4` | Denied or not allowed |
| `SBI_ERR_INVALID_ADDRESS` | `-5` | Invalid address |
| `SBI_ERR_ALREADY_AVAILABLE` | `-6` | Resource already available |

### 6.3 Supported Extension Subset

#### 1. Base Extension (EID `0x10`)
Mandatory discovery extension per SBI specification:
* **FID 0 (`sbi_get_spec_version`)**: Returns SBI specification version `0x02000000` (v2.0) in `a1`.
* **FID 1 (`sbi_get_impl_id`)**: Returns `0xF00501` (Fursoy Minimal SBI Implementation ID) in `a1`.
* **FID 2 (`sbi_get_impl_version`)**: Returns implementation version `1` in `a1`.
* **FID 3 (`sbi_probe_extension`)**:
  - Argument `a0 = eid`.
  - Returns `a1 = 1` if `eid` is one of:
    - `0x10` (Base)
    - `0x54494D45` (Timer)
    - `0x53525354` (System Reset)
    - `0x4442434E` (Debug Console)
  - Returns `a1 = 0` for all other extensions.
* **FID 4 (`sbi_get_mvendorid`)**: Returns `0` in `a1`.
* **FID 5 (`sbi_get_marchid`)**: Returns `0` in `a1`.
* **FID 6 (`sbi_get_mimpid`)**: Returns `0` in `a1`.

#### 2. Timer Extension (TIME, EID `0x54494D45` / `'TIME'`)
Replaces legacy SBI v0.1 timer call:
* **FID 0 (`sbi_set_timer`)**:
  - Argument: `a0 = stime_value` (64-bit absolute time deadline).
  - Behavior:
    - If `stime_value == -1ULL`: Clears `mip.STIP`, disables `mie.MTIE`, sets CLINT `mtimecmp = -1ULL`.
    - If `stime_value <= mtime` (past deadline): Immediately writes `stime_value` to `mtimecmp`, clears `mip.STIP`, enables `mie.MTIE`. Hardware will assert `MTIP` on the next cycle, triggering immediate trap and virtual `STIP` delivery.
    - Otherwise: Clears `mip.STIP`, writes `stime_value` to CLINT `mtimecmp`, enables `mie.MTIE`.
  - Returns: `a0 = SBI_SUCCESS` (0), `a1 = 0`.

#### 3. System Reset Extension (SRST, EID `0x53525354` / `'SRST'`)
Normative deterministic reset and shutdown behavior (P1-4):
* **FID 0 (`sbi_system_reset`)**:
  - Arguments: `a0 = reset_type`, `a1 = reset_reason`.
  - Types:
    - `0 = SBI_SRST_RESET_TYPE_SHUTDOWN`
    - `1 = SBI_SRST_RESET_TYPE_COLD_REBOOT`
    - `2 = SBI_SRST_RESET_TYPE_WARM_REBOOT`
  - **Shutdown Behavior (`reset_type == 0`)**:
    1. Optionally emits terminal console string `"Fursoy platform halted.\n"` via UART.
    2. Disables machine interrupts: `csrw mie, zero`.
    3. Enters deterministic terminal halt loop:
       ```asm
       halt_loop:
           wfi
           j halt_loop
       ```
    4. The simulation testbench monitors the program counter; upon detecting `PC == &halt_loop`, the simulation is cleanly terminated with status `PASS`.
    5. Does not return.
  - **Reboot Behavior (`reset_type == 1` or `2`)**:
    - For Platform v1, cold reboot and warm reboot are explicitly unsupported.
    - Returns `a0 = SBI_ERR_NOT_SUPPORTED` (`-2`), `a1 = 0`.
  - **Invalid Type (`reset_type > 2`)**:
    - Returns `a0 = SBI_ERR_INVALID_PARAM` (`-3`), `a1 = 0`.

#### 4. Debug Console Extension (DBCN, EID `0x4442434E` / `'DBCN'`)
Modern SBI console extension for early printk:
* **FID 0 (`sbi_debug_console_write`)**:
  - Arguments: `a0 = num_bytes`, `a1 = base_addr_lo`, `a2 = base_addr_hi`.
  - Validates physical memory range `[base_addr, base_addr + num_bytes)` against permitted supervisor DRAM.
  - Passes bytes sequentially to the UART TX engine.
  - Returns: `a0 = SBI_SUCCESS`, `a1 = num_bytes_written`.
* **FID 1 (`sbi_debug_console_read`)**:
  - Arguments: `a0 = num_bytes`, `a1 = base_addr_lo`, `a2 = base_addr_hi`.
  - Returns: `a0 = SBI_SUCCESS`, `a1 = 0` (no input available in non-interactive v1).
* **FID 2 (`sbi_debug_console_write_byte`)**:
  - Argument: `a0 = byte`.
  - Transmits single byte via UART.
  - Returns: `a0 = SBI_SUCCESS`, `a1 = 0`.

---

## 7. Timer SBI Path & Interrupt Virtualization

### 7.1 Architectural Interaction Model

Slice-0 possesses a single physical CLINT instance providing `mtime` and `mtimecmp`.
Supervisor timer interrupts are completely virtualized through M-mode firmware without introducing
a second timer peripheral.

```
       +-----------------------------------------------------------+
       |                       S-mode Linux                        |
       +-----------------------------------------------------------+
               |                                           ^
   1. ecall    |                                           | 5. STIP delivered
   (TIME FID 0)|                                           |    (cause 5)
               v                                           |
       +-----------------------------------------------------------+
       |                      M-mode Firmware                      |
       +-----------------------------------------------------------+
         |           ^                             |
2. write |           | 3. CLINT MTIP (cause 7)     | 4. csrs mip, (1<<5)
 mtimecmp|           |    fires when               |    csrc mie, (1<<7)
         v           |    mtime >= mtimecmp        |    mret
       +---------------+                           |
       |  CLINT Timer  |---------------------------+
       +---------------+
```

### 7.2 Detailed Event Lifecycle

1. **Timer Programming**:
   - S-mode executes `ecall` with EID `0x54494D45`, FID `0`, and deadline in `a0`.
   - M-mode trap handler receives Supervisor ECALL (`mcause = 9`).
   - M-mode clears `mip.STIP` (`stip_q <= 0`), writes `a0` to CLINT `mtimecmp` at `0x0200_4000`, and enables `mie.MTIE = 1`.
   - M-mode advances `mepc += 4` and executes `mret` back to S-mode.
2. **Hardware Comparator Match**:
   - CLINT hardware counter `mtime` continuously increments.
   - When `mtime >= mtimecmp`, CLINT hardware asserts `irq_timer_o`, which drives core `irq_timer_i` -> `mip.MTIP` (bit 7).
3. **M-Mode Trap Interception**:
   - Because `mideleg[7] = 0` (MTIP is not delegated) and `mie.MTIE = 1`, the core traps to M-mode with interrupt cause 7 (`mcause = 0x8000_0000_0000_0007`).
4. **Virtual STIP Injection**:
   - M-mode trap handler identifies `mcause == 7`.
   - To avoid infinite re-entry, M-mode masks the physical timer interrupt: `csrc mie, (1 << 7)`.
   - M-mode sets the virtual supervisor timer interrupt pending bit: `csrs mip, (1 << 5)`.
   - M-mode executes `mret` to resume S-mode.
5. **S-Mode Interrupt Delivery**:
   - Upon resuming S-mode, the core evaluates supervisor interrupt eligibility.
   - Because `mideleg[5] == 1` and `stip_q == 1`, when `sstatus.SIE == 1` and `sie.STIE == 1`, the core delivers a Supervisor Timer Interrupt (`scause = 0x8000_0000_0000_0005`).
   - Linux handles the timer tick and calls `sbi_set_timer` with the next deadline, completing the cycle and clearing `mip.STIP`.
6. **Past Deadline Handling**:
   - If S-mode programs a deadline where `stime_value <= mtime`, CLINT asserts `MTIP` immediately on comparator match, and steps 3–5 execute without delay.

---

## 8. UART Architecture (Lite-16550A)

### 8.1 Register Programming Model (P1-3)

To ensure 100% out-of-the-box compatibility with the upstream Linux `serial8250` and `earlycon` drivers
without writing a custom driver, the Fursoy UART implements a standard **Lite-16550A** MMIO interface.

* **Base Address**: `0x1000_0000`
* **Aperture**: 4 KiB (`0x1000_0000` – `0x1000_0FFF`)
* **Register Stride**: 4 bytes (`reg-shift = <2>`, standard 32-bit MMIO alignment)
* **Access Rules**: Strictly naturally aligned 32-bit MMIO accesses only (`reg-shift = <2>`, `reg-io-width = <4>`). Non-32-bit accesses or misaligned offsets raise platform bus errors with zero side effects.

The register decoded at offsets `0x00` and `0x04` depends on the **Divisor Latch Access Bit (DLAB)**, which is `LCR[7]`:

| Offset | DLAB | Register Name | Access | Reset Value | Description / Bitfields |
|---|---|---|---|---|---|
| `0x00` | **0** | **RBR / THR** | R / W | `0x00` | Receiver Buffer (R) / Transmitter Holding Register (W) |
| `0x00` | **1** | **DLL** | R / W | `0x00` | Divisor Latch LSB (stored 8-bit divisor; writes **never** transmit) |
| `0x04` | **0** | **IER** | R / W | `0x00` | Interrupt Enable Register (`IER[0] = RX_INT`, `IER[1] = TX_INT`) |
| `0x04` | **1** | **DLM** | R / W | `0x00` | Divisor Latch MSB (stored 8-bit divisor; writes **never** transmit) |
| `0x08` | **x** | **IIR / FCR** | R / W | `0x01` / `0x00` | Interrupt Identification (R) / FIFO Control (W, writes ignored) |
| `0x0C` | **x** | **LCR** | R / W | `0x03` | Line Control Register (Bit 7 = DLAB; bits 1:0 = 8 data bits) |
| `0x10` | **x** | **MCR** | R / W | `0x00` | Modem Control Register (bit 3 = OUT2/interrupt gate) |
| `0x14` | **x** | **LSR** | R only | `0x60` | Line Status: bit 5 (`THRE` = 1), bit 6 (`TEMT` = 1), bit 0 (`DR` = 0) |
| `0x18` | **x** | **MSR** | R only | `0x00` | Modem Status Register (all signals inactive) |
| `0x1C` | **x** | **SCR** | R / W | `0x00` | Scratch Register (8-bit storage) |

### 8.2 Operational Behavior

1. **DLAB / DLL / DLM Semantics (P1-3)**:
   - When `LCR[7] == 1`:
     - Writing to offset `0x00` updates the internal 8-bit `DLL` register. **This write must never transmit UART characters.**
     - Writing to offset `0x04` updates the internal 8-bit `DLM` register.
     - Reading offset `0x00` returns the current `DLL` value.
     - Reading offset `0x04` returns the current `DLM` value.
   - When `LCR[7] == 0`:
     - Writing to offset `0x00` writes to `THR` and immediately transmits a character.
     - Reading offset `0x04` reads `IER`.
2. **FIFO Capability Reporting (P1-3)**:
   - Slice-0 implements deterministic non-FIFO mode.
   - `IIR[7:6]` is hardwired to `2'b00` (FIFOs disabled / not present).
   - Writes to `FCR` (offset `0x08`) are accepted and ignored; they do not alter `IIR[7:6]`.
   - `IIR` reads return `0x01` (bit 0 = 1: no interrupt pending; bits 7:6 = 0: no FIFO).
3. **Transmitter (THR)**:
   - Writing byte $B$ to offset `0x00` when `LCR[7] == 0` immediately emits $B$ to the console sink (Verilator stdout / simulator log / hardware TX FIFO).
   - In simulation, TX is instantaneous with infinite bandwidth; `LSR.THRE` (bit 5) and `LSR.TEMT` (bit 6) remain hardwired to `1`.
4. **Receiver (RBR)**:
   - In v1 minimal boot, RX is non-interactive. Reading `RBR` returns `0x00`; `LSR.DR` (bit 0) reads `0`.
5. **Interrupts (P2-2)**:
   - The UART interrupt line exclusively owns **PLIC Source ID 1**.
   - In production/FPGA systems, external `irq_sources_i[1]` is tied low; PLIC Source 1 is solely driven by the UART.
   - For early Linux boot, polling mode is employed (`IER = 0x00`).
6. **Unsupported Offsets**:
   - Accesses to offsets `0x20` through `0xFFF` within the 4 KiB aperture read as `0` and ignore writes.

---

## 9. Console / Debug SBI Architecture Decision

### 9.1 Evaluation and Strategy

Two console paths exist in RISC-V Linux ecosystems:
1. **SBI Debug Console (DBCN)**: Kernel delegates all printing to M-mode via `ecall`.
2. **Direct MMIO UART**: Kernel talks directly to the 16550A hardware registers.

**Architectural Decision**:
* **Hardware Consolidation**: A single physical Lite-16550A peripheral resides at `0x1000_0000`.
* **Firmware Console**: M-mode firmware utilizes direct MMIO writes to `0x1000_0000` to print boot diagnostics.
* **Firmware SBI Service**: Firmware exposes SBI DBCN (EID `0x4442434E`), routing DBCN writes directly through its internal UART driver.
* **Supervisor Console**:
  - Early boot: Linux may use either `earlycon=sbi` or `earlycon=uart8250,mmio32,0x10000000`. Both work deterministically.
  - Main console: PMP Entry 3 grants S-mode read/write access to `0x1000_0000`. Linux binds the standard upstream `serial8250` driver as `/dev/ttyS0` via the device tree.
* **Advantage**: Zero hardware duplication; full compatibility with stock Linux kernels whether built with or without `CONFIG_RISCV_SBI_CONSOLE`.

---

## 10. Device Tree Contract (DTS Specification)

The Flattened Device Tree placed at `0x8200_0000` must conform to the following normative DTS layout:

```dts
/dts-v1/;

/ {
    #address-cells = <2>;
    #size-cells = <2>;
    compatible = "fursoy,slice0-soc", "fursoy,fursoy-s0";
    model = "Fursoy Slice-0 RISC-V Server Platform";

    chosen {
        bootargs = "console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x10000000 root=/dev/ram0 rw";
        stdout-path = "/soc/serial@10000000:115200n8";
    };

    cpus {
        #address-cells = <1>;
        #size-cells = <0>;
        timebase-frequency = <10000000>; /* 10 MHz CLINT timebase */

        cpu0: cpu@0 {
            device_type = "cpu";
            reg = <0>;
            status = "okay";
            compatible = "riscv";
            riscv,isa = "rv64ima_zicsr_zifencei";
            riscv,isa-extensions = "i", "m", "a", "zicsr", "zifencei";
            mmu-type = "riscv,sv39";

            cpu0_intc: interrupt-controller {
                #interrupt-cells = <1>;
                compatible = "riscv,cpu-intc";
                interrupt-controller;
            };
        };
    };

    memory@80000000 {
        device_type = "memory";
        reg = <0x0 0x80000000 0x0 0x10000000>; /* Full 256 MiB physical DRAM */
    };

    reserved-memory {
        #address-cells = <2>;
        #size-cells = <2>;
        ranges;

        firmware_sbi@80000000 {
            reg = <0x0 0x80000000 0x0 0x00200000>; /* 2 MiB M-mode reservation */
            no-map;
        };
    };

    soc {
        #address-cells = <2>;
        #size-cells = <2>;
        compatible = "simple-bus";
        ranges;

        plic@c000000 {
            compatible = "riscv,plic0", "sifive,plic-1.0.0";
            reg = <0x0 0x0c000000 0x0 0x00400000>;
            interrupt-controller;
            #interrupt-cells = <1>;
            riscv,ndev = <31>;
            interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>; /* Context 0 M, Context 1 S */
        };

        serial@10000000 {
            compatible = "ns16550a";
            reg = <0x0 0x10000000 0x0 0x00001000>;
            reg-shift = <2>;
            reg-io-width = <4>;
            clock-frequency = <10000000>;
            current-speed = <115200>;
            interrupt-parent = <&plic>;
            interrupts = <1>; /* PLIC external interrupt source 1 */
        };
    };
};
```

### 10.1 Key DTS Normative Policies

1. **Root Compatible String (P2-1)**:
   - Uses strictly Fursoy-specific compatible strings: `"fursoy,slice0-soc", "fursoy,fursoy-s0"`.
   - Does not declare `"riscv-virtio"` because Fursoy does not implement QEMU virt hardware.
2. **Canonical Memory Description (P1-2)**:
   - `memory@80000000` declares the full 256 MiB physical aperture (`reg = <0x0 0x80000000 0x0 0x10000000>`). Unit-address and `reg` start address agree.
   - `/reserved-memory` explicitly carves out the lower 2 MiB (`0x8000_0000..0x801F_FFFF`) with the `no-map` attribute, ensuring Linux will never allocate page frames over firmware memory.
3. **Absence of CLINT Node (P1-1)**:
   - The physical CLINT (`0x0200_0000`) is intentionally omitted from the Linux Device Tree.
   - Direct S-mode MMIO access to CLINT is prohibited by PMP.
   - Exposing a `clint@2000000` node with `compatible = "riscv,clint0"` would cause Linux to bind its native CLINT driver and attempt direct access to `mtime`, provoking load access faults.
   - Linux timer service is provided exclusively through the RISC-V SBI Timer extension (`sbi_set_timer`).
4. **Modern ISA Extension Property (P2-2)**:
   - Includes `riscv,isa-extensions = "i", "m", "a", "zicsr", "zifencei";` matching the frozen implementation.
   - Retains `riscv,isa = "rv64ima_zicsr_zifencei"` for legacy compatibility without claiming unsupported extensions.

---

## 11. PMP and Supervisor Access Policy

### 11.1 PMP Configuration Table

The frozen Fursoy PMP implementation (`pmp-v1.md`) uses lowest-index-matching priority.
Firmware initializes the 16-entry PMP array as follows:

| Entry | Physical Base | Size / Type | Configuration (`pmpcfg`) | Access Rights (S/U-Mode) | Protected Region |
|---|---|---|---|---|---|
| **0** | `0x8000_0000` | 2 MiB (NAPOT) | `8'h18` (`A=NAPOT, R=0, W=0, X=0, L=0`) | **NONE (Deny all)** | M-mode Firmware RAM |
| **1** | `0x8000_0000` | 256 MiB (NAPOT) | `8'h1F` (`A=NAPOT, R=1, W=1, X=1, L=0`) | **Read + Write + Execute** | System DRAM (Kernel + DTB + Free) |
| **2** | `0x0C00_0000` | 4 MiB (NAPOT) | `8'h1B` (`A=NAPOT, R=1, W=1, X=0, L=0`) | **Read + Write** | PLIC MMIO Aperture |
| **3** | `0x1000_0000` | 4 KiB (NAPOT) | `8'h1B` (`A=NAPOT, R=1, W=1, X=0, L=0`) | **Read + Write** | UART MMIO Aperture |
| **4–15** | `0x0` | Disabled (OFF) | `8'h00` (`A=OFF`) | **Default Deny** | Unmapped space & CLINT |

### 11.2 Access Matrix for S-Mode

| Target Region | S-Mode Instruction Fetch | S-Mode Load | S-Mode Store / AMO | Architectural Result |
|---|---|---|---|---|
| **Firmware RAM** (`0x8000_0000`–`0x801F_FFFF`) | **DENIED** | **DENIED** | **DENIED** | Traps with cause 1, 5, or 7; zero store side effects |
| **Linux DRAM** (`0x8020_0000`–`0x8FFF_FFFF`) | **ALLOWED** | **ALLOWED** | **ALLOWED** | Normal kernel operation |
| **PLIC MMIO** (`0x0C00_0000`–`0x0C3F_FFFF`) | **DENIED** | **ALLOWED** | **ALLOWED** | Driver claims/completes interrupts; fetch traps with cause 1 |
| **UART MMIO** (`0x1000_0000`–`0x1000_0FFF`) | **DENIED** | **ALLOWED** | **ALLOWED** | Console read/write permitted; fetch traps with cause 1 |
| **CLINT MMIO** (`0x0200_0000`–`0x0200_FFFF`) | **DENIED** | **DENIED** | **DENIED** | Traps with cause 1, 5, or 7; S-mode must use SBI Timer |
| **Unmapped Holes** | **DENIED** | **DENIED** | **DENIED** | Default PMP deny prevents spurious bus transactions |

---

## 12. ECALL Dispatch and Trap Flow

### 12.1 S-Mode ECALL Trapping Mechanics

1. S-mode executes `ecall`.
2. Core hardware detects Supervisor ECALL:
   - `mcause <= 64'd9` (Environment call from S-mode).
   - `mepc <= PC of ecall`.
   - `mstatus.MPP <= 2'b01` (recording S-mode origin).
   - `mstatus.MPIE <= mstatus.MIE`.
   - `mstatus.MIE <= 0`.
   - Redirects PC to `mtvec` base address.

### 12.2 Firmware Handler Execution

1. **Context Preservation**: Firmware saves caller-saved GPRs (`a0`–`a7`, `t0`–`t6`, `ra`) to a dedicated M-mode scratch stack.
2. **Dispatch**:
   - Inspects `a7` (EID) and `a6` (FID).
   - If `a7` matches a supported extension, invokes the registered C handler.
   - If unsupported, sets `sbiret.error = SBI_ERR_NOT_SUPPORTED` (`-2`), `sbiret.value = 0`.
3. **Return Value Packing**:
   - Overwrites saved `a0` with `sbiret.error`.
   - Overwrites saved `a1` with `sbiret.value`.
4. **PC Advancement**: Firmware reads saved `mepc`, adds `4`, and writes back to `mepc` so `mret` returns to the instruction following `ecall`.
5. **Context Restore & Return**: Restores registers, executes `mret` to resume S-mode execution.

---

## 13. System Reset & Shutdown Behavior

### 13.1 SBI System Reset (SRST) Execution (P1-4)

When S-mode calls `sbi_system_reset(reset_type, reset_reason)`:

1. **Shutdown (`reset_type == 0`)**:
   - Firmware optionally emits `"Fursoy platform halted.\n"` via UART.
   - Disables machine interrupts: `csrw mie, zero`.
   - Enters deterministic terminal halt loop:
     ```asm
     halt_loop:
         wfi
         j halt_loop
     ```
   - **Simulation Check**: The testbench monitors core commit and trap traces. When the core enters `halt_loop`, the simulation is marked as cleanly terminated (`PASS`).
   - Does not return.
2. **Unsupported Reboot Types (`reset_type == 1` or `2`)**:
   - For Platform v1, cold reboot and warm reboot are explicitly unsupported.
   - Returns `a0 = SBI_ERR_NOT_SUPPORTED` (`-2`), `a1 = 0`.
3. **Invalid Parameter (`reset_type > 2`)**:
   - Returns `a0 = SBI_ERR_INVALID_PARAM` (`-3`), `a1 = 0`.

---

## 14. Linux Scope Assumptions & First Boot Milestones

### 14.1 Target Configuration
* **Core**: Single-hart Hart 0, RV64IMA + Zicsr + Zifencei.
* **Privilege**: S-mode with Sv39 paging.
* **No Cache Requirement**: Slice-0 memory interface provides coherent single-port RAM access without hardware caches.
* **No SMP**: Linux boots with `CONFIG_SMP=n` or single-core SMP (`maxcpus=1`).
* **Console**: 16550A serial console at `0x1000_0000`.

### 14.2 Observable Verification Checkpoints

* **Checkpoint 1 (Firmware Handoff)**: Firmware initializes CSRs, PMP, and completes `mret` to `0x8020_0000` with `a0=0, a1=0x8200_0000`.
* **Checkpoint 2 (Kernel Banner)**: Linux decompressor and early setup complete; first banner appears on console:
  `Linux version 6.x.y (fursoy@server) ...`
* **Checkpoint 3 (Early Setup)**: Linux reports CPU identification, memory zones (`256 MiB` total, 2 MiB reserved), PMP detection, and Sv39 page table activation.
* **Checkpoint 4 (Driver Initialization)**: Linux initializes PLIC (`riscv,plic0`), registers timer via SBI TIME, and attaches `serial8250` driver.
* **Checkpoint 5 (Console / Init Reached)**: Linux mounts rootfs (initramfs) and reaches userspace `/init` or prints the canonical `Kernel panic - not syncing: VFS: Unable to mount root fs` (confirming full kernel boot completion).

---

## 15. Verification Plan

### 15.1 Focused Architectural Scenario Matrix

| Scenario ID | Category | Scenario Name | Stimulus / Test Description | Expected Observable Result |
|---|---|---|---|---|
| `PLAT-01` | Reset | Reset Vector & Privilege | Reset release with `RESET_PC = 0x8000_0000` | Core starts in M-mode (`priv_mode=11`) at `0x8000_0000` |
| `PLAT-02` | Reset | Initial GPR/CSR Hygiene | Firmware entry inspection | `mstatus=0x1800`, `mie=0`, `satp=0`, stack pointer valid |
| `PLAT-03` | PMP | Firmware Isolation from S-Mode | S-mode attempts read/write to `0x8000_1000` | Traps with cause 5 / 7; no data corruption; memory untouched |
| `PLAT-04` | PMP | S-Mode DRAM Access | S-mode loads/stores to `0x8020_0000` and `0x8200_0000` | Access succeeds without trap; correct readback |
| `PLAT-05` | PMP | S-Mode PLIC Access | S-mode reads/writes PLIC Context 1 threshold | Readback matches written priority threshold; no fault |
| `PLAT-06` | PMP | S-Mode UART Access | S-mode reads/writes UART registers at `0x1000_0000` | MMIO read/write succeeds; character emitted |
| `PLAT-07` | PMP | S-Mode CLINT Denial | S-mode attempts direct load/store to `0x0200_4000` | Traps with cause 5 / 7; CLINT memory unmodified |
| `PLAT-08` | Handoff | M $\rightarrow$ S Transition | Firmware executes `mret` handoff | Core enters S-mode (`priv_mode=01`) at `0x8020_0000` |
| `PLAT-09` | Handoff | Kernel Arguments (`a0`, `a1`) | Inspect `a0` and `a1` at `0x8020_0000` | `a0 == 0` (Hart 0), `a1 == 0x8200_0000` (DTB pointer) |
| `PLAT-10` | Handoff | Paging State at Handoff | Inspect `satp` at S-mode entry | `satp == 0` (Bare mode); translation disabled |
| `PLAT-11` | Trap | Supervisor ECALL Delegation | S-mode executes `ecall` | Traps to M-mode (`mcause=9`, not delegated to `scause`) |
| `PLAT-12` | SBI | Base Extension Spec Version | S-mode calls Base FID 0 | Returns `a0 = 0`, `a1 = 0x02000000` (SBI v2.0) |
| `PLAT-13` | SBI | Base Extension Probe Valid | S-mode probes EIDs `0x10`, `0x54494D45`, `0x53525354` | Returns `a0 = 0`, `a1 = 1` for each |
| `PLAT-14` | SBI | Base Extension Probe Invalid | S-mode probes unallocated EID `0x12345678` | Returns `a0 = 0`, `a1 = 0` |
| `PLAT-15` | SBI | Unsupported Function ID | S-mode calls Base EID with FID 99 | Returns `a0 = SBI_ERR_NOT_SUPPORTED` (`-2`) |
| `PLAT-16` | Timer | Timer Programming via SBI | S-mode calls `sbi_set_timer(deadline)` | CLINT `mtimecmp` updated to deadline; `mip.STIP=0` |
| `PLAT-17` | Timer | Timer Interrupt Injection | CLINT `mtime` exceeds `mtimecmp` | M-mode traps (cause 7), sets `mip.STIP=1`, masks `mie.MTIE` |
| `PLAT-18` | Timer | S-Mode Timer Delivery | S-mode with `sie.STIE=1, sstatus.SIE=1` | S-mode traps with `scause = 5` (Supervisor timer interrupt) |
| `PLAT-19` | Timer | Timer Clear on Reprogram | S-mode calls `sbi_set_timer(future_deadline)` | `mip.STIP` cleared to 0; `scause=5` deasserts |
| `PLAT-20` | UART | UART TX Character Emit | Write `'A'` (`0x41`) to `0x1000_0000` | Character `'A'` observed at simulator console sink |
| `PLAT-21` | UART | UART Access Width Enforcement | Naturally aligned 32-bit MMIO writes to `THR` | Correct character transmission; non-32-bit accesses return bus error with zero side effects |
| `PLAT-22` | UART | Invalid Misaligned Access | 16-bit write to odd address `0x1000_0001` | Core / interconnect raises access fault (cause 7) |
| `PLAT-23` | Reset | SBI System Reset Shutdown | S-mode calls SRST FID 0 (`type=0`) | Platform disables interrupts and enters `halt_loop` |
| `PLAT-24` | Smoke | Linux Boot Smoke Checkpoint | Full simulation boot through Checkpoint 2 | Kernel banner printed to console; Sv39 activated |
| `PLAT-25` | Timer | Past Timer Deadline | `sbi_set_timer(past_time)` where `past <= mtime` | Immediate `MTIP` $\rightarrow$ `STIP` $\rightarrow$ S-mode trap (cause 5) |
| `PLAT-26` | Timer | Repeated Timer Lifecycle | 5 sequential timer interrupt / reprogram cycles | Each tick correctly delivered, cleared, and re-armed |
| `PLAT-27` | Reset | SRST Unsupported Reboot Types | S-mode calls SRST FID 0 (`type=1` or `2`) | Returns `a0 = SBI_ERR_NOT_SUPPORTED` (`-2`) |
| `PLAT-28` | Reset | SRST Invalid Reset Type | S-mode calls SRST FID 0 (`type=99`) | Returns `a0 = SBI_ERR_INVALID_PARAM` (`-3`) |
| `PLAT-29` | UART | UART DLAB Divisor Access | Set `LCR[7]=1`; write `DLL=0x12, DLM=0x34` | Readback returns `0x12` and `0x34` respectively |
| `PLAT-30` | UART | DLAB Write Zero TX Side-Effect | Set `LCR[7]=1`; write byte to offset `0x00` | Stored in `DLL`; zero characters emitted to sink |
| `PLAT-31` | UART | UART Non-FIFO Reporting | Read `IIR` (offset `0x08`) | Returns `0x01`; bits 7:6 strictly `2'b00` |
| `PLAT-32` | DTB | DTB Structure Conformance | Automated validation of pre-compiled DTB | Validates full-DRAM node, `no-map`, no CLINT, Fursoy compat |

### 15.2 Formal Architectural Invariants

* **Invariant 1 (Firmware Memory Containment)**:
  $$\forall t, (\text{priv\_mode} < \text{M-mode}) \land (8000\_0000_{16} \le \text{addr} < 8020\_0000_{16}) \implies \text{access\_fault} = 1$$
* **Invariant 2 (CLINT S-Mode Denial)**:
  $$\forall t, (\text{priv\_mode} < \text{M-mode}) \land (0200\_0000_{16} \le \text{addr} < 0201\_0000_{16}) \implies \text{access\_fault} = 1$$
* **Invariant 3 (S-Mode ECALL M-Trap Invariant)**:
  $$\text{ecall} \land (\text{priv\_mode} == \text{S-mode}) \implies (\text{next\_priv} == \text{M-mode}) \land (\text{mcause} == 9) \land (\text{mepc} == \text{PC})$$
* **Invariant 4 (SBI Atomic GPR Preservation)**:
  $$\forall r \in \{x1..x9, x12..x31\}, \quad r_{\text{post\_sbi}} = r_{\text{pre\_sbi}}$$
* **Invariant 5 (Deterministic PTW MMIO Rejection)**:
  $$\text{req\_ptw} \land (\text{addr} \in \{\text{CLINT}, \text{PLIC}, \text{UART}\}) \implies \text{reject\_ptw\_mmio} = 1$$
* **Invariant 6 (UART DLAB Transmission Isolation)**:
  $$\text{req\_store} \land (\text{addr} == 1000\_0000_{16}) \land (\text{LCR}[7] == 1) \implies \text{tx\_emit} = 0$$

---

## 16. Summary of Architectural Decisions

1. **Physical Memory Map**: Non-overlapping layout preserving DRAM at `0x8000_0000`. 2 MiB firmware RAM at `0x8000_0000`, kernel at `0x8020_0000`, DTB at `0x8200_0000`, PLIC at `0x0C00_0000`, CLINT at `0x0200_0000`, UART at `0x1000_0000`. Boot ROM range (`0x0001_0000..0x0001_FFFF`) is reserved future allocation and unmapped in Slice-0.
2. **Reset & Handoff**: Resets in M-mode at `0x8000_0000`. Hands off via `mret` to `0x8020_0000` with `a0=0` (Hart 0), `a1=0x8200_0000` (DTB pointer), and `satp=0` (Bare mode).
3. **SBI Subset**: Minimal modern SBI v2.0 implementing Base (`0x10`), TIME (`0x54494D45`), SRST (`0x53525354`), and DBCN (`0x4442434E`). Legacy SBI v0.1 calls are excluded.
4. **Deterministic System Reset**: Shutdown enters a documented terminal `halt_loop: wfi; j halt_loop` with interrupts disabled. Cold/warm reboot return `SBI_ERR_NOT_SUPPORTED`. No exit MMIO device.
5. **Timer Strategy**: Physical CLINT timer virtualized through SBI Timer extension. M-mode catches MTIP (cause 7) and sets `mip.STIP` (cause 5) for S-mode. No second timer device. Past deadlines fire immediately.
6. **UART DLAB & Non-FIFO Behavior**: Lite-16550A MMIO at `0x1000_0000`. When `LCR[7]==1`, offsets 0x00/0x04 access `DLL`/`DLM` without transmitting data. `IIR[7:6]` hardwired to `2'b00` (non-FIFO mode).
7. **Device Tree Policy**: Full 256 MiB DRAM aperture declared at `memory@80000000` with 2 MiB `no-map` reservation. CLINT node omitted from Linux DT. Root compatible `"fursoy,slice0-soc", "fursoy,fursoy-s0"`. `riscv,isa-extensions` declared explicitly.
8. **PMP Policy**: 4 NAPOT entries protecting M-mode firmware and granting S-mode access to DRAM, PLIC, and UART. CLINT and unmapped space are default-denied to S-mode.
9. **Verification Matrix**: 32 focused scenarios covering reset, PMP, handoff, SBI calls, timer lifecycle, past deadlines, UART DLAB, SRST, and Linux boot milestones.
