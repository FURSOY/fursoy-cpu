// =============================================================================
// Fursoy Slice-2.5 Milestone S2.5-M3a Multi-Core Benchmark Testbench (fursoy_s2_soc)
// =============================================================================
// Runs bare-metal SMP benchmarks (CoreMark N=1/2/4, McCalpin FP64 STREAM N=1/2/4)
// on fursoy_s2_soc with shared 256 KiB inclusive L2 and MESI coherence.
// =============================================================================

#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
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

static std::string json_escape(const std::string &s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    if (c == '\\') out += "\\\\";
    else if (c == '"') out += "\\\"";
    else if (c == '\r') continue;
    else if (static_cast<unsigned char>(c) < 0x20) continue;
    else out.push_back(c);
  }
  return out;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::cerr << "Usage: " << argv[0] << " <elf> [max_cycles] [dram_rd_lat] [dram_wr_lat]\n";
    return 1;
  }
  const char *elf_path = argv[1];
  uint64_t max_cycles = (argc >= 3) ? std::stoull(argv[2], nullptr, 0) : 100000000ULL;
  uint64_t dram_rd_lat = (argc >= 4) ? std::stoull(argv[3], nullptr, 0) : 2ULL;
  uint64_t dram_wr_lat = (argc >= 5) ? std::stoull(argv[4], nullptr, 0) : 1ULL;

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
  uint64_t last_total_commits = 0;
  uint64_t stall_cycles = 0;
  uint64_t dram_reads = 0;
  uint64_t dram_writes = 0;

  bool seen_exit = false;
  bool seen_fail = false;
  bool seen_trap = false;
  bool watchdog_stall = false;
  int exit_rc = -1;
  uint64_t post_exit_drain = 0;

  std::string line_buf;
  std::vector<std::string> uart_lines;
  constexpr uint64_t kWatchdogLimit = 500000ULL;
  constexpr uint64_t kProgressInterval = 1000000ULL;
  auto t0 = std::chrono::steady_clock::now();

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
      uint8_t rh = uint8_t(dut.dram_req_hart_o);
      if (dut.dram_req_write_o) {
        dram_writes++;
        if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
          std::memcpy(&ram[byte_addr - RAM_BASE], (const void *)&dut.dram_req_wdata_o, 64);
        }
        uint64_t ready = wr_q.empty() ? (cycles + dram_wr_lat) : std::max(cycles + dram_wr_lat, wr_q.back().ready_cycle);
        wr_q.push_back({rh, ready});
      } else {
        dram_reads++;
        uint64_t ready = rd_q.empty() ? (cycles + dram_rd_lat) : std::max(cycles + dram_rd_lat, rd_q.back().ready_cycle);
        rd_q.push_back({line_addr, rh, uint8_t(dut.dram_req_mid_o), uint8_t(dut.dram_req_tag_o), ready});
      }
    }

    dut.clk_i = 1;
    dut.eval();

    uint64_t total_commits = 0;
    for (int h = 0; h < NUM_HARTS; h++) {
      uint8_t rv = dut.retire_valid_o[h];
      if (rv & 1u) hart_commits[h]++;
      if (rv & 2u) hart_commits[h]++;
      total_commits += hart_commits[h];
    }

    if (dut.uart_tx_valid_o) {
      unsigned char uch = static_cast<unsigned char>(dut.uart_tx_data_o);
      if (uch == 0x01u || uch == 0x02u) {
        // Control bytes ignored on s2_soc TB
      } else if (uch == '\n') {
        uart_lines.push_back(line_buf);
        std::cerr << "[UART N=" << NUM_HARTS << "] " << line_buf << std::endl;
        if (line_buf.rfind("[BENCH_EXIT] rc=", 0) == 0) {
          exit_rc = std::stoi(line_buf.substr(16));
          seen_exit = true;
        } else if (line_buf == "[BENCH_FAIL]") {
          seen_fail = true;
        } else if (line_buf.rfind("[BENCH_TRAP]", 0) == 0) {
          seen_trap = true;
        }
        line_buf.clear();
      } else if (uch != '\r') {
        line_buf.push_back(static_cast<char>(uch));
      }
    }

    cycles++;
    if (total_commits != last_total_commits) {
      last_total_commits = total_commits;
      stall_cycles = 0;
    } else if (!seen_exit && !seen_fail) {
      stall_cycles++;
      if (stall_cycles >= kWatchdogLimit) {
        watchdog_stall = true;
        std::cerr << "[WATCHDOG ERROR] No hart committed for " << kWatchdogLimit << " cycles at cyc=" << cycles << "\n";
        break;
      }
    }

    if ((cycles % kProgressInterval) == 0) {
      double el = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
      double cps = (el > 0.0) ? (double(cycles) / el) : 0.0;
      std::cerr << "[PROGRESS N=" << NUM_HARTS << "] cycles=" << cycles
                << " elapsed_s=" << std::fixed << std::setprecision(1) << el
                << " cyc/s=" << cps << " commits=" << total_commits << std::endl;
    }

    if (seen_exit || seen_fail) {
      post_exit_drain++;
      if (post_exit_drain >= 64) break;
    }
  }

  double wall_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  uint64_t total_commits = 0;
  bool all_harts_ok = true;
  for (int h = 0; h < NUM_HARTS; h++) {
    total_commits += hart_commits[h];
    if (hart_commits[h] == 0) all_harts_ok = false;
  }

  bool passed = seen_exit && (exit_rc == 0) && !seen_fail && !seen_trap && !watchdog_stall && all_harts_ok;

  std::cout << "{\n"
            << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
            << "  \"soc\": \"fursoy_s2_soc\",\n"
            << "  \"num_harts\": " << NUM_HARTS << ",\n"
            << "  \"dram_rd_lat\": " << dram_rd_lat << ",\n"
            << "  \"dram_wr_lat\": " << dram_wr_lat << ",\n"
            << "  \"exit_rc\": " << exit_rc << ",\n"
            << "  \"seen_trap\": " << (seen_trap ? "true" : "false") << ",\n"
            << "  \"watchdog_stall\": " << (watchdog_stall ? "true" : "false") << ",\n"
            << "  \"all_harts_ok\": " << (all_harts_ok ? "true" : "false") << ",\n"
            << "  \"wall_seconds\": " << std::fixed << std::setprecision(3) << wall_s << ",\n"
            << "  \"total_cycles\": " << cycles << ",\n"
            << "  \"total_commits\": " << total_commits << ",\n"
            << "  \"dram_reads\": " << dram_reads << ",\n"
            << "  \"dram_writes\": " << dram_writes << ",\n"
            << "  \"per_hart_commits\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_commits[h];
  std::cout << "],\n"
            << "  \"uart_lines\": [";
  for (size_t i = 0; i < uart_lines.size(); i++) {
    std::cout << (i ? "," : "") << "\n    \"" << json_escape(uart_lines[i]) << "\"";
  }
  std::cout << "\n  ]\n}\n";

  return passed ? 0 : 1;
}
