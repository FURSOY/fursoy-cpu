// =============================================================================
// Fursoy Slice-1 Milestone 5 Phase B2: Fetch Queue (FQ16) Unit Verification TB
// =============================================================================
// Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.2
//
// Verification Scope:
// 1. Fill all 16 entries and confirm full behavior (count=16, full=1, free=0, empty=0).
// 2. Reject/backpressure 17th entry when full (push_ack=0, zero corruption/loss).
// 3. Reject partial overflow at count=15 (accepts 1, rejects 2nd).
// 4. Drain entries in order (strict FIFO order check across all 16 entries).
// 5. Modulo-16 pointer wraparound & slot reuse across 15->0 boundary.
// 6. Simultaneous enqueue/dequeue when full (2 push + 2 pop maintains count=16).
// 7. Simultaneous enqueue/dequeue at count=15 with 1 pop accepting 2 pushes (P2-1).
// 8. Simultaneous enqueue/dequeue mid-occupancy (count=8).
// 9. Flush/redirect while partially full (count=7 -> count=0 in 1 cycle).
// 10. Flush/redirect while full (count=16 -> count=0 in 1 cycle).
// 11. Sustained backpressure for 50+ cycles without loss, duplication, or reordering.
// 12. Randomized torture testing (50,000 ops) against independent std::deque model.
// =============================================================================

#include <iostream>
#include <iomanip>
#include <deque>
#include <cstdint>
#include <cassert>
#include <memory>
#include <random>

#include "Vfursoy_s1_fetch_queue.h"
#include "verilated.h"

class FQTB {
public:
    std::unique_ptr<Vfursoy_s1_fetch_queue> dut;
    uint64_t cycle_count;

    FQTB() : dut(std::make_unique<Vfursoy_s1_fetch_queue>()), cycle_count(0) {
        dut->clk_i = 0;
        dut->rst_i = 0;
        dut->flush_i = 0;
        dut->push0_valid_i = 0;
        dut->push1_valid_i = 0;
        dut->pop0_i = 0;
        dut->pop1_i = 0;
        for (int i = 0; i < 41; i++) {
            dut->push0_entry_i[i] = 0;
            dut->push1_entry_i[i] = 0;
        }
        dut->eval();
    }

    void reset() {
        dut->rst_i = 1;
        dut->flush_i = 0;
        dut->push0_valid_i = 0;
        dut->push1_valid_i = 0;
        dut->pop0_i = 0;
        dut->pop1_i = 0;
        step();
        step();
        dut->rst_i = 0;
        step();
    }

    void step() {
        dut->clk_i = 0;
        dut->eval();
        dut->clk_i = 1;
        dut->eval();
        cycle_count++;
    }

    void set_push0(uint32_t id) {
        dut->push0_valid_i = 1;
        dut->push0_entry_i[0] = id;
    }

    void set_push1(uint32_t id) {
        dut->push1_valid_i = 1;
        dut->push1_entry_i[0] = id;
    }

    void clear_pushes() {
        dut->push0_valid_i = 0;
        dut->push1_valid_i = 0;
    }

    void set_pops(bool p0, bool p1) {
        dut->pop0_i = p0 ? 1 : 0;
        dut->pop1_i = p1 ? 1 : 0;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "=============================================================================\n";
    std::cout << "Fursoy Slice-1 Milestone 5 Phase B2: Fetch Queue (FQ16) Unit Verification\n";
    std::cout << "Reference: docs/architecture/slice1-m5-performance-v1.md Section 7.2\n";
    std::cout << "=============================================================================\n";

    FQTB tb;

    // Test 1: Reset and Initial State
    tb.reset();
    assert(tb.dut->count_o == 0);
    assert(tb.dut->free_count_o == 16);
    assert(tb.dut->empty_o == 1);
    assert(tb.dut->full_o == 0);
    assert(tb.dut->pop0_valid_o == 0);
    assert(tb.dut->pop1_valid_o == 0);
    std::cout << "  [PASS] Test 01: Reset and initial state (count=0, free=16, empty=1, full=0)\n";

    // Test 2: Fill all 16 entries and confirm full behavior
    tb.reset();
    uint32_t cur_id = 100;
    for (int pair = 0; pair < 8; pair++) {
        assert(tb.dut->count_o == pair * 2);
        assert(tb.dut->free_count_o == 16 - pair * 2);
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.set_pops(false, false);
        tb.dut->eval();
        assert(tb.dut->push_ack_o == 2);
        tb.step();
    }
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 16);
    assert(tb.dut->free_count_o == 0);
    assert(tb.dut->full_o == 1);
    assert(tb.dut->empty_o == 0);
    assert(tb.dut->pop0_valid_o == 1);
    assert(tb.dut->pop1_valid_o == 1);
    std::cout << "  [PASS] Test 02: Fill all 16 entries in pairs (count=16, free=0, full=1, empty=0)\n";

    // Test 3: Reject / backpressure 17th entry when full
    tb.set_push0(999);
    tb.set_push1(1000);
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->push_ack_o == 0); // Both rejected
    tb.step();
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 16);
    assert(tb.dut->full_o == 1);
    std::cout << "  [PASS] Test 03: Reject 17th and 18th push when full (push_ack=0, count=16)\n";

    // Test 4: Drain all 16 entries in order
    uint32_t expected_id = 100;
    for (int pair = 0; pair < 8; pair++) {
        tb.dut->eval();
        assert(tb.dut->pop0_valid_o == 1);
        assert(tb.dut->pop1_valid_o == 1);
        assert(tb.dut->pop0_entry_o[0] == expected_id);
        assert(tb.dut->pop1_entry_o[0] == expected_id + 1);
        expected_id += 2;
        tb.set_pops(true, true);
        tb.step();
    }
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->count_o == 0);
    assert(tb.dut->empty_o == 1);
    assert(tb.dut->free_count_o == 16);
    assert(tb.dut->full_o == 0);
    std::cout << "  [PASS] Test 04: Drain all 16 entries in pairs in exact FIFO order\n";

    // Test 5: Reject partial overflow at count=15
    tb.reset();
    cur_id = 200;
    // Push 14 entries in 7 pairs
    for (int p = 0; p < 7; p++) {
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.step();
    }
    // Push 1 entry to reach count=15
    tb.dut->push0_valid_i = 1;
    tb.dut->push0_entry_i[0] = cur_id++;
    tb.dut->push1_valid_i = 0;
    tb.step();
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 15);
    assert(tb.dut->free_count_o == 1);
    assert(tb.dut->full_o == 0);

    // Offer 2 pushes with 0 pops
    tb.set_push0(cur_id);
    tb.set_push1(cur_id + 1);
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->push_ack_o == 1); // Only push0 accepted, push1 rejected!
    tb.step();
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 16);
    assert(tb.dut->full_o == 1);
    std::cout << "  [PASS] Test 05: Partial overflow at count=15 (accepts 1 of 2 pushes, full=1)\n";

    // Test 6: Modulo-16 Pointer Wraparound and Slot Reuse
    tb.reset();
    cur_id = 300;
    expected_id = 300;
    // Push 4, then pop 2 and push 2 each cycle for 64 cycles
    tb.set_push0(cur_id++);
    tb.set_push1(cur_id++);
    tb.step();
    tb.set_push0(cur_id++);
    tb.set_push1(cur_id++);
    tb.step();
    for (int cyc = 0; cyc < 64; cyc++) {
        tb.dut->eval();
        assert(tb.dut->pop0_valid_o == 1);
        assert(tb.dut->pop1_valid_o == 1);
        assert(tb.dut->pop0_entry_o[0] == expected_id++);
        assert(tb.dut->pop1_entry_o[0] == expected_id++);
        tb.set_pops(true, true);
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.step();
        assert(tb.dut->count_o == 4);
    }
    tb.clear_pushes();
    tb.set_pops(false, false);
    tb.step();
    // Drain remaining 4
    for (int i = 0; i < 2; i++) {
        tb.dut->eval();
        assert(tb.dut->pop0_entry_o[0] == expected_id++);
        assert(tb.dut->pop1_entry_o[0] == expected_id++);
        tb.set_pops(true, true);
        tb.step();
    }
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->count_o == 0);
    assert(tb.dut->empty_o == 1);
    std::cout << "  [PASS] Test 06: Modulo-16 pointer wraparound & slot reuse across 128 items\n";

    // Test 7: Simultaneous Enqueue / Dequeue when completely full
    tb.reset();
    cur_id = 500;
    expected_id = 500;
    // Fill to 16
    for (int p = 0; p < 8; p++) {
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.step();
    }
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 16);
    assert(tb.dut->full_o == 1);

    // Run 32 cycles of simultaneous 2-push + 2-pop while FULL
    for (int cyc = 0; cyc < 32; cyc++) {
        tb.dut->eval();
        assert(tb.dut->pop0_valid_o == 1);
        assert(tb.dut->pop1_valid_o == 1);
        assert(tb.dut->pop0_entry_o[0] == expected_id++);
        assert(tb.dut->pop1_entry_o[0] == expected_id++);
        tb.set_pops(true, true);
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.dut->eval();
        assert(tb.dut->push_ack_o == 2); // 2 pops frees 2 slots in same cycle!
        tb.step();
        assert(tb.dut->count_o == 16);
        assert(tb.dut->full_o == 1);
    }
    tb.clear_pushes();
    tb.set_pops(false, false);
    tb.step();
    std::cout << "  [PASS] Test 07: Simultaneous 2-push + 2-pop when FULL (count stays 16, ack=2)\n";

    // Test 8: Dual-Push Admission at count=15 with 1 Pop (Section 7.2 / P2-1 Resolution)
    tb.reset();
    cur_id = 700;
    expected_id = 700;
    for (int p = 0; p < 7; p++) {
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.step();
    }
    tb.dut->push0_valid_i = 1;
    tb.dut->push0_entry_i[0] = cur_id++;
    tb.dut->push1_valid_i = 0;
    tb.step();
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 15);
    assert(tb.dut->full_o == 0);

    // At count=15, 1 pop occurs simultaneously with 2 pushes
    tb.set_pops(true, false); // 1 pop
    tb.set_push0(cur_id++);
    tb.set_push1(cur_id++);
    tb.dut->eval();
    assert(tb.dut->push_ack_o == 2); // MUST accept 2 pushes since 1 pop occurs!
    tb.step();
    tb.clear_pushes();
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->count_o == 16); // 15 - 1 + 2 = 16
    assert(tb.dut->full_o == 1);
    std::cout << "  [PASS] Test 08: Dual-push admission at count=15 with 1 pop (ack=2, count=16)\n";

    // Test 9: Simultaneous operations mid-occupancy (count=8)
    tb.reset();
    cur_id = 800;
    for (int p = 0; p < 4; p++) {
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.step();
    }
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 8);

    // 2 pushes + 1 pop -> count becomes 9
    tb.set_pops(true, false);
    tb.set_push0(cur_id++);
    tb.set_push1(cur_id++);
    tb.dut->eval();
    assert(tb.dut->push_ack_o == 2);
    tb.step();
    tb.clear_pushes();
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->count_o == 9);

    // 1 push + 2 pops -> count becomes 8
    tb.set_pops(true, true);
    tb.dut->push0_valid_i = 1;
    tb.dut->push0_entry_i[0] = cur_id++;
    tb.dut->push1_valid_i = 0;
    tb.dut->eval();
    assert(tb.dut->push_ack_o == 1);
    tb.step();
    tb.clear_pushes();
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->count_o == 8);
    std::cout << "  [PASS] Test 09: Simultaneous enqueue/dequeue mid-occupancy (count=8->9->8)\n";

    // Test 10: Flush while partially full
    tb.reset();
    for (int p = 0; p < 3; p++) {
        tb.set_push0(1); tb.set_push1(2); tb.step();
    }
    tb.dut->push0_valid_i = 1; tb.dut->push0_entry_i[0] = 3; tb.dut->push1_valid_i = 0; tb.step();
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 7);
    tb.dut->flush_i = 1;
    tb.step();
    tb.dut->flush_i = 0;
    tb.dut->eval();
    assert(tb.dut->count_o == 0);
    assert(tb.dut->empty_o == 1);
    assert(tb.dut->free_count_o == 16);
    assert(tb.dut->full_o == 0);
    assert(tb.dut->pop0_valid_o == 0);
    assert(tb.dut->pop1_valid_o == 0);
    std::cout << "  [PASS] Test 10: Single-cycle flush while partially full (count=7 -> 0)\n";

    // Test 11: Flush while completely full
    tb.reset();
    for (int p = 0; p < 8; p++) {
        tb.set_push0(1); tb.set_push1(2); tb.step();
    }
    tb.clear_pushes();
    tb.dut->eval();
    assert(tb.dut->count_o == 16);
    assert(tb.dut->full_o == 1);
    tb.dut->flush_i = 1;
    tb.step();
    tb.dut->flush_i = 0;
    tb.dut->eval();
    assert(tb.dut->count_o == 0);
    assert(tb.dut->empty_o == 1);
    assert(tb.dut->free_count_o == 16);
    assert(tb.dut->full_o == 0);
    std::cout << "  [PASS] Test 11: Single-cycle flush while completely full (count=16 -> 0)\n";

    // Test 12: Sustained backpressure without loss or reordering
    tb.reset();
    cur_id = 900;
    expected_id = 900;
    for (int p = 0; p < 8; p++) {
        tb.set_push0(cur_id++);
        tb.set_push1(cur_id++);
        tb.step();
    }
    // Sustain backpressure for 50 cycles
    for (int cyc = 0; cyc < 50; cyc++) {
        tb.set_push0(9999);
        tb.set_push1(9999);
        tb.set_pops(false, false);
        tb.dut->eval();
        assert(tb.dut->push_ack_o == 0);
        assert(tb.dut->count_o == 16);
        assert(tb.dut->full_o == 1);
        tb.step();
    }
    tb.clear_pushes();
    // Now drain and verify all 16
    for (int p = 0; p < 8; p++) {
        tb.dut->eval();
        assert(tb.dut->pop0_entry_o[0] == expected_id++);
        assert(tb.dut->pop1_entry_o[0] == expected_id++);
        tb.set_pops(true, true);
        tb.step();
    }
    tb.set_pops(false, false);
    tb.dut->eval();
    assert(tb.dut->count_o == 0);
    assert(tb.dut->empty_o == 1);
    std::cout << "  [PASS] Test 12: Sustained backpressure for 50 cycles with zero corruption\n";

    // Test 13: Randomized Stress Testing against Independent std::deque Reference Model (50,000 ops)
    tb.reset();
    std::deque<uint32_t> ref_queue;
    std::mt19937 rng(42);
    cur_id = 1;
    uint64_t accepted_pushes = 0;
    uint64_t actual_pops = 0;

    for (int op = 0; op < 50000; op++) {
        // Decide flush (0.5% probability)
        bool do_flush = (rng() % 200) == 0;
        if (do_flush) {
            tb.dut->flush_i = 1;
            tb.clear_pushes();
            tb.set_pops(false, false);
            tb.step();
            tb.dut->flush_i = 0;
            ref_queue.clear();
            continue;
        }

        // Generate pop request
        int pop_req = rng() % 3; // 0, 1, or 2 pops
        bool req_pop0 = (pop_req >= 1);
        bool req_pop1 = (pop_req == 2);

        // Generate push request
        int push_req = rng() % 3; // 0, 1, or 2 pushes
        bool req_push0 = (push_req >= 1);
        bool req_push1 = (push_req == 2);
        uint32_t p0_id = cur_id++;
        uint32_t p1_id = cur_id++;

        tb.dut->pop0_i = req_pop0 ? 1 : 0;
        tb.dut->pop1_i = req_pop1 ? 1 : 0;
        tb.dut->push0_valid_i = req_push0 ? 1 : 0;
        tb.dut->push0_entry_i[0] = p0_id;
        tb.dut->push1_valid_i = req_push1 ? 1 : 0;
        tb.dut->push1_entry_i[0] = p1_id;

        tb.dut->eval();

        // Check reference model outputs before clock edge
        assert(tb.dut->count_o == (uint32_t)ref_queue.size());
        assert(tb.dut->empty_o == (ref_queue.size() == 0 ? 1 : 0));
        assert(tb.dut->full_o == (ref_queue.size() == 16 ? 1 : 0));
        assert(tb.dut->free_count_o == (uint32_t)(16 - ref_queue.size()));

        if (ref_queue.size() >= 1) {
            assert(tb.dut->pop0_valid_o == 1);
            assert(tb.dut->pop0_entry_o[0] == ref_queue[0]);
        } else {
            assert(tb.dut->pop0_valid_o == 0);
        }

        if (ref_queue.size() >= 2) {
            assert(tb.dut->pop1_valid_o == 1);
            assert(tb.dut->pop1_entry_o[0] == ref_queue[1]);
        } else {
            assert(tb.dut->pop1_valid_o == 0);
        }

        // Execute pops in reference model
        int ref_pops = 0;
        if (req_pop0 && ref_queue.size() >= 1) {
            if (req_pop1 && ref_queue.size() >= 2) {
                ref_pops = 2;
                ref_queue.pop_front();
                ref_queue.pop_front();
            } else {
                ref_pops = 1;
                ref_queue.pop_front();
            }
        }
        actual_pops += ref_pops;

        // Check push acceptance
        uint8_t ack = tb.dut->push_ack_o;
        if (ack >= 1) {
            ref_queue.push_back(p0_id);
            accepted_pushes++;
        }
        if (ack == 2) {
            ref_queue.push_back(p1_id);
            accepted_pushes++;
        }
        assert(ref_queue.size() <= 16);

        tb.step();
    }

    std::cout << "  [PASS] Test 13: Randomized torture against golden reference (50,000 ops, "
              << accepted_pushes << " pushes, " << actual_pops << " pops, 0 mismatches)\n";

    std::cout << "\nALL 13 FQ16 UNIT VERIFICATION SCENARIOS PASSED PERFECTLY!\n";
    return 0;
}
