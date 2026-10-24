# Fursoy Slice-1 Milestone 9 — SoC Interconnect, Peripheral Integration & Linux Boot Architecture Specification

**Document ID:** `docs/architecture/slice1-m9-soc-linux-v1.md`  
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.1 (Incorporating Independent Architecture Review Remediations — Ready for Freeze)  
**Target Core:** Fursoy Slice-1 (`fursoy_s1_core`, Single-Hart 2-Wide OoO RV64IMAFDV_Zba_Zbb_Zicsr_Zifencei_Sv39)  
**Target SoC:** Fursoy Slice-1 SoC (`fursoy_s1_soc`, Single-Hart Server Infrastructure Platform)  
**Master Plan Gate:** Gate G5 Final Exit Gate ("Full Single-Core Linux-Bootable Processor")  

**Predecessor Substrates & Frozen Baselines:**
- **Milestone 1** (Verified & Frozen): PRF80, ROB48, FreeList48, SRAT/ARAT, 8 Checkpoints, Recovery Substrate.
- **Milestone 2** (Verified & Frozen): PRF Data Storage 64b, IntIQ16, Port 0 ALU0/BR, Port 1 ALU1/MUL/DIV, Lossless WB.
- **Milestone 3** (Verified & Frozen): MemIQ12, LQ16, SQ16, Port 2 AGU, L1D 16 KiB 4W, 4 MSHR, 2 WBB, TRT4, PRF 6R3W.
- **Milestone 4** (Verified & Frozen): Decoupled Frontend (F0–D0), FQ12, BTB512 2W, Gshare4096 12b GHR, RAS16, L1I 16 KiB 4W, 2 I-MSHR, ITLB64 4W + 8-entry Superpage CAM, Shared Sv39 PTW, Privileged CSR/System Execution (`satp`, `SFENCE.VMA`, MRET/SRET), `FENCE.I` Clean/Invalidate.
- **Milestone 5** (Verified & Frozen): Integrated Performance, Telemetry & Throughput Optimization (Phase A HPM 48 event sources, up to 29 programmable 64-bit counters, 8-category single-owner CPI decomposition engine; Phase B1 speculative load issue past unresolved stores with LQ CAM snooping & ROB sticky mem_violation & one-shot replay-safe token; Phase B2 FQ16 expansion; Phase B3 MemIQ16 expansion; Phase B4 Oldest-Ready Matrix Scheduling).
- **Milestone 6** (Verified & Frozen): Advanced Branch Prediction & Instruction Stream Optimization (Phase A TAGE-Lite 5-table predictor ~3.7 KiB; Phase B Hardened RAS with RISC-V §2.5 coroutine-swap classification; Phase C Conservative L1I Next-Line Prefetcher with 4 KiB page abort; Phase D HPM Telemetry & CPI Conservation Closeout).
- **Milestone 7** (Verified & Frozen): Multi-Banked L1D, Dual AGU & Coherent Interconnect Integration (Phase A Port 2 AGU0 / Port 3 AGU1 load-dedicated issue & MemIQ16 dual-issue scheduler; Phase B 4-banked synonym-safe 16 KiB L1D datapath with same-bank collision arbitration & doubleword broadcast; Phase C dual-ported LQ16/SQ16 multi-lane store-to-load forwarding; Phase D protocol-neutral coherent snoop query/invalidation boundary & HPM expansion to 56 events).
- **Milestone 8** (Verified & Frozen): Standard Floating-Point (RV64FD) & Vector Execution (RVV 1.0) Subsystem Closeout (Dedicated 64-entry FPRF, FRAT, FPIQ16, pipelined FMA, Radix-4 FDIV/FSQRT, conversions, dual-AGU FP memory operations, 48-entry banked VRF, VIQ8 multi-beat uop expansion, `vtype`/`vl` dynamic calculation, VLEFF protocol, 64-event HPM telemetry expansion, and single-owner CPI conservation closure).

**Predecessor Freeze Commit:** `11a64ede257e98155ab7769f7b94b754980dd630`  
**Combined Frozen M1–M8 Production RTL Manifest SHA-256 (40 files):**  
`4d6fc54a6efb0d0deb94d4416926bd769c0783871499075f5de434959206d7cb`  
**Reference Documents:** `CPU_MASTER_PLAN.md` (Sections 1, 2, 4.5, 9 Gate G5), `docs/architecture/slice1-core-v1.md`, `docs/architecture/platform-sbi-v1.md`, `docs/architecture/sv39-mmu-v1.md`, `docs/architecture/plic-v1.md`, `docs/architecture/pmp-v1.md`, `docs/architecture/s-mode-bare-v1.md`.

---

## 1. Executive Summary & Scope Definition

### 1.1 Context & Objective
Milestones 1 through 8 established, optimized, and froze a 2-wide out-of-order, superscalar RISC-V processor core with full integer, floating-point (RV64FD), and vector architecture (RVV 1.0) execution capabilities, advanced branch prediction (TAGE-Lite), multi-banked caching, and an 8-category CPI cycle conservation telemetry engine.

However, `fursoy_s1_core` currently operates as an **isolated compute core verified in standalone testbenches**:
1. **Absence of Asynchronous Interrupts**: The core possesses no external interrupt pins. While `fursoy_s1_csr` contains `mip`/`mie` registers and synchronous trap logic, it lacks the asynchronous interrupt arbitration mechanism required to take timer, software, and external interrupts at the ROB head between instructions.
2. **Absence of Uncached MMIO Datapath**: All LSU traffic in `fursoy_s1_core` is currently channeled into 512-bit cache-line transactions (`bus_rd_req`, `bus_wr_req`). It possesses no byte-masked, un-cached bus channel to read and write memory-mapped peripheral registers (CLINT, PLIC, UART) non-speculatively.
3. **Absence of Slice-1 System-on-Chip (SoC) Fabric**: While `fursoy_s0_soc.sv` served the single-channel in-order Slice-0 core, no SoC wrapper exists to arbitrate Slice-1's four independent memory channels (L1I refill, L1D refill, L1D writeback, and PTW walks) into a unified DRAM subsystem and peripheral crossbar.

The objective of **Milestone 9 (M9)** is to complete the **Gate G5 ("Full Single-Core Linux-Bootable Processor") exit requirements** by engineering, integrating, and verifying:
- An **Asynchronous Interrupt Subsystem** with precise ROB head trap delivery, `mideleg` routing, and `WFI` sleep/wakeup semantics;
- A **Dedicated Uncached MMIO Pipeline** in LSU that executes non-speculatively at the ROB head with exact byte/halfword/word/doubleword transfer sizes, completely bypassing L1D cache arrays and MSHRs;
- The **Fursoy Slice-1 SoC Interconnect Fabric (`fursoy_s1_soc.sv`)**, featuring a 5-master crossbar arbitrating L1I, L1D refills, L1D evictions, PTW walks, and uncached MMIO into a 256 MB DRAM controller and peripheral bus;
- Integrated peripherals: **CLINT** (timer/software interrupts), **PLIC** (31 external interrupts), and **UART16550** (serial console);
- The **Minimal SBI v2.0 Firmware Runtime** and Flattened Device Tree (`fursoy_s1.dts`);
- **Full Linux 6.6.x Kernel Boot** to an interactive BusyBox userspace `/bin/sh` shell prompt, executing memory stress tests and multi-process workloads under Sv39 virtual memory.

```
+===================================================================================================+
|                                  MILESTONE 9 ARCHITECTURAL CHARTER                                |
+===================================================================================================+

  1. Asynchronous Interrupt Subsystem & Precise ROB Head Trap Arbitration (Phase A):
     Add external interrupt ports (irq_timer_i, irq_software_i, irq_external_i, irq_seip_i) to
     fursoy_s1_core. Wire mip/mie registers, implement mideleg S-mode delegation, and establish an
     exact ROB head interrupt delivery engine that vectors execution at instruction boundaries with
     zero register, free list, or checkpoint state corruption. Support WFI sleep/wakeup.

  2. Dedicated Uncached MMIO Pipeline & LSU Bypass Channel (Phase B):
     Equip the LSU and core boundary with an independent uncached MMIO master interface (mmio_req_o,
     mmio_rsp_i). Enforce strictly non-speculative execution: MMIO loads and stores issue ONLY when
     reaching the ROB head. Support 1/2/4/8-byte access widths with byte-enable strobes. Enforce
     PTW MMIO access rejection (reject_ptw_mmio) with precise page-fault generation.

  3. Fursoy Slice-1 SoC Interconnect Fabric & Peripherals Integration (Phase C):
     Implement fursoy_s1_soc.sv with a 5-master crossbar arbitrating L1I refill (512b), L1D refill (512b),
     L1D writeback (512b), PTW walk (64b), and core MMIO (64b). Integrate verified CLINT, PLIC, and
     UART16550 peripherals. Enforce physical address decoding, unmapped hole error responses, and
     synchronous interrupt distribution.

  4. Device Tree, Minimal SBI v2.0 Firmware & Early Linux Kernel Handoff (Phase D):
     Author fursoy_s1.dts with exact Slice-1 CPU features (RV64IMAFDV, 16K L1I, 16K L1D 4-bank).
     Compile minimal M-mode SBI firmware supporting Base, TIME, SRST, and DBCN extensions. Validate
     S-mode kernel handoff at 0x8020_0000 and achieve earlycon kernel console output.

  5. Full Linux Boot, Userspace Stress Suite & Milestone 9 Closeout (Phase E):
     Boot Linux 6.6.50 kernel to BusyBox 1.36.1 user space (/bin/sh). Execute memory allocation and
     userspace stress workloads (mem_stress) under Sv39 translation. Confirm 64-event HPM telemetry
     and CPI cycle conservation under Linux execution. Complete Gate G5 closeout.
```

### 1.2 Strict Scope Boundaries

To maintain rigorous architectural discipline and avoid scope creep, the following boundaries are formally established:

#### In-Scope:
- Addition of 4 external interrupt lines (`irq_timer_i`, `irq_software_i`, `irq_external_i`, `irq_seip_i`) to `fursoy_s1_core` and `fursoy_s1_csr`.
- Precise asynchronous interrupt retirement arbitration in `fursoy_s1_rob.sv` and `fursoy_s1_csr.sv` conforming strictly to Privileged Architecture v1.13.
- Hardware support for the `WFI` instruction: core sleeps when no interrupt is pending, waking combinationally upon assertion of any unmasked interrupt.
- Dedicated 64-bit uncached MMIO channel on `fursoy_s1_core` (`mmio_req_valid_o`, `mmio_req_addr_o`, `mmio_req_is_store_o`, `mmio_req_size_o`, `mmio_req_wdata_o`, `mmio_req_wstrb_o`, `mmio_rsp_valid_i`, `mmio_rsp_rdata_i`, `mmio_rsp_error_i`).
- Strict non-speculative execution for MMIO in `fursoy_s1_lsu_queues.sv` and `fursoy_s1_lsu.sv`: MMIO operations stall until reaching the ROB head.
- Implementation of `fursoy_s1_soc.sv` arbitrating L1I, L1D refills, L1D evictions, PTW reads, and MMIO accesses into a 256 MB DRAM controller and peripheral space.
- Integration of proven peripheral IP: CLINT (`rtl/platform/fursoy_s0_clint.sv`), PLIC (`rtl/platform/fursoy_s0_plic.sv`), and Lite-16550A UART (`rtl/platform/fursoy_s0_uart.sv`).
- Flattened Device Tree binary payload (`fursoy_s1.dtb`) declaring Slice-1 architecture, caches, and peripherals.
- Minimal SBI v2.0 firmware image (`sbi_firmware.elf`) providing Base, TIME, SRST, and DBCN extensions.
- Booting uncompressed 64-bit Linux kernel Image (Linux 6.6.50) with integrated BusyBox 1.36.1 initramfs to `/bin/sh` in Verilator.

#### Strictly Out-of-Scope:
- **Multi-Core Clustering & Hardware Coherent Interconnect**: Milestone 9 is strictly a **single-hart (Hart 0)** system integration milestone. Multi-core scaling (2→4→8 cores) and coherent L2/L3 cache hierarchies are deferred to Gate G7.
- **Physical PPA Convergence (Gate G6)**: Deep sub-micron standard cell placement, CTS, SPEF parasitic extraction, and full-chip timing closure are reserved for Gate G6.
- **Hardware AIA (APLIC / IMSIC)**: The platform utilizes standard RISC-V PLIC and CLINT controllers. Advanced Interrupt Architecture (AIA) is not required for RV64 Linux boot.
- **PCIe Root Complex, NVMe, and VirtIO**: Mass storage is provided via an embedded CPIO initramfs; complex bus controller IP is excluded from the initial SoC baseline.
- **Dynamic Branch Predictor Restructuring**: TAGE-Lite, RAS, and BTB geometries are frozen from Milestone 6 and will not be altered.
- **L1 Cache Array Re-architecting**: The 4-banked 16 KiB L1D and 16 KiB L1I designs are frozen from Milestone 7/8.

---

## 2. SoC Memory Map & Address Apertures

### 2.1 64-Bit Physical Address Space Allocation
The physical address space of `fursoy_s1_soc` is partitioned into distinct, non-overlapping architectural apertures:

```
+===================================================================================================+
|                               FURSOY SLICE-1 PHYSICAL MEMORY MAP                                  |
+===================================================================================================+

  Address Range                     Size      Region Name          Access Permissions  Description
  --------------------------------  --------  -------------------  ------------------  -----------------------------------------
  0x0000_1000 - 0x0000_1FFF         4 KiB     Boot ROM             M (R-X)             Hardware Reset Trampoline (Jumps to DRAM)
  0x0200_0000 - 0x0200_FFFF         64 KiB    CLINT MMIO           M only (RW)         Core-Local Interruptor (mtime, mtimecmp)
  0x0C00_0000 - 0x0C3F_FFFF         4 MiB     PLIC MMIO            M / S (RW)          Platform-Level Interrupt Controller
  0x1000_0000 - 0x1000_0FFF         4 KiB     UART MMIO            M / S (RW)          Lite-16550A Serial Console
  0x8000_0000 - 0x801F_FFFF         2 MiB     Firmware / SBI RAM   M only (RWX)        M-mode Minimal SBI Runtime & Stack
  0x8020_0000 - 0x81FF_FFFF         30 MiB    Linux Kernel Image   S / U (RWX)         Linux Kernel Payload (_start entry point)
  0x8200_0000 - 0x820F_FFFF         1 MiB     Device Tree (DTB)    S / U (RO)          Flattened Device Tree Binary
  0x8210_0000 - 0x8FFF_FFFF         223 MiB   Linux System DRAM    S / U (RWX)         Page Tables, Slab, Userspace Memory
  All Other Ranges                  --        Unmapped Apertures   None                Returns Bus Error -> Precise Access Fault
```

### 2.2 Aperture Attributes & Cacheability Rules
1. **DRAM Aperture (`0x8000_0000` – `0x8FFF_FFFF`)**:
   - Cacheable, idempotent, and supports 64-byte burst read/write transactions.
   - All instruction fetches and normal data loads/stores targeting this range allocate into L1I and L1D caches.
   - PMP checks (16 entries) are evaluated before physical issuance.
2. **Peripheral MMIO Apertures (`0x0200_0000` – `0x1000_0FFF`)**:
   - Strictly **Non-Cacheable** and **Non-Idempotent**.
   - Instruction fetching from MMIO apertures is **strictly prohibited**; attempting to fetch from MMIO generates an Instruction Access Fault (`cause = 1`).
   - Speculative data access is **strictly prohibited**. Accesses route via the dedicated core MMIO channel and execute strictly at the ROB head.
3. **Boot ROM Aperture (`0x0000_1000` – `0x0000_1FFF`)**:
   - Read-only, un-cached. Contains standard RISC-V reset trampoline instructions redirecting execution to `0x8000_0000`.

### 2.3 Unmapped Hole & Bus Access Error Contract
- Any physical address not encompassed within the defined apertures (e.g. `0x1000_1000` – `0x7FFF_FFFF`, or `> 0x9000_0000`) is an unmapped hole.
- The SoC crossbar immediately terminates accesses to unmapped apertures by asserting `error = 1` on the response bus.
- In `fursoy_s1_core`, a bus error on instruction fetch generates an **Instruction Access Fault** (`mcause/scause = 1`), on load generates a **Load Access Fault** (`mcause/scause = 5`), and on store generates a **Store Access Fault** (`mcause/scause = 7`).

### 2.4 PTW MMIO Rejection Contract (`reject_ptw_mmio`)
- In accordance with RISC-V Privileged Architecture §4.3.2, page table descriptors must reside strictly in idempotent RAM.
- If the hardware Page Table Walker (PTW) generates a memory request targeting an address outside the DRAM aperture (`pa < 64'h0000_0000_8000_0000` or `pa > 64'h0000_0000_8FFF_FFFF`), the access is immediately intercepted by `reject_ptw_mmio`.
- Zero bus transactions are issued to the peripheral interconnect. The PTW terminates the translation walk and returns a **Page Fault** (`cause = 12/13/15`) for the faulting virtual address, preventing peripheral register corruption or bus deadlock.

---

## 3. Asynchronous Interrupt Subsystem & Precise ROB Head Trap Delivery

### 3.1 External Interrupt Interface
`fursoy_s1_core` is augmented with four asynchronous interrupt inputs:
- `irq_timer_i`: Machine timer interrupt generated by CLINT (`mtime >= mtimecmp`).
- `irq_software_i`: Machine software/inter-processor interrupt generated by CLINT (`msip`).
- `irq_external_i`: Machine external interrupt generated by PLIC (`plic_irq_meip`).
- `irq_seip_i`: Supervisor external interrupt generated by PLIC (`plic_irq_seip`).

All interrupt inputs are level-sensitive, active-high, and synchronous to `clk_i`.

### 3.2 CSR Architecture: Interrupt Registers & Delegation
The core's CSR subsystem (`fursoy_s1_csr.sv`) implements complete standard interrupt control:

```
+===================================================================================================+
|                                    CSR INTERRUPT BIT MAPPING                                      |
+===================================================================================================+

  Bit    Interrupt Name         MIP Field    MIE Field    MIDELEG Bit   Delegatable to S-Mode?
  -----  ---------------------  -----------  -----------  ------------  ----------------------
  11     Machine External       MEIP         MEIE         0 (Fixed)     No
  9      Supervisor External    SEIP (plic)  SEIE         Bit 9 (RW)    Yes
  7      Machine Timer          MTIP         MTIE         0 (Fixed)     No
  5      Supervisor Timer       STIP         STIE         Bit 5 (RW)    Yes (via SBI Timer)
  3      Machine Software       MSIP         MSIE         0 (Fixed)     No
  1      Supervisor Software    SSIP         SSIE         Bit 1 (RW)    Yes (via SBI IPI)
```

1. **`mip` (Machine Interrupt Pending)**:
   - `mip.MTIP` reflects the registered state of `irq_timer_i`.
   - `mip.MSIP` reflects the registered state of `irq_software_i`.
   - `mip.MEIP` reflects the registered state of `irq_external_i`.
   - `mip.SEIP` reflects `irq_seip_i` ORed with software-writable supervisor external interrupt bit.
2. **`mie` (Machine Interrupt Enable)**: Standard WARL enable mask for individual interrupt sources.
3. **`mideleg` (Machine Interrupt Delegation)**:
   - When bit $k$ in `mideleg` is 1 and the core executes in Supervisor or User mode, interrupt $k$ is delegated to S-mode: it traps directly to `stvec`, recording cause in `scause` (with MSB `1'b1`), saving PC in `sepc`, and updating `sstatus.SPIE` and `sstatus.SPP`.
   - If bit $k$ is 0, or if executing in Machine mode, the trap vectors to `mtvec`.

### 3.3 Out-of-Order Interrupt Delivery Contract (ROB Head Invariant)
In an out-of-order superscalar pipeline, asynchronous interrupts **must not disrupt instruction execution mid-stream**.

```
                           +---------------------------+
                           |  Asynchronous Interrupt   |
                           |   (irq_timer/plic/clint)  |
                           +-------------+-------------+
                                         |
                                         v
                         +---------------+---------------+
                         | Pending & Unmasked Interrupt? |
                         | (mip & mie & global_enable)   |
                         +---------------+---------------+
                                         | Yes
                                         v
                      +------------------+------------------+
                      | Is Instruction at ROB Head Ready to |
                      |    Commit, or Waiting for Retire?   |
                      +------------------+------------------+
                                         |
                                         v
+===================================================================================================+
|                        PRECISE OUT-OF-ORDER INTERRUPT RETIREMENT INVARIANT                        |
|                                                                                                   |
|  1. Older instructions in ROB up to the interrupt point commit completely.                        |
|  2. The interrupt acts as an architectural boundary: the instruction at the ROB head is NOT       |
|     retired. Its PC is captured precisely in mepc / sepc.                                         |
|  3. All younger speculative instructions in ROB, IntIQ, MemIQ, FPIQ, and VIQ are purged.          |
|  4. Free list reclamation walks squashed ROB entries, restoring physical register ownership.      |
|  5. SRAT is restored from ARAT. Pipeline vectors to mtvec / stvec with ZERO state leakage.        |
+===================================================================================================+
```

**Formal Delivery Rules**:
1. An interrupt is candidate for delivery if and only if:
   $$\text{PendingMasked} = (\text{mip} \ \& \ \text{mie})$$
   $$\text{InterruptDeliverable} = (\text{priv\_mode} < M) \ \lor \ ((\text{priv\_mode} == M) \land \text{mstatus.MIE})$$
2. If an interrupt is deliverable, the ROB head arbitration halts further instruction retirements.
3. When instructions reside in the ROB, the instruction currently at the ROB head is **not retired**; its architectural program counter is preserved and written to `mepc` (or `sepc` if delegated). If an asynchronous interrupt arrives while the ROB is empty (e.g., during frontend instruction starvation, pipeline drain, or `WFI` sleep wakeup), the PC captured in `mepc`/`sepc` is the current architectural next-instruction fetch / redirect PC (`fe_pc`), vectoring cleanly without corrupting architectural state.
4. The interrupt cause is formatted as `(1'b1 << 63) | cause_idx` (e.g. `0x8000_0000_0000_0007` for MTIP, `0x8000_0000_0000_0009` for SEIP).
5. The core initiates a full architectural flush (`sys_flush_valid_o = 1`), purging all younger in-flight instructions across all issue queues and pipeline stages.
6. The Free List is reconstructed from ARAT, and execution redirects to `mtvec` or `stvec`.

### 3.4 Wait-For-Interrupt (`WFI`) Sleep & Wakeup Protocol
1. When a `WFI` instruction commits at the ROB head:
   - If any interrupt is pending in `mip` (regardless of `mstatus.MIE`), `WFI` acts as a 1-cycle NOP and execution continues to `PC + 4`.
   - If no interrupt is pending, the core transitions into an explicit `SLEEP` state: frontend instruction fetching is gated, pipeline dispatch halts, and core power dissipation is minimized.
2. The assertion of any qualified interrupt input (`irq_timer_i`, `irq_software_i`, `irq_external_i`) immediately clears the `SLEEP` state:
   - If `mstatus.MIE == 1`, the core immediately takes the interrupt trap vector.
   - If `mstatus.MIE == 0`, the core resumes execution by fetching the instruction at `PC + 4`, satisfying the RISC-V Privileged Specification §3.3.3.

---

## 4. Uncached MMIO Pipeline & LSU Bypass

### 4.1 Dedicated Core Boundary MMIO Interface
`fursoy_s1_core` exposes an independent uncached master channel:

```systemverilog
    // Dedicated Uncached MMIO Channel (Core Master -> SoC Crossbar)
    output logic                   mmio_req_valid_o,
    output logic [63:0]            mmio_req_addr_o,
    output logic                   mmio_req_is_store_o,
    output logic [2:0]             mmio_req_size_o,      // 0=1B, 1=2B, 2=4B, 3=8B
    output logic [63:0]            mmio_req_wdata_o,
    output logic [7:0]             mmio_req_wstrb_o,     // Byte enable mask
    input  logic                   mmio_req_ready_i,

    input  logic                   mmio_rsp_valid_i,
    input  logic [63:0]            mmio_rsp_rdata_i,
    input  logic                   mmio_rsp_error_i,
    output logic                   mmio_rsp_ready_o
```

### 4.2 Strict Non-Speculative Execution Contract
Peripherals (such as a UART RX FIFO or interrupt controller claim register) undergo destructive read side effects upon access.

**Architectural Contract**:
1. In `fursoy_s1_lsu_queues.sv`, physical addresses outside the DRAM aperture are flagged with `is_mmio = 1'b1`.
2. **Speculative Issue Ban**: An instruction with `is_mmio == 1'b1` is **strictly prohibited from issuing speculatively**.
3. **Head-of-ROB Serialized Dispatch**:
   - An MMIO load in the Load Queue (LQ16) or MMIO store in the Store Queue (SQ16) remains dormant until its associated `rob_idx` reaches the **absolute head of the ROB** (`rob_head_o == rob_idx`).
   - All older instructions must have completed and retired.
   - The pipeline must be free of active branch mispredictions or pending flushes.
4. Once verified at the ROB head, the MMIO request handshakes over `mmio_req_*`.
5. For MMIO stores, the store does not retire upon request handshake; the core holds the ROB head until `mmio_rsp_valid_i` returns (identical to MMIO loads). If `mmio_rsp_error_i == 1'b1`, a precise Store Access Fault (`mcause = 7`, `mtval = mmio_req_addr_o`) is recorded at the ROB head prior to retirement with zero memory or register side effects. If `mmio_rsp_error_i == 1'b0`, the store completes and retires in the response arrival cycle.
6. For MMIO loads, the core holds the ROB head until `mmio_rsp_valid_i` returns. If `mmio_rsp_error_i == 1'b1`, a precise Load Access Fault (`mcause = 5`, `mtval = mmio_req_addr_o`) is recorded at the ROB head prior to retirement with zero destination PRF corruption. If `mmio_rsp_error_i == 1'b0`, data is captured directly into the PRF writeback bus, completing the uop and retiring it in the same cycle.

### 4.3 Transfer Sizing & Byte Enable Generation
MMIO accesses strictly preserve the program-specified operand width:
- `LB` / `LBU` / `SB`: `mmio_req_size_o = 3'b000` (1 Byte). `mmio_req_wstrb_o` asserts exactly 1 bit according to `addr[2:0]`.
- `LH` / `LHU` / `SH`: `mmio_req_size_o = 3'b001` (2 Bytes). `mmio_req_wstrb_o` asserts exactly 2 bits aligned to `addr[2:1]`.
- `LW` / `LWU` / `SW`: `mmio_req_size_o = 3'b010` (4 Bytes). `mmio_req_wstrb_o` asserts 4 bits aligned to `addr[2]`.
- `LD` / `SD`: `mmio_req_size_o = 3'b011` (8 Bytes). `mmio_req_wstrb_o = 8'b1111_1111`.

### 4.4 Non-Blocking Cache & MSHR Immunity
- MMIO transactions **never allocate an L1D cache line**, **never allocate an MSHR**, and **never query the Writeback Buffer (WBB)**.
- MMIO traffic completely bypasses the 4-banked L1D SRAM arrays, guaranteeing zero tag pollution and zero interference with concurrent cacheable memory operations.

---

## 5. Slice-1 SoC Interconnect Fabric (`fursoy_s1_soc.sv`)

### 5.1 5-Master Interconnect Crossbar Topology
`fursoy_s1_soc.sv` encapsulates `fursoy_s1_core` and manages arbitration across five independent core masters:

```
+===================================================================================================+
|                                  FURSOY SLICE-1 SOC INTERCONNECT                                  |
+===================================================================================================+

    +-------------------+    512-bit
    | L1I Refill Master +------------+
    +-------------------+            |
    +-------------------+    512-bit |
    | L1D Refill Master +------------+     +==========================+     +----------------------+
    +-------------------+            +---->|                          |---->| 256 MB DRAM Memory   |
    +-------------------+    512-bit |     |   5-to-1 Crossbar &      |     | Controller (512-bit) |
    | L1D Evict Master  +------------+     |   Multi-Channel Arbiter  |     +----------------------+
    +-------------------+            |     |   (fursoy_s1_soc.sv)     |
    +-------------------+    64-bit  |     |                          |     +----------------------+
    | PTW Walk Master   +------------+     |                          |---->| Peripheral Crossbar  |
    +-------------------+            |     +==========================+     | (CLINT, PLIC, UART)  |
    +-------------------+    64-bit  |                                      +-----------+----------+
    | Core MMIO Master  +------------+                                                  |
    +-------------------+                                                               v
                                                                            +----------------------+
                                                                            | CLINT: 0x0200_0000   |
                                                                            | PLIC:  0x0C00_0000   |
                                                                            | UART:  0x1000_0000   |
                                                                            +----------------------+
```

### 5.2 Priority & Arbitration Hierarchy
To prevent pipeline starvation and guarantee forward progress:
1. **Priority Tier 1 — Core MMIO**: Since MMIO operations stall the ROB head, MMIO transactions receive highest dispatch priority on the peripheral bus.
2. **Priority Tier 2 — Shared PTW Walks**: Page table walks resolve translation misses for both L1I and L1D. Stalling PTW blocks entire execution pipelines; PTW reads hold priority over cache refills.
3. **Priority Tier 3 — L1I Refills**: High frontend priority to prevent instruction starve cycles (`C_fe_starve`).
4. **Priority Tier 4 — L1D Demand Refills**: Low-latency servicing of outstanding demand load misses.
5. **Priority Tier 5 — L1D Dirty Evictions**: Writeback buffer evictions drain opportunistically into DRAM when no higher-priority read requests contend for the bus.

### 5.3 Peripheral Integration
- **CLINT (`rtl/platform/fursoy_s0_clint.sv`)**:
  - Memory map: `0x0200_0000` (`msip`, 32-bit naturally aligned, `req_size_i == 3'd2`), `0x0200_4000` (`mtimecmp`, 64-bit naturally aligned, `req_size_i == 3'd3`), `0x0200_BFF8` (`mtime`, 64-bit naturally aligned, `req_size_i == 3'd3`).
  - Drives `irq_timer_i` when `mtime >= mtimecmp`; drives `irq_software_i` when `msip[0] == 1`. Non-conforming access sizes or misaligned offsets return bus error.
- **PLIC (`rtl/platform/fursoy_s0_plic.sv`)**:
  - Memory map: `0x0C00_0000` (priorities), `0x0C00_1000` (pending), `0x0C00_2000` (enables), `0x0C20_0000` (threshold & claim). Strictly 32-bit naturally aligned MMIO access (`req_size_i == 3'd2`).
  - Handles 31 interrupt sources; drives `irq_external_i` (M-mode) and `irq_seip_i` (S-mode). Source 1 is permanently mapped to UART.
- **UART16550 (`rtl/platform/fursoy_s0_uart.sv`)**:
  - Memory map (4-byte word-aligned stride, `reg-shift = 2`, `reg-io-width = 4`):
    * `0x1000_0000`: `RBR` (read) / `THR` (write) when `DLAB=0`; `DLL` divisor latch LSB when `DLAB=1`.
    * `0x1000_0004`: `IER` when `DLAB=0`; `DLM` divisor latch MSB when `DLAB=1`.
    * `0x1000_0008`: `IIR` (read, hardwired non-FIFO `2'b00`) / `FCR` (write, ignored).
    * `0x1000_000C`: `LCR` (line control register, bit 7 is DLAB).
    * `0x1000_0010`: `MCR` (modem control register).
    * `0x1000_0014`: `LSR` (line status register, reports THRE=1, TEMT=1, DR=0, value 0x60).
    * `0x1000_0018`: `MSR` (modem status register, 0x00).
    * `0x1000_001C`: `SCR` (scratch register).
  - Enforces strictly 32-bit naturally aligned MMIO accesses (`req_size_i == 3'd2`); non-32-bit or misaligned accesses are rejected with bus error and zero internal state mutation.
  - Transmits console bytes via simulation logging and asserts active-high level-sensitive IRQ routed exclusively to PLIC Source 1.

---

## 6. Firmware & Linux Boot Subsystem

### 6.1 Flattened Device Tree Specification (`fursoy_s1.dts`)
The system boots using an architectural device tree compiled with `dtc -I dts -O dtb`:

```dts
/dts-v1/;

/ {
    #address-cells = <2>;
    #size-cells = <2>;
    compatible = "fursoy,slice1-soc", "fursoy,fursoy-s1";
    model = "Fursoy Slice-1 Out-of-Order Server SoC";

    cpus {
        #address-cells = <1>;
        #size-cells = <0>;
        timebase-frequency = <10000000>; // 10 MHz CLINT timebase

        cpu@0 {
            device_type = "cpu";
            reg = <0>;
            status = "okay";
            compatible = "riscv";
            riscv,isa = "rv64imafdv_zba_zbb_zicsr_zifencei";
            mmu-type = "riscv,sv39";

            i-cache-size = <16384>;
            i-cache-block-size = <64>;
            i-cache-sets = <64>;
            d-cache-size = <16384>;
            d-cache-block-size = <64>;
            d-cache-sets = <64>;

            cpu0_intc: interrupt-controller {
                #interrupt-cells = <1>;
                compatible = "riscv,cpu-intc";
                interrupt-controller;
            };
        };
    };

    memory@80000000 {
        device_type = "memory";
        reg = <0x0 0x80000000 0x0 0x10000000>; // 256 MB DRAM
    };

    soc {
        #address-cells = <2>;
        #size-cells = <2>;
        compatible = "simple-bus";
        ranges;

        clint@2000000 {
            compatible = "riscv,clint0";
            reg = <0x0 0x02000000 0x0 0x00010000>;
            interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>; // Software (3), Timer (7)
        };

        plic: interrupt-controller@c000000 {
            compatible = "riscv,plic0", "sifive,plic-1.0.0";
            reg = <0x0 0x0C000000 0x0 0x00400000>;
            #interrupt-cells = <1>;
            interrupt-controller;
            riscv,ndev = <31>;
            interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>; // M-External (11), S-External (9)
        };

        serial@10000000 {
            compatible = "ns16550a";
            reg = <0x0 0x10000000 0x0 0x00001000>;
            interrupt-parent = <&plic>;
            interrupts = <1>;
            clock-frequency = <10000000>;
            current-speed = <115200>;
            reg-shift = <2>;
            reg-io-width = <4>;
        };
    };

    chosen {
        bootargs = "console=ttyS0,115200 earlycon=uart8250,mmio32,0x10000000 root=/dev/ram0 rw init=/init";
        stdout-path = "/soc/serial@10000000:115200n8";
    };
};
```

### 6.2 Minimal SBI v2.0 Firmware Runtime Contract
1. **Entry Point & Reset Execution**:
   - Hardware resets in M-mode at `0x8000_0000`.
   - Firmware initializes Machine stack, sets `mstatus.FS = 2'b01` (Initial) and `mstatus.VS = 2'b01` (Initial).
   - Configures PMP Entry 0 protecting SBI memory (`0x8000_0000`–`0x801F_FFFF`, NAPOT, no S/U access).
   - Configures `medeleg = 0xB3FF` and `mideleg = 0x0222` (delegating S-timer, S-software, S-external interrupts).
2. **SBI Extension Support**:
   - **Base Extension (EID `0x10`)**: Returns SBI spec version `2.0`, Fursoy implementation ID.
   - **Timer Extension (EID `0x54494D45`)**: Function 0 (`sbi_set_timer`) writes CLINT `mtimecmp`, clearing `mip.STIP`.
   - **Debug Console Extension (EID `0x4442434E`)**: Function 0/1/2 (`sbi_dbcn_write_byte`) forwards characters to UART.
   - **System Reset Extension (EID `0x53525354`)**: Shuts down simulation cleanly upon OS poweroff.
3. **Handoff to S-Mode**:
   - Firmware prepares S-mode register state: `a0 = 0` (Hart ID), `a1 = 0x8200_0000` (Physical address of DTB).
   - Sets `mepc = 0x8020_0000` (Linux kernel entry).
   - Sets `mstatus.MPP = 2'b01` (S-mode) and `mstatus.MPIE = 0`.
   - Executes `mret`, transferring architectural control to Linux kernel `_start`.

### 6.3 Linux Kernel & Userspace Environment
- **Kernel Image**: Standard Linux 6.6.50 compiled with `ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu-`.
- **Defconfig Features**: `CONFIG_SMP=n`, `CONFIG_MMU=y`, `CONFIG_RISCV_SBI=y`, `CONFIG_SERIAL_8250=y`, `CONFIG_SERIAL_8250_CONSOLE=y`, `CONFIG_FPU=y`, `CONFIG_RISCV_ISA_V=y`.
- **Rootfs / Initramfs**: Embedded CPIO archive containing BusyBox 1.36.1 and `/init` script mounting `/proc`, `/sys`, and launching test suites.
- **Userspace Workload**: Executes `mem_stress` verifying dynamic memory allocation (`malloc`, `free`), pointer chasing, and multi-process fork/wait operations under Sv39 translation.

---

## 7. Phased Execution Structure

Milestone 9 execution is structured into 5 sequential, auditable phases:

```
+---------------------------------------------------------------------------------------------------+
|                                  MILESTONE 9 EXECUTION PHASES                                     |
+---------------------------------------------------------------------------------------------------+
|  Phase A: Asynchronous Interrupt Subsystem & ROB Head Trap Delivery                               |
|           Wire irq_* ports, implement mip/mie registers, mideleg routing, ROB head interrupt      |
|           delivery invariant, and WFI sleep/wakeup state machine. Verify in s1_m9_phase_a_tb.     |
+---------------------------------------------------------------------------------------------------+
|  Phase B: Uncached MMIO Pipeline & LSU Bypass Channel                                             |
|           Equip LSU with dedicated uncached MMIO master channel, enforce head-of-ROB non-speculative  |
|           issue, 1/2/4/8-byte transfers, and reject_ptw_mmio. Verify in s1_m9_phase_b_tb.          |
+---------------------------------------------------------------------------------------------------+
|  Phase C: Slice-1 SoC Interconnect & Peripherals Integration (fursoy_s1_soc.sv)                   |
|           Implement fursoy_s1_soc crossbar arbitrating L1I, L1D, PTW, and MMIO. Integrate CLINT,  |
|           PLIC, and UART. Run bare-metal SoC test suite. Verify in s1_m9_phase_c_tb.              |
+---------------------------------------------------------------------------------------------------+
|  Phase D: Device Tree, SBI Firmware & Early Linux Kernel Handoff                                  |
|           Build fursoy_s1.dtb, compile minimal SBI firmware, hand off to S-mode at 0x8020_0000,    |
|           and achieve earlycon kernel console boot in Verilator. Verify in s1_m9_phase_d_tb.      |
+---------------------------------------------------------------------------------------------------+
|  Phase E: Full Linux Boot, Userspace Stress Suite & Milestone 9 Closeout                          |
|           Boot Linux to /bin/sh shell prompt, run mem_stress userspace benchmark, verify 64-event |
|           HPM telemetry and CPI conservation under Linux. Generate results/s1-m9-closeout.json.   |
+---------------------------------------------------------------------------------------------------+
```

---

## 8. Section 8 Mandatory Architectural Properties (`PROP_M9_01` .. `PROP_M9_30`)

To guarantee absolute verification rigor and eliminate vacuous test passing, Milestone 9 defines 30 verifiable properties:

### 8.1 Interrupt Subsystem Properties (Phase A)
- **`PROP_M9_01`**: Asynchronous interrupt arrival while `mstatus.MIE == 0` is buffered in `mip` without interrupting program execution.
- **`PROP_M9_02`**: Asynchronous interrupt arrival while `mstatus.MIE == 1` vectors strictly at the boundary of the instruction currently at the ROB head; the instruction at the ROB head is not retired.
- **`PROP_M9_03`**: Interrupt delivery causes zero register leakage: squashed younger speculative instructions return allocated physical registers to the Free List.
- **`PROP_M9_04`**: When `mideleg[k] == 1` and `priv_mode <= S`, interrupt $k$ vectors strictly to `stvec`, recording cause in `scause` and updating `sstatus.SPIE`.
- **`PROP_M9_05`**: When `mideleg[k] == 0`, interrupt $k$ vectors strictly to `mtvec`, recording cause in `mcause` and updating `mstatus.MPIE`.
- **`PROP_M9_06`**: `WFI` instruction sleep/wakeup: core enters sleep when no interrupt is pending, waking immediately upon assertion of an unmasked interrupt.

### 8.2 Uncached MMIO Datapath Properties (Phase B)
- **`PROP_M9_07`**: MMIO loads and stores remain dormant in LQ/SQ and issue to `mmio_req_*` if and only if their ROB slot reaches the ROB head (`rob_head_o == rob_idx`).
- **`PROP_M9_08`**: Speculative MMIO access ban: younger MMIO operations under pending branch mispredictions never issue bus handshakes.
- **`PROP_M9_09`**: MMIO transfers strictly preserve program operand size: `LB/SB` (1B), `LH/SH` (2B), `LW/SW` (4B), `LD/SD` (8B) with exact byte enable strobes (`mmio_wstrb`).
- **`PROP_M9_10`**: Sub-word MMIO loads are sign-extended (`LB`, `LH`, `LW`) or zero-extended (`LBU`, `LHU`, `LWU`) into the PRF destination register with zero bit-drift.
- **`PROP_M9_11`**: MMIO accesses produce zero allocations in L1D cache arrays, zero allocations in MSHRs, and zero queries against the WBB.
- **`PROP_M9_12`**: PTW MMIO rejection (`reject_ptw_mmio`): PTW requests targeting addresses outside DRAM aperture raise page-fault exceptions without issuing bus requests.

### 8.3 SoC Interconnect & Peripherals Properties (Phase C)
- **`PROP_M9_13`**: 5-master crossbar arbitration fairness: no master (L1I, L1D refill, L1D evict, PTW, MMIO) is starved under continuous saturated memory traffic.
- **`PROP_M9_14`**: CLINT register access exactness: 32-bit naturally aligned MMIO access (`req_size_i == 3'd2`) to `msip` (`0x0200_0000`) and 64-bit naturally aligned MMIO accesses (`req_size_i == 3'd3`) to `mtime` (`0x0200_BFF8`) and `mtimecmp` (`0x0200_4000`), complying strictly with `rtl/platform/fursoy_s0_clint.sv`.
- **`PROP_M9_15`**: CLINT timer interrupt assertion: `irq_timer_i` asserts when `mtime >= mtimecmp` and deasserts within 1 cycle of writing `mtimecmp > mtime`.
- **`PROP_M9_16`**: PLIC priority and claim arbitration: highest-priority active interrupt source is presented on claim register read; reading claim clears pending status.
- **`PROP_M9_17`**: UART16550 TX/RX loopback: written bytes to THR are captured in simulation log; incoming bytes generate PLIC interrupt line 1.
- **`PROP_M9_18`**: Unmapped aperture and MMIO bus error synchronization: MMIO loads and stores hold the ROB head until `mmio_rsp_valid_i` returns; responses with `mmio_rsp_error_i == 1'b1` record a precise access fault at the ROB head (`mcause = 5` for load, `mcause = 7` for store, `mtval = faulting_addr`) prior to retirement with zero architectural state mutation; unmapped instruction fetch returns error resulting in precise instruction access fault (`mcause = 1`).

### 8.4 Firmware & SBI Runtime Properties (Phase D)
- **`PROP_M9_19`**: Hardware reset execution starts at `0x8000_0000` in M-mode with clean CSR initialization.
- **`PROP_M9_20`**: SBI Base Extension (EID `0x10`) returns valid specification version and Fursoy implementation metadata.
- **`PROP_M9_21`**: SBI Timer Extension (`sbi_set_timer`) programs CLINT `mtimecmp` and clears `mip.STIP`.
- **`PROP_M9_22`**: SBI Console Extension (`sbi_dbcn_write_byte`) outputs characters to UART console.
- **`PROP_M9_23`**: S-mode handoff: firmware successfully executes `mret`, transferring control to `0x8020_0000` with `a0 = 0`, `a1 = 0x8200_0000`, and `priv_mode == S`.
- **`PROP_M9_24`**: Linux `earlycon` console registration: kernel parses `earlycon=uart8250,mmio32,0x10000000` boot argument and prints early boot banner to console.
- **`PROP_M9_25`**: Linux Sv39 MMU initialization: kernel successfully sets `satp`, enables paging, and transitions to virtual addressing.
- **`PROP_M9_26`**: Device Tree driver binding: Linux kernel parses `fursoy_s1.dtb`, probing CPU, memory, CLINT, PLIC, and UART drivers.

### 8.5 Full Linux Boot & Userspace Properties (Phase E)
- **`PROP_M9_27`**: Complete Linux kernel boot: kernel mounts embedded CPIO initramfs and executes `/init` without panic.
- **`PROP_M9_28`**: Userspace shell prompt: system reaches interactive BusyBox `/bin/sh` shell.
- **`PROP_M9_29`**: Userspace memory stress suite (`mem_stress`): executes dynamic memory allocation, pointer chasing, and multi-process fork/exec under Sv39 translation with zero memory corruption.
- **`PROP_M9_30`**: Telemetry and CPI cycle conservation closure: 64-event HPM telemetry records active kernel/userspace metrics, and single-owner CPI conservation holds with zero cycle leakage throughout full Linux boot.

---

## 9. Verification Gates & Sign-off Criteria

To achieve sign-off and freeze Milestone 9, the implementation must pass all eight verification gates:

```
+===================================================================================================+
|                                MILESTONE 9 VERIFICATION SIGN-OFF GATES                            |
+===================================================================================================+

  Gate 1: Verilator RTL Lint Cleanliness Gate
          Zero warnings, zero errors across all production RTL files using `verilator --lint-only -Wall`.

  Gate 2: Phase A Interrupt Subsystem Unit Gate
          All interrupt properties (PROP_M9_01..PROP_M9_06) pass in `verification/s1_m9_phase_a_tb.cpp`.

  Gate 3: Phase B Uncached MMIO Pipeline Unit Gate
          All MMIO properties (PROP_M9_07..PROP_M9_12) pass in `verification/s1_m9_phase_b_tb.cpp`.

  Gate 4: Phase C SoC Interconnect & Peripherals Gate
          All SoC properties (PROP_M9_13..PROP_M9_18) pass in `verification/s1_m9_phase_c_tb.cpp`.

  Gate 5: Phase D SBI Firmware & Linux Earlycon Gate
          All SBI/Earlycon properties (PROP_M9_19..PROP_M9_26) pass in `verification/s1_m9_phase_d_tb.cpp`.

  Gate 6: Phase E Full Linux Boot & Userspace Stress Gate
          Full Linux kernel boot reaches BusyBox userspace (/bin/sh); userspace memory suite executes cleanly;
          properties (PROP_M9_27..PROP_M9_30) pass in `verification/s1_m9_closeout_tb.cpp`.

  Gate 7: CPI Cycle Conservation & Telemetry Gate
          Continuous per-cycle verification confirms zero unclassified cycle leakage across Linux boot:
          sum(C_0..7) == Delta(mcycle).

  Gate 8: Predecessor Regression Invariant Gate
          All historical regression suites pass cleanly with exit code 0:
          M8 Closeout, M8 Phase D/C/B/A, M7 Closeout, M6 Closeout, M5 B4, M1 Substrate, Slice-0 contract.
```
