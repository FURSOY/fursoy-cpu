// =============================================================================
// Fursoy Slice-2 Directed P0-1 Stress Testbench:
//   Uncached MMIO (UART THR + PLIC Claim/Complete) vs High-Frequency MSIP IRQ
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
static uint32_t get32(const std::vector<uint8_t> &b, size_t o) { return uint32_t(get64(b, o) & 0xffffffffULL); }
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

static uint64_t parse_hex_field(const std::string &line, const std::string &key) {
  auto pos = line.find(key);
  if (pos == std::string::npos) return 0xdeadbeefULL;
  pos += key.size();
  return std::stoull(line.substr(pos, 16), nullptr, 16);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::cerr << "Usage: " << argv[0] << " <elf_path> [max_cycles]\n";
    return 1;
  }
  const char *elf_path = argv[1];
  uint64_t max_cycles = (argc >= 3) ? std::stoull(argv[2], nullptr, 0) : 300000ULL;

  std::vector<uint8_t> ram(RAM_SIZE, 0);
  load_elf(elf_path, ram);

  Vfursoy_s2_soc dut;
  S2SwmrScoreboard<NUM_HARTS> sb;
  sb.bind(dut.rootp);

  dut.clk_i = 0;
  dut.rst_i = 1;
  dut.frontend_en_i = 1;
  dut.irq_sources_i = (1u << 2);  // Level-high PLIC Source 2 until EOT (0x04)
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
  std::string phase1_bytes;
  bool seen_eot = false;
  bool seen_ack = false;
  bool seen_summary = false;
  std::string summary_line;
  bool sb_ok = true;

  // Independently derived golden 128-byte UART payload
  std::string expected_phase1;
  expected_phase1.reserve(128);
  for (int i = 0; i < 128; i++) expected_phase1.push_back(char(0x30 + (i & 63)));

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
      uint64_t byte_addr = rsp.line_addr << 6;
      if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
        std::memcpy((void *)&dut.dram_rd_rsp_data_i, &ram[byte_addr - RAM_BASE], 64);
        dut.dram_rd_rsp_error_i = 0;
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
        if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
          std::memcpy(&ram[byte_addr - RAM_BASE], (const void *)&dut.dram_req_wdata_o, 64);
        }
        wr_q.push_back({rh, cycles + 1});
      } else {
        rd_q.push_back({line_addr, rh, uint8_t(dut.dram_req_mid_o), uint8_t(dut.dram_req_tag_o), cycles + 2});
      }
    }

    dut.clk_i = 1;
    dut.eval();

    if (!sb.check_cycle(cycles)) sb_ok = false;

    for (int h = 0; h < NUM_HARTS; h++) {
      uint8_t rv = dut.retire_valid_o[h];
      if (rv & 1u) hart_commits[h]++;
      if (rv & 2u) hart_commits[h]++;
    }

    if (dut.uart_tx_valid_o) {
      uint8_t ch = uint8_t(dut.uart_tx_data_o);
      if (!seen_eot) {
        if (ch == 0x04) {
          seen_eot = true;
          dut.irq_sources_i = 0;  // Drop PLIC Source 2 for drain + idle verification
        } else {
          phase1_bytes.push_back(char(ch));
        }
      } else if (!seen_ack) {
        if (ch == 0x06) {
          seen_ack = true;
        }
      } else {
        if (ch == '\n') {
          seen_summary = true;
          break;
        }
        summary_line.push_back(char(ch));
      }
    }

    cycles++;
  }

  uint64_t ipi_cnt   = seen_summary ? parse_hex_field(summary_line, "ipi=") : 0;
  uint64_t claim_cnt = seen_summary ? parse_hex_field(summary_line, "claims=") : 0;
  uint64_t bad_claim = seen_summary ? parse_hex_field(summary_line, "bad=") : 0xdeadbeefULL;
  uint64_t drain_id  = seen_summary ? parse_hex_field(summary_line, "drain=") : 0;
  uint64_t idle_id   = seen_summary ? parse_hex_field(summary_line, "idle=") : 0xdeadbeefULL;
  uint64_t bad_trap  = seen_summary ? parse_hex_field(summary_line, "badtrap=") : 0xdeadbeefULL;

  bool uart_exact_ok = (phase1_bytes == expected_phase1);
  bool plic_exact_ok = (claim_cnt == 128 && bad_claim == 0 && drain_id == 2 && idle_id == 0);
  bool ipi_stress_ok = (ipi_cnt >= 150 && bad_trap == 0);
  bool passed = seen_eot && seen_ack && seen_summary && uart_exact_ok && plic_exact_ok && ipi_stress_ok && sb_ok;

  std::cout << "{\n"
            << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
            << "  \"num_harts\": " << NUM_HARTS << ",\n"
            << "  \"cycles\": " << cycles << ",\n"
            << "  \"uart_bytes_expected\": 128,\n"
            << "  \"uart_bytes_received\": " << phase1_bytes.size() << ",\n"
            << "  \"uart_exact_1to1_match\": " << (uart_exact_ok ? "true" : "false") << ",\n"
            << "  \"ipi_preemptions\": " << ipi_cnt << ",\n"
            << "  \"plic_claims_completed\": " << claim_cnt << ",\n"
            << "  \"plic_bad_claims\": " << bad_claim << ",\n"
            << "  \"plic_drain_id\": " << drain_id << ",\n"
            << "  \"plic_idle_id\": " << idle_id << ",\n"
            << "  \"unexpected_traps\": " << bad_trap << ",\n"
            << "  \"sb_ok\": " << (sb_ok ? "true" : "false") << ",\n"
            << "  \"swmr_violations\": " << sb.stats.swmr_violations << ",\n"
            << "  \"metadata_violations\": " << sb.stats.metadata_violations << ",\n"
            << "  \"inclusion_violations\": " << sb.stats.inclusion_violations << ",\n"
            << "  \"data_coherence_violations\": " << sb.stats.data_coherence_violations << ",\n"
            << "  \"per_hart_commits\": [";
  for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_commits[h];
  std::cout << "]\n}\n";
  return passed ? 0 : 1;
}
