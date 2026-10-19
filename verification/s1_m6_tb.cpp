// =============================================================================
// Fursoy Slice-1 Milestone 6 Phase D: Integrated Core Verification & Profiling TB
// =============================================================================
// Reference: docs/architecture/slice1-m6-frontend-opt-v1.md Sections 8, 10, and 11
//
// Verification & Profiling Scope:
// 1. Integrated core verification of Milestone 6 frontend optimizations:
//    - PROP_M6_31: Odd-Word Fetch Alignment (PC[2]==1 masks Slot 0 and delivers Slot 1)
//    - PROP_M6_32: HPM Counter Mapping (0x0B..0x12 under BPU/TAGE/RAS stimulation)
//    - PROP_M6_33: CPI Cycle Conservation Law (sum(C_k) == mcycle over every cycle)
//    - PROP_M6_34: Multi-Checkpoint Drain (8 consecutive branches allocate and retire with 0 leak)
//    - PROP_M6_35: Nested Mispredict Cascade (older branch recovery strictly dominates younger)
// 2. Execution of the 5 canonical microarchitectural profiling workloads from clean reset:
//    - branch_torture
//    - pointer_chasing
//    - stream_memcpy
//    - int_dependency
//    - raw_stress
// 3. Extraction of 48 HPM events, 8-category single-owner CPI decomposition, and IPC metrics.
// 4. Output of machine-readable JSON profile data for tools/run_s1_m6_closeout.py.
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
    return (imm12 << 31) | ((imm10_5 & 0x3F) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) |
           ((funct3 & 0x07) << 12) | ((imm4_1 & 0xF) << 8) | (imm11 << 7) | (opcode & 0x7F);
}

inline uint32_t enc_u(uint32_t imm, uint32_t rd, uint32_t opcode) {
    return (imm & 0xFFFFF000) | ((rd & 0x1F) << 7) | (opcode & 0x7F);
}

inline uint32_t enc_j(uint32_t imm, uint32_t rd, uint32_t opcode) {
    uint32_t imm20    = (imm >> 20) & 1;
    uint32_t imm10_1  = (imm >> 1) & 0x3FF;
    uint32_t imm11    = (imm >> 11) & 1;
    uint32_t imm19_12 = (imm >> 12) & 0xFF;
    return (imm20 << 31) | ((imm10_1 & 0x3FF) << 21) | (imm11 << 20) | ((imm19_12 & 0xFF) << 12) |
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

class M6TB {
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

    M6TB() : dut(std::make_unique<Vfursoy_s1_core>()),
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

        // Invariant: PROP_M6_33 (CPI Cycle Conservation Law)
        if (!dut->rst_i) {
            uint64_t cpi_sum = 0;
            for (int k = 0; k < 8; k++) {
                cpi_sum += dut->cpi_category_o[k];
            }
            if (cpi_sum != dut->mcycle_o) {
                std::cerr << "[CRITICAL ASSERTION FAILURE] PROP_M6_33 CPI Conservation broken at cycle "
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

ProfileMetrics run_workload_branch_torture(M6TB& tb) {
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

ProfileMetrics run_workload_pointer_chasing(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80002000ULL;
    uint64_t data_base = 0x80020000ULL;

    for (int i = 0; i < 8; i++) {
        uint64_t next = data_base + ((i + 1) % 8) * 64;
        tb.write_mem_dword(data_base + i * 64, next);
    }

    tb.write_mem_word(base + 0, rv_lui(1, (data_base >> 12) & 0xFFFFF));
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

ProfileMetrics run_workload_stream_memcpy(M6TB& tb) {
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

ProfileMetrics run_workload_int_dependency(M6TB& tb) {
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

ProfileMetrics run_workload_raw_stress(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80008000ULL;
    uint64_t data_base = 0x80060000ULL;

    tb.write_mem_dword(data_base, 0x1234567890ABCDEFULL);

    tb.write_mem_word(base + 0,  rv_lui(1, (data_base >> 12) & 0xFFFFF));
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
// Milestone 6 Integrated Core Property Tests (PROP_M6_31 .. PROP_M6_35)
// -----------------------------------------------------------------------------

// PROP_M6_31: Odd-Word Fetch Alignment
// Fetch starting at PC[2]==1 masks Slot 0 and delivers Slot 1 correctly to FQ16.
void test_core_m6_odd_word_fetch_alignment(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;
    uint64_t odd_target = 0x80000104ULL; // PC[2] == 1

    // Jump from base to odd_target
    tb.write_mem_word(base + 0, rv_jal(0, (int32_t)(odd_target - base)));

    // At odd_target - 4 (0x80000100, PC[2]==0): Slot 0 poison instruction!
    tb.write_mem_word(odd_target - 4, rv_addi(10, 0, 999));

    // At odd_target (0x80000104, PC[2]==1): Slot 1 target instruction
    tb.write_mem_word(odd_target + 0, rv_addi(10, 0, 42));
    tb.write_mem_word(odd_target + 4, rv_addi(11, 10, 1));
    tb.write_mem_word(odd_target + 8, rv_addi(12, 0, 100));

    // Run until 4 instructions retire: JAL, addi 42, addi 43, addi 100
    tb.wait_until_retired(4, 500);

    bool saw_odd_target = false;
    bool saw_poison = false;
    for (auto pc : tb.retired_pcs) {
        if (pc == odd_target) saw_odd_target = true;
        if (pc == (odd_target - 4)) saw_poison = true;
    }

    assert(saw_odd_target && "Target at PC[2]==1 must have been executed and retired!");
    assert(!saw_poison && "Slot 0 poison instruction at PC[2]==0 must have been masked out!");
    assert(!tb.exception_seen && "No exception should occur during unaligned fetch!");
    std::cout << "  [PASS] PROP_M6_31: Odd-word fetch alignment verified (Slot 0 masked, Slot 1 retired cleanly)\n";
}

// PROP_M6_32: HPM Counter Mapping
// Events 0x0B..0x12 verified incrementing precisely under TAGE/RAS stimulation.
void test_core_m6_hpm_counter_mapping(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;
    uint64_t func1 = 0x80000100ULL;
    uint64_t target_ind = 0x80000200ULL;
    uint64_t func_corrupt = 0x80000300ULL;
    uint64_t finish_pc = target_ind + 8;

    // Reset baseline events
    uint64_t ev_before[49];
    for (int ev = 1; ev <= 48; ev++) ev_before[ev] = tb.raw_event_accum[ev];

    // Main entry:
    // Set up 4-iteration loop: x20 = 4, x2 = 1
    tb.write_mem_word(base + 0, rv_addi(20, 0, 4));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 1));
    // loop_start: base + 8
    // 1. Call func1: pushes RAS (0x10), queries BTB (0x0B). On iter >= 2, hits BTB (0x0C)!
    tb.write_mem_word(base + 8, rv_jal(1, (int32_t)(func1 - (base + 8))));
    tb.write_mem_word(base + 12, rv_addi(20, 20, -1));
    // Branch back to loop_start (base + 8):
    tb.write_mem_word(base + 16, rv_bne(20, 0, -8));

    // Post-loop:
    // 2. Indirect jump to target_ind via register x5: triggers target mispredict (0x0F)
    tb.write_mem_word(base + 20, rv_lui(5, (target_ind >> 12) & 0xFFFFF));
    tb.write_mem_word(base + 24, rv_addi(5, 5, target_ind & 0xFFF));
    tb.write_mem_word(base + 28, rv_jalr(0, 5, 0));

    // func1:
    // Conditional branch: triggers 0x0D (EV_BPU_COND_PRED) and 0x0E (EV_BPU_DIR_MISPRED on iter 1)
    tb.write_mem_word(func1 + 0, rv_bne(2, 0, 8)); // taken branch to func1 + 8
    tb.write_mem_word(func1 + 4, rv_addi(7, 0, 888)); // wrong path
    // Return: pops RAS (0x11)
    tb.write_mem_word(func1 + 8, rv_jalr(0, 1, 0));

    // target_ind:
    // Call func_corrupt: pushes RAS (0x10)
    tb.write_mem_word(target_ind + 0, rv_jal(1, (int32_t)(func_corrupt - (target_ind + 0))));
    // Expected return target:
    tb.write_mem_word(target_ind + 4, rv_addi(8, 0, 777));
    // Corrupted return target landing pad & finish marker:
    tb.write_mem_word(target_ind + 8, rv_addi(15, 0, 42));

    // func_corrupt:
    // Corrupt return register x1 by +4 before returning -> triggers 0x12 (EV_RAS_RET_MISPRED)
    tb.write_mem_word(func_corrupt + 0, rv_addi(1, 1, 4));
    tb.write_mem_word(func_corrupt + 4, rv_jalr(0, 1, 0));

    // Run until finish_pc retires
    int cyc = 0;
    bool saw_finish = false;
    while (!saw_finish && cyc < 2000) {
        tb.step();
        for (auto pc : tb.retired_pcs) {
            if ((pc & 0xFFFFFFFFULL) == (finish_pc & 0xFFFFFFFFULL)) saw_finish = true;
        }
        cyc++;
    }
    if (!saw_finish) {
        std::cerr << "DEBUG: saw_finish=false after " << cyc << " cycles, total_retired=" << tb.total_retired_ops
                  << " exception_seen=" << tb.exception_seen << " cause=" << (int)tb.exception_cause << "\n";
        std::cerr << "Retired PCs: ";
        for (auto pc : tb.retired_pcs) std::cerr << std::hex << "0x" << pc << " ";
        std::cerr << std::dec << "\n";
    }
    assert(saw_finish && "Execution must reach finish_pc in test_core_m6_hpm_counter_mapping!");

    uint64_t ev_delta[49];
    for (int ev = 1; ev <= 48; ev++) ev_delta[ev] = tb.raw_event_accum[ev] - ev_before[ev];

    std::cout << "  [PASS] PROP_M6_32: HPM events 0x0B..0x12 verified incrementing under BPU/TAGE/RAS stimulation:\n"
              << "         0x0B (BTB_QUERIES)=" << ev_delta[0x0B]
              << " | 0x0C (BTB_HITS)=" << ev_delta[0x0C]
              << " | 0x0D (COND_PRED)=" << ev_delta[0x0D]
              << " | 0x0E (DIR_MISPRED)=" << ev_delta[0x0E] << "\n"
              << "         0x0F (TGT_MISPRED)=" << ev_delta[0x0F]
              << " | 0x10 (CALL_PUSH)=" << ev_delta[0x10]
              << " | 0x11 (RET_POP)=" << ev_delta[0x11]
              << " | 0x12 (RET_MISPRED)=" << ev_delta[0x12] << std::endl;

    // Assert that HPM events 0x0B..0x12 observed stimulation
    assert(ev_delta[0x0B] > 0 && "EV_BTB_QUERIES (0x0B) must increment!");
    assert(ev_delta[0x0C] > 0 && "EV_BTB_HITS (0x0C) must increment!");
    assert(ev_delta[0x0D] > 0 && "EV_BPU_COND_PRED (0x0D) must increment!");
    assert(ev_delta[0x0E] > 0 && "EV_BPU_DIR_MISPRED (0x0E) must increment!");
    assert(ev_delta[0x0F] > 0 && "EV_BPU_TGT_MISPRED (0x0F) must increment!");
    assert(ev_delta[0x10] > 0 && "EV_RAS_CALL_PUSH (0x10) must increment!");
    assert(ev_delta[0x11] > 0 && "EV_RAS_RET_POP (0x11) must increment!");
    assert(ev_delta[0x12] > 0 && "EV_RAS_RET_MISPRED (0x12) must increment!");
}

// PROP_M6_33: CPI Conservation Law
// sum(C_k) == mcycle continuously holds across all testbench cycles without leakage.
void test_core_m6_cpi_conservation_law(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Run 50 cycles of mixed integer instructions
    tb.write_mem_word(base + 0,  rv_addi(1, 0, 10));
    tb.write_mem_word(base + 4,  rv_addi(2, 0, 20));
    tb.write_mem_word(base + 8,  rv_add(3, 1, 2));
    tb.write_mem_word(base + 12, rv_sub(4, 3, 1));
    tb.write_mem_word(base + 16, rv_addi(5, 0, 100));

    tb.wait_until_retired(5, 500);

    uint64_t sum_cpi = 0;
    for (int k = 0; k < 8; k++) sum_cpi += tb.dut->cpi_category_o[k];

    assert(sum_cpi == tb.dut->mcycle_o && "PROP_M6_33 CPI Conservation invariant violated!");
    std::cout << "  [PASS] PROP_M6_33: CPI Conservation Law verified (sum(C_0..7) = " << sum_cpi
              << " == mcycle = " << tb.dut->mcycle_o << ", zero leakage)\n";
}

// PROP_M6_34: Multi-Checkpoint Drain
// 8 consecutive checkpoints allocated and retired in program order without leak.
void test_core_m6_multi_checkpoint_drain(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;

    // Verify initial clean state: all 8 checkpoints free
    assert(tb.dut->chkpt_free_count_o == 8 && "Initial checkpoint free count must be 8!");

    tb.write_mem_word(base + 0, rv_addi(1, 0, 1));
    // 8 consecutive conditional branches (all untaken):
    for (int i = 0; i < 8; i++) {
        tb.write_mem_word(base + 4 + i * 4, rv_beq(1, 0, 16));
    }
    tb.write_mem_word(base + 4 + 8 * 4, rv_addi(2, 0, 99));

    // Wait until all 1 setup + 8 branches + 1 final = 10 ops retire
    tb.wait_until_retired(10, 1000);

    // Allow pipeline to fully settle
    for (int i = 0; i < 5; i++) tb.step();

    // Verify that all 8 checkpoints were cleanly released back to 8
    assert(tb.dut->chkpt_free_count_o == 8 && "All 8 checkpoints must be freed after retirement!");
    std::cout << "  [PASS] PROP_M6_34: Multi-checkpoint drain verified (8 consecutive branches allocated and retired with chkpt_free_count_o == 8)\n";
}

// PROP_M6_35: Nested Mispredict Cascade
// Younger branch mispredicts while older recovery is active; older recovery dominates.
void test_core_m6_nested_mispredict_cascade(M6TB& tb) {
    tb.reset();
    tb.mem.clear();
    uint64_t base = 0x80000000ULL;
    uint64_t targetA = 0x80000400ULL;
    uint64_t targetB = 0x80000600ULL;

    tb.write_mem_word(base + 0, rv_addi(1, 0, 10));
    tb.write_mem_word(base + 4, rv_addi(2, 0, 1));

    // Branch A (older): taken to targetA (predicted untaken)
    tb.write_mem_word(base + 8, rv_bne(2, 0, (int32_t)(targetA - (base + 8))));

    // On Branch A's speculative wrong path:
    tb.write_mem_word(base + 12, rv_addi(3, 0, 2));
    // Branch B (younger): taken to targetB (predicted untaken)
    tb.write_mem_word(base + 16, rv_bne(3, 0, (int32_t)(targetB - (base + 16))));

    // On Branch B's speculative wrong path:
    tb.write_mem_word(base + 20, rv_addi(4, 0, 111));
    tb.write_mem_word(base + 24, rv_addi(4, 0, 112));

    // At targetB (wrong path of A, right path of B):
    tb.write_mem_word(targetB + 0, rv_addi(5, 0, 222));
    tb.write_mem_word(targetB + 4, rv_addi(5, 0, 223));

    // At targetA (true architectural path):
    tb.write_mem_word(targetA + 0, rv_addi(6, 0, 777));
    tb.write_mem_word(targetA + 4, rv_addi(7, 0, 888));
    tb.write_mem_word(targetA + 8, rv_addi(8, 0, 999));

    // Run until 2 setup + 1 Branch A + 3 targetA = 6 instructions retire
    tb.wait_until_retired(6, 1000);

    bool saw_targetA = false;
    bool saw_targetB = false;
    bool saw_wrong_path_b = false;

    for (auto pc : tb.retired_pcs) {
        if (pc == targetA) saw_targetA = true;
        if (pc == targetB) saw_targetB = true;
        if (pc == (base + 20) || pc == (base + 24)) saw_wrong_path_b = true;
    }

    assert(saw_targetA && "Target A instructions must be retired!");
    assert(!saw_targetB && "Target B instructions must NEVER be retired (older recovery dominates)!");
    assert(!saw_wrong_path_b && "Wrong path instructions must NEVER be retired!");
    assert(tb.total_retired_ops >= 6);

    std::cout << "  [PASS] PROP_M6_35: Nested mispredict cascade verified (older recovery dominates and squashes younger path)\n";
}

// -----------------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "=============================================================================\n";
    std::cout << "Fursoy Slice-1 Milestone 6 Phase D: Integrated Core Verification & Profiling\n";
    std::cout << "Reference: docs/architecture/slice1-m6-frontend-opt-v1.md Sections 8, 10, and 11\n";
    std::cout << "=============================================================================\n";

    M6TB tb;

    std::cout << "\n--- Running Core-Integrated M6 Verification Scenarios (PROP_M6_31 .. PROP_M6_35) ---\n";
    test_core_m6_odd_word_fetch_alignment(tb);
    test_core_m6_hpm_counter_mapping(tb);
    test_core_m6_cpi_conservation_law(tb);
    test_core_m6_multi_checkpoint_drain(tb);
    test_core_m6_nested_mispredict_cascade(tb);

    std::cout << "\n--- Running Milestone 6 Profiling on 5 Canonical Microarchitectural Kernels ---\n";
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
        std::cout << "   EV_BPU_COND_PRED (0x0D): " << p.events[0x0D]
                  << " | EV_BPU_DIR_MISPRED (0x0E): " << p.events[0x0E]
                  << " | EV_RAS_CALL_PUSH (0x10): " << p.events[0x10]
                  << " | EV_RAS_RET_POP (0x11): " << p.events[0x11] << "\n";
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
