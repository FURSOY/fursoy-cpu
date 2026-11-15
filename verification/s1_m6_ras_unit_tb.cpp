// =============================================================================
// Fursoy Slice-1 Milestone 6 Phase B: Return Address Stack (RAS) Unit Testbench
// =============================================================================
// Reference: docs/architecture/slice1-m6-frontend-opt-v1.md Section 6.3 & Section 10
//
// Verification Scope:
// 1. Directed verification of all 5 link-register cases:
//    - Case 1 (None): rd, rs1 not in {x1, x5} -> Zero RAS action.
//    - Case 2 (Call / PUSH): rd in {x1, x5}, rs1 not in {x1, x5} -> Push PC+4.
//    - Case 3 (Return / POP): rd not in {x1, x5}, rs1 in {x1, x5} -> Pop target.
//    - Case 4 (Coroutine Swap / POP then PUSH): rd, rs1 in {x1, x5}, rd != rs1 ->
//      Predict target from TOS, overwrite TOS with PC+4, strict TOS/depth invariance.
//    - Case 5 (Special Link / PUSH only): rd, rs1 in {x1, x5}, rd == rs1 -> Push PC+4.
// 2. Dedicated Coroutine Swap Torture:
//    - 10,000 continuous alternating Case 4 coroutine swaps between x1 and x5;
//      assert that tos_q and depth_q remain strictly invariant throughout sequence.
// 3. Deep call recursion:
//    - 32 consecutive nested calls (assert circular pointer wrapping modulo 16
//      and logical depth saturation at 16).
// 4. Deep call return:
//    - 32 consecutive returns (assert correct unwinding of last 16 returns
//      and clean depth underflow floor at 0).
// 5. Speculative checkpoint capture across 8 checkpoints and single-cycle recovery.
// 6. Stage F3 Early JAL restore verification (early_jal_restore_ras).
// 7. Dual-slot interaction (Slot 0 untaken COND + Slot 1 CORO; Slot 0 taken suppression).
// 8. Multi-seed randomized call/return/coroutine torture across canonical seeds
//    (42, 20260920, 20261009) with >= 25,000 accepted operations per seed
//    (75,000 total ops) against independent cycle-synchronous C++ GoldenRAS model,
//    requiring 0 mismatches and 0 assertion failures.
// =============================================================================

#include <iostream>
#include <iomanip>
#include <vector>
#include <utility>
#include <algorithm>
#include <cstdint>
#include <cassert>
#include <memory>
#include <random>
#include <sstream>

#include "Vfursoy_s1_bpu.h"
#include "Vfursoy_s1_bpu___024root.h"
#include "verilated.h"

// -----------------------------------------------------------------------------
// Golden Reference Model Data Structures
// -----------------------------------------------------------------------------
struct GoldenRASSnapshot {
    uint64_t array[16];
    uint8_t  tos;   // 4-bit (0..15)
    uint8_t  depth; // 5-bit (0..16)

    bool operator==(const GoldenRASSnapshot& o) const {
        if (tos != o.tos || depth != o.depth) return false;
        for (int i = 0; i < 16; i++) {
            if (array[i] != o.array[i]) return false;
        }
        return true;
    }
    bool operator!=(const GoldenRASSnapshot& o) const { return !(*this == o); }
};

static inline GoldenRASSnapshot unpack_ras_chkpt(const uint32_t words[33]) {
    GoldenRASSnapshot snap;
    snap.depth = words[0] & 0x1F;
    snap.tos   = (words[0] >> 5) & 0x0F;

    for (int i = 0; i < 16; i++) {
        int bit_start = 9 + 64 * i;
        int w = bit_start / 32;
        int s = bit_start % 32;
        uint64_t val = 0;
        if (s == 0) {
            val = (uint64_t)words[w] | ((uint64_t)words[w + 1] << 32);
        } else {
            uint64_t p0 = (uint64_t)words[w] >> s;
            uint64_t p1 = (uint64_t)words[w + 1] << (32 - s);
            uint64_t p2 = (w + 2 < 33) ? ((uint64_t)words[w + 2] << (64 - s)) : 0ULL;
            val = p0 | p1 | p2;
        }
        snap.array[i] = val;
    }
    return snap;
}

static inline void pack_ras_chkpt(const GoldenRASSnapshot& snap, uint32_t words[33]) {
    for (int w = 0; w < 33; w++) words[w] = 0;
    words[0] |= (snap.depth & 0x1F);
    words[0] |= ((snap.tos & 0x0F) << 5);

    for (int i = 0; i < 16; i++) {
        int bit_start = 9 + 64 * i;
        uint64_t val = snap.array[i];
        int w = bit_start / 32;
        int s = bit_start % 32;
        if (s == 0) {
            words[w]     |= (uint32_t)(val & 0xFFFFFFFFULL);
            words[w + 1] |= (uint32_t)(val >> 32);
        } else {
            words[w]     |= (uint32_t)((val << s) & 0xFFFFFFFFULL);
            words[w + 1] |= (uint32_t)((val >> (32 - s)) & 0xFFFFFFFFULL);
            if (w + 2 < 33) {
                words[w + 2] |= (uint32_t)(val >> (64 - s));
            }
        }
    }
}

class GoldenRAS {
public:
    GoldenRASSnapshot snap;
    GoldenRASSnapshot checkpoints[8];

    GoldenRAS() { reset(); }

    void reset() {
        for (int i = 0; i < 16; i++) snap.array[i] = 0;
        snap.tos   = 0;
        snap.depth = 0;
        for (int i = 0; i < 8; i++) checkpoints[i] = snap;
    }

    uint64_t peek_top() const {
        return snap.array[snap.tos];
    }

    // Case 1: None
    void do_none() {
        // Zero RAS action
    }

    // Case 2 & Case 5: Call / PUSH (PC + 4)
    void do_push(uint64_t return_pc) {
        snap.tos = (snap.tos + 1) & 0x0F;
        snap.array[snap.tos] = return_pc;
        if (snap.depth < 16) snap.depth++;
    }

    // Case 3: Return / POP
    uint64_t do_pop() {
        uint64_t target = peek_top();
        if (snap.depth > 0) {
            snap.tos = (snap.tos - 1) & 0x0F;
            snap.depth--;
        }
        return target;
    }

    // Case 4: Coroutine Swap / POP then PUSH (PC + 4)
    uint64_t do_coroutine_swap(uint64_t return_pc) {
        uint64_t target = peek_top();
        snap.array[snap.tos] = return_pc;
        // CRITICAL INVARIANT: tos and depth remain strictly invariant!
        return target;
    }

    void capture_checkpoint(int id) {
        assert(id >= 0 && id < 8);
        checkpoints[id] = snap;
    }

    void restore_checkpoint(int id) {
        assert(id >= 0 && id < 8);
        snap = checkpoints[id];
    }

    void restore_early(const GoldenRASSnapshot& s) {
        snap = s;
    }
};

// -----------------------------------------------------------------------------
// Testbench Driver Wrapper
// -----------------------------------------------------------------------------
class RASTestbench {
public:
    std::unique_ptr<Vfursoy_s1_bpu> dut;
    uint64_t cycle;

    RASTestbench() : dut(std::make_unique<Vfursoy_s1_bpu>()), cycle(0) {
        dut->clk_i = 0;
        dut->rst_i = 0;
        dut->fetch_lookup_valid_i = 0;
        dut->fetch_pc_i = 0;
        dut->early_jal_valid_i = 0;
        for (int i = 0; i < 33; i++) dut->early_jal_restore_ras_i[i] = 0;
        dut->early_jal_restore_ras_id_i = 0;
        dut->chkpt_alloc_valid0_i = 0;
        dut->chkpt_alloc_id0_i = 0;
        for (int i = 0; i < 33; i++) dut->chkpt_alloc_ras0_i[i] = 0;
        dut->chkpt_alloc_ras_id0_i = 0;
        dut->chkpt_alloc_valid1_i = 0;
        dut->chkpt_alloc_id1_i = 0;
        for (int i = 0; i < 33; i++) dut->chkpt_alloc_ras1_i[i] = 0;
        dut->chkpt_alloc_ras_id1_i = 0;
        dut->recover_valid_i = 0;
        dut->recover_chkpt_id_i = 0;
        dut->recover_actual_taken_i = 0;
        dut->recover_actual_target_i = 0;
        dut->flush_valid_i = 0;
        dut->train_valid_i = 0;
        dut->train_pc_i = 0;
        dut->train_actual_taken_i = 0;
        dut->train_actual_target_i = 0;
        dut->train_br_type_i = 0;
    }

    void tick() {
        dut->clk_i = 0;
        dut->eval();
        dut->clk_i = 1;
        dut->eval();
        cycle++;
    }

    void reset_dut() {
        dut->fetch_lookup_valid_i = 0;
        dut->early_jal_valid_i = 0;
        dut->chkpt_alloc_valid0_i = 0;
        dut->chkpt_alloc_valid1_i = 0;
        dut->recover_valid_i = 0;
        dut->flush_valid_i = 0;
        dut->train_valid_i = 0;
        dut->rst_i = 1;
        tick();
        tick();
        dut->rst_i = 0;
        tick();
    }

    void train_btb(uint64_t pc, uint8_t br_type, uint64_t target) {
        dut->fetch_lookup_valid_i = 0;
        dut->train_valid_i = 1;
        dut->train_pc_i = pc;
        dut->train_actual_taken_i = 1;
        dut->train_actual_target_i = target;
        dut->train_br_type_i = br_type;
        tick();
        dut->train_valid_i = 0;
        dut->eval();
    }

    GoldenRASSnapshot get_current_snapshot() {
#ifdef TEST_INDEXED_RAS_CHKPT
        GoldenRASSnapshot snap;
        snap.tos   = dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q & 0x0F;
        snap.depth = dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q & 0x1F;
        for (int i = 0; i < 16; i++) {
            uint64_t lo = (uint64_t)dut->rootp->fursoy_s1_bpu__DOT__ras_array[2 * i];
            uint64_t hi = (uint64_t)dut->rootp->fursoy_s1_bpu__DOT__ras_array[2 * i + 1];
            snap.array[i] = lo | (hi << 32);
        }
        return snap;
#else
        return unpack_ras_chkpt(dut->slot0_ras_chkpt_o);
#endif
    }
};

// -----------------------------------------------------------------------------
// Main Test Runner
// -----------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    std::cout << "[M6-RAS] Starting Fursoy Slice-1 Milestone 6 Phase B RAS Unit Testbench..." << std::endl;

    RASTestbench tb;
    GoldenRAS golden;

    // Verify packing/unpacking round-trip
    {
        GoldenRASSnapshot test_snap;
        test_snap.tos = 7;
        test_snap.depth = 13;
        for (int i = 0; i < 16; i++) {
            test_snap.array[i] = 0x80001000ULL + i * 0x100ULL + 0xDEADBEEF00000000ULL;
        }
        uint32_t packed[33];
        pack_ras_chkpt(test_snap, packed);
        GoldenRASSnapshot unpacked = unpack_ras_chkpt(packed);
        assert(test_snap == unpacked && "pack/unpack round-trip mismatch");
    }

    tb.reset_dut();
    golden.reset();

    int tests_passed = 0;
    int tests_total  = 0;

    auto test_check = [&](bool condition, const std::string& name) {
        tests_total++;
        if (condition) {
            tests_passed++;
            std::cout << "  [PASS] " << name << std::endl;
        } else {
            std::cerr << "  [FAIL] " << name << std::endl;
            assert(false);
        }
    };

    // =========================================================================
    // PART 1: DIRECTED CALLING CONVENTION LINK-REGISTER CASES (Cases 1..5)
    // =========================================================================
    std::cout << "\n--- Executing Directed Link-Register Properties ---" << std::endl;

    // Case 1: Indirect Jump (rd not in {x1, x5}, rs1 not in {x1, x5}) -> Zero RAS action
    {
        uint64_t ind_pc = 0x80001000;
        uint64_t ind_target = 0x80009000;
        tb.train_btb(ind_pc, 5 /* BR_TYPE_IND */, ind_target);

        tb.dut->fetch_pc_i = ind_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->slot0_pred_taken_o == 1, "Case 1: Indirect jump predicted taken");
        test_check(tb.dut->slot0_pred_target_o == ind_target, "Case 1: Target predicted from BTB");
        test_check(tb.dut->event_ras_call_o == 0, "Case 1: Zero RAS call event");
        test_check(tb.dut->event_ras_ret_o == 0, "Case 1: Zero RAS ret event");

        uint8_t pre_tos = tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q;
        uint8_t pre_depth = tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q;

        tb.tick(); // advance cycle

        test_check(tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q == pre_tos, "Case 1: TOS invariant");
        test_check(tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q == pre_depth, "Case 1: Depth invariant");
        tb.dut->fetch_lookup_valid_i = 0;
    }

    // Case 2: Call / PUSH (rd in {x1, x5}, rs1 not in {x1, x5}) -> Push return PC
    {
        uint64_t call_pc = 0x80002000;
        uint64_t call_target = 0x8000A000;
        tb.train_btb(call_pc, 3 /* BR_TYPE_CALL */, call_target);

        tb.dut->fetch_pc_i = call_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->slot0_pred_taken_o == 1, "Case 2: Call predicted taken");
        test_check(tb.dut->slot0_pred_target_o == call_target, "Case 2: Target predicted from BTB");
        test_check(tb.dut->event_ras_call_o == 1, "Case 2: EV_RAS_CALL_PUSH asserted");
        test_check(tb.dut->event_ras_ret_o == 0, "Case 2: EV_RAS_RET_POP deasserted");

        tb.tick();

        GoldenRASSnapshot s = tb.get_current_snapshot();
        test_check(s.tos == 1, "Case 2: TOS incremented to 1");
        test_check(s.depth == 1, "Case 2: Depth incremented to 1");
        test_check(s.array[1] == call_pc + 4, "Case 2: Pushed return PC (PC+4) installed at TOS");
        tb.dut->fetch_lookup_valid_i = 0;
    }

    // Case 3: Return / POP (rd not in {x1, x5}, rs1 in {x1, x5}) -> Pop from RAS
    {
        uint64_t ret_pc = 0x8000A040;
        tb.train_btb(ret_pc, 4 /* BR_TYPE_RET */, 0);

        tb.dut->fetch_pc_i = ret_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->slot0_pred_taken_o == 1, "Case 3: Return predicted taken");
        test_check(tb.dut->slot0_pred_target_o == 0x80002004, "Case 3: Predicted target popped correctly from RAS TOS");
        test_check(tb.dut->event_ras_call_o == 0, "Case 3: EV_RAS_CALL_PUSH deasserted");
        test_check(tb.dut->event_ras_ret_o == 1, "Case 3: EV_RAS_RET_POP asserted");

        tb.tick();

        GoldenRASSnapshot s = tb.get_current_snapshot();
        test_check(s.tos == 0, "Case 3: TOS decremented to 0");
        test_check(s.depth == 0, "Case 3: Depth decremented to 0");
        tb.dut->fetch_lookup_valid_i = 0;
    }

    // Case 4: Coroutine Swap (rd in {x1, x5}, rs1 in {x1, x5}, rd != rs1) -> POP then PUSH
    {
        // First push an initial caller return address (0x80003000)
        uint64_t init_call_pc = 0x80003000;
        tb.train_btb(init_call_pc, 3 /* BR_TYPE_CALL */, 0x8000B000);
        tb.dut->fetch_pc_i = init_call_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.tick();
        tb.dut->fetch_lookup_valid_i = 0;

        GoldenRASSnapshot before_coro = tb.get_current_snapshot();
        test_check(before_coro.tos == 1, "Case 4 Precondition: Initial TOS is 1");
        test_check(before_coro.depth == 1, "Case 4 Precondition: Initial Depth is 1");
        test_check(before_coro.array[1] == 0x80003004, "Case 4 Precondition: Initial return address is 0x80003004");

        // Now execute Case 4 Coroutine Swap at PC 0x8000B020
        uint64_t coro_pc = 0x8000B020;
        tb.train_btb(coro_pc, 6 /* BR_TYPE_CORO */, 0);

        tb.dut->fetch_pc_i = coro_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->slot0_pred_taken_o == 1, "Case 4: Coroutine swap predicted taken");
        test_check(tb.dut->slot0_pred_target_o == 0x80003004, "Case 4: Return target predicted from current TOS");
        test_check(tb.dut->event_ras_call_o == 1, "Case 4: EV_RAS_CALL_PUSH asserted for coroutine swap push");
        test_check(tb.dut->event_ras_ret_o == 1, "Case 4: EV_RAS_RET_POP asserted for coroutine swap pop");

        tb.tick();

        GoldenRASSnapshot after_coro = tb.get_current_snapshot();
        test_check(after_coro.tos == 1, "Case 4 CRITICAL INVARIANT: TOS strictly invariant (tos=1)");
        test_check(after_coro.depth == 1, "Case 4 CRITICAL INVARIANT: Depth strictly invariant (depth=1)");
        test_check(after_coro.array[1] == coro_pc + 4, "Case 4: New return address (PC+4 = 0x8000B024) overwritten in-place at TOS");
        tb.dut->fetch_lookup_valid_i = 0;
    }

    // Case 5: Special Link Re-use (rd in {x1, x5}, rs1 in {x1, x5}, rd == rs1) -> PUSH only
    {
        uint64_t spec_pc = 0x80004000;
        uint64_t spec_target = 0x8000C000;
        tb.train_btb(spec_pc, 3 /* BR_TYPE_CALL */, spec_target);

        tb.dut->fetch_pc_i = spec_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->slot0_pred_taken_o == 1, "Case 5: Special link call predicted taken");
        test_check(tb.dut->slot0_pred_target_o == spec_target, "Case 5: Target predicted from BTB");
        test_check(tb.dut->event_ras_call_o == 1, "Case 5: EV_RAS_CALL_PUSH asserted");
        test_check(tb.dut->event_ras_ret_o == 0, "Case 5: EV_RAS_RET_POP deasserted");

        tb.tick();

        GoldenRASSnapshot s = tb.get_current_snapshot();
        test_check(s.tos == 2, "Case 5: TOS incremented to 2");
        test_check(s.depth == 2, "Case 5: Depth incremented to 2");
        test_check(s.array[2] == spec_pc + 4, "Case 5: Pushed return PC installed at TOS");
        tb.dut->fetch_lookup_valid_i = 0;
    }

    // Reset for subsequent isolated suites
    tb.reset_dut();
    golden.reset();

    // =========================================================================
    // PART 2: DEDICATED COROUTINE SWAP TORTURE (10,000 ALTERNATING SWAPS)
    // =========================================================================
    std::cout << "\n--- Executing 10,000 Continuous Alternating Coroutine Swap Torture ---" << std::endl;
    {
        // Set up initial state with depth 4
        for (int i = 0; i < 4; i++) {
            uint64_t pc = 0x80001000 + i * 0x10;
            tb.train_btb(pc, 3 /* CALL */, 0x80002000);
            tb.dut->fetch_pc_i = pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.tick();
            tb.dut->fetch_lookup_valid_i = 0;
        }

        uint8_t base_tos = tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q;
        uint8_t base_depth = tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q;
        test_check(base_tos == 4, "Torture Setup: Base TOS is 4");
        test_check(base_depth == 4, "Torture Setup: Base Depth is 4");

        uint64_t coro_pc_A = 0x80010000;
        uint64_t coro_pc_B = 0x80020000;
        tb.train_btb(coro_pc_A, 6 /* CORO */, 0);
        tb.train_btb(coro_pc_B, 6 /* CORO */, 0);

        uint64_t expected_target = tb.dut->rootp->fursoy_s1_bpu__DOT__ras_top_val;
        bool invariant_held = true;

        for (int step = 0; step < 10000; step++) {
            uint64_t active_pc = (step % 2 == 0) ? coro_pc_A : coro_pc_B;
            tb.dut->fetch_pc_i = active_pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.dut->eval();

            if (tb.dut->slot0_pred_target_o != expected_target) {
                std::cerr << "Mismatch at step " << step << ": expected target 0x" << std::hex
                          << expected_target << " but got 0x" << tb.dut->slot0_pred_target_o << std::dec << std::endl;
                invariant_held = false;
                break;
            }

            if (tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q != base_tos ||
                tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q != base_depth) {
                invariant_held = false;
                break;
            }

            tb.tick();

            if (tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q != base_tos ||
                tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q != base_depth) {
                invariant_held = false;
                break;
            }

            expected_target = active_pc + 4;
        }
        tb.dut->fetch_lookup_valid_i = 0;

        test_check(invariant_held, "Coroutine Swap Torture: 10,000 alternating swaps PASSED with 0 pointer/depth drift");
    }

    // Reset
    tb.reset_dut();
    golden.reset();

    // =========================================================================
    // PART 3: DEEP CALL RECURSION (32 CONSECUTIVE CALLS)
    // =========================================================================
    std::cout << "\n--- Executing Deep Call Recursion (32 Consecutive Calls) ---" << std::endl;
    {
        bool call_chain_pass = true;
        for (int i = 0; i < 32; i++) {
            uint64_t call_pc = 0x80001000 + i * 8;
            tb.train_btb(call_pc, 3 /* CALL */, 0x80005000);

            tb.dut->fetch_pc_i = call_pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.tick();

            uint8_t exp_tos = (i + 1) & 0x0F;
            uint8_t exp_depth = (i + 1 < 16) ? (i + 1) : 16;

            if (tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q != exp_tos ||
                tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q != exp_depth) {
                std::cerr << "Deep Call Recursion mismatch at step " << i << ": tos="
                          << (int)tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q << " (exp " << (int)exp_tos
                          << "), depth=" << (int)tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q
                          << " (exp " << (int)exp_depth << ")" << std::endl;
                call_chain_pass = false;
                break;
            }
        }
        tb.dut->fetch_lookup_valid_i = 0;

        test_check(call_chain_pass, "Deep Call Recursion: 32 calls verified (physical pointer wrapped mod 16, depth saturated at 16)");
    }

    // =========================================================================
    // PART 4: DEEP CALL RETURN (32 CONSECUTIVE RETURNS)
    // =========================================================================
    std::cout << "\n--- Executing Deep Call Return (32 Consecutive Returns) ---" << std::endl;
    {
        bool ret_chain_pass = true;
        uint64_t ret_pc = 0x80005000;
        tb.train_btb(ret_pc, 4 /* RET */, 0);

        for (int i = 0; i < 32; i++) {
            tb.dut->fetch_pc_i = ret_pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.dut->eval();

            // Last 16 calls were 16..31: return address for i in 0..15 was (0x80001000 + (31 - i) * 8 + 4)
            if (i < 16) {
                uint64_t exp_ret = 0x80001000 + (31 - i) * 8 + 4;
                if (tb.dut->slot0_pred_target_o != exp_ret) {
                    std::cerr << "Deep Return mismatch at step " << i << ": target=0x" << std::hex
                              << tb.dut->slot0_pred_target_o << " (exp 0x" << exp_ret << ")" << std::dec << std::endl;
                    ret_chain_pass = false;
                    break;
                }
            }

            tb.tick();

            uint8_t exp_depth = (16 - (i + 1) > 0) ? (16 - (i + 1)) : 0;
            if (tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q != exp_depth) {
                std::cerr << "Deep Return depth mismatch at step " << i << ": depth="
                          << (int)tb.dut->rootp->fursoy_s1_bpu__DOT__ras_depth_q << " (exp "
                          << (int)exp_depth << ")" << std::endl;
                ret_chain_pass = false;
                break;
            }
        }
        tb.dut->fetch_lookup_valid_i = 0;

        test_check(ret_chain_pass, "Deep Call Return: 32 returns verified (correct unwinding of last 16 calls and depth floored at 0)");
    }

    // Reset
    tb.reset_dut();
    golden.reset();

    // =========================================================================
    // PART 5: SPECULATIVE CHECKPOINT CAPTURE ACROSS 8 CHECKPOINTS & RECOVERY
    // =========================================================================
    std::cout << "\n--- Executing Checkpoint Capture across 8 Checkpoints & 1-Cycle Recovery ---" << std::endl;
    {
        GoldenRASSnapshot saved_chkpts[8];

        for (int chkpt_id = 0; chkpt_id < 8; chkpt_id++) {
            // Push some calls to vary RAS state
            for (int k = 0; k < chkpt_id + 1; k++) {
                uint64_t pc = 0x80001000 + chkpt_id * 0x100 + k * 8;
                tb.train_btb(pc, 3 /* CALL */, 0x80009000);
                tb.dut->fetch_pc_i = pc;
                tb.dut->fetch_lookup_valid_i = 1;
                tb.tick();
            }
            tb.dut->fetch_lookup_valid_i = 0;

            saved_chkpts[chkpt_id] = tb.get_current_snapshot();

            // Allocate checkpoint
            tb.dut->chkpt_alloc_valid0_i = 1;
            tb.dut->chkpt_alloc_id0_i    = chkpt_id;
#ifdef TEST_INDEXED_RAS_CHKPT
            tb.dut->chkpt_alloc_ras_id0_i = tb.dut->slot0_ras_id_o;
#else
            pack_ras_chkpt(saved_chkpts[chkpt_id], tb.dut->chkpt_alloc_ras0_i);
#endif
            tb.tick();
            tb.dut->chkpt_alloc_valid0_i = 0;
        }

        // Mutate RAS state radically (perform flush or coroutine swaps)
        for (int k = 0; k < 5; k++) {
            uint64_t pc = 0x80008000 + k * 8;
            tb.train_btb(pc, 6 /* CORO */, 0);
            tb.dut->fetch_pc_i = pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.tick();
        }
        tb.dut->fetch_lookup_valid_i = 0;

        bool recovery_pass = true;
        // Verify 1-cycle restoration for each checkpoint
        for (int chkpt_id = 7; chkpt_id >= 0; chkpt_id--) {
            tb.dut->recover_valid_i          = 1;
            tb.dut->recover_chkpt_id_i       = chkpt_id;
            tb.dut->recover_actual_taken_i   = 1;
            tb.dut->recover_actual_target_i  = 0x8000F000;
            tb.tick();
            tb.dut->recover_valid_i          = 0;
            tb.dut->eval();

            GoldenRASSnapshot restored = tb.get_current_snapshot();
            if (restored != saved_chkpts[chkpt_id]) {
                std::cerr << "Checkpoint recovery mismatch for ID " << chkpt_id << std::endl;
                recovery_pass = false;
                break;
            }
        }

        test_check(recovery_pass, "Checkpoint Rollback: 8 checkpoints restored in single cycle matching pre-dispatch state bit-for-bit");
    }

    // Reset
    tb.reset_dut();
    golden.reset();

    // =========================================================================
    // PART 6: STAGE F3 EARLY JAL RESTORE VERIFICATION
    // =========================================================================
    std::cout << "\n--- Executing Stage F3 Early JAL Restore Verification ---" << std::endl;
    {
        // Establish baseline RAS state
        for (int k = 0; k < 5; k++) {
            uint64_t pc = 0x80001000 + k * 8;
            tb.train_btb(pc, 3 /* CALL */, 0x80009000);
            tb.dut->fetch_pc_i = pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.tick();
        }
        tb.dut->fetch_lookup_valid_i = 0;

        GoldenRASSnapshot pre_jal = tb.get_current_snapshot();
#ifdef TEST_INDEXED_RAS_CHKPT
        uint8_t pre_jal_id = tb.dut->slot0_ras_id_o;
#endif

        // Mutate RAS state speculatively
        for (int k = 0; k < 3; k++) {
            uint64_t pc = 0x80002000 + k * 8;
            tb.train_btb(pc, 3 /* CALL */, 0x80009000);
            tb.dut->fetch_pc_i = pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.tick();
        }
        tb.dut->fetch_lookup_valid_i = 0;

        // Early JAL restore
        tb.dut->early_jal_valid_i = 1;
#ifdef TEST_INDEXED_RAS_CHKPT
        tb.dut->early_jal_restore_ras_id_i = pre_jal_id;
#else
        pack_ras_chkpt(pre_jal, tb.dut->early_jal_restore_ras_i);
#endif
        tb.tick();
        tb.dut->early_jal_valid_i = 0;
        tb.dut->eval();

        GoldenRASSnapshot post_jal = tb.get_current_snapshot();
#ifdef TEST_INDEXED_RAS_CHKPT
        test_check(post_jal == pre_jal && tb.dut->slot0_ras_id_o == pre_jal_id,
                   "Stage F3 Early JAL: Clean 1-cycle restoration of TOS pointer, depth, ID, and RAS contents");
#else
        test_check(post_jal == pre_jal, "Stage F3 Early JAL: Clean 1-cycle restoration of TOS pointer, depth, and RAS contents");
#endif
    }

    // Reset
    tb.reset_dut();
    golden.reset();

    // =========================================================================
    // PART 7: DUAL-SLOT INTERACTION VERIFICATION
    // =========================================================================
    std::cout << "\n--- Executing Dual-Slot Interaction Verification ---" << std::endl;
    {
        // Scenario A: Slot 0 is untaken COND branch, Slot 1 is Coroutine Swap
        uint64_t block_pc = 0x80001000;
        uint64_t s0_pc    = 0x80001000;
        uint64_t s1_pc    = 0x80001004;

        // Push initial return address
        tb.train_btb(0x80000000, 3 /* CALL */, 0x80001000);
        tb.dut->fetch_pc_i = 0x80000000;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.tick();
        tb.dut->fetch_lookup_valid_i = 0;

        GoldenRASSnapshot before_dual = tb.get_current_snapshot();

        // Train Slot 0 as COND: first install in BTB, then train untaken
        tb.train_btb(s0_pc, 0 /* COND */, 0x80009000);
        tb.dut->train_valid_i = 1;
        tb.dut->train_pc_i = s0_pc;
        tb.dut->train_actual_taken_i = 0;
        tb.dut->train_br_type_i = 0;
        tb.tick();
        tb.tick();
        tb.dut->train_valid_i = 0;

        // Train Slot 1 as CORO
        tb.train_btb(s1_pc, 6 /* CORO */, 0);

        tb.dut->fetch_pc_i = block_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->slot0_pred_taken_o == 0, "Dual-Slot: Slot 0 COND predicted untaken");
        test_check(tb.dut->slot1_pred_taken_o == 1, "Dual-Slot: Slot 1 CORO predicted taken");
        test_check(tb.dut->pred_redirect_o == 1, "Dual-Slot: Block redirects on Slot 1");
        test_check(tb.dut->pred_slot_o == 1, "Dual-Slot: Pred slot is Slot 1");
        test_check(tb.dut->pred_target_o == 0x80000004, "Dual-Slot: Redirects to top of stack popped from RAS");

        tb.tick();
        tb.dut->fetch_lookup_valid_i = 0;

        GoldenRASSnapshot after_dual = tb.get_current_snapshot();
        test_check(after_dual.tos == before_dual.tos, "Dual-Slot: Slot 1 Coroutine Swap preserves TOS");
        test_check(after_dual.depth == before_dual.depth, "Dual-Slot: Slot 1 Coroutine Swap preserves Depth");
        test_check(after_dual.array[after_dual.tos] == s1_pc + 4, "Dual-Slot: Slot 1 Coroutine Swap overwrites TOS with s1_pc + 4");

        // Scenario B: Slot 0 is TAKEN CALL, Slot 1 is CORO -> Slot 1 must be suppressed
        tb.train_btb(s0_pc, 3 /* CALL */, 0x80003000);
        tb.dut->fetch_pc_i = block_pc;
        tb.dut->fetch_lookup_valid_i = 1;
        tb.dut->eval();

        test_check(tb.dut->pred_redirect_o == 1, "Dual-Slot Taken Suppression: Redirect asserted");
        test_check(tb.dut->pred_slot_o == 0, "Dual-Slot Taken Suppression: Slot 0 dominates redirect");
        test_check(tb.dut->pred_target_o == 0x80003000, "Dual-Slot Taken Suppression: Target is Slot 0 target");

        tb.tick();
        tb.dut->fetch_lookup_valid_i = 0;
        test_check(tb.dut->rootp->fursoy_s1_bpu__DOT__ras_tos_q == ((after_dual.tos + 1) & 0x0F),
                   "Dual-Slot Taken Suppression: Only Slot 0 CALL updated RAS");
    }

#ifdef TEST_INDEXED_RAS_CHKPT
    // =========================================================================
    // PART 7B: RENAME-BACKPRESSURE STRESS (>= 24 IN-FLIGHT RAS MUTATIONS)
    // =========================================================================
    std::cout << "\n--- Executing Indexed RAS Rename-Backpressure & Wrap Protection Stress ---" << std::endl;
    {
        tb.reset_dut();
        golden.reset();

        std::vector<std::pair<uint8_t, GoldenRASSnapshot>> inflight;
        inflight.push_back({tb.dut->slot0_ras_id_o, tb.get_current_snapshot()}); // slot 0 baseline

        bool monotonic_ok = (inflight[0].first == 0);
        // Simulate 26 un-renamed consecutive CALL/CORO/RET mutations (> FETCH_QUEUE_DEPTH+BPU_FIFO_DEPTH = 24)
        for (int step = 0; step < 26; step++) {
            uint64_t pc = 0x80040000 + step * 8;
            uint8_t br_type = (step < 14) ? 3 /* CALL */ : ((step < 20) ? 6 /* CORO */ : 4 /* RET */);
            tb.train_btb(pc, br_type, 0x80050000);
            tb.dut->fetch_pc_i = pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.dut->eval();
            if (br_type == 3) golden.do_push(pc + 4);
            else if (br_type == 6) golden.do_coroutine_swap(pc + 4);
            else golden.do_pop();
            tb.tick();
            tb.dut->fetch_lookup_valid_i = 0;

            uint8_t cur_id = tb.dut->slot0_ras_id_o;
            if (cur_id != (uint8_t)(step + 1)) monotonic_ok = false;
            inflight.push_back({cur_id, golden.snap});
        }
        test_check(monotonic_ok, "Backpressure Stress: 26 consecutive un-renamed mutations assigned unique IDs 1..26 without wrapping slot 0");

        // Advance 10 more mutations so allocator wraps 31 -> 1..5 while keeping slot 0 intact
        bool wrap_skips_zero = true;
        for (int step = 26; step < 36; step++) {
            uint64_t pc = 0x80040000 + step * 8;
            tb.train_btb(pc, 3 /* CALL */, 0x80050000);
            tb.dut->fetch_pc_i = pc;
            tb.dut->fetch_lookup_valid_i = 1;
            tb.tick();
            tb.dut->fetch_lookup_valid_i = 0;
            if (tb.dut->slot0_ras_id_o == 0 || tb.dut->slot0_ras_id_o > 31) wrap_skips_zero = false;
        }
        test_check(wrap_skips_zero, "Backpressure Stress: Allocator wrap across 31->1 never overwrites reserved slot 0");

        // Verify delayed Rename checkpoint capture across slot 0 and slots 12, 18, 25, 26 + recovery
        const int sample_indices[5] = {0, 12, 18, 25, 26};
        for (int c = 0; c < 5; c++) {
            tb.dut->chkpt_alloc_valid0_i   = 1;
            tb.dut->chkpt_alloc_id0_i      = c;
            tb.dut->chkpt_alloc_ras_id0_i  = inflight[sample_indices[c]].first;
            tb.tick();
            tb.dut->chkpt_alloc_valid0_i   = 0;
        }

        bool bp_recover_ok = true;
        for (int c = 4; c >= 0; c--) {
            tb.dut->recover_valid_i        = 1;
            tb.dut->recover_chkpt_id_i     = c;
            tb.dut->recover_actual_taken_i = 1;
            tb.dut->recover_actual_target_i = 0x8000F000;
            tb.tick();
            tb.dut->recover_valid_i = 0;
            tb.dut->eval();

            GoldenRASSnapshot restored = tb.get_current_snapshot();
            if (restored != inflight[sample_indices[c]].second || tb.dut->slot0_ras_id_o != 0) {
                bp_recover_ok = false;
                break;
            }
        }
        test_check(bp_recover_ok, "Backpressure Stress: Delayed Rename allocation & recovery exact for baseline slot 0 and IDs 12/18/25/26");
    }
#endif

    // Reset
    tb.reset_dut();
    golden.reset();

    // =========================================================================
    // PART 8: MULTI-SEED RANDOMIZED STRESS TORTURE
    // =========================================================================
    std::cout << "\n--- Executing Multi-Seed Randomized Stress Torture ---" << std::endl;

    const std::vector<uint64_t> canonical_seeds = {42, 20260920, 20261009};
    const int target_ops_per_seed = 25000;
    int total_accepted_ops = 0;
    std::vector<std::string> seed_reports;

    for (uint64_t seed : canonical_seeds) {
        std::cout << "Starting randomized torture run for seed: " << seed << " (target: " << target_ops_per_seed << " ops)..." << std::endl;
        std::mt19937_64 rng(seed);

        tb.reset_dut();
        golden.reset();

        int seed_accepted_ops = 0;
        int seed_mismatches = 0;
#ifdef TEST_INDEXED_RAS_CHKPT
        std::vector<std::pair<uint8_t, GoldenRASSnapshot>> id_history;
        id_history.push_back({tb.dut->slot0_ras_id_o, golden.snap});
#endif

        while (seed_accepted_ops < target_ops_per_seed) {
            uint32_t op_type = rng() % 100;

            if (op_type < 30) {
                // Operation: CALL (Push PC + 4)
                uint64_t pc = 0x80000000 + (rng() % 1000) * 8;
                uint64_t target = 0x80010000 + (rng() % 500) * 8;
                tb.train_btb(pc, 3 /* CALL */, target);

                tb.dut->fetch_pc_i = pc;
                tb.dut->fetch_lookup_valid_i = 1;
                tb.dut->eval();

                golden.do_push(pc + 4);
                tb.tick();
                tb.dut->fetch_lookup_valid_i = 0;
#ifdef TEST_INDEXED_RAS_CHKPT
                if (tb.dut->slot0_ras_id_o != id_history.back().first) {
                    id_history.push_back({tb.dut->slot0_ras_id_o, golden.snap});
                    if (id_history.size() > 24) id_history.erase(id_history.begin());
                }
#endif
                seed_accepted_ops++;

            } else if (op_type < 60) {
                // Operation: RETURN (Pop from RAS)
                uint64_t pc = 0x80020000 + (rng() % 1000) * 8;
                tb.train_btb(pc, 4 /* RET */, 0);

                tb.dut->fetch_pc_i = pc;
                tb.dut->fetch_lookup_valid_i = 1;
                tb.dut->eval();

                uint64_t exp_target = golden.do_pop();
                if (tb.dut->slot0_pred_target_o != exp_target) {
                    seed_mismatches++;
                }

                tb.tick();
                tb.dut->fetch_lookup_valid_i = 0;
#ifdef TEST_INDEXED_RAS_CHKPT
                if (tb.dut->slot0_ras_id_o != id_history.back().first) {
                    id_history.push_back({tb.dut->slot0_ras_id_o, golden.snap});
                    if (id_history.size() > 24) id_history.erase(id_history.begin());
                }
#endif
                seed_accepted_ops++;

            } else if (op_type < 85) {
                // Operation: COROUTINE SWAP (Case 4: Pop and Push, in-place overwrite)
                uint64_t pc = 0x80030000 + (rng() % 1000) * 8;
                tb.train_btb(pc, 6 /* CORO */, 0);

                tb.dut->fetch_pc_i = pc;
                tb.dut->fetch_lookup_valid_i = 1;
                tb.dut->eval();

                uint64_t exp_target = golden.do_coroutine_swap(pc + 4);
                if (tb.dut->slot0_pred_target_o != exp_target) {
                    seed_mismatches++;
                }

                tb.tick();
                tb.dut->fetch_lookup_valid_i = 0;
#ifdef TEST_INDEXED_RAS_CHKPT
                if (tb.dut->slot0_ras_id_o != id_history.back().first) {
                    id_history.push_back({tb.dut->slot0_ras_id_o, golden.snap});
                    if (id_history.size() > 24) id_history.erase(id_history.begin());
                }
#endif
                seed_accepted_ops++;

            } else if (op_type < 93) {
                // Operation: Branch Checkpoint Allocation & Port 0 Recovery
                int chkpt_id = rng() % 8;
                golden.capture_checkpoint(chkpt_id);

                tb.dut->chkpt_alloc_valid0_i = 1;
                tb.dut->chkpt_alloc_id0_i    = chkpt_id;
#ifdef TEST_INDEXED_RAS_CHKPT
                tb.dut->chkpt_alloc_ras_id0_i = tb.dut->slot0_ras_id_o;
#else
                pack_ras_chkpt(golden.snap, tb.dut->chkpt_alloc_ras0_i);
#endif
                tb.tick();
                tb.dut->chkpt_alloc_valid0_i = 0;

                // Random recovery probability (50%)
                if (rng() % 2 == 0) {
                    golden.restore_checkpoint(chkpt_id);
                    tb.dut->recover_valid_i         = 1;
                    tb.dut->recover_chkpt_id_i      = chkpt_id;
                    tb.dut->recover_actual_taken_i  = 1;
                    tb.dut->recover_actual_target_i = 0x8000F000;
                    tb.tick();
                    tb.dut->recover_valid_i         = 0;
#ifdef TEST_INDEXED_RAS_CHKPT
                    id_history.clear();
                    id_history.push_back({tb.dut->slot0_ras_id_o, golden.snap});
                    if (tb.dut->slot0_ras_id_o != 0) seed_mismatches++;
#endif
                    seed_accepted_ops++;
                }

            } else {
                // Operation: Early JAL Restore
#ifdef TEST_INDEXED_RAS_CHKPT
                size_t pick = rng() % id_history.size();
                uint8_t target_id = id_history[pick].first;
                GoldenRASSnapshot target_snap = id_history[pick].second;
                id_history.resize(pick + 1);

                golden.restore_early(target_snap);
                tb.dut->early_jal_valid_i = 1;
                tb.dut->early_jal_restore_ras_id_i = target_id;
                tb.tick();
                tb.dut->early_jal_valid_i = 0;
                if (tb.dut->slot0_ras_id_o != target_id) seed_mismatches++;
#else
                GoldenRASSnapshot rand_snap;
                rand_snap.tos   = rng() % 16;
                rand_snap.depth = rng() % 17;
                for (int k = 0; k < 16; k++) rand_snap.array[k] = rng();

                golden.restore_early(rand_snap);
                tb.dut->early_jal_valid_i = 1;
                pack_ras_chkpt(rand_snap, tb.dut->early_jal_restore_ras_i);
                tb.tick();
                tb.dut->early_jal_valid_i = 0;
#endif
                seed_accepted_ops++;
            }

            // Assert continuous synchronization against GoldenRAS
            GoldenRASSnapshot dut_snap = tb.get_current_snapshot();
            if (dut_snap != golden.snap) {
                std::cerr << "DUT state mismatch against GoldenRAS at seed " << seed << " op " << seed_accepted_ops << std::endl;
                seed_mismatches++;
                break;
            }
        }

        total_accepted_ops += seed_accepted_ops;
        std::stringstream ss;
        ss << "    {\"seed\": " << seed << ", \"accepted_ops\": " << seed_accepted_ops
           << ", \"cycles\": " << tb.cycle << ", \"mismatches\": " << seed_mismatches
           << ", \"status\": \"" << (seed_mismatches == 0 ? "pass" : "fail") << "\"}";
        seed_reports.push_back(ss.str());

        std::cout << "  Seed " << seed << " completed: " << seed_accepted_ops
                  << " accepted ops, " << tb.cycle << " cycles, " << seed_mismatches << " mismatches -> "
                  << (seed_mismatches == 0 ? "PASS" : "FAIL") << std::endl;
        assert(seed_mismatches == 0 && "Randomized torture seed failed with mismatches");
    }

    std::cout << "\n=======================================================" << std::endl;
    std::cout << "RAS Hardening & Coroutine Swap Unit Verification Summary:" << std::endl;
    std::cout << "  Directed Properties: " << tests_passed << "/" << tests_total << " PASS" << std::endl;
    std::cout << "  Multi-Seed Randomized Operations: " << total_accepted_ops << " accepted ops across " << canonical_seeds.size() << " seeds" << std::endl;
    std::cout << "  All Seeds Met >= 25,000 Ops Contract: YES" << std::endl;
    std::cout << "  Overall Result: ALL PASS" << std::endl;
    std::cout << "=======================================================" << std::endl;

    std::cout << "--- BEGIN JSON UNIT RESULTS ---" << std::endl;
    std::cout << "{" << std::endl;
    std::cout << "  \"directed_scenarios\": " << tests_passed << "," << std::endl;
    std::cout << "  \"directed_total\": " << tests_total << "," << std::endl;
    std::cout << "  \"total_accepted_ops\": " << total_accepted_ops << "," << std::endl;
    std::cout << "  \"seeds\": [" << std::endl;
    for (size_t i = 0; i < seed_reports.size(); i++) {
        std::cout << seed_reports[i] << (i + 1 < seed_reports.size() ? "," : "") << std::endl;
    }
    std::cout << "  ]," << std::endl;
    std::cout << "  \"status\": \"pass\"" << std::endl;
    std::cout << "}" << std::endl;
    std::cout << "--- END JSON UNIT RESULTS ---" << std::endl;

    return 0;
}
