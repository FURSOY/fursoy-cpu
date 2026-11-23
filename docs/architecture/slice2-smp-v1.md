# Fursoy Slice-2 — Symmetric Multi-Processing (SMP) Multi-Core Architecture Specification

**Document ID:** `docs/architecture/slice2-smp-v1.md`  
**Status:** CANONICAL ARCHITECTURAL SPECIFICATION v1.1 (Post-Audit Revision — Ready for `S2-M1`)  
**Baseline Anchor:** `main` @ `2e46fa4` (Slice-1 Single-Core Gate G5 Signed Off)  
**Target Cluster / SoC:** `fursoy_s2_cluster` / `fursoy_s2_soc` (Scalable `NUM_HARTS = 2` default, `4`-hart ready, `RV64IMAFDV_Zba_Zbb_Zicsr_Zifencei_Sv39`)  
**Target Frequency / Library:** `500 MHz` (`2.000 ns` period) on Nangate45 Typical (`1.10V, 25C`)  
**Reference Documents:** `docs/architecture/slice1-core-v1.md`, `docs/architecture/slice1-m7-multibank-l1d-v1.md`, `docs/architecture/slice1-m9-soc-linux-v1.md`, `docs/architecture/plic-v1.md`, `docs/architecture/rv64a-v1.md`.

---

## 1. Top-Level SMP Topology & Scalability (`NUM_HARTS = 2` default, `4`-hart ready)

### 1.1 Cluster & SoC Hierarchy
Slice-2 scales the verified Slice-1 2-wide out-of-order core (`rtl/core/fursoy_s1_core.sv`) into a symmetric multi-core cluster backed by a **directory-tracked MESI Coherence Hub + Shared L2** (`fursoy_s2_coherence_mgr` / `fursoy_s2_l2`). A directory-backed hub is chosen over a raw broadcast-snooping crossbar because:
1. Broadcast N-way combinational snoop fanout and N-way tag lookups degrade `500 MHz` (`2.000 ns`) timing closure at `NUM_HARTS = 4`.
2. A centralized directory serializes all coherence transactions at a single point of coherence, guaranteeing `RVWMO` multi-copy atomicity (`IRIW`) and clean scaling across `N = 2` and `N = 4`.

```text
  +---------------------+         +---------------------+
  |  fursoy_s1_core #0  |   ...   | fursoy_s1_core #N-1 |  mhartid_i = 0 .. N-1
  |  SMP_COHERENCE_EN=1 |         |  SMP_COHERENCE_EN=1 |  Shared clk_i / rst_i
  +---+------+------+---+         +---+------+------+---+
      |      |      |                 |      |      |
    MMIO    PTW   L1I/L1D           MMIO    PTW   L1I/L1D
      |      |  (VC0rd/VC0wr/VC1/VC2) |      |  (VC0rd/VC0wr/VC1/VC2)
      |      +------+-----------------+------+------+
      |             |                               |
      |             v                               |
      |   +-----------------------------------------+---+
      |   |      fursoy_s2_coherence_mgr + fursoy_s2_l2 |
      |   |  (Directory MSHRs, Snoop Filter, L2 Arrays) |
      |   +---------------------+-----------------------+
      |                         | 512-bit DRAM Port
      v                         v
  +------------------------+   External 256 MiB DRAM (0x8000_0000 .. 0x8FFF_FFFF)
  |  fursoy_s2_mmio_xbar   |   (Registered arbiter + registered slave handshakes)
  +----+-------+-------+---+
       |       |       |
       v       v       v
  fursoy_s2_clint  fursoy_s2_plic  fursoy_s0_uart
```

New Slice-2 RTL modules:
- `rtl/platform/fursoy_s2_cluster.sv`: Instantiates `NUM_HARTS` instances of `fursoy_s1_core` (`gen_harts[0 .. NUM_HARTS-1]`) with `SMP_COHERENCE_EN = 1'b1` and `mhartid_i = 64'(h)`, connected to `fursoy_s2_coherence_mgr` (which embeds or wraps `fursoy_s2_l2`).
- `rtl/platform/fursoy_s2_coherence_mgr.sv` and `rtl/platform/fursoy_s2_l2.sv`: Directory-backed MESI coherence hub, L1I/PTW coherent read interface, and shared L2 cache.
- `rtl/platform/fursoy_s2_mmio_xbar.sv`: Round-robin arbitrated `NUM_HARTS`-to-4 MMIO crossbar with a registered arbiter-to-slave output stage connecting per-hart `mmio_req_*`/`mmio_rsp_*` ports to `fursoy_s2_clint`, `fursoy_s2_plic`, `fursoy_s0_uart`, and an unmapped-aperture error responder (`rsp_error = 1'b1`).
- `rtl/platform/fursoy_s2_clint.sv`: Parameterized multi-hart CLINT (`0x0200_0000`).
- `rtl/platform/fursoy_s2_plic.sv`: Parameterized multi-context PLIC (`0x0C00_0000`).
- `rtl/platform/fursoy_s2_soc.sv`: Top-level SMP SoC wrapping `fursoy_s2_cluster`, `fursoy_s2_mmio_xbar`, `fursoy_s2_clint`, `fursoy_s2_plic`, and `fursoy_s0_uart`, plus per-hart PMP L1I aperture checks (`0x8000_0000 .. 0x801F_FFFF` restricted to M-mode, mirroring `fursoy_s1_soc.sv`).

### 1.2 Shared Clock, Reset & Boot Partitioning
- **Clock & Reset**: All harts, the coherence hub, and platform peripherals share a single synchronous `clk_i` and active-high `rst_i`.
- **Reset Vector**: All `NUM_HARTS` cores begin execution at `0x8000_0000` in M-mode (`priv_mode_q = 2'b11`). Hart `0` proceeds through platform SBI initialization; Harts `1 .. NUM_HARTS-1` branch immediately on `csrr t0, mhartid` into an M-mode `WFI` parking loop until woken by Hart `0` via SBI HSM (`msip[h] = 1`). No per-hart reset-PC hardware override is required.

### 1.3 `SMP_COHERENCE_EN` Backward Compatibility & `fursoy_s1_core.sv` Port Delta
Existing Slice-1 verification suites (`tools/run_s1_lint.py`, `tools/run_s1_sail_cosim.py`, `tools/run_s1_m9_closeout.py`, `verification/s1_m4_tb.cpp`, `verification/s1_m7_tb.cpp`) instantiate `fursoy_s1_core` directly, inspect hierarchical paths (`u_backend__DOT__u_lsu__DOT__u_lsu_queues`), and rely on 0-cycle combinational snoop responses in `s1_m7_tb.cpp` (`01 = SNOOP_INV`, `10 = SNOOP_READ`, `11 = SNOOP_CLEAN_INV`).

To guarantee **zero Slice-1 regression breakage**:
1. Add `parameter bit SMP_COHERENCE_EN = 1'b0` to `fursoy_s1_core`, `fursoy_s1_backend`, `fursoy_s1_lsu`, `fursoy_s1_lsu_queues`, `fursoy_s1_l1d`, `fursoy_s1_frontend`, and `fursoy_s1_l1i`. When `SMP_COHERENCE_EN = 1'b0`, all Slice-1 single-core semantics (including 0-cycle snoop response, immediate `SC` evaluation, and `CLEAN_SWEEP`) remain bit-identical.
2. Preserve all existing instance names (`u_substrate`, `u_backend`, `u_frontend`, `u_csr`, `u_lsu`, `u_lsu_queues`, `u_l1d`, `u_l1i`, `u_ptw`).
3. Tie new input ports on `fursoy_s1_core` to `'0` in `rtl/platform/fursoy_s1_soc.sv` so `verilator --lint-only -Wall` stays zero-warning clean, and default-zero inputs in Verilator C++ testbenches require no C++ modifications.

| Interface Group | Existing `fursoy_s1_core.sv` Ports | Slice-2 Additions (`SMP_COHERENCE_EN = 1`) |
| :--- | :--- | :--- |
| **Hart Identification** | *(none; `12'hf14` hardwired `64'd0` in `fursoy_s1_csr.sv`)* | `input logic [63:0] mhartid_i` → wired to `u_csr.mhartid_i` (`12'hf14` returns `mhartid_i`) |
| **L1D Coherence Read/Upgrade (`VC0_RD` / `VC2`)** | `bus_rd_req_valid_o`, `bus_rd_req_addr_o[49:0]`, `bus_rd_req_tag_o`, `bus_rd_req_ready_i`, `bus_rd_rsp_valid_i`, `bus_rd_rsp_tag_i`, `bus_rd_rsp_data_i[511:0]` | `output coh_req_op_t bus_rd_req_op_o` (`COH_GETS`, `COH_GETM`, `COH_UPGRADE`), `input mesi_state_t bus_rd_rsp_state_i` (`MESI_S`, `MESI_E`, `MESI_M`), `input logic bus_rd_rsp_has_data_i` |
| **L1D Writeback (`VC0_WR` / `VC2`)** | `bus_wr_req_valid_o`, `bus_wr_req_addr_o[49:0]`, `bus_wr_req_data_o[511:0]`, `bus_wr_req_ready_i`, `bus_wr_rsp_valid_i` | Separate `VC0_WR` channel for dirty `PutM` evictions; `bus_wr_rsp_valid_i` acts as `PutAck` from `fursoy_s2_coherence_mgr`. Clean `E`/`S` evictions are silent (no `VC0_WR` traffic). |
| **L1D Snoop Channel (`VC1` / `VC2`)** | `snoop_req_valid_i`, `snoop_req_addr_i[55:0]`, `snoop_req_type_i[1:0]`, `snoop_rsp_valid_o`, `snoop_rsp_has_data_o`, `snoop_rsp_was_dirty_o`, `snoop_rsp_data_o[511:0]` | `output logic snoop_req_ready_o` (was unconnected in `fursoy_s1_lsu.sv`), `input logic snoop_rsp_ready_i`, `output logic snoop_rsp_ack_only_o` |
| **L1I Coherence** | `l1i_bus_rd_req_*`, `l1i_bus_rd_rsp_*` | Routed through `fursoy_s2_coherence_mgr` (`COH_GETS_NC`); `l1i_bus_rd_req_tag_o` widened/paired with `imshr_epoch_q` tracking across `FENCE.I` (§3.3). |
| **PTW Coherence** | `ptw_mem_req_{valid_o,addr_o,ready_i}`, `ptw_mem_rsp_{valid_i,data_i,error_i}` | Routed through `fursoy_s2_coherence_mgr` coherent 8-byte/64-byte read port (`COH_GETS_NC`, after local `backend_sq_empty` + `ptw_snoop_dirty_hit`). |
| **CLINT / PLIC IRQs** | `irq_timer_i`, `irq_software_i`, `irq_external_i`, `irq_seip_i`, `mtime_i` | **Unchanged** — per-hart wires from `fursoy_s2_clint` & `fursoy_s2_plic`. |

---

## 2. MESI Cache Coherence Protocol & Directory-Backed L2

### 2.1 MESI State Encoding & L1D Extensions (`rtl/core/fursoy_s1_l1d.sv`)
When `SMP_COHERENCE_EN = 1`, each cache line in the 16 KiB 4-way L1D (`64` sets × `4` ways × `64 B`) carries a 2-bit `mesi_state_t` in `coh_state_array[L1D_SETS][L1D_WAYS]` (defined in `rtl/core/fursoy_s1_pkg.sv`):

| Encoding | State | Valid | Dirty | Local Read | Local Write / AMO / SC | External Snoop Behavior |
| :--- | :--- | :---: | :---: | :--- | :--- | :--- |
| `2'b00` | `MESI_I` (Invalid) | `0` | `0` | Miss → MSHR `COH_GETS` | Miss → MSHR `COH_GETM` | Ack (`has_data = 0, was_dirty = 0`) |
| `2'b01` | `MESI_S` (Shared) | `1` | `0` | Hit | Hit-no-perm → MSHR `COH_UPGRADE` | `GETS`: keep `S`; `INV`/`GETM`: `S → I` |
| `2'b10` | `MESI_E` (Exclusive) | `1` | `0` | Hit | Hit → silent `E → M` write | `GETS`: `E → S`; `INV`/`GETM`: `E → I` |
| `2'b11` | `MESI_M` (Modified) | `1` | `1` | Hit | Hit → stay `M` | `GETS`: `M → S` + dirty data; `GETM`/`INV`: `M → I` + dirty data |

`valid_array` and `dirty_array` remain synchronized (`valid = (state != MESI_I)`, `dirty = (state == MESI_M)`) so existing `select_victim_way()` and `ptw_snoop_dirty_hit_o` continue to operate uniformly.

#### L1D Refill, MSHR & WBB Extensions (`mshr_entry_t` / `wbb_entry_t` in `fursoy_s1_pkg.sv`)
- **Extend `mshr_entry_t` with**:
  - `coh_req_op_t req_op` (`COH_GETS`, `COH_GETM`, `COH_UPGRADE`)
  - `logic [1:0] upgrade_way` (way index for `COH_UPGRADE`; **must also populate `victim_way <= upgrade_way`** so `*_set_mshr_reserved_ways` locks `upgrade_way` against eviction by concurrent misses in the same set)
  - `mesi_state_t grant_state` (captured on `bus_rd_rsp_valid_i` into `rsp_fifo_q` / Beat 0)
  - `logic grant_has_data` (captured from `bus_rd_rsp_has_data_i`)
  - `logic grant_committed_q` (set once `bus_rd_rsp_valid_i` arrives for this MSHR)
  - `logic snoop_inv_seen` / `logic snoop_downgrade_seen`
- **Beat 1 `dirty_array` & `coh_state_array` Install**:
  - On Beat 1 (`refill_busy_q`), L1D **must not** hardcode `dirty_array[set_i][rep_way] <= 1'b0` (`fursoy_s1_l1d.sv#L1169`). Instead, when `SMP_COHERENCE_EN = 1`:
    - `coh_state_array[set_i][rep_way] <= mshr_q[refill_tag_q].grant_state`
    - `dirty_array[set_i][rep_way] <= (mshr_q[refill_tag_q].grant_state == MESI_M)`
  - Preserving `MESI_M` / `dirty = 1` on `GrantM` dirty forwarding ensures that if a remote L1D forwarded dirty data (`M → I` without updating L2/DRAM) and the local `SC` aborts or the line is later evicted before a store modifies it, the line is still written back to L2 via `PutM` on eviction or forwarded on snoop.
- **Full Refill-Window Snoop Protection**:
  - Once the Coherence Hub commits `bus_rd_rsp_valid_i` (`Grant*`) on `VC2`, L1D **must never set `mshr_snoop_invalid_q`** for that MSHR (`!mshr_q[m].grant_committed_q`).
  - Instead, `snoop_req_ready_o` deasserts (`1'b0`) whenever:
    1. `refill_busy_q` (Beat 1) is active, or
    2. `refill_beat0_active` (`!refill_busy_q && ((rsp_fifo_count_q != 3'd0) || refill_arriving)`) is active for any buffered `rsp_fifo_q` entry or incoming `bus_rd_rsp_valid_i` matching `snoop_req_addr_i` (or unconditionally during the 2-cycle Beat 0/Beat 1 install window).
  - Because `rsp_fifo_q` and Beat 0/Beat 1 drain unconditionally without waiting on `VC0`/`VC1`, stalling `snoop_req_ready_o` across the refill window is strictly bounded and causes the incoming snoop to observe the freshly installed `coh_state_array`/`bank_data` (including forwarding dirty data if `grant_state == MESI_M`).
- **Write-Permission Stall (`S → M`) & Victim Eviction**:
  - In `fursoy_s1_l1d.sv`, `store_cache_hit` requires `(coh_state_array[store_set][store_cache_hit_way] inside {MESI_E, MESI_M})`. When a store/AMO/SC hits in `MESI_S`, `store_can_drain` treats it as a permission miss (`store_upgrade_miss = 1`) and allocates an MSHR with `req_op = COH_UPGRADE`, `upgrade_way = store_cache_hit_way`, and `victim_way = store_cache_hit_way` (no WBB reservation needed).
  - Clean `E`/`S` victim evictions are **silent** (no `PutE`/`PutS` bus traffic).
- **Both `Upgrade`-vs-`Invalidate` Race Directions**:
  1. **Forward race (`SNOOP_INV`/`SNOOP_GETM` arrives before `GrantM`)**: When `SNOOP_INV` or `SNOOP_GETM` hits an active `COH_UPGRADE` MSHR (`!grant_committed_q`), set `mshr_q[m].snoop_inv_seen <= 1'b1` and **do not** set `mshr_snoop_invalid_q[m]`. When Hart `0`'s `COH_UPGRADE` reaches serialization in `fursoy_s2_coherence_mgr`, the Hub checks `sharer_vec[0]`: seeing `0`, the Hub automatically promotes the response to a full data grant (`bus_rd_rsp_has_data_i = 1`, `bus_rd_rsp_state_i = MESI_M`) with the latest 512-bit line, and L1D executes Beat 0/Beat 1 install cleanly.
  2. **Reverse race (`GrantM(has_data = 0)` on `VC2` overtaken by `SNOOP_GETM`/`SNOOP_INV` on `VC1`)**: Because `VC1` and `VC2` are independent channels, a remote `SNOOP_GETM`/`SNOOP_INV` on `VC1` can invalidate the local `S` line (`S → I`, setting `snoop_inv_seen <= 1'b1`) *after* the Hub launched `GrantM(has_data = 0)` on `VC2` (Wait—note that under strict directory serialization, the Hub will not serialize a competing `GetM` before `GrantM` is issued unless `VC1` from an earlier grant overtook `VC2`; handling this case unconditionally makes L1D immune to channel reordering). If `bus_rd_rsp_valid_i` arrives for a `COH_UPGRADE` MSHR with `bus_rd_rsp_has_data_i == 0` while `snoop_inv_seen == 1` (or `coh_state_array[set][upgrade_way] == MESI_I`), L1D **must discard** the dataless `GrantM` (never promote `I → M`) and transition the MSHR back to `MSHR_WAIT_BUS` with `req_op <= COH_GETM`, `snoop_inv_seen <= 1'b0`, and `grant_committed_q <= 1'b0` to re-fetch the full line.
  3. **Normal uncontested `COH_UPGRADE`**: If `bus_rd_rsp_has_data_i == 0` and `!snoop_inv_seen` (line still in `MESI_S`), L1D promotes `coh_state_array[set][upgrade_way] <= MESI_M` in 1 cycle with zero bank overwrite and frees the MSHR (or drains waiters).

#### WBB `PutM` vs. `SNOOP_*` Races & Silent Data Loss Prevention (Option A)
In `fursoy_s1_l1d.sv#L259-L280`:
1. **Separate forwarding vs. snoop WBB matching**: Keep `check_wbb_hit` (load/store forwarding) and `ptw_snoop_wbb_hit` gated on `!wbb_q[i].draining`, **but allow `snoop_wbb_hit` to match `wbb_q[i]` even when `wbb_q[i].draining == 1`**. When a `SNOOP_GETS` or `SNOOP_GETM` hits a `draining == 1` dirty `wbb_q[idx]` slot (`valid && draining && dirty`), L1D forwards `SnoopRsp(has_data = 1, was_dirty = 1)`, clears `wbb_q[idx].dirty <= 1'b0`, and **keeps `wbb_q[idx].valid == 1'b1` while `draining == 1`** until `PutAck` (`bus_wr_rsp_valid_i`) clears both `valid` and `draining`.
2. **Preserve `wbb_slot*_avail` until `PutAck`**: `wbb_slot0_avail = !wbb_q[0].valid` and `wbb_slot1_avail = !wbb_q[1].valid` remain `0` while `draining == 1` until `bus_wr_rsp_valid_i` (`PutAck`) arrives, guaranteeing a new dirty victim `Y` can never overwrite an in-flight `PutM` slot even after its dirty payload was forwarded via `SnoopRsp`.
3. **Invalidate non-draining WBB on `SNOOP_GETS` (no `S`-state WBB retention)**: When `SNOOP_GETS` hits a non-draining dirty `wbb_q[idx]` (`valid && !draining && dirty`), L1D forwards the 512b dirty payload (`snoop_rsp_was_dirty_o = 1`, `snoop_rsp_has_data_o = 1`) and **invalidates `wbb_q[idx].valid <= 1'b0`** (`dirty <= 1'b0`). Because L2 receives the forwarded dirty line and becomes coherent owner/sharer, retiring the non-draining WBB slot prevents WBB slot leaks and guarantees `store_wbb_hit` can never write into a clean `S`-state WBB line.

### 2.2 Formalized `snoop_op_t`, 2-Stage Snoop Pipeline & Virtual Channels
Formalize `snoop_op_t` in `fursoy_s1_pkg.sv` matching `s1_m7_tb.cpp` (`bit[0] = inv`, `bit[1] = read`, with `2'b00` mapped to legacy `INV` when `SMP_COHERENCE_EN = 0`):

| `snoop_op_t` | Encoding | Meaning | Action on `M` | Action on `E` | Action on `S` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `SNOOP_INV` | `2'b01` | Invalidate copy (L2 back-invalidation / upgrade) | `M → I` (writeback/discard per `CLEAN_INV`) | `E → I`, ack | `S → I`, ack |
| `SNOOP_GETS` | `2'b10` | Coherent shared read (`SNOOP_READ`) | `M → S` + return 512b dirty data | `E → S`, ack | `S → S`, ack |
| `SNOOP_GETM` | `2'b11` | Coherent read-for-ownership (`SNOOP_CLEAN_INV`) | `M → I` + return 512b dirty data | `E → I`, ack | `S → I`, ack |

#### 2-Stage L1D Snoop Pipeline (`S0` / `S1`) Hazards & `LQ` Replay
When `SMP_COHERENCE_EN = 1`, snoops execute in two registered stages (`S0` acceptance → `S1` bank readout/response):
- **Bank & store-drain priority across `S0` and `S1`**: When `S0` detects a snoop hit (`snoop_s0_hit`) or `S1` is retiring a snoop hit (`snoop_s1_hit`), suppress `store_can_drain` and `load0/1_accept` to the matching `line_addr` (or matching set/way) across **both `S0` and `S1`** so a store draining into `E`/`M` cannot write `bank_data` in the same cycle `S0` invalidates or downgrades that line.
- **Beat 0 / Beat 1 refill gating**: `snoop_req_ready_o` gates off whenever `refill_beat0_active || refill_busy_q` (or when `amo_line_lock_q == 1`, §3.2) so an `S0` snoop can never collide with Beat 1 writes to `bank_data[4..7]` in `S1`.
- **Speculative `LQ` replay window**: In `fursoy_s1_lsu_queues.sv`, evaluate `snoop_lq_match` in **both `S0` and `S1`** — covering `S0` acceptance (`snoop_req_valid_i && snoop_req_ready_o && snoop_do_inv`) as well as loads completing via `load0/1_rsp_valid_o && load0/1_rsp_hit_o` or `mshr_refill_valid_i` on the cycle a snoop enters `S0` — so in-flight speculative loads/`LR`s never escape `lsu_violation_valid_o`.

#### Virtual Channel Separation & Deadlock-Freedom Invariants
Four logically independent non-blocking channels connect each core's L1D to `fursoy_s2_coherence_mgr`:
1. **`VC0_RD` — Read / Upgrade Requests (Core → Hub)**: Dedicated per-hart skid buffer for `GetS`, `GetM`, `Upgrade`.
2. **`VC0_WR` — Dirty Writebacks (Core → Hub)**: Separate per-hart skid buffer for `PutM` (never head-of-line blocked behind stalled `VC0_RD` requests, preventing WBB exhaustion deadlocks).
3. **`VC1` — Snoop / Forward (Hub → Core)**: `SNOOP_GETS`, `SNOOP_GETM`, `SNOOP_INV`.
4. **`VC2` — Responses (Bidirectional)**: Core → Hub `SnoopRsp` (with optional 512b dirty payload) and Hub → Core `Grant` (`GrantS/E/M` ± 512b data) and `PutAck`.

`VC2` is strictly non-blocking and never waits on `VC1` or `VC0_RD`/`VC0_WR`; `snoop_req_ready_o` only deasserts for bounded local hazards (`refill_beat0_active`, `refill_busy_q`, or 2-cycle `amo_line_lock_q`) that drain unconditionally without bus traffic.

### 2.3 Directory-Backed Shared L2 (`fursoy_s2_coherence_mgr` + `fursoy_s2_l2`)
- **Geometry**: Parameterizable shared inclusive L2 (default **256 KiB, 8-way, 512 sets, 64 B line**).
- **Directory State per L2 Line**:
  - `tag[40:0]` (`PA[55:15]`), `l2_state` (`L2_I`, `L2_S`, `L2_M`), `l2_dirty`, `sharer_vec[NUM_HARTS-1:0]`, `owner_id[$clog2(NUM_HARTS)-1:0]`.
  - **Silent `E`/`S` eviction handling**: Because clean `E`/`S` L1D evictions are silent, a snoop to a hart marked in `sharer_vec` or `owner_id` may return `has_data = 0, was_dirty = 0`. When `SNOOP_GETS` or `SNOOP_GETM` targets `L2_M` and the owner returns `has_data = 0` (meaning the owner held clean `E` and silently evicted), the Hub serves the authoritative 512b line directly from `fursoy_s2_l2` data arrays and clears the former owner from `sharer_vec`/`owner_id`.
- **Late `PutM` & `VC0_WR` Stall Interaction (Option A)**: If a `PutM` from Hart `h` is stalled in `VC0_WR` behind an active `DIR_MSHR`, no dirty data is lost because `snoop_wbb_hit` (§2.1) matches the `draining == 1` WBB slot and forwards `SnoopRsp(has_data = 1, was_dirty = 1)` directly on `VC2` (clearing `dirty` while preserving `valid` and `draining`). Once the `DIR_MSHR` retires and the stalled `PutM` unblocks into `Stage C0` of `fursoy_s2_coherence_mgr`, the directory observes `owner_id != h` (or `!sharer_vec[h]` or `l2_state != L2_M`) and returns `PutAck` as a **no-op writeback** (without overwriting L2 data or altering `owner_id`/`sharer_vec`) to retire the draining WBB slot cleanly. If `PutM` reaches `Stage C0` first while `DIR_MSHR` is still waiting on Hart `h`'s snoop response, the Hub consumes the `PutM` payload as the authoritative dirty writeback, clears the pending snoop wait, and sends `PutAck`.
- **Directory MSHR Serialization & `victim_addr` Hazards**: `fursoy_s2_coherence_mgr` maintains an 8-entry Directory Transaction Table (`DIR_MSHR_DEPTH = 8`). Each `DIR_MSHR` entry tracks both `line_addr` (the miss line) and `victim_addr` (the L2 capacity-eviction victim undergoing back-invalidation, if any). Any incoming `VC0_RD` or `VC0_WR` request whose address matches *either* `line_addr` or `victim_addr` of an active `DIR_MSHR` waits in its per-hart skid buffer until that `DIR_MSHR` retires, eliminating races between `PutM(V)` and L2 eviction of `V`.
- **Cache-to-Cache Dirty Forwarding vs. L2 Writeback**:
  - `SNOOP_GETM` hitting `M` in Hart `j`: Hart `j` transitions `M → I` and returns dirty data on `VC2`; Hub forwards dirty data directly to requester Hart `i` (`GrantM`), updates `owner_id = i`, `sharer_vec = (1 << i)` (no DRAM write).
  - `SNOOP_GETS` hitting `M` in Hart `j`: Hart `j` transitions `M → S` and returns dirty data on `VC2`; Hub forwards data to requester Hart `i` (`GrantS`), writes dirty data into L2 (`l2_dirty = 1`, `l2_state = L2_S`), and sets `sharer_vec = (1 << i) | (1 << j)`.
- **Coherent L1I & PTW Paths**:
  - **L1I**: `l1i_bus_rd_req_*` connects to a read-only requester port on `fursoy_s2_coherence_mgr` (`COH_GETS_NC`). The Hub snoops any `L2_M` owner L1D (bringing dirty instructions/data into L2 and returning the coherent 512b line to L1I) without adding the L1I to `sharer_vec`.
  - **PTW**: `ptw_mem_req_*` (after `backend_sq_empty` and local `ptw_snoop_dirty_hit` check in `fursoy_s1_core.sv`) connects to a dedicated coherent read port on `fursoy_s2_coherence_mgr` (`COH_GETS_NC`), returning the requested 64-bit PTE slice from L2 or the remote `M`-owner L1D.

---

## 3. RV64A Multi-Hart Atomics (`LR`/`SC`, `AMO`) & Memory Ordering (`RVWMO` / `FENCE`)

### 3.1 `LR`/`SC` Reservation Sets, Coherence-Point Atomicity & IRQ Safety
In `rtl/core/fursoy_s1_lsu_queues.sv`, per-hart reservation registers `res_valid_q`, `res_pa_q`, and `res_size_q` require three SMP rules when `SMP_COHERENCE_EN = 1`:
1. **Remote Snoop Invalidation & Same-Cycle `LR` Priority**:
   - Whenever `snoop_req_valid_i && snoop_req_ready_o && snoop_do_inv` targets `snoop_line_addr == res_pa_q[55:6]`, immediately clear `res_valid_q <= 1'b0` (`SNOOP_GETS` leaves `res_valid_q` intact).
   - If a matching `snoop_do_inv` occurs on the **same cycle** an `LR` completes on Port 2/Port 3 (`fursoy_s1_lsu_queues.sv#L1987-L2010`), the snoop invalidation takes strict priority (`res_valid_q <= 1'b0`).
2. **Coherence-Point `sc_acquire_req` Handshake & IRQ Masking**:
   - In Slice-1 (`fursoy_s1_lsu_queues.sv#L1193-L1206`), `SC` evaluated `sc_ok_val` at completion and drained later via `l1d_store_drain_valid_o` (`#L869-L872`, `#L1973-L1977`). Under SMP, `SC` must validate and commit **atomically at the coherence point**:
   - Gate `sc_acquire_req` off if `csr_irq_pending_valid` is asserted; conversely, suppress `irq_candidate_valid` in `fursoy_s1_csr.sv` while `sc_acquire_inflight` is active so an asynchronous interrupt can never flush an in-flight `SC` after it mutates L1D.
   - When `SC` reaches `rob_head_i` and `sq_drain_head_q`, if `!(res_valid_q && res_pa_q == pa && res_size_q == size)`, `SC` fails immediately (`rd = 1`, no bus traffic).
   - Otherwise, `lsu_queues` asserts `sc_acquire_req` (with `pa`, `mask`, `data`) to `fursoy_s1_l1d`:
     - **Case A (`E` or `M` hit in L1D)**: Gate `snoop_req_ready_o = 1'b0` on the cycle `sc_acquire_req` Case A fires into `L1D` (inhibited if a matching snoop is already in `S0`/`S1`) so `S0` snoop acceptance and the atomic `SC` write can never occur simultaneously. `L1D` atomically writes `SC` data into `bank_data` (`coh_state <= MESI_M`, `dirty_array <= 1`), clears `res_valid_q`, and pulses `sc_acquire_done (ok = 1)`. `lsu_queues` **sets `sq_q[s].drained <= 1'b1` and `sc_success <= 1'b1`** so `SC` is never drained a second time via `l1d_store_drain_valid_o`, and commits `rd = 0`.
     - **Case B (`I` or `S` in L1D)**: `L1D` issues `COH_GETM` / `COH_UPGRADE` while `SC` waits at `rob_head_i`. If a remote `SNOOP_INV`/`SNOOP_GETM` arrives during the refill/upgrade, `res_valid_q` clears; as soon as `res_valid_q == 0` (or when `GetM` returns with `res_valid_q == 0`), `L1D`/`lsu_queues` aborts the store write and returns `sc_acquire_done (ok = 0)` → `SC` commits `rd = 1`.
3. **Livelock & Forward-Progress Guarantee**:
   - `LR` always requests `COH_GETS` (never `COH_GETM`), preventing spinning `LR` loops from stealing write ownership.
   - `fursoy_s2_coherence_mgr` arbitrates harts with strict rotating round-robin fairness.
   - A per-hart consecutive-`SC`-failure counter (`sc_fail_streak_q[3:0]`) triggers a bounded LFSR backoff (`4 .. 15` cycles before re-issuing `LR` or `SC` miss after `>= 4` consecutive failures) to break symmetric dual/quad-hart ping-pong.

### 3.2 2-Cycle L1D Line-Locked `AMO` Execution
In `fursoy_s1_lsu_queues.sv` (`amo_state_q`: `AMO_IDLE → AMO_WAIT_REFILL → AMO_READY_COMP`), `AMO` already serializes at `sq_drain_head_q == s`, `rob_idx == rob_head_i`, and `l1d_quiescent_i`. For `SMP_COHERENCE_EN = 1`:
1. **IRQ & Same-Cycle Snoop Inhibit**: Mask `amo_cand_ready` when `csr_irq_pending_valid` is asserted or when a matching snoop is in `S0`/`S1`; **gate `snoop_req_ready_o = 1'b0` on the cycle `amo_cand_ready` fires into `L1D`** so `S0` snoop acceptance and `amo_line_lock_q` assertion can never occur simultaneously on the same cycle. Suppress `irq_candidate_valid` in `fursoy_s1_csr.sv` whenever `amo_line_lock_q || (amo_state_q != AMO_IDLE)`, and clear `amo_line_lock_q <= 1'b0` unconditionally on `flush_valid_i`.
2. **Ownership Acquire (`COH_GETM` / `COH_UPGRADE`)**: `amo_cand_ready` drives `load0_req_is_amo_o = 1'b1` to `fursoy_s1_l1d`, which requires `coh_state inside {MESI_E, MESI_M}`. If `I` or `S`, `L1D` allocates an MSHR and stalls `AMO` in `AMO_WAIT_REFILL`. If `mshr_snoop_invalid_q` was set on the `AMO` refill before Beat 1 (early pre-grant snoop), `AMO` **must not** latch `mshr_refill_data_i`—it automatically re-issues `COH_GETM` until an un-invalidated `E`/`M` ownership refill completes.
3. **2-Cycle Lock & Atomic Writeback**: Once `L1D` holds `E`/`M` and delivers `amo_old_val`, `L1D` asserts `amo_line_lock_q <= 1'b1`. While `amo_line_lock_q == 1` (strictly **2 cycles**: Cycle 1 `compute_amo_new_val()`, Cycle 2 `store_can_drain` writes `new_val` into `bank_data` + `MESI_M` + clears `amo_line_lock_q <= 0`), **`snoop_req_ready_o` stalls ALL incoming snoops (`1'b0`)** (not just address-matching snoops, guaranteeing no unrelated dirty snoop can claim `bank_data` and delay `store_can_drain`). Because the line is already owned in `E`/`M` and no external bus wait can occur while locked, `amo_line_lock_q` cannot deadlock.

### 3.3 `RVWMO`, `FENCE` Global Quiescence, `CLEAN_SWEEP` Bypass & Cross-Hart Shootdown
- **Speculative OoO Load Snooping**: `fursoy_s1_lsu_queues.sv#L420-L435` (`snoop_lq_match`) remains enabled for `SMP_COHERENCE_EN = 1` (checking both `S0` snoops and `S0`/`S1` completing loads, §2.2).
- **`FENCE` (`MEM_FENCE`) Global Quiescence**: Extend `l1d_quiescent_o` in `fursoy_s1_l1d.sv` (when `SMP_COHERENCE_EN = 1`) to also require `put_ack_pending_cnt_q == 0` (all `PutM` writebacks acknowledged by `PutAck`) and zero active upgrade MSHRs before `MEM_FENCE` retires.
- **Bypass L1D `CLEAN_SWEEP` on `FENCE.I` / `SFENCE.VMA`**: When `SMP_COHERENCE_EN = 1`, `dcache_clean_all_req_i` skips `CLEAN_SWEEP` over `dirty_array` (`fursoy_s1_l1d.sv#L1403-L1437`) and transitions `CLEAN_IDLE → CLEAN_DRAIN → CLEAN_DONE`. Because `L1I` and `PTW` are hardware-coherent via `fursoy_s2_coherence_mgr`, bypassing `CLEAN_SWEEP` prevents clearing `dirty_array` while leaving `valid_array = 1` (`MESI_M` vs. L2 directory desync) and makes `FENCE.I`/`SFENCE.VMA` latency deterministic once `SQ`/`WBB` drain.
- **L1I In-Flight Refill Epoch (`imshr_epoch_q`)**: In `fursoy_s1_l1i.sv#L437-L445`, `l1i_inval_all_i` clears `imshr_q[0..1].valid <= 1'b0`. To prevent a stale pre-`FENCE.I` `l1i_bus_rd_rsp_valid_i` from colliding with a new miss reusing `imshr_q[0..1]`, track a per-slot 2-bit `imshr_epoch_q` (or `l1i_inval_discard_cnt_q` per tag) appended to `l1i_bus_rd_req_tag_o` (extended in `fursoy_s2_coherence_mgr`) so mismatched responses from pre-`FENCE.I` requests are silently dropped.
- **Cross-Hart `SFENCE.VMA` & `FENCE.I` Shootdown (`SBI RFENCE`)**:
  - Software invokes `SBI RFENCE` (`EID 0x52464E43`: `REMOTE_FENCE_I`, `REMOTE_SFENCE_VMA`, `REMOTE_SFENCE_VMA_ASID`).
  - The initiator writes per-target-hart shootdown descriptors in M-mode SBI RAM (`0x8000_0000 .. 0x801F_FFFF`), executes `fence rw, w`, sets `CLINT msip[h] = 1` for each target hart, and waits on an atomic ack counter (`amoadd.d`).
  - **Simultaneous-`RFENCE` Deadlock Prevention**: Because M-mode ECALL handlers execute with `mstatus.MIE == 0`, if two harts invoke `SBI RFENCE` simultaneously, spinning blindly on the ack counter would deadlock. Therefore, the `SBI RFENCE` wait loop **must poll `mip.MSIP`** and service any incoming `REMOTE_SFENCE_VMA` / `REMOTE_FENCE_I` / `SSIP` work from its local mailbox while waiting, clearing `msip[mhartid]` and updating `ipi_reason` atomically via `amoadd`/`amoand`.

---

## 4. SMP Platform Peripherals, SBI Firmware & Parameterized DTB

### 4.1 `fursoy_s2_clint` (`BASE_ADDR = 64'h0000_0000_0200_0000`)
Parameterized generalization of `rtl/platform/fursoy_s0_clint.sv` (`parameter int unsigned NUM_HARTS = 2`):

| Offset Range | Width | Access | Reset | Semantics |
| :--- | :--- | :--- | :--- | :--- |
| `0x0000 + 4*h` (`h < NUM_HARTS`) | 32-bit | RW | `0` | `msip[h]`: bit `0` drives `irq_software_o[h]` |
| `0x4000 + 8*h` (`h < NUM_HARTS`) | 64-bit | RW | `64'hFFFF_FFFF_FFFF_FFFF` | `mtimecmp[h]`: `mtime_q >= mtimecmp_q[h]` drives registered `irq_timer_q[h]` |
| `0xBFF8` | 64-bit | RW | `64'd0` | Shared 64-bit `mtime_q` (increments +1/cycle), exported on `mtime_o` |

- **32-bit Lane Steering for `msip[h]`**: Unlike `fursoy_s0_clint` (which only had `msip[0]` at `addr[2] == 0`), odd harts (`h = 1, 3`) place `msip[h]` at `addr[2] == 1`. `fursoy_s2_mmio_xbar` / `fursoy_s2_clint` must steer 32-bit `msip[h]` writes (`req_size_i == 3'd2`) using `req_addr_i[2] ? req_store_data_i[63:32] : req_store_data_i[31:0]` and replicate the 32-bit `msip[h]` read response across `{rsp_word, rsp_word}` (matching `fursoy_s1_soc.sv#L377, L390`). Misaligned or wrong-size accesses assert `access_error_o` and `rsp_error_o`.

### 4.2 `fursoy_s2_plic` (`BASE_ADDR = 64'h0000_0000_0C00_0000`)
Parameterized generalization of `rtl/platform/fursoy_s0_plic.sv` (`NUM_HARTS = 2` default, `NUM_CONTEXTS = 2 * NUM_HARTS`, `31` physical sources `1..31`, UART on source `1`):
- **Context mapping**: Context `2*h` = Hart `h` M-mode (`irq_meip_o[h]`); Context `2*h + 1` = Hart `h` S-mode (`irq_seip_o[h]`).
- **Register map** (strict 32-bit aligned MMIO, lane-steered via `mmio_wdata_32` and `{rsp_data_q, rsp_data_q}`):
  - Source priority `1..31`: `BASE_ADDR + 24'h000004 .. 24'h00007C` (`priority_q[1..31]`, 3-bit)
  - Pending bitmap `[31:1]`: `BASE_ADDR + 24'h001000` (RO)
  - Context `c` enable `[31:1]`: `BASE_ADDR + 24'h002000 + c * 24'h000080` (`enable_q[c][31:1]`)
  - Context `c` threshold: `BASE_ADDR + 24'h200000 + c * 24'h001000` (`threshold_q[c]`, 3-bit)
  - Context `c` claim/complete: `BASE_ADDR + 24'h200004 + c * 24'h001000`
- **Unified Registered Response & Claim Consistency**: Unify `rsp_valid_q` / `rsp_error_q` across **both loads and stores** (unlike `fursoy_s0_plic.sv#L261-L267` which registered loads only). On a valid Claim read (`claim_c_fire`), consume the exact registered `claim_selected_id_q[c]` latched into `rsp_data_q` to transition `pending_q[k] <= 1'b0`, `in_service_q[k] <= 1'b1`. Because `fursoy_s2_mmio_xbar` serializes MMIO requests, at most one hart claims a given source; completion requires `enable_q[c][k] && in_service_q[k]`.

### 4.3 Shared `UART`, SBI Firmware (`fursoy_s2_sbi_*`) & Multi-Hart DTB / Linux Config
- **UART**: Retain `rtl/platform/fursoy_s0_uart.sv` (`0x1000_0000`), shared across harts behind `fursoy_s2_mmio_xbar` (round-robin fairness).
- **SMP SBI Firmware (`software/firmware/fursoy_s2_sbi_*`)**: Extends `fursoy_s1_sbi_*` inside the existing 2 MiB `0x8000_0000 .. 0x801F_FFFF` reserved region (`fursoy_s1_sbi_link.ld`):
  - **Per-hart M-mode stacks**: `sp = __stack_top - (mhartid * 4096)` stored in `mscratch`.
  - **Secondary hart boot (`SBI HSM`, `EID 0x48534D`)**: `hart_start` (`FID 0`), `hart_stop` (`FID 1`), `hart_get_status` (`FID 2`). Hart `0` boots Linux (`0x8020_0000`, `a0 = 0`, `a1 = 0x8200_0000`); Harts `1..N-1` sleep in `wfi` with `mie.MSIE = 1` until `hart_start` writes the per-hart entry/opaque record and triggers `msip[hartid] = 1`.
  - **IPI & Timer (`SBI sPI`, `EID 0x735049`; `SBI TIME`, `EID 0x54494D45`)**: `send_ipi` atomically sets `IPI_REASON_SSIP` via `amoor.w` and writes `msip[h] = 1`; target M-mode converts it into `mip.SSIP` (bit `1`). `SBI TIME` programs `0x0200_4000 + 8 * mhartid`.
  - **Remote Fence (`SBI RFENCE`, `EID 0x52464E43`)**: `remote_fence_i` (`FID 0`), `remote_sfence_vma` (`FID 1`), `remote_sfence_vma_asid` (`FID 2`) with `mip.MSIP` re-entrant wait loop (§3.3).
  - **Shutdown (`SBI SRST`, `EID 0x53525354`)**: Broadcasts halt IPI to all harts before entering `halt_loop`.
  - *OpenSBI `fw_jump` compatibility note*: If upstream OpenSBI is optionally targeted, expose `RV64IMAFDV` in `misa` (`12'h301`) and minimal WARL `pmpcfg0`/`pmpaddr0` CSRs in `fursoy_s1_csr.sv` (currently `12'h301` reads `64'd0` and PMP CSRs trap as unimplemented).
- **Parameterized DTB Generator (`tools/gen_s2_dts.py`)**:
  - Emits `/cpus/cpu@0 .. cpu@(N-1)` with `reg = <h>`, `riscv,isa = "rv64imafdv_zba_zbb_zicsr_zifencei"`, `mmu-type = "riscv,sv39"`, and `cpu<h>_intc: interrupt-controller`.
  - Populates `clint@2000000` `interrupts-extended` (`<&cpu<h>_intc 3 &cpu<h>_intc 7>`) and `interrupt-controller@c000000` `interrupts-extended` (`<&cpu<h>_intc 11 &cpu<h>_intc 9>`) for `h = 0 .. N-1`.
- **Linux Kernel Configuration (`software/linux/fursoy_s2_defconfig`)**: Derived from `software/linux/fursoy_s0_defconfig`, enabling `CONFIG_SMP=y` and `CONFIG_NR_CPUS=4`.

---

## 5. 500 MHz (`2.0 ns`) Nangate 45nm Timing Closure Strategy

Using the `tools/run_s1_synth.py` flow (`sv2v -DSYNTHESIS` → Yosys → `abc -D 1000 -constr tools/synth/abc.constr` → OpenSTA at `period = 2.000 ns`, `input/output_delay = 0.2 ns`), Slice-2 pipelines six critical boundaries:

| Block / Path | Critical Path Risk at `500 MHz` | Required Architectural / Pipeline Solution |
| :--- | :--- | :--- |
| **`fursoy_s1_l1d` Snoop Path** | Current Slice-1 snoop (`fursoy_s1_l1d.sv#L554-L565`) runs tag CAM + WBB CAM + 8-bank 512b `read_cache_line` + output mux in `0` cycles. | When `SMP_COHERENCE_EN = 1`, split into a **2-stage registered snoop pipeline**: **Stage S0** latches `snoop_req_*` and evaluates `snoop_cache_hit` / `snoop_wbb_hit` / `snoop_mshr_hit`; **Stage S1** reads `bank_data` / `wbb_q` and registers `snoop_rsp_{valid,has_data,was_dirty,ack_only,data}_o`. |
| **`fursoy_s2_coherence_mgr`** | `4*N` skid buffers + `DIR_MSHR` hazard CAM + arbiter + Directory tag CAM + L2/snoop mux in 1 cycle exceeds `2.0 ns`. | Partition into **3 pipeline stages**: **C0** evaluates `DIR_MSHR` `line_addr`/`victim_addr` hazard eligibility **per-skid-buffer in parallel *before* the `4*N`-to-1 arbiter mux** → registers granted request; **C1** (Directory tag/sharer lookup → flop); **C2** (Snoop dispatch / L2 data mux / `VC2` Grant mux → flop). |
| **`fursoy_s2_plic` Priority Tree** | `fursoy_s0_plic.sv#L92-L106` uses a linear 31-source priority loop per context feeding `read_data_comb` on `req_fire`. At `2*N = 8` contexts (`N=4`), this exceeds `2.0 ns`. | Replace the linear loop with a **5-level balanced binary reduction tree** (`31 → 16 → 8 → 4 → 2 → 1` 3-bit priority+ID comparators), continuously register `claim_selected_id_q[c]`, and unify registered `rsp_valid_q` / `rsp_error_q` across loads and stores. |
| **`fursoy_s2_mmio_xbar`** | Combinational `NUM_HARTS` arbiter → address decode → slave priority tree / response mux across `NUM_HARTS` cores. | Register the `fursoy_s2_mmio_xbar` **output stage between the arbiter and slave buses** (and register the slave response mux back to the winning hart). |
| **`fursoy_s2_clint` Comparators** | `N` parallel 64-bit `mtime_q >= mtimecmp_q[h]` comparators driving boundary outputs `irq_timer_o[h]`. | Register `irq_timer_q[h] <= (mtime_q >= mtimecmp_q[h])` inside `fursoy_s2_clint`, isolating the 64-bit carry chain from the `0.2 ns` output-delay budget. |
| **`fursoy_s1_csr` `mhartid_i`** | Additional `12'hf14` mux input in `fursoy_s1_csr.sv`. | Static per-hart tie-off; re-verify `csr` gated STA in `run_s2_synth.py` (`WNS >= 0.0 ns`). |

Create `tools/run_s2_synth.py` gating all 8 Slice-1 gated blocks (`branch_unit`, `csr`, `dtlb`, `itlb`, `agu`, `ptw`, `decode`, `alu`) **plus** `fursoy_s2_clint`, `fursoy_s2_plic`, `fursoy_s2_mmio_xbar`, `fursoy_s2_coherence_mgr` (control/directory logic), and the pipelined L1D snoop controller.

---

## 6. Phased Implementation Roadmap (`S2-M1` .. `S2-M5`) & Verification Plan

### 6.1 Milestones (`S2-M1` .. `S2-M5`)

| Milestone | Scope & Deliverables | Exit / Acceptance Gate |
| :--- | :--- | :--- |
| **`S2-M1`** | `mhartid_i` in `fursoy_s1_core`/`csr`; `fursoy_s2_clint`, `fursoy_s2_plic`, `fursoy_s2_mmio_xbar`; initial non-coherent `fursoy_s2_soc` (`N=2, 4` with round-robin DRAM arbiter). | Verilator `-Wall` lint clean; all Slice-1 regressions (`s1-lint`, `s1-sail-cosim`, `s1-m9-closeout`) pass; 2-hart & 4-hart `mhartid` + CLINT MSIP/MTIP + PLIC multi-context tests pass. |
| **`S2-M2`** | MESI states + `COH_GETS`/`COH_GETM`/`COH_UPGRADE` MSHRs + 2-stage snoop pipeline + WBB draining fixes in `fursoy_s1_l1d.sv`; `fursoy_s2_coherence_mgr` + `fursoy_s2_l2`; coherent `L1I` + `PTW` routing; **Verilator C++ cycle-by-cycle SWMR coherence scoreboard**. | Directed coherence tests pass with `0` SWMR violations: `M→S`/`M→I` forwarding, `GrantM` dirty install, both `Upgrade`-vs-`Inv` races, WBB draining & `PutM` late-arrival races, coherent `PTW` & `L1I` refill. |
| **`S2-M3`** | Snoop invalidation of `res_valid_q`, coherence-point `sc_acquire_req` + IRQ interlocks, `LR`/`SC` backoff, 2-cycle L1D `amo_line_lock_q`, global `FENCE` quiescence, `CLEAN_SWEEP` bypass, `imshr_epoch_q`, and `fursoy_s2_sbi_*` (`HSM`, `sPI`, `RFENCE`, `TIME`, `SRST`). | Contended `LR`/`SC` & `AMO` tests, `FENCE` ordering, simultaneous `SBI RFENCE`, and cross-hart `SFENCE.VMA` / `FENCE.I` shootdown tests pass on `N=2` and `N=4` with `0` SWMR violations. |
| **`S2-M4`** | Full SMP Litmus Suite, randomized multi-hart coherence torture, and `tools/run_s2_synth.py` `500 MHz` Nangate45 STA closure. | `0` forbidden litmus outcomes across 10,000+ iterations/test; `0` SWMR violations; `WNS >= 0.0 ns` on all gated Slice-1 & Slice-2 blocks. |
| **`S2-M5`** | `tools/gen_s2_dts.py` (`N=2, 4`), `fursoy_s2_defconfig` (`CONFIG_SMP=y`, `CONFIG_NR_CPUS=4`), Linux 6.6.50 + BusyBox SMP boot & closeout runner. | Linux 6.6.50 boots cleanly on `N=2` and `N=4`; `/proc/cpuinfo` shows `N` online harts; multi-thread atomic + Sv39 demand-paging userspace stress passes; Slice-1 closeout remains green. |

### 6.2 SMP Litmus Suite, Stress Matrix & Coherence Scoreboard
- **Directed Litmus Suite (`N = 2` and `N = 4`, `>= 10,000` iterations per pattern with randomized DRAM latency & clock-phase jitter)**:
  - **`MP`** (Message Passing): Hart 0 stores payload + `fence rw, w` + flag; Hart 1 loads flag + `fence r, rw` + payload (`flag==1 && payload==0` count = `0`).
  - **`SB`** (Store Buffering): Hart 0 `st X=1; fence rw,rw; ld Y` vs. Hart 1 `st Y=1; fence rw,rw; ld X` (`r0==0 && r1==0` count = `0`; directly validates SQ drain + `LQ` `snoop_lq_match` replay).
  - **`LB`** (Load Buffering) & **`IRIW`** (Independent Reads of Independent Writes across 4 harts: validates MESI directory multi-copy atomicity).
  - **Same-Address Coherence (`CoRR`, `CoWR`, `CoRW`, `CoWW`)**: Enforces single-line total write order across speculative loads.
  - **`LR`/`SC` Ping-Pong & False-Sharing Torture**: 2 and 4 harts hammer shared and adjacent-word (same 64 B line) `lr.d`/`sc.d` loops with a bounded-progress watchdog verifying zero livelock and exact final sums.
  - **`AMO` Contention Torture**: All `N` harts execute concurrent `amoadd.{w,d}`, `amoswap`, `amomin/max`, and `amoand/or/xor` operations on shared lines.
  - **Cross-Hart `SFENCE.VMA` & `FENCE.I` Shootdown**: Hart 0 updates a shared Sv39 PTE (dirty in L1D) + calls `SBI RFENCE REMOTE_SFENCE_VMA` (including simultaneous two-hart `SBI RFENCE` stress); Hart 1 validates new mapping. Hart 0 patches code + `fence rw, w` + `SBI RFENCE REMOTE_FENCE_I`; Hart 1 executes patched instructions.
  - **Multi-Context PLIC & CLINT Stress**: Concurrent per-hart timer IRQs, `msip` IPI storms (including odd-hart `addr[2] == 1` `msip` lane steering), and multi-hart PLIC claim/complete races with zero double-claims or dropped IRQs.
- **Cycle-by-Cycle Verilator C++ SWMR Coherence Monitor (delivered in `S2-M2`)**:
  - Inspects `coh_state_array` and `wbb_q` across all `NUM_HARTS` L1Ds every cycle during `S2-M2..S2-M4` runs and asserts the **Single-Writer, Multiple-Reader (SWMR)** invariant: for every 64 B `line_addr`, at most one L1D holds `MESI_M` or `MESI_E` (with zero other harts in `MESI_S`/`E`/`M`), and every `MESI_S` copy matches the global architectural line image.
- **Non-Regression Gate**: Every Slice-2 milestone closes with a fresh pass of `tools/run_s1_lint.py`, `tools/run_s1_sail_cosim.py`, `s1_m7_tb` (`SMP_COHERENCE_EN = 0`), and `tools/run_s1_m9_closeout.py`.
