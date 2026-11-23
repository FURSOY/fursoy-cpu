// =============================================================================
// Fursoy Slice-2 Milestone S2-M5 Multi-Hart SMP Linux Boot Testbench
// =============================================================================
// Boots Linux 6.6.50 (CONFIG_SMP=y, embedded BusyBox + s2_smp_test initramfs)
// on fursoy_s2_soc (NUM_HARTS = 2 or 4, SMP_COHERENCE_EN = 1) via fursoy_s2_sbi.
//
// Features:
// - Links against shared Vfursoy_s2_soc__ALL.a (supports single/multi-threaded Verilator)
// - Live unbuffered UART TX console streaming + optional log file
// - Per-hart retired instruction counters, IPC, privilege transitions & secondary bring-up
// - Forward-progress watchdog + live Kernel panic / Oops / RCU stall / SBI trap detection
// - Smoke mode (--smoke) and full SMP Linux closeout mode
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

static constexpr uint64_t RAM_BASE    = 0x80000000ULL;
static constexpr uint64_t RAM_SIZE    = 256 * 1024 * 1024ULL; // 256 MiB DRAM
static constexpr uint64_t KERNEL_BASE = 0x80200000ULL;
static constexpr uint64_t DTB_BASE    = 0x82000000ULL;

static uint64_t get64(const std::vector<uint8_t> &b, size_t o) {
  uint64_t v = 0;
  for (int i = 0; i < 8; i++) v |= uint64_t(b[o + i]) << (8 * i);
  return v;
}
static uint32_t get32(const std::vector<uint8_t> &b, size_t o) { return uint32_t(get64(b, o) & 0xffffffffULL); }
static uint16_t get16(const std::vector<uint8_t> &b, size_t o) { return uint16_t(b[o] | (uint16_t(b[o + 1]) << 8)); }

static size_t load_raw_bin(const char *path, std::vector<uint8_t> &ram, uint64_t load_addr) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error(std::string("Cannot open binary: ") + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  if (load_addr < RAM_BASE || load_addr - RAM_BASE + b.size() > RAM_SIZE) {
    throw std::runtime_error(std::string("Binary outside DRAM aperture: ") + path);
  }
  std::memcpy(&ram[load_addr - RAM_BASE], b.data(), b.size());
  return b.size();
}

static size_t load_elf(const char *path, std::vector<uint8_t> &ram) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error(std::string("Cannot open ELF: ") + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  if (b.size() < 64 || get32(b, 0) != 0x464c457f || b[4] != 2 || b[5] != 1 || get16(b, 18) != 243) {
    throw std::runtime_error(std::string("Invalid RISC-V ELF64: ") + path);
  }
  uint64_t phoff = get64(b, 32);
  uint16_t entsz = get16(b, 54), count = get16(b, 56);
  size_t total = 0;
  for (unsigned i = 0; i < count; i++) {
    size_t o = phoff + i * entsz;
    if (o + 56 > b.size()) throw std::runtime_error("Bad ELF program header");
    if (get32(b, o) != 1) continue; // PT_LOAD
    uint64_t fileoff = get64(b, o + 8);
    uint64_t paddr   = get64(b, o + 24);
    uint64_t filesz  = get64(b, o + 32);
    uint64_t memsz   = get64(b, o + 40);
    if (paddr < RAM_BASE || memsz > RAM_SIZE || paddr - RAM_BASE > RAM_SIZE - memsz || fileoff + filesz > b.size()) {
      throw std::runtime_error("ELF segment outside DRAM aperture");
    }
    std::memcpy(&ram[paddr - RAM_BASE], &b[fileoff], filesz);
    total += filesz;
  }
  return total;
}

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

struct ConsoleMatcher {
  std::string tail;
  void push(char c) {
    tail.push_back(c);
    if (tail.size() > 1024) tail.erase(0, tail.size() - 512);
  }
  bool ends_with(const char *s) const {
    size_t n = std::strlen(s);
    return tail.size() >= n && tail.compare(tail.size() - n, n, s) == 0;
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 4) {
    std::cerr << "Usage: " << argv[0]
              << " <sbi_elf> <kernel_img> <dtb_bin> [max_cycles] [console_log] [smoke_mode=0|1]\n";
    return 1;
  }

  const char *sbi_elf = argv[1];
  const char *kernel_img = argv[2];
  const char *dtb_bin = argv[3];
  uint64_t max_cycles = (argc >= 5) ? std::stoull(argv[4], nullptr, 0) : 150000000ULL;
  const char *console_log_path = (argc >= 6 && std::strlen(argv[5]) > 0) ? argv[5] : nullptr;
  bool smoke_mode = (argc >= 7) && (std::atoi(argv[6]) != 0);

  try {
    std::vector<uint8_t> ram(RAM_SIZE, 0);
    size_t fw_sz = load_elf(sbi_elf, ram);
    size_t kernel_sz = load_raw_bin(kernel_img, ram, KERNEL_BASE);
    size_t dtb_sz = load_raw_bin(dtb_bin, ram, DTB_BASE);
    if (KERNEL_BASE + kernel_sz > DTB_BASE) {
      throw std::runtime_error("Kernel Image overlaps DTB aperture at 0x8200_0000");
    }

    std::cerr << "[S2-M5 TB] NUM_HARTS=" << NUM_HARTS
              << " mode=" << (smoke_mode ? "smoke" : "full")
              << " max_cycles=" << max_cycles << "\n"
              << "[S2-M5 TB] SBI=" << fw_sz << "B @0x80000000"
              << " Kernel=" << kernel_sz << "B @0x80200000"
              << " DTB=" << dtb_sz << "B @0x82000000\n";

    std::ofstream console_log;
    if (console_log_path) console_log.open(console_log_path, std::ios::out | std::ios::trunc);

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
    dut.dram_rd_rsp_error_i = 0;
    std::memset((void *)&dut.dram_rd_rsp_data_i, 0, sizeof(dut.dram_rd_rsp_data_i));
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

    const auto wall_start = std::chrono::steady_clock::now();
    uint64_t cycles = 0;
    uint64_t last_progress_cycle = 0;
    constexpr uint64_t WATCHDOG_LIMIT = 250000ULL;

    std::array<uint64_t, NUM_HARTS> hart_commits{};
    std::array<uint64_t, NUM_HARTS> hart_smode_commits{};
    std::array<uint64_t, NUM_HARTS> hart_umode_commits{};
    std::array<bool, NUM_HARTS> hart_seen_smode{};
    std::array<bool, NUM_HARTS> hart_seen_umode{};
    std::array<uint64_t, NUM_HARTS> hart_last_pc{};

    ConsoleMatcher con;
    uint64_t uart_bytes = 0;

    // Boot & SMP milestones
    bool seen_sbi_handoff = false;
    bool seen_linux_banner = false;
    bool seen_smp_brought_up = false;
    bool seen_run_init = false;
    bool seen_cpuinfo_pass = false;
    bool seen_affinity_pass = false;
    bool seen_pthreads_pass = false;
    bool seen_busybox_pass = false;
    bool seen_all_pass = false;

    // Fatal / error detectors
    bool seen_kernel_panic = false;
    bool seen_oops = false;
    bool seen_rcu_stall = false;
    bool seen_sbi_trap = false;
    bool seen_userspace_fail = false;
    bool watchdog_triggered = false;

    uint64_t cyc_sbi_handoff = 0;
    uint64_t cyc_linux_banner = 0;
    uint64_t cyc_smp_brought_up = 0;
    uint64_t cyc_run_init = 0;
    uint64_t cyc_all_pass = 0;
    uint64_t post_event_drain = 0;

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

      bool any_commit = false;
      for (int h = 0; h < NUM_HARTS; h++) {
        uint8_t rv = dut.retire_valid_o[h];
        uint8_t priv = dut.csr_priv_mode_o[h] & 0x3u;
        for (int slot = 0; slot < 2; slot++) {
          if (rv & (1u << slot)) {
            any_commit = true;
            hart_commits[h]++;
            uint64_t pc = dut.retire_pc_o[h][slot];
            hart_last_pc[h] = pc;
            if (priv == 1u) {
              hart_smode_commits[h]++;
              if (!hart_seen_smode[h]) {
                hart_seen_smode[h] = true;
                if (h > 0) {
                  std::cerr << "[S2-M5 TB] hart" << h << " entered S-mode at cyc=" << cycles
                            << " pc=0x" << std::hex << pc << std::dec << "\n";
                }
              }
              if (h == 0 && !seen_sbi_handoff && pc == KERNEL_BASE) {
                seen_sbi_handoff = true;
                cyc_sbi_handoff = cycles;
              }
            } else if (priv == 0u) {
              hart_umode_commits[h]++;
              hart_seen_umode[h] = true;
            }
          }
        }
      }

      if (any_commit) {
        last_progress_cycle = cycles;
      }

      if (dut.uart_tx_valid_o) {
        char ch = char(dut.uart_tx_data_o);
        uart_bytes++;
        std::cout.put(ch);
        std::cout.flush();
        if (console_log.is_open()) {
          console_log.put(ch);
          console_log.flush();
        }
        con.push(ch);

        if (!seen_linux_banner && con.ends_with("Linux version 6.6.50")) {
          seen_linux_banner = true;
          cyc_linux_banner = cycles;
        }
        if (!seen_smp_brought_up && con.ends_with("Brought up ")) {
          seen_smp_brought_up = true;
          cyc_smp_brought_up = cycles;
        }
        if (!seen_run_init && con.ends_with("Run /init as init process")) {
          seen_run_init = true;
          cyc_run_init = cycles;
        }
        if (!seen_cpuinfo_pass && con.ends_with("[SMP_CPUINFO_PASS]")) seen_cpuinfo_pass = true;
        if (!seen_affinity_pass && con.ends_with("[SMP_AFFINITY_PASS]")) seen_affinity_pass = true;
        if (!seen_pthreads_pass && con.ends_with("[SMP_PTHREADS_PASS]")) seen_pthreads_pass = true;
        if (!seen_busybox_pass && con.ends_with("[SMP_BUSYBOX_PASS]")) seen_busybox_pass = true;
        if (!seen_all_pass && con.ends_with("[S2_M5_LINUX_ALL_PASS]")) {
          seen_all_pass = true;
          cyc_all_pass = cycles;
        }

        if (con.ends_with("Kernel panic")) seen_kernel_panic = true;
        if (con.ends_with("Oops:") || con.ends_with("Unable to handle kernel") || con.ends_with("BUG:")) seen_oops = true;
        if (con.ends_with("rcu_sched self-detected stall") || con.ends_with("INFO: rcu_")) seen_rcu_stall = true;
        if (con.ends_with("!SBI!")) seen_sbi_trap = true;
        if (con.ends_with("FURSOY_USERSPACE_FAIL") || con.ends_with("[S2_M5_LINUX_FAIL]") || con.ends_with("[SMP_TEST_FAIL]")) {
          seen_userspace_fail = true;
        }
      }

      cycles++;

      bool fatal = seen_kernel_panic || seen_oops || seen_rcu_stall || seen_sbi_trap || seen_userspace_fail;
      if (fatal || seen_all_pass) {
        post_event_drain++;
        if (post_event_drain >= 4000) break;
      }

      // Forward-progress watchdog: only fires if all harts stall for WATCHDOG_LIMIT cycles
      bool all_wfi = (dut.wfi_sleep_o == ((1u << NUM_HARTS) - 1u));
      if (!all_wfi && (cycles - last_progress_cycle) > WATCHDOG_LIMIT) {
        watchdog_triggered = true;
        std::cerr << "\n[S2-M5 TB] WATCHDOG triggered at cycle " << cycles << "\n";
        break;
      }

      if ((cycles % 100000ULL) == 0ULL) {
        auto now = std::chrono::steady_clock::now();
        double dt = std::chrono::duration<double>(now - wall_start).count();
        uint64_t tot_c = 0;
        for (int h = 0; h < NUM_HARTS; h++) tot_c += hart_commits[h];
        std::cerr << "[S2-M5 TB] cyc=" << cycles
                  << " commits=" << tot_c
                  << " hc=[";
        for (int h = 0; h < NUM_HARTS; h++) {
          if (h) std::cerr << ",";
          std::cerr << hart_commits[h];
        }
        std::cerr << "] pc=[";
        for (int h = 0; h < NUM_HARTS; h++) {
          if (h) std::cerr << ",";
          std::cerr << "0x" << std::hex << hart_last_pc[h] << std::dec;
        }
        std::cerr << "] priv=[";
        for (int h = 0; h < NUM_HARTS; h++) {
          if (h) std::cerr << ",";
          std::cerr << unsigned(dut.csr_priv_mode_o[h] & 0x3u);
        }
        std::cerr << "] wfi=0x" << std::hex << unsigned(dut.wfi_sleep_o)
                  << " sw=0x" << unsigned(dut.diag_irq_software_o)
                  << " tmr=0x" << unsigned(dut.diag_irq_timer_o) << std::dec
                  << " rate=" << std::fixed << std::setprecision(1) << (dt > 0 ? cycles / dt : 0.0) << " cyc/s"
                  << " uart=" << uart_bytes << "B\n";
      }
    }

    auto wall_end = std::chrono::steady_clock::now();
    double wall_s = std::chrono::duration<double>(wall_end - wall_start).count();
    uint64_t total_commits = 0;
    bool all_harts_smode = true;
    for (int h = 0; h < NUM_HARTS; h++) {
      total_commits += hart_commits[h];
      if (!hart_seen_smode[h]) all_harts_smode = false;
    }

    bool no_errors = !seen_kernel_panic && !seen_oops && !seen_rcu_stall && !seen_sbi_trap &&
                     !seen_userspace_fail && !watchdog_triggered;
    bool passed = false;
    if (smoke_mode) {
      passed = no_errors && seen_sbi_handoff && seen_linux_banner && (cycles >= max_cycles || seen_all_pass);
    } else {
      passed = no_errors && seen_sbi_handoff && seen_linux_banner && all_harts_smode &&
               seen_cpuinfo_pass && seen_affinity_pass && seen_pthreads_pass &&
               seen_busybox_pass && seen_all_pass;
    }

    double cyc_per_s = (wall_s > 0.0) ? (double(cycles) / wall_s) : 0.0;
    std::cout << "\n{\n"
              << "  \"status\": \"" << (passed ? "pass" : "fail") << "\",\n"
              << "  \"mode\": \"" << (smoke_mode ? "smoke" : "full") << "\",\n"
              << "  \"num_harts\": " << NUM_HARTS << ",\n"
              << "  \"cycles\": " << cycles << ",\n"
              << "  \"wall_sec\": " << std::fixed << std::setprecision(2) << wall_s << ",\n"
              << "  \"cycles_per_sec\": " << std::fixed << std::setprecision(1) << cyc_per_s << ",\n"
              << "  \"total_commits\": " << total_commits << ",\n"
              << "  \"total_ipc\": " << std::fixed << std::setprecision(4) << (cycles > 0 ? double(total_commits) / double(cycles) : 0.0) << ",\n"
              << "  \"uart_bytes\": " << uart_bytes << ",\n"
              << "  \"seen_sbi_handoff\": " << (seen_sbi_handoff ? "true" : "false") << ",\n"
              << "  \"cyc_sbi_handoff\": " << cyc_sbi_handoff << ",\n"
              << "  \"seen_linux_banner\": " << (seen_linux_banner ? "true" : "false") << ",\n"
              << "  \"cyc_linux_banner\": " << cyc_linux_banner << ",\n"
              << "  \"seen_smp_brought_up\": " << (seen_smp_brought_up ? "true" : "false") << ",\n"
              << "  \"cyc_smp_brought_up\": " << cyc_smp_brought_up << ",\n"
              << "  \"all_harts_smode\": " << (all_harts_smode ? "true" : "false") << ",\n"
              << "  \"seen_run_init\": " << (seen_run_init ? "true" : "false") << ",\n"
              << "  \"cyc_run_init\": " << cyc_run_init << ",\n"
              << "  \"seen_cpuinfo_pass\": " << (seen_cpuinfo_pass ? "true" : "false") << ",\n"
              << "  \"seen_affinity_pass\": " << (seen_affinity_pass ? "true" : "false") << ",\n"
              << "  \"seen_pthreads_pass\": " << (seen_pthreads_pass ? "true" : "false") << ",\n"
              << "  \"seen_busybox_pass\": " << (seen_busybox_pass ? "true" : "false") << ",\n"
              << "  \"seen_all_pass\": " << (seen_all_pass ? "true" : "false") << ",\n"
              << "  \"cyc_all_pass\": " << cyc_all_pass << ",\n"
              << "  \"seen_kernel_panic\": " << (seen_kernel_panic ? "true" : "false") << ",\n"
              << "  \"seen_oops\": " << (seen_oops ? "true" : "false") << ",\n"
              << "  \"seen_rcu_stall\": " << (seen_rcu_stall ? "true" : "false") << ",\n"
              << "  \"seen_sbi_trap\": " << (seen_sbi_trap ? "true" : "false") << ",\n"
              << "  \"seen_userspace_fail\": " << (seen_userspace_fail ? "true" : "false") << ",\n"
              << "  \"watchdog_triggered\": " << (watchdog_triggered ? "true" : "false") << ",\n"
              << "  \"per_hart_commits\": [";
    for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_commits[h];
    std::cout << "],\n  \"per_hart_ipc\": [";
    for (int h = 0; h < NUM_HARTS; h++) {
      std::cout << (h ? ", " : "") << std::fixed << std::setprecision(4)
                << (cycles > 0 ? double(hart_commits[h]) / double(cycles) : 0.0);
    }
    std::cout << "],\n  \"per_hart_smode_commits\": [";
    for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_smode_commits[h];
    std::cout << "],\n  \"per_hart_umode_commits\": [";
    for (int h = 0; h < NUM_HARTS; h++) std::cout << (h ? ", " : "") << hart_umode_commits[h];
    std::cout << "]\n}\n";
    return passed ? 0 : 1;
  } catch (const std::exception &e) {
    std::cerr << "[S2-M5 TB ERROR] " << e.what() << "\n";
    return 1;
  }
}
