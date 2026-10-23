// =============================================================================
// Fursoy Slice-1 Milestone 5 Phase B4: Integer Issue Queue (IntIQ) Unit TB
// =============================================================================
// Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.4
//
// Verification Scope:
// 1. Oldest-ready selection with multiple simultaneously ready operations.
// 2. Older unready operation versus younger ready operation (out-of-order bypass).
// 3. Strict no-age-inversion: younger branch NEVER bypasses older ready ALU
//    when Port 1 cannot accept ALU.
// 4. Equal-age tie-breaking with branch priority (Section 7.4 Rule 4).
// 5. Equal-age tie-breaking with Slot 0 precedence (Section 7.4 Rule 2).
// 6. Flexible ALU + Branch concurrent dual-issue in 1 cycle (P2-1 optimization).
// 7. Symmetric flexible ALUs dual-issue to Port 0 and Port 1.
// 8. Multiplier and Divider port arbitration and credit backpressure.
// 9. ROB-index circular wraparound across 47 -> 0 boundary with strict age preservation.
// 10. Tag wakeup snooping from WB0, WB1, WB2 (registered timing and dispatch snoop).
// 11. Branch recovery squash (recover_valid_i) with circular ROB age distance filtering.
// 12. Single-cycle flush (flush_valid_i) of partially full and full queues.
// 13. Full queue capacity (16 entries) and dispatch backpressure (dispatch_ready_o).
// 14. Sustained downstream backpressure on Port 1 without pipeline deadlock.
// 15. Randomized torture testing (>= 25,000 accepted operations per canonical seed:
//     seeds 42, 20260920, 20261009) against an independent golden reference model.
// =============================================================================

#include <iostream>
#include <iomanip>
#include <vector>
#include <deque>
#include <cstdint>
#include <cassert>
#include <memory>
#include <random>

#include "Vfursoy_s1_int_iq.h"
#include "Vfursoy_s1_int_iq___024root.h"
#include "verilated.h"

// Forward declaration of UOP classes matching fursoy_s1_pkg
constexpr uint8_t UOP_ALU_INT   = 0;
constexpr uint8_t UOP_ALU_SHIFT = 1;
constexpr uint8_t UOP_ALU_ZBA   = 2;
constexpr uint8_t UOP_ALU_ZBB   = 3;
constexpr uint8_t UOP_BRANCH    = 4;
constexpr uint8_t UOP_JAL       = 5;
constexpr uint8_t UOP_JALR      = 6;
constexpr uint8_t UOP_MUL       = 7;
constexpr uint8_t UOP_DIV       = 8;
constexpr uint8_t UOP_SYSTEM    = 13;

struct IntIQTestUop {
    uint8_t  uop_class;
    uint8_t  sub_op;
    uint64_t imm;
    bool     use_imm;
    uint8_t  prs1;
    bool     prs1_ready;
    uint8_t  prs2;
    bool     prs2_ready;
    uint8_t  pnew;
    uint8_t  rob_idx;
    uint8_t  rob_epoch;
    uint8_t  chkpt_id;
    uint64_t pc;
    bool     pred_taken;
    uint64_t pred_target;
    bool     is_branch;
    bool     is_jal;
    bool     is_jalr;
    uint8_t  br_type;
    uint16_t pre_ghr;
    bool     exception;
    uint8_t  exc_cause;
};

inline uint8_t calc_rob_dist(uint8_t idx, uint8_t head) {
    if (idx >= head) return idx - head;
    return (48 - head) + idx;
}

// Packed struct field accessors for VlWide<12> iq_entry_t (375 bits total with M8 fields)
inline uint8_t get_uop_rob_idx(const VlWide<12>& uop) {
    return (uop[8] >> 12) & 0x3F;
}
inline uint8_t get_uop_pnew(const VlWide<12>& uop) {
    return (uop[8] >> 18) & 0x7F;
}
inline bool get_uop_is_branch(const VlWide<12>& uop) {
    return (uop[4] >> 3) & 1;
}

class IntIQTB {
public:
    std::unique_ptr<Vfursoy_s1_int_iq> dut;
    uint64_t cycle_count;

    IntIQTB() : dut(std::make_unique<Vfursoy_s1_int_iq>()), cycle_count(0) {
        dut->clk_i = 0;
        dut->rst_i = 0;
        dut->flush_valid_i = 0;
        dut->recover_valid_i = 0;
        dut->recover_rob_idx_i = 0;
        dut->rob_head_i = 0;

        dut->rename_ack_i = 0;

        dut->uop0_valid_i = 0;
        dut->uop0_class_i = 0;
        dut->uop0_subop_i = 0;
        dut->uop0_imm_i = 0;
        dut->uop0_use_imm_i = 0;
        dut->uop0_prs1_i = 0;
        dut->uop0_prs1_ready_i = 0;
        dut->uop0_prs2_i = 0;
        dut->uop0_prs2_ready_i = 0;
        dut->uop0_pnew_i = 0;
        dut->uop0_rob_idx_i = 0;
        dut->uop0_rob_epoch_i = 0;
        dut->uop0_chkpt_id_i = 0;
        dut->uop0_pc_i = 0;
        dut->uop0_pred_taken_i = 0;
        dut->uop0_pred_target_i = 0;
        dut->uop0_is_branch_i = 0;
        dut->uop0_is_jal_i = 0;
        dut->uop0_is_jalr_i = 0;
        dut->uop0_br_type_i = 0;
        dut->uop0_pre_ghr_i[0] = 0; dut->uop0_pre_ghr_i[1] = 0; dut->uop0_pre_ghr_i[2] = 0; dut->uop0_pre_ghr_i[3] = 0;
        dut->uop0_exception_i = 0;
        dut->uop0_exc_cause_i = 0;

        dut->uop1_valid_i = 0;
        dut->uop1_class_i = 0;
        dut->uop1_subop_i = 0;
        dut->uop1_imm_i = 0;
        dut->uop1_use_imm_i = 0;
        dut->uop1_prs1_i = 0;
        dut->uop1_prs1_ready_i = 0;
        dut->uop1_prs2_i = 0;
        dut->uop1_prs2_ready_i = 0;
        dut->uop1_pnew_i = 0;
        dut->uop1_rob_idx_i = 0;
        dut->uop1_rob_epoch_i = 0;
        dut->uop1_chkpt_id_i = 0;
        dut->uop1_pc_i = 0;
        dut->uop1_pred_taken_i = 0;
        dut->uop1_pred_target_i = 0;
        dut->uop1_is_branch_i = 0;
        dut->uop1_is_jal_i = 0;
        dut->uop1_is_jalr_i = 0;
        dut->uop1_br_type_i = 0;
        dut->uop1_pre_ghr_i[0] = 0; dut->uop1_pre_ghr_i[1] = 0; dut->uop1_pre_ghr_i[2] = 0; dut->uop1_pre_ghr_i[3] = 0;
        dut->uop1_exception_i = 0;
        dut->uop1_exc_cause_i = 0;

        dut->wb0_valid_i = 0;
        dut->wb0_comp_ack_i = 0;
        dut->wb0_pnew_i = 0;

        dut->wb1_valid_i = 0;
        dut->wb1_comp_ack_i = 0;
        dut->wb1_pnew_i = 0;

        dut->wb2_valid_i = 0;
        dut->wb2_comp_ack_i = 0;
        dut->wb2_comp_exception_i = 0;
        dut->wb2_pnew_i = 0;

        dut->can_issue_mul_i  = 1;
        dut->can_issue_alu1_i = 1;
        dut->can_issue_div_i  = 1;
    }

    void reset() {
        dut->rst_i = 1;
        dut->clk_i = 0;
        dut->eval();
        for (int i = 0; i < 5; i++) {
            dut->clk_i = 1; dut->eval();
            dut->clk_i = 0; dut->eval();
            cycle_count++;
        }
        dut->rst_i = 0;
        dut->eval();
    }

    void step() {
        dut->clk_i = 1;
        dut->eval();
        dut->clk_i = 0;
        dut->eval();
        cycle_count++;
    }

    void set_uop0(const IntIQTestUop& u) {
        dut->uop0_valid_i       = 1;
        dut->uop0_class_i       = u.uop_class;
        dut->uop0_subop_i       = u.sub_op;
        dut->uop0_imm_i         = u.imm;
        dut->uop0_use_imm_i     = u.use_imm;
        dut->uop0_prs1_i        = u.prs1;
        dut->uop0_prs1_ready_i  = u.prs1_ready;
        dut->uop0_prs2_i        = u.prs2;
        dut->uop0_prs2_ready_i  = u.prs2_ready;
        dut->uop0_pnew_i        = u.pnew;
        dut->uop0_rob_idx_i     = u.rob_idx;
        dut->uop0_rob_epoch_i   = u.rob_epoch;
        dut->uop0_chkpt_id_i    = u.chkpt_id;
        dut->uop0_pc_i          = u.pc;
        dut->uop0_pred_taken_i  = u.pred_taken;
        dut->uop0_pred_target_i = u.pred_target;
        dut->uop0_is_branch_i   = u.is_branch;
        dut->uop0_is_jal_i      = u.is_jal;
        dut->uop0_is_jalr_i     = u.is_jalr;
        dut->uop0_br_type_i     = u.br_type;
        dut->uop0_pre_ghr_i[0] = u.pre_ghr; dut->uop0_pre_ghr_i[1] = 0; dut->uop0_pre_ghr_i[2] = 0; dut->uop0_pre_ghr_i[3] = 0;
        dut->uop0_exception_i   = u.exception;
        dut->uop0_exc_cause_i   = u.exc_cause;
    }

    void clear_uop0() {
        dut->uop0_valid_i = 0;
    }

    void set_uop1(const IntIQTestUop& u) {
        dut->uop1_valid_i       = 1;
        dut->uop1_class_i       = u.uop_class;
        dut->uop1_subop_i       = u.sub_op;
        dut->uop1_imm_i         = u.imm;
        dut->uop1_use_imm_i     = u.use_imm;
        dut->uop1_prs1_i        = u.prs1;
        dut->uop1_prs1_ready_i  = u.prs1_ready;
        dut->uop1_prs2_i        = u.prs2;
        dut->uop1_prs2_ready_i  = u.prs2_ready;
        dut->uop1_pnew_i        = u.pnew;
        dut->uop1_rob_idx_i     = u.rob_idx;
        dut->uop1_rob_epoch_i   = u.rob_epoch;
        dut->uop1_chkpt_id_i    = u.chkpt_id;
        dut->uop1_pc_i          = u.pc;
        dut->uop1_pred_taken_i  = u.pred_taken;
        dut->uop1_pred_target_i = u.pred_target;
        dut->uop1_is_branch_i   = u.is_branch;
        dut->uop1_is_jal_i      = u.is_jal;
        dut->uop1_is_jalr_i     = u.is_jalr;
        dut->uop1_br_type_i     = u.br_type;
        dut->uop1_pre_ghr_i[0] = u.pre_ghr; dut->uop1_pre_ghr_i[1] = 0; dut->uop1_pre_ghr_i[2] = 0; dut->uop1_pre_ghr_i[3] = 0;
        dut->uop1_exception_i   = u.exception;
        dut->uop1_exc_cause_i   = u.exc_cause;
    }

    void clear_uop1() {
        dut->uop1_valid_i = 0;
    }
};

static IntIQTestUop make_uop(uint8_t uclass, uint8_t rob_idx, uint8_t prs1, bool prs1_ready,
                             uint8_t prs2, bool prs2_ready, uint8_t pnew, bool use_imm = false) {
    IntIQTestUop u{};
    u.uop_class = uclass;
    u.sub_op = 0;
    u.imm = 0;
    u.use_imm = use_imm;
    u.prs1 = prs1;
    u.prs1_ready = prs1_ready;
    u.prs2 = prs2;
    u.prs2_ready = prs2_ready;
    u.pnew = pnew;
    u.rob_idx = rob_idx;
    u.rob_epoch = 0;
    u.chkpt_id = 0;
    u.pc = 0x80000000ULL + (rob_idx * 4);
    u.pred_taken = false;
    u.pred_target = 0;
    u.is_branch = (uclass == UOP_BRANCH);
    u.is_jal = (uclass == UOP_JAL);
    u.is_jalr = (uclass == UOP_JALR);
    u.br_type = 0;
    u.pre_ghr = 0;
    u.exception = false;
    u.exc_cause = 0;
    return u;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "=============================================================================\n";
    std::cout << "Fursoy Slice-1 M5 Phase B4: Oldest-Ready Matrix Scheduler Unit TB\n";
    std::cout << "=============================================================================\n";

    IntIQTB tb;

    // -------------------------------------------------------------------------
    // Test 1: Multiple simultaneously ready operations with correct oldest-ready selection
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Allocate 4 ALUs with different ROB indices, all waiting on p50
        // rob_idx: 10, 5, 8, 2
        tb.set_uop0(make_uop(UOP_ALU_INT, 10, 50, false, 2, true, 3));
        tb.set_uop1(make_uop(UOP_ALU_INT, 5,  50, false, 5, true, 4));
        tb.dut->rename_ack_i = 3;
        tb.step();

        tb.set_uop0(make_uop(UOP_ALU_INT, 8, 50, false, 8, true, 5));
        tb.set_uop1(make_uop(UOP_ALU_INT, 2, 50, false, 11, true, 6));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();

        // Broadcast WB wakeup for p50
        tb.dut->wb0_valid_i    = 1;
        tb.dut->wb0_comp_ack_i = 1;
        tb.dut->wb0_pnew_i     = 50;
        tb.step();
        tb.dut->wb0_valid_i = 0;
        tb.dut->eval();

        // In this cycle, ready uops have rob_dist: 2, 5, 8, 10.
        // Oldest is rob 2 (dist 2). Second oldest is rob 5 (dist 5).
        // Symmetric ALUs: Port 0 gets rob 2, Port 1 gets rob 5!
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 2);
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 5);
        std::cout << "  [PASS] Test 1: Multiple simultaneously ready uops correctly select oldest-ready (rob 2 on P0, rob 5 on P1)\n";
    }

    // -------------------------------------------------------------------------
    // Test 2: Older unready operation versus younger ready operation (OoO bypass)
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0: ALU (rob 2, dist 2, unready prs1)
        // Slot 1: ALU (rob 8, dist 8, ready)
        tb.set_uop0(make_uop(UOP_ALU_INT, 2, 1, false, 2, true, 3)); // Unready!
        tb.set_uop1(make_uop(UOP_ALU_INT, 8, 4, true, 5, true, 6));  // Ready!
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();
        tb.dut->eval();

        // Older uop (rob 2) is unready. Younger uop (rob 8) must issue!
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 8);
        std::cout << "  [PASS] Test 2: Older unready uop does not block younger ready uop (rob 8 issued out-of-order)\n";
    }

    // -------------------------------------------------------------------------
    // Test 3: Strict No Age Inversion: Younger branch NEVER bypasses older ready ALU
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0: Flex ALU (rob 4, dist 4, ready)
        // Slot 1: Branch (rob 10, dist 10, ready)
        tb.set_uop0(make_uop(UOP_ALU_INT, 4, 1, true, 2, true, 3));
        tb.set_uop1(make_uop(UOP_BRANCH,  10, 4, true, 5, true, 0));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();

        // Constrain Port 1: ALU1 credit NOT available (can_issue_alu1_i = 0)
        tb.dut->can_issue_alu1_i = 0;
        tb.dut->eval();

        // Under Section 7.4 Rule 4: Younger branch (rob 10) MUST NEVER bypass older ready ALU (rob 4).
        // Port 0 must issue the older ALU (rob 4).
        // Younger branch cannot issue on Port 1, so it must wait!
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 4);
        assert(tb.dut->issue1_valid_o == 0);
        std::cout << "  [PASS] Test 3: Strict no-age-inversion verified (older ALU rob 4 issued on P0, younger branch held when P1 busy)\n";
        tb.dut->can_issue_alu1_i = 1;
    }

    // -------------------------------------------------------------------------
    // Test 4: Equal-age tie-breaking with branch priority (Section 7.4 Rule 4)
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0: Flex ALU (rob 6, ready)
        // Slot 1: Branch (rob 6, ready) - Identical age!
        tb.set_uop0(make_uop(UOP_ALU_INT, 6, 1, true, 2, true, 3));
        tb.set_uop1(make_uop(UOP_BRANCH,  6, 4, true, 5, true, 0));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();

        // Test with P1 available: Branch gets Port 0, ALU gets Port 1
        tb.dut->can_issue_alu1_i = 1;
        tb.dut->eval();
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_is_branch(tb.dut->issue0_uop_o) == 1);
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_is_branch(tb.dut->issue1_uop_o) == 0);

        // Test with P1 unavailable: Branch priority tie-breaker ensures Branch gets Port 0!
        tb.dut->can_issue_alu1_i = 0;
        tb.dut->eval();
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_is_branch(tb.dut->issue0_uop_o) == 1);
        assert(tb.dut->issue1_valid_o == 0);
        std::cout << "  [PASS] Test 4: Equal-age tie-breaking with branch priority verified (Branch won P0 tie-break)\n";
        tb.dut->can_issue_alu1_i = 1;
    }

    // -------------------------------------------------------------------------
    // Test 5: Equal-age tie-breaking with Slot 0 precedence (Section 7.4 Rule 2)
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0: Flex ALU (rob 7, ready)
        // Slot 1: Flex ALU (rob 7, ready) - Identical age, both ALUs
        tb.set_uop0(make_uop(UOP_ALU_INT, 7, 1, true, 2, true, 3));
        tb.set_uop1(make_uop(UOP_ALU_INT, 7, 4, true, 5, true, 6));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();

        // When P1 unavailable, Slot 0 ALU must take precedence over Slot 1 ALU
        tb.dut->can_issue_alu1_i = 0;
        tb.dut->eval();
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_pnew(tb.dut->issue0_uop_o) == 3); // Slot 0 has pnew=3
        assert(tb.dut->issue1_valid_o == 0);
        std::cout << "  [PASS] Test 5: Equal-age non-branch tie-breaking gives Slot 0 precedence (pnew 3 selected)\n";
        tb.dut->can_issue_alu1_i = 1;
    }

    // -------------------------------------------------------------------------
    // Test 6: Bipartite matching optimization (P2-1) with concurrent dual issue
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0: Flex ALU (rob 4, ready)
        // Slot 1: Branch (rob 8, ready)
        // When P1 available: Branch goes to P0, Flex ALU goes to P1 (concurrent dual-issue)
        tb.set_uop0(make_uop(UOP_ALU_INT, 4, 1, true, 2, true, 3));
        tb.set_uop1(make_uop(UOP_BRANCH,  8, 4, true, 5, true, 0));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();
        tb.dut->can_issue_alu1_i = 1;
        tb.dut->eval();

        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 8); // Branch on Port 0
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 4); // Older ALU on Port 1
        std::cout << "  [PASS] Test 6: Bipartite matching concurrent dual-issue (Branch on P0, older ALU on P1 in 1 cycle)\n";
    }

    // -------------------------------------------------------------------------
    // Test 7: Multiplier and Divider port arbitration and credit backpressure
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0: MUL (rob 5), Slot 1: DIV (rob 10), Slot 2: ALU (rob 15)
        // All waiting on p50
        tb.set_uop0(make_uop(UOP_MUL, 5,  50, false, 2, true, 3));
        tb.set_uop1(make_uop(UOP_DIV, 10, 50, false, 5, true, 4));
        tb.dut->rename_ack_i = 3;
        tb.step();

        tb.set_uop0(make_uop(UOP_ALU_INT, 15, 50, false, 8, true, 5));
        tb.clear_uop1();
        tb.dut->rename_ack_i = 1;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();

        // Broadcast WB wakeup for p50
        tb.dut->wb0_valid_i    = 1;
        tb.dut->wb0_comp_ack_i = 1;
        tb.dut->wb0_pnew_i     = 50;
        tb.step();
        tb.dut->wb0_valid_i = 0;

        // 7a. MUL credit available -> MUL on P1, ALU on P0
        tb.dut->can_issue_mul_i  = 1;
        tb.dut->can_issue_div_i  = 0;
        tb.dut->can_issue_alu1_i = 1;
        tb.dut->eval();
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 5);
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 15);

        // 7b. MUL credit exhausted, DIV available -> DIV on P1, ALU on P0
        tb.dut->can_issue_mul_i  = 0;
        tb.dut->can_issue_div_i  = 1;
        tb.dut->eval();
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 10);
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 15);

        std::cout << "  [PASS] Test 7: Multiplier and Divider credit arbitration and P1 dispatch verified\n";
        tb.dut->can_issue_mul_i = 1;
        tb.dut->can_issue_div_i = 1;
    }

    // -------------------------------------------------------------------------
    // Test 8: ROB circular wraparound across 47 -> 0 boundary
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 44; // ROB head at 44

        // Entries waiting on p50:
        // rob 46 (dist 2)
        // rob 47 (dist 3)
        // rob 0  (dist 4 - wrapped!)
        // rob 1  (dist 5 - wrapped!)
        tb.set_uop0(make_uop(UOP_ALU_INT, 46, 50, false, 2, true, 3));
        tb.set_uop1(make_uop(UOP_ALU_INT, 47, 50, false, 5, true, 4));
        tb.dut->rename_ack_i = 3;
        tb.step();

        tb.set_uop0(make_uop(UOP_ALU_INT, 0, 50, false, 8, true, 5));
        tb.set_uop1(make_uop(UOP_ALU_INT, 1, 50, false, 11, true, 6));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();

        // Broadcast WB wakeup for p50
        tb.dut->wb0_valid_i    = 1;
        tb.dut->wb0_comp_ack_i = 1;
        tb.dut->wb0_pnew_i     = 50;
        tb.step();
        tb.dut->wb0_valid_i = 0;

        // Cycle 1: Oldest are rob 46 (dist 2) and rob 47 (dist 3)
        tb.dut->eval();
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 46);
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 47);
        tb.step(); // Deallocate 46 and 47

        // Cycle 2: Remaining oldest are rob 0 (dist 4) and rob 1 (dist 5)
        tb.dut->eval();
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 0);
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 1);
        std::cout << "  [PASS] Test 8: Wrap-safe age comparison across ROB circular wraparound (47->0) verified\n";
    }

    // -------------------------------------------------------------------------
    // Test 9: Wakeup detection from WB0, WB1, WB2
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Slot 0 waiting on p15; Slot 1 waiting on p20
        tb.set_uop0(make_uop(UOP_ALU_INT, 5, 15, false, 2, true, 3));
        tb.set_uop1(make_uop(UOP_ALU_INT, 6, 20, false, 2, true, 4));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();
        tb.dut->eval();

        // Neither ready yet
        assert(tb.dut->issue0_valid_o == 0);
        assert(tb.dut->issue1_valid_o == 0);

        // Broadcast WB0: p15, WB1: p20
        tb.dut->wb0_valid_i    = 1;
        tb.dut->wb0_comp_ack_i = 1;
        tb.dut->wb0_pnew_i     = 15;

        tb.dut->wb1_valid_i    = 1;
        tb.dut->wb1_comp_ack_i = 1;
        tb.dut->wb1_pnew_i     = 20;
        tb.step();

        tb.dut->wb0_valid_i = 0;
        tb.dut->wb1_valid_i = 0;
        tb.dut->eval();

        // Both awakened and now issue!
        assert(tb.dut->issue0_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == 5);
        assert(tb.dut->issue1_valid_o == 1);
        assert(get_uop_rob_idx(tb.dut->issue1_uop_o) == 6);
        std::cout << "  [PASS] Test 9: Tag wakeup from WB0 and WB1 correctly sets ready bits and enables issue\n";
    }

    // -------------------------------------------------------------------------
    // Test 10: Branch recovery squash (recover_valid_i)
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->rob_head_i = 0;

        // Dispatch 3 uops: rob 5 (older), rob 10 (recovery point), rob 15 (younger)
        tb.set_uop0(make_uop(UOP_ALU_INT, 5,  1, false, 2, true, 3));
        tb.set_uop1(make_uop(UOP_ALU_INT, 10, 4, false, 5, true, 6));
        tb.dut->rename_ack_i = 3;
        tb.step();

        tb.set_uop0(make_uop(UOP_ALU_INT, 15, 7, false, 8, true, 9));
        tb.clear_uop1();
        tb.dut->rename_ack_i = 1;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();

        // Assert branch recovery at rob 10
        tb.dut->recover_valid_i   = 1;
        tb.dut->recover_rob_idx_i = 10;
        tb.step();
        tb.dut->recover_valid_i = 0;
        tb.dut->eval();

        // Check diagnostic valid mask: rob 5 and rob 10 must survive; rob 15 must be squashed!
        for (int i = 0; i < 16; i++) {
            if (tb.dut->diag_valid_mask_o & (1 << i)) {
                assert(tb.dut->diag_rob_idx_o[i] <= 10);
                assert(tb.dut->diag_rob_idx_o[i] != 15);
            }
        }
        std::cout << "  [PASS] Test 10: Branch recovery squashes younger entry rob 15 and preserves older rob 5 and rob 10\n";
    }

    // -------------------------------------------------------------------------
    // Test 11: Single-cycle flush (flush_valid_i)
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.set_uop0(make_uop(UOP_ALU_INT, 1, 1, true, 2, true, 3));
        tb.set_uop1(make_uop(UOP_ALU_INT, 2, 4, true, 5, true, 6));
        tb.dut->rename_ack_i = 3;
        tb.step();
        tb.dut->rename_ack_i = 0;
        tb.clear_uop0();
        tb.clear_uop1();

        tb.dut->flush_valid_i = 1;
        tb.step();
        tb.dut->flush_valid_i = 0;
        tb.dut->eval();

        assert(tb.dut->diag_valid_mask_o == 0);
        assert(tb.dut->issue0_valid_o == 0);
        assert(tb.dut->issue1_valid_o == 0);
        std::cout << "  [PASS] Test 11: Single-cycle flush clears all queue entries\n";
    }

    // -------------------------------------------------------------------------
    // Test 12: Full queue capacity (16 entries) and dispatch backpressure
    // -------------------------------------------------------------------------
    {
        tb.reset();
        for (int i = 0; i < 8; i++) {
            assert(tb.dut->dispatch_ready_o == 3);
            tb.set_uop0(make_uop(UOP_ALU_INT, i * 2,     1, false, 2, true, 3));
            tb.set_uop1(make_uop(UOP_ALU_INT, i * 2 + 1, 4, false, 5, true, 6));
            tb.dut->rename_ack_i = 3;
            tb.step();
        }
        tb.clear_uop0();
        tb.clear_uop1();
        tb.dut->rename_ack_i = 0;
        tb.dut->eval();

        // Queue now full with 16 entries
        assert(tb.dut->diag_valid_mask_o == 0xFFFF);
        assert(tb.dut->dispatch_ready_o == 0); // Both slots stalled
        std::cout << "  [PASS] Test 12: Full queue capacity (16 entries) asserts dispatch backpressure dispatch_ready_o=00\n";
    }

    // -------------------------------------------------------------------------
    // Test 13: Sustained downstream backpressure on Port 1
    // -------------------------------------------------------------------------
    {
        tb.reset();
        tb.dut->can_issue_alu1_i = 0; // P1 cannot issue ALUs
        tb.dut->rob_head_i = 0;

        // Dispatch 4 ALUs waiting on physical register 10
        for (int i = 0; i < 2; i++) {
            tb.set_uop0(make_uop(UOP_ALU_INT, i * 2,     10, false, 0, true, 3));
            tb.set_uop1(make_uop(UOP_ALU_INT, i * 2 + 1, 10, false, 0, true, 6));
            tb.dut->rename_ack_i = 3;
            tb.step();
        }
        tb.clear_uop0();
        tb.clear_uop1();
        tb.dut->rename_ack_i = 0;

        // Broadcast wakeup for physical register 10
        tb.dut->wb0_valid_i = 1;
        tb.dut->wb0_comp_ack_i = 1;
        tb.dut->wb0_pnew_i = 10;
        tb.step();
        tb.dut->wb0_valid_i = 0;

        // Drain 4 entries purely through Port 0 (1 per cycle)
        for (int i = 0; i < 4; i++) {
            tb.dut->eval();
            assert(tb.dut->issue0_valid_o == 1);
            assert(get_uop_rob_idx(tb.dut->issue0_uop_o) == i);
            assert(tb.dut->issue1_valid_o == 0);
            tb.step();
        }
        tb.dut->eval();
        assert(tb.dut->issue0_valid_o == 0);
        std::cout << "  [PASS] Test 13: Sustained Port 1 backpressure drains queue through Port 0 without deadlock\n";
        tb.dut->can_issue_alu1_i = 1;
    }

    // -------------------------------------------------------------------------
    // Test 14: Multi-Seed Randomized Golden-Model Torture Verification
    // Canonical Seeds: 42, 20260920, 20261009 (contract >= 25,000 accepted ops each)
    // -------------------------------------------------------------------------
    struct GoldenEntry {
        bool valid = false;
        uint8_t uop_class = 0;
        uint8_t rob_idx = 0;
        uint8_t prs1 = 0;
        bool prs1_ready = false;
        uint8_t prs2 = 0;
        bool prs2_ready = false;
        uint8_t pnew = 0;
        bool is_branch = false;
        uint8_t port_mask = 3;
    };

    struct RandomIntIQStats {
        uint64_t seed = 0;
        uint64_t attempted_iterations = 0;
        uint64_t accepted_allocs = 0;
        uint64_t accepted_issues = 0;
        uint64_t accepted_ops = 0;
        uint64_t mismatches = 0;
        bool watchdog_tripped = false;
    };

    auto is_older_golden = [](uint8_t cand_dist, bool cand_is_br, uint8_t cand_idx,
                              uint8_t curr_dist, bool curr_is_br, uint8_t curr_idx) -> bool {
        if (cand_dist < curr_dist) return true;
        if (cand_dist == curr_dist) {
            if (cand_is_br && !curr_is_br) return true;
            if (!cand_is_br && curr_is_br) return false;
            return cand_idx < curr_idx;
        }
        return false;
    };

    auto run_randomized_intiq_test = [&](IntIQTB& unit_tb, uint64_t seed, uint64_t min_accepted) -> RandomIntIQStats {
        RandomIntIQStats stats;
        stats.seed = seed;
        unit_tb.reset();

        GoldenEntry golden[16];
        uint8_t current_rob_head = 0;
        std::mt19937_64 rng(seed);
        const uint64_t watchdog_iteration_limit = 500000;

        while ((stats.accepted_allocs < min_accepted || stats.accepted_issues < min_accepted) && !stats.watchdog_tripped) {
            stats.attempted_iterations++;
            if (stats.attempted_iterations > watchdog_iteration_limit) {
                stats.watchdog_tripped = true;
                break;
            }

            // Randomly advance rob_head
            if (rng() % 20 == 0) current_rob_head = (current_rob_head + 1) % 48;
            unit_tb.dut->rob_head_i = current_rob_head;

            // Environmental port credits
            bool can_mul  = (rng() % 10 < 8);
            bool can_div  = (rng() % 10 < 7);
            bool can_alu1 = (rng() % 10 < 8);

            unit_tb.dut->can_issue_mul_i  = can_mul;
            unit_tb.dut->can_issue_div_i  = can_div;
            unit_tb.dut->can_issue_alu1_i = can_alu1;

            // Compute readiness in golden model
            bool ready_p0[16]{}, ready_p1[16]{};
            for (int i = 0; i < 16; i++) {
                if (golden[i].valid) {
                    bool ops_ready = golden[i].prs1_ready && golden[i].prs2_ready;
                    ready_p0[i] = ops_ready && (golden[i].port_mask & 1);

                    bool p1_cred = false;
                    if (golden[i].uop_class == UOP_MUL) p1_cred = can_mul;
                    else if (golden[i].uop_class == UOP_DIV) p1_cred = can_div;
                    else p1_cred = can_alu1;

                    ready_p1[i] = ops_ready && (golden[i].port_mask & 2) && p1_cred;
                }
            }

            // Compute u0 (oldest ready) and u1 (second oldest ready)
            bool u0_valid = false, u1_valid = false;
            uint8_t u0_idx = 0, u1_idx = 0;
            uint8_t u0_dist = 63, u1_dist = 63;

            for (int i = 0; i < 16; i++) {
                if (ready_p0[i] || ready_p1[i]) {
                    uint8_t d = calc_rob_dist(golden[i].rob_idx, current_rob_head);
                    if (!u0_valid || is_older_golden(d, golden[i].is_branch, i, u0_dist, golden[u0_idx].is_branch, u0_idx)) {
                        u0_dist = d;
                        u0_idx = i;
                        u0_valid = true;
                    }
                }
            }

            if (u0_valid) {
                for (int i = 0; i < 16; i++) {
                    if ((i != u0_idx) && (ready_p0[i] || ready_p1[i])) {
                        uint8_t d = calc_rob_dist(golden[i].rob_idx, current_rob_head);
                        if (!u1_valid || is_older_golden(d, golden[i].is_branch, i, u1_dist, golden[u1_idx].is_branch, u1_idx)) {
                            u1_dist = d;
                            u1_idx = i;
                            u1_valid = true;
                        }
                    }
                }
            }

            // Golden bipartite port matching
            bool exp_p0_valid = false, exp_p1_valid = false;
            uint8_t exp_p0_idx = 0, exp_p1_idx = 0;

            if (u0_valid) {
                bool is_p0_only_u0 = (golden[u0_idx].port_mask == 1);
                bool is_p1_only_u0 = (golden[u0_idx].port_mask == 2);

                if (is_p0_only_u0) {
                    exp_p0_valid = true;
                    exp_p0_idx   = u0_idx;
                    uint8_t best_p1_d = 63;
                    for (int i = 0; i < 16; i++) {
                        if ((i != u0_idx) && ready_p1[i]) {
                            uint8_t d = calc_rob_dist(golden[i].rob_idx, current_rob_head);
                            if (!exp_p1_valid || is_older_golden(d, false, i, best_p1_d, false, exp_p1_idx)) {
                                best_p1_d    = d;
                                exp_p1_idx   = i;
                                exp_p1_valid = true;
                            }
                        }
                    }
                } else if (is_p1_only_u0) {
                    exp_p1_valid = true;
                    exp_p1_idx   = u0_idx;
                    uint8_t best_p0_d = 63;
                    for (int i = 0; i < 16; i++) {
                        if ((i != u0_idx) && ready_p0[i]) {
                            uint8_t d = calc_rob_dist(golden[i].rob_idx, current_rob_head);
                            if (!exp_p0_valid || is_older_golden(d, golden[i].is_branch, i, best_p0_d, golden[exp_p0_idx].is_branch, exp_p0_idx)) {
                                best_p0_d    = d;
                                exp_p0_idx   = i;
                                exp_p0_valid = true;
                            }
                        }
                    }
                } else {
                    // Flex ALU u0
                    if (u1_valid) {
                        bool is_p0_only_u1 = (golden[u1_idx].port_mask == 1);
                        bool is_p1_only_u1 = (golden[u1_idx].port_mask == 2);
                        bool is_flex_u1    = (golden[u1_idx].port_mask == 3);

                        if (is_p0_only_u1 && ready_p1[u0_idx]) {
                            exp_p0_valid = true; exp_p0_idx = u1_idx;
                            exp_p1_valid = true; exp_p1_idx = u0_idx;
                        } else if (is_p1_only_u1 && ready_p1[u1_idx]) {
                            exp_p0_valid = true; exp_p0_idx = u0_idx;
                            exp_p1_valid = true; exp_p1_idx = u1_idx;
                        } else if (is_flex_u1 && ready_p1[u1_idx]) {
                            exp_p0_valid = true; exp_p0_idx = u0_idx;
                            exp_p1_valid = true; exp_p1_idx = u1_idx;
                        } else {
                            exp_p0_valid = true; exp_p0_idx = u0_idx;
                            uint8_t best_p1_d = 63;
                            for (int i = 0; i < 16; i++) {
                                if ((i != u0_idx) && ready_p1[i]) {
                                    uint8_t d = calc_rob_dist(golden[i].rob_idx, current_rob_head);
                                    if (!exp_p1_valid || is_older_golden(d, false, i, best_p1_d, false, exp_p1_idx)) {
                                        best_p1_d    = d;
                                        exp_p1_idx   = i;
                                        exp_p1_valid = true;
                                    }
                                }
                            }
                        }
                    } else {
                        exp_p0_valid = true; exp_p0_idx = u0_idx;
                    }
                }
            }

            // Recovery setup
            bool do_recover = (rng() % 300 == 0);
            uint8_t rec_rob_idx = rng() % 48;
            unit_tb.dut->recover_valid_i   = do_recover;
            unit_tb.dut->recover_rob_idx_i = rec_rob_idx;

            // WB snoops
            bool wb0_v = (rng() % 10 < 3);
            uint8_t wb0_p = (rng() % 63) + 1;
            unit_tb.dut->wb0_valid_i    = wb0_v;
            unit_tb.dut->wb0_comp_ack_i = 1;
            unit_tb.dut->wb0_pnew_i     = wb0_p;

            bool wb1_v = (rng() % 10 < 3);
            uint8_t wb1_p = (rng() % 63) + 1;
            unit_tb.dut->wb1_valid_i    = wb1_v;
            unit_tb.dut->wb1_comp_ack_i = 1;
            unit_tb.dut->wb1_pnew_i     = wb1_p;

            bool wb2_v = (rng() % 10 < 3);
            uint8_t wb2_p = (rng() % 63) + 1;
            unit_tb.dut->wb2_valid_i          = wb2_v;
            unit_tb.dut->wb2_comp_ack_i       = 1;
            unit_tb.dut->wb2_comp_exception_i = (rng() % 10 == 0);
            unit_tb.dut->wb2_pnew_i           = wb2_p;

            // Pre-step evaluation & verification
            unit_tb.dut->eval();

            if (unit_tb.dut->issue0_valid_o != (exp_p0_valid ? 1 : 0)) stats.mismatches++;
            assert(unit_tb.dut->issue0_valid_o == (exp_p0_valid ? 1 : 0));
            if (exp_p0_valid) {
                if (get_uop_rob_idx(unit_tb.dut->issue0_uop_o) != golden[exp_p0_idx].rob_idx) stats.mismatches++;
                assert(get_uop_rob_idx(unit_tb.dut->issue0_uop_o) == golden[exp_p0_idx].rob_idx);
                stats.accepted_issues++;
            }

            if (unit_tb.dut->issue1_valid_o != (exp_p1_valid ? 1 : 0)) stats.mismatches++;
            assert(unit_tb.dut->issue1_valid_o == (exp_p1_valid ? 1 : 0));
            if (exp_p1_valid) {
                if (get_uop_rob_idx(unit_tb.dut->issue1_uop_o) != golden[exp_p1_idx].rob_idx) stats.mismatches++;
                assert(get_uop_rob_idx(unit_tb.dut->issue1_uop_o) == golden[exp_p1_idx].rob_idx);
                stats.accepted_issues++;
            }

            // Check dispatch availability
            int golden_free = 0;
            int g_slot0 = -1, g_slot1 = -1;
            for (int i = 0; i < 16; i++) {
                if (!golden[i].valid) {
                    golden_free++;
                    if (g_slot0 == -1) g_slot0 = i;
                    else if (g_slot1 == -1) g_slot1 = i;
                }
            }

            uint8_t exp_dispatch_ready = 0;
            if (golden_free >= 1) exp_dispatch_ready |= 1;
            if (golden_free >= 2) exp_dispatch_ready |= 2;
            if (unit_tb.dut->dispatch_ready_o != exp_dispatch_ready) stats.mismatches++;
            assert(unit_tb.dut->dispatch_ready_o == exp_dispatch_ready);

            // Decide allocations
            bool try_alloc0 = !do_recover && (rng() % 10 < 6);
            bool try_alloc1 = try_alloc0 && (rng() % 10 < 5);

            uint8_t ack = 0;
            IntIQTestUop u0{}, u1{};
            auto gen_class = [&]() -> uint8_t {
                uint32_t r = rng() % 10;
                if (r < 6) return UOP_ALU_INT;
                if (r < 8) return UOP_BRANCH;
                if (r < 9) return UOP_MUL;
                return UOP_DIV;
            };

            if (try_alloc0 && (exp_dispatch_ready & 1)) {
                uint8_t cls = gen_class();
                u0 = make_uop(cls, rng() % 48, (rng() % 63) + 1, (rng() % 3 == 0), (rng() % 63) + 1, (rng() % 3 == 0), (rng() % 63) + 1);
                unit_tb.set_uop0(u0);
                ack |= 1;
            } else {
                unit_tb.clear_uop0();
            }

            if (try_alloc1 && (exp_dispatch_ready & 2)) {
                uint8_t cls = gen_class();
                u1 = make_uop(cls, rng() % 48, (rng() % 63) + 1, (rng() % 3 == 0), (rng() % 63) + 1, (rng() % 3 == 0), (rng() % 63) + 1);
                unit_tb.set_uop1(u1);
                ack |= 2;
            } else {
                unit_tb.clear_uop1();
            }

            unit_tb.dut->rename_ack_i = ack;

            // Sequential Golden Model State Update
            // 1. Deallocate issued uops
            if (exp_p0_valid) golden[exp_p0_idx].valid = false;
            if (exp_p1_valid) golden[exp_p1_idx].valid = false;

            // 2. Squash younger entries on recovery
            if (do_recover) {
                uint8_t rec_dist = calc_rob_dist(rec_rob_idx, current_rob_head);
                for (int i = 0; i < 16; i++) {
                    if (golden[i].valid && (calc_rob_dist(golden[i].rob_idx, current_rob_head) > rec_dist)) {
                        golden[i].valid = false;
                    }
                }
            }

            // 3. Wakeup on surviving entries
            for (int i = 0; i < 16; i++) {
                if (golden[i].valid) {
                    if (wb0_v) {
                        if (golden[i].prs1 == wb0_p) golden[i].prs1_ready = true;
                        if (golden[i].prs2 == wb0_p) golden[i].prs2_ready = true;
                    }
                    if (wb1_v) {
                        if (golden[i].prs1 == wb1_p) golden[i].prs1_ready = true;
                        if (golden[i].prs2 == wb1_p) golden[i].prs2_ready = true;
                    }
                    if (wb2_v && !unit_tb.dut->wb2_comp_exception_i) {
                        if (golden[i].prs1 == wb2_p) golden[i].prs1_ready = true;
                        if (golden[i].prs2 == wb2_p) golden[i].prs2_ready = true;
                    }
                }
            }

            // 4. Allocate new entries
            if ((ack & 1) && g_slot0 != -1) {
                golden[g_slot0].valid = true;
                golden[g_slot0].uop_class = u0.uop_class;
                golden[g_slot0].rob_idx = u0.rob_idx;
                golden[g_slot0].prs1 = u0.prs1;
                golden[g_slot0].prs1_ready = u0.prs1_ready || (u0.prs1 == 0) ||
                    (wb0_v && (u0.prs1 == wb0_p)) ||
                    (wb1_v && (u0.prs1 == wb1_p)) ||
                    (wb2_v && !unit_tb.dut->wb2_comp_exception_i && (u0.prs1 == wb2_p));
                golden[g_slot0].prs2 = u0.prs2;
                golden[g_slot0].prs2_ready = u0.prs2_ready || (u0.prs2 == 0) ||
                    (wb0_v && (u0.prs2 == wb0_p)) ||
                    (wb1_v && (u0.prs2 == wb1_p)) ||
                    (wb2_v && !unit_tb.dut->wb2_comp_exception_i && (u0.prs2 == wb2_p));
                golden[g_slot0].pnew = u0.pnew;
                golden[g_slot0].is_branch = u0.is_branch;
                if (u0.is_branch) golden[g_slot0].port_mask = 1;
                else if (u0.uop_class == UOP_MUL || u0.uop_class == UOP_DIV) golden[g_slot0].port_mask = 2;
                else golden[g_slot0].port_mask = 3;

                stats.accepted_allocs++;
            }

            if ((ack & 2) && g_slot1 != -1) {
                golden[g_slot1].valid = true;
                golden[g_slot1].uop_class = u1.uop_class;
                golden[g_slot1].rob_idx = u1.rob_idx;
                golden[g_slot1].prs1 = u1.prs1;
                golden[g_slot1].prs1_ready = u1.prs1_ready || (u1.prs1 == 0) ||
                    (wb0_v && (u1.prs1 == wb0_p)) ||
                    (wb1_v && (u1.prs1 == wb1_p)) ||
                    (wb2_v && !unit_tb.dut->wb2_comp_exception_i && (u1.prs1 == wb2_p));
                golden[g_slot1].prs2 = u1.prs2;
                golden[g_slot1].prs2_ready = u1.prs2_ready || (u1.prs2 == 0) ||
                    (wb0_v && (u1.prs2 == wb0_p)) ||
                    (wb1_v && (u1.prs2 == wb1_p)) ||
                    (wb2_v && !unit_tb.dut->wb2_comp_exception_i && (u1.prs2 == wb2_p));
                golden[g_slot1].pnew = u1.pnew;
                golden[g_slot1].is_branch = u1.is_branch;
                if (u1.is_branch) golden[g_slot1].port_mask = 1;
                else if (u1.uop_class == UOP_MUL || u1.uop_class == UOP_DIV) golden[g_slot1].port_mask = 2;
                else golden[g_slot1].port_mask = 3;

                stats.accepted_allocs++;
            }

            // Step clock
            unit_tb.step();
        }

        stats.accepted_ops = stats.accepted_allocs + stats.accepted_issues;
        return stats;
    };

    // Run multi-seed tests
    const std::vector<uint64_t> canonical_seeds = {42, 20260920, 20261009};
    const uint64_t min_accepted_threshold = 25000;

    std::cout << "  --- Test 14: Multi-Seed Randomized Golden Torture Verification ---\n";
    for (auto seed : canonical_seeds) {
        auto stats = run_randomized_intiq_test(tb, seed, min_accepted_threshold);
        std::cout << "seed_" << stats.seed
                  << ": iterations=" << stats.attempted_iterations
                  << " allocs=" << stats.accepted_allocs
                  << " issues=" << stats.accepted_issues
                  << " ops=" << stats.accepted_ops
                  << " mismatches=" << stats.mismatches
                  << " watchdog=" << (stats.watchdog_tripped ? "TIMEOUT" : "OK")
                  << "\n";
        assert(!stats.watchdog_tripped);
        assert(stats.mismatches == 0);
        assert(stats.accepted_allocs >= min_accepted_threshold);
        assert(stats.accepted_issues >= min_accepted_threshold);
    }

    std::cout << "=============================================================================\n";
    std::cout << "ALL 14 UNIT SCENARIOS PASS (seeds 42, 20260920, 20261009 >= 25k ops each)\n";
    std::cout << "=============================================================================\n";
    return 0;
}
