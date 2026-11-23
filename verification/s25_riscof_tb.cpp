// =============================================================================
// Fursoy S2.5-M2a RISCOF Verilator Signature Testbench
// =============================================================================
// Executes compiled riscv-arch-test ELF PT_LOAD segments on fursoy_s1_core
// (frontend_en_i = 1, SMP_COHERENCE_EN = 0), detects RVMODEL_HALT at the
// write_tohost PC, drains outstanding stores, snoops dirty L1D/WBB lines in
// [begin_signature, end_signature) via the hardware coherence snoop port, and
// writes the 32-bit-word RISCOF signature file.
// =============================================================================

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
#include <string>
#include <vector>

#include "Vfursoy_s1_core.h"
#include "verilated.h"

namespace {

constexpr uint64_t kDramBase  = 0x0000000080000000ULL;
constexpr uint64_t kDramLimit = 0x0000000090000000ULL; // 256 MiB

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

class RiscofDutTB {
public:
    std::unique_ptr<Vfursoy_s1_core> dut;
    std::map<uint64_t, std::vector<uint8_t>> mem;
    std::deque<BusReq> l1i_bus_q;
    std::deque<BusReq> l1d_bus_q;
    std::deque<PtwReq> ptw_bus_q;
    bool mmio_rsp_pend = false;
    uint64_t cycle_count = 0;

    RiscofDutTB() {
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

    uint32_t read_dram_word(uint64_t pa) const {
        uint64_t aligned = pa & ~3ULL;
        uint64_t line_addr = aligned >> 6;
        uint32_t offset = static_cast<uint32_t>(aligned & 0x3FULL);
        auto it = mem.find(line_addr);
        if (it == mem.end()) return 0U;
        uint32_t val = 0;
        std::memcpy(&val, &it->second[offset], 4);
        return val;
    }

    void reset() {
        dut->rst_i                  = 1;
        dut->clk_i                  = 0;
        dut->frontend_en_i          = 1;
        dut->priv_mode_i            = 3;
        dut->mstatus_i              = 0;
        dut->satp_i                 = 0;
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

        dut->mmio_req_ready_i       = 1;
        dut->mmio_rsp_valid_i       = 0;
        dut->mmio_rsp_rdata_i       = 0;
        dut->mmio_rsp_error_i       = 0;

        dut->snoop_req_valid_i      = 0;
        dut->snoop_req_addr_i       = 0;
        dut->snoop_req_type_i       = 0;
        dut->snoop_rsp_ready_i      = 1;

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
        mmio_rsp_pend = false;
        cycle_count = 0;

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

    bool step_cycle(uint64_t halt_pc) {
        dut->clk_i = 0;
        dut->eval();

        bool hit_halt = false;
        uint8_t retire_mask = dut->retire_valid_o & 0x3U;
        for (int k = 0; k < 2; k++) {
            if (((retire_mask >> k) & 1U) && dut->retire_pc_o[k] == halt_pc) {
                hit_halt = true;
            }
        }

        if (dut->l1i_bus_rd_req_valid_o && dut->l1i_bus_rd_req_ready_i) {
            l1i_bus_q.push_back({dut->l1i_bus_rd_req_addr_o, dut->l1i_bus_rd_req_tag_o, 1});
        }
        if (dut->bus_rd_req_valid_o && dut->bus_rd_req_ready_i) {
            l1d_bus_q.push_back({dut->bus_rd_req_addr_o, dut->bus_rd_req_tag_o, 1});
        }
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

        if (dut->ptw_mem_req_valid_o && dut->ptw_mem_req_ready_i) {
            ptw_bus_q.push_back({dut->ptw_mem_req_addr_o, 1});
        }

        // Service uncached MMIO channel (unmapped non-DRAM addresses return bus decode error -> Access Fault)
        bool next_mmio_rsp = false;
        if (dut->mmio_req_valid_o && dut->mmio_req_ready_i) {
            next_mmio_rsp = true;
        }
        if (mmio_rsp_pend) {
            dut->mmio_rsp_valid_i = 1;
            dut->mmio_rsp_rdata_i = 0;
            dut->mmio_rsp_error_i = 1;
        } else {
            dut->mmio_rsp_valid_i = 0;
            dut->mmio_rsp_rdata_i = 0;
            dut->mmio_rsp_error_i = 0;
        }
        mmio_rsp_pend = next_mmio_rsp;

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

        dut->clk_i = 1;
        dut->eval();
        cycle_count++;
        return hit_halt;
    }

    void snoop_signature_region(uint64_t sig_begin, uint64_t sig_end) {
        if (sig_end <= sig_begin) return;
        uint64_t first_line = sig_begin >> 6;
        uint64_t last_line  = (sig_end - 1) >> 6;
        for (uint64_t la = first_line; la <= last_line; la++) {
            dut->snoop_req_valid_i = 1;
            dut->snoop_req_addr_i  = (la << 6) & 0x00FFFFFFFFFFFFFFULL;
            dut->snoop_req_type_i  = 2; // SNOOP_GETS (non-destructive dirty readout)
            dut->eval();
            if (dut->snoop_rsp_valid_o && dut->snoop_rsp_has_data_o) {
                auto it = mem.find(la);
                if (it == mem.end()) {
                    it = mem.emplace(la, std::vector<uint8_t>(64, 0)).first;
                }
                std::memcpy(it->second.data(), (const void*)&dut->snoop_rsp_data_o, 64);
            }
        }
        dut->snoop_req_valid_i = 0;
        dut->eval();
    }

    void dump_signature(const std::string& path, uint64_t sig_begin, uint64_t sig_end, uint32_t gran) {
        std::ofstream ofs(path);
        if (!ofs) {
            std::cerr << "ERROR: Failed to open signature output: " << path << "\n";
            std::exit(2);
        }
        if (gran == 4) {
            for (uint64_t addr = sig_begin; addr < sig_end; addr += 4) {
                uint32_t w = read_dram_word(addr);
                ofs << std::hex << std::nouppercase << std::setfill('0') << std::setw(8) << w << "\n";
            }
        } else {
            for (uint64_t addr = sig_begin; addr < sig_end; addr += gran) {
                for (int off = (int)gran - 4; off >= 0; off -= 4) {
                    uint32_t w = read_dram_word(addr + (uint64_t)off);
                    ofs << std::hex << std::nouppercase << std::setfill('0') << std::setw(8) << w;
                }
                ofs << "\n";
            }
        }
    }
};

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::string sig_out;
    uint64_t halt_pc = 0;
    uint64_t sig_begin = 0;
    uint64_t sig_end = 0;
    uint32_t sig_gran = 4;
    uint64_t max_cycles = 2000000;
    std::vector<MemSegment> segs;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--sig-out" && i + 1 < argc) {
            sig_out = argv[++i];
        } else if (arg == "--halt-pc" && i + 1 < argc) {
            halt_pc = std::stoull(argv[++i], nullptr, 16);
        } else if (arg == "--sig-begin" && i + 1 < argc) {
            sig_begin = std::stoull(argv[++i], nullptr, 16);
        } else if (arg == "--sig-end" && i + 1 < argc) {
            sig_end = std::stoull(argv[++i], nullptr, 16);
        } else if (arg == "--sig-gran" && i + 1 < argc) {
            sig_gran = static_cast<uint32_t>(std::stoul(argv[++i], nullptr, 10));
        } else if (arg == "--max-cycles" && i + 1 < argc) {
            max_cycles = std::stoull(argv[++i], nullptr, 10);
        } else if (arg == "--seg" && i + 1 < argc) {
            std::string spec = argv[++i];
            size_t colon = spec.find(':');
            if (colon == std::string::npos) {
                std::cerr << "Invalid --seg format: " << spec << "\n";
                return 2;
            }
            segs.push_back({std::stoull(spec.substr(0, colon), nullptr, 16), spec.substr(colon + 1)});
        } else {
            std::cerr << "Unknown arg: " << arg << "\n";
            return 2;
        }
    }

    if (sig_out.empty() || halt_pc == 0 || segs.empty()) {
        std::cerr << "Usage: s25_riscof_tb --sig-out <file> --halt-pc <hex> --sig-begin <hex> --sig-end <hex> --seg <paddr>:<bin>...\n";
        return 2;
    }

    RiscofDutTB tb;
    for (const auto& seg : segs) {
        tb.load_segment(seg.paddr, seg.path);
    }
    tb.reset();

    bool halted = false;
    for (uint64_t cyc = 0; cyc < max_cycles; cyc++) {
        if (tb.step_cycle(halt_pc)) {
            halted = true;
            // Allow final fence/stores to settle into L1D/WBB
            for (int d = 0; d < 64; d++) {
                tb.step_cycle(0);
            }
            break;
        }
    }

    if (!halted) {
        std::cerr << "ERROR: RISCOF DUT timed out after " << max_cycles << " cycles (halt_pc=0x"
                  << std::hex << halt_pc << ")\n";
        return 3;
    }

    tb.snoop_signature_region(sig_begin, sig_end);
    tb.dump_signature(sig_out, sig_begin, sig_end, sig_gran);
    return 0;
}
