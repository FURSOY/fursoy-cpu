// =============================================================================
// Fursoy Slice-1 Differential Co-Simulation Testbench (vs. sail-riscv)
// =============================================================================
// Executes compiled ELF PT_LOAD segments on fursoy_s1_core (frontend_en_i = 1)
// starting at 0x0000_0000_8000_0000 and records an ordered JSONL architectural
// commit/trap trace for instruction-by-instruction comparison against Sail.
// =============================================================================

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "Vfursoy_s1_core.h"
#include "verilated.h"

namespace {

constexpr uint64_t kDramBase  = 0x0000000080000000ULL;
constexpr uint64_t kDramLimit = 0x0000000090000000ULL; // 256 MiB [0x8000_0000, 0x9000_0000)

struct MemSegment {
    uint64_t paddr;
    std::string path;
};

struct BusReq {
    uint64_t addr;
    uint8_t  tag;
    int      delay;
};

struct PtwReq {
    uint64_t paddr;
    int      delay;
};

class SailCosimTB {
public:
    std::unique_ptr<Vfursoy_s1_core> dut;
    std::map<uint64_t, std::vector<uint8_t>> mem;
    std::deque<BusReq> l1i_bus_q;
    std::deque<BusReq> l1d_bus_q;
    std::deque<PtwReq> ptw_bus_q;
    uint64_t cycle_count = 0;
    bool prev_exc_valid = false;

    SailCosimTB() {
        dut = std::make_unique<Vfursoy_s1_core>();
    }

    void load_segment(uint64_t paddr, const std::string& bin_path) {
        std::ifstream ifs(bin_path, std::ios::binary);
        if (!ifs) {
            std::cerr << "ERROR: Failed to open segment binary: " << bin_path << "\n";
            std::exit(2);
        }
        std::vector<uint8_t> data((std::istreambuf_iterator<char>(ifs)),
                                  std::istreambuf_iterator<char>());
        for (size_t i = 0; i < data.size(); i++) {
            uint64_t pa = paddr + i;
            uint64_t line_addr = pa >> 6;
            uint32_t offset = static_cast<uint32_t>(pa & 0x3FULL);
            auto it = mem.find(line_addr);
            if (it == mem.end()) {
                it = mem.emplace(line_addr, std::vector<uint8_t>(64, 0)).first;
            }
            it->second[offset] = data[i];
        }
    }

    uint64_t read_dram_qword(uint64_t pa) const {
        uint64_t aligned = pa & ~7ULL;
        uint64_t line_addr = aligned >> 6;
        uint32_t offset = static_cast<uint32_t>(aligned & 0x3FULL);
        auto it = mem.find(line_addr);
        if (it == mem.end()) return 0ULL;
        uint64_t val = 0;
        std::memcpy(&val, &it->second[offset], 8);
        return val;
    }

    void reset() {
        dut->rst_i                  = 1;
        dut->clk_i                  = 0;
        dut->frontend_en_i          = 1;
        dut->priv_mode_i            = 3; // Let internal csr_priv_mode control privilege transitions
        dut->mstatus_i              = 0; // Reset cleanly (FS=0, VS=0) just like Sail
        dut->satp_i                 = 0; // Let internal csr_satp drive Sv39 translation
        dut->pmp_allow_i            = 1;
        dut->trap_valid_i           = 0;
        dut->trap_target_i          = 0;
        dut->mret_valid_i           = 0;
        dut->mret_target_i          = 0;
        dut->sfence_vma_valid_i     = 0;
        dut->sfence_vma_va_i        = 0;
        dut->sfence_vma_asid_i      = 0;
        dut->retire_ready_i         = 1;
        dut->flush_valid_i          = 0;

        dut->uop0_valid_i           = 0;
        dut->uop0_rs1_i             = 0;
        dut->uop0_rs2_i             = 0;
        dut->uop0_rd_i              = 0;
        dut->uop0_class_i           = 0;
        dut->uop0_subop_i           = 0;
        dut->uop0_imm_i             = 0;
        dut->uop0_use_imm_i         = 0;
        dut->uop0_pc_i              = 0;
        dut->uop0_pred_taken_i      = 0;
        dut->uop0_pred_target_i     = 0;
        dut->uop0_is_branch_i       = 0;
        dut->uop0_is_jal_i          = 0;
        dut->uop0_is_jalr_i         = 0;
        dut->uop0_is_fp_i           = 0;
        dut->uop0_fp_dest_valid_i   = 0;
        dut->uop0_fs3_i             = 0;
        dut->uop0_frm_i             = 0;
        dut->uop0_is_vec_i          = 0;
        dut->uop0_vec_dest_valid_i  = 0;
        dut->uop0_prd_vec_i         = 0;
        dut->uop1_valid_i           = 0;
        dut->uop1_rs1_i             = 0;
        dut->uop1_rs2_i             = 0;
        dut->uop1_rd_i              = 0;
        dut->uop1_class_i           = 0;
        dut->uop1_subop_i           = 0;
        dut->uop1_imm_i             = 0;
        dut->uop1_use_imm_i         = 0;
        dut->uop1_pc_i              = 0;
        dut->uop1_pred_taken_i      = 0;
        dut->uop1_pred_target_i     = 0;
        dut->uop1_is_branch_i       = 0;
        dut->uop1_is_jal_i          = 0;
        dut->uop1_is_jalr_i         = 0;
        dut->uop1_is_fp_i           = 0;
        dut->uop1_fp_dest_valid_i   = 0;
        dut->uop1_fs3_i             = 0;
        dut->uop1_frm_i             = 0;
        dut->uop1_is_vec_i          = 0;
        dut->uop1_vec_dest_valid_i  = 0;
        dut->uop1_prd_vec_i         = 0;

        dut->probe_paddr_i          = 0;
        dut->probe_fp_paddr_i       = 0;
        dut->probe_vrf_paddr_i      = 0;

        dut->test_dtlb_req_valid_i    = 0;
        dut->test_dtlb_req_tr_id_i    = 0;
        dut->test_dtlb_req_vpn_i      = 0;
        dut->test_dtlb_req_is_store_i = 0;
        dut->test_dtlb_req_is_amo_i   = 0;

        dut->l1i_bus_rd_req_ready_i = 1;
        dut->l1i_bus_rd_rsp_valid_i = 0;
        dut->l1i_bus_rd_rsp_tag_i   = 0;
        std::memset((void*)&dut->l1i_bus_rd_rsp_data_i, 0, sizeof(dut->l1i_bus_rd_rsp_data_i));
        dut->l1i_bus_rd_rsp_error_i = 0;

        dut->ptw_mem_req_ready_i    = 1;
        dut->ptw_mem_rsp_valid_i    = 0;
        dut->ptw_mem_rsp_data_i     = 0;
        dut->ptw_mem_rsp_error_i    = 0;

        dut->bus_rd_req_ready_i     = 1;
        dut->bus_rd_rsp_valid_i     = 0;
        dut->bus_rd_rsp_tag_i       = 0;
        std::memset((void*)&dut->bus_rd_rsp_data_i, 0, sizeof(dut->bus_rd_rsp_data_i));

        dut->bus_wr_req_ready_i     = 1;
        dut->bus_wr_rsp_valid_i     = 0;

        dut->snoop_req_valid_i      = 0;
        dut->snoop_req_addr_i       = 0;
        dut->snoop_req_type_i       = 0;

        dut->irq_timer_i            = 0;
        dut->irq_software_i         = 0;
        dut->irq_external_i         = 0;
        dut->irq_seip_i             = 0;
        dut->test_csr_we_i          = 0;
        dut->test_csr_addr_i        = 0;
        dut->test_csr_wdata_i       = 0;

        dut->test_inject_valid_i    = 0;
        dut->test_inject_data_i     = 0;
        dut->test_inject_pnew_i     = 0;
        dut->test_inject_rob_idx_i  = 0;
        dut->test_inject_rob_epoch_i= 0;
        dut->test_inject_mispredict_i = 0;

        dut->comp_fp_wb_valid_i     = 0;
        for (int i = 0; i < 3; i++) dut->comp_fp_wb_preg_i[i] = 0;
        for (int i = 0; i < 5; i++) dut->comp_fflags_i[i] = 0;
        dut->test_fp_w0_valid_i     = 0;
        dut->test_fp_w1_valid_i     = 0;
        dut->test_fp_w2_valid_i     = 0;
        dut->test_vrf_w_valid_i     = 0;
        dut->test_vec_cfg_valid_i   = 0;
        dut->test_fof_fault_valid_i = 0;
        dut->test_viq_alloc_valid_i = 0;
        dut->test_viq_issue_ready_i = 0;

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
        ptw_bus_q.clear();
        cycle_count = 0;
        prev_exc_valid = false;

        for (int i = 0; i < 15; i++) {
            dut->clk_i = 0; dut->eval();
            dut->clk_i = 1; dut->eval();
            cycle_count++;
        }
        dut->rst_i = 0;

        for (int i = 0; i < 20; i++) {
            dut->clk_i = 0; dut->eval();
            dut->clk_i = 1; dut->eval();
            cycle_count++;
            if (!dut->reconstructing_o && !dut->fl_fp_reconstructing_o) break;
        }
    }

    struct PreRetireSlot {
        uint64_t pc;
        uint8_t  rd;
        uint8_t  pnew;
        uint8_t  is_fp;
        uint8_t  fp_dest_valid;
        uint8_t  prd_fp;
        uint8_t  is_vec;
        uint8_t  vec_dest_valid;
        uint8_t  prd_vec;
    };

    void step_and_trace(std::ostream& trace_out, bool& hit_htif, uint64_t htif_pc, bool has_htif_pc) {
        // 1. Clock Low Phase
        dut->clk_i = 0;
        dut->eval();

        // Capture pre-posedge retirement & exception signals
        uint8_t retire_mask = dut->retire_valid_o & 0x3U;
        std::vector<PreRetireSlot> retiring;
        for (int k = 0; k < 2; k++) {
            if ((retire_mask >> k) & 1U) {
                PreRetireSlot s{};
                s.pc             = dut->retire_pc_o[k];
                s.rd             = dut->retire_rd_o[k];
                s.pnew           = dut->retire_pnew_o[k];
                s.is_fp          = (dut->retire_is_fp_o >> k) & 1U;
                s.fp_dest_valid  = (dut->retire_fp_dest_valid_o >> k) & 1U;
                s.prd_fp         = dut->retire_prd_fp_o[k];
                s.is_vec         = (dut->retire_is_vec_o >> k) & 1U;
                s.vec_dest_valid = (dut->retire_vec_dest_valid_o >> k) & 1U;
                s.prd_vec        = dut->retire_prd_vec_o[k];
                retiring.push_back(s);
            }
        }

        bool     exc_valid = (dut->retire_exception_o != 0);
        uint64_t exc_pc    = dut->retire_exc_pc_o;
        uint32_t exc_cause = dut->retire_exc_cause_o;
        uint32_t pre_priv  = dut->csr_priv_mode_o;

        // Service L1I read requests
        if (dut->l1i_bus_rd_req_valid_o && dut->l1i_bus_rd_req_ready_i) {
            BusReq req{};
            req.addr  = dut->l1i_bus_rd_req_addr_o;
            req.tag   = dut->l1i_bus_rd_req_tag_o;
            req.delay = 1;
            l1i_bus_q.push_back(req);
        }

        // Service L1D read requests
        if (dut->bus_rd_req_valid_o && dut->bus_rd_req_ready_i) {
            BusReq req{};
            req.addr  = dut->bus_rd_req_addr_o;
            req.tag   = dut->bus_rd_req_tag_o;
            req.delay = 1;
            l1d_bus_q.push_back(req);
        }

        // Service L1D writeback evictions
        if (dut->bus_wr_req_valid_o && dut->bus_wr_req_ready_i) {
            uint64_t line_addr = dut->bus_wr_req_addr_o;
            auto it = mem.find(line_addr);
            if (it == mem.end()) {
                it = mem.emplace(line_addr, std::vector<uint8_t>(64, 0)).first;
            }
            std::memcpy(it->second.data(), (const void*)&dut->bus_wr_req_data_o, 64);
            dut->bus_wr_rsp_valid_i = 1;
        } else {
            dut->bus_wr_rsp_valid_i = 0;
        }

        // Service PTW memory read requests
        if (dut->ptw_mem_req_valid_o && dut->ptw_mem_req_ready_i) {
            PtwReq req{};
            req.paddr = dut->ptw_mem_req_addr_o;
            req.delay = 1;
            ptw_bus_q.push_back(req);
        }

        // L1I response delivery
        if (!l1i_bus_q.empty() && l1i_bus_q.front().delay == 0) {
            BusReq req = l1i_bus_q.front();
            l1i_bus_q.pop_front();
            dut->l1i_bus_rd_rsp_valid_i = 1;
            dut->l1i_bus_rd_rsp_tag_i   = req.tag;
            uint64_t byte_pa = req.addr << 6;
            if (byte_pa >= kDramBase && byte_pa < kDramLimit) {
                dut->l1i_bus_rd_rsp_error_i = 0;
                auto it = mem.find(req.addr);
                if (it != mem.end()) {
                    std::memcpy((void*)&dut->l1i_bus_rd_rsp_data_i, it->second.data(), 64);
                } else {
                    std::memset((void*)&dut->l1i_bus_rd_rsp_data_i, 0, 64);
                }
            } else {
                dut->l1i_bus_rd_rsp_error_i = 1;
                std::memset((void*)&dut->l1i_bus_rd_rsp_data_i, 0, 64);
            }
        } else {
            dut->l1i_bus_rd_rsp_valid_i = 0;
            for (auto& r : l1i_bus_q) if (r.delay > 0) r.delay--;
        }

        // L1D response delivery
        if (!l1d_bus_q.empty() && l1d_bus_q.front().delay == 0) {
            BusReq req = l1d_bus_q.front();
            l1d_bus_q.pop_front();
            dut->bus_rd_rsp_valid_i = 1;
            dut->bus_rd_rsp_tag_i   = req.tag;
            auto it = mem.find(req.addr);
            if (it != mem.end()) {
                std::memcpy((void*)&dut->bus_rd_rsp_data_i, it->second.data(), 64);
            } else {
                std::memset((void*)&dut->bus_rd_rsp_data_i, 0, 64);
            }
        } else {
            dut->bus_rd_rsp_valid_i = 0;
            for (auto& r : l1d_bus_q) if (r.delay > 0) r.delay--;
        }

        // PTW response delivery
        if (!ptw_bus_q.empty() && ptw_bus_q.front().delay == 0) {
            PtwReq req = ptw_bus_q.front();
            ptw_bus_q.pop_front();
            dut->ptw_mem_rsp_valid_i = 1;
            if (req.paddr >= kDramBase && (req.paddr + 8ULL) <= kDramLimit) {
                dut->ptw_mem_rsp_error_i = 0;
                dut->ptw_mem_rsp_data_i  = read_dram_qword(req.paddr);
            } else {
                dut->ptw_mem_rsp_error_i = 1;
                dut->ptw_mem_rsp_data_i  = 0;
            }
        } else {
            dut->ptw_mem_rsp_valid_i = 0;
            for (auto& r : ptw_bus_q) if (r.delay > 0) r.delay--;
        }

        // 2. Clock High Phase (Architectural state commits on this posedge)
        dut->clk_i = 1;
        dut->eval();
        cycle_count++;

        // 3. Emit Post-Commit Trace Records (RF writes and CSRs have settled)
        for (size_t idx = 0; idx < retiring.size(); idx++) {
            const auto& s = retiring[idx];
            uint64_t gpr_val = 0;
            uint64_t fpr_val = 0;
            std::array<uint32_t, 8> vrf_words{};

            if (s.fp_dest_valid) {
                dut->probe_fp_paddr_i = s.prd_fp;
                dut->eval();
                fpr_val = dut->probe_fp_pdata_o;
            } else if (s.vec_dest_valid) {
                dut->probe_vrf_paddr_i = s.prd_vec;
                dut->eval();
                for (int w = 0; w < 8; w++) vrf_words[w] = dut->probe_vrf_pdata_o[w];
            } else if (s.rd != 0) {
                dut->probe_paddr_i = s.pnew;
                dut->eval();
                gpr_val = dut->probe_pdata_o;
            }

            std::ostringstream vrf_hex;
            vrf_hex << "0x" << std::hex << std::setfill('0');
            for (int w = 7; w >= 0; w--) {
                vrf_hex << std::setw(8) << vrf_words[w];
            }

            trace_out << "{\"type\":\"retire\""
                      << ",\"cycle\":" << std::dec << cycle_count
                      << ",\"slot_last\":" << ((idx + 1 == retiring.size()) ? 1 : 0)
                      << ",\"pc\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << s.pc << "\""
                      << ",\"rd\":" << std::dec << (int)s.rd
                      << ",\"vd\":" << std::dec << (int)s.prd_vec
                      << ",\"fp_dest\":" << (int)s.fp_dest_valid
                      << ",\"vec_dest\":" << (int)s.vec_dest_valid
                      << ",\"gpr\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << gpr_val << "\""
                      << ",\"fpr\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << fpr_val << "\""
                      << ",\"vrf\":\"" << vrf_hex.str() << "\""
                      << ",\"priv\":" << std::dec << (int)dut->csr_priv_mode_o
                      << ",\"fflags\":" << std::dec << (int)dut->fcsr_fflags_o
                      << ",\"vl\":" << std::dec << dut->vl_o
                      << ",\"vtype\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->vtype_o << "\""
                      << ",\"mstatus\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_mstatus_o << "\""
                      << ",\"satp\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_satp_o << "\""
                      << "}\n";

            if (has_htif_pc && s.pc == htif_pc) {
                hit_htif = true;
            }
        }

        // sys_flush_valid_o is registered in fursoy_s1_csr, so retire_exception_o stays
        // asserted for two consecutive cycles (trap-latch cycle + ROB-flush cycle).
        if (exc_valid && !prev_exc_valid) {
            trace_out << "{\"type\":\"trap\""
                      << ",\"cycle\":" << std::dec << cycle_count
                      << ",\"pc\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << exc_pc << "\""
                      << ",\"cause\":" << std::dec << exc_cause
                      << ",\"pre_priv\":" << std::dec << pre_priv
                      << ",\"post_priv\":" << std::dec << (int)dut->csr_priv_mode_o
                      << ",\"mcause\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_mcause_o << "\""
                      << ",\"mepc\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_mepc_o << "\""
                      << ",\"mtval\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_mtval_o << "\""
                      << ",\"scause\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_scause_o << "\""
                      << ",\"sepc\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_sepc_o << "\""
                      << ",\"stval\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_stval_o << "\""
                      << ",\"mstatus\":\"0x" << std::hex << std::setfill('0') << std::setw(16) << dut->csr_mstatus_o << "\""
                      << "}\n";
        }
        prev_exc_valid = exc_valid;
    }
};

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::vector<MemSegment> segments;
    std::string trace_path;
    uint64_t htif_pc = 0;
    bool has_htif_pc = false;
    uint64_t max_cycles = 500000ULL;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--seg" && i + 1 < argc) {
            std::string val = argv[++i];
            size_t colon = val.find(':');
            if (colon == std::string::npos) {
                std::cerr << "Invalid --seg format (expected hexaddr:path): " << val << "\n";
                return 2;
            }
            MemSegment seg;
            seg.paddr = std::stoull(val.substr(0, colon), nullptr, 16);
            seg.path  = val.substr(colon + 1);
            segments.push_back(seg);
        } else if (arg == "--trace-out" && i + 1 < argc) {
            trace_path = argv[++i];
        } else if (arg == "--htif-pc" && i + 1 < argc) {
            htif_pc = std::stoull(argv[++i], nullptr, 16);
            has_htif_pc = true;
        } else if (arg == "--max-cycles" && i + 1 < argc) {
            max_cycles = std::stoull(argv[++i], nullptr, 0);
        } else {
            std::cerr << "Unknown or incomplete argument: " << arg << "\n";
            return 2;
        }
    }

    if (segments.empty() || trace_path.empty()) {
        std::cerr << "Usage: s1_sail_cosim_tb --seg <hex:bin> [--seg ...] --trace-out <jsonl> [--htif-pc <hex>] [--max-cycles N]\n";
        return 2;
    }

    SailCosimTB tb;
    for (const auto& s : segments) {
        tb.load_segment(s.paddr, s.path);
    }
    tb.reset();

    std::ofstream trace_ofs(trace_path);
    if (!trace_ofs) {
        std::cerr << "ERROR: Unable to open trace output: " << trace_path << "\n";
        return 2;
    }

    bool hit_htif = false;
    while (!hit_htif && tb.cycle_count < max_cycles) {
        tb.step_and_trace(trace_ofs, hit_htif, htif_pc, has_htif_pc);
    }

    trace_ofs.close();
    if (has_htif_pc && !hit_htif) {
        std::cerr << "ERROR: Timed out after " << tb.cycle_count
                  << " cycles without retiring htif_pc=0x" << std::hex << htif_pc << std::dec << "\n";
        return 3;
    }
    return 0;
}
