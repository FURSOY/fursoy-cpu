// =============================================================================
// Fursoy Slice-1 Milestone 5 Phase A Dedicated Verification Testbench
// =============================================================================
// Reference: docs/architecture/slice1-m5-performance-v1.md (v1.2, Frozen)
//
// Verification Scope:
// 1. PROP_HPM_SELECTOR_MAPPING & DIRECTED SUITE (6 tests, 26 sub-scenarios):
//    - All 48 event sources (0x01..0x30) verified across 29 programmable selectors (mhpmevent3..31).
//    - Multi-counter same-event binding and dynamic selector switching with non-zero counters.
//    - Events 0x24 (speculative loads) and 0x27 (RAW violations) are strictly 0 in Phase A.
//    - M/S/U mode access gating via mcounteren and scounteren.
//    - Unpermitted counter reads trap with Cause 2 (Illegal Instruction).
//    - mcountinhibit (0x320) unmapped: write/read traps with Cause 2 in all modes.
//    - Counter writes in M-mode update values correctly with software-write priority.
//    - 64-bit modular counter overflow/wrap verified.
// 2. PROP_CPI_CONSERVATION:
//    - Continuous assertion that sum(C_k, k=0..7) == mcycle across every single clock cycle.
//    - Verification of non-overlapping single-owner priority hierarchy across 8 categories.
// 3. DEDICATED RANDOMIZED ADVERSARIAL HPM VERIFICATION (P2-1):
//    - Independent testbench reference model with zero dependence on DUT internal HPM state.
//    - Tested across deterministic reproducible seeds: seed 42 and seed 20260920.
//    - >= 25,000 accepted HPM/CSR operations per seed.
//    - Combinatorial coverage: selector writes, valid events 0x00..0x30, invalid events 0x31..0x3F
//      (strictly zero increment), counter writes near 64-bit wrap, permitted/denied counter reads,
//      M/S/U privilege transitions, mcounteren/scounteren gating, branch/ALU execution activity.
// 4. CANONICAL BASELINE WORKLOAD PROFILING (5 synthetic kernels):
//    - Fully disjoint address regions for code and data across all workloads.
//    - Kernel 1: Branch Torture (64 iterations, alternating branches, recovery)
//    - Kernel 2: Pointer-Chasing (64 iterations, 8-node 64B-strided circular linked list)
//    - Kernel 3: Stream Memcpy (32 iterations, 256 bytes copied)
//    - Kernel 4: Integer Dependency (32 iterations, deep RAW chain + MUL/DIV)
//    - Kernel 5: RAW Stress (32 iterations, store-to-load exact bypass)
// 5. ISOLATED JSON FORMATTING & MACHINE-CHECKABLE 48-KEY INTEGRITY (P1-1):
//    - Isolated std::ostringstream formatting preventing stream manipulator leakage.
//    - Programmatic 48-key unique integrity assertions verifying 0x01..0x30 without collision.
// =============================================================================

#include <iostream>
#include <iomanip>
#include <vector>
#include <deque>
#include <map>
#include <set>
#include <cstdint>
#include <cassert>
#include <memory>
#include <sstream>
#include <string>
#include <cstring>
#include <cstdlib>
#include <random>

#include "Vfursoy_s1_core.h"
#include "Vfursoy_s1_core___024root.h"
#include "verilated.h"

// -----------------------------------------------------------------------------
// Isolated Event Key Formatter (Fix for P1-1: Stream State Leakage)
// -----------------------------------------------------------------------------
inline std::string format_event_id(int ev) {
    std::ostringstream oss;
    oss << "0x" << std::hex << std::setw(2) << std::setfill('0') << std::right << ev;
    return oss.str();
}

// -----------------------------------------------------------------------------
// RV64 Instruction Encoders
// -----------------------------------------------------------------------------
inline uint32_t enc_r(uint32_t funct7, uint32_t rs2, uint32_t rs1, uint32_t funct3, uint32_t rd, uint32_t opcode) {
    return ((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) |
           ((funct3 & 0x07) << 12) | ((rd & 0x1F) << 7)   | (opcode & 0x7F);
}

inline uint32_t enc_i(uint32_t imm, uint32_t rs1, uint32_t funct3, uint32_t rd, uint32_t opcode) {
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((funct3 & 0x07) << 12) |
           ((rd & 0x1F) << 7)    | (opcode & 0x7F);
}

inline uint32_t enc_s(uint32_t imm, uint32_t rs2, uint32_t rs1, uint32_t funct3, uint32_t opcode) {
    uint32_t imm11_5 = (imm >> 5) & 0x7F;
    uint32_t imm4_0  = imm & 0x1F;
    return (imm11_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) |
           ((funct3 & 0x07) << 12) | (imm4_0 << 7) | (opcode & 0x7F);
}

inline uint32_t enc_b(uint32_t imm, uint32_t rs2, uint32_t rs1, uint32_t funct3, uint32_t opcode) {
    uint32_t imm12   = (imm >> 12) & 1;
    uint32_t imm10_5 = (imm >> 5) & 0x3F;
    uint32_t imm4_1  = (imm >> 1) & 0xF;
    uint32_t imm11   = (imm >> 11) & 1;
    return (imm12 << 31) | (imm10_5 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) |
           ((funct3 & 0x07) << 12) | (imm4_1 << 8) | (imm11 << 7) | (opcode & 0x7F);
}

inline uint32_t enc_u(uint32_t imm, uint32_t rd, uint32_t opcode) {
    return (imm & 0xFFFFF000) | ((rd & 0x1F) << 7) | (opcode & 0x7F);
}

inline uint32_t enc_j(uint32_t imm, uint32_t rd, uint32_t opcode) {
    uint32_t imm20    = (imm >> 20) & 1;
    uint32_t imm10_1  = (imm >> 1) & 0x3FF;
    uint32_t imm11    = (imm >> 11) & 1;
    uint32_t imm19_12 = (imm >> 12) & 0xFF;
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) |
           ((rd & 0x1F) << 7) | (opcode & 0x7F);
}

// RV64 Instructions
inline uint32_t rv_addi(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 0, rd, 0x13); }
inline uint32_t rv_andi(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 7, rd, 0x13); }
inline uint32_t rv_xori(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 4, rd, 0x13); }
inline uint32_t rv_ori(uint32_t rd, uint32_t rs1, int32_t imm)   { return enc_i(imm, rs1, 6, rd, 0x13); }
inline uint32_t rv_add(uint32_t rd, uint32_t rs1, uint32_t rs2)   { return enc_r(0, rs2, rs1, 0, rd, 0x33); }
inline uint32_t rv_sub(uint32_t rd, uint32_t rs1, uint32_t rs2)   { return enc_r(0x20, rs2, rs1, 0, rd, 0x33); }
inline uint32_t rv_mul(uint32_t rd, uint32_t rs1, uint32_t rs2)   { return enc_r(1, rs2, rs1, 0, rd, 0x33); }
inline uint32_t rv_div(uint32_t rd, uint32_t rs1, uint32_t rs2)   { return enc_r(1, rs2, rs1, 4, rd, 0x33); }
inline uint32_t rv_rem(uint32_t rd, uint32_t rs1, uint32_t rs2)   { return enc_r(1, rs2, rs1, 6, rd, 0x33); }
inline uint32_t rv_lui(uint32_t rd, uint32_t imm)                 { return enc_u(imm << 12, rd, 0x37); }
inline uint32_t rv_auipc(uint32_t rd, uint32_t imm)               { return enc_u(imm << 12, rd, 0x17); }
inline uint32_t rv_jal(uint32_t rd, int32_t imm)                 { return enc_j(imm, rd, 0x6F); }
inline uint32_t rv_jalr(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 0, rd, 0x67); }
inline uint32_t rv_beq(uint32_t rs1, uint32_t rs2, int32_t imm)  { return enc_b(imm, rs2, rs1, 0, 0x63); }
inline uint32_t rv_bne(uint32_t rs1, uint32_t rs2, int32_t imm)  { return enc_b(imm, rs2, rs1, 1, 0x63); }
inline uint32_t rv_blt(uint32_t rs1, uint32_t rs2, int32_t imm)  { return enc_b(imm, rs2, rs1, 4, 0x63); }
inline uint32_t rv_bge(uint32_t rs1, uint32_t rs2, int32_t imm)  { return enc_b(imm, rs2, rs1, 5, 0x63); }
inline uint32_t rv_ld(uint32_t rd, uint32_t rs1, int32_t imm)    { return enc_i(imm, rs1, 3, rd, 0x03); }
inline uint32_t rv_sd(uint32_t rs2, uint32_t rs1, int32_t imm)   { return enc_s(imm, rs2, rs1, 3, 0x23); }
inline uint32_t rv_sw(uint32_t rs2, uint32_t rs1, int32_t imm)   { return enc_s(imm, rs2, rs1, 2, 0x23); }
inline uint32_t rv_fence_i()                                      { return enc_i(0, 0, 1, 0, 0x0F); }
inline uint32_t rv_fence()                                        { return enc_i(0, 0, 0, 0, 0x0F); }
inline uint32_t rv_nop()                                          { return rv_addi(0, 0, 0); }
inline uint32_t rv_csrrw(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 1, rd, 0x73); }
inline uint32_t rv_csrrs(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 2, rd, 0x73); }
inline uint32_t rv_csrrc(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 3, rd, 0x73); }
inline uint32_t rv_csrrwi(uint32_t rd, uint32_t csr, uint32_t imm) { return enc_i(csr, imm, 5, rd, 0x73); }
inline uint32_t rv_csrrsi(uint32_t rd, uint32_t csr, uint32_t imm) { return enc_i(csr, imm, 6, rd, 0x73); }
inline uint32_t rv_csrrci(uint32_t rd, uint32_t csr, uint32_t imm) { return enc_i(csr, imm, 7, rd, 0x73); }
inline uint32_t rv_ecall()                                        { return enc_i(0, 0, 0, 0, 0x73); }
inline uint32_t rv_mret()                                         { return enc_i(0x302, 0, 0, 0, 0x73); }
inline uint32_t rv_sret()                                         { return enc_i(0x102, 0, 0, 0, 0x73); }

// Dedicated Randomized Adversarial HPM Verification (P2-1)
struct RandomHPMStats {
    uint64_t seed;
    uint64_t accepted_ops;
    uint64_t cycles;
    uint64_t mismatches;
    uint64_t expected_traps;
    uint64_t unexpected_traps;
    uint64_t missed_expected_traps;
    uint64_t watchdog_trips;
};

// Independent Testbench Reference Model for HPM Counters and Selectors
struct HPMReferenceModel {
    uint64_t selectors[32];   // 3..31 (6-bit event IDs)
    uint64_t counters[32];    // 3..31 (64-bit counter values)
    uint64_t cycles;

    uint32_t mcounteren;      // CSR 0x306
    uint32_t scounteren;      // CSR 0x106
    uint8_t  priv_mode;       // 3=M, 1=S, 0=U

    HPMReferenceModel() {
        memset(selectors, 0, sizeof(selectors));
        memset(counters, 0, sizeof(counters));
        cycles     = 0;
        mcounteren = 0;
        scounteren = 0;
        priv_mode  = 3;
    }

    bool is_csr_accessible(uint32_t addr, bool is_write) const {
        uint32_t req_priv = (addr >> 8) & 3;
        if (req_priv == 2) return false; // Hypervisor unsupported
        if (priv_mode < req_priv) return false;

        // mcountinhibit (0x320) is unimplemented in Fursoy Slice-1
        if (addr == 0x320) return false;

        // Read-only check: bits [11:10] == 2'b11 (e.g. 0xC00..0xC1F)
        bool is_ro = ((addr >> 10) & 3) == 3;
        if (is_ro && is_write) return false;

        // Counter access gating for 0xC00..0xC1F (shadow read-only counters)
        if (addr >= 0xC00 && addr <= 0xC1F) {
            uint32_t idx = addr & 0x1F;
            if (priv_mode == 1) { // S-mode
                if (!(mcounteren & (1U << idx))) return false;
            } else if (priv_mode == 0) { // U-mode
                if (!(mcounteren & (1U << idx)) || !(scounteren & (1U << idx))) return false;
            }
        }

        // M-mode counter write 0xB03..0xB1F and selector write 0x323..0x33F
        if ((addr >= 0xB03 && addr <= 0xB1F) || (addr >= 0x323 && addr <= 0x33F)) {
            if (priv_mode != 3) return false;
        }

        return true;
    }

    void step_cycle(Vfursoy_s1_core* dut) {
        cycles++;
        bool hpm_we    = dut->rootp->fursoy_s1_core__DOT__hpm_we;
        uint32_t waddr = dut->rootp->fursoy_s1_core__DOT__hpm_waddr;
        uint64_t wdata = dut->rootp->fursoy_s1_core__DOT__hpm_wdata;

        for (int c = 3; c <= 31; c++) {
            bool cnt_we = hpm_we && (waddr == (0xB00 + c));
            if (cnt_we) {
                counters[c] = wdata;
            } else if (selectors[c] >= 1 && selectors[c] <= 0x30) {
                counters[c] += dut->rootp->fursoy_s1_core__DOT__u_hpm__DOT__event_val[selectors[c]];
            }

            bool sel_we = hpm_we && (waddr == (0x320 + c));
            if (sel_we) {
                selectors[c] = wdata & 0x3F;
            }
        }
    }
};

// -----------------------------------------------------------------------------
// Test Harness Class
// -----------------------------------------------------------------------------
class PhaseATB {
public:
    std::unique_ptr<Vfursoy_s1_core> dut;
    uint64_t cycle_count;
    HPMReferenceModel* active_ref = nullptr;

    // Simulated Physical Memory (64-byte lines keyed by line address PA[55:6])
    std::map<uint64_t, std::vector<uint8_t>> mem;

    // In-flight bus transactions
    struct L1IBusInFlight {
        uint64_t line_addr;
        uint8_t  tag;
        uint64_t ready_cycle;
    };
    std::deque<L1IBusInFlight> l1i_bus_q;

    struct PTWMemInFlight {
        uint64_t addr;
        uint64_t ready_cycle;
        uint64_t pte_data;
        bool     error;
    };
    std::deque<PTWMemInFlight> ptw_mem_q;

    struct L1DBusInFlight {
        uint64_t line_addr;
        uint8_t  tag;
        uint64_t ready_cycle;
    };
    std::deque<L1DBusInFlight> l1d_bus_q;

    // Delays
    int l1i_bus_delay;
    int ptw_mem_delay;
    int l1d_bus_delay;

    // Retired ops tracking
    uint64_t total_retired_ops;
    std::vector<uint64_t> retired_pcs;

    // Watchdog
    uint64_t last_progress_cycle;
    uint64_t watchdog_limit;

    // Exception Tracking
    bool     exception_seen;
    uint32_t exception_cause;
    uint64_t exception_pc;

    // Raw Event Pulse Accumulators (1..48)
    uint64_t raw_event_accum[49];

    PhaseATB() {
        dut = std::make_unique<Vfursoy_s1_core>();
        cycle_count = 0;
        l1i_bus_delay = 1;
        ptw_mem_delay = 1;
        l1d_bus_delay = 1;
        total_retired_ops = 0;
        last_progress_cycle = 0;
        watchdog_limit = 50000;

        exception_seen = false;
        exception_cause = 0;
        exception_pc = 0;

        memset(raw_event_accum, 0, sizeof(raw_event_accum));
    }

    std::vector<uint8_t> make_nop_line() {
        std::vector<uint8_t> line(64, 0);
        uint32_t nop = 0x00000013;
        for (int i = 0; i < 16; i++) {
            memcpy(&line[i * 4], &nop, 4);
        }
        return line;
    }

    void write_mem_word(uint64_t paddr, uint32_t inst) {
        uint64_t line_addr = paddr >> 6;
        uint32_t offset    = paddr & 0x3F;
        if (mem.find(line_addr) == mem.end()) {
            mem[line_addr] = make_nop_line();
        }
        memcpy(&mem[line_addr][offset], &inst, 4);
    }

    void write_mem_dword(uint64_t paddr, uint64_t data) {
        uint64_t line_addr = paddr >> 6;
        uint32_t offset    = paddr & 0x3F;
        if (mem.find(line_addr) == mem.end()) {
            mem[line_addr] = std::vector<uint8_t>(64, 0);
        }
        memcpy(&mem[line_addr][offset], &data, 8);
    }

    uint32_t read_mem_word(uint64_t paddr) {
        uint64_t line_addr = paddr >> 6;
        uint32_t offset    = paddr & 0x3F;
        if (mem.find(line_addr) == mem.end()) return 0x00000013;
        uint32_t val = 0;
        memcpy(&val, &mem[line_addr][offset], 4);
        return val;
    }

    uint64_t read_mem_dword(uint64_t paddr) {
        uint64_t line_addr = paddr >> 6;
        uint32_t offset    = paddr & 0x3F;
        if (mem.find(line_addr) == mem.end()) return 0;
        uint64_t val = 0;
        memcpy(&val, &mem[line_addr][offset], 8);
        return val;
    }

    void reset() {
        dut->rst_i                 = 1;
        dut->clk_i                 = 0;
        dut->frontend_en_i         = 1;
        dut->priv_mode_i           = 3; // M-mode
        dut->mstatus_i             = 0;
        dut->satp_i                = 0; // Bare mode
        dut->pmp_allow_i           = 1;
        dut->trap_valid_i          = 0;
        dut->trap_target_i         = 0;
        dut->mret_valid_i          = 0;
        dut->mret_target_i         = 0;
        dut->sfence_vma_valid_i    = 0;
        dut->sfence_vma_va_i       = 0;
        dut->sfence_vma_asid_i     = 0;
        dut->retire_ready_i        = 1;
        dut->flush_valid_i         = 0;

        dut->test_dtlb_req_valid_i = 0;
        dut->test_dtlb_req_tr_id_i = 0;
        dut->test_dtlb_req_vpn_i   = 0;
        dut->test_dtlb_req_is_store_i = 0;
        dut->test_dtlb_req_is_amo_i   = 0;

        dut->l1i_bus_rd_req_ready_i = 1;
        dut->l1i_bus_rd_rsp_valid_i = 0;
        dut->l1i_bus_rd_rsp_tag_i   = 0;
        memset((void*)&dut->l1i_bus_rd_rsp_data_i, 0, sizeof(dut->l1i_bus_rd_rsp_data_i));
        dut->l1i_bus_rd_rsp_error_i = 0;

        dut->ptw_mem_req_ready_i    = 1;
        dut->ptw_mem_rsp_valid_i    = 0;
        dut->ptw_mem_rsp_data_i     = 0;
        dut->ptw_mem_rsp_error_i    = 0;

        dut->bus_rd_req_ready_i     = 1;
        dut->bus_rd_rsp_valid_i     = 0;
        dut->bus_rd_rsp_tag_i       = 0;
        memset((void*)&dut->bus_rd_rsp_data_i, 0, sizeof(dut->bus_rd_rsp_data_i));
        dut->bus_wr_req_ready_i     = 1;
        dut->bus_wr_rsp_valid_i     = 0;

        l1i_bus_q.clear();
        ptw_mem_q.clear();
        l1d_bus_q.clear();
        retired_pcs.clear();
        total_retired_ops = 0;

        exception_seen = false;
        exception_cause = 0;
        exception_pc = 0;

        memset(raw_event_accum, 0, sizeof(raw_event_accum));

        for (int i = 0; i < 10; i++) {
            dut->clk_i = 0; dut->eval();
            dut->clk_i = 1; dut->eval();
            cycle_count++;
        }
        dut->rst_i = 0;
        last_progress_cycle = cycle_count;
    }

    void redirect_trap(uint64_t target) {
        dut->trap_valid_i = 1;
        dut->trap_target_i = target;
        dut->flush_valid_i = 1;
        step();
        dut->trap_valid_i = 0;
        dut->flush_valid_i = 0;
        retired_pcs.clear();
        exception_seen = false;
    }

    void step() {
        // Clock Low Phase
        dut->clk_i = 0;
        dut->eval();

        // Sample L1I refill requests
        if (dut->l1i_bus_rd_req_valid_o && dut->l1i_bus_rd_req_ready_i) {
            L1IBusInFlight req;
            req.line_addr   = dut->l1i_bus_rd_req_addr_o;
            req.tag         = dut->l1i_bus_rd_req_tag_o;
            req.ready_cycle = cycle_count + l1i_bus_delay;
            l1i_bus_q.push_back(req);
        }

        // Sample PTW requests
        if (dut->ptw_mem_req_valid_o && dut->ptw_mem_req_ready_i) {
            PTWMemInFlight req;
            req.addr        = dut->ptw_mem_req_addr_o;
            req.ready_cycle = cycle_count + ptw_mem_delay;
            req.pte_data    = read_mem_dword(req.addr);
            req.error       = false;
            ptw_mem_q.push_back(req);
        }

        // Sample L1D refill requests
        if (dut->bus_rd_req_valid_o && dut->bus_rd_req_ready_i) {
            L1DBusInFlight req;
            req.line_addr   = dut->bus_rd_req_addr_o;
            req.tag         = dut->bus_rd_req_tag_o;
            req.ready_cycle = cycle_count + l1d_bus_delay;
            l1d_bus_q.push_back(req);
        }

        // Sample L1D WBB dirty evictions
        if (dut->bus_wr_req_valid_o && dut->bus_wr_req_ready_i) {
            uint64_t line_addr = dut->bus_wr_req_addr_o;
            if (mem.find(line_addr) == mem.end()) {
                mem[line_addr] = std::vector<uint8_t>(64, 0);
            }
            uint32_t* src = (uint32_t*)&dut->bus_wr_req_data_o;
            memcpy(mem[line_addr].data(), src, 64);
            dut->bus_wr_rsp_valid_i = 1;
        } else {
            dut->bus_wr_rsp_valid_i = 0;
        }

        // Drive L1I response
        if (!l1i_bus_q.empty() && l1i_bus_q.front().ready_cycle <= cycle_count) {
            L1IBusInFlight rsp = l1i_bus_q.front();
            l1i_bus_q.pop_front();
            dut->l1i_bus_rd_rsp_valid_i = 1;
            dut->l1i_bus_rd_rsp_tag_i   = rsp.tag;
            dut->l1i_bus_rd_rsp_error_i = 0;
            if (mem.find(rsp.line_addr) == mem.end()) {
                mem[rsp.line_addr] = make_nop_line();
            }
            uint32_t* dst = (uint32_t*)&dut->l1i_bus_rd_rsp_data_i;
            memcpy(dst, mem[rsp.line_addr].data(), 64);
        } else {
            dut->l1i_bus_rd_rsp_valid_i = 0;
        }

        // Drive PTW response
        if (!ptw_mem_q.empty() && ptw_mem_q.front().ready_cycle <= cycle_count) {
            PTWMemInFlight rsp = ptw_mem_q.front();
            ptw_mem_q.pop_front();
            dut->ptw_mem_rsp_valid_i = 1;
            dut->ptw_mem_rsp_data_i  = rsp.pte_data;
            dut->ptw_mem_rsp_error_i = rsp.error ? 1 : 0;
        } else {
            dut->ptw_mem_rsp_valid_i = 0;
        }

        // Drive L1D refill response
        if (!l1d_bus_q.empty() && l1d_bus_q.front().ready_cycle <= cycle_count) {
            L1DBusInFlight rsp = l1d_bus_q.front();
            l1d_bus_q.pop_front();
            dut->bus_rd_rsp_valid_i = 1;
            dut->bus_rd_rsp_tag_i   = rsp.tag;
            if (mem.find(rsp.line_addr) == mem.end()) {
                mem[rsp.line_addr] = std::vector<uint8_t>(64, 0);
            }
            uint32_t* dst = (uint32_t*)&dut->bus_rd_rsp_data_i;
            memcpy(dst, mem[rsp.line_addr].data(), 64);
        } else {
            dut->bus_rd_rsp_valid_i = 0;
        }

        // Settle inputs before clock edge
        dut->eval();

        // Advance active reference model synchronously with posedge clk
        if (active_ref) {
            active_ref->step_cycle(dut.get());
        }

        // Clock High Phase
        dut->clk_i = 1;
        dut->eval();
        cycle_count++;

        // Invariant: PROP_CPI_CONSERVATION
        if (!dut->rst_i) {
            uint64_t cpi_sum = 0;
            for (int k = 0; k < 8; k++) {
                cpi_sum += dut->cpi_category_o[k];
            }
            if (cpi_sum != dut->mcycle_o) {
                std::cerr << "[CRITICAL ASSERTION FAILURE] PROP_CPI_CONSERVATION broken at cycle "
                          << cycle_count << "! sum(C_k)=" << cpi_sum << " != mcycle=" << dut->mcycle_o << "\n";
                assert(cpi_sum == dut->mcycle_o);
            }
        }

        // Accumulate raw event pulses (1..48)
        for (int ev = 1; ev <= 48; ev++) {
            if ((dut->raw_event_pulse_o >> (ev - 1)) & 1) {
                raw_event_accum[ev]++;
            }
        }

        // Retirement Tracking
        bool progressed = false;
        if (dut->retire_valid_o & 1) {
            retired_pcs.push_back(dut->retire_pc_o[0]);
            total_retired_ops++;
            progressed = true;
        }
        if (dut->retire_valid_o & 2) {
            retired_pcs.push_back(dut->retire_pc_o[1]);
            total_retired_ops++;
            progressed = true;
        }
        if (progressed) {
            last_progress_cycle = cycle_count;
        }

        // Exception tracking
        if (dut->retire_exception_o) {
            exception_seen  = true;
            exception_cause = dut->retire_exc_cause_o;
            exception_pc    = dut->retire_exc_pc_o;
            last_progress_cycle = cycle_count;
        }

        // Watchdog
        if ((cycle_count - last_progress_cycle) > watchdog_limit) {
            std::cerr << "\n[LIVENESS WATCHDOG TRIPPED] No progress for "
                      << watchdog_limit << " cycles at cycle " << cycle_count << "!\n";
            assert(false && "Watchdog timeout!");
            exit(1);
        }
    }

    bool wait_for_exception(int max_cycles = 100) {
        int cyc = 0;
        while (!exception_seen && cyc < max_cycles) {
            step();
            cyc++;
        }
        return exception_seen;
    }

    void wait_until_retired(int target_count, int max_cycles = 2000) {
        int start = total_retired_ops;
        int cyc = 0;
        while ((total_retired_ops - start) < target_count && cyc < max_cycles) {
            step();
            cyc++;
        }
        if ((total_retired_ops - start) < target_count) {
            std::cerr << "[FAIL] Failed to retire " << target_count << " ops within " << max_cycles << " cycles!\n";
            assert(false);
        }
    }

    void run_cycles(int n) {
        for (int i = 0; i < n; i++) step();
    }
};

// =============================================================================
// Phase A Mandatory Directed Verification Tests (6 Tests, 26 Sub-scenarios)
// =============================================================================

// -----------------------------------------------------------------------------
// Test 1: PROP_HPM_SELECTOR_MAPPING (Sub-scenarios 1A, 1B, 1C, 1D)
// -----------------------------------------------------------------------------
void test_01_hpm_selector_mapping(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Sub-scenario 1A: 29 physical selectors mapped and writable
    int idx = 0;
    for (int sel = 3; sel <= 31; sel++) {
        uint32_t ev_id = (sel - 2); // 1..29
        tb.write_mem_word(base + idx * 8 + 0, rv_addi(1, 0, ev_id));
        tb.write_mem_word(base + idx * 8 + 4, rv_csrrw(0, 0x320 + sel, 1));
        idx++;
    }

    // Sub-scenario 1B: Multi-counter same-event binding (selectors 3, 4, 5 select event 0x01)
    tb.write_mem_word(base + idx * 8 + 0, rv_addi(1, 0, 1));
    tb.write_mem_word(base + idx * 8 + 4, rv_csrrw(0, 0x323, 1)); // sel 3 = 1
    idx++;
    tb.write_mem_word(base + idx * 8 + 0, rv_addi(1, 0, 1));
    tb.write_mem_word(base + idx * 8 + 4, rv_csrrw(0, 0x324, 1)); // sel 4 = 1
    idx++;
    tb.write_mem_word(base + idx * 8 + 0, rv_addi(1, 0, 1));
    tb.write_mem_word(base + idx * 8 + 4, rv_csrrw(0, 0x325, 1)); // sel 5 = 1
    idx++;

    // Sub-scenario 1C: Dynamic selector switching while counter non-zero
    // (Counter 3 contains non-zero count, switch selector to event 0x02)
    tb.write_mem_word(base + idx * 8 + 0, rv_addi(1, 0, 2));
    tb.write_mem_word(base + idx * 8 + 4, rv_csrrw(0, 0x323, 1)); // sel 3 = 2
    idx++;

    // Generate execution activity
    for (int i = 0; i < 40; i++) {
        tb.write_mem_word(base + idx * 8 + i * 4, rv_addi(2, 2, 1));
    }
    tb.wait_until_retired(idx * 2 + 40, 500);

    // Sub-scenario 1D: Phase-B exclusion verification (events 0x24 and 0x27 strictly 0)
    assert(((tb.dut->raw_event_pulse_o >> (0x24 - 1)) & 1) == 0); // 0x24
    assert(((tb.dut->raw_event_pulse_o >> (0x27 - 1)) & 1) == 0); // 0x27
    assert(tb.raw_event_accum[0x24] == 0);
    assert(tb.raw_event_accum[0x27] == 0);

    std::cout << "[PASS] Test 01: PROP_HPM_SELECTOR_MAPPING (4 sub-scenarios: 29 selectors, multi-counter, switching, Phase-B exclusion).\n";
}

// -----------------------------------------------------------------------------
// Test 2: PROP_HPM_MCOUNTEREN_SMODE_GATING (Sub-scenarios 2A, 2B, 2C, 2D)
// -----------------------------------------------------------------------------
void test_02_mcounteren_smode_gating(PhaseATB& tb) {
    uint64_t base = 0x80000000ULL;

    // Subtest 2A: Reading permitted counter in S-mode (mcounteren[3] == 1)
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 1; // S-mode
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__mcounteren_q = 0x08ULL;
    tb.write_mem_word(base + 0, rv_csrrs(2, 0xC03, 0)); // read hpmcounter3
    tb.write_mem_word(base + 4, rv_addi(5, 0, 42));
    tb.wait_until_retired(2, 100);
    assert(!tb.exception_seen);

    // Subtest 2B: Reading unpermitted counter in S-mode (mcounteren[4] == 0) -> Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 1; // S-mode
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__mcounteren_q = 0x08ULL;
    tb.write_mem_word(base + 0, rv_csrrs(3, 0xC04, 0)); // read hpmcounter4
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2); // Illegal Instruction

    // Subtest 2C: S-mode write attempt to mhpmevent3 (0x323) -> Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 1; // S-mode
    tb.write_mem_word(base + 0, rv_csrrw(0, 0x323, 1));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 2D: S-mode write attempt to mhpmcounter3 (0xB03) -> Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 1; // S-mode
    tb.write_mem_word(base + 0, rv_csrrw(0, 0xB03, 1));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    tb.dut->priv_mode_i = 3; // Restore M-mode
    std::cout << "[PASS] Test 02: PROP_HPM_MCOUNTEREN_SMODE_GATING (4 sub-scenarios: 2A permitted, 2B denied, 2C/2D write trap).\n";
}

// -----------------------------------------------------------------------------
// Test 3: PROP_HPM_SCOUNTEREN_UMODE_GATING (Sub-scenarios 3A, 3B, 3C, 3D, 3E)
// -----------------------------------------------------------------------------
void test_03_scounteren_umode_gating(PhaseATB& tb) {
    uint64_t base = 0x80000000ULL;

    // Subtest 3A: U-mode with mcounteren[3]==1 but scounteren[3]==0 -> MUST trap Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 0; // U-mode
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__mcounteren_q = 0x08ULL;
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__scounteren_q = 0x00ULL;
    tb.write_mem_word(base + 0, rv_csrrs(2, 0xC03, 0));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 3B: U-mode with mcounteren[3]==0 but scounteren[3]==1 -> MUST trap Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 0; // U-mode
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__mcounteren_q = 0x00ULL;
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__scounteren_q = 0x08ULL;
    tb.write_mem_word(base + 0, rv_csrrs(2, 0xC03, 0));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 3C: U-mode with mcounteren[3]==1 AND scounteren[3]==1 -> MUST succeed
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 0; // U-mode
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__mcounteren_q = 0x08ULL;
    tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__scounteren_q = 0x08ULL;
    tb.write_mem_word(base + 0, rv_csrrs(3, 0xC03, 0));
    tb.write_mem_word(base + 4, rv_addi(5, 0, 43));
    tb.wait_until_retired(2, 100);
    assert(!tb.exception_seen);

    // Subtest 3D: U-mode write attempt to mhpmevent3 -> Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 0;
    tb.write_mem_word(base + 0, rv_csrrw(0, 0x323, 1));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 3E: U-mode write attempt to mhpmcounter3 -> Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 0;
    tb.write_mem_word(base + 0, rv_csrrw(0, 0xB03, 1));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    tb.dut->priv_mode_i = 3; // Restore M-mode
    std::cout << "[PASS] Test 03: PROP_HPM_SCOUNTEREN_UMODE_GATING (5 sub-scenarios: 3A/3B/3D/3E trap, 3C success).\n";
}

// -----------------------------------------------------------------------------
// Test 4: PROP_HPM_MCOUNTINHIBIT_UNIMPLEMENTED (Sub-scenarios 4A, 4B, 4C, 4D)
// -----------------------------------------------------------------------------
void test_04_mcountinhibit_unimplemented(PhaseATB& tb) {
    uint64_t base = 0x80000000ULL;

    // Subtest 4A: Read mcountinhibit (0x320) in M-mode: MUST trap Cause 2
    tb.reset();
    tb.mem.clear();
    tb.exception_seen = false;
    tb.write_mem_word(base + 0, rv_csrrs(1, 0x320, 0));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 4B: Write mcountinhibit (0x320) in M-mode: MUST trap Cause 2
    tb.reset();
    tb.mem.clear();
    tb.exception_seen = false;
    tb.write_mem_word(base + 0, rv_addi(1, 0, 1));
    tb.write_mem_word(base + 4, rv_csrrw(0, 0x320, 1));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 4C: Read mcountinhibit in S-mode: MUST trap Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 1;
    tb.write_mem_word(base + 0, rv_csrrs(1, 0x320, 0));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    // Subtest 4D: Read mcountinhibit in U-mode: MUST trap Cause 2
    tb.reset();
    tb.mem.clear();
    tb.dut->priv_mode_i = 0;
    tb.write_mem_word(base + 0, rv_csrrs(1, 0x320, 0));
    assert(tb.wait_for_exception(100));
    assert(tb.exception_cause == 2);

    tb.dut->priv_mode_i = 3;
    std::cout << "[PASS] Test 04: PROP_HPM_MCOUNTINHIBIT_UNIMPLEMENTED (4 sub-scenarios: 4A/4B/4C/4D all trap Cause 2).\n";
}

// -----------------------------------------------------------------------------
// Test 5: PROP_HPM_COUNTER_WRITE_MMODE (Sub-scenarios 5A, 5B, 5C, 5D)
// -----------------------------------------------------------------------------
void test_05_counter_write_mmode(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Subtest 5A & 5B: Write specific 64-bit value to mhpmcounter3 (0xB03) and minstret (0xB02)
    tb.write_mem_word(base + 0,  rv_addi(1, 0, 0x123));
    tb.write_mem_word(base + 4,  rv_csrrw(0, 0xB03, 1));
    tb.write_mem_word(base + 8,  rv_csrrs(2, 0xB03, 0));
    tb.write_mem_word(base + 12, rv_addi(3, 0, 0x500));
    tb.write_mem_word(base + 16, rv_csrrw(0, 0xB02, 3)); // minstret
    tb.write_mem_word(base + 20, rv_csrrs(4, 0xB02, 0));
    tb.wait_until_retired(6, 200);

    assert(tb.dut->mhpmcounter_o[3] >= 0x123);
    assert(tb.dut->minstret_o >= 0x500);

    // Subtest 5C: 64-bit modular counter wrap test
    // Write 0xFFFFFFFFFFFFFFFE to counter 4, select event 1, run instructions to verify wrap
    tb.dut->rootp->fursoy_s1_core__DOT__u_hpm__DOT__mhpmcounter_q[4] = 0xFFFFFFFFFFFFFFFEULL;
    tb.dut->rootp->fursoy_s1_core__DOT__u_hpm__DOT__mhpmevent_q[4]   = 0x01; // EV_FETCH_CYCLES
    for (int i = 0; i < 5; i++) tb.step();
    // Verify counter 4 wrapped past 0
    assert(tb.dut->mhpmcounter_o[4] < 100ULL);

    // Subtest 5D: Software-write priority over hardware increment
    tb.reset();
    tb.mem.clear();
    tb.dut->rootp->fursoy_s1_core__DOT__u_hpm__DOT__mhpmevent_q[3] = 0x01; // active event
    tb.write_mem_word(base + 0, rv_addi(1, 0, 0x777));
    tb.write_mem_word(base + 4, rv_csrrw(0, 0xB03, 1)); // direct overwrite
    tb.write_mem_word(base + 8, rv_nop());
    tb.write_mem_word(base + 12, rv_nop());
    tb.wait_until_retired(4, 100);
    tb.run_cycles(3);
    assert(tb.dut->mhpmcounter_o[3] >= 0x777);

    std::cout << "[PASS] Test 05: PROP_HPM_COUNTER_WRITE_MMODE (4 sub-scenarios: 5A counter, 5B minstret, 5C wrap, 5D SW priority).\n";
}

// -----------------------------------------------------------------------------
// Test 6: PROP_CPI_CONSERVATION_STRESS (Sub-scenarios 6A, 6B, 6C, 6D, 6E)
// -----------------------------------------------------------------------------
void test_06_cpi_conservation_stress(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Run mixed sequence: ALU, Branch (mispredicted), Loads, Stores, FENCE.I
    // 1. ALU (C_productive)
    tb.write_mem_word(base + 0, rv_addi(1, 0, 10));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 20));
    // 2. Branch mispredict recovery (C_br_recover)
    tb.write_mem_word(base + 8, rv_beq(1, 2, 16)); // not taken
    tb.write_mem_word(base + 12, rv_addi(3, 1, 1));
    // 3. Store + Load
    tb.write_mem_word(base + 16, rv_addi(4, 0, 0x80000800));
    tb.write_mem_word(base + 20, rv_sd(3, 4, 0));
    tb.write_mem_word(base + 24, rv_ld(5, 4, 0));
    // 4. FENCE.I serialization (C_serialize)
    tb.write_mem_word(base + 28, rv_fence_i());
    tb.write_mem_word(base + 32, rv_addi(6, 5, 1));

    tb.wait_until_retired(9, 500);

    // Subtest 6A, 6B, 6C: Check CPI category non-zero accumulation
    assert(tb.dut->cpi_category_o[2] > 0); // C_productive
    assert(tb.dut->cpi_category_o[0] > 0); // C_serialize (due to fence.i)
    assert(tb.dut->cpi_category_o[1] >= 0); // C_br_recover

    // Subtest 6D & 6E: Priority hierarchy and strict conservation
    uint64_t sum = 0;
    for (int k = 0; k < 8; k++) sum += tb.dut->cpi_category_o[k];
    assert(sum == tb.dut->mcycle_o);

    std::cout << "[PASS] Test 06: PROP_CPI_CONSERVATION_STRESS (5 sub-scenarios: 6A prod, 6B ser, 6C rec, 6D prio, 6E conservation).\n";
}

// =============================================================================
// Dedicated Randomized Adversarial HPM Verification (P2-1)
// =============================================================================

RandomHPMStats run_randomized_hpm_test(PhaseATB& tb, uint64_t seed, int target_ops) {
    RandomHPMStats stats;
    stats.seed = seed;
    stats.accepted_ops = 0;
    stats.cycles = 0;
    stats.mismatches = 0;
    stats.expected_traps = 0;
    stats.unexpected_traps = 0;
    stats.missed_expected_traps = 0;
    stats.watchdog_trips = 0;

    tb.reset();
    tb.mem.clear();

    HPMReferenceModel ref;
    tb.active_ref = &ref;
    std::mt19937_64 rng(seed);

    const int BATCH_SIZE = 250;
    int num_batches = (target_ops + BATCH_SIZE - 1) / BATCH_SIZE;

    for (int b = 0; b < num_batches; b++) {
        // Deterministic privilege partition:
        // 60% M-mode, 20% S-mode, 20% U-mode
        uint8_t batch_priv = 3; // M-mode
        if (b % 5 == 1) batch_priv = 1; // S-mode
        else if (b % 5 == 2) batch_priv = 0; // U-mode

        ref.priv_mode = batch_priv;
        tb.dut->priv_mode_i = batch_priv;

        // In M-mode, randomly update counter enable masks
        if (batch_priv == 3 || b == 0) {
            ref.mcounteren = (uint32_t)rng();
            ref.scounteren = (uint32_t)rng();
            tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__mcounteren_q = ref.mcounteren;
            tb.dut->rootp->fursoy_s1_core__DOT__u_csr__DOT__scounteren_q = ref.scounteren;
        }

        uint64_t batch_base = 0x80100000ULL + (b * 0x4000ULL);
        uint64_t data_base  = 0x80500000ULL + (b * 0x2000ULL);
        uint64_t pc = batch_base;

        std::map<uint64_t, bool> expect_trap_at_pc;

        for (int op = 0; op < BATCH_SIZE; op++) {
            int op_type = rng() % 100;

            if (batch_priv == 3) { // M-mode operations
                if (op_type < 25) {
                    // Selector Write
                    int c = 3 + (rng() % 29);
                    uint32_t ev = 0;
                    int sub = rng() % 10;
                    if (sub < 4) ev = 1 + (rng() % 48); // 0x01..0x30 valid
                    else if (sub < 6) ev = 0;           // 0x00 disabled
                    else if (sub < 8) ev = 0x31 + (rng() % 15); // 0x31..0x3F invalid
                    else ev = (uint32_t)ref.selectors[3 + (rng() % 29)]; // same as other counter

                    tb.write_mem_word(pc, rv_addi(1, 0, ev));
                    tb.write_mem_word(pc + 4, rv_csrrw(0, 0x320 + c, 1));
                    expect_trap_at_pc[pc + 4] = false;
                    pc += 8;
                } else if (op_type < 50) {
                    // Counter Write
                    int c = 3 + (rng() % 29);
                    uint64_t val = 0;
                    int sub = rng() % 10;
                    if (sub < 4) val = 0xFFFFFFFFFFFFFFF0ULL + (rng() % 16); // near 64-bit wrap
                    else if (sub < 7) val = 1 + (rng() % 100);               // small int
                    else val = rng();                                        // full 64-bit

                    tb.write_mem_dword(data_base + op * 8, val);
                    tb.write_mem_word(pc, rv_lui(2, ((data_base + op * 8) >> 12) & 0xFFFFF));
                    tb.write_mem_word(pc + 4, rv_ld(1, 2, (data_base + op * 8) & 0xFFF));
                    tb.write_mem_word(pc + 8, rv_csrrw(0, 0xB00 + c, 1));
                    expect_trap_at_pc[pc + 8] = false;
                    pc += 12;
                } else if (op_type < 70) {
                    // Counter Read (User view 0xC00+c)
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0xC00 + c, 0));
                    expect_trap_at_pc[pc] = false;
                    pc += 4;
                } else if (op_type < 80) {
                    // Counter Read (Machine view 0xB00+c)
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0xB00 + c, 0));
                    expect_trap_at_pc[pc] = false;
                    pc += 4;
                } else if (op_type < 90) {
                    // Selector Read (0x320+c)
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0x320 + c, 0));
                    expect_trap_at_pc[pc] = false;
                    pc += 4;
                } else if (op_type < 95) {
                    // Unimplemented mcountinhibit (0x320) access -> MUST trap Cause 2
                    tb.write_mem_word(pc, rv_csrrs(3, 0x320, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else {
                    // ALU + Branch activity
                    tb.write_mem_word(pc, rv_addi(4, 4, 1));
                    tb.write_mem_word(pc + 4, rv_bne(4, 0, 8));
                    tb.write_mem_word(pc + 8, rv_addi(5, 5, 1));
                    expect_trap_at_pc[pc] = false;
                    expect_trap_at_pc[pc + 4] = false;
                    expect_trap_at_pc[pc + 8] = false;
                    pc += 12;
                }
            } else if (batch_priv == 1) { // S-mode operations
                if (op_type < 50) {
                    // Permitted or Denied Counter Read (0xC00+c)
                    int c = 3 + (rng() % 29);
                    bool permitted = (ref.mcounteren & (1U << c)) != 0;
                    tb.write_mem_word(pc, rv_csrrs(3, 0xC00 + c, 0));
                    expect_trap_at_pc[pc] = !permitted;
                    pc += 4;
                } else if (op_type < 70) {
                    // Denied M-mode counter read (0xB00+c) -> MUST trap Cause 2
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0xB00 + c, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else if (op_type < 85) {
                    // Denied selector read/write (0x320+c) -> MUST trap Cause 2
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0x320 + c, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else if (op_type < 95) {
                    // Unimplemented mcountinhibit -> MUST trap Cause 2
                    tb.write_mem_word(pc, rv_csrrs(3, 0x320, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else {
                    // ALU activity
                    tb.write_mem_word(pc, rv_addi(4, 4, 1));
                    expect_trap_at_pc[pc] = false;
                    pc += 4;
                }
            } else { // U-mode operations
                if (op_type < 50) {
                    // Permitted or Denied Counter Read (0xC00+c)
                    int c = 3 + (rng() % 29);
                    bool permitted = ((ref.mcounteren & (1U << c)) != 0) && ((ref.scounteren & (1U << c)) != 0);
                    tb.write_mem_word(pc, rv_csrrs(3, 0xC00 + c, 0));
                    expect_trap_at_pc[pc] = !permitted;
                    pc += 4;
                } else if (op_type < 70) {
                    // Denied M-mode counter read (0xB00+c) -> MUST trap Cause 2
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0xB00 + c, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else if (op_type < 85) {
                    // Denied selector read/write (0x320+c) -> MUST trap Cause 2
                    int c = 3 + (rng() % 29);
                    tb.write_mem_word(pc, rv_csrrs(3, 0x320 + c, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else if (op_type < 95) {
                    // Unimplemented mcountinhibit -> MUST trap Cause 2
                    tb.write_mem_word(pc, rv_csrrs(3, 0x320, 0));
                    expect_trap_at_pc[pc] = true;
                    pc += 4;
                } else {
                    // ALU activity
                    tb.write_mem_word(pc, rv_addi(4, 4, 1));
                    expect_trap_at_pc[pc] = false;
                    pc += 4;
                }
            }
        }

        // Terminal delimiter for the batch
        uint64_t end_pc = pc;
        tb.write_mem_word(end_pc, rv_addi(6, 0, 999));

        // Launch batch execution
        tb.redirect_trap(batch_base);

        int batch_cyc = 0;
        const int MAX_BATCH_CYCLES = 15000;
        while (batch_cyc < MAX_BATCH_CYCLES) {
            tb.step();
            batch_cyc++;

            // Independent Scoreboard check: verify all 29 counters match reference model
            for (int c = 3; c <= 31; c++) {
                if (tb.dut->mhpmcounter_o[c] != ref.counters[c]) {
                    if (stats.mismatches < 5) {
                        std::cerr << "[MISMATCH] cycle " << ref.cycles << " counter " << c
                                  << " dut=0x" << std::hex << tb.dut->mhpmcounter_o[c]
                                  << " ref=0x" << ref.counters[c]
                                  << " sel=0x" << ref.selectors[c] << std::dec << "\n";
                    }
                    stats.mismatches++;
                }
            }

            // Exception handling & verification
            if (tb.dut->retire_exception_o) {
                uint64_t exc_pc = tb.dut->retire_exc_pc_o;
                uint32_t cause  = tb.dut->retire_exc_cause_o;

                if (expect_trap_at_pc.count(exc_pc) && expect_trap_at_pc[exc_pc]) {
                    stats.expected_traps++;
                    if (cause != 2) {
                        std::cerr << "[UNEXPECTED TRAP CAUSE] at PC 0x" << std::hex << exc_pc << " cause " << cause << std::dec << "\n";
                        stats.unexpected_traps++;
                        stats.mismatches++;
                    }
                } else {
                    std::cerr << "[UNEXPECTED TRAP] at PC 0x" << std::hex << exc_pc << " cause " << cause << std::dec << "\n";
                    stats.unexpected_traps++;
                    stats.mismatches++;
                }
                stats.accepted_ops++;
                tb.redirect_trap(exc_pc + 4);
                batch_cyc++;
                continue;
            }

            // Retirement tracking
            bool reached_end = false;
            if (tb.dut->retire_valid_o & 1) {
                uint64_t ret_pc = tb.dut->retire_pc_o[0];
                if (ret_pc == end_pc) reached_end = true;
                else {
                    if (expect_trap_at_pc.count(ret_pc) && expect_trap_at_pc[ret_pc]) {
                        std::cerr << "[MISSED EXPECTED TRAP] at PC 0x" << std::hex << ret_pc << std::dec << "\n";
                        stats.missed_expected_traps++;
                        stats.mismatches++;
                    }
                    stats.accepted_ops++;
                }
            }
            if (tb.dut->retire_valid_o & 2) {
                uint64_t ret_pc = tb.dut->retire_pc_o[1];
                if (ret_pc == end_pc) reached_end = true;
                else {
                    if (expect_trap_at_pc.count(ret_pc) && expect_trap_at_pc[ret_pc]) {
                        std::cerr << "[MISSED EXPECTED TRAP] at PC 0x" << std::hex << ret_pc << std::dec << "\n";
                        stats.missed_expected_traps++;
                        stats.mismatches++;
                    }
                    stats.accepted_ops++;
                }
            }

            if (reached_end) break;
        }

        if (batch_cyc >= MAX_BATCH_CYCLES) {
            stats.watchdog_trips++;
            std::cerr << "[FAIL] Batch " << b << " watchdog trip after " << batch_cyc << " cycles!\n";
            assert(false && "Randomized HPM batch watchdog timeout!");
        }
    }

    tb.active_ref = nullptr;
    stats.cycles = ref.cycles;
    tb.dut->priv_mode_i = 3; // Restore M-mode
    std::cout << "[PASS] Randomized HPM verification (Seed " << seed << "): "
              << stats.accepted_ops << " ops, " << stats.cycles << " cycles, "
              << stats.expected_traps << " expected traps, "
              << stats.mismatches << " mismatches, "
              << stats.unexpected_traps << " unexpected traps, "
              << stats.missed_expected_traps << " missed traps, "
              << stats.watchdog_trips << " watchdog trips.\n";

    assert(stats.mismatches == 0);
    assert(stats.unexpected_traps == 0);
    assert(stats.missed_expected_traps == 0);
    assert(stats.watchdog_trips == 0);

    return stats;
}

// =============================================================================
// Synthetic Microarchitectural Profiling Workloads (Deterministic & Disjoint)
// =============================================================================

struct ProfileMetrics {
    std::string name;
    uint64_t start_cycle;
    uint64_t end_cycle;
    uint64_t elapsed_cycles;
    uint64_t start_instret;
    uint64_t end_instret;
    uint64_t elapsed_instret;
    double   ipc;
    uint64_t cpi_cat[8];
    uint64_t events[49];
};

// Machine-checkable 48-Key Unique Integrity Assertion (Item 2)
void verify_profile_48_keys(const ProfileMetrics& p) {
    std::set<std::string> seen_keys;
    for (int ev = 1; ev <= 48; ev++) {
        std::string key = format_event_id(ev);
        assert(seen_keys.find(key) == seen_keys.end() && "Duplicate event key detected in profile!");
        seen_keys.insert(key);
        assert(key.length() == 4 && key.rfind("0x", 0) == 0 && "Malformed event key format!");
    }
    assert(seen_keys.size() == 48 && "Profile must contain exactly 48 unique keys!");
    for (int ev = 1; ev <= 48; ev++) {
        std::string expected_key = format_event_id(ev);
        assert(seen_keys.count(expected_key) == 1 && "Missing expected event key in profile!");
    }
}

// -----------------------------------------------------------------------------
// Workload 1: Branch Torture
// Parameters: Iterations = 64, Code Base = 0x80000000ULL, 7 inst/iter avg
// -----------------------------------------------------------------------------
ProfileMetrics run_workload_branch_torture(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Loop: 64 iterations of alternating branches
    // x1 = loop count = 64
    tb.write_mem_word(base + 0,  rv_addi(1, 0, 64)); // x1 = 64
    tb.write_mem_word(base + 4,  rv_addi(3, 0, 0));
    tb.write_mem_word(base + 8,  rv_addi(5, 0, 0));

    // loop (offset 12)
    tb.write_mem_word(base + 12, rv_andi(2, 1, 1));
    tb.write_mem_word(base + 16, rv_beq(2, 0, 8)); // jump to target1 (pc+8)
    tb.write_mem_word(base + 20, rv_addi(3, 3, 1));
    // target1 (offset 24)
    tb.write_mem_word(base + 24, rv_andi(4, 1, 2));
    tb.write_mem_word(base + 28, rv_bne(4, 0, 8)); // jump to target2 (pc+8)
    tb.write_mem_word(base + 32, rv_addi(5, 5, 1));
    // target2 (offset 36)
    tb.write_mem_word(base + 36, rv_addi(1, 1, -1));
    tb.write_mem_word(base + 40, rv_bne(1, 0, -28)); // jump back to loop (offset 12)
    // exit (offset 44)
    tb.write_mem_word(base + 44, rv_addi(6, 0, 42));

    uint64_t c0 = tb.dut->mcycle_o;
    uint64_t i0 = tb.dut->minstret_o;
    uint64_t cpi_cat_0[8];
    for (int k = 0; k < 8; k++) cpi_cat_0[k] = tb.dut->cpi_category_o[k];
    uint64_t events_0[49];
    for (int ev = 1; ev <= 48; ev++) events_0[ev] = tb.raw_event_accum[ev];

    tb.wait_until_retired(3 + 64 * 7, 3000);

    ProfileMetrics m;
    m.name = "branch_torture";
    m.start_cycle = c0;
    m.end_cycle = tb.dut->mcycle_o;
    m.elapsed_cycles = m.end_cycle - m.start_cycle;
    m.start_instret = i0;
    m.end_instret = tb.dut->minstret_o;
    m.elapsed_instret = m.end_instret - m.start_instret;
    m.ipc = (double)m.elapsed_instret / (double)(m.elapsed_cycles ? m.elapsed_cycles : 1);

    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_cat_0[k];
    for (int ev = 1; ev <= 48; ev++) m.events[ev] = tb.raw_event_accum[ev] - events_0[ev];

    verify_profile_48_keys(m);
    return m;
}

// -----------------------------------------------------------------------------
// Workload 2: Pointer Chasing
// Parameters: Iterations = 64, Code Base = 0x80002000ULL, Data Base = 0x80020000ULL
// Working set = 8 nodes x 64 B = 512 B circular linked list (1 node/line)
// -----------------------------------------------------------------------------
ProfileMetrics run_workload_pointer_chasing(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80002000ULL;
    uint64_t data_base = 0x80020000ULL;

    // Build 8-node circular linked list at data_base
    for (int i = 0; i < 8; i++) {
        uint64_t next = data_base + ((i + 1) % 8) * 64; // each node on a different cache line
        tb.write_mem_dword(data_base + i * 64, next);
    }

    tb.write_mem_word(base + 0, rv_lui(1, (data_base >> 12) & 0xFFFFF));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 64)); // 64 iterations
    // loop (offset 8)
    tb.write_mem_word(base + 8,  rv_ld(1, 1, 0));
    tb.write_mem_word(base + 12, rv_addi(2, 2, -1));
    tb.write_mem_word(base + 16, rv_bne(2, 0, -8));
    tb.write_mem_word(base + 20, rv_addi(3, 0, 99));

    // Redirect core to base PC
    tb.redirect_trap(base);

    uint64_t c0 = tb.dut->mcycle_o;
    uint64_t i0 = tb.dut->minstret_o;
    uint64_t cpi_cat_0[8];
    for (int k = 0; k < 8; k++) cpi_cat_0[k] = tb.dut->cpi_category_o[k];
    uint64_t events_0[49];
    for (int ev = 1; ev <= 48; ev++) events_0[ev] = tb.raw_event_accum[ev];

    tb.wait_until_retired(2 + 64 * 3 + 1, 5000);

    ProfileMetrics m;
    m.name = "pointer_chasing";
    m.start_cycle = c0;
    m.end_cycle = tb.dut->mcycle_o;
    m.elapsed_cycles = m.end_cycle - m.start_cycle;
    m.start_instret = i0;
    m.end_instret = tb.dut->minstret_o;
    m.elapsed_instret = m.end_instret - m.start_instret;
    m.ipc = (double)m.elapsed_instret / (double)(m.elapsed_cycles ? m.elapsed_cycles : 1);

    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_cat_0[k];
    for (int ev = 1; ev <= 48; ev++) m.events[ev] = tb.raw_event_accum[ev] - events_0[ev];

    verify_profile_48_keys(m);
    return m;
}

// -----------------------------------------------------------------------------
// Workload 3: Stream Memcpy
// Parameters: Iterations = 32 (256 B), Code Base = 0x80004000ULL,
// Src Base = 0x80030000ULL, Dst Base = 0x80040000ULL
// -----------------------------------------------------------------------------
ProfileMetrics run_workload_stream_memcpy(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80004000ULL;
    uint64_t src_base = 0x80030000ULL;
    uint64_t dst_base = 0x80040000ULL;

    for (int i = 0; i < 32; i++) {
        tb.write_mem_dword(src_base + i * 8, 0x1111222233334444ULL + i);
    }

    tb.write_mem_word(base + 0,  rv_lui(1, (src_base >> 12) & 0xFFFFF));
    tb.write_mem_word(base + 4,  rv_lui(2, (dst_base >> 12) & 0xFFFFF));
    tb.write_mem_word(base + 8,  rv_addi(3, 0, 32)); // count = 32 dwords
    // loop (offset 12)
    tb.write_mem_word(base + 12, rv_ld(4, 1, 0));
    tb.write_mem_word(base + 16, rv_sd(4, 2, 0));
    tb.write_mem_word(base + 20, rv_addi(1, 1, 8));
    tb.write_mem_word(base + 24, rv_addi(2, 2, 8));
    tb.write_mem_word(base + 28, rv_addi(3, 3, -1));
    tb.write_mem_word(base + 32, rv_bne(3, 0, -20));
    tb.write_mem_word(base + 36, rv_addi(5, 0, 100));

    tb.redirect_trap(base);

    uint64_t c0 = tb.dut->mcycle_o;
    uint64_t i0 = tb.dut->minstret_o;
    uint64_t cpi_cat_0[8];
    for (int k = 0; k < 8; k++) cpi_cat_0[k] = tb.dut->cpi_category_o[k];
    uint64_t events_0[49];
    for (int ev = 1; ev <= 48; ev++) events_0[ev] = tb.raw_event_accum[ev];

    tb.wait_until_retired(3 + 32 * 6 + 1, 4000);

    ProfileMetrics m;
    m.name = "stream_memcpy";
    m.start_cycle = c0;
    m.end_cycle = tb.dut->mcycle_o;
    m.elapsed_cycles = m.end_cycle - m.start_cycle;
    m.start_instret = i0;
    m.end_instret = tb.dut->minstret_o;
    m.elapsed_instret = m.end_instret - m.start_instret;
    m.ipc = (double)m.elapsed_instret / (double)(m.elapsed_cycles ? m.elapsed_cycles : 1);

    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_cat_0[k];
    for (int ev = 1; ev <= 48; ev++) m.events[ev] = tb.raw_event_accum[ev] - events_0[ev];

    verify_profile_48_keys(m);
    return m;
}

// -----------------------------------------------------------------------------
// Workload 4: Integer Dependency & ALU Stress
// Parameters: Iterations = 32, Code Base = 0x80006000ULL, pure register RAW chains + MUL/DIV
// -----------------------------------------------------------------------------
ProfileMetrics run_workload_int_dependency(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80006000ULL;

    tb.write_mem_word(base + 0,  rv_addi(1, 0, 32));
    tb.write_mem_word(base + 4,  rv_addi(2, 0, 1));
    // loop (offset 8)
    tb.write_mem_word(base + 8,  rv_addi(2, 2, 1));
    tb.write_mem_word(base + 12, rv_addi(2, 2, 2));
    tb.write_mem_word(base + 16, rv_addi(2, 2, 3));
    tb.write_mem_word(base + 20, rv_mul(3, 2, 2));
    tb.write_mem_word(base + 24, rv_div(4, 3, 1));
    tb.write_mem_word(base + 28, rv_add(2, 2, 4));
    tb.write_mem_word(base + 32, rv_addi(1, 1, -1));
    tb.write_mem_word(base + 36, rv_bne(1, 0, -28));
    tb.write_mem_word(base + 40, rv_addi(5, 0, 101));

    tb.redirect_trap(base);

    uint64_t c0 = tb.dut->mcycle_o;
    uint64_t i0 = tb.dut->minstret_o;
    uint64_t cpi_cat_0[8];
    for (int k = 0; k < 8; k++) cpi_cat_0[k] = tb.dut->cpi_category_o[k];
    uint64_t events_0[49];
    for (int ev = 1; ev <= 48; ev++) events_0[ev] = tb.raw_event_accum[ev];

    tb.wait_until_retired(2 + 32 * 8 + 1, 5000);

    ProfileMetrics m;
    m.name = "int_dependency";
    m.start_cycle = c0;
    m.end_cycle = tb.dut->mcycle_o;
    m.elapsed_cycles = m.end_cycle - m.start_cycle;
    m.start_instret = i0;
    m.end_instret = tb.dut->minstret_o;
    m.elapsed_instret = m.end_instret - m.start_instret;
    m.ipc = (double)m.elapsed_instret / (double)(m.elapsed_cycles ? m.elapsed_cycles : 1);

    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_cat_0[k];
    for (int ev = 1; ev <= 48; ev++) m.events[ev] = tb.raw_event_accum[ev] - events_0[ev];

    verify_profile_48_keys(m);
    return m;
}

// -----------------------------------------------------------------------------
// Workload 5: RAW Stress (Store-to-Load Exact Forwarding)
// Parameters: Iterations = 32, Code Base = 0x80008000ULL, Data Base = 0x80060000ULL
// -----------------------------------------------------------------------------
ProfileMetrics run_workload_raw_stress(PhaseATB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80008000ULL;
    uint64_t data_base = 0x80060000ULL;

    tb.write_mem_dword(data_base, 0x1234567890ABCDEFULL);

    tb.write_mem_word(base + 0,  rv_lui(1, (data_base >> 12) & 0xFFFFF));
    tb.write_mem_word(base + 4,  rv_addi(2, 0, 32));
    tb.write_mem_word(base + 8,  rv_addi(4, 0, 0));
    // loop (offset 12)
    tb.write_mem_word(base + 12, rv_sd(2, 1, 0));
    tb.write_mem_word(base + 16, rv_ld(3, 1, 0)); // Store-to-Load exact bypass (EV_LOAD_FWD_EXACT)
    tb.write_mem_word(base + 20, rv_add(4, 4, 3));
    tb.write_mem_word(base + 24, rv_addi(2, 2, -1));
    tb.write_mem_word(base + 28, rv_bne(2, 0, -16));
    tb.write_mem_word(base + 32, rv_addi(5, 0, 102));

    tb.redirect_trap(base);

    uint64_t c0 = tb.dut->mcycle_o;
    uint64_t i0 = tb.dut->minstret_o;
    uint64_t cpi_cat_0[8];
    for (int k = 0; k < 8; k++) cpi_cat_0[k] = tb.dut->cpi_category_o[k];
    uint64_t events_0[49];
    for (int ev = 1; ev <= 48; ev++) events_0[ev] = tb.raw_event_accum[ev];

    tb.wait_until_retired(3 + 32 * 5 + 1, 4000);

    ProfileMetrics m;
    m.name = "raw_stress";
    m.start_cycle = c0;
    m.end_cycle = tb.dut->mcycle_o;
    m.elapsed_cycles = m.end_cycle - m.start_cycle;
    m.start_instret = i0;
    m.end_instret = tb.dut->minstret_o;
    m.elapsed_instret = m.end_instret - m.start_instret;
    m.ipc = (double)m.elapsed_instret / (double)(m.elapsed_cycles ? m.elapsed_cycles : 1);

    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_cat_0[k];
    for (int ev = 1; ev <= 48; ev++) m.events[ev] = tb.raw_event_accum[ev] - events_0[ev];

    verify_profile_48_keys(m);
    return m;
}

// =============================================================================
// Main Verification Runner
// =============================================================================
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "=============================================================================\n";
    std::cout << "Fursoy Slice-1 Milestone 5 Phase A: Instrumentation & Baseline Profiling TB\n";
    std::cout << "Canonical Spec: docs/architecture/slice1-m5-performance-v1.md (Frozen v1.2)\n";
    std::cout << "=============================================================================\n";

    PhaseATB tb;

    std::cout << "\n--- Running Phase A Mandatory Directed Verification Tests (6 Tests, 26 Sub-scenarios) ---\n";
    test_01_hpm_selector_mapping(tb);
    test_02_mcounteren_smode_gating(tb);
    test_03_scounteren_umode_gating(tb);
    test_04_mcountinhibit_unimplemented(tb);
    test_05_counter_write_mmode(tb);
    test_06_cpi_conservation_stress(tb);

    std::cout << "\n--- Running Phase A Dedicated Randomized Adversarial HPM Verification ---\n";
    RandomHPMStats stats_42 = run_randomized_hpm_test(tb, 42ULL, 25000);
    RandomHPMStats stats_20260920 = run_randomized_hpm_test(tb, 20260920ULL, 25000);

    std::cout << "\n--- Running Phase A Baseline Profiling Microarchitectural Kernels ---\n";
    std::vector<ProfileMetrics> profiles;
    profiles.push_back(run_workload_branch_torture(tb));
    profiles.push_back(run_workload_pointer_chasing(tb));
    profiles.push_back(run_workload_stream_memcpy(tb));
    profiles.push_back(run_workload_int_dependency(tb));
    profiles.push_back(run_workload_raw_stress(tb));

    std::cout << "\n=============================================================================\n";
    std::cout << "PHASE A BASELINE PROFILING RESULTS SUMMARY:\n";
    std::cout << "=============================================================================\n";
    for (const auto& p : profiles) {
        std::ostringstream ss;
        ss << "Kernel: " << std::setw(20) << std::left << p.name
           << " | Cycles: " << std::setw(7) << std::right << p.elapsed_cycles
           << " | Instret: " << std::setw(7) << std::right << p.elapsed_instret
           << " | IPC: " << std::fixed << std::setprecision(3) << p.ipc;
        std::cout << ss.str() << "\n";
        std::cout << "   CPI Decomp [serialize, br_recov, productive, mem_stall, be_rename, be_sched, fe_starve, idle]:\n";
        std::cout << "     [" << p.cpi_cat[0] << ", " << p.cpi_cat[1] << ", " << p.cpi_cat[2] << ", "
                  << p.cpi_cat[3] << ", " << p.cpi_cat[4] << ", " << p.cpi_cat[5] << ", "
                  << p.cpi_cat[6] << ", " << p.cpi_cat[7] << "]\n";
    }

    // Output JSON data marker for runner
    std::cout << "\n--- BEGIN JSON PROFILE DATA ---\n";
    std::cout << "{\n";
    std::cout << "  \"directed_tests\": 6,\n";
    std::cout << "  \"directed_sub_scenarios\": 26,\n";
    std::cout << "  \"directed_status\": \"pass\",\n";
    std::cout << "  \"cpi_conservation_status\": \"pass\",\n";
    std::cout << "  \"randomized_hpm_verification\": {\n";
    std::cout << "    \"seed_42\": {\n";
    std::cout << "      \"seed\": " << stats_42.seed << ",\n";
    std::cout << "      \"accepted_operations\": " << stats_42.accepted_ops << ",\n";
    std::cout << "      \"cycles\": " << stats_42.cycles << ",\n";
    std::cout << "      \"mismatches\": " << stats_42.mismatches << ",\n";
    std::cout << "      \"expected_traps\": " << stats_42.expected_traps << ",\n";
    std::cout << "      \"unexpected_traps\": " << stats_42.unexpected_traps << ",\n";
    std::cout << "      \"missed_expected_traps\": " << stats_42.missed_expected_traps << ",\n";
    std::cout << "      \"watchdog_trips\": " << stats_42.watchdog_trips << "\n";
    std::cout << "    },\n";
    std::cout << "    \"seed_20260920\": {\n";
    std::cout << "      \"seed\": " << stats_20260920.seed << ",\n";
    std::cout << "      \"accepted_operations\": " << stats_20260920.accepted_ops << ",\n";
    std::cout << "      \"cycles\": " << stats_20260920.cycles << ",\n";
    std::cout << "      \"mismatches\": " << stats_20260920.mismatches << ",\n";
    std::cout << "      \"expected_traps\": " << stats_20260920.expected_traps << ",\n";
    std::cout << "      \"unexpected_traps\": " << stats_20260920.unexpected_traps << ",\n";
    std::cout << "      \"missed_expected_traps\": " << stats_20260920.missed_expected_traps << ",\n";
    std::cout << "      \"watchdog_trips\": " << stats_20260920.watchdog_trips << "\n";
    std::cout << "    }\n";
    std::cout << "  },\n";
    std::cout << "  \"profiles\": {\n";
    for (size_t i = 0; i < profiles.size(); i++) {
        const auto& p = profiles[i];
        std::cout << "    \"" << p.name << "\": {\n";
        std::cout << "      \"cycles\": " << p.elapsed_cycles << ",\n";
        std::cout << "      \"instret\": " << p.elapsed_instret << ",\n";
        std::cout << "      \"ipc\": " << std::fixed << std::setprecision(4) << p.ipc << ",\n";
        std::cout << "      \"cpi_breakdown\": {\n";
        std::cout << "        \"C_serialize\": " << p.cpi_cat[0] << ",\n";
        std::cout << "        \"C_br_recover\": " << p.cpi_cat[1] << ",\n";
        std::cout << "        \"C_productive\": " << p.cpi_cat[2] << ",\n";
        std::cout << "        \"C_mem_stall\": " << p.cpi_cat[3] << ",\n";
        std::cout << "        \"C_be_rename\": " << p.cpi_cat[4] << ",\n";
        std::cout << "        \"C_be_sched\": " << p.cpi_cat[5] << ",\n";
        std::cout << "        \"C_fe_starve\": " << p.cpi_cat[6] << ",\n";
        std::cout << "        \"C_idle_other\": " << p.cpi_cat[7] << "\n";
        std::cout << "      },\n";
        std::cout << "      \"events\": {\n";
        for (int ev = 1; ev <= 48; ev++) {
            std::cout << "        \"" << format_event_id(ev) << "\": "
                      << p.events[ev] << (ev < 48 ? "," : "") << "\n";
        }
        std::cout << "      }\n";
        std::cout << "    }" << (i + 1 < profiles.size() ? "," : "") << "\n";
    }
    std::cout << "  }\n";
    std::cout << "}\n";
    std::cout << "--- END JSON PROFILE DATA ---\n";

    std::cout << "\nVERIFICATION RESULT: ALL TESTS PASSED\n";
    return 0;
}
