// =============================================================================
// Fursoy Slice-1 Milestone 9 Phase B Dedicated Verification Testbench
// =============================================================================
// Reference: docs/architecture/slice1-m9-soc-linux-v1.md Section 4, 8.2
//
// Verification Scope:
// 1. Mandatory Section 8.2 Properties:
//    - PROP_M9_07: Strictly non-speculative MMIO load execution at ROB head.
//    - PROP_M9_08: Strictly non-speculative MMIO store execution & branch mispredict ban.
//    - PROP_M9_09: Width formatting & exact byte enable generation (1B, 2B, 4B, 8B).
//    - PROP_M9_10: Sub-word MMIO loads sign/zero extension into PRF without bit-drift.
//    - PROP_M9_11: Non-blocking cache/MSHR immunity & precise Load Access Fault (mcause=5, mtval=addr).
//    - PROP_M9_12: PTW MMIO rejection (reject_ptw_mmio) & precise Store Access Fault (mcause=7, mtval=addr).
// 2. Multi-Seed Randomized Stress Torture:
//    - >= 25,000 accepted MMIO operations across seeds (42, 20260920, 20261009).
//    - Differential golden checker: zero mismatches, zero register/memory corruption.
// =============================================================================

#include <iostream>
#include <iomanip>
#include <vector>
#include <deque>
#include <map>
#include <cstdint>
#include <cassert>
#include <random>
#include <memory>
#include <string>
#include <cstring>

#include "Vfursoy_s1_core.h"
#include "verilated.h"

// -----------------------------------------------------------------------------
// Micro-Operation Enums (matching fursoy_s1_pkg.sv)
// -----------------------------------------------------------------------------
constexpr uint8_t UOP_ALU_INT = 0;
constexpr uint8_t UOP_BRANCH  = 4;
constexpr uint8_t UOP_LOAD    = 9;
constexpr uint8_t UOP_STORE   = 10;
constexpr uint8_t UOP_SYSTEM  = 13;

constexpr uint8_t ALU_ADD     = 0;
constexpr uint8_t ALU_LUI     = 7;

constexpr uint8_t BR_EQ       = 42;
constexpr uint8_t BR_NE       = 43;

constexpr uint8_t MEM_LB      = 61;
constexpr uint8_t MEM_LBU     = 62;
constexpr uint8_t MEM_LH      = 63;
constexpr uint8_t MEM_LHU     = 64;
constexpr uint8_t MEM_LW      = 65;
constexpr uint8_t MEM_LWU     = 66;
constexpr uint8_t MEM_LD      = 67;
constexpr uint8_t MEM_SB      = 68;
constexpr uint8_t MEM_SH      = 69;
constexpr uint8_t MEM_SW      = 70;
constexpr uint8_t MEM_SD      = 71;

// -----------------------------------------------------------------------------
// Testbench Harness & Cycle Stepper
// -----------------------------------------------------------------------------
class CoreMMIOTB {
public:
    std::unique_ptr<Vfursoy_s1_core> dut;
    uint64_t cycle_count;

    // Simulated MMIO Peripheral Storage (byte-addressable map)
    std::map<uint64_t, uint8_t> mmio_memory;

    // MMIO In-Flight Request Queue
    struct MMIOReq {
        uint64_t addr;
        bool is_store;
        uint8_t size;
        uint64_t wdata;
        uint8_t wstrb;
        uint64_t return_cyc;
        bool error;
    };
    std::deque<MMIOReq> mmio_queue;

    // Configuration
    int mmio_resp_latency; // Default latency in cycles
    bool mmio_inject_error;
    uint64_t total_mmio_reqs_accepted;
    uint64_t bus_rd_req_count;
    uint64_t bus_wr_req_count;

    CoreMMIOTB() {
        dut = std::make_unique<Vfursoy_s1_core>();
        cycle_count = 0;
        mmio_resp_latency = 1;
        mmio_inject_error = false;
        total_mmio_reqs_accepted = 0;
        bus_rd_req_count = 0;
        bus_wr_req_count = 0;
        clear_inputs();
    }

    void clear_inputs() {
        dut->clk_i = 0;
        dut->rst_i = 0;
        dut->frontend_en_i = 0; // Direct testbench injection mode
        dut->priv_mode_i = 3;   // Machine mode
        dut->mstatus_i = 0;
        dut->satp_i = 0;
        dut->pmp_allow_i = 1;

        dut->trap_valid_i = 0;
        dut->trap_target_i = 0;
        dut->mret_valid_i = 0;
        dut->mret_target_i = 0;
        dut->sfence_vma_valid_i = 0;
        dut->sfence_vma_va_i = 0;
        dut->sfence_vma_asid_i = 0;

        // Uop 0
        dut->uop0_valid_i = 0;
        dut->uop0_rs1_i = 0;
        dut->uop0_rs2_i = 0;
        dut->uop0_rd_i = 0;
        dut->uop0_class_i = 0;
        dut->uop0_subop_i = 0;
        dut->uop0_imm_i = 0;
        dut->uop0_use_imm_i = 0;
        dut->uop0_pc_i = 0;
        dut->uop0_pred_taken_i = 0;
        dut->uop0_pred_target_i = 0;
        dut->uop0_is_branch_i = 0;
        dut->uop0_is_jal_i = 0;
        dut->uop0_is_jalr_i = 0;
        dut->uop0_is_fp_i = 0;
        dut->uop0_fp_dest_valid_i = 0;
        dut->uop0_fs3_i = 0;
        dut->uop0_frm_i = 0;
        dut->uop0_is_vec_i = 0;
        dut->uop0_vec_dest_valid_i = 0;
        dut->uop0_prd_vec_i = 0;

        // Uop 1
        dut->uop1_valid_i = 0;
        dut->uop1_rs1_i = 0;
        dut->uop1_rs2_i = 0;
        dut->uop1_rd_i = 0;
        dut->uop1_class_i = 0;
        dut->uop1_subop_i = 0;
        dut->uop1_imm_i = 0;
        dut->uop1_use_imm_i = 0;
        dut->uop1_pc_i = 0;
        dut->uop1_pred_taken_i = 0;
        dut->uop1_pred_target_i = 0;
        dut->uop1_is_branch_i = 0;
        dut->uop1_is_jal_i = 0;
        dut->uop1_is_jalr_i = 0;
        dut->uop1_is_fp_i = 0;
        dut->uop1_fp_dest_valid_i = 0;
        dut->uop1_fs3_i = 0;
        dut->uop1_frm_i = 0;
        dut->uop1_is_vec_i = 0;
        dut->uop1_vec_dest_valid_i = 0;
        dut->uop1_prd_vec_i = 0;

        dut->flush_valid_i = 0;
        dut->retire_ready_i = 1;

        dut->probe_paddr_i = 0;
        dut->probe_fp_paddr_i = 0;
        dut->probe_vrf_paddr_i = 0;

        dut->test_inject_valid_i = 0;
        dut->test_inject_data_i = 0;
        dut->test_inject_pnew_i = 0;
        dut->test_inject_rob_idx_i = 0;
        dut->test_inject_rob_epoch_i = 0;
        dut->test_inject_mispredict_i = 0;

        dut->comp_fp_wb_valid_i = 0;
        for (int i = 0; i < 3; i++) dut->comp_fp_wb_preg_i[i] = 0;
        for (int i = 0; i < 5; i++) dut->comp_fflags_i[i] = 0;

        dut->test_fp_w0_valid_i = 0; dut->test_fp_w0_paddr_i = 0; dut->test_fp_w0_data_i = 0;
        dut->test_fp_w1_valid_i = 0; dut->test_fp_w1_paddr_i = 0; dut->test_fp_w1_data_i = 0;
        dut->test_fp_w2_valid_i = 0; dut->test_fp_w2_paddr_i = 0; dut->test_fp_w2_data_i = 0;

        dut->test_vrf_w_valid_i = 0;
        dut->test_vrf_w_paddr_i = 0;
        dut->test_vrf_w_byte_mask_i = 0;
        memset((void*)&dut->test_vrf_w_data_i, 0, sizeof(dut->test_vrf_w_data_i));
        dut->test_vec_cfg_valid_i = 0;
        dut->test_vec_cfg_avl_i = 0;
        dut->test_vec_cfg_vtype_i = 0;
        dut->test_vec_cfg_rs1_is_zero_i = 0;
        dut->test_vec_cfg_rd_is_zero_i = 0;
        dut->test_fof_fault_valid_i = 0;
        dut->test_fof_fault_elem_i = 0;

        dut->bus_rd_rsp_valid_i = 0;
        dut->bus_rd_rsp_tag_i = 0;
        memset((void*)&dut->bus_rd_rsp_data_i, 0, sizeof(dut->bus_rd_rsp_data_i));
        dut->bus_rd_req_ready_i = 1;
        dut->bus_wr_rsp_valid_i = 0;
        dut->bus_wr_req_ready_i = 1;

        dut->ptw_req_ready_i = 1;
        dut->ptw_rsp_valid_i = 0;
        dut->ptw_rsp_tr_id_i = 0;
        dut->ptw_rsp_pa_i = 0;
        dut->ptw_rsp_page_fault_i = 0;
        dut->ptw_rsp_access_fault_i = 0;

        dut->l1i_bus_rd_req_ready_i = 1;
        dut->l1i_bus_rd_rsp_valid_i = 0;
        dut->l1i_bus_rd_rsp_tag_i = 0;
        memset((void*)&dut->l1i_bus_rd_rsp_data_i, 0, sizeof(dut->l1i_bus_rd_rsp_data_i));
        dut->l1i_bus_rd_rsp_error_i = 0;

        dut->ptw_mem_req_ready_i = 1;
        dut->ptw_mem_rsp_valid_i = 0;
        dut->ptw_mem_rsp_data_i = 0;
        dut->ptw_mem_rsp_error_i = 0;

        dut->test_dtlb_req_valid_i = 0;
        dut->test_dtlb_req_tr_id_i = 0;
        dut->test_dtlb_req_vpn_i = 0;
        dut->test_dtlb_req_is_store_i = 0;
        dut->test_dtlb_req_is_amo_i = 0;

        dut->snoop_req_valid_i = 0;
        dut->snoop_req_addr_i = 0;
        dut->snoop_req_type_i = 0;

        dut->test_ev_fp_issue_i = 0;
        dut->test_ev_fp_fma_busy_i = 0;
        dut->test_ev_fp_fdiv_stall_i = 0;
        dut->test_ev_fp_rename_stall_i = 0;
        dut->test_ev_vec_uop_commit_i = 0;
        dut->test_ev_vec_mem_traffic_i = 0;
        dut->test_ev_vec_viq_full_i = 0;
        dut->test_ev_vec_fof_trunc_i = 0;

        dut->irq_timer_i = 0;
        dut->irq_software_i = 0;
        dut->irq_external_i = 0;
        dut->irq_seip_i = 0;

        dut->test_csr_we_i = 0;
        dut->test_csr_addr_i = 0;
        dut->test_csr_wdata_i = 0;

        // Dedicated MMIO Master Channel Inputs
        dut->mmio_req_ready_i = 1;
        dut->mmio_rsp_valid_i = 0;
        dut->mmio_rsp_rdata_i = 0;
        dut->mmio_rsp_error_i = 0;
    }

    void step() {
        dut->clk_i = 0;
        dut->eval();

        // 1. Observe Cacheable DRAM Bus Refill / Eviction requests (for immunity check)
        if (dut->bus_rd_req_valid_o && dut->bus_rd_req_ready_i) {
            bus_rd_req_count++;
        }
        if (dut->bus_wr_req_valid_o && dut->bus_wr_req_ready_i) {
            bus_wr_req_count++;
        }

        // 2. Observe and Capture Core MMIO Master Requests
        if (dut->mmio_req_valid_o && dut->mmio_req_ready_i) {
            MMIOReq req;
            req.addr = dut->mmio_req_addr_o;
            req.is_store = dut->mmio_req_is_store_o != 0;
            req.size = dut->mmio_req_size_o;
            req.wdata = dut->mmio_req_wdata_o;
            req.wstrb = dut->mmio_req_wstrb_o;
            req.return_cyc = cycle_count + mmio_resp_latency;
            req.error = mmio_inject_error;
            mmio_queue.push_back(req);
            total_mmio_reqs_accepted++;

            // For non-error stores, apply write strobes to simulated MMIO memory
            if (req.is_store && !req.error) {
                uint64_t base_word_addr = req.addr & ~7ULL;
                for (int b = 0; b < 8; b++) {
                    if (req.wstrb & (1 << b)) {
                        uint8_t byte_val = (uint8_t)((req.wdata >> (b * 8)) & 0xFF);
                        mmio_memory[base_word_addr + b] = byte_val;
                    }
                }
            }
        }

        // 3. Deliver MMIO Response when scheduled return cycle reached
        if (!mmio_queue.empty() && mmio_queue.front().return_cyc <= cycle_count) {
            MMIOReq rsp = mmio_queue.front();
            mmio_queue.pop_front();
            dut->mmio_rsp_valid_i = 1;
            dut->mmio_rsp_error_i = rsp.error ? 1 : 0;
            if (rsp.is_store) {
                dut->mmio_rsp_rdata_i = 0;
            } else {
                // Return 8-byte aligned word from mmio_memory
                uint64_t base_word_addr = rsp.addr & ~7ULL;
                uint64_t rdata = 0;
                for (int b = 0; b < 8; b++) {
                    uint64_t byte_val = 0;
                    auto it = mmio_memory.find(base_word_addr + b);
                    if (it != mmio_memory.end()) {
                        byte_val = it->second;
                    }
                    rdata |= (byte_val << (b * 8));
                }
                dut->mmio_rsp_rdata_i = rdata;
            }
        } else {
            dut->mmio_rsp_valid_i = 0;
            dut->mmio_rsp_error_i = 0;
            dut->mmio_rsp_rdata_i = 0;
        }

        dut->eval();
        dut->clk_i = 1;
        dut->eval();
        cycle_count++;
        dut->clk_i = 0;
        dut->eval();
    }

    void reset() {
        clear_inputs();
        dut->rst_i = 1;
        for (int i = 0; i < 10; i++) step();
        dut->rst_i = 0;
        clear_inputs();
        step();
        mmio_queue.clear();
        mmio_memory.clear();
        total_mmio_reqs_accepted = 0;
        bus_rd_req_count = 0;
        bus_wr_req_count = 0;
        mmio_resp_latency = 1;
        mmio_inject_error = false;
    }

    void write_csr(uint16_t addr, uint64_t val) {
        dut->test_csr_we_i = 1;
        dut->test_csr_addr_i = addr;
        dut->test_csr_wdata_i = val;
        step();
        dut->test_csr_we_i = 0;
        dut->test_csr_addr_i = 0;
        dut->test_csr_wdata_i = 0;
        step();
    }

    void set_priv(uint8_t priv) {
        write_csr(0x000, priv);
        dut->priv_mode_i = priv;
        dut->eval();
    }

    bool dispatch_uop(uint8_t u_class, uint8_t subop, uint8_t rd, uint8_t rs1, uint8_t rs2, uint64_t imm, uint64_t pc) {
        if ((dut->dispatch_ready_o & 1) == 0) return false;
        dut->uop0_valid_i = 1;
        dut->uop0_class_i = u_class;
        dut->uop0_subop_i = subop;
        dut->uop0_rd_i = rd;
        dut->uop0_rs1_i = rs1;
        dut->uop0_rs2_i = rs2;
        dut->uop0_imm_i = imm;
        dut->uop0_use_imm_i = 1;
        dut->uop0_pc_i = pc;

        dut->uop1_valid_i = 0;
        dut->eval();
        bool ack = (dut->rename_ack_o & 1) != 0;
        step();
        dut->uop0_valid_i = 0;
        dut->eval();
        return ack;
    }

    void wait_quiescent(int max_cycles = 100) {
        for (int i = 0; i < max_cycles; i++) {
            dut->uop0_valid_i = 0;
            dut->uop1_valid_i = 0;
            step();
            if (dut->rob_count_o == 0 && mmio_queue.empty()) return;
        }
    }

    uint64_t read_prf(uint8_t paddr) {
        dut->probe_paddr_i = paddr;
        dut->eval();
        return dut->probe_pdata_o;
    }

    uint64_t read_arch_reg(uint8_t areg) {
        return read_prf(dut->arat_map_o[areg]);
    }
};

// -----------------------------------------------------------------------------
// Test Results Accumulator
// -----------------------------------------------------------------------------
struct TestResults {
    int total_props_tested;
    int props_passed;
    uint64_t torture_events_accepted;
    int torture_mismatches;
    std::vector<std::string> passed_properties;
};

// -----------------------------------------------------------------------------
// Main Test Suite
// -----------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "===================================================================\n";
    std::cout << "Fursoy Slice-1 Milestone 9 Phase B Verification Suite\n";
    std::cout << "Authoritative Spec: docs/architecture/slice1-m9-soc-linux-v1.md Section 4, 8.2\n";
    std::cout << "===================================================================\n\n";

    TestResults results = {0, 0, 0, 0, {}};
    CoreMMIOTB tb;

    // =========================================================================
    // SECTION 1: DIRECTED PROPERTY VERIFICATION (PROP_M9_07 .. PROP_M9_12)
    // =========================================================================

    // -------------------------------------------------------------------------
    // PROP_M9_07: Strictly Non-Speculative MMIO Load Execution at ROB Head
    // -------------------------------------------------------------------------
    {
        std::cout << "[RUN] Testing PROP_M9_07: Strictly Non-Speculative MMIO Load at ROB Head..." << std::endl;
        tb.reset();

        uint64_t mmio_addr = 0x10000000ULL; // UART aperture (uncached MMIO)
        uint64_t expected_data = 0x0123456789ABCDEFULL;

        // Populate MMIO memory at 0x1000_0000
        for (int b = 0; b < 8; b++) {
            tb.mmio_memory[mmio_addr + b] = (uint8_t)((expected_data >> (b * 8)) & 0xFF);
        }

        // Set base register x1 = mmio_addr
        bool ack = tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, mmio_addr, 0x100);
        assert(ack && "PROP_M9_07 FAILED: Address setup uop failed to dispatch!");

        // Dispatch a multi-cycle slow ALU uop in front of MMIO load to keep ROB busy
        // x2 = x1 + 1
        ack = tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 1, 0, 1, 0x104);
        assert(ack && "PROP_M9_07 FAILED: Older ALU uop failed to dispatch!");

        // Dispatch MMIO load: LD x5, 0(x1)
        ack = tb.dispatch_uop(UOP_LOAD, MEM_LD, 5, 1, 0, 0, 0x108);
        assert(ack && "PROP_M9_07 FAILED: MMIO load failed to dispatch!");

        // Set MMIO response latency to 4 cycles
        tb.mmio_resp_latency = 4;

        // While older uops have not completed, verify mmio_req_valid_o is NEVER asserted
        // Step a few cycles and verify MMIO load remains completely dormant in LQ
        bool saw_premature_issue = false;
        for (int c = 0; c < 3; c++) {
            if (tb.dut->mmio_req_valid_o && tb.dut->rob_count_o > 1) {
                saw_premature_issue = true;
            }
            tb.step();
        }
        assert(!saw_premature_issue && "PROP_M9_07 FAILED: MMIO load issued speculatively before reaching ROB head!");

        // Now step until mmio_req_valid_o asserts at ROB head
        bool saw_handshake_at_head = false;
        for (int c = 0; c < 20; c++) {
            if (tb.dut->mmio_req_valid_o) {
                assert(tb.dut->mmio_req_addr_o == mmio_addr && "PROP_M9_07 FAILED: MMIO load addr mismatch!");
                assert(tb.dut->mmio_req_is_store_o == 0 && "PROP_M9_07 FAILED: MMIO load flagged as store!");
                assert(tb.dut->mmio_req_size_o == 3 && "PROP_M9_07 FAILED: MMIO LD size should be 3 (8B)!");
                saw_handshake_at_head = true;
                break;
            }
            tb.step();
        }
        assert(saw_handshake_at_head && "PROP_M9_07 FAILED: MMIO load never handshaked at ROB head!");

        // Wait until load response arrives and uop retires
        tb.wait_quiescent(30);

        // Verify register x5 received the exact MMIO data
        uint64_t act_val = tb.read_arch_reg(5);
        assert(act_val == expected_data && "PROP_M9_07 FAILED: Formatted PRF data mismatch!");

        results.total_props_tested++;
        results.props_passed++;
        results.passed_properties.push_back("PROP_M9_07");
        std::cout << "  -> PASS: Non-speculative MMIO load issuance at ROB head & PRF delivery verified.\n";
    }

    // -------------------------------------------------------------------------
    // PROP_M9_08: Strictly Non-Speculative MMIO Store & Branch Mispredict Ban
    // -------------------------------------------------------------------------
    {
        std::cout << "[RUN] Testing PROP_M9_08: Speculative MMIO Access Ban under Branch Mispredict & MMIO Store..." << std::endl;
        tb.reset();

        uint64_t mmio_addr = 0x10000010ULL;
        uint64_t store_data = 0xCAFEBABE11223344ULL;

        // Step 1: Branch Mispredict Ban
        // Dispatch conditional branch BEQ x0, x0 (actual taken) with pred_taken = 0 (mispredicted)
        tb.clear_inputs();
        tb.dut->retire_ready_i = 0;
        tb.dut->uop0_valid_i = 1;
        tb.dut->uop0_class_i = UOP_BRANCH;
        tb.dut->uop0_subop_i = BR_EQ;
        tb.dut->uop0_rs1_i = 0;
        tb.dut->uop0_rs2_i = 0;
        tb.dut->uop0_imm_i = 16;
        tb.dut->uop0_is_branch_i = 1;
        tb.dut->uop0_pc_i = 0x80000100;
        tb.dut->uop0_pred_taken_i = 0;
        tb.dut->uop0_pred_target_i = 0x80000104;
        tb.step();

        // Dispatch speculative younger MMIO store behind the mispredicted branch
        tb.clear_inputs();
        tb.dut->retire_ready_i = 0;
        tb.dut->uop0_valid_i = 1;
        tb.dut->uop0_class_i = UOP_STORE;
        tb.dut->uop0_subop_i = MEM_SD;
        tb.dut->uop0_rs1_i = 0; // x0 base
        tb.dut->uop0_rs2_i = 0; // x0 data
        tb.dut->uop0_imm_i = mmio_addr;
        tb.dut->uop0_use_imm_i = 1;
        tb.dut->uop0_pc_i = 0x80000104;
        tb.step();

        // Dispatch speculative younger MMIO load behind the mispredicted branch
        tb.clear_inputs();
        tb.dut->retire_ready_i = 0;
        tb.dut->uop0_valid_i = 1;
        tb.dut->uop0_class_i = UOP_LOAD;
        tb.dut->uop0_subop_i = MEM_LD;
        tb.dut->uop0_rd_i = 10;
        tb.dut->uop0_rs1_i = 0;
        tb.dut->uop0_imm_i = mmio_addr;
        tb.dut->uop0_use_imm_i = 1;
        tb.dut->uop0_pc_i = 0x80000108;
        tb.step();

        // Allow branch to execute and resolve mispredict while asserting mmio_req_valid_o is NEVER asserted
        tb.clear_inputs();
        tb.dut->retire_ready_i = 1;
        bool illegal_mmio_handshake = false;
        for (int c = 0; c < 30; c++) {
            if (tb.dut->mmio_req_valid_o) {
                illegal_mmio_handshake = true;
            }
            tb.step();
            if (tb.dut->rob_count_o == 0) break;
        }
        assert(!illegal_mmio_handshake && "PROP_M9_08 FAILED: Speculative MMIO operation asserted mmio_req_valid_o under mispredict!");

        // Step 2: Normal MMIO Store Execution at ROB Head
        tb.reset();
        tb.mmio_resp_latency = 3;

        // Set x1 = mmio_addr, x2 = store_data
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, mmio_addr, 0x200);
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, store_data, 0x204);
        tb.wait_quiescent(20);

        // Dispatch MMIO store: SD x2, 0(x1)
        bool ack = tb.dispatch_uop(UOP_STORE, MEM_SD, 0, 1, 2, 0, 0x208);
        assert(ack && "PROP_M9_08 FAILED: MMIO store failed to dispatch!");

        bool saw_store_handshake = false;
        for (int c = 0; c < 20; c++) {
            if (tb.dut->mmio_req_valid_o) {
                assert(tb.dut->mmio_req_addr_o == mmio_addr && "PROP_M9_08 FAILED: MMIO store addr mismatch!");
                assert(tb.dut->mmio_req_is_store_o == 1 && "PROP_M9_08 FAILED: MMIO store req_is_store should be 1!");
                assert(tb.dut->mmio_req_wstrb_o == 0xFF && "PROP_M9_08 FAILED: MMIO SD wstrb should be 0xFF!");
                assert(tb.dut->mmio_req_wdata_o == store_data && "PROP_M9_08 FAILED: MMIO SD wdata mismatch!");
                saw_store_handshake = true;
                break;
            }
            tb.step();
        }
        assert(saw_store_handshake && "PROP_M9_08 FAILED: MMIO store never handshaked at ROB head!");

        tb.wait_quiescent(30);

        // Verify simulated MMIO memory captured the 8 bytes
        uint64_t mem_val = 0;
        for (int b = 0; b < 8; b++) {
            mem_val |= ((uint64_t)tb.mmio_memory[mmio_addr + b]) << (b * 8);
        }
        assert(mem_val == store_data && "PROP_M9_08 FAILED: MMIO store memory data mismatch!");

        results.total_props_tested++;
        results.props_passed++;
        results.passed_properties.push_back("PROP_M9_08");
        std::cout << "  -> PASS: Speculative MMIO ban & ROB head store execution verified.\n";
    }

    // -------------------------------------------------------------------------
    // PROP_M9_09: Width Formatting & Byte Enables (1B, 2B, 4B, 8B)
    // -------------------------------------------------------------------------
    {
        std::cout << "[RUN] Testing PROP_M9_09: Width Formatting & Byte Strobes across all widths..." << std::endl;
        tb.reset();
        tb.mmio_resp_latency = 1;

        uint64_t base_addr = 0x10000040ULL;
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, base_addr, 0x300);
        tb.wait_quiescent(20);

        // 1. SB across offsets 0..7
        for (int offset = 0; offset < 8; offset++) {
            uint64_t val = 0x11ULL * (offset + 1);
            tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, val, 0x310 + offset * 8);
            tb.wait_quiescent(10);
            tb.dispatch_uop(UOP_STORE, MEM_SB, 0, 1, 2, offset, 0x350 + offset * 8);

            bool saw_req = false;
            for (int c = 0; c < 20; c++) {
                if (tb.dut->mmio_req_valid_o) {
                    assert(tb.dut->mmio_req_size_o == 0 && "SB size must be 0 (1B)");
                    assert(tb.dut->mmio_req_wstrb_o == (1 << offset) && "SB wstrb mismatch");
                    uint8_t act_byte = (uint8_t)((tb.dut->mmio_req_wdata_o >> (offset * 8)) & 0xFF);
                    assert(act_byte == (uint8_t)val && "SB aligned wdata mismatch");
                    saw_req = true;
                    break;
                }
                tb.step();
            }
            assert(saw_req && "SB request not observed");
            tb.wait_quiescent(15);
        }

        // 2. SH across offsets 0, 2, 4, 6
        for (int offset = 0; offset < 8; offset += 2) {
            uint64_t val = 0x2211ULL + offset * 0x0100ULL;
            tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, val, 0x400 + offset * 8);
            tb.wait_quiescent(10);
            tb.dispatch_uop(UOP_STORE, MEM_SH, 0, 1, 2, offset, 0x440 + offset * 8);

            bool saw_req = false;
            for (int c = 0; c < 20; c++) {
                if (tb.dut->mmio_req_valid_o) {
                    assert(tb.dut->mmio_req_size_o == 1 && "SH size must be 1 (2B)");
                    assert(tb.dut->mmio_req_wstrb_o == (3 << offset) && "SH wstrb mismatch");
                    uint16_t act_half = (uint16_t)((tb.dut->mmio_req_wdata_o >> (offset * 8)) & 0xFFFF);
                    assert(act_half == (uint16_t)val && "SH aligned wdata mismatch");
                    saw_req = true;
                    break;
                }
                tb.step();
            }
            assert(saw_req && "SH request not observed");
            tb.wait_quiescent(15);
        }

        // 3. SW across offsets 0, 4
        for (int offset = 0; offset < 8; offset += 4) {
            uint64_t val = 0xAABBCCDDULL + offset;
            tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, val, 0x500 + offset * 8);
            tb.wait_quiescent(10);
            tb.dispatch_uop(UOP_STORE, MEM_SW, 0, 1, 2, offset, 0x540 + offset * 8);

            bool saw_req = false;
            for (int c = 0; c < 20; c++) {
                if (tb.dut->mmio_req_valid_o) {
                    assert(tb.dut->mmio_req_size_o == 2 && "SW size must be 2 (4B)");
                    assert(tb.dut->mmio_req_wstrb_o == (0x0F << offset) && "SW wstrb mismatch");
                    uint32_t act_word = (uint32_t)((tb.dut->mmio_req_wdata_o >> (offset * 8)) & 0xFFFFFFFF);
                    assert(act_word == (uint32_t)val && "SW aligned wdata mismatch");
                    saw_req = true;
                    break;
                }
                tb.step();
            }
            assert(saw_req && "SW request not observed");
            tb.wait_quiescent(15);
        }

        // 4. SD offset 0
        {
            uint64_t val = 0xFEEDBEEF01234567ULL;
            tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, val, 0x600);
            tb.wait_quiescent(10);
            tb.dispatch_uop(UOP_STORE, MEM_SD, 0, 1, 2, 0, 0x604);

            bool saw_req = false;
            for (int c = 0; c < 20; c++) {
                if (tb.dut->mmio_req_valid_o) {
                    assert(tb.dut->mmio_req_size_o == 3 && "SD size must be 3 (8B)");
                    assert(tb.dut->mmio_req_wstrb_o == 0xFF && "SD wstrb must be 0xFF");
                    assert(tb.dut->mmio_req_wdata_o == val && "SD wdata mismatch");
                    saw_req = true;
                    break;
                }
                tb.step();
            }
            assert(saw_req && "SD request not observed");
            tb.wait_quiescent(15);
        }

        results.total_props_tested++;
        results.props_passed++;
        results.passed_properties.push_back("PROP_M9_09");
        std::cout << "  -> PASS: Width formatting and byte strobes verified across all widths (1B, 2B, 4B, 8B).\n";
    }

    // -------------------------------------------------------------------------
    // PROP_M9_10: Sub-Word MMIO Load Sign/Zero Extension into PRF
    // -------------------------------------------------------------------------
    {
        std::cout << "[RUN] Testing PROP_M9_10: Sub-Word MMIO Load Sign/Zero Extension..." << std::endl;
        tb.reset();
        tb.mmio_resp_latency = 1;

        uint64_t base_addr = 0x10000080ULL;
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, base_addr, 0x700);
        tb.wait_quiescent(20);

        // Populate base_addr with known patterned bytes:
        // Byte 0: 0x85 (negative), Byte 1: 0x34 (positive), Byte 2: 0x9A, Byte 3: 0xF0
        // Byte 4: 0x78, Byte 5: 0x56, Byte 6: 0x34, Byte 7: 0x12
        uint64_t test_word = 0x12345678F09A3485ULL;
        for (int b = 0; b < 8; b++) {
            tb.mmio_memory[base_addr + b] = (uint8_t)((test_word >> (b * 8)) & 0xFF);
        }

        // Test LB (sign-extended byte 0: 0x85 -> 0xFFFFFFFFFFFFFF85)
        tb.dispatch_uop(UOP_LOAD, MEM_LB, 3, 1, 0, 0, 0x704);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(3) == 0xFFFFFFFFFFFFFF85ULL && "LB sign-extension mismatch!");

        // Test LBU (zero-extended byte 0: 0x85 -> 0x0000000000000085)
        tb.dispatch_uop(UOP_LOAD, MEM_LBU, 4, 1, 0, 0, 0x708);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(4) == 0x0000000000000085ULL && "LBU zero-extension mismatch!");

        // Test LH (sign-extended halfword at offset 2: 0xF09A -> 0xFFFFFFFFFFFFF09A)
        tb.dispatch_uop(UOP_LOAD, MEM_LH, 5, 1, 0, 2, 0x70C);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(5) == 0xFFFFFFFFFFFFF09AULL && "LH sign-extension mismatch!");

        // Test LHU (zero-extended halfword at offset 2: 0xF09A -> 0x000000000000F09A)
        tb.dispatch_uop(UOP_LOAD, MEM_LHU, 6, 1, 0, 2, 0x710);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(6) == 0x000000000000F09AULL && "LHU zero-extension mismatch!");

        // Test LW (sign-extended word at offset 0: 0xF09A3485 -> 0xFFFFFFFFF09A3485)
        tb.dispatch_uop(UOP_LOAD, MEM_LW, 7, 1, 0, 0, 0x714);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(7) == 0xFFFFFFFFF09A3485ULL && "LW sign-extension mismatch!");

        // Test LWU (zero-extended word at offset 0: 0xF09A3485 -> 0x00000000F09A3485)
        tb.dispatch_uop(UOP_LOAD, MEM_LWU, 8, 1, 0, 0, 0x718);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(8) == 0x00000000F09A3485ULL && "LWU zero-extension mismatch!");

        // Test LD (64-bit doubleword)
        tb.dispatch_uop(UOP_LOAD, MEM_LD, 9, 1, 0, 0, 0x71C);
        tb.wait_quiescent(25);
        assert(tb.read_arch_reg(9) == test_word && "LD mismatch!");

        results.total_props_tested++;
        results.props_passed++;
        results.passed_properties.push_back("PROP_M9_10");
        std::cout << "  -> PASS: Sub-word MMIO load sign/zero-extensions into PRF verified without bit-drift.\n";
    }

    // -------------------------------------------------------------------------
    // PROP_M9_11: Cache/MSHR Immunity & Load Access Fault Trap
    // -------------------------------------------------------------------------
    {
        std::cout << "[RUN] Testing PROP_M9_11: L1D Cache Immunity & Precise Load Access Fault (mcause=5)..." << std::endl;
        tb.reset();

        // 1. Immunity check: execute multiple MMIO operations and verify zero bus activity
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, 0x10000000ULL, 0x800);
        tb.wait_quiescent(20);

        tb.bus_rd_req_count = 0;
        tb.bus_wr_req_count = 0;

        for (int i = 0; i < 5; i++) {
            tb.dispatch_uop(UOP_LOAD, MEM_LD, 5 + i, 1, 0, 0, 0x810 + i * 4);
            tb.wait_quiescent(20);
        }

        assert(tb.bus_rd_req_count == 0 && "PROP_M9_11 FAILED: MMIO load allocated/queried cache refill bus!");
        assert(tb.bus_wr_req_count == 0 && "PROP_M9_11 FAILED: MMIO load triggered cache eviction bus!");

        // 2. Unmapped MMIO read error response -> Load Access Fault (mcause=5, mtval=addr)
        uint64_t unmapped_addr = 0x03000000ULL; // unmapped peripheral space
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, unmapped_addr, 0x850);
        tb.wait_quiescent(20);

        // Pre-initialize PRF destination x12 to known sentinel value 0x12345678
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 12, 0, 0, 0x12345678ULL, 0x854);
        tb.wait_quiescent(20);
        assert(tb.read_arch_reg(12) == 0x12345678ULL && "Sentinel setup failed");

        // Arm error injection for next MMIO transaction
        tb.mmio_inject_error = true;
        tb.dispatch_uop(UOP_LOAD, MEM_LW, 12, 2, 0, 0, 0x858);

        // Step until trap is recorded at ROB head
        bool saw_trap = false;
        for (int c = 0; c < 30; c++) {
            tb.step();
            if (tb.dut->csr_mcause_o == 5) {
                saw_trap = true;
                break;
            }
        }
        tb.mmio_inject_error = false;

        assert(saw_trap && "PROP_M9_11 FAILED: Load access fault (mcause=5) not recorded!");
        assert(tb.dut->csr_mtval_o == unmapped_addr && "PROP_M9_11 FAILED: mtval does not match faulting MMIO addr!");
        assert(tb.read_arch_reg(12) == 0x12345678ULL && "PROP_M9_11 FAILED: Destination PRF corrupted upon Load Access Fault!");

        results.total_props_tested++;
        results.props_passed++;
        results.passed_properties.push_back("PROP_M9_11");
        std::cout << "  -> PASS: Cache immunity and precise Load Access Fault (mcause=5, mtval=addr) verified.\n";
    }

    // -------------------------------------------------------------------------
    // PROP_M9_12: PTW MMIO Rejection (reject_ptw_mmio) & Store Access Fault (mcause=7)
    // -------------------------------------------------------------------------
    {
        std::cout << "[RUN] Testing PROP_M9_12: reject_ptw_mmio & Precise Store Access Fault (mcause=7)..." << std::endl;
        tb.reset();

        // 1. PTW MMIO Rejection Contract
        // Point satp root PPN to UART aperture: PPN = 0x10000 (PA = 0x1000_0000 outside DRAM aperture)
        tb.dut->frontend_en_i = 1;
        tb.dut->satp_i = (8ULL << 60) | (0x10000ULL);
        tb.dut->priv_mode_i = 1; // S-mode
        tb.dut->eval();
        tb.step();

        // Inject DTLB translation request for VPN 0x40000
        tb.dut->test_dtlb_req_valid_i = 1;
        tb.dut->test_dtlb_req_tr_id_i = 1;
        tb.dut->test_dtlb_req_vpn_i = 0x40000;
        tb.dut->test_dtlb_req_is_store_i = 0;
        tb.dut->test_dtlb_req_is_amo_i = 0;

        bool saw_ptw_rejection = false;
        bool saw_illegal_mem_req = false;
        for (int c = 0; c < 30; c++) {
            if (tb.dut->ptw_mem_req_valid_o) {
                saw_illegal_mem_req = true;
            }
            if (tb.dut->test_dtlb_rsp_valid_o) {
                if (tb.dut->test_dtlb_rsp_page_fault_o) {
                    saw_ptw_rejection = true;
                    break;
                }
            }
            tb.step();
            if (tb.dut->test_dtlb_req_ready_o) {
                tb.dut->test_dtlb_req_valid_i = 0;
            }
        }
        tb.dut->test_dtlb_req_valid_i = 0;
        tb.dut->frontend_en_i = 0;
        tb.dut->satp_i = 0;
        tb.dut->priv_mode_i = 3; // return to M-mode
        tb.step();

        assert(!saw_illegal_mem_req && "PROP_M9_12 FAILED: PTW issued memory bus request to MMIO address!");
        assert(saw_ptw_rejection && "PROP_M9_12 FAILED: PTW MMIO address did not raise page fault!");

        // 2. Unmapped MMIO write error response -> Store Access Fault (mcause=7, mtval=addr)
        uint64_t unmapped_addr = 0x03000020ULL;
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, unmapped_addr, 0x900);
        tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, 0x99887766ULL, 0x904);
        tb.wait_quiescent(20);

        tb.mmio_inject_error = true;
        tb.dispatch_uop(UOP_STORE, MEM_SW, 0, 1, 2, 0, 0x908);

        bool saw_store_trap = false;
        for (int c = 0; c < 30; c++) {
            tb.step();
            if (tb.dut->csr_mcause_o == 7) {
                saw_store_trap = true;
                break;
            }
        }
        tb.mmio_inject_error = false;

        assert(saw_store_trap && "PROP_M9_12 FAILED: Store access fault (mcause=7) not recorded!");
        assert(tb.dut->csr_mtval_o == unmapped_addr && "PROP_M9_12 FAILED: mtval does not match faulting MMIO store addr!");

        results.total_props_tested++;
        results.props_passed++;
        results.passed_properties.push_back("PROP_M9_12");
        std::cout << "  -> PASS: reject_ptw_mmio and precise Store Access Fault (mcause=7, mtval=addr) verified.\n";
    }

    // =========================================================================
    // SECTION 2: MULTI-SEED RANDOMIZED STRESS TORTURE (>= 25,000 MMIO OPS)
    // =========================================================================
    {
        std::cout << "\n===================================================================\n";
        std::cout << "Running Multi-Seed Randomized MMIO Stress Torture (>= 25,000 Ops)...\n";
        std::cout << "Canonical Seeds: 42, 20260920, 20261009\n";
        std::cout << "===================================================================\n";

        const std::vector<uint32_t> seeds = {42, 20260920, 20261009};
        const uint64_t ops_per_seed = 8500; // 8500 * 3 = 25,500 operations total
        uint64_t total_torture_ops = 0;
        int torture_mismatches = 0;

        // Base apertures: UART (0x1000_0000), CLINT (0x0200_0000), PLIC (0x0C00_0000)
        const std::vector<uint64_t> apertures = {
            0x10000000ULL, // UART
            0x02000000ULL, // CLINT
            0x0C000000ULL  // PLIC
        };

        for (uint32_t seed : seeds) {
            std::cout << "[TORTURE] Starting Seed " << seed << " (" << ops_per_seed << " ops)..." << std::endl;
            std::mt19937_64 rng(seed);
            tb.reset();

            // Golden memory mirror
            std::map<uint64_t, uint8_t> golden_mmio;

            for (uint64_t op = 0; op < ops_per_seed; op++) {
                uint64_t ap_base = apertures[rng() % apertures.size()];
                uint64_t reg_offset = (rng() % 32) * 8; // 32 8-byte slots in aperture
                uint64_t addr = ap_base + reg_offset;

                bool is_store = (rng() % 2) != 0;
                int width_sel = rng() % 4; // 0=1B, 1=2B, 2=4B, 3=8B
                tb.mmio_resp_latency = rng() % 4; // 0..3 cycle latency

                // Set up address register x1 = addr
                tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 1, 0, 0, addr, 0x1000 + (op % 1000) * 16);

                if (is_store) {
                    uint64_t st_val = rng();
                    tb.dispatch_uop(UOP_ALU_INT, ALU_ADD, 2, 0, 0, st_val, 0x1004 + (op % 1000) * 16);
                    tb.wait_quiescent(10);

                    if (width_sel == 0) { // SB
                        uint8_t byte_off = rng() % 8;
                        tb.dispatch_uop(UOP_STORE, MEM_SB, 0, 1, 2, byte_off, 0x1008 + (op % 1000) * 16);
                        golden_mmio[addr + byte_off] = (uint8_t)(st_val & 0xFF);
                    } else if (width_sel == 1) { // SH
                        uint8_t half_off = (rng() % 4) * 2;
                        tb.dispatch_uop(UOP_STORE, MEM_SH, 0, 1, 2, half_off, 0x1008 + (op % 1000) * 16);
                        golden_mmio[addr + half_off + 0] = (uint8_t)(st_val & 0xFF);
                        golden_mmio[addr + half_off + 1] = (uint8_t)((st_val >> 8) & 0xFF);
                    } else if (width_sel == 2) { // SW
                        uint8_t word_off = (rng() % 2) * 4;
                        tb.dispatch_uop(UOP_STORE, MEM_SW, 0, 1, 2, word_off, 0x1008 + (op % 1000) * 16);
                        for (int b = 0; b < 4; b++) {
                            golden_mmio[addr + word_off + b] = (uint8_t)((st_val >> (b * 8)) & 0xFF);
                        }
                    } else { // SD
                        tb.dispatch_uop(UOP_STORE, MEM_SD, 0, 1, 2, 0, 0x1008 + (op % 1000) * 16);
                        for (int b = 0; b < 8; b++) {
                            golden_mmio[addr + b] = (uint8_t)((st_val >> (b * 8)) & 0xFF);
                        }
                    }
                    tb.wait_quiescent(15);
                } else {
                    // Load
                    tb.wait_quiescent(10);
                    if (width_sel == 0) { // LBU
                        uint8_t byte_off = rng() % 8;
                        tb.dispatch_uop(UOP_LOAD, MEM_LBU, 5, 1, 0, byte_off, 0x1008 + (op % 1000) * 16);
                        tb.wait_quiescent(15);
                        uint64_t act = tb.read_arch_reg(5);
                        uint64_t exp = (uint64_t)golden_mmio[addr + byte_off];
                        if (act != exp) {
                            torture_mismatches++;
                            std::cerr << "[FAIL] Torture Seed " << seed << " Op " << op << " LBU mismatch: act=0x"
                                      << std::hex << act << " exp=0x" << exp << std::dec << std::endl;
                            assert(false);
                        }
                    } else if (width_sel == 1) { // LHU
                        uint8_t half_off = (rng() % 4) * 2;
                        tb.dispatch_uop(UOP_LOAD, MEM_LHU, 5, 1, 0, half_off, 0x1008 + (op % 1000) * 16);
                        tb.wait_quiescent(15);
                        uint64_t act = tb.read_arch_reg(5);
                        uint64_t exp = ((uint64_t)golden_mmio[addr + half_off]) |
                                       (((uint64_t)golden_mmio[addr + half_off + 1]) << 8);
                        if (act != exp) {
                            torture_mismatches++;
                            std::cerr << "[FAIL] Torture Seed " << seed << " Op " << op << " LHU mismatch: act=0x"
                                      << std::hex << act << " exp=0x" << exp << std::dec << std::endl;
                            assert(false);
                        }
                    } else if (width_sel == 2) { // LWU
                        uint8_t word_off = (rng() % 2) * 4;
                        tb.dispatch_uop(UOP_LOAD, MEM_LWU, 5, 1, 0, word_off, 0x1008 + (op % 1000) * 16);
                        tb.wait_quiescent(15);
                        uint64_t act = tb.read_arch_reg(5);
                        uint64_t exp = 0;
                        for (int b = 0; b < 4; b++) {
                            exp |= (((uint64_t)golden_mmio[addr + word_off + b]) << (b * 8));
                        }
                        if (act != exp) {
                            torture_mismatches++;
                            std::cerr << "[FAIL] Torture Seed " << seed << " Op " << op << " LWU mismatch: act=0x"
                                      << std::hex << act << " exp=0x" << exp << std::dec << std::endl;
                            assert(false);
                        }
                    } else { // LD
                        tb.dispatch_uop(UOP_LOAD, MEM_LD, 5, 1, 0, 0, 0x1008 + (op % 1000) * 16);
                        tb.wait_quiescent(15);
                        uint64_t act = tb.read_arch_reg(5);
                        uint64_t exp = 0;
                        for (int b = 0; b < 8; b++) {
                            exp |= (((uint64_t)golden_mmio[addr + b]) << (b * 8));
                        }
                        if (act != exp) {
                            torture_mismatches++;
                            std::cerr << "[FAIL] Torture Seed " << seed << " Op " << op << " LD mismatch: act=0x"
                                      << std::hex << act << " exp=0x" << exp << std::dec << std::endl;
                            assert(false);
                        }
                    }
                }
                total_torture_ops++;
            }
            std::cout << "  [PASS] Seed " << seed << " completed: " << ops_per_seed << " operations with 0 mismatches.\n";
        }

        results.torture_events_accepted = total_torture_ops;
        results.torture_mismatches = torture_mismatches;
    }

    // =========================================================================
    // SECTION 3: JSON RESULT REPORTING
    // =========================================================================
    std::cout << "\n--- BEGIN JSON RESULTS ---\n";
    std::cout << "{\n";
    std::cout << "  \"phase\": \"Phase B\",\n";
    std::cout << "  \"status\": \"" << (results.props_passed == 6 && results.torture_mismatches == 0 ? "pass" : "fail") << "\",\n";
    std::cout << "  \"total_properties\": " << results.total_props_tested << ",\n";
    std::cout << "  \"passed_properties_count\": " << results.props_passed << ",\n";
    std::cout << "  \"randomized_torture_operations\": " << results.torture_events_accepted << ",\n";
    std::cout << "  \"torture_seeds\": [42, 20260920, 20261009],\n";
    std::cout << "  \"torture_mismatches\": " << results.torture_mismatches << ",\n";
    std::cout << "  \"properties\": [\n";
    for (size_t i = 0; i < results.passed_properties.size(); i++) {
        std::cout << "    \"" << results.passed_properties[i] << "\"" << (i + 1 < results.passed_properties.size() ? "," : "") << "\n";
    }
    std::cout << "  ]\n";
    std::cout << "}\n";
    std::cout << "--- END JSON RESULTS ---\n";

    return (results.props_passed == 6 && results.torture_mismatches == 0) ? 0 : 1;
}
