// =============================================================================
// Fursoy Slice-1 Milestone 9 Phase D Verification Testbench
// =============================================================================
// Standalone comprehensive C++ unit testbench covering properties:
// - PROP_M9_19: SBI Base extension probe and version discovery (EID 0x10);
// - PROP_M9_20: SBI TIME extension programming CLINT mtimecmp and asserting
// timer interrupts;
// - PROP_M9_21: SBI DBCN console write character streaming through UART;
// - PROP_M9_22: Precise S-mode handoff (mstatus.MPP=S, mepc=0x8020_0000, a0=0,
// a1=DTB);
// - PROP_M9_23: Device Tree blob integrity and memory/peripheral node parsing;
// - PROP_M9_24: Linux earlycon UART registration and early banner string
// emission;
// - PROP_M9_25: Mixed privilege exception arbitration between M-mode (SBI
// ecall) and S-mode (page fault / timer);
// - PROP_M9_26: Multi-seed randomized stress torture of firmware service
// routines across seeds 42, 20260920, and 20261009 with zero mismatches.
//
// Specification authority: docs/architecture/slice1-m9-soc-linux-v1.md v1.1 §6,
// §8.4
// =============================================================================

#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Vfursoy_s1_soc.h"
#include "Vfursoy_s1_soc___024root.h"
#include "verilated.h"

static constexpr uint64_t RAM_BASE = 0x80000000ULL;
static constexpr uint64_t RAM_SIZE = 256 * 1024 * 1024ULL; // 256 MiB DRAM
static constexpr uint64_t DTB_BASE = 0x82000000ULL;
static constexpr uint64_t SIG_ADDR = 0x80250000ULL;

static uint64_t get64(const std::vector<uint8_t> &b, size_t o) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++)
    v |= uint64_t(b[o + i]) << (8 * i);
  return v;
}
static uint32_t get32(const std::vector<uint8_t> &b, size_t o) {
  return uint32_t(get64(b, o) & 0xffffffff);
}
static uint16_t get16(const std::vector<uint8_t> &b, size_t o) {
  return uint16_t(b[o] | (uint16_t(b[o + 1]) << 8));
}

static size_t load_raw_bin(const char *path, std::vector<uint8_t> &ram,
                           uint64_t load_addr) {
  std::ifstream f(path, std::ios::binary);
  if (!f)
    throw std::runtime_error(std::string("Cannot open binary file: ") + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  if (load_addr < RAM_BASE || load_addr - RAM_BASE + b.size() > RAM_SIZE) {
    throw std::runtime_error(
        std::string("Binary placement outside RAM aperture: ") + path);
  }
  for (size_t i = 0; i < b.size(); i++) {
    ram[load_addr - RAM_BASE + i] = b[i];
  }
  return b.size();
}

static size_t load_elf(const char *path, std::vector<uint8_t> &ram) {
  std::ifstream f(path, std::ios::binary);
  if (!f)
    throw std::runtime_error(std::string("Cannot open ELF file: ") + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  if (b.size() < 64 || get32(b, 0) != 0x464c457f || b[4] != 2 || b[5] != 1 ||
      get16(b, 18) != 243) {
    throw std::runtime_error(std::string("Invalid RISC-V ELF64: ") + path);
  }
  uint64_t phoff = get64(b, 32);
  uint16_t entsz = get16(b, 54), count = get16(b, 56);
  size_t total_loaded = 0;
  for (unsigned i = 0; i < count; i++) {
    size_t o = phoff + i * entsz;
    if (o + 56 > b.size())
      throw std::runtime_error("Bad program header in ELF");
    if (get32(b, o) != 1)
      continue; // PT_LOAD segment
    uint64_t fileoff = get64(b, o + 8), addr = get64(b, o + 24);
    uint64_t filesz = get64(b, o + 32), memsz = get64(b, o + 40);
    if (addr < RAM_BASE || memsz > RAM_SIZE ||
        addr - RAM_BASE > RAM_SIZE - memsz || fileoff + filesz > b.size()) {
      throw std::runtime_error("Segment placed outside RAM bounds");
    }
    for (uint64_t j = 0; j < filesz; j++)
      ram[addr - RAM_BASE + j] = b[fileoff + j];
    total_loaded += filesz;
  }
  return total_loaded;
}

struct DRAMInFlight {
  uint64_t line_addr;
  uint8_t mid;
  uint8_t tag;
  uint64_t ready_cycle;
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 4) {
    std::cerr
        << "Usage: " << argv[0]
        << " <fw_elf> <payload_elf> <dtb_bin> [halt_loop_pc] [max_cycles]\n";
    return 1;
  }

  const char *fw_elf = argv[1];
  const char *payload_elf = argv[2];
  const char *dtb_bin = argv[3];
  uint64_t halt_loop_pc = (argc >= 5) ? std::stoull(argv[4], nullptr, 0) : 0ULL;
  uint64_t max_cycles =
      (argc >= 6) ? std::stoull(argv[5], nullptr, 0) : 500000ULL;

  try {
    std::vector<uint8_t> ram(RAM_SIZE, 0);

    // 1. Load Firmware ELF at 0x8000_0000
    size_t fw_sz = load_elf(fw_elf, ram);

    // 2. Load S-mode Payload ELF at 0x8020_0000
    size_t payload_sz = load_elf(payload_elf, ram);

    // 3. Load Canonical DTB binary at 0x8200_0000
    size_t dtb_sz = load_raw_bin(dtb_bin, ram, DTB_BASE);

    std::cerr << "[TB] Firmware loaded: " << fw_sz << " bytes\n"
              << "[TB] Payload loaded:  " << payload_sz << " bytes\n"
              << "[TB] DTB loaded:      " << dtb_sz << " bytes at 0x8200_0000\n"
              << "[TB] Max cycles:      " << max_cycles << "\n";

    Vfursoy_s1_soc dut;
    std::string uart_output;
    std::deque<DRAMInFlight> dram_rd_queue;
    std::vector<std::pair<uint64_t, int>> retire_trace;

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.frontend_en_i = 1; // Autonomous frontend instruction fetch active
    dut.irq_sources_i = 0;
    dut.irq_external_i = 0;

    dut.dram_req_ready_i = 1;
    dut.dram_rd_rsp_valid_i = 0;
    dut.dram_rd_rsp_mid_i = 0;
    dut.dram_rd_rsp_tag_i = 0;
    memset((void *)&dut.dram_rd_rsp_data_i, 0, sizeof(dut.dram_rd_rsp_data_i));
    dut.dram_rd_rsp_error_i = 0;
    dut.dram_wr_rsp_valid_i = 0;

    dut.test_csr_we_i = 0;
    dut.test_csr_addr_i = 0;
    dut.test_csr_wdata_i = 0;

    dut.uop0_valid_i = 0;
    dut.uop0_rs1_i = 0;
    dut.uop0_rs2_i = 0;
    dut.uop0_rd_i = 0;
    dut.uop0_class_i = 0;
    dut.uop0_subop_i = 0;
    dut.uop0_imm_i = 0;
    dut.uop0_use_imm_i = 0;
    dut.uop0_pc_i = 0;

    dut.uop1_valid_i = 0;
    dut.uop1_rs1_i = 0;
    dut.uop1_rs2_i = 0;
    dut.uop1_rd_i = 0;
    dut.uop1_class_i = 0;
    dut.uop1_subop_i = 0;
    dut.uop1_imm_i = 0;
    dut.uop1_use_imm_i = 0;
    dut.uop1_pc_i = 0;

    dut.probe_paddr_i = 0;
    dut.eval();

    // 10 reset cycles
    for (int r = 0; r < 10; r++) {
      dut.clk_i = 1;
      dut.eval();
      dut.clk_i = 0;
      dut.eval();
    }
    dut.rst_i = 0;

    uint64_t cycles = 0;
    uint64_t commits = 0;
    uint64_t last_commit_cycle = 0;
    bool seen_reset_pc = false;
    bool seen_handoff_pc = false;
    bool halted = false;
    int halt_streak = 0;
    uint64_t last_retire_pc = 0;
    int last_priv = 0;

    auto read_mem_cached = [&](uint64_t addr, unsigned size) -> uint64_t {
      uint32_t set = (addr >> 6) & 0x3f;
      uint64_t tag = addr >> 12;

      // Check L1D cache banks
      for (int w = 0; w < 4; w++) {
        if (dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array[set][w] &&
            (dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array[set][w] == tag)) {
          int byte_in_line = addr & 0x3f;
          int bank = (byte_in_line >> 3) & 7;
          uint64_t dword = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data[bank][set][w];
          unsigned shift = (addr & 7) * 8;
          unsigned bytes = 1 << size;
          uint64_t mask = (bytes == 8) ? ~0ULL : ((1ULL << (bytes * 8)) - 1ULL);
          return (dword >> shift) & mask;
        }
      }

      // Fallback to DRAM
      size_t o = addr - RAM_BASE;
      uint64_t v = 0;
      unsigned bytes = 1 << size;
      for (unsigned b = 0; b < bytes; b++) {
        if (o + b < ram.size()) v |= uint64_t(ram[o + b]) << (8 * b);
      }
      return v;
    };

    while (cycles < max_cycles && !halted) {
      dut.clk_i = 0;
      dut.eval();

      // Observe DRAM request
      if (dut.dram_req_valid_o && dut.dram_req_ready_i) {
        uint64_t line_addr = dut.dram_req_addr_o;
        uint64_t byte_addr = line_addr << 6;

        if (dut.dram_req_write_o) {
          // DRAM Writeback
          if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
            uint32_t *src = (uint32_t *)&dut.dram_req_wdata_o;
            memcpy(&ram[byte_addr - RAM_BASE], src, 64);
          }
          dut.dram_wr_rsp_valid_i = 1;
        } else {
          // DRAM Read (L1I refill, L1D refill, PTW walk)
          DRAMInFlight req;
          req.line_addr = line_addr;
          req.mid = dut.dram_req_mid_o;
          req.tag = dut.dram_req_tag_o;
          req.ready_cycle = cycles + 1; // 1-cycle DRAM read latency
          dram_rd_queue.push_back(req);
        }
      } else {
        dut.dram_wr_rsp_valid_i = 0;
      }

      // Deliver DRAM Read response
      if (!dram_rd_queue.empty() &&
          dram_rd_queue.front().ready_cycle <= cycles) {
        DRAMInFlight rsp = dram_rd_queue.front();
        dram_rd_queue.pop_front();
        dut.dram_rd_rsp_valid_i = 1;
        dut.dram_rd_rsp_mid_i = rsp.mid;
        dut.dram_rd_rsp_tag_i = rsp.tag;
        dut.dram_rd_rsp_error_i = 0;

        uint64_t rsp_byte_addr = rsp.line_addr << 6;
        uint32_t *dst = (uint32_t *)&dut.dram_rd_rsp_data_i;
        if (rsp_byte_addr >= RAM_BASE &&
            rsp_byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
          memcpy(dst, &ram[rsp_byte_addr - RAM_BASE], 64);
        } else {
          memset(dst, 0, 64);
          dut.dram_rd_rsp_error_i = 1;
        }
      } else {
        dut.dram_rd_rsp_valid_i = 0;
      }

      auto check_sym = [&](uint64_t pc) {
        if (pc == 0x80200000ULL) {
          seen_handoff_pc = true;
        }
        if (pc == 0x80200f00ULL || pc == 0x80200210ULL || pc == 0x8020032cULL || pc == 0x80200bf0ULL) {
          int s_ra = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[1];
          int a_ra = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__arat_q[1];
          uint64_t s_val = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[s_ra];
          uint64_t a_val = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[a_ra];
          std::cerr << "[RA TRACE at cycle " << cycles << "] pc=0x" << std::hex << pc
                    << " srat_ra=p" << std::dec << s_ra << "(0x" << std::hex << s_val << ")"
                    << " arat_ra=p" << std::dec << a_ra << "(0x" << std::hex << a_val << ")"
                    << std::dec << "\n";
        }
        if (pc == 0x802000b8ULL) {
          static int trap_count = 0;
          trap_count++;
          if (trap_count <= 20) {
            std::cerr << "[S_TRAP ENTER #" << trap_count << " at cycle " << cycles << "] pc=0x" << std::hex << pc
                      << " scause=0x" << dut.csr_scause_o
                      << " sepc=0x" << dut.csr_sepc_o
                      << " stval=0x" << dut.csr_stval_o
                      << " mcause=0x" << dut.csr_mcause_o
                      << " mepc=0x" << dut.csr_mepc_o
                      << std::dec << "\n";
          }
        }
        if (pc == 0x80200228ULL || pc == 0x80000168ULL || pc == 0x8020032cULL || pc == 0x80200f04ULL || pc == 0x80200db8ULL) {
          int a0_p = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[10];
          int a1_p = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[11];
          int a2_p = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[12];
          int a6_p = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[16];
          int a7_p = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[17];
          uint64_t v_a0 = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[a0_p];
          uint64_t v_a1 = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[a1_p];
          uint64_t v_a2 = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[a2_p];
          uint64_t v_a6 = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[a6_p];
          uint64_t v_a7 = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_prf__DOT__mem_q[a7_p];
          std::cerr << "[SBI CALL TRACE at cycle " << cycles << "] pc=0x" << std::hex << pc
                    << " priv=" << (int)dut.csr_priv_mode_o
                    << " a0=0x" << v_a0 << " a1=0x" << v_a1
                    << " a2=0x" << v_a2 << " a6=0x" << v_a6 << " a7=0x" << v_a7
                    << std::dec << "\n";
        }
        if (cycles >= 17440 && cycles <= 17800) {
          std::cerr << "[CYCLE " << cycles << "] pc=0x" << std::hex << pc
                    << " priv=" << (int)dut.csr_priv_mode_o << std::dec << "\n";
        }
        if (pc >= 0x80000460ULL && pc <= 0x800004a0ULL) {
          static bool seen_panic = false;
          if (!seen_panic) {
            seen_panic = true;
            std::cerr << "[PANIC DETECTED at cycle " << cycles << "] pc=0x" << std::hex << pc
                      << " mcause=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_csr__DOT__mcause_q
                      << " mepc=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_csr__DOT__mepc_q
                      << " mstatus=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_csr__DOT__mstatus_q
                      << " mip_q=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_csr__DOT__mip_q
                      << " mie=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_csr__DOT__mie_q
                      << std::dec << "\n";
          }
        }
      };

      if (dut.retire_valid_o & 1) {
        commits++;
        last_commit_cycle = cycles;
        uint64_t pc0 = dut.retire_pc_o[0];
        if (pc0 == 0x80000000ULL) seen_reset_pc = true;
        check_sym(pc0);
        last_retire_pc = pc0;
        last_priv = (int)dut.csr_priv_mode_o;
        if (halt_loop_pc != 0 && pc0 >= halt_loop_pc && pc0 <= halt_loop_pc + 0x10) {
          halt_streak++;
          if (halt_streak >= 5) halted = true;
        }
        retire_trace.push_back({last_retire_pc, last_priv});
        if (retire_trace.size() > 256) retire_trace.erase(retire_trace.begin());
      }
      if (dut.retire_valid_o & 2) {
        commits++;
        last_commit_cycle = cycles;
        uint64_t pc1 = dut.retire_pc_o[1];
        if (pc1 == 0x80000000ULL) seen_reset_pc = true;
        check_sym(pc1);
        last_retire_pc = pc1;
        last_priv = (int)dut.csr_priv_mode_o;
        if (halt_loop_pc != 0 && pc1 >= halt_loop_pc && pc1 <= halt_loop_pc + 0x10) {
          halt_streak++;
          if (halt_streak >= 5) halted = true;
        }
        retire_trace.push_back({last_retire_pc, last_priv});
        if (retire_trace.size() > 256) retire_trace.erase(retire_trace.begin());
      }

      // Also check WFI sleep state
      if (dut.wfi_sleep_o) {
        halt_streak++;
        if (halt_streak >= 20)
          halted = true;
      }

      dut.clk_i = 1;
      dut.eval();

      if (cycles >= 17440 && cycles <= 17475) {
        std::cerr << "[CYCLE " << cycles << "] f0_pc=0x" << std::hex
                  << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_frontend__DOT__f0_pc_q
                  << " rob_head=" << std::dec
                  << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__head_q
                  << " rob_tail="
                  << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__tail_q
                  << " recovering="
                  << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__recovering_q
                  << " ret_exc="
                  << (int)dut.retire_exception_o
                  << " exc_cause=" << (int)dut.retire_exc_cause_o
                  << " exc_pc=0x" << std::hex
                  << dut.retire_exc_pc_o
                  << " ret0_pc=0x"
                  << dut.retire_pc_o[0]
                  << " ret_v=" << (int)dut.retire_valid_o
                  << std::dec << "\n";
      }



      // Observe UART TX emit immediately following rising edge
      if (dut.uart_tx_valid_o) {
        char c = (char)dut.uart_tx_data_o;
        uart_output += c;
      }

      // Stall Watchdog: if no commits for 5000 cycles after reset
      if (cycles > 500 && (cycles - last_commit_cycle > 5000)) {
        std::cerr << "[TB WATCHDOG] Simulation stalled at cycle=" << cycles
                  << " commits=" << commits << " last_pc=0x" << std::hex << last_retire_pc
                  << " s_last_cause=0x" << read_mem_cached(0x80201ee0, 3)
                  << " s_last_epc=0x" << read_mem_cached(0x80201ed8, 3)
                  << " s_last_tval=0x" << read_mem_cached(0x80201ed0, 3)
                  << " dtb_magic=0x" << read_mem_cached(0x82000000, 2)
                  << " dtb_totalsize=0x" << read_mem_cached(0x82000004, 2)
                  << " dtb_off_struct=0x" << read_mem_cached(0x82000008, 2)
                  << " dtb_off_strings=0x" << read_mem_cached(0x8200000c, 2)
                  << std::dec << "\n";
        break;
      }

      cycles++;
    }

    // =====================================================================
    // Post-Simulation Signature & Property Analysis (via Cached L1D/RAM)
    // =====================================================================

    uint32_t sig_magic = (uint32_t)read_mem_cached(SIG_ADDR + 0, 2);
    uint32_t sig_pass = (uint32_t)read_mem_cached(SIG_ADDR + 4, 2);
    uint32_t sig_fail = (uint32_t)read_mem_cached(SIG_ADDR + 8, 2);
    uint32_t p_m9_19 = (uint32_t)read_mem_cached(SIG_ADDR + 12, 2);
    uint32_t p_m9_20 = (uint32_t)read_mem_cached(SIG_ADDR + 16, 2);
    uint32_t p_m9_21 = (uint32_t)read_mem_cached(SIG_ADDR + 20, 2);
    uint32_t p_m9_22 = (uint32_t)read_mem_cached(SIG_ADDR + 24, 2);
    uint32_t p_m9_23 = (uint32_t)read_mem_cached(SIG_ADDR + 28, 2);
    uint32_t p_m9_24 = (uint32_t)read_mem_cached(SIG_ADDR + 32, 2);
    uint32_t p_m9_25 = (uint32_t)read_mem_cached(SIG_ADDR + 36, 2);
    uint32_t p_m9_26 = (uint32_t)read_mem_cached(SIG_ADDR + 40, 2);
    uint32_t seeds_ok = (uint32_t)read_mem_cached(SIG_ADDR + 44, 2);
    uint32_t events_done = (uint32_t)read_mem_cached(SIG_ADDR + 48, 2);
    uint32_t p19_err = (uint32_t)read_mem_cached(SIG_ADDR + 52, 2);
    uint32_t p19_val = (uint32_t)read_mem_cached(SIG_ADDR + 56, 2);
    uint64_t cap_hart = read_mem_cached(SIG_ADDR + 64, 3);
    uint64_t cap_dtb = read_mem_cached(SIG_ADDR + 72, 3);
    uint64_t cap_satp = read_mem_cached(SIG_ADDR + 80, 3);
    uint64_t cap_sstatus = read_mem_cached(SIG_ADDR + 88, 3);
    uint64_t cap_sie = read_mem_cached(SIG_ADDR + 96, 3);
    uint64_t cap_hygiene = read_mem_cached(SIG_ADDR + 104, 3);

    std::cerr << "[TB SIGNATURE DUMP]:\n";
    for (int i = 0; i < 20; i++) {
      uint32_t val = (uint32_t)read_mem_cached(SIG_ADDR + i * 4, 2);
      uint32_t dram_val = 0;
      size_t o = SIG_ADDR + i * 4 - RAM_BASE;
      if (o + 4 <= ram.size()) {
        memcpy(&dram_val, &ram[o], 4);
      }
      std::cerr << "  sig[" << i * 4 << " / 0x" << std::hex << (i * 4) << std::dec
                << "]: cached=0x" << std::hex << val << " dram=0x" << dram_val << std::dec << "\n";
    }
    std::cerr << " [S TRAP STATE]: traps=" << read_mem_cached(0x80201eb0, 3)
              << " cause=0x" << std::hex << read_mem_cached(0x80201ea8, 3)
              << " epc=0x" << read_mem_cached(0x80201ea0, 3)
              << " tval=0x" << read_mem_cached(0x80201e98, 3)
              << " timer_ticks=" << std::dec << read_mem_cached(0x80201e90, 3) << "\n";

    bool prop_19_ok = (p_m9_19 == 1) && seen_reset_pc;
    bool prop_20_ok = (p_m9_20 == 1);
    bool prop_21_ok =
        (p_m9_21 == 1) && (uart_output.find("[SBI_DBCN]") != std::string::npos);
    bool prop_22_ok = (p_m9_22 == 1) && seen_handoff_pc;
    bool prop_23_ok = (p_m9_23 == 1);
    bool prop_24_ok =
        (p_m9_24 == 1) &&
        (uart_output.find("Linux version 6.6.50") != std::string::npos) &&
        (uart_output.find("earlycon: uart8250 at MMIO32 0x0000000010000000") !=
         std::string::npos);
    bool prop_25_ok = (p_m9_25 == 1);
    bool prop_26_ok = (p_m9_26 == 1) && (seeds_ok == 3) && (events_done >= 150);

    int total_props_passed = (prop_19_ok ? 1 : 0) + (prop_20_ok ? 1 : 0) +
                             (prop_21_ok ? 1 : 0) + (prop_22_ok ? 1 : 0) +
                             (prop_23_ok ? 1 : 0) + (prop_24_ok ? 1 : 0) +
                             (prop_25_ok ? 1 : 0) + (prop_26_ok ? 1 : 0);

    bool all_passed = (total_props_passed == 8) && (sig_magic == 0x53424931) &&
                      (sig_fail == 0);

    if (!all_passed) {
      std::cerr << "[TB DEBUG] sig_magic=0x" << std::hex << sig_magic
                << " pass=" << std::dec << sig_pass << " fail=" << sig_fail
                << " p19=" << p_m9_19 << " p20=" << p_m9_20 << " p21=" << p_m9_21
                << " p22=" << p_m9_22 << " p23=" << p_m9_23 << " p24=" << p_m9_24
                << " p25=" << p_m9_25 << " p26=" << p_m9_26
                << " seeds_ok=" << seeds_ok << " events=" << events_done
                << " p19_err=" << p19_err << " p19_val=0x" << std::hex << p19_val << std::dec
                << " cap_hart=0x" << std::hex << cap_hart
                << " cap_dtb=0x" << cap_dtb
                << " cap_satp=0x" << cap_satp
                << " cap_sstatus=0x" << cap_sstatus
                << " cap_sie=0x" << cap_sie
                << " cap_hygiene=0x" << cap_hygiene << std::dec
                << " uart_len=" << uart_output.size() << "\n";
      std::cerr << " [UART OUTPUT]:\n" << uart_output << "\n";
      std::cerr << " [UART OUTPUT (first 256 raw hex)]:\n";
      for (size_t i = 0; i < uart_output.size() && i < 256; i++) {
        fprintf(stderr, "%02x ", (uint8_t)uart_output[i]);
        if ((i + 1) % 16 == 0) fprintf(stderr, "\n");
      }
      fprintf(stderr, "\n");
      std::cerr << " [UART OUTPUT (last 256 raw hex)]:\n";
      size_t start_last = (uart_output.size() > 256) ? (uart_output.size() - 256) : 0;
      for (size_t i = start_last; i < uart_output.size(); i++) {
        fprintf(stderr, "%02x ", (uint8_t)uart_output[i]);
        if ((i - start_last + 1) % 16 == 0) fprintf(stderr, "\n");
      }
      fprintf(stderr, "\n");
      std::cerr << " last_pc=0x" << std::hex << last_retire_pc << " last_priv="
                << std::dec << last_priv << " mcause=0x" << std::hex
                << dut.csr_mcause_o << " mepc=0x" << dut.csr_mepc_o
                << " mtval=0x" << dut.csr_mtval_o << " mstatus=0x"
                << dut.csr_mstatus_o << std::dec << "\n";
      std::cerr << " [RETIRE TRACE (last " << retire_trace.size() << ")]:\n";
      for (size_t t = 0; t < retire_trace.size(); t++) {
        std::cerr << "  #" << t << ": pc=0x" << std::hex << retire_trace[t].first
                  << " priv=" << std::dec << retire_trace[t].second << "\n";
      }
      std::cerr << "[TB ROB DEBUG] rob_count="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__count_q
                << " rob_head="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__head_q
                << " rob_tail="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__tail_q
                << " recovering="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__recovering_q
                << " target_tail="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__target_tail_q
                << " head_pc=0x" << std::hex << dut.retire_pc_o[0] << std::dec
                << " can_retire="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__uop0_can_retire
                << " retire_grant="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__retire_grant
                << " lsu_retire0_allow="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__lsu_retire0_allow
                << " head0_lq_found="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__head0_lq_found
                << " head0_lq_idx="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__head0_lq_idx
                << "\n";
      int r_head = (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__head_q;
      std::cerr << "  ROB[" << r_head << "] w3=0x" << std::hex
                << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__entries_q[r_head][3]
                << " w2=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__entries_q[r_head][2]
                << " w1=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__entries_q[r_head][1]
                << " w0=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rob__DOT__entries_q[r_head][0]
                << std::dec << "\n";
      std::cerr << "  mem_iq can_issue=0x" << std::hex
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__can_issue << std::dec << "\n";

      int srat_a0 = (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[10];
      int arat_a0 = (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__arat_q[10];
      std::cerr << "  a0(x10): srat=p" << srat_a0 << " arat=p" << arat_a0 << "\n";
      std::cerr << "  prf_status ready_q: ";
      for (int w = 0; w < 3; w++) {
        std::cerr << "w" << w << "=0x" << std::hex << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_prf_status__DOT__ready_q[w] << " ";
      }
      std::cerr << std::dec << "\n";
      for (int reg = 0; reg < 32; reg++) {
        int pr = (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_rat__DOT__srat_q[reg];
        int rdy = (pr == 0) ? 1 : ((dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_substrate__DOT__u_prf_status__DOT__ready_q[pr / 32] >> (pr % 32)) & 1);
        std::cerr << "  x" << reg << "->p" << pr << "(rdy=" << rdy << ") ";
        if ((reg + 1) % 4 == 0) std::cerr << "\n";
      }

      for (int m = 0; m < 16; m++) {
        uint32_t val = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][5];
        if (val != 0 || m < 4) {
          std::cerr << "  mem_iq[" << m << "] w5=0x" << std::hex
                    << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][5]
                    << " w4=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][4]
                    << " w3=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][3]
                    << " w2=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][2]
                    << " w1=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][1]
                    << " w0=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_mem_iq__DOT__entries_q[m][0]
                    << std::dec << "\n";
        }
      }
      for (int l = 0; l < 16; l++) {
        uint32_t val = dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][12];
        if (val != 0 || l < 4) {
          std::cerr << "  LQ[" << l << "] w12=0x" << std::hex
                    << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][12]
                    << " w11=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][11]
                    << " w10=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][10]
                    << " w9=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][9]
                    << " w8=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][8]
                    << " w7=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][7]
                    << " w6=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][6]
                    << " w5=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][5]
                    << " w4=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][4]
                    << " w3=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][3]
                    << " w2=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][2]
                    << " w1=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][1]
                    << " w0=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__lq_q[l][0]
                    << std::dec << "\n";
        }
      }
      std::cerr << "[TB MMIO DEBUG] state="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__mmio_state_q
                << " cand_valid="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__mmio_cand_valid
                << " req_valid=" << (int)dut.rootp->fursoy_s1_soc__DOT__mmio_req_valid
                << " req_ready=" << (int)dut.rootp->fursoy_s1_soc__DOT__mmio_req_ready
                << " inflight=" << (int)dut.rootp->fursoy_s1_soc__DOT__mmio_inflight_q
                << " sq_drain_head="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_drain_head_q
                << " sq_tail="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_tail_q
                << "\n";
      std::cerr << "[TB L1D DRAIN DEBUG] sd_valid="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__l1d_store_drain_valid
                << " sd_ready="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__l1d_store_drain_ready
                << " sd_done="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__l1d_store_drain_done
                << " mshr_free="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__mshr_free_count
                << " refill_busy="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q
                << " fifo_cnt="
                << (int)dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q
                << "\n";
      for (int s = 0; s < 16; s++) {
        std::cerr << "  SQ[" << s << "] w9=0x" << std::hex
                  << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][9]
                  << " w8=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][8]
                  << " w7=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][7]
                  << " w6=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][6]
                  << " w5=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][5]
                  << " w4=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][4]
                  << " w3=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][3]
                  << " w2=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][2]
                  << " w1=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][1]
                  << " w0=0x" << dut.rootp->fursoy_s1_soc__DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_lsu_queues__DOT__sq_q[s][0]
                  << std::dec << "\n";
      }
    }

    std::cout << "\n{\n"
              << "  \"status\": \"" << (all_passed ? "pass" : "fail") << "\",\n"
              << "  \"cycles\": " << cycles << ",\n"
              << "  \"commits\": " << commits << ",\n"
              << "  \"properties_tested\": 8,\n"
              << "  \"properties_passed\": " << total_props_passed << ",\n"
              << "  \"prop_m9_19_base\": \"" << (prop_19_ok ? "PASS" : "FAIL")
              << "\",\n"
              << "  \"prop_m9_20_time\": \"" << (prop_20_ok ? "PASS" : "FAIL")
              << "\",\n"
              << "  \"prop_m9_21_dbcn\": \"" << (prop_21_ok ? "PASS" : "FAIL")
              << "\",\n"
              << "  \"prop_m9_22_handoff\": \""
              << (prop_22_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"prop_m9_23_dtb\": \"" << (prop_23_ok ? "PASS" : "FAIL")
              << "\",\n"
              << "  \"prop_m9_24_earlycon\": \""
              << (prop_24_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"prop_m9_25_mixed_priv\": \""
              << (prop_25_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"prop_m9_26_torture\": \""
              << (prop_26_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"torture_seeds_passed\": " << seeds_ok << ",\n"
              << "  \"torture_events_completed\": " << events_done << ",\n"
              << "  \"seen_reset_pc\": " << (seen_reset_pc ? "true" : "false")
              << ",\n"
              << "  \"seen_handoff_pc\": "
              << (seen_handoff_pc ? "true" : "false") << ",\n"
              << "  \"srst_halted\": " << (halted ? "true" : "false") << "\n"
              << "}\n";

    return all_passed ? 0 : 1;

  } catch (const std::exception &e) {
    std::cerr << "[TB FATAL ERROR] " << e.what() << "\n";
    return 1;
  }
}
