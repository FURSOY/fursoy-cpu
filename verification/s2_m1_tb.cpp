// =============================================================================
// Fursoy Slice-2 Milestone S2-M1 Verification Testbench
// =============================================================================
// Exercises fursoy_s2_soc (NUM_HARTS = 2 or 4):
// - Unique mhartid (0 .. NUM_HARTS-1) readback and private per-hart DRAM access
// - Cross-hart CLINT msip[h] IPI ring (explicitly exercising odd harts h=1, 3)
// - Staggered per-hart CLINT mtimecmp[h] timer interrupts
// - fursoy_s2_plic multi-context (2*h M-mode, 2*h+1 S-mode) enable, threshold,
//   priority preemption, threshold-independent claim, and 8-round concurrent
//   single-claim exclusivity
// =============================================================================

#include <array>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Vfursoy_s2_soc.h"
#include "verilated.h"

#ifndef NUM_HARTS
#define NUM_HARTS 2
#endif

static constexpr uint64_t RAM_BASE = 0x80000000ULL;
static constexpr uint64_t RAM_SIZE = 256 * 1024 * 1024ULL;

struct DRAMRdInFlight {
  uint64_t line_addr;
  uint8_t hart;
  uint8_t mid;
  uint8_t tag;
  uint64_t ready_cycle;
};

struct DRAMWrInFlight {
  uint8_t hart;
  uint64_t ready_cycle;
};

static uint64_t get64(const std::vector<uint8_t> &b, size_t o) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v |= uint64_t(b[o + i]) << (8 * i);
  return v;
}
static uint32_t get32(const std::vector<uint8_t> &b, size_t o) { return uint32_t(get64(b, o) & 0xffffffff); }
static uint16_t get16(const std::vector<uint8_t> &b, size_t o) { return uint16_t(b[o] | (uint16_t(b[o + 1]) << 8)); }

static void load_elf(const char *path, std::vector<uint8_t> &ram) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error(std::string("Cannot open ELF: ") + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  if (b.size() < 64 || get32(b, 0) != 0x464c457f || b[4] != 2 || b[5] != 1 || get16(b, 18) != 243) {
    throw std::runtime_error(std::string("Invalid RISC-V ELF64: ") + path);
  }
  uint64_t phoff = get64(b, 32);
  uint16_t entsz = get16(b, 54), count = get16(b, 56);
  for (unsigned i = 0; i < count; i++) {
    size_t o = phoff + i * entsz;
    if (get32(b, o) != 1) continue;
    uint64_t fileoff = get64(b, o + 8);
    uint64_t paddr   = get64(b, o + 24);
    uint64_t filesz  = get64(b, o + 32);
    uint64_t memsz   = get64(b, o + 40);
    if (paddr < RAM_BASE || memsz > RAM_SIZE || paddr - RAM_BASE > RAM_SIZE - memsz || fileoff + filesz > b.size()) {
      throw std::runtime_error("ELF segment outside RAM bounds");
    }
    std::memcpy(&ram[paddr - RAM_BASE], &b[fileoff], filesz);
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::cerr << "Usage: " << argv[0] << " <elf_path> [max_cycles]\n";
    return 1;
  }
  const char *elf_path = argv[1];
  uint64_t max_cycles = (argc >= 3) ? std::stoull(argv[2], nullptr, 0) : 500000ULL;

  std::vector<uint8_t> ram(RAM_SIZE, 0);
  load_elf(elf_path, ram);

  Vfursoy_s2_soc dut;
  dut.clk_i = 0;
  dut.rst_i = 1;
  dut.frontend_en_i = 1;
  dut.irq_sources_i = 0;
  dut.irq_external_i = 0;
  dut.dram_req_ready_i = 1;
  dut.dram_rd_rsp_valid_i = 0;
  dut.dram_rd_rsp_hart_i = 0;
  dut.dram_rd_rsp_mid_i = 0;
  dut.dram_rd_rsp_tag_i = 0;
  std::memset((void *)&dut.dram_rd_rsp_data_i, 0, sizeof(dut.dram_rd_rsp_data_i));
  dut.dram_rd_rsp_error_i = 0;
  dut.dram_wr_rsp_valid_i = 0;
  dut.dram_wr_rsp_hart_i = 0;
  dut.eval();

  for (int r = 0; r < 10; r++) {
    dut.clk_i = 1; dut.eval();
    dut.clk_i = 0; dut.eval();
  }
  dut.rst_i = 0;

  std::deque<DRAMRdInFlight> rd_q;
  std::deque<DRAMWrInFlight> wr_q;

  uint64_t cycles = 0;
  std::array<uint64_t, NUM_HARTS> hart_commits{};
  std::array<bool, NUM_HARTS> seen_msip{};
  std::array<bool, NUM_HARTS> seen_mtip{};
  std::array<bool, NUM_HARTS> seen_seip{};
  std::array<bool, NUM_HARTS> seen_h_pass{};

  std::string line_buf;
  std::string full_log;
  bool seen_all_pass = false;
  bool seen_fail = false;

  // Pulse helper for irq_sources_i: hold bit b high for pulse_rem[b] cycles
  std::array<int, 32> irq_pulse_rem{};

  // Track Test 4B rounds: 8 rounds, each has NUM_HARTS claims
  int cur_4b_round = -1;
  std::array<std::vector<std::pair<int, int>>, 8> claims_4b;

  uint64_t post_pass_drain = 0;

  while (cycles < max_cycles) {
    dut.clk_i = 0;

    // Update pulsed PLIC irq_sources_i
    uint32_t irq_mask = 0;
    for (int b = 2; b < 32; b++) {
      if (irq_pulse_rem[b] > 0) {
        irq_mask |= (1u << b);
        irq_pulse_rem[b]--;
      }
    }
    dut.irq_sources_i = irq_mask;

    // Drive DRAM responses
    if (!wr_q.empty() && wr_q.front().ready_cycle <= cycles) {
      dut.dram_wr_rsp_valid_i = 1;
      dut.dram_wr_rsp_hart_i = wr_q.front().hart;
      wr_q.pop_front();
    } else {
      dut.dram_wr_rsp_valid_i = 0;
    }

    if (!rd_q.empty() && rd_q.front().ready_cycle <= cycles) {
      DRAMRdInFlight rsp = rd_q.front();
      rd_q.pop_front();
      dut.dram_rd_rsp_valid_i = 1;
      dut.dram_rd_rsp_hart_i = rsp.hart;
      dut.dram_rd_rsp_mid_i = rsp.mid;
      dut.dram_rd_rsp_tag_i = rsp.tag;
      dut.dram_rd_rsp_error_i = 0;
      uint64_t byte_addr = rsp.line_addr << 6;
      if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
        std::memcpy((void *)&dut.dram_rd_rsp_data_i, &ram[byte_addr - RAM_BASE], 64);
      } else {
        std::memset((void *)&dut.dram_rd_rsp_data_i, 0, 64);
        dut.dram_rd_rsp_error_i = 1;
      }
    } else {
      dut.dram_rd_rsp_valid_i = 0;
    }

    dut.eval();

    if (dut.dram_req_valid_o && dut.dram_req_ready_i) {
      uint64_t line_addr = dut.dram_req_addr_o;
      uint64_t byte_addr = line_addr << 6;
      uint8_t req_hart = uint8_t(dut.dram_req_hart_o);
      if (dut.dram_req_write_o) {
        if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
          std::memcpy(&ram[byte_addr - RAM_BASE], (const void *)&dut.dram_req_wdata_o, 64);
        }
        wr_q.push_back({req_hart, cycles + 1});
      } else {
        rd_q.push_back({line_addr, req_hart, uint8_t(dut.dram_req_mid_o), uint8_t(dut.dram_req_tag_o), cycles + 2});
      }
    }

    dut.clk_i = 1;
    dut.eval();

    // Hardware IRQ & commit observation per hart
    for (int h = 0; h < NUM_HARTS; h++) {
      if (dut.diag_irq_software_o & (1u << h)) seen_msip[h] = true;
      if (dut.diag_irq_timer_o & (1u << h)) seen_mtip[h] = true;
      if (dut.diag_irq_seip_o & (1u << h)) seen_seip[h] = true;
      uint8_t rv = dut.retire_valid_o[h];
      if (rv & 1u) hart_commits[h]++;
      if (rv & 2u) hart_commits[h]++;
    }

    // UART marker handling
    if (dut.uart_tx_valid_o) {
      char ch = char(dut.uart_tx_data_o);
      full_log.push_back(ch);
      if (ch == '\n') {
        std::cout << "[UART] " << line_buf << "\n";
        for (int h = 0; h < NUM_HARTS; h++) {
          if (line_buf == ("[4A_S" + std::to_string(h) + "]")) irq_pulse_rem[2 + h] = 3;
          if (line_buf == ("[4A_P" + std::to_string(h) + "]")) irq_pulse_rem[6 + h] = 3;
          if (line_buf == ("[4A_M" + std::to_string(h) + "]")) irq_pulse_rem[10 + h] = 3;
          if (line_buf == ("[H_PASS_" + std::to_string(h) + "]")) seen_h_pass[h] = true;
          if (line_buf.rfind("[FAIL_H", 0) == 0) seen_fail = true;
          if (cur_4b_round >= 0 && cur_4b_round < 8) {
            std::string pfx = "[4B_C" + std::to_string(h) + "=";
            if (line_buf.rfind(pfx, 0) == 0) {
              int val = std::stoi(line_buf.substr(pfx.size()));
              claims_4b[cur_4b_round].push_back({h, val});
            }
          }
        }
        for (int r = 0; r < 8; r++) {
          if (line_buf == ("[4B_R" + std::to_string(r) + "]")) {
            cur_4b_round = r;
            irq_pulse_rem[14] = 3;
          }
        }
        if (line_buf == "[S2_M1_ALL_PASS]") seen_all_pass = true;
        line_buf.clear();
      } else {
        line_buf.push_back(ch);
      }
    }

    cycles++;
    if (seen_all_pass || seen_fail) {
      post_pass_drain++;
      if (post_pass_drain >= 64) break;
    }
  }

  // Validate 4B single-claim exclusivity
  bool plic_4b_ok = true;
  std::array<int, 8> winners_4b{};
  for (int r = 0; r < 8; r++) {
    winners_4b[r] = -1;
    if (int(claims_4b[r].size()) != NUM_HARTS) {
      plic_4b_ok = false;
      continue;
    }
    int win_cnt = 0;
    for (auto &kv : claims_4b[r]) {
      if (kv.second == 14) {
        win_cnt++;
        winners_4b[r] = kv.first;
      } else if (kv.second != 0) {
        plic_4b_ok = false;
      }
    }
    if (win_cnt != 1) plic_4b_ok = false;
  }

  bool all_harts_ok = true;
  for (int h = 0; h < NUM_HARTS; h++) {
    if (!seen_msip[h] || !seen_mtip[h] || !seen_seip[h] || !seen_h_pass[h] || hart_commits[h] == 0) {
      all_harts_ok = false;
    }
  }

  bool passed = seen_all_pass && !seen_fail && plic_4b_ok && all_harts_ok;

  std::cout << "{\n"
            << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
            << "  \"num_harts\": " << NUM_HARTS << ",\n"
            << "  \"cycles\": " << cycles << ",\n"
            << "  \"seen_all_pass\": " << (seen_all_pass ? "true" : "false") << ",\n"
            << "  \"seen_fail\": " << (seen_fail ? "true" : "false") << ",\n"
            << "  \"plic_4b_ok\": " << (plic_4b_ok ? "true" : "false") << ",\n"
            << "  \"all_harts_ok\": " << (all_harts_ok ? "true" : "false") << ",\n"
            << "  \"per_hart_commits\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << hart_commits[h] << (h + 1 < NUM_HARTS ? ", " : "");
  std::cout << "],\n  \"per_hart_msip_seen\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (seen_msip[h] ? "true" : "false") << (h + 1 < NUM_HARTS ? ", " : "");
  std::cout << "],\n  \"per_hart_mtip_seen\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (seen_mtip[h] ? "true" : "false") << (h + 1 < NUM_HARTS ? ", " : "");
  std::cout << "],\n  \"per_hart_seip_seen\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (seen_seip[h] ? "true" : "false") << (h + 1 < NUM_HARTS ? ", " : "");
  std::cout << "],\n  \"plic_4b_winners\": [";
  for (int r = 0; r < 8; r++) std::cout << winners_4b[r] << (r < 7 ? ", " : "");
  std::cout << "]\n}\n";

  return passed ? 0 : 1;
}
