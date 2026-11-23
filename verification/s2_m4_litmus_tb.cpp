// =============================================================================
// Fursoy Slice-2 Milestone S2-M4 Full 8-Test RVWMO SMP Litmus Testbench
// =============================================================================

#include <array>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
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
    std::cerr << "Usage: " << argv[0] << " <litmus_elf> [max_cycles]\n";
    return 1;
  }
  const char *elf_path = argv[1];
  uint64_t max_cycles = (argc >= 3) ? std::stoull(argv[2], nullptr, 0) : 1200000ULL;

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
  std::map<std::string, uint64_t> litmus_forbidden;
  std::map<std::string, uint64_t> litmus_observed;
  uint64_t mp_ctrl_reordered = 0;
  uint64_t mp_ctrl_seen11 = 0;
  bool seen_all_pass = false;
  bool seen_fail = false;
  std::string line_buf;
  uint64_t post_pass_drain = 0;
  bool sb_ok = true;

  auto parse_litmus_line = [&](const std::string &line) {
    if (line.rfind("[LITMUS] ", 0) != 0) return;
    std::string rest = line.substr(9);
    size_t sp = rest.find(' ');
    if (sp == std::string::npos) return;
    std::string name = rest.substr(0, sp);
    auto extract_num = [&](const std::string &key, uint64_t &out) -> bool {
      size_t pos = line.find(key);
      if (pos == std::string::npos) return false;
      pos += key.size();
      out = std::stoull(line.substr(pos), nullptr, 10);
      return true;
    };
    if (name == "MP_CTRL") {
      extract_num("reordered=", mp_ctrl_reordered);
      extract_num("observed=", mp_ctrl_seen11);
    } else {
      uint64_t f = 0, o = 0;
      if (extract_num("forbidden=", f)) litmus_forbidden[name] = f;
      if (extract_num("observed=", o)) litmus_observed[name] = o;
    }
  };

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
      // Pseudo-randomized latency jitter (2..5 cycles) preserving per-queue FIFO completion
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

    for (int h = 0; h < NUM_HARTS; h++) {
      uint8_t rv = dut.retire_valid_o[h];
      if (rv & 1u) hart_commits[h]++;
      if (rv & 2u) hart_commits[h]++;
    }

    if (dut.uart_tx_valid_o) {
      char ch = char(dut.uart_tx_data_o);
      if (ch == '\n') {
        std::cout << "[UART] " << line_buf << std::endl;
        parse_litmus_line(line_buf);
        if (line_buf == "[LITMUS_ALL_PASS]") seen_all_pass = true;
        if (line_buf == "[LITMUS_FAIL]") seen_fail = true;
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

  const char *req_tests[] = {"MP", "SB", "LB", "IRIW", "CoRR", "CoWR", "CoRW", "CoWW"};
  bool all_tests_present = true;
  bool zero_forbidden = true;
  for (const char *t : req_tests) {
    if (litmus_forbidden.find(t) == litmus_forbidden.end()) all_tests_present = false;
    else if (litmus_forbidden[t] != 0) zero_forbidden = false;
  }

  bool all_harts_ok = true;
  for (int h = 0; h < NUM_HARTS; h++) {
    if (hart_commits[h] == 0) all_harts_ok = false;
  }

  bool passed = sb_ok && seen_all_pass && !seen_fail && all_tests_present && zero_forbidden && all_harts_ok;

  std::cout << "{\n"
            << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
            << "  \"num_harts\": " << NUM_HARTS << ",\n"
            << "  \"cycles\": " << cycles << ",\n"
            << "  \"all_tests_present\": " << (all_tests_present ? "true" : "false") << ",\n"
            << "  \"zero_forbidden\": " << (zero_forbidden ? "true" : "false") << ",\n"
            << "  \"all_harts_ok\": " << (all_harts_ok ? "true" : "false") << ",\n"
            << "  \"sb_ok\": " << (sb_ok ? "true" : "false") << ",\n"
            << "  \"mp_ctrl_reordered\": " << mp_ctrl_reordered << ",\n"
            << "  \"mp_ctrl_seen11\": " << mp_ctrl_seen11 << ",\n"
            << "  \"litmus_tests\": {";
  for (size_t i = 0; i < 8; i++) {
    const char *t = req_tests[i];
    uint64_t f = litmus_forbidden.count(t) ? litmus_forbidden[t] : 999999;
    uint64_t o = litmus_observed.count(t) ? litmus_observed[t] : 0;
    std::cout << (i ? "," : "") << "\n    \"" << t << "\": {\"forbidden\": " << f << ", \"observed\": " << o << "}";
  }
  std::cout << "\n  },\n"
            << "  \"swmr_violations\": " << sb.stats.swmr_violations << ",\n"
            << "  \"metadata_violations\": " << sb.stats.metadata_violations << ",\n"
            << "  \"inclusion_violations\": " << sb.stats.inclusion_violations << ",\n"
            << "  \"data_coherence_violations\": " << sb.stats.data_coherence_violations << ",\n"
            << "  \"sb_cycle_checks\": " << sb.stats.cycle_checks << ",\n"
            << "  \"per_hart_commits\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_commits[h];
  std::cout << "]\n}\n";

  return passed ? 0 : 1;
}
