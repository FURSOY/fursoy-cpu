// =============================================================================
// Fursoy Slice-1 Milestone 9 Closeout Verification Testbench
// =============================================================================
// Boots the genuine Linux 6.6.50 Image (embedded BusyBox initramfs) on the
// full fursoy_s1_soc RTL and checks the Gate G5 properties:
// - PROP_M9_27: SBI M-mode reset -> S-mode handoff -> Sv39 activation -> Linux
//               banner/earlycon -> "Run /init as init process" without panic.
// - PROP_M9_28: BusyBox /bin/sh userspace runs shell tests [TEST 01]..[TEST 20]
//               and reaches FURSOY_USERSPACE_PASS with U-mode ecalls observed.
// - PROP_M9_29: Userspace mem_stress under Sv39 demand paging
//               ([MEM_STRESS_START] -> [MEM_STRESS_PASS]) with page faults.
// - PROP_M9_30: Single-owner CPI conservation (sum C_k == mcycle) checked every
//               cycle of the boot, with HPM raw event activity observed.
//
// Observation is limited to SoC top-level ports (UART TX, retirement trace,
// CSR observability, HPM telemetry). No internal hierarchy or cache SRAM is
// accessed: DRAM responses are served from the testbench DRAM model only.
//
// Specification authority: docs/architecture/slice1-m9-soc-linux-v1.md v1.1 §6, §7.5, §8.5
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

#include "Vfursoy_s1_soc.h"
#include "verilated.h"

static constexpr uint64_t RAM_BASE    = 0x80000000ULL;
static constexpr uint64_t RAM_SIZE    = 256 * 1024 * 1024ULL; // 256 MiB platform DRAM
static constexpr uint64_t KERNEL_BASE = 0x80200000ULL;
static constexpr uint64_t DTB_BASE    = 0x82000000ULL;

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

static size_t load_raw_bin(const char *path, std::vector<uint8_t> &ram, uint64_t load_addr) {
  std::ifstream f(path, std::ios::binary);
  if (!f) throw std::runtime_error(std::string("Cannot open binary: ") + path);
  std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
  if (load_addr < RAM_BASE || load_addr - RAM_BASE + b.size() > RAM_SIZE) {
    throw std::runtime_error(std::string("Binary placement outside RAM aperture: ") + path);
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
  size_t total_loaded = 0;
  for (unsigned i = 0; i < count; i++) {
    size_t o = phoff + i * entsz;
    if (o + 56 > b.size()) throw std::runtime_error("Bad program header in ELF");
    if (get32(b, o) != 1) continue; // PT_LOAD segment
    uint64_t fileoff = get64(b, o + 8);
    uint64_t paddr   = get64(b, o + 24); // p_paddr
    uint64_t filesz  = get64(b, o + 32);
    uint64_t memsz   = get64(b, o + 40);
    if (paddr < RAM_BASE || memsz > RAM_SIZE || paddr - RAM_BASE > RAM_SIZE - memsz || fileoff + filesz > b.size()) {
      throw std::runtime_error("Segment placed outside RAM bounds");
    }
    std::memcpy(&ram[paddr - RAM_BASE], &b[fileoff], filesz);
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

// Fixed-size ring buffer of recently retired PCs (diagnostics only).
struct RetireRing {
  static constexpr size_t N = 64;
  std::array<uint64_t, N> pc{};
  std::array<uint8_t, N> priv{};
  size_t head = 0;
  size_t count = 0;
  void push(uint64_t p, uint8_t pr) {
    pc[head] = p;
    priv[head] = pr;
    head = (head + 1) % N;
    if (count < N) count++;
  }
  void dump(std::ostream &os, size_t last) const {
    size_t n = last < count ? last : count;
    for (size_t i = 0; i < n; i++) {
      size_t idx = (head + N - n + i) % N;
      os << "    pc=0x" << std::hex << pc[idx] << " priv=" << std::dec << int(priv[idx]) << "\n";
    }
  }
};

// Incremental console marker matcher over a bounded tail of UART output.
struct ConsoleMatcher {
  std::string tail;
  bool ends_with(const char *s) const {
    size_t n = std::strlen(s);
    return tail.size() >= n && tail.compare(tail.size() - n, n, s) == 0;
  }
  void push(char c) {
    tail.push_back(c);
    if (tail.size() > 512) tail.erase(0, tail.size() - 256);
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 4) {
    std::cerr << "Usage: " << argv[0] << " <fw_elf> <kernel_img> <dtb_bin> [halt_loop_pc] [max_cycles] [console_log]\n";
    return 1;
  }

  const char *fw_elf = argv[1];
  const char *kernel_img = argv[2];
  const char *dtb_bin = argv[3];
  uint64_t halt_loop_pc = (argc >= 5) ? std::stoull(argv[4], nullptr, 0) : 0ULL;
  uint64_t max_cycles = (argc >= 6) ? std::stoull(argv[5], nullptr, 0) : 150000000ULL;
  const char *console_log_path = (argc >= 7) ? argv[6] : nullptr;

  try {
    std::vector<uint8_t> ram(RAM_SIZE, 0);

    size_t fw_sz = load_elf(fw_elf, ram);                          // SBI at 0x8000_0000
    size_t kernel_sz = load_raw_bin(kernel_img, ram, KERNEL_BASE); // Linux Image at 0x8020_0000
    size_t dtb_sz = load_raw_bin(dtb_bin, ram, DTB_BASE);          // DTB at 0x8200_0000
    if (KERNEL_BASE + kernel_sz > DTB_BASE) {
      throw std::runtime_error("Kernel image overlaps with DTB aperture at 0x8200_0000");
    }

    std::cerr << "[TB] Firmware loaded: " << fw_sz << " bytes at 0x8000_0000\n"
              << "[TB] Kernel loaded:   " << kernel_sz << " bytes at 0x8020_0000\n"
              << "[TB] DTB loaded:      " << dtb_sz << " bytes at 0x8200_0000\n"
              << "[TB] Simulation DRAM: 256 MiB (0x8000_0000..0x8FFF_FFFF)\n"
              << "[TB] Max cycles:      " << max_cycles << "\n";

    std::ofstream console_log;
    if (console_log_path) console_log.open(console_log_path, std::ios::out | std::ios::trunc);

    Vfursoy_s1_soc dut;
    std::deque<DRAMInFlight> dram_rd_queue;

    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.frontend_en_i = 1; // Autonomous frontend active
    dut.irq_sources_i = 0;
    dut.irq_external_i = 0;

    dut.dram_req_ready_i = 1;
    dut.dram_rd_rsp_valid_i = 0;
    dut.dram_rd_rsp_mid_i = 0;
    dut.dram_rd_rsp_tag_i = 0;
    std::memset((void *)&dut.dram_rd_rsp_data_i, 0, sizeof(dut.dram_rd_rsp_data_i));
    dut.dram_rd_rsp_error_i = 0;
    dut.dram_wr_rsp_valid_i = 0;

    dut.test_csr_we_i = 0;
    dut.test_csr_addr_i = 0;
    dut.test_csr_wdata_i = 0;

    dut.uop0_valid_i = 0; dut.uop0_rs1_i = 0; dut.uop0_rs2_i = 0; dut.uop0_rd_i = 0;
    dut.uop0_class_i = 0; dut.uop0_subop_i = 0; dut.uop0_imm_i = 0; dut.uop0_use_imm_i = 0;
    dut.uop0_pc_i = 0;
    dut.uop1_valid_i = 0; dut.uop1_rs1_i = 0; dut.uop1_rs2_i = 0; dut.uop1_rd_i = 0;
    dut.uop1_class_i = 0; dut.uop1_subop_i = 0; dut.uop1_imm_i = 0; dut.uop1_use_imm_i = 0;
    dut.uop1_pc_i = 0;
    dut.probe_paddr_i = 0;
    dut.eval();

    for (int r = 0; r < 10; r++) {
      dut.clk_i = 1; dut.eval();
      dut.clk_i = 0; dut.eval();
    }
    dut.rst_i = 0;

    const auto wall_start = std::chrono::steady_clock::now();

    uint64_t cycles = 0;
    uint64_t commits = 0;
    uint64_t user_commits = 0;
    uint64_t last_commit_cycle = 0;
    uint64_t last_retire_pc = 0;
    RetireRing ring;
    ConsoleMatcher con;
    uint64_t uart_bytes = 0;

    // Milestones
    bool seen_reset_pc = false, seen_handoff_pc = false, seen_satp_sv39 = false, seen_virt_pc = false;
    bool seen_earlycon = false, seen_kernel_banner = false, seen_machine_model = false;
    bool seen_run_init = false, seen_init_banner = false, seen_userspace_begin = false;
    bool seen_mem_stress_start = false, seen_mem_stress_pass = false, seen_userspace_pass = false;
    bool seen_userspace_fail = false, seen_kernel_panic = false, seen_oops = false;
    uint32_t shell_tests_mask = 0; // bit n set when "[TEST nn]" printed (1..21)

    uint64_t cycle_handoff = 0, cycle_satp = 0, cycle_virt = 0, cycle_earlycon = 0;
    uint64_t cycle_run_init = 0, cycle_userspace_begin = 0, cycle_mem_stress_pass = 0, cycle_userspace_pass = 0;

    uint64_t page_faults_total = 0;      // causes 12, 13, 15
    uint64_t page_faults_user = 0;       // page faults raised while in U-mode
    uint64_t access_faults = 0;          // causes 1, 5, 7
    uint64_t user_ecalls = 0;            // cause 8
    uint64_t supervisor_ecalls = 0;      // cause 9 (SBI calls)
    uint64_t other_exceptions = 0;

    bool halted_srst = false, halted_pass = false, halted_fail = false, watchdog = false;
    uint64_t drain_cycles = 0;
    int halt_streak = 0;

    uint64_t cpi_checks = 0;
    uint64_t cpi_conservation_errors = 0;
    uint64_t hpm_event_mask_all[2] = {0, 0};  // union of raw_event_pulse_o over the boot
    uint64_t hpm_event_mask_user[2] = {0, 0}; // union while in U-mode

    bool pending_wr_rsp = false;

    while (cycles < max_cycles) {
      // 1. Falling clock edge: update registered DRAM response outputs for this cycle
      dut.clk_i = 0;
      dut.dram_wr_rsp_valid_i = pending_wr_rsp ? 1 : 0;
      pending_wr_rsp = false;

      if (!dram_rd_queue.empty() && dram_rd_queue.front().ready_cycle <= cycles) {
        DRAMInFlight rsp = dram_rd_queue.front();
        dram_rd_queue.pop_front();
        dut.dram_rd_rsp_valid_i = 1;
        dut.dram_rd_rsp_mid_i = rsp.mid;
        dut.dram_rd_rsp_tag_i = rsp.tag;
        dut.dram_rd_rsp_error_i = 0;
        uint64_t rsp_byte_addr = rsp.line_addr << 6;
        void *dst = (void *)&dut.dram_rd_rsp_data_i;
        if (rsp_byte_addr >= RAM_BASE && rsp_byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
          std::memcpy(dst, &ram[rsp_byte_addr - RAM_BASE], 64);
        } else {
          std::memset(dst, 0, 64);
          dut.dram_rd_rsp_error_i = 1;
        }
      } else {
        dut.dram_rd_rsp_valid_i = 0;
      }

      // 2. Settle all DUT combinational logic with stable inputs before sampling DRAM requests
      dut.eval();

      // 3. Synchronous DRAM request sampling immediately prior to posedge clk_i
      if (dut.dram_req_valid_o && dut.dram_req_ready_i) {
        uint64_t line_addr = dut.dram_req_addr_o;
        uint64_t byte_addr = line_addr << 6;
        if (dut.dram_req_write_o) {
          if (byte_addr >= RAM_BASE && byte_addr + 64 <= RAM_BASE + RAM_SIZE) {
            std::memcpy(&ram[byte_addr - RAM_BASE], (const void *)&dut.dram_req_wdata_o, 64);
          }
          pending_wr_rsp = true;
        } else {
          dram_rd_queue.push_back({line_addr, (uint8_t)dut.dram_req_mid_o, (uint8_t)dut.dram_req_tag_o, cycles + 1});
        }
      }

      // 4. Rising clock edge
      dut.clk_i = 1;
      dut.eval();

      const uint8_t priv = (uint8_t)dut.csr_priv_mode_o;

      // ---------------------------------------------------------------------
      // Console observation (UART TX)
      // ---------------------------------------------------------------------
      if (dut.uart_tx_valid_o) {
        char ch = char(dut.uart_tx_data_o);
        uart_bytes++;
        std::cout << ch;
        if (ch == '\n') std::cout << std::flush;
        if (console_log.is_open()) console_log << ch;
        con.push(ch);
        if (!seen_earlycon) { seen_earlycon = true; cycle_earlycon = cycles; }
        if (con.ends_with("Linux version 6.6.50")) seen_kernel_banner = true;
        if (con.ends_with("Machine model: Fursoy")) seen_machine_model = true;
        if (con.ends_with("Run /init as init process") && !seen_run_init) { seen_run_init = true; cycle_run_init = cycles; }
        if (con.ends_with("[INIT] Fursoy")) seen_init_banner = true;
        if (con.ends_with("FURSOY_USERSPACE_BEGIN") && !seen_userspace_begin) { seen_userspace_begin = true; cycle_userspace_begin = cycles; }
        if (con.ends_with("[MEM_STRESS_START]")) seen_mem_stress_start = true;
        if (con.ends_with("[MEM_STRESS_PASS]") && !seen_mem_stress_pass) { seen_mem_stress_pass = true; cycle_mem_stress_pass = cycles; }
        if (con.ends_with("FURSOY_USERSPACE_PASS") && !seen_userspace_pass) { seen_userspace_pass = true; cycle_userspace_pass = cycles; }
        if (con.ends_with("FURSOY_USERSPACE_FAIL")) seen_userspace_fail = true;
        if (con.ends_with("Kernel panic")) seen_kernel_panic = true;
        if (con.ends_with("Oops") || con.ends_with("Unable to handle kernel")) seen_oops = true;
        // "[TEST nn]" markers
        if (ch == ']' && con.tail.size() >= 9) {
          const std::string t = con.tail.substr(con.tail.size() - 9);
          if (t.compare(0, 6, "[TEST ") == 0 && isdigit((unsigned char)t[6]) && isdigit((unsigned char)t[7])) {
            int n = (t[6] - '0') * 10 + (t[7] - '0');
            if (n >= 1 && n <= 31) shell_tests_mask |= (1u << n);
          }
        }
      }

      // ---------------------------------------------------------------------
      // Retirement observation
      // ---------------------------------------------------------------------
      for (int s = 0; s < 2; s++) {
        if (!(dut.retire_valid_o & (1u << s))) continue;
        commits++;
        if (priv == 0) user_commits++;
        last_commit_cycle = cycles;
        uint64_t pc = dut.retire_pc_o[s];
        last_retire_pc = pc;
        ring.push(pc, priv);
        if (pc == 0x80000000ULL) seen_reset_pc = true;
        if (pc == KERNEL_BASE && !seen_handoff_pc) { seen_handoff_pc = true; cycle_handoff = cycles; }
        if (!seen_virt_pc && pc >= 0xffffffff80000000ULL) { seen_virt_pc = true; cycle_virt = cycles; }
      }

      if (!seen_satp_sv39 && ((dut.csr_satp_o >> 60) == 8)) { seen_satp_sv39 = true; cycle_satp = cycles; }

      if (dut.retire_exception_o) {
        uint8_t c = dut.retire_exc_cause_o;
        if (c == 12 || c == 13 || c == 15) {
          page_faults_total++;
          if (priv == 0) page_faults_user++;
        } else if (c == 1 || c == 5 || c == 7) {
          access_faults++;
        } else if (c == 8) {
          user_ecalls++;
        } else if (c == 9) {
          supervisor_ecalls++;
        } else {
          other_exceptions++;
        }
      }

      // ---------------------------------------------------------------------
      // PROP_M9_30: continuous single-owner CPI conservation + HPM activity
      // ---------------------------------------------------------------------
      {
        uint64_t cpi_sum = 0;
        for (int k = 0; k < 8; k++) cpi_sum += dut.cpi_category_o[k];
        cpi_checks++;
        if (cpi_sum != dut.mcycle_o) {
          if (cpi_conservation_errors < 8) {
            std::cerr << "[TB FATAL] CPI conservation violation at cycle " << cycles
                      << ": sum(C_0..7)=" << cpi_sum << " != mcycle=" << dut.mcycle_o << "\n";
          }
          cpi_conservation_errors++;
        }
        uint64_t lo = dut.raw_event_pulse_o;
        hpm_event_mask_all[0] |= lo;
        if (priv == 0) hpm_event_mask_user[0] |= lo;
      }

      // ---------------------------------------------------------------------
      // Termination
      // ---------------------------------------------------------------------
      if (seen_userspace_pass || seen_userspace_fail || seen_kernel_panic || seen_oops) {
        // Drain so trailing console lines finish transmitting.
        uint64_t drain_limit = seen_oops ? 400000ULL : 50000ULL;
        if (++drain_cycles > drain_limit) {
          halted_pass = seen_userspace_pass && !seen_userspace_fail && !seen_kernel_panic;
          halted_fail = !halted_pass;
          cycles++;
          break;
        }
      }
      if (halt_loop_pc != 0 && last_retire_pc == halt_loop_pc) {
        if (++halt_streak > 100) { halted_srst = true; cycles++; break; }
      }

      if (cycles > 0 && (cycles % 5000000 == 0)) {
        double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall_start).count();
        std::cerr << "[HEARTBEAT] cycle=" << std::dec << cycles << " commits=" << commits
                  << " pc=0x" << std::hex << last_retire_pc << std::dec
                  << " priv=" << int(priv) << " pgfaults=" << page_faults_total
                  << " uart_bytes=" << uart_bytes << " cpi_errs=" << cpi_conservation_errors
                  << " wall=" << std::fixed << std::setprecision(1) << secs << "s\n";
      }

      if (cycles > 1000 && !dut.wfi_sleep_o && (cycles - last_commit_cycle > 2000000)) {
        watchdog = true;
        std::cerr << "[TB WATCHDOG] No retirement for 2,000,000 cycles at cycle=" << std::dec << cycles
                  << " commits=" << commits << " last_pc=0x" << std::hex << last_retire_pc
                  << " rob_count=" << std::dec << int(dut.rob_count_o)
                  << " disp_rdy=" << int(dut.dispatch_ready_o)
                  << " raw_ev=0x" << std::hex << uint64_t(dut.raw_event_pulse_o)
                  << " satp=0x" << dut.csr_satp_o << " priv=" << std::dec << int(priv)
                  << " mcause=0x" << std::hex << dut.csr_mcause_o << " mepc=0x" << dut.csr_mepc_o
                  << " scause=0x" << dut.csr_scause_o << " sepc=0x" << dut.csr_sepc_o
                  << " stval=0x" << dut.csr_stval_o << std::dec << "\n";
        break;
      }

      cycles++;
    }

    std::cout << std::flush;
    std::cerr << "  [LAST 32 RETIRES]:\n";
    ring.dump(std::cerr, 32);

    auto popcount64 = [](uint64_t v) { int n = 0; while (v) { v &= v - 1; n++; } return n; };
    int hpm_events_active = popcount64(hpm_event_mask_all[0]);
    int hpm_events_active_user = popcount64(hpm_event_mask_user[0]);

    bool shell_tests_ok = true;
    int shell_tests_seen = 0;
    for (int n = 1; n <= 20; n++) {
      if (shell_tests_mask & (1u << n)) shell_tests_seen++;
      else shell_tests_ok = false;
    }
    const bool clean_kernel = !seen_kernel_panic && !seen_oops;

    bool prop_27_ok = seen_reset_pc && seen_handoff_pc && seen_satp_sv39 && seen_virt_pc &&
                      seen_earlycon && seen_kernel_banner && seen_machine_model && seen_run_init && clean_kernel;
    bool prop_28_ok = seen_init_banner && seen_userspace_begin && shell_tests_ok && seen_userspace_pass &&
                      !seen_userspace_fail && user_ecalls > 0 && user_commits > 0 && clean_kernel;
    bool prop_29_ok = seen_mem_stress_start && seen_mem_stress_pass && page_faults_user >= 10 &&
                      seen_userspace_pass && clean_kernel;
    bool prop_30_ok = (cpi_checks > 0) && (cpi_conservation_errors == 0) &&
                      hpm_events_active > 0 && hpm_events_active_user > 0;

    int total_props_passed = int(prop_27_ok) + int(prop_28_ok) + int(prop_29_ok) + int(prop_30_ok);
    bool all_passed = (total_props_passed == 4) && halted_pass && !watchdog;

    double wall_secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - wall_start).count();

    std::cout << "\n{\n"
              << "  \"status\": \"" << (all_passed ? "pass" : "fail") << "\",\n"
              << "  \"cycles\": " << cycles << ",\n"
              << "  \"commits\": " << commits << ",\n"
              << "  \"user_commits\": " << user_commits << ",\n"
              << "  \"wall_seconds\": " << std::fixed << std::setprecision(1) << wall_secs << ",\n"
              << "  \"properties_tested\": 4,\n"
              << "  \"properties_passed\": " << total_props_passed << ",\n"
              << "  \"prop_m9_27_linux_kernel_boot\": \"" << (prop_27_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"prop_m9_28_busybox_shell\": \"" << (prop_28_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"prop_m9_29_demand_paging_mem_stress\": \"" << (prop_29_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"prop_m9_30_cpi_conservation\": \"" << (prop_30_ok ? "PASS" : "FAIL") << "\",\n"
              << "  \"cpi_checks\": " << cpi_checks << ",\n"
              << "  \"cpi_conservation_errors\": " << cpi_conservation_errors << ",\n"
              << "  \"cpi_breakdown\": {\n"
              << "    \"C_serialize\": " << dut.cpi_category_o[0] << ",\n"
              << "    \"C_br_recover\": " << dut.cpi_category_o[1] << ",\n"
              << "    \"C_productive\": " << dut.cpi_category_o[2] << ",\n"
              << "    \"C_mem_stall\": " << dut.cpi_category_o[3] << ",\n"
              << "    \"C_be_rename\": " << dut.cpi_category_o[4] << ",\n"
              << "    \"C_be_sched\": " << dut.cpi_category_o[5] << ",\n"
              << "    \"C_fe_starve\": " << dut.cpi_category_o[6] << ",\n"
              << "    \"C_idle_other\": " << dut.cpi_category_o[7] << "\n"
              << "  },\n"
              << "  \"mcycle\": " << dut.mcycle_o << ",\n"
              << "  \"minstret\": " << dut.minstret_o << ",\n"
              << "  \"hpm_raw_events_active\": " << hpm_events_active << ",\n"
              << "  \"hpm_raw_events_active_user\": " << hpm_events_active_user << ",\n"
              << "  \"hpm_raw_event_mask\": \"0x" << std::hex << hpm_event_mask_all[0] << std::dec << "\",\n"
              << "  \"shell_tests_seen\": " << shell_tests_seen << ",\n"
              << "  \"seen_reset_pc\": " << (seen_reset_pc ? "true" : "false") << ",\n"
              << "  \"seen_handoff_pc\": " << (seen_handoff_pc ? "true" : "false") << ",\n"
              << "  \"seen_satp_sv39\": " << (seen_satp_sv39 ? "true" : "false") << ",\n"
              << "  \"seen_virt_pc\": " << (seen_virt_pc ? "true" : "false") << ",\n"
              << "  \"seen_earlycon\": " << (seen_earlycon ? "true" : "false") << ",\n"
              << "  \"seen_kernel_banner\": " << (seen_kernel_banner ? "true" : "false") << ",\n"
              << "  \"seen_machine_model\": " << (seen_machine_model ? "true" : "false") << ",\n"
              << "  \"seen_run_init\": " << (seen_run_init ? "true" : "false") << ",\n"
              << "  \"seen_init_banner\": " << (seen_init_banner ? "true" : "false") << ",\n"
              << "  \"seen_userspace_begin\": " << (seen_userspace_begin ? "true" : "false") << ",\n"
              << "  \"seen_mem_stress_start\": " << (seen_mem_stress_start ? "true" : "false") << ",\n"
              << "  \"seen_mem_stress_pass\": " << (seen_mem_stress_pass ? "true" : "false") << ",\n"
              << "  \"seen_userspace_pass\": " << (seen_userspace_pass ? "true" : "false") << ",\n"
              << "  \"seen_userspace_fail\": " << (seen_userspace_fail ? "true" : "false") << ",\n"
              << "  \"seen_kernel_panic\": " << (seen_kernel_panic ? "true" : "false") << ",\n"
              << "  \"seen_oops\": " << (seen_oops ? "true" : "false") << ",\n"
              << "  \"cycle_handoff\": " << cycle_handoff << ",\n"
              << "  \"cycle_satp\": " << cycle_satp << ",\n"
              << "  \"cycle_virt\": " << cycle_virt << ",\n"
              << "  \"cycle_earlycon\": " << cycle_earlycon << ",\n"
              << "  \"cycle_run_init\": " << cycle_run_init << ",\n"
              << "  \"cycle_userspace_begin\": " << cycle_userspace_begin << ",\n"
              << "  \"cycle_mem_stress_pass\": " << cycle_mem_stress_pass << ",\n"
              << "  \"cycle_userspace_pass\": " << cycle_userspace_pass << ",\n"
              << "  \"page_faults_total\": " << page_faults_total << ",\n"
              << "  \"page_faults_user\": " << page_faults_user << ",\n"
              << "  \"access_faults\": " << access_faults << ",\n"
              << "  \"user_ecalls\": " << user_ecalls << ",\n"
              << "  \"supervisor_ecalls\": " << supervisor_ecalls << ",\n"
              << "  \"other_exceptions\": " << other_exceptions << ",\n"
              << "  \"uart_bytes\": " << uart_bytes << ",\n"
              << "  \"halted_on_userspace_pass\": " << (halted_pass ? "true" : "false") << ",\n"
              << "  \"halted_on_failure_marker\": " << (halted_fail ? "true" : "false") << ",\n"
              << "  \"halted_on_srst\": " << (halted_srst ? "true" : "false") << ",\n"
              << "  \"watchdog_fired\": " << (watchdog ? "true" : "false") << "\n"
              << "}\n";

    return all_passed ? 0 : 1;

  } catch (const std::exception &e) {
    std::cerr << "[TB FATAL ERROR] " << e.what() << "\n";
    return 1;
  }
}
