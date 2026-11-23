// =============================================================================
// Fursoy Slice-2 Milestone S2-M2 MESI Coherence & SWMR Scoreboard Testbench
// =============================================================================

#include <array>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "Vfursoy_s2_soc.h"
#include "verilated.h"
#include "s2_swmr_scoreboard.h"

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
  uint64_t max_cycles = (argc >= 3) ? std::stoull(argv[2], nullptr, 0) : 400000ULL;

  std::vector<uint8_t> ram(RAM_SIZE, 0);
  load_elf(elf_path, ram);

  Vfursoy_s2_soc dut;
  S2SwmrScoreboard<NUM_HARTS> sb;
  sb.bind(dut.rootp);

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
  std::array<bool, NUM_HARTS> seen_h_pass{};
  bool seen_t1 = false, seen_t2 = false, seen_t3 = false, seen_t4 = false, seen_t5 = false;
  bool seen_all_pass = false, seen_fail = false;
  std::string line_buf;
  uint64_t post_pass_drain = 0;
  bool sb_ok = true;

  while (cycles < max_cycles) {
    dut.clk_i = 0;

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

    if (!sb.check_cycle(cycles)) {
      std::cerr << "[SB ERROR] " << sb.stats.first_error << "\n";
      sb_ok = false;
      break;
    }

    for (int h = 0; h < NUM_HARTS; h++) {
      uint8_t rv = dut.retire_valid_o[h];
      if (rv & 1u) hart_commits[h]++;
      if (rv & 2u) hart_commits[h]++;
    }

    if (dut.uart_tx_valid_o) {
      char ch = char(dut.uart_tx_data_o);
      if (ch == '\n') {
        std::cout << "[UART] " << line_buf << "\n";
        if (line_buf == "[T1_PINGPONG_PASS]") seen_t1 = true;
        if (line_buf == "[T2_RACE_EVICT_PASS]") seen_t2 = true;
        if (line_buf == "[T3_SHARED_RO_PASS]") seen_t3 = true;
        if (line_buf == "[T4_COH_L1I_PASS]") seen_t4 = true;
        if (line_buf == "[T5_COH_PTW_PASS]") seen_t5 = true;
        if (line_buf == "[ALL_PASS]") seen_all_pass = true;
        if (line_buf.rfind("[FAIL_H", 0) == 0) seen_fail = true;
        for (int h = 0; h < NUM_HARTS; h++) {
          if (line_buf == ("[HART_PASS_H" + std::to_string(h) + "]")) seen_h_pass[h] = true;
        }
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

  bool all_harts_ok = true;
  for (int h = 0; h < NUM_HARTS; h++) {
    if (!seen_h_pass[h] || hart_commits[h] == 0) all_harts_ok = false;
  }

  bool tests_ok = seen_t1 && seen_t2 && seen_t3 && seen_t4 && seen_t5 && seen_all_pass && !seen_fail;
  bool mesi_cov_ok = (sb.stats.seen_mesi_s_multi_hart > 0) &&
                     (sb.stats.seen_mesi_e > 0) &&
                     (sb.stats.seen_mesi_m > 0) &&
                     (sb.stats.seen_wbb_dirty > 0);
  bool passed = sb_ok && tests_ok && all_harts_ok && mesi_cov_ok;

  std::cout << "{\n"
            << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
            << "  \"num_harts\": " << NUM_HARTS << ",\n"
            << "  \"cycles\": " << cycles << ",\n"
            << "  \"tests_ok\": " << (tests_ok ? "true" : "false") << ",\n"
            << "  \"all_harts_ok\": " << (all_harts_ok ? "true" : "false") << ",\n"
            << "  \"sb_ok\": " << (sb_ok ? "true" : "false") << ",\n"
            << "  \"mesi_cov_ok\": " << (mesi_cov_ok ? "true" : "false") << ",\n"
            << "  \"swmr_violations\": " << sb.stats.swmr_violations << ",\n"
            << "  \"metadata_violations\": " << sb.stats.metadata_violations << ",\n"
            << "  \"inclusion_violations\": " << sb.stats.inclusion_violations << ",\n"
            << "  \"data_coherence_violations\": " << sb.stats.data_coherence_violations << ",\n"
            << "  \"sb_cycle_checks\": " << sb.stats.cycle_checks << ",\n"
            << "  \"seen_mesi_s_multi_hart\": " << sb.stats.seen_mesi_s_multi_hart << ",\n"
            << "  \"seen_mesi_e\": " << sb.stats.seen_mesi_e << ",\n"
            << "  \"seen_mesi_m\": " << sb.stats.seen_mesi_m << ",\n"
            << "  \"seen_wbb_dirty\": " << sb.stats.seen_wbb_dirty << ",\n"
            << "  \"per_hart_commits\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << hart_commits[h] << (h + 1 < NUM_HARTS ? ", " : "");
  std::cout << "]\n}\n";

  return passed ? 0 : 1;
}
