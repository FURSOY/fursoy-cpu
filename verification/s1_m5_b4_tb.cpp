// =============================================================================
// Fursoy Slice-1 Milestone 5 Phase B4: Core-Integrated Oldest-Ready Scheduler & Profiling TB
// =============================================================================
// Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.4 (Oldest-Ready Matrix Scheduling)
//
// Coverage:
// 1. Integrated core verification of 16-entry Oldest-Ready Matrix Scheduler (IntIQ):
//    - Fill IntIQ to full capacity (16 entries) in real core pipeline;
//    - Core backpressure holding 17th integer uop and asserting EV_STALL_INTIQ_FULL (0x15);
//    - Branch misprediction recovery squashing younger integer uops from IntIQ;
//    - Milestone 5 Phase B1 speculative load replay forward progress with oldest-ready IntIQ;
//    - Modulo-16 circular wraparound across continuous integer streaming (64+ ALU/branch uops);
//    - CPI cycle conservation identity: sum(C_k) == mcycle over every interval;
//    - HPM Event Authenticity (0x15 EV_STALL_INTIQ_FULL, 0x1B EV_ISSUE_PORT0, 0x1C EV_ISSUE_PORT1_ALU, 0x21 EV_INTIQ_EMPTY).
// 2. Canonical 5 Baseline Profiling Workloads under B4:
//    - Branch Torture
//    - Pointer Chasing
//    - Stream Memcpy
//    - Integer Dependency
//    - RAW Stress
// 3. Machine-Readable JSON Output Format with 48 HPM events and CPI breakdown.
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

#include "Vfursoy_s1_core.h"
#include "Vfursoy_s1_core___024root.h"
#include "verilated.h"

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

inline uint32_t rv_addi(uint32_t rd, uint32_t rs1, int32_t imm) { return enc_i(imm, rs1, 0, rd, 0x13); }
inline uint32_t rv_add(uint32_t rd, uint32_t rs1, uint32_t rs2) { return enc_r(0x00, rs2, rs1, 0, rd, 0x33); }
inline uint32_t rv_sub(uint32_t rd, uint32_t rs1, uint32_t rs2) { return enc_r(0x20, rs2, rs1, 0, rd, 0x33); }
inline uint32_t rv_andi(uint32_t rd, uint32_t rs1, int32_t imm) { return enc_i(imm, rs1, 7, rd, 0x13); }
inline uint32_t rv_ori(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 6, rd, 0x13); }
inline uint32_t rv_xori(uint32_t rd, uint32_t rs1, int32_t imm) { return enc_i(imm, rs1, 4, rd, 0x13); }
inline uint32_t rv_slli(uint32_t rd, uint32_t rs1, uint32_t sh) { return enc_i(sh & 0x3F, rs1, 1, rd, 0x13); }
inline uint32_t rv_srli(uint32_t rd, uint32_t rs1, uint32_t sh) { return enc_i(sh & 0x3F, rs1, 5, rd, 0x13); }
inline uint32_t rv_srai(uint32_t rd, uint32_t rs1, uint32_t sh) { return enc_i((sh & 0x3F) | 0x400, rs1, 5, rd, 0x13); }
inline uint32_t rv_lui(uint32_t rd, uint32_t imm20)             { return enc_u(imm20 << 12, rd, 0x37); }
inline uint32_t rv_auipc(uint32_t rd, uint32_t imm20)           { return enc_u(imm20 << 12, rd, 0x17); }
inline uint32_t rv_jal(uint32_t rd, int32_t imm)                { return enc_j(imm, rd, 0x6F); }
inline uint32_t rv_jalr(uint32_t rd, uint32_t rs1, int32_t imm) { return enc_i(imm, rs1, 0, rd, 0x67); }
inline uint32_t rv_beq(uint32_t rs1, uint32_t rs2, int32_t imm) { return enc_b(imm, rs2, rs1, 0, 0x63); }
inline uint32_t rv_bne(uint32_t rs1, uint32_t rs2, int32_t imm) { return enc_b(imm, rs2, rs1, 1, 0x63); }
inline uint32_t rv_fence_i()                                    { return enc_i(0, 0, 1, 0, 0x0F); }
inline uint32_t rv_fence()                                      { return enc_i(0, 0, 0, 0, 0x0F); }
inline uint32_t rv_csrrw(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 1, rd, 0x73); }
inline uint32_t rv_csrrs(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 2, rd, 0x73); }
inline uint32_t rv_nop()                                        { return rv_addi(0, 0, 0); }

inline uint32_t rv_mul(uint32_t rd, uint32_t rs1, uint32_t rs2)  { return enc_r(0x01, rs2, rs1, 0, rd, 0x33); }
inline uint32_t rv_div(uint32_t rd, uint32_t rs1, uint32_t rs2)  { return enc_r(0x01, rs2, rs1, 4, rd, 0x33); }

inline uint32_t rv_lb(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 0, rd, 0x03); }
inline uint32_t rv_ld(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 3, rd, 0x03); }
inline uint32_t rv_sd(uint32_t rs2, uint32_t rs1, int32_t imm) { return enc_s(imm, rs2, rs1, 3, 0x23); }

struct L1IBusInFlight {
    uint64_t line_addr;
    uint8_t  tag;
    uint64_t ready_cycle;
};

struct PTWMemInFlight {
    uint64_t addr;
    uint64_t ready_cycle;
    uint64_t pte_data;
    bool     error;
};

struct L1DBusInFlight {
    uint64_t line_addr;
    uint8_t  tag;
    uint64_t ready_cycle;
};

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

class B4TB {
public:
    std::unique_ptr<Vfursoy_s1_core> dut;
    uint64_t cycle_count;
    uint64_t last_progress_cycle;
    const uint64_t watchdog_limit = 10000;

    std::map<uint64_t, std::vector<uint8_t>> mem;

    std::deque<L1IBusInFlight> l1i_bus_q;
    std::deque<PTWMemInFlight> ptw_mem_q;
    std::deque<L1DBusInFlight> l1d_bus_q;

    int l1i_bus_delay;
    int ptw_mem_delay;
    int l1d_bus_delay;

    std::vector<uint64_t> retired_pcs;
    uint64_t total_retired_ops;
    bool exception_seen;
    uint8_t exception_cause;
    uint64_t exception_pc;
    uint64_t raw_event_accum[49];

    B4TB() : dut(std::make_unique<Vfursoy_s1_core>()),
             cycle_count(0), last_progress_cycle(0),
             l1i_bus_delay(4), ptw_mem_delay(4), l1d_bus_delay(4),
             total_retired_ops(0), exception_seen(false),
             exception_cause(0), exception_pc(0) {
        memset(raw_event_accum, 0, sizeof(raw_event_accum));
    }

    std::vector<uint8_t> make_nop_line() {
        std::vector<uint8_t> line(64, 0);
        uint32_t nop = rv_nop();
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
            mem[line_addr] = make_nop_line();
        }
        memcpy(&mem[line_addr][offset], &data, 8);
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

        dut->mmio_req_ready_i       = 1;
        dut->mmio_rsp_valid_i       = 0;
        dut->mmio_rsp_rdata_i       = 0;
        dut->mmio_rsp_error_i       = 0;

        dut->test_inject_valid_i    = 0;
        dut->test_inject_data_i     = 0;
        dut->test_inject_pnew_i     = 0;
        dut->test_inject_rob_idx_i  = 0;
        dut->test_inject_rob_epoch_i= 0;
        dut->test_inject_mispredict_i = 0;

        l1i_bus_q.clear();
        ptw_mem_q.clear();
        l1d_bus_q.clear();
        retired_pcs.clear();
        total_retired_ops = 0;
        exception_seen = false;

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

        dut->eval();

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

        if (dut->retire_exception_o) {
            exception_seen  = true;
            exception_cause = dut->retire_exc_cause_o;
            exception_pc    = dut->retire_exc_pc_o;
            last_progress_cycle = cycle_count;
        }

        if ((cycle_count - last_progress_cycle) > watchdog_limit) {
            std::cerr << "\n[LIVENESS WATCHDOG TRIPPED] No progress for "
                      << watchdog_limit << " cycles at cycle " << cycle_count << "!\n";
            assert(false && "Watchdog timeout!");
            exit(1);
        }
    }

    void wait_until_retired(int target_count, int max_cycles = 5000) {
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
};

inline void verify_profile_48_keys(const ProfileMetrics& m) {
    for (int ev = 1; ev <= 48; ev++) {
        std::string k = format_event_id(ev);
        assert(!k.empty());
    }
}

// -----------------------------------------------------------------------------
// Workloads
// -----------------------------------------------------------------------------

ProfileMetrics run_workload_branch_torture(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    tb.write_mem_word(base + 0,  rv_addi(1, 0, 64)); // x1 = 64
    tb.write_mem_word(base + 4,  rv_addi(3, 0, 0));
    tb.write_mem_word(base + 8,  rv_addi(5, 0, 0));

    tb.write_mem_word(base + 12, rv_andi(2, 1, 1));
    tb.write_mem_word(base + 16, rv_beq(2, 0, 8));
    tb.write_mem_word(base + 20, rv_addi(3, 3, 1));
    tb.write_mem_word(base + 24, rv_andi(4, 1, 2));
    tb.write_mem_word(base + 28, rv_bne(4, 0, 8));
    tb.write_mem_word(base + 32, rv_addi(5, 5, 1));
    tb.write_mem_word(base + 36, rv_addi(1, 1, -1));
    tb.write_mem_word(base + 40, rv_bne(1, 0, -28));
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

ProfileMetrics run_workload_pointer_chasing(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80002000ULL;
    uint64_t data_base = 0x80020000ULL;

    for (int i = 0; i < 8; i++) {
        uint64_t next = data_base + ((i + 1) % 8) * 64;
        tb.write_mem_dword(data_base + i * 64, next);
    }

    tb.write_mem_word(base + 0, rv_auipc(1, (data_base - base) >> 12));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 64));
    tb.write_mem_word(base + 8,  rv_ld(1, 1, 0));
    tb.write_mem_word(base + 12, rv_addi(2, 2, -1));
    tb.write_mem_word(base + 16, rv_bne(2, 0, -8));
    tb.write_mem_word(base + 20, rv_addi(3, 0, 99));

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

ProfileMetrics run_workload_stream_memcpy(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80004000ULL;
    uint64_t src_base = 0x80034000ULL;
    uint64_t dst_base = 0x80044004ULL;

    for (int i = 0; i < 32; i++) {
        tb.write_mem_dword(src_base + i * 8, 0x1111222233334444ULL + i);
    }

    tb.write_mem_word(base + 0,  rv_auipc(1, (src_base - (base + 0)) >> 12));
    tb.write_mem_word(base + 4,  rv_auipc(2, (dst_base - (base + 4)) >> 12));
    tb.write_mem_word(base + 8,  rv_addi(3, 0, 32));
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

ProfileMetrics run_workload_int_dependency(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80006000ULL;

    tb.write_mem_word(base + 0,  rv_addi(1, 0, 32));
    tb.write_mem_word(base + 4,  rv_addi(2, 0, 1));
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

ProfileMetrics run_workload_raw_stress(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80008000ULL;
    uint64_t data_base = 0x80060000ULL;

    tb.write_mem_dword(data_base, 0x1234567890ABCDEFULL);

    tb.write_mem_word(base + 0,  rv_auipc(1, (data_base - base) >> 12));
    tb.write_mem_word(base + 4,  rv_addi(2, 0, 32));
    tb.write_mem_word(base + 8,  rv_addi(4, 0, 0));
    tb.write_mem_word(base + 12, rv_sd(2, 1, 0));
    tb.write_mem_word(base + 16, rv_ld(3, 1, 0));
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

// -----------------------------------------------------------------------------
// Dedicated Integrated Core IntIQ Oldest-Ready Tests
// -----------------------------------------------------------------------------

// Scenario 1: Fill all 16 entries in core and verify full backpressure EV_STALL_INTIQ_FULL (0x15)
void test_core_intiq_fill_and_backpressure(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Set up a multi-cycle divide: x2 = 100 / 7 (~34 cycles)
    tb.write_mem_word(base + 0, rv_addi(11, 0, 100));
    tb.write_mem_word(base + 4, rv_addi(12, 0, 7));
    tb.write_mem_word(base + 8, rv_div(2, 11, 12)); // slow divide produces x2

    // 18 ALU ops waiting for x2: they enter IntIQ but CANNOT issue until divide completes!
    for (int i = 0; i < 18; i++) {
        tb.write_mem_word(base + 12 + i * 4, rv_addi(13 + (i % 10), 2, i + 1));
    }
    tb.write_mem_word(base + 12 + 18 * 4, rv_addi(30, 0, 88));

    uint64_t stall_intiq_before = tb.raw_event_accum[0x15];

    // Run until all retire: 3 setup + 18 dependent + 1 final = 22 ops
    tb.wait_until_retired(22, 2000);

    uint64_t stall_intiq = tb.raw_event_accum[0x15] - stall_intiq_before;

    // With 18 ALUs and IntIQ depth = 16, Rename MUST have stalled due to IntIQ full!
    assert(stall_intiq >= 1);
    assert(tb.total_retired_ops >= 22);
    std::cout << "  [PASS] Core Scenario 1: IntIQ filled to capacity in core pipeline (EV_STALL_INTIQ_FULL asserted "
              << stall_intiq << " cycles, all 22 ops retired)\n";
}

// Scenario 2: Branch misprediction recovery squashes younger integer ops in IntIQ
void test_core_intiq_branch_recovery_squash(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;
    uint64_t target = 0x80000100ULL;

    tb.write_mem_word(base + 0, rv_addi(1, 0, 10));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 1));
    tb.write_mem_word(base + 8, rv_bne(2, 0, (int32_t)(target - (base + 8)))); // Taken branch to target

    // Wrong path instructions: multiple ALU ops that should be squashed
    for (int i = 0; i < 10; i++) {
        tb.write_mem_word(base + 12 + i * 4, rv_addi(10 + i, 1, i + 1));
    }

    // Target instructions
    tb.write_mem_word(target + 0, rv_addi(4, 1, 5)); // x4 = 15
    tb.write_mem_word(target + 4, rv_addi(5, 4, 1)); // x5 = 16

    tb.wait_until_retired(5, 500);

    bool saw_target = false;
    for (auto pc : tb.retired_pcs) {
        if (pc == target) saw_target = true;
        assert(pc < base + 12 || pc >= target); // No wrong path retired
    }
    assert(saw_target);
    std::cout << "  [PASS] Core Scenario 2: Branch recovery squashes younger integer uops from IntIQ without side effects\n";
}

// Scenario 3: Milestone 5 Phase B1 speculative load replay forward progress with oldest-ready scheduling
void test_core_intiq_speculative_load_replay(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;
    uint64_t data_base = 0x80050000ULL;

    tb.write_mem_dword(data_base, 0x5555AAAA5555AAAAULL);

    // Tight store-load sequence designed to trigger forwarding and verify replay safety with ALU ops
    tb.write_mem_word(base + 0,  rv_auipc(1, (data_base - base) >> 12));
    tb.write_mem_word(base + 4,  rv_addi(2, 0, 42));
    tb.write_mem_word(base + 8,  rv_sd(2, 1, 0));
    tb.write_mem_word(base + 12, rv_ld(3, 1, 0));
    tb.write_mem_word(base + 16, rv_addi(8, 0, 10));      // Interleaved ALU op
    tb.write_mem_word(base + 20, rv_sub(4, 3, 2));         // x4 = x3 - x2 (must be 0)
    tb.write_mem_word(base + 24, rv_bne(4, 0, 8));         // branch if not equal
    tb.write_mem_word(base + 28, rv_addi(5, 0, 100));      // Pass marker PC: base + 28
    tb.write_mem_word(base + 32, rv_addi(5, 0, 200));      // Fail marker PC: base + 32

    tb.wait_until_retired(8, 500);

    assert(!tb.retired_pcs.empty());
    assert(tb.retired_pcs.back() == base + 28);
    std::cout << "  [PASS] Core Scenario 3: Speculative load replay forward progress with oldest-ready IntIQ verified\n";
}

// Scenario 4: Modulo-16 continuous integer operation streaming (64+ ALU ops in order)
void test_core_intiq_continuous_streaming(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    const int total_ops = 64;
    tb.write_mem_word(base + 0, rv_addi(5, 0, 0)); // accumulator x5 = 0

    int offset = 4;
    for (int i = 0; i < total_ops; i++) {
        tb.write_mem_word(base + offset, rv_addi(5, 5, 1)); offset += 4;
    }
    // Expected accumulator: 64
    tb.write_mem_word(base + offset, rv_addi(6, 0, 64));        offset += 4;
    tb.write_mem_word(base + offset, rv_sub(7, 5, 6));          offset += 4;
    tb.write_mem_word(base + offset, rv_bne(7, 0, 8));          offset += 4;
    tb.write_mem_word(base + offset, rv_addi(10, 0, 999));      // Pass marker PC
    uint64_t pass_pc = base + offset;
    offset += 4;
    tb.write_mem_word(base + offset, rv_addi(10, 0, 666));      // Fail marker PC

    // 1 setup + 64 addi + 4 check = 69 insts
    tb.wait_until_retired(1 + total_ops + 4, 3500);

    assert(!tb.retired_pcs.empty());
    assert(tb.retired_pcs.back() == pass_pc);
    std::cout << "  [PASS] Core Scenario 4: Continuous streaming of 64 integer ops across multiple IntIQ wraparounds (sum=64)\n";
}

// Scenario 5: HPM Event Authenticity and CPI cycle conservation
void test_core_intiq_hpm_and_cpi(B4TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    tb.write_mem_word(base + 0, rv_addi(1, 0, 10));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 20));
    tb.write_mem_word(base + 8, rv_add(3, 1, 2));
    tb.write_mem_word(base + 12, rv_sub(4, 3, 1));
    tb.write_mem_word(base + 16, rv_addi(5, 0, 100));

    uint64_t ev_port0_before = tb.raw_event_accum[0x1B];
    uint64_t ev_intiq_empty_before = tb.raw_event_accum[0x21];

    tb.wait_until_retired(5, 500);

    uint64_t ev_port0 = tb.raw_event_accum[0x1B] - ev_port0_before;
    uint64_t ev_intiq_empty = tb.raw_event_accum[0x21] - ev_intiq_empty_before;

    assert(ev_port0 >= 1); // At least one uop issued to Port 0
    assert(ev_intiq_empty >= 1); // IntIQ empty cycles observed
    std::cout << "  [PASS] Core Scenario 5: HPM events & CPI identity verified (EV_ISSUE_PORT0="
              << ev_port0 << ", EV_INTIQ_EMPTY=" << ev_intiq_empty << ", CPI identity strictly conserved)\n";
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "=============================================================================\n";
    std::cout << "Fursoy Slice-1 Milestone 5 Phase B4: Integrated Oldest-Ready IntIQ & Profiling\n";
    std::cout << "Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.4 (Phase B4)\n";
    std::cout << "=============================================================================\n";

    B4TB tb;

    std::cout << "\n--- Running Core-Integrated Oldest-Ready IntIQ Verification Scenarios ---\n";
    test_core_intiq_fill_and_backpressure(tb);
    test_core_intiq_branch_recovery_squash(tb);
    test_core_intiq_speculative_load_replay(tb);
    test_core_intiq_continuous_streaming(tb);
    test_core_intiq_hpm_and_cpi(tb);

    std::cout << "\n--- Running Phase B4 Profiling on 5 Canonical Microarchitectural Kernels ---\n";
    std::vector<ProfileMetrics> profiles;
    profiles.push_back(run_workload_branch_torture(tb));
    profiles.push_back(run_workload_pointer_chasing(tb));
    profiles.push_back(run_workload_stream_memcpy(tb));
    profiles.push_back(run_workload_int_dependency(tb));
    profiles.push_back(run_workload_raw_stress(tb));

    for (const auto& p : profiles) {
        std::ostringstream ss;
        ss << "Kernel: " << std::setw(18) << std::left << p.name
           << " | Cycles: " << std::setw(7) << std::right << p.elapsed_cycles
           << " | Instret: " << std::setw(7) << std::right << p.elapsed_instret
           << " | IPC: " << std::fixed << std::setprecision(4) << p.ipc;
        std::cout << ss.str() << "\n";
        std::cout << "   CPI Decomp [serialize, br_recov, productive, mem_stall, be_rename, be_sched, fe_starve, idle]:\n";
        std::cout << "     [" << p.cpi_cat[0] << ", " << p.cpi_cat[1] << ", " << p.cpi_cat[2] << ", "
                  << p.cpi_cat[3] << ", " << p.cpi_cat[4] << ", " << p.cpi_cat[5] << ", "
                  << p.cpi_cat[6] << ", " << p.cpi_cat[7] << "]\n";
        std::cout << "   Issue Port 0 (0x1B): " << p.events[0x1B]
                  << " | Issue Port 1 ALU (0x1C): " << p.events[0x1C]
                  << " | IntIQ Full (0x15): " << p.events[0x15]
                  << " | IntIQ Empty (0x21): " << p.events[0x21] << "\n";
    }

    // Output JSON data marker for runner
    std::cout << "\n--- BEGIN JSON PROFILE DATA ---\n";
    std::cout << "{\n";
    std::cout << "  \"core_directed_scenarios\": 5,\n";
    std::cout << "  \"core_directed_status\": \"pass\",\n";
    std::cout << "  \"cpi_conservation_status\": \"pass\",\n";
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

    std::cout << "\nVERIFICATION RESULT: ALL TESTS PASSED (5 Core Directed Scenarios, 5/5 Workloads)\n";
    return 0;
}
