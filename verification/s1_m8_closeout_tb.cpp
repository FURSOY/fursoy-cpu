// =============================================================================
// Fursoy Slice-1 Milestone 8 Integrated Verification & Closeout Testbench
// =============================================================================
// Canonical Reference: docs/architecture/slice1-m8-fp-vector-v1.md Sections 10, 11, 12
//
// Verification & Profiling Scope:
// 1. PROP_M8_37: All 8 new telemetry events (0x39..0x40) increment accurately on triggers.
// 2. PROP_M8_38: Single-Owner CPI Cycle Conservation Law (sum(C_0..7) == mcycle over every cycle).
// 3. PROP_M8_39: Numerical benchmark profiling suite execution (Linpack, SciMark2, Whetstone, Vector).
// 4. PROP_M8_40: Integrated multi-seed stress torture gate across canonical seeds (42, 20260920, 20261009).
// =============================================================================

#include <iostream>
#include <iomanip>
#include <array>
#include <vector>
#include <deque>
#include <map>
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
inline uint32_t rv_lui(uint32_t rd, uint32_t imm20)             { return enc_u(imm20 << 12, rd, 0x37); }
inline uint32_t rv_auipc(uint32_t rd, uint32_t imm20)           { return enc_u(imm20 << 12, rd, 0x17); }
inline uint32_t rv_bne(uint32_t rs1, uint32_t rs2, int32_t imm) { return enc_b(imm, rs2, rs1, 1, 0x63); }
inline uint32_t rv_jal(uint32_t rd, int32_t imm)               { return enc_j(imm, rd, 0x6F); }
inline uint32_t rv_ld(uint32_t rd, uint32_t rs1, int32_t imm)  { return enc_i(imm, rs1, 3, rd, 0x03); }
inline uint32_t rv_sd(uint32_t rs2, uint32_t rs1, int32_t imm) { return enc_s(imm, rs2, rs1, 3, 0x23); }
inline uint32_t rv_fence_i()                                   { return 0x0000100FU; }
inline uint32_t rv_csrrw(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 1, rd, 0x73); }
inline uint32_t rv_csrrs(uint32_t rd, uint32_t csr, uint32_t rs1) { return enc_i(csr, rs1, 2, rd, 0x73); }

// Floating-point RV64D Encoders
inline uint32_t rv_fld(uint32_t rd, uint32_t rs1, int32_t imm)   { return enc_i(imm, rs1, 3, rd, 0x07); }
inline uint32_t rv_fsd(uint32_t rs2, uint32_t rs1, int32_t imm)  { return enc_s(imm, rs2, rs1, 3, 0x27); }
inline uint32_t rv_fmadd_d(uint32_t rd, uint32_t rs1, uint32_t rs2, uint32_t rs3, uint32_t rm=7) {
    return ((rs3 & 0x1F) << 27) | (1 << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((rm & 0x7) << 12) | ((rd & 0x1F) << 7) | 0x43;
}
inline uint32_t rv_fadd_d(uint32_t rd, uint32_t rs1, uint32_t rs2, uint32_t rm=7) {
    return enc_r(0x01, rs2, rs1, rm, rd, 0x53);
}
inline uint32_t rv_fsub_d(uint32_t rd, uint32_t rs1, uint32_t rs2, uint32_t rm=7) {
    return enc_r(0x05, rs2, rs1, rm, rd, 0x53);
}
inline uint32_t rv_fmul_d(uint32_t rd, uint32_t rs1, uint32_t rs2, uint32_t rm=7) {
    return enc_r(0x09, rs2, rs1, rm, rd, 0x53);
}
inline uint32_t rv_fdiv_d(uint32_t rd, uint32_t rs1, uint32_t rs2, uint32_t rm=7) {
    return enc_r(0x0D, rs2, rs1, rm, rd, 0x53);
}
inline uint32_t rv_fsqrt_d(uint32_t rd, uint32_t rs1, uint32_t rm=7) {
    return enc_r(0x2D, 0, rs1, rm, rd, 0x53);
}
inline uint32_t rv_feq_d(uint32_t rd, uint32_t rs1, uint32_t rs2) {
    return enc_r(0x51, rs2, rs1, 2, rd, 0x53);
}
inline uint32_t rv_flt_d(uint32_t rd, uint32_t rs1, uint32_t rs2) {
    return enc_r(0x51, rs2, rs1, 1, rd, 0x53);
}
inline uint32_t rv_fcvt_l_d(uint32_t rd, uint32_t rs1, uint32_t rm=7) {
    return enc_r(0x61, 2, rs1, rm, rd, 0x53);
}
inline uint32_t rv_fcvt_d_l(uint32_t rd, uint32_t rs1, uint32_t rm=7) {
    return enc_r(0x69, 2, rs1, rm, rd, 0x53);
}
inline uint32_t rv_fmv_d_x(uint32_t rd, uint32_t rs1) {
    return enc_r(0x79, 0, rs1, 0, rd, 0x53);
}
inline uint32_t rv_fmv_x_d(uint32_t rd, uint32_t rs1) {
    return enc_r(0x71, 0, rs1, 0, rd, 0x53);
}

// Vector RVV 1.0 Encoders
inline uint32_t rv_vsetvli(uint32_t rd, uint32_t rs1, uint32_t vtypei) {
    return ((vtypei & 0x7FF) << 20) | ((rs1 & 0x1F) << 15) | (7 << 12) | ((rd & 0x1F) << 7) | 0x57;
}
inline uint32_t rv_vsetivli(uint32_t rd, uint32_t uimm, uint32_t vtypei) {
    return (3U << 30) | ((vtypei & 0x3FF) << 20) | ((uimm & 0x1F) << 15) | (7 << 12) | ((rd & 0x1F) << 7) | 0x57;
}
inline uint32_t rv_vle32_v(uint32_t vd, uint32_t rs1, uint32_t vm=1) {
    return ((vm & 1) << 25) | ((rs1 & 0x1F) << 15) | (6 << 12) | ((vd & 0x1F) << 7) | 0x07;
}
inline uint32_t rv_vle32ff_v(uint32_t vd, uint32_t rs1, uint32_t vm=1) {
    return ((vm & 1) << 25) | (0x10U << 20) | ((rs1 & 0x1F) << 15) | (6 << 12) | ((vd & 0x1F) << 7) | 0x07;
}
inline uint32_t rv_vse32_v(uint32_t vs3, uint32_t rs1, uint32_t vm=1) {
    return ((vm & 1) << 25) | ((rs1 & 0x1F) << 15) | (6 << 12) | ((vs3 & 0x1F) << 7) | 0x27;
}
inline uint32_t rv_vadd_vx(uint32_t vd, uint32_t vs2, uint32_t rs1, uint32_t vm=1) {
    return ((vm & 1) << 25) | ((vs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | (4 << 12) | ((vd & 0x1F) << 7) | 0x57;
}
inline uint32_t rv_vadd_vi(uint32_t vd, uint32_t vs2, int32_t simm5, uint32_t vm=1) {
    return ((vm & 1) << 25) | ((vs2 & 0x1F) << 20) | ((simm5 & 0x1F) << 15) | (3 << 12) | ((vd & 0x1F) << 7) | 0x57;
}
inline uint32_t rv_vmul_vx(uint32_t vd, uint32_t vs2, uint32_t rs1, uint32_t vm=1) {
    return (0x25U << 26) | ((vm & 1) << 25) | ((vs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | (6 << 12) | ((vd & 0x1F) << 7) | 0x57;
}
inline uint32_t rv_vredsum_vs(uint32_t vd, uint32_t vs2, uint32_t vs1, uint32_t vm=1) {
    return ((vm & 1) << 25) | ((vs2 & 0x1F) << 20) | ((vs1 & 0x1F) << 15) | (2 << 12) | ((vd & 0x1F) << 7) | 0x57;
}

inline void emit_la_pc(std::vector<uint32_t>& prog, uint64_t code_base, uint32_t rd, uint64_t target) {
    uint64_t cur_pc = code_base + prog.size() * 4ULL;
    int64_t diff = (int64_t)(target - cur_pc);
    int32_t hi = (int32_t)((diff + 0x800LL) >> 12);
    int32_t lo = (int32_t)(diff & 0xFFFLL);
    if (lo >= 0x800) lo -= 0x1000;
    prog.push_back(rv_auipc(rd, (uint32_t)hi));
    prog.push_back(rv_addi(rd, rd, lo));
}

inline void emit_enable_fs_vs(std::vector<uint32_t>& prog, uint32_t scratch_gpr = 10) {
    prog.push_back(rv_lui(scratch_gpr, 0x2));
    prog.push_back(rv_addi(scratch_gpr, scratch_gpr, 0x200)); // 0x2200: FS=01, VS=01
    prog.push_back(rv_csrrs(0, 0x300, scratch_gpr));          // csrs mstatus, scratch_gpr
}

inline uint64_t dbl_to_u64(double d) {
    uint64_t u = 0;
    memcpy(&u, &d, 8);
    return u;
}

// -----------------------------------------------------------------------------
// Workload Profiling Metrics Structure
// -----------------------------------------------------------------------------
struct ProfileMetrics {
    std::string name;
    bool synthetic_stimulus = false;
    uint32_t stimulus_vl = 0;
    uint64_t elapsed_cycles = 0;
    uint64_t elapsed_instret = 0;
    double ipc = 0.0;
    uint64_t cpi_cat[8] = {};
    uint64_t events[65] = {};
};

// -----------------------------------------------------------------------------
// Milestone 8 Integrated Verification & Profiling Harness
// -----------------------------------------------------------------------------
class M8CloseoutTB {
public:
    std::unique_ptr<Vfursoy_s1_core> dut;
    std::map<uint64_t, std::vector<uint8_t>> mem; // 64-byte line aligned memory
    uint64_t cycle_count;
    uint64_t total_retired_ops;
    uint64_t raw_event_accum[65];

    struct L1IBusReq {
        uint64_t addr;
        uint8_t  tag;
        int      delay;
    };
    std::deque<L1IBusReq> l1i_bus_q;

    struct L1DBusReq {
        uint64_t addr;
        uint8_t  tag;
        int      delay;
    };
    std::deque<L1DBusReq> l1d_bus_q;

    M8CloseoutTB() {
        dut = std::make_unique<Vfursoy_s1_core>();
        cycle_count = 0;
        total_retired_ops = 0;
        memset(raw_event_accum, 0, sizeof(raw_event_accum));
        reset();
    }

    void write_mem_word(uint64_t paddr, uint32_t inst) {
        uint64_t line_addr = paddr >> 6;
        uint32_t offset    = paddr & 0x3F;
        if (mem.find(line_addr) == mem.end()) {
            mem[line_addr] = std::vector<uint8_t>(64, 0x13); // NOPs
        }
        memcpy(&mem[line_addr][offset], &inst, 4);
    }

    void write_mem_dword(uint64_t paddr, uint64_t data) {
        uint64_t line_addr = paddr >> 6;
        uint32_t offset    = paddr & 0x3F;
        if (mem.find(line_addr) == mem.end()) {
            mem[line_addr] = std::vector<uint8_t>(64, 0x13);
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

    void reset(uint64_t initial_mstatus = (1ULL << 13) | (1ULL << 9)) {
        dut->rst_i                 = 1;
        dut->clk_i                 = 0;
        dut->frontend_en_i         = 1;
        dut->priv_mode_i           = 3; // M-mode
        dut->mstatus_i             = initial_mstatus; // FS=Initial, VS=Initial
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

        dut->uop0_valid_i          = 0;
        dut->uop0_rs1_i            = 0;
        dut->uop0_rs2_i            = 0;
        dut->uop0_rd_i             = 0;
        dut->uop0_class_i          = 0;
        dut->uop0_subop_i          = 0;
        dut->uop0_imm_i            = 0;
        dut->uop0_use_imm_i        = 0;
        dut->uop0_pc_i             = 0;
        dut->uop0_pred_taken_i     = 0;
        dut->uop0_pred_target_i    = 0;
        dut->uop0_is_branch_i      = 0;
        dut->uop0_is_jal_i         = 0;
        dut->uop0_is_jalr_i        = 0;
        dut->uop0_is_fp_i          = 0;
        dut->uop0_fp_dest_valid_i  = 0;
        dut->uop0_fs3_i            = 0;
        dut->uop0_frm_i            = 0;
        dut->uop0_is_vec_i         = 0;
        dut->uop0_vec_dest_valid_i = 0;
        dut->uop0_prd_vec_i        = 0;
        dut->uop1_valid_i          = 0;
        dut->probe_paddr_i         = 0;

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

        dut->snoop_req_valid_i      = 0;
        dut->snoop_req_addr_i       = 0;
        dut->snoop_req_type_i       = 0;

        dut->test_inject_valid_i    = 0;
        dut->test_inject_data_i     = 0;
        dut->test_inject_pnew_i     = 0;
        dut->test_inject_rob_idx_i  = 0;
        dut->test_inject_rob_epoch_i= 0;
        dut->test_inject_mispredict_i = 0;

        dut->test_fp_w0_valid_i     = 0;
        dut->test_fp_w1_valid_i     = 0;
        dut->test_fp_w2_valid_i     = 0;
        dut->probe_fp_paddr_i       = 0;

        dut->test_vrf_w_valid_i     = 0;
        dut->probe_vrf_paddr_i      = 0;
        dut->test_vec_cfg_valid_i   = 0;
        dut->test_fof_fault_valid_i = 0;

        dut->test_ev_fp_issue_i        = 0;
        dut->test_ev_fp_fma_busy_i     = 0;
        dut->test_ev_fp_fdiv_stall_i   = 0;
        dut->test_ev_fp_rename_stall_i = 0;
        dut->test_ev_vec_uop_commit_i  = 0;
        dut->test_ev_vec_mem_traffic_i = 0;
        dut->test_ev_vec_viq_full_i    = 0;
        dut->test_ev_vec_fof_trunc_i   = 0;

        l1i_bus_q.clear();
        l1d_bus_q.clear();

        for (int i = 0; i < 15; i++) {
            dut->clk_i = 0; dut->eval();
            dut->clk_i = 1; dut->eval();
            cycle_count++;
        }
        dut->rst_i = 0;
        dut->mstatus_i = 0; // Release external force, allow internal mstatus_q to evolve
        dut->l1i_bus_rd_req_ready_i = 0;
        dut->bus_rd_req_ready_i     = 0;
        dut->ptw_mem_req_ready_i    = 0;

        // Wait for freelist and status reconstruction to complete
        for (int i = 0; i < 20; i++) {
            dut->clk_i = 0; dut->eval();
            dut->clk_i = 1; dut->eval();
            cycle_count++;
            if (!dut->reconstructing_o && !dut->fl_fp_reconstructing_o) break;
        }
        dut->l1i_bus_rd_req_ready_i = 1;
        dut->bus_rd_req_ready_i     = 1;
        dut->ptw_mem_req_ready_i    = 1;
    }

    void step() {
        // 1. Clock Low Phase
        dut->clk_i = 0;
        dut->eval();

        // Service L1I read requests
        if (dut->l1i_bus_rd_req_valid_o && dut->l1i_bus_rd_req_ready_i) {
            L1IBusReq req;
            req.addr  = dut->l1i_bus_rd_req_addr_o;
            req.tag   = dut->l1i_bus_rd_req_tag_o;
            req.delay = 1;
            l1i_bus_q.push_back(req);
        }

        // Service L1D read requests
        if (dut->bus_rd_req_valid_o && dut->bus_rd_req_ready_i) {
            L1DBusReq req;
            req.addr  = dut->bus_rd_req_addr_o;
            req.tag   = dut->bus_rd_req_tag_o;
            req.delay = 1;
            l1d_bus_q.push_back(req);
        }

        // Service L1D writeback evictions
        if (dut->bus_wr_req_valid_o && dut->bus_wr_req_ready_i) {
            uint64_t line_addr = dut->bus_wr_req_addr_o;
            if (mem.find(line_addr) == mem.end()) mem[line_addr] = std::vector<uint8_t>(64, 0);
            memcpy(mem[line_addr].data(), (void*)&dut->bus_wr_req_data_o, 64);
            dut->bus_wr_rsp_valid_i = 1;
        } else {
            dut->bus_wr_rsp_valid_i = 0;
        }

        // L1I response delivery
        if (!l1i_bus_q.empty() && l1i_bus_q.front().delay == 0) {
            L1IBusReq req = l1i_bus_q.front();
            l1i_bus_q.pop_front();
            dut->l1i_bus_rd_rsp_valid_i = 1;
            dut->l1i_bus_rd_rsp_tag_i   = req.tag;
            dut->l1i_bus_rd_rsp_error_i = 0;
            if (mem.find(req.addr) != mem.end()) {
                memcpy((void*)&dut->l1i_bus_rd_rsp_data_i, mem[req.addr].data(), 64);
            } else {
                memset((void*)&dut->l1i_bus_rd_rsp_data_i, 0x13, 64); // NOPs
            }
        } else {
            dut->l1i_bus_rd_rsp_valid_i = 0;
            for (auto& r : l1i_bus_q) if (r.delay > 0) r.delay--;
        }

        // L1D response delivery
        if (!l1d_bus_q.empty() && l1d_bus_q.front().delay == 0) {
            L1DBusReq req = l1d_bus_q.front();
            l1d_bus_q.pop_front();
            dut->bus_rd_rsp_valid_i = 1;
            dut->bus_rd_rsp_tag_i   = req.tag;
            if (mem.find(req.addr) != mem.end()) {
                memcpy((void*)&dut->bus_rd_rsp_data_i, mem[req.addr].data(), 64);
            } else {
                memset((void*)&dut->bus_rd_rsp_data_i, 0, 64);
            }
        } else {
            dut->bus_rd_rsp_valid_i = 0;
            for (auto& r : l1d_bus_q) if (r.delay > 0) r.delay--;
        }

        // 2. Clock High Phase
        dut->clk_i = 1;
        dut->eval();
        cycle_count++;

        // Track event pulses
        for (int e = 1; e <= 64; e++) {
            if ((dut->raw_event_pulse_o >> (e - 1)) & 1ULL) {
                raw_event_accum[e]++;
            }
        }

        // Single-Owner CPI Cycle Conservation Assertion
        if (!dut->rst_i) {
            uint64_t cpi_sum = 0;
            for (int k = 0; k < 8; k++) {
                cpi_sum += dut->cpi_category_o[k];
            }
            assert(cpi_sum == dut->mcycle_o && "[CPI LEAKAGE ERROR] sum(C_k) != mcycle!");
        }

        if (dut->retire_valid_o & 1) total_retired_ops++;
        if (dut->retire_valid_o & 2) total_retired_ops++;
    }

    void wait_until_retired(uint64_t target_ops, uint64_t max_cycles = 10000) {
        uint64_t start_cycles = cycle_count;
        uint64_t start_ops = total_retired_ops;
        while ((total_retired_ops - start_ops) < target_ops && (cycle_count - start_cycles) < max_cycles) {
            step();
        }
    }

    bool wait_until_pc(uint64_t halt_pc, uint64_t max_cycles = 15000) {
        uint64_t start_cycles = cycle_count;
        uint64_t last_ret_pc = 0;
        while ((cycle_count - start_cycles) < max_cycles) {
            step();
            assert(!dut->retire_exception_o && "Unexpected architectural exception in benchmark!");
            if (dut->retire_valid_o & 1) last_ret_pc = dut->retire_pc_o[0];
            if (dut->retire_valid_o & 2) last_ret_pc = dut->retire_pc_o[1];
            if (((dut->retire_valid_o & 1) && dut->retire_pc_o[0] == halt_pc) ||
                ((dut->retire_valid_o & 2) && dut->retire_pc_o[1] == halt_pc)) {
                return true;
            }
        }
        std::cerr << "[TIMEOUT] halt_pc=0x" << std::hex << halt_pc
                  << " last_ret_pc=0x" << last_ret_pc
                  << " instret=" << std::dec << dut->minstret_o
                  << " rob_cnt=" << (int)dut->rob_count_o
                  << " fpiq_free=" << (int)dut->rootp->fursoy_s1_core__DOT__u_backend__DOT__u_fp_iq__DOT__free_count
                  << " head_v=" << (int)dut->diag_head_valid_o
                  << " head_c=" << (int)dut->diag_head_completed_o
                  << " head_rd=" << (int)dut->diag_head_rd_o
                  << " fl_fp_cnt=" << (int)dut->fl_fp_count_o
                  << " prf_fp_rdy=0x" << std::hex << dut->prf_fp_ready_o << std::dec
                  << " srat[1..5]=" << (int)dut->srat_fp_map_o[1] << "," << (int)dut->srat_fp_map_o[2]
                  << "," << (int)dut->srat_fp_map_o[3] << "," << (int)dut->srat_fp_map_o[4] << "," << (int)dut->srat_fp_map_o[5]
                  << " arat[4..5]=" << (int)dut->arat_fp_map_o[4] << "," << (int)dut->arat_fp_map_o[5]
                  << "\n";
        return false;
    }

    uint64_t read_arch_gpr(uint32_t gpr_idx) {
        uint8_t paddr = dut->arat_map_o[gpr_idx];
        dut->probe_paddr_i = paddr;
        dut->eval();
        return dut->probe_pdata_o;
    }

    uint64_t read_arch_fpr(uint32_t fpr_idx) {
        uint8_t paddr = dut->arat_fp_map_o[fpr_idx];
        dut->probe_fp_paddr_i = paddr;
        dut->eval();
        return dut->probe_fp_pdata_o;
    }

    std::array<uint32_t, 8> read_vrf_reg(uint32_t vreg_idx) {
        dut->probe_vrf_paddr_i = vreg_idx;
        dut->eval();
        std::array<uint32_t, 8> words{};
        for (int w = 0; w < 8; w++) words[w] = dut->probe_vrf_pdata_o[w];
        return words;
    }
};

// -----------------------------------------------------------------------------
// Test 1: PROP_M8_37 — HPM FP & Vector Telemetry Events (0x39 .. 0x40)
// -----------------------------------------------------------------------------
void test_prop_m8_37_telemetry_events(M8CloseoutTB& tb) {
    tb.reset();
    std::cout << "[RUN] Testing PROP_M8_37: All 8 new telemetry events (0x39..0x40)...\n";

    uint64_t ev_before[65];
    for (int e = 1; e <= 64; e++) ev_before[e] = tb.raw_event_accum[e];

    // 1. Stimulate EV_FP_ISSUE (0x39)
    tb.dut->test_ev_fp_issue_i = 1;
    tb.step();
    tb.dut->test_ev_fp_issue_i = 0;

    // 2. Stimulate EV_FP_FMA_BUSY (0x3A)
    tb.dut->test_ev_fp_fma_busy_i = 1;
    tb.step();
    tb.dut->test_ev_fp_fma_busy_i = 0;

    // 3. Stimulate EV_FP_FDIV_STALL (0x3B)
    tb.dut->test_ev_fp_fdiv_stall_i = 1;
    tb.step();
    tb.dut->test_ev_fp_fdiv_stall_i = 0;

    // 4. Stimulate EV_FP_RENAME_STALL (0x3C)
    tb.dut->test_ev_fp_rename_stall_i = 1;
    tb.step();
    tb.dut->test_ev_fp_rename_stall_i = 0;

    // 5. Stimulate EV_VEC_UOP_COMMIT (0x3D)
    tb.dut->test_ev_vec_uop_commit_i = 1;
    tb.step();
    tb.dut->test_ev_vec_uop_commit_i = 0;

    // 6. Stimulate EV_VEC_MEM_TRAFFIC (0x3E)
    tb.dut->test_ev_vec_mem_traffic_i = 1;
    tb.step();
    tb.dut->test_ev_vec_mem_traffic_i = 0;

    // 7. Stimulate EV_VEC_VIQ_FULL (0x3F)
    tb.dut->test_ev_vec_viq_full_i = 1;
    tb.step();
    tb.dut->test_ev_vec_viq_full_i = 0;

    // 8. Stimulate EV_VEC_FOF_TRUNC (0x40)
    tb.dut->test_ev_vec_fof_trunc_i = 1;
    tb.step();
    tb.dut->test_ev_vec_fof_trunc_i = 0;

    tb.step();

    for (int ev = 0x39; ev <= 0x40; ev++) {
        uint64_t delta = tb.raw_event_accum[ev] - ev_before[ev];
        assert(delta >= 1 && "Telemetry event must increment upon trigger!");
    }

    std::cout << "  -> PASS: All 8 new telemetry events (0x39..0x40) verified cleanly\n";
}

// -----------------------------------------------------------------------------
// Test 2: PROP_M8_38 — Single-Owner CPI Cycle Conservation Law
// -----------------------------------------------------------------------------
void test_prop_m8_38_cpi_conservation(M8CloseoutTB& tb) {
    tb.reset();
    std::cout << "[RUN] Testing PROP_M8_38: Single-Owner CPI Cycle Conservation Law...\n";

    // Run 500 cycles with dynamic mixed operations
    for (int c = 0; c < 500; c++) {
        tb.step();
        uint64_t cpi_sum = 0;
        for (int k = 0; k < 8; k++) {
            cpi_sum += tb.dut->cpi_category_o[k];
        }
        assert(cpi_sum == tb.dut->mcycle_o && "CPI Conservation Law violated!");
    }

    std::cout << "  -> PASS: Continuous assertion of sum(C_0..7) == mcycle holds with 0 cycle leakage\n";
}

// -----------------------------------------------------------------------------
// Test 3: PROP_M8_39 — Numerical Benchmark Profiling Suite
// -----------------------------------------------------------------------------
ProfileMetrics run_benchmark_linpack(M8CloseoutTB& tb) {
    tb.reset(0);
    tb.mem.clear();
    uint64_t code_base = 0x80000000ULL;
    uint64_t a_base    = 0x80010000ULL;
    uint64_t x_base    = 0x80011000ULL;
    uint64_t y_base    = 0x80012000ULL;

    const int N = 8;
    const double alpha = 2.5;
    std::array<double, N> x_vals{}, y_vals{};
    tb.write_mem_dword(a_base, dbl_to_u64(alpha));
    for (int i = 0; i < N; i++) {
        x_vals[i] = 1.0 * (i + 1);
        y_vals[i] = 10.0 * (i + 1);
        tb.write_mem_dword(x_base + i * 8, dbl_to_u64(x_vals[i]));
        tb.write_mem_dword(y_base + i * 8, dbl_to_u64(y_vals[i]));
    }

    std::vector<uint32_t> prog;
    emit_enable_fs_vs(prog, 10);
    emit_la_pc(prog, code_base, 5, a_base);
    emit_la_pc(prog, code_base, 6, x_base);
    emit_la_pc(prog, code_base, 7, y_base);
    prog.push_back(rv_addi(8, 0, N));     // x8 = N
    prog.push_back(rv_fld(0, 5, 0));      // f0 = alpha

    size_t loop_idx = prog.size();
    prog.push_back(rv_fld(1, 6, 0));      // f1 = x[i]
    prog.push_back(rv_fld(2, 7, 0));      // f2 = y[i]
    prog.push_back(rv_fmadd_d(3, 0, 1, 2)); // f3 = alpha * x[i] + y[i]
    prog.push_back(rv_fsd(3, 7, 0));      // y[i] = f3
    prog.push_back(rv_addi(6, 6, 8));
    prog.push_back(rv_addi(7, 7, 8));
    prog.push_back(rv_addi(8, 8, -1));
    int32_t bne_off = (int32_t)(((int64_t)loop_idx - (int64_t)prog.size()) * 4);
    prog.push_back(rv_bne(8, 0, bne_off));
    prog.push_back(rv_fence_i());
    uint64_t halt_pc = code_base + prog.size() * 4ULL;
    prog.push_back(rv_jal(0, 0));

    for (size_t i = 0; i < prog.size(); i++) tb.write_mem_word(code_base + i * 4ULL, prog[i]);

    uint64_t start_cyc = tb.dut->mcycle_o;
    uint64_t start_ret = tb.dut->minstret_o;
    uint64_t cpi_start[8];
    for (int k = 0; k < 8; k++) cpi_start[k] = tb.dut->cpi_category_o[k];
    uint64_t ev_start[65];
    for (int ev = 1; ev <= 64; ev++) ev_start[ev] = tb.raw_event_accum[ev];

    assert(tb.wait_until_pc(halt_pc, 15000) && "linpack_daxpy timed out!");

    uint64_t elapsed_cyc = tb.dut->mcycle_o - start_cyc;
    uint64_t elapsed_ret = tb.dut->minstret_o - start_ret;

    // Verify architectural outputs
    assert(tb.dut->mstatus_fs_o == 3 && "linpack_daxpy failed to set mstatus.FS = Dirty!");
    for (int i = 0; i < N; i++) {
        double expected = alpha * x_vals[i] + y_vals[i];
        uint64_t got_bits = tb.read_mem_dword(y_base + i * 8);
        assert(got_bits == dbl_to_u64(expected) && "linpack_daxpy DRAM result mismatch!");
    }

    ProfileMetrics m;
    m.name = "linpack_daxpy";
    m.synthetic_stimulus = false;
    m.elapsed_cycles  = elapsed_cyc ? elapsed_cyc : 1;
    m.elapsed_instret = elapsed_ret;
    m.ipc = (double)elapsed_ret / (double)m.elapsed_cycles;
    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_start[k];
    for (int ev = 1; ev <= 64; ev++) m.events[ev] = tb.raw_event_accum[ev] - ev_start[ev];
    return m;
}

ProfileMetrics run_benchmark_scimark2(M8CloseoutTB& tb) {
    tb.reset(0);
    tb.mem.clear();
    uint64_t code_base = 0x80000000ULL;
    uint64_t c_base    = 0x80018000ULL;
    uint64_t g_base    = 0x80019000ULL;

    const int N = 6;
    const double omega_q = 0.125; // omega / 4 = 0.5 / 4
    const double one_m_w = 0.5;   // 1 - omega
    std::array<double, N + 2> g{};
    for (int i = 0; i < N + 2; i++) g[i] = 1.0 + 0.5 * i;

    tb.write_mem_dword(c_base + 0, dbl_to_u64(omega_q));
    tb.write_mem_dword(c_base + 8, dbl_to_u64(one_m_w));
    for (int i = 0; i < N + 2; i++) tb.write_mem_dword(g_base + i * 8, dbl_to_u64(g[i]));

    std::vector<uint32_t> prog;
    emit_enable_fs_vs(prog, 10);
    emit_la_pc(prog, code_base, 5, c_base);
    emit_la_pc(prog, code_base, 6, g_base + 8); // &g[1]
    prog.push_back(rv_addi(7, 0, N));
    prog.push_back(rv_fld(0, 5, 0));            // f0 = omega/4
    prog.push_back(rv_fld(1, 5, 8));            // f1 = 1 - omega

    size_t loop_idx = prog.size();
    prog.push_back(rv_fld(2, 6, -8));           // g[i-1]
    prog.push_back(rv_fld(3, 6, 8));            // g[i+1]
    prog.push_back(rv_fld(4, 6, 0));            // g[i]
    prog.push_back(rv_fadd_d(5, 2, 3));         // g[i-1] + g[i+1]
    prog.push_back(rv_fmul_d(5, 0, 5));         // omega/4 * (g[i-1] + g[i+1])
    prog.push_back(rv_fmadd_d(4, 1, 4, 5));     // (1-omega)*g[i] + omega/4*(...)
    prog.push_back(rv_fsd(4, 6, 0));
    prog.push_back(rv_addi(6, 6, 8));
    prog.push_back(rv_addi(7, 7, -1));
    int32_t bne_off = (int32_t)(((int64_t)loop_idx - (int64_t)prog.size()) * 4);
    prog.push_back(rv_bne(7, 0, bne_off));
    prog.push_back(rv_fence_i());
    uint64_t halt_pc = code_base + prog.size() * 4ULL;
    prog.push_back(rv_jal(0, 0));

    for (size_t i = 0; i < prog.size(); i++) tb.write_mem_word(code_base + i * 4ULL, prog[i]);

    uint64_t start_cyc = tb.dut->mcycle_o;
    uint64_t start_ret = tb.dut->minstret_o;
    uint64_t cpi_start[8];
    for (int k = 0; k < 8; k++) cpi_start[k] = tb.dut->cpi_category_o[k];
    uint64_t ev_start[65];
    for (int ev = 1; ev <= 64; ev++) ev_start[ev] = tb.raw_event_accum[ev];

    assert(tb.wait_until_pc(halt_pc, 15000) && "scimark2_sor timed out!");

    uint64_t elapsed_cyc = tb.dut->mcycle_o - start_cyc;
    uint64_t elapsed_ret = tb.dut->minstret_o - start_ret;

    assert(tb.dut->mstatus_fs_o == 3 && "scimark2_sor failed to set mstatus.FS = Dirty!");
    for (int i = 1; i <= N; i++) {
        g[i] = one_m_w * g[i] + omega_q * (g[i - 1] + g[i + 1]);
        uint64_t got_bits = tb.read_mem_dword(g_base + i * 8);
        assert(got_bits == dbl_to_u64(g[i]) && "scimark2_sor DRAM result mismatch!");
    }

    ProfileMetrics m;
    m.name = "scimark2_sor";
    m.synthetic_stimulus = false;
    m.elapsed_cycles  = elapsed_cyc ? elapsed_cyc : 1;
    m.elapsed_instret = elapsed_ret;
    m.ipc = (double)elapsed_ret / (double)m.elapsed_cycles;
    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_start[k];
    for (int ev = 1; ev <= 64; ev++) m.events[ev] = tb.raw_event_accum[ev] - ev_start[ev];
    return m;
}

ProfileMetrics run_benchmark_whetstone(M8CloseoutTB& tb) {
    tb.reset(0);
    tb.mem.clear();
    uint64_t code_base = 0x80000000ULL;
    uint64_t out_base  = 0x80020000ULL;

    std::vector<uint32_t> prog;
    emit_enable_fs_vs(prog, 10);
    emit_la_pc(prog, code_base, 5, out_base);
    prog.push_back(rv_addi(6, 0, 9));       // x6 = 9
    prog.push_back(rv_addi(7, 0, 3));       // x7 = 3
    prog.push_back(rv_fcvt_d_l(0, 6));      // f0 = 9.0
    prog.push_back(rv_fcvt_d_l(1, 7));      // f1 = 3.0
    prog.push_back(rv_fsqrt_d(2, 0));       // f2 = sqrt(9.0) = 3.0
    prog.push_back(rv_feq_d(11, 2, 1));     // x11 = (sqrt(9.0) == 3.0) = 1
    prog.push_back(rv_addi(8, 0, 1));
    prog.push_back(rv_fcvt_d_l(3, 8));      // f3 = 1.0
    prog.push_back(rv_fdiv_d(4, 3, 1));     // f4 = 1.0 / 3.0 (inexact -> NX flag)
    prog.push_back(rv_fadd_d(5, 4, 2));     // f5 = 3.0 + 1.0/3.0
    prog.push_back(rv_fmul_d(5, 5, 1));     // f5 = (3.0 + 1.0/3.0) * 3.0 (~10.0)
    prog.push_back(rv_fsd(5, 5, 0));        // out[0] = f5
    prog.push_back(rv_fcvt_l_d(12, 2));     // x12 = 3
    prog.push_back(rv_csrrs(13, 0x001, 0)); // x13 = fflags
    prog.push_back(rv_fence_i());
    uint64_t halt_pc = code_base + prog.size() * 4ULL;
    prog.push_back(rv_jal(0, 0));

    for (size_t i = 0; i < prog.size(); i++) tb.write_mem_word(code_base + i * 4ULL, prog[i]);

    uint64_t start_cyc = tb.dut->mcycle_o;
    uint64_t start_ret = tb.dut->minstret_o;
    uint64_t cpi_start[8];
    for (int k = 0; k < 8; k++) cpi_start[k] = tb.dut->cpi_category_o[k];
    uint64_t ev_start[65];
    for (int ev = 1; ev <= 64; ev++) ev_start[ev] = tb.raw_event_accum[ev];

    assert(tb.wait_until_pc(halt_pc, 15000) && "whetstone_kernel timed out!");

    uint64_t elapsed_cyc = tb.dut->mcycle_o - start_cyc;
    uint64_t elapsed_ret = tb.dut->minstret_o - start_ret;

    double exp_f5 = ((1.0 / 3.0) + 3.0) * 3.0;
    assert(tb.dut->mstatus_fs_o == 3 && "whetstone_kernel failed to set mstatus.FS = Dirty!");
    assert(tb.read_arch_gpr(11) == 1 && "whetstone feq.d mismatch!");
    assert(tb.read_arch_gpr(12) == 3 && "whetstone fcvt.l.d mismatch!");
    assert((tb.read_arch_gpr(13) & 0x1ULL) == 1 && "whetstone fflags.NX not accrued!");
    assert((tb.dut->fcsr_fflags_o & 0x1) == 1 && "whetstone fcsr.fflags mismatch!");
    assert(tb.read_mem_dword(out_base) == dbl_to_u64(exp_f5) && "whetstone DRAM result mismatch!");

    ProfileMetrics m;
    m.name = "whetstone_kernel";
    m.synthetic_stimulus = false;
    m.elapsed_cycles  = elapsed_cyc ? elapsed_cyc : 1;
    m.elapsed_instret = elapsed_ret;
    m.ipc = (double)elapsed_ret / (double)m.elapsed_cycles;
    for (int k = 0; k < 8; k++) m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_start[k];
    for (int ev = 1; ev <= 64; ev++) m.events[ev] = tb.raw_event_accum[ev] - ev_start[ev];
    return m;
}

ProfileMetrics run_benchmark_vector(M8CloseoutTB& tb) {
    tb.reset(0);
    tb.mem.clear();
    uint64_t code_base = 0x80000000ULL;
    uint64_t src_base  = 0x80030000ULL;
    uint64_t msk_base  = 0x80031000ULL;
    uint64_t red_base  = 0x80031800ULL;
    uint64_t dst_base  = 0x80032000ULL;
    uint64_t fof_base  = 0x8FFFFFF8ULL; // Last 8 bytes inside DRAM before 0x90000000

    for (uint32_t i = 0; i < 8; i++) {
        uint64_t pair = ((uint64_t)((i * 2 + 2) * 10) << 32) | (uint64_t)((i * 2 + 1) * 10);
        if (i < 4) tb.write_mem_dword(src_base + i * 8, pair);
    }
    tb.write_mem_dword(msk_base, 0x0000000000000055ULL); // bits 0,2,4,6
    tb.write_mem_dword(red_base, 100ULL);                // initial sum = 100
    tb.write_mem_dword(fof_base, 0xBB000022AA000011ULL); // 2 valid elements at end of DRAM

    std::vector<uint32_t> prog;
    emit_enable_fs_vs(prog, 10);
    emit_la_pc(prog, code_base, 5, src_base);
    emit_la_pc(prog, code_base, 6, msk_base);
    emit_la_pc(prog, code_base, 7, dst_base);
    emit_la_pc(prog, code_base, 8, red_base);
    emit_la_pc(prog, code_base, 17, fof_base);

    prog.push_back(rv_addi(12, 0, 8));             // vl target = 8
    prog.push_back(rv_addi(13, 0, 3));             // mul factor = 3
    prog.push_back(rv_addi(15, 0, 1000));          // masked addend = 1000
    prog.push_back(rv_vsetvli(11, 12, 0x0D0));     // e32, m1, ta, ma -> vl=8
    prog.push_back(rv_vle32_v(2, 5, 1));           // v2 = {10..80}
    prog.push_back(rv_vle32_v(0, 6, 1));           // v0 mask = 0x55
    prog.push_back(rv_vle32_v(6, 8, 1));           // v6[0] = 100
    prog.push_back(rv_vmul_vx(3, 2, 13, 1));       // v3 = v2 * 3
    prog.push_back(rv_vadd_vi(4, 3, 7, 1));        // v4 = v3 + 7 = {37,67,...,247}
    prog.push_back(rv_vredsum_vs(5, 4, 6, 1));     // v5[0] = 100 + 1136 = 1236
    prog.push_back(rv_vadd_vx(4, 4, 15, 0));       // masked vadd.vx v4, v4, x15, v0.t
    prog.push_back(rv_vse32_v(4, 7, 1));           // store v4 to dst_base
    prog.push_back(rv_fence_i());                  // flush dirty L1D lines to backing DRAM
    prog.push_back(rv_vsetivli(16, 4, 0x0D0));     // vl = 4, e32, m1
    prog.push_back(rv_vle32ff_v(7, 17, 1));        // faults on element 2 -> truncates vl to 2
    prog.push_back(rv_csrrs(18, 0xC20, 0));        // x18 = vl (expected 2)
    uint64_t halt_pc = code_base + prog.size() * 4ULL;
    prog.push_back(rv_jal(0, 0));

    for (size_t i = 0; i < prog.size(); i++) tb.write_mem_word(code_base + i * 4ULL, prog[i]);

    uint64_t start_cyc = tb.dut->mcycle_o;
    uint64_t start_ret = tb.dut->minstret_o;
    uint64_t cpi_start[8];
    for (int k = 0; k < 8; k++) cpi_start[k] = tb.dut->cpi_category_o[k];
    uint64_t ev_start[65];
    for (int ev = 1; ev <= 64; ev++) ev_start[ev] = tb.raw_event_accum[ev];

    assert(tb.wait_until_pc(halt_pc, 15000) && "vector_stream timed out!");

    uint64_t elapsed_cyc = tb.dut->mcycle_o - start_cyc;
    uint64_t elapsed_ret = tb.dut->minstret_o - start_ret;

    // Verify architectural VRF, CSRs, and DRAM results
    assert(tb.dut->mstatus_vs_o == 3 && "vector_stream failed to set mstatus.VS = Dirty!");
    assert(tb.dut->vl_o == 2 && "vector_stream vle32ff failed to truncate vl to 2!");
    assert(tb.dut->vtype_o == 0xD0ULL && "vector_stream vtype mismatch!");
    assert(tb.read_arch_gpr(11) == 8 && "vector_stream vsetvli rd mismatch!");
    assert(tb.read_arch_gpr(18) == 2 && "vector_stream post-FOF csrr vl mismatch!");
    auto v5_words = tb.read_vrf_reg(5);
    assert(v5_words[0] == 1236U && "vector_stream vredsum.vs result mismatch!");
    auto v7_words = tb.read_vrf_reg(7);
    assert(v7_words[0] == 0xAA000011U && v7_words[1] == 0xBB000022U &&
           "vector_stream vle32ff valid elements mismatch!");

    const uint32_t expected_dst[8] = {1037, 67, 1097, 127, 1157, 187, 1217, 247};
    for (int i = 0; i < 4; i++) {
        uint64_t got_q = tb.read_mem_dword(dst_base + i * 8);
        uint32_t lo = (uint32_t)(got_q & 0xFFFFFFFFULL);
        uint32_t hi = (uint32_t)(got_q >> 32);
        assert(lo == expected_dst[i * 2] && hi == expected_dst[i * 2 + 1] &&
               "vector_stream vse32 DRAM result mismatch!");
    }

    ProfileMetrics m;
    m.name = "vector_stream";
    m.synthetic_stimulus = false;
    m.elapsed_cycles  = elapsed_cyc ? elapsed_cyc : 1;
    m.elapsed_instret = elapsed_ret;
    m.ipc = (double)elapsed_ret / (double)m.elapsed_cycles;
    uint64_t cpi_sum = 0;
    for (int k = 0; k < 8; k++) {
        m.cpi_cat[k] = tb.dut->cpi_category_o[k] - cpi_start[k];
        cpi_sum += m.cpi_cat[k];
    }
    assert(cpi_sum == m.elapsed_cycles && "Vector profile CPI delta conservation violated!");
    for (int ev = 1; ev <= 64; ev++) m.events[ev] = tb.raw_event_accum[ev] - ev_start[ev];
    return m;
}

// -----------------------------------------------------------------------------
// Test 4: PROP_M8_40 — Multi-Seed Stress Torture Gate (75,000 Ops)
// -----------------------------------------------------------------------------
struct TortureStats {
    uint64_t ops_completed = 0;
    uint64_t comparisons_checked = 0;
    uint64_t mismatches = 0;
    bool mismatch_detector_self_test_passed = false;
};

static inline bool compare_and_record(const char* rf_name, uint32_t idx, uint64_t actual,
                                      uint64_t expected, uint64_t& comparisons,
                                      uint64_t& mismatches, bool log_on_mismatch = true) {
    comparisons++;
    if (actual != expected) {
        mismatches++;
        if (log_on_mismatch && mismatches <= 10) {
            std::cerr << "[TORTURE MISMATCH] " << rf_name << "[" << idx << "] actual=0x"
                      << std::hex << actual << " expected=0x" << expected << std::dec << "\n";
        }
        return false;
    }
    return true;
}

TortureStats test_prop_m8_40_stress_torture(M8CloseoutTB& tb) {
    std::cout << "\n[RUN] Testing PROP_M8_40: Multi-Seed Stress Torture Gate (75,000 Ops)...\n";
    const uint64_t seeds[3] = {42ULL, 20260920ULL, 20261009ULL};
    TortureStats stats;

    // Negative self-test: prove that a deliberate scoreboard/probe divergence is caught
    {
        uint64_t self_cmp = 0, self_mis = 0;
        bool matched = compare_and_record("SELF_TEST", 7, 0x1122334455667788ULL,
                                          0x1122334455667789ULL, self_cmp, self_mis, false);
        assert(!matched && self_cmp == 1 && self_mis == 1 &&
               "Torture mismatch detector self-test failed to catch injected discrepancy!");
        stats.mismatch_detector_self_test_passed = true;
        std::cout << "  [SELF-TEST] Mismatch catcher verified (1 deliberate mismatch detected).\n";
    }

    for (int s = 0; s < 3; s++) {
        uint64_t seed = seeds[s];
        std::mt19937_64 rng(seed);
        tb.reset();
        tb.dut->frontend_en_i = 0; // Drive deterministic micro-ops & direct register writes

        std::array<uint64_t, 32> shadow_arch_int{};
        std::array<uint64_t, 64> shadow_fprf{};
        std::array<std::array<uint32_t, 8>, 48> shadow_vrf{};

        for (uint64_t op = 0; op < 25000; op++) {
            uint32_t op_type = rng() % 5;
            switch (op_type) {
                case 0: { // Integer op through real rename/ALU/PRF/ARAT pipeline + probe_pdata_o check
                    uint32_t rd = (rng() % 31) + 1;
                    uint64_t val = rng();
                    tb.dut->uop0_valid_i   = 1;
                    tb.dut->uop0_class_i   = 0; // UOP_ALU_INT
                    tb.dut->uop0_subop_i   = 0; // ALU_ADD
                    tb.dut->uop0_rs1_i     = 0;
                    tb.dut->uop0_rs2_i     = 0;
                    tb.dut->uop0_rd_i      = rd;
                    tb.dut->uop0_use_imm_i = 1;
                    tb.dut->uop0_imm_i     = val;
                    tb.dut->uop0_pc_i      = 0x80000000ULL + (op * 4);
                    tb.dut->clk_i = 0;
                    tb.dut->eval();
                    assert((tb.dut->rename_ack_o & 1) && "Int torture uop0 rejected unexpectedly!");
                    tb.step();
                    tb.dut->uop0_valid_i = 0;

                    int wait_c = 0;
                    while (tb.dut->rob_count_o > 0 && wait_c < 20) {
                        tb.step();
                        wait_c++;
                    }
                    assert(tb.dut->rob_count_o == 0 && "Int torture uop timed out in ROB!");
                    shadow_arch_int[rd] = val;

                    uint8_t paddr = tb.dut->arat_map_o[rd];
                    tb.dut->probe_paddr_i = paddr;
                    tb.dut->eval();
                    compare_and_record("INT_PRF", paddr, tb.dut->probe_pdata_o,
                                       shadow_arch_int[rd], stats.comparisons_checked, stats.mismatches);

                    uint32_t chk_r = (rng() % 31) + 1;
                    uint8_t chk_p = tb.dut->arat_map_o[chk_r];
                    tb.dut->probe_paddr_i = chk_p;
                    tb.dut->eval();
                    compare_and_record("INT_PRF_SPOT", chk_p, tb.dut->probe_pdata_o,
                                       shadow_arch_int[chk_r], stats.comparisons_checked, stats.mismatches);
                    break;
                }
                case 1: { // FP writeback via test_fp_w0_valid_i + probe_fp_pdata_o check
                    uint32_t fp_rd = rng() % 64;
                    uint64_t fp_val = rng();
                    tb.dut->test_fp_w0_valid_i = 1;
                    tb.dut->test_fp_w0_paddr_i = fp_rd;
                    tb.dut->test_fp_w0_data_i  = fp_val;
                    tb.step();
                    tb.dut->test_fp_w0_valid_i = 0;
                    shadow_fprf[fp_rd] = fp_val;

                    tb.dut->probe_fp_paddr_i = fp_rd;
                    tb.dut->eval();
                    compare_and_record("FPRF", fp_rd, tb.dut->probe_fp_pdata_o,
                                       shadow_fprf[fp_rd], stats.comparisons_checked, stats.mismatches);

                    uint32_t chk_fp = rng() % 64;
                    tb.dut->probe_fp_paddr_i = chk_fp;
                    tb.dut->eval();
                    compare_and_record("FPRF_SPOT", chk_fp, tb.dut->probe_fp_pdata_o,
                                       shadow_fprf[chk_fp], stats.comparisons_checked, stats.mismatches);
                    break;
                }
                case 2: { // Vector write via test_vrf_w_valid_i + probe_vrf_pdata_o check (256-bit)
                    uint32_t vrd = rng() % 48;
                    uint32_t byte_mask = (rng() % 4 == 0) ? (uint32_t)rng() : 0xFFFFFFFFU;
                    std::array<uint32_t, 8> wwords{};
                    for (int w = 0; w < 8; w++) {
                        wwords[w] = (uint32_t)rng();
                        tb.dut->test_vrf_w_data_i[w] = wwords[w];
                    }
                    tb.dut->test_vrf_w_valid_i     = 1;
                    tb.dut->test_vrf_w_paddr_i     = vrd;
                    tb.dut->test_vrf_w_byte_mask_i = byte_mask;
                    tb.step();
                    tb.dut->test_vrf_w_valid_i     = 0;

                    for (int w = 0; w < 8; w++) {
                        uint32_t bank_bytes = (byte_mask >> (w * 4)) & 0xF;
                        for (int b = 0; b < 4; b++) {
                            if ((bank_bytes >> b) & 1U) {
                                uint32_t bmask = 0xFFU << (b * 8);
                                shadow_vrf[vrd][w] = (shadow_vrf[vrd][w] & ~bmask) | (wwords[w] & bmask);
                            }
                        }
                    }

                    tb.dut->probe_vrf_paddr_i = vrd;
                    tb.dut->eval();
                    for (int w = 0; w < 8; w++) {
                        compare_and_record("VRF", vrd * 8 + w, tb.dut->probe_vrf_pdata_o[w],
                                           shadow_vrf[vrd][w], stats.comparisons_checked, stats.mismatches);
                    }

                    uint32_t chk_v = rng() % 48;
                    tb.dut->probe_vrf_paddr_i = chk_v;
                    tb.dut->eval();
                    for (int w = 0; w < 8; w++) {
                        compare_and_record("VRF_SPOT", chk_v * 8 + w, tb.dut->probe_vrf_pdata_o[w],
                                           shadow_vrf[chk_v][w], stats.comparisons_checked, stats.mismatches);
                    }
                    break;
                }
                case 3: { // Telemetry pulse
                    uint32_t ev_sel = 0x39 + (rng() % 8);
                    if (ev_sel == 0x39) tb.dut->test_ev_fp_issue_i = 1;
                    if (ev_sel == 0x3A) tb.dut->test_ev_fp_fma_busy_i = 1;
                    if (ev_sel == 0x3B) tb.dut->test_ev_fp_fdiv_stall_i = 1;
                    if (ev_sel == 0x3C) tb.dut->test_ev_fp_rename_stall_i = 1;
                    if (ev_sel == 0x3D) tb.dut->test_ev_vec_uop_commit_i = 1;
                    if (ev_sel == 0x3E) tb.dut->test_ev_vec_mem_traffic_i = 1;
                    if (ev_sel == 0x3F) tb.dut->test_ev_vec_viq_full_i = 1;
                    if (ev_sel == 0x40) tb.dut->test_ev_vec_fof_trunc_i = 1;
                    tb.step();
                    tb.dut->test_ev_fp_issue_i        = 0;
                    tb.dut->test_ev_fp_fma_busy_i     = 0;
                    tb.dut->test_ev_fp_fdiv_stall_i   = 0;
                    tb.dut->test_ev_fp_rename_stall_i = 0;
                    tb.dut->test_ev_vec_uop_commit_i  = 0;
                    tb.dut->test_ev_vec_mem_traffic_i = 0;
                    tb.dut->test_ev_vec_viq_full_i    = 0;
                    tb.dut->test_ev_vec_fof_trunc_i   = 0;
                    break;
                }
                default: {
                    tb.step();
                    break;
                }
            }
            stats.ops_completed++;
        }
        std::cout << "  [TORTURE] Seed " << seed << " completed 25,000 ops (checked="
                  << stats.comparisons_checked << ", mismatches=" << stats.mismatches << ")\n";
    }
    assert(stats.mismatches == 0 && "PROP_M8_40 failed with shadow scoreboard mismatches!");
    std::cout << "  -> PASS: PROP_M8_40 Multi-Seed Stress Torture complete ("
              << stats.ops_completed << " ops, " << stats.comparisons_checked
              << " probe checks, " << stats.mismatches << " mismatches)\n";
    return stats;
}

// -----------------------------------------------------------------------------
// Main Function
// -----------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "=============================================================================\n";
    std::cout << "Fursoy Slice-1 Milestone 8 Integrated Closeout Verification Suite\n";
    std::cout << "Specification: docs/architecture/slice1-m8-fp-vector-v1.md v1.1\n";
    std::cout << "=============================================================================\n";

    M8CloseoutTB tb;

    // 1. Verify PROP_M8_37
    test_prop_m8_37_telemetry_events(tb);

    // 2. Verify PROP_M8_38
    test_prop_m8_38_cpi_conservation(tb);

    // 3. Verify PROP_M8_39
    std::cout << "\n[RUN] Testing PROP_M8_39: Numerical Benchmark Profiling Suite...\n";
    std::vector<ProfileMetrics> profiles;
    profiles.push_back(run_benchmark_linpack(tb));
    profiles.push_back(run_benchmark_scimark2(tb));
    profiles.push_back(run_benchmark_whetstone(tb));
    ProfileMetrics vec_real = run_benchmark_vector(tb);
    assert(!vec_real.synthetic_stimulus && vec_real.elapsed_instret > 0);
    assert(vec_real.events[0x3D] > 0 && "EV_VEC_UOP_COMMIT did not fire on fetched vector execution!");
    assert(vec_real.events[0x40] >= 1 && "EV_VEC_FOF_TRUNC did not fire on fetched vle32ff!");
    profiles.push_back(vec_real);
    std::cout << "  -> PASS: Numerical benchmark profiling executed to completion (100% genuine fetched RV64IMAFDV workloads verified)\n";

    // 4. Verify PROP_M8_40
    TortureStats torture_stats = test_prop_m8_40_stress_torture(tb);

    // Output Machine-Readable JSON
    std::cout << "\n--- BEGIN JSON PROFILE DATA ---\n";
    std::cout << "{\n";
    std::cout << "  \"status\": \"pass\",\n";
    std::cout << "  \"total_properties_tested\": 4,\n";
    std::cout << "  \"properties_passed\": 4,\n";
    std::cout << "  \"passed_properties\": [\n";
    std::cout << "    \"PROP_M8_37\",\n";
    std::cout << "    \"PROP_M8_38\",\n";
    std::cout << "    \"PROP_M8_39\",\n";
    std::cout << "    \"PROP_M8_40\"\n";
    std::cout << "  ],\n";
    std::cout << "  \"cpi_conservation_status\": \"pass\",\n";
    std::cout << "  \"torture_ops_completed\": " << torture_stats.ops_completed << ",\n";
    std::cout << "  \"comparisons_checked\": " << torture_stats.comparisons_checked << ",\n";
    std::cout << "  \"torture_mismatches\": " << torture_stats.mismatches << ",\n";
    std::cout << "  \"mismatch_detector_self_test\": \"" << (torture_stats.mismatch_detector_self_test_passed ? "pass" : "fail") << "\",\n";
    std::cout << "  \"profiles\": {\n";
    for (size_t p = 0; p < profiles.size(); p++) {
        const auto& m = profiles[p];
        std::cout << "    \"" << m.name << "\": {\n";
        std::cout << "      \"synthetic_stimulus\": " << (m.synthetic_stimulus ? "true" : "false") << ",\n";
        if (m.synthetic_stimulus) {
            std::cout << "      \"stimulus_vl\": " << m.stimulus_vl << ",\n";
        }
        std::cout << "      \"cycles\": " << m.elapsed_cycles << ",\n";
        std::cout << "      \"instret\": " << m.elapsed_instret << ",\n";
        std::cout << "      \"ipc\": " << std::fixed << std::setprecision(4) << m.ipc << ",\n";
        std::cout << "      \"cpi_breakdown\": {\n";
        std::cout << "        \"C_serialize\": " << m.cpi_cat[0] << ",\n";
        std::cout << "        \"C_br_recover\": " << m.cpi_cat[1] << ",\n";
        std::cout << "        \"C_productive\": " << m.cpi_cat[2] << ",\n";
        std::cout << "        \"C_mem_stall\": " << m.cpi_cat[3] << ",\n";
        std::cout << "        \"C_be_rename\": " << m.cpi_cat[4] << ",\n";
        std::cout << "        \"C_be_sched\": " << m.cpi_cat[5] << ",\n";
        std::cout << "        \"C_fe_starve\": " << m.cpi_cat[6] << ",\n";
        std::cout << "        \"C_idle_other\": " << m.cpi_cat[7] << "\n";
        std::cout << "      },\n";
        std::cout << "      \"events\": {\n";
        for (int ev = 1; ev <= 64; ev++) {
            std::cout << "        \"" << format_event_id(ev) << "\": " << m.events[ev]
                      << (ev < 64 ? ",\n" : "\n");
        }
        std::cout << "      }\n";
        std::cout << "    }" << (p < profiles.size() - 1 ? ",\n" : "\n");
    }
    std::cout << "  }\n";
    std::cout << "}\n";
    std::cout << "--- END JSON PROFILE DATA ---\n\n";

    std::cout << "=============================================================================\n";
    std::cout << "Milestone 8 Closeout Verification Complete: ALL PASS\n";
    std::cout << "=============================================================================\n";
    return 0;
}
