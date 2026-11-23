// =============================================================================
// Fursoy Slice-2 Milestone S2-M4 Randomized Multi-Hart Coherence Torture Harness
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
static constexpr uint64_t WATCHDOG_STALL_CYCLES = 16384ULL;
static constexpr uint64_t MIN_TOTAL_COMMITS = 100000ULL;

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
    std::cerr << "Usage: " << argv[0] << " <torture_elf> [max_cycles]\n";
    return 1;
  }
  const char *elf_path = argv[1];
  uint64_t max_cycles = (argc >= 3) ? std::stoull(argv[2], nullptr, 0) : 2000000ULL;

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
  uint64_t last_any_commit_cycle = 0;
  bool watchdog_ok = true;
  bool seen_all_pass = false;
  bool seen_fail = false;
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
      uint64_t lat = 2ULL + ((cycles ^ line_addr ^ req_hart) & 3ULL);
      if (dut.dram_req_write_o) {
        if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
          std::memcpy(&ram[byte_addr - RAM_BASE], (const void *)&dut.dram_req_wdata_o, 64);
        }
        uint64_t ready = wr_q.empty() ? (cycles + lat) : std::max(cycles + lat, wr_q.back().ready_cycle);
        wr_q.push_back({req_hart, ready});
      } else {
        uint64_t ready = rd_q.empty() ? (cycles + lat) : std::max(cycles + lat, rd_q.back().ready_cycle);
        rd_q.push_back({line_addr, req_hart, uint8_t(dut.dram_req_mid_o), uint8_t(dut.dram_req_tag_o), ready});
      }
    }

    dut.clk_i = 1;
    dut.eval();

    if (!sb.check_cycle(cycles)) {
      std::cerr << "[SB ERROR] " << sb.stats.first_error << "\n";
      sb_ok = false;
      break;
    }

    bool any_commit = false;
    for (int h = 0; h < NUM_HARTS; h++) {
      uint8_t rv = dut.retire_valid_o[h];
      if (rv & 1u) { hart_commits[h]++; any_commit = true; }
      if (rv & 2u) { hart_commits[h]++; any_commit = true; }
    }
    if (any_commit) last_any_commit_cycle = cycles;

    if (!seen_all_pass && !seen_fail && (cycles - last_any_commit_cycle > WATCHDOG_STALL_CYCLES)) {
      std::cerr << "[WATCHDOG] Zero commits across all harts for " << WATCHDOG_STALL_CYCLES << " cycles at cyc=" << cycles << "\n";
      watchdog_ok = false;
      break;
    }

    if (dut.uart_tx_valid_o) {
      char ch = char(dut.uart_tx_data_o);
      if (ch == '\n') {
        std::cout << "[UART] " << line_buf << "\n";
        if (line_buf == "[TORTURE_ALL_PASS]") seen_all_pass = true;
        if (line_buf == "[TORTURE_FAIL]" || line_buf == "[TORTURE_SHADOW_FAIL]") seen_fail = true;
        line_buf.clear();
      } else {
        line_buf.push_back(ch);
      }
    }

    cycles++;
    if (seen_all_pass || seen_fail) {
      post_pass_drain++;
      if (post_pass_drain >= 128) break;
    }
  }

  uint64_t total_commits = 0;
  bool all_harts_ok = true;
  for (int h = 0; h < NUM_HARTS; h++) {
    total_commits += hart_commits[h];
    if (hart_commits[h] < 20000ULL) all_harts_ok = false;
  }

  bool min_commits_ok = (total_commits >= MIN_TOTAL_COMMITS);
  bool passed = sb_ok && watchdog_ok && seen_all_pass && !seen_fail && all_harts_ok && min_commits_ok;

  std::cout << "{\n"
            << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
            << "  \"num_harts\": " << NUM_HARTS << ",\n"
            << "  \"cycles\": " << cycles << ",\n"
            << "  \"total_commits\": " << total_commits << ",\n"
            << "  \"min_commits_ok\": " << (min_commits_ok ? "true" : "false") << ",\n"
            << "  \"all_harts_ok\": " << (all_harts_ok ? "true" : "false") << ",\n"
            << "  \"watchdog_ok\": " << (watchdog_ok ? "true" : "false") << ",\n"
            << "  \"sb_ok\": " << (sb_ok ? "true" : "false") << ",\n"
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
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_commits[h];
  std::cout << "]\n}\n";

  return passed ? 0 : 1;
}
