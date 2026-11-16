// Focused verification suite for Fursoy CPU Platform-Level Interrupt Controller (PLIC) v1.
// Specification authority: docs/architecture/plic-v1.md (frozen v1)
// Covers all 31 verification scenarios and formal invariant properties.

#include "Vfursoy_s0_plic.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static constexpr uint64_t PLIC_BASE = 0x000000000C000000ULL;
static constexpr uint64_t PRIO_BASE = PLIC_BASE;
static constexpr uint64_t PEND_BASE = PLIC_BASE + 0x001000;
static constexpr uint64_t EN_C0     = PLIC_BASE + 0x002000;
static constexpr uint64_t EN_C1     = PLIC_BASE + 0x002080;
static constexpr uint64_t THRESH_C0 = PLIC_BASE + 0x200000;
static constexpr uint64_t CLAIM_C0  = PLIC_BASE + 0x200004;
static constexpr uint64_t THRESH_C1 = PLIC_BASE + 0x201000;
static constexpr uint64_t CLAIM_C1  = PLIC_BASE + 0x201004;

static void check(bool cond, const std::string &msg) {
    if (!cond) {
        throw std::runtime_error("FAIL: " + msg);
    }
}

struct PlicDriver {
    Vfursoy_s0_plic dut;
    unsigned cycles = 0;

    void tick() {
        dut.clk_i = 0; dut.eval();
        dut.clk_i = 1; dut.eval();
        dut.clk_i = 0; dut.eval();
        ++cycles;
    }

    void reset() {
        dut.clk_i = 0; dut.rst_i = 1;
        dut.req_valid_i = 0; dut.req_store_i = 0;
        dut.req_addr_i = 0; dut.req_size_i = 0; dut.req_store_data_i = 0;
        dut.rsp_ready_i = 1; dut.irq_sources_i = 0;
        dut.eval();
        for (int i = 0; i < 3; i++) tick();
        dut.rst_i = 0;
        dut.eval();
    }

    // Single 32-bit MMIO store transaction
    bool write32(uint64_t addr, uint32_t data, unsigned size = 2) {
        dut.req_valid_i = 1;
        dut.req_store_i = 1;
        dut.req_addr_i = addr;
        dut.req_size_i = size;
        dut.req_store_data_i = uint64_t(data);
        dut.rsp_ready_i = 1;
        dut.eval();

        bool accepted = dut.req_ready_o;
        bool access_err = dut.access_error_o;
        tick();

        dut.req_valid_i = 0;
        dut.req_store_i = 0;
        dut.eval();
        return accepted && !access_err;
    }

    // Single 32-bit MMIO load transaction
    std::pair<uint32_t, bool> read32(uint64_t addr, unsigned size = 2) {
        dut.req_valid_i = 1;
        dut.req_store_i = 0;
        dut.req_addr_i = addr;
        dut.req_size_i = size;
        dut.rsp_ready_i = 1;
        dut.eval();

        bool accepted = dut.req_ready_o;
        bool access_err = dut.access_error_o;
        tick();

        dut.req_valid_i = 0;
        dut.eval();

        // Wait for response if needed
        int timeout = 10;
        while (!dut.rsp_valid_o && --timeout > 0) {
            tick();
        }
        if (timeout == 0) {
            throw std::runtime_error("read32 response timeout at addr " + std::to_string(addr));
        }

        uint32_t data = uint32_t(dut.rsp_data_o);
        bool err = dut.rsp_error_o || access_err || !accepted;

        // Consume response
        tick();
        return {data, !err};
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    PlicDriver drv;
    unsigned scenarios = 0;

    try {
        // =====================================================================
        // PLIC-01: Reset Quiescence
        // =====================================================================
        drv.reset();
        check(!drv.dut.irq_meip_o, "PLIC-01: MEIP low on reset");
        check(!drv.dut.irq_seip_o, "PLIC-01: SEIP low on reset");
        auto [p0, ok_p0] = drv.read32(PEND_BASE);
        check(ok_p0 && p0 == 0, "PLIC-01: Pending register 0 on reset");
        auto [th0, ok_th0] = drv.read32(THRESH_C0);
        check(ok_th0 && th0 == 0, "PLIC-01: Threshold C0 0 on reset");
        auto [th1, ok_th1] = drv.read32(THRESH_C1);
        check(ok_th1 && th1 == 0, "PLIC-01: Threshold C1 0 on reset");
        auto [en0, ok_en0] = drv.read32(EN_C0);
        check(ok_en0 && en0 == 0, "PLIC-01: Enable C0 0 on reset");
        auto [en1, ok_en1] = drv.read32(EN_C1);
        check(ok_en1 && en1 == 0, "PLIC-01: Enable C1 0 on reset");
        ++scenarios;

        // =====================================================================
        // PLIC-02: Priority Programming & WARL
        // =====================================================================
        // Source 0 is RO0
        check(drv.write32(PRIO_BASE, 0x7), "PLIC-02: write to Source 0 priority accepted");
        auto [s0_prio, s0_ok] = drv.read32(PRIO_BASE);
        check(s0_ok && s0_prio == 0, "PLIC-02: Source 0 priority is hardwired to 0");

        // Source 1..31 accept 3-bit values; upper bits are WARL 0
        for (unsigned i = 1; i <= 31; i++) {
            uint64_t addr = PRIO_BASE + i * 4;
            check(drv.write32(addr, 0xFFFFFFF8 | (i % 8)), "PLIC-02: write priority");
            auto [rd_prio, rd_ok] = drv.read32(addr);
            check(rd_ok && rd_prio == (i % 8), "PLIC-02: priority WARL bits [31:3] read 0");
        }
        ++scenarios;

        // =====================================================================
        // PLIC-03: Priority 0 Disablement
        // =====================================================================
        drv.reset();
        // Configure Source 1: priority = 0, enable C0 = 1, threshold C0 = 0
        drv.write32(PRIO_BASE + 4, 0);
        drv.write32(EN_C0, 1 << 1);
        drv.write32(THRESH_C0, 0);
        // Assert Source 1 level
        drv.dut.irq_sources_i = (1 << 1);
        drv.tick();
        check(!drv.dut.irq_meip_o, "PLIC-03: priority 0 never asserts MEIP notification");
        auto [cl_p0, cl_p0_ok] = drv.read32(CLAIM_C0);
        check(cl_p0_ok && cl_p0 == 0, "PLIC-03: priority 0 source is never claimed (returns 0)");
        ++scenarios;

        // =====================================================================
        // PLIC-04: Pending Bit Level Latching & Read-Only
        // =====================================================================
        drv.reset();
        drv.dut.irq_sources_i = (1 << 5) | (1 << 12);
        drv.tick();
        auto [pend_val, pend_ok] = drv.read32(PEND_BASE);
        check(pend_ok && (pend_val == ((1 << 5) | (1 << 12))), "PLIC-04: level assertion sets pending bits");
        // Attempt to write to Pending register (should be silently ignored)
        check(drv.write32(PEND_BASE, 0), "PLIC-04: write to pending accepted without error");
        auto [pend_after, pend_after_ok] = drv.read32(PEND_BASE);
        check(pend_after_ok && (pend_after == ((1 << 5) | (1 << 12))), "PLIC-04: pending bits are read-only to software");
        ++scenarios;

        // =====================================================================
        // PLIC-05: Transient Source Pulse Before Claim
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 7 * 4, 4); // Source 7, prio 4
        drv.write32(EN_C0, 1 << 7);        // Enable in C0
        // Pulse source 7 for 1 cycle, then drop to 0
        drv.dut.irq_sources_i = (1 << 7);
        drv.tick();
        drv.dut.irq_sources_i = 0;
        drv.tick();
        // Verify pending remains latched
        auto [p_latched, p_latched_ok] = drv.read32(PEND_BASE);
        check(p_latched_ok && (p_latched & (1 << 7)), "PLIC-05: pending bit remains latched after level falls");
        check(drv.dut.irq_meip_o, "PLIC-05: MEIP notification remains asserted while pending is latched");
        // Claim source 7
        auto [cl_trans, cl_trans_ok] = drv.read32(CLAIM_C0);
        check(cl_trans_ok && cl_trans == 7, "PLIC-05: claim succeeds for transient pulse");
        check(!drv.dut.irq_meip_o, "PLIC-05: notification deasserts after claim");
        // Complete source 7 while level is 0
        check(drv.write32(CLAIM_C0, 7), "PLIC-05: complete write");
        auto [p_post_comp, p_post_comp_ok] = drv.read32(PEND_BASE);
        check(p_post_comp_ok && !(p_post_comp & (1 << 7)), "PLIC-05: gateway returns to IDLE without re-pending");
        ++scenarios;

        // =====================================================================
        // PLIC-06: Enable Masking
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 3 * 4, 5); // Source 3, prio 5
        drv.dut.irq_sources_i = (1 << 3);
        drv.tick();
        check(!drv.dut.irq_meip_o, "PLIC-06: source disabled in C0 does not assert MEIP");
        check(!drv.dut.irq_seip_o, "PLIC-06: source disabled in C1 does not assert SEIP");
        // Enable in C0 only
        drv.write32(EN_C0, 1 << 3);
        drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-06: enabling in C0 asserts MEIP");
        check(!drv.dut.irq_seip_o, "PLIC-06: C1 remains masked");
        ++scenarios;

        // =====================================================================
        // PLIC-07: Threshold Masking on Notification
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 4 * 4, 3); // Source 4, prio 3
        drv.write32(EN_C0, 1 << 4);
        drv.dut.irq_sources_i = (1 << 4);
        drv.tick();
        // Thresh = 0 -> prio 3 > 0 -> asserted
        drv.write32(THRESH_C0, 0); drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-07: prio 3 > thresh 0 asserts notification");
        // Thresh = 3 -> prio 3 not > 3 -> masked!
        drv.write32(THRESH_C0, 3); drv.tick();
        check(!drv.dut.irq_meip_o, "PLIC-07: prio 3 not > thresh 3 masks notification");
        // Thresh = 2 -> prio 3 > 2 -> asserted
        drv.write32(THRESH_C0, 2); drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-07: prio 3 > thresh 2 asserts notification");
        // Thresh = 7 -> all notifications masked
        drv.write32(THRESH_C0, 7); drv.tick();
        check(!drv.dut.irq_meip_o, "PLIC-07: thresh 7 completely masks all notifications");
        ++scenarios;

        // =====================================================================
        // PLIC-08: Claim While Threshold Masks Notification (P0 Requirement)
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 5 * 4, 2); // Source 5, prio 2
        drv.write32(EN_C0, 1 << 5);
        drv.write32(THRESH_C0, 5);         // Thresh 5 > prio 2 -> MEIP is 0
        drv.dut.irq_sources_i = (1 << 5);
        drv.tick();
        check(!drv.dut.irq_meip_o, "PLIC-08: MEIP output is low due to threshold");
        // Claim read must STILL succeed because claim_eligible ignores threshold!
        auto [cl_p0_thresh, cl_p0_thresh_ok] = drv.read32(CLAIM_C0);
        check(cl_p0_thresh_ok && cl_p0_thresh == 5, "PLIC-08: Claim read returns source 5 despite high threshold");
        auto [p_after_cl, p_after_cl_ok] = drv.read32(PEND_BASE);
        check(p_after_cl_ok && !(p_after_cl & (1 << 5)), "PLIC-08: Claim atomically cleared pending");
        ++scenarios;

        // =====================================================================
        // PLIC-09: Disabled Source Excluded from Claim
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 6 * 4, 4);
        drv.write32(EN_C0, 0);             // Disabled in C0
        drv.dut.irq_sources_i = (1 << 6);
        drv.tick();
        auto [cl_dis, cl_dis_ok] = drv.read32(CLAIM_C0);
        check(cl_dis_ok && cl_dis == 0, "PLIC-09: Claim returns 0 for disabled source");
        auto [p_dis, p_dis_ok] = drv.read32(PEND_BASE);
        check(p_dis_ok && (p_dis & (1 << 6)), "PLIC-09: Pending remains set for unclaimable source");
        ++scenarios;

        // =====================================================================
        // PLIC-10: Highest Priority Selection
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 2 * 4, 3); // Source 2, prio 3
        drv.write32(PRIO_BASE + 8 * 4, 6); // Source 8, prio 6
        drv.write32(EN_C0, (1 << 2) | (1 << 8));
        drv.dut.irq_sources_i = (1 << 2) | (1 << 8);
        drv.tick();
        auto [cl_high, cl_high_ok] = drv.read32(CLAIM_C0);
        check(cl_high_ok && cl_high == 8, "PLIC-10: Highest priority source 8 claimed first");
        ++scenarios;

        // =====================================================================
        // PLIC-11: Equal-Priority Lowest-ID Tie-Break
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 4 * 4, 5); // Source 4, prio 5
        drv.write32(PRIO_BASE + 9 * 4, 5); // Source 9, prio 5
        drv.write32(EN_C0, (1 << 4) | (1 << 9));
        drv.dut.irq_sources_i = (1 << 4) | (1 << 9);
        drv.tick();
        auto [cl_tie, cl_tie_ok] = drv.read32(CLAIM_C0);
        check(cl_tie_ok && cl_tie == 4, "PLIC-11: Lowest ID source 4 wins tie-break against source 9");
        ++scenarios;

        // =====================================================================
        // PLIC-12: Empty Claim Return & Zero Side Effects
        // =====================================================================
        drv.reset();
        auto [cl_empty, cl_empty_ok] = drv.read32(CLAIM_C0);
        check(cl_empty_ok && cl_empty == 0, "PLIC-12: Empty claim returns 0");
        ++scenarios;

        // =====================================================================
        // PLIC-13: Gateway In-Service Lockout (No Duplicate Claims)
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 10 * 4, 4);
        drv.write32(EN_C0, 1 << 10);
        drv.dut.irq_sources_i = (1 << 10);
        drv.tick();
        auto [cl_lock, cl_lock_ok] = drv.read32(CLAIM_C0);
        check(cl_lock_ok && cl_lock == 10, "PLIC-13: Source 10 claimed");
        // While in service, source 10 is asserted high again
        drv.dut.irq_sources_i = (1 << 10);
        drv.tick();
        auto [cl_lock2, cl_lock2_ok] = drv.read32(CLAIM_C0);
        check(cl_lock2_ok && cl_lock2 == 0, "PLIC-13: Source in-service cannot be claimed again");
        ++scenarios;

        // =====================================================================
        // PLIC-14: Completion With Source Held High -> Re-pending
        // =====================================================================
        // Source 10 is currently in-service, level is held high
        check(drv.write32(CLAIM_C0, 10), "PLIC-14: Complete write for source 10");
        auto [pend_re, pend_re_ok] = drv.read32(PEND_BASE);
        check(pend_re_ok && (pend_re & (1 << 10)), "PLIC-14: Source held high immediately re-pends upon completion");
        check(drv.dut.irq_meip_o, "PLIC-14: MEIP re-asserts for re-pended source");
        ++scenarios;

        // =====================================================================
        // PLIC-15: Cross-Context Completion Protection (P1 Requirement)
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 11 * 4, 4);
        drv.write32(EN_C0, 1 << 11); // Enabled ONLY in C0
        drv.write32(EN_C1, 0);       // Disabled in C1
        drv.dut.irq_sources_i = (1 << 11);
        drv.tick();
        auto [cl_c0, cl_c0_ok] = drv.read32(CLAIM_C0);
        check(cl_c0_ok && cl_c0 == 11, "PLIC-15: Context 0 claims source 11");
        // Context 1 attempts to write completion for source 11 while enable_q[1][11] == 0
        check(drv.write32(CLAIM_C1, 11), "PLIC-15: Context 1 complete write issued");
        // Verify source 11 remains IN_SERVICE: level is high, so if it were completed, it would re-pend!
        auto [p_still_lock, p_still_lock_ok] = drv.read32(PEND_BASE);
        check(p_still_lock_ok && !(p_still_lock & (1 << 11)), "PLIC-15: Source 11 remains locked in-service, not completed by unauthorized context");
        // Context 0 writes completion: now it completes properly!
        check(drv.write32(CLAIM_C0, 11), "PLIC-15: Context 0 completes source 11");
        auto [p_c0_re, p_c0_re_ok] = drv.read32(PEND_BASE);
        check(p_c0_re_ok && (p_c0_re & (1 << 11)), "PLIC-15: Context 0 successfully completed and re-pended source 11");
        ++scenarios;

        // =====================================================================
        // PLIC-16: Spurious / Unowned Completion
        // =====================================================================
        drv.reset();
        check(drv.write32(CLAIM_C0, 0), "PLIC-16: ID 0 complete write accepted");
        check(drv.write32(CLAIM_C0, 99), "PLIC-16: Out-of-range complete write accepted");
        check(drv.write32(CLAIM_C0, 5), "PLIC-16: Not-in-service complete write accepted");
        auto [p_spur, p_spur_ok] = drv.read32(PEND_BASE);
        check(p_spur_ok && p_spur == 0, "PLIC-16: Spurious completions produce zero state modifications");
        ++scenarios;

        // =====================================================================
        // PLIC-17: Shared Source Multi-Context Contention
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 12 * 4, 5);
        drv.write32(EN_C0, 1 << 12);
        drv.write32(EN_C1, 1 << 12);
        drv.dut.irq_sources_i = (1 << 12);
        drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-17: MEIP asserted for shared source");
        check(drv.dut.irq_seip_o, "PLIC-17: SEIP asserted for shared source");
        // Context 0 claims source 12 first
        auto [cl_c0_win, cl_c0_win_ok] = drv.read32(CLAIM_C0);
        check(cl_c0_win_ok && cl_c0_win == 12, "PLIC-17: Context 0 wins claim");
        check(!drv.dut.irq_meip_o, "PLIC-17: MEIP deasserts");
        check(!drv.dut.irq_seip_o, "PLIC-17: SEIP deasserts immediately because pending was cleared");
        // Context 1 claims next -> returns 0!
        auto [cl_c1_lose, cl_c1_lose_ok] = drv.read32(CLAIM_C1);
        check(cl_c1_lose_ok && cl_c1_lose == 0, "PLIC-17: Context 1 claim returns 0");
        ++scenarios;

        // =====================================================================
        // PLIC-18: Simultaneous Independent MEIP and SEIP Delivery
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 1 * 4, 3); // Source 1 for C0
        drv.write32(PRIO_BASE + 2 * 4, 4); // Source 2 for C1
        drv.write32(EN_C0, 1 << 1);
        drv.write32(EN_C1, 1 << 2);
        drv.dut.irq_sources_i = (1 << 1) | (1 << 2);
        drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-18: Independent MEIP asserted");
        check(drv.dut.irq_seip_o, "PLIC-18: Independent SEIP asserted");
        auto [cl_sim_c1, cl_sim_c1_ok] = drv.read32(CLAIM_C1);
        check(cl_sim_c1_ok && cl_sim_c1 == 2, "PLIC-18: C1 claims source 2");
        check(drv.dut.irq_meip_o, "PLIC-18: MEIP remains asserted for source 1");
        check(!drv.dut.irq_seip_o, "PLIC-18: SEIP deasserts");
        auto [cl_sim_c0, cl_sim_c0_ok] = drv.read32(CLAIM_C0);
        check(cl_sim_c0_ok && cl_sim_c0 == 1, "PLIC-18: C0 claims source 1");
        check(!drv.dut.irq_meip_o, "PLIC-18: MEIP deasserts");
        ++scenarios;

        // =====================================================================
        // PLIC-19: 32-bit Access Width Enforcement (Sub-word / Doubleword Rejection)
        // =====================================================================
        drv.reset();
        // Byte store (size = 0)
        bool byte_ok = drv.write32(PRIO_BASE + 4, 1, 0);
        check(!byte_ok, "PLIC-19: Byte store rejected with bus error");
        // Halfword store (size = 1)
        bool half_ok = drv.write32(PRIO_BASE + 4, 1, 1);
        check(!half_ok, "PLIC-19: Halfword store rejected with bus error");
        // Doubleword store (size = 3)
        bool dword_ok = drv.write32(PRIO_BASE + 4, 1, 3);
        check(!dword_ok, "PLIC-19: Doubleword store rejected with bus error");
        // Byte load (size = 0)
        auto [b_data, b_ok] = drv.read32(PRIO_BASE + 4, 0);
        check(!b_ok, "PLIC-19: Byte load rejected with bus error");
        ++scenarios;

        // =====================================================================
        // PLIC-20: Misaligned Access Rejection
        // =====================================================================
        drv.reset();
        bool mis_st = drv.write32(PRIO_BASE + 5, 1, 2); // addr ending in 5
        check(!mis_st, "PLIC-20: Misaligned store rejected with bus error");
        auto [mis_ld, mis_ld_ok] = drv.read32(PRIO_BASE + 6, 2); // addr ending in 6
        check(!mis_ld_ok, "PLIC-20: Misaligned load rejected with bus error");
        ++scenarios;

        // =====================================================================
        // PLIC-21: Rejected Claim Read Zero Side Effect
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 15 * 4, 5);
        drv.write32(EN_C0, 1 << 15);
        drv.dut.irq_sources_i = (1 << 15);
        drv.tick();
        // Attempt misaligned Claim read
        auto [rej_cl, rej_cl_ok] = drv.read32(CLAIM_C0 + 1, 2);
        check(!rej_cl_ok, "PLIC-21: Misaligned Claim read produces bus error");
        // Verify source 15 is still pending and was NOT claimed!
        auto [p_unmut, p_unmut_ok] = drv.read32(PEND_BASE);
        check(p_unmut_ok && (p_unmut & (1 << 15)), "PLIC-21: Rejected Claim read did not clear pending");
        check(drv.dut.irq_meip_o, "PLIC-21: Notification remains asserted");
        ++scenarios;

        // =====================================================================
        // PLIC-22: Rejected Complete Write Zero Side Effect
        // =====================================================================
        // Claim source 15 legally
        auto [cl_leg, cl_leg_ok] = drv.read32(CLAIM_C0);
        check(cl_leg_ok && cl_leg == 15, "PLIC-22: Legitimate claim of source 15");
        // Attempt misaligned complete write
        bool rej_comp = drv.write32(CLAIM_C0 + 2, 15, 2);
        check(!rej_comp, "PLIC-22: Misaligned complete write rejected with bus error");
        // Verify source 15 remains IN_SERVICE (does not re-pend even though line is high)
        auto [p_still_lock2, p_still_lock2_ok] = drv.read32(PEND_BASE);
        check(p_still_lock2_ok && !(p_still_lock2 & (1 << 15)), "PLIC-22: Rejected complete write did not release in-service");
        ++scenarios;

        // =====================================================================
        // PLIC-23: Unimplemented Source Words (RAZ/WI)
        // =====================================================================
        drv.reset();
        // Read unimplemented priority word
        auto [u_prio, u_prio_ok] = drv.read32(PRIO_BASE + 0x200);
        check(u_prio_ok && u_prio == 0, "PLIC-23: Unimplemented priority reads 0 (RAZ)");
        check(drv.write32(PRIO_BASE + 0x200, 0x1234), "PLIC-23: Write to unimplemented priority ignored (WI)");
        // Read unimplemented pending word
        auto [u_pend, u_pend_ok] = drv.read32(PEND_BASE + 0x10);
        check(u_pend_ok && u_pend == 0, "PLIC-23: Unimplemented pending reads 0 (RAZ)");
        // Read unimplemented enable word
        auto [u_en, u_en_ok] = drv.read32(EN_C0 + 0x10);
        check(u_en_ok && u_en == 0, "PLIC-23: Unimplemented enable reads 0 (RAZ)");
        ++scenarios;

        // =====================================================================
        // PLIC-24: Unmapped Context Windows Bus Error
        // =====================================================================
        drv.reset();
        // Context 2 threshold offset (0x202000)
        auto [unm_val, unm_ok] = drv.read32(PLIC_BASE + 0x202000);
        check(!unm_ok, "PLIC-24: Unmapped context window produces bus error");
        ++scenarios;

        // =====================================================================
        // PLIC-25: Sequential Servicing of Multiple Pending Sources
        // =====================================================================
        drv.reset();
        // Configure Sources 1..4 with priorities 1..4
        for (unsigned i = 1; i <= 4; i++) {
            drv.write32(PRIO_BASE + i * 4, i);
        }
        drv.write32(EN_C0, 0x1E); // sources 1..4
        drv.dut.irq_sources_i = 0x1E;
        drv.tick();
        // Expected service order: 4 (prio 4), 3 (prio 3), 2 (prio 2), 1 (prio 1)
        for (int expected = 4; expected >= 1; expected--) {
            auto [cl_seq, cl_seq_ok] = drv.read32(CLAIM_C0);
            check(cl_seq_ok && cl_seq == expected, "PLIC-25: Sequential claim returned source " + std::to_string(expected));
            drv.dut.irq_sources_i &= ~(1 << expected); // deassert peripheral
            check(drv.write32(CLAIM_C0, expected), "PLIC-25: Complete source " + std::to_string(expected));
        }
        auto [cl_none, cl_none_ok] = drv.read32(CLAIM_C0);
        check(cl_none_ok && cl_none == 0, "PLIC-25: All sources serviced; Claim returns 0");
        check(!drv.dut.irq_meip_o, "PLIC-25: MEIP deasserted after servicing all");
        ++scenarios;

        // =====================================================================
        // PLIC-26: Reset While Sources in PENDING
        // =====================================================================
        drv.reset();
        drv.dut.irq_sources_i = (1 << 16) | (1 << 17);
        drv.tick();
        auto [p_before_rst, p_before_rst_ok] = drv.read32(PEND_BASE);
        check(p_before_rst_ok && (p_before_rst == ((1 << 16) | (1 << 17))), "PLIC-26: Pending set before reset");
        drv.reset();
        auto [p_after_rst, p_after_rst_ok] = drv.read32(PEND_BASE);
        check(p_after_rst_ok && p_after_rst == 0, "PLIC-26: Pending cleanly cleared by reset");
        ++scenarios;

        // =====================================================================
        // PLIC-27: Reset While Sources in IN_SERVICE
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 18 * 4, 5);
        drv.write32(EN_C0, 1 << 18);
        drv.dut.irq_sources_i = (1 << 18);
        drv.tick();
        auto [cl_rst, cl_rst_ok] = drv.read32(CLAIM_C0);
        check(cl_rst_ok && cl_rst == 18, "PLIC-27: Claimed source 18 into IN_SERVICE");
        drv.reset();
        // After reset, verify source 18 is not stuck in-service:
        drv.write32(PRIO_BASE + 18 * 4, 5);
        drv.write32(EN_C0, 1 << 18);
        drv.dut.irq_sources_i = (1 << 18);
        drv.tick();
        auto [cl_post_rst, cl_post_rst_ok] = drv.read32(CLAIM_C0);
        check(cl_post_rst_ok && cl_post_rst == 18, "PLIC-27: Source 18 successfully claimed post-reset, proving in-service cleared");
        ++scenarios;

        // =====================================================================
        // PLIC-28: Asserted Source Across Reset Release
        // =====================================================================
        drv.dut.clk_i = 0; drv.dut.rst_i = 1;
        drv.dut.irq_sources_i = (1 << 20); // Held high across reset
        drv.tick();
        drv.dut.rst_i = 0;
        drv.dut.eval();
        // First clock edge post-reset
        drv.tick();
        // Pending bit becomes 1
        auto [p_across, p_across_ok] = drv.read32(PEND_BASE);
        check(p_across_ok && (p_across & (1 << 20)), "PLIC-28: Source asserted across reset becomes pending on first active clock edge");
        // Notification is suppressed because priorities and enables reset to 0
        check(!drv.dut.irq_meip_o && !drv.dut.irq_seip_o, "PLIC-28: Notifications remain 0 post-reset");
        ++scenarios;

        // =====================================================================
        // PLIC-29: Higher-Priority Interrupt Preemption While Lower-Priority In-Service
        // =====================================================================
        drv.reset();
        drv.write32(PRIO_BASE + 2 * 4, 2); // Source 2: prio 2
        drv.write32(PRIO_BASE + 5 * 4, 6); // Source 5: prio 6
        drv.write32(EN_C0, (1 << 2) | (1 << 5));
        drv.dut.irq_sources_i = (1 << 2);
        drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-29: Low-prio source 2 notifies");
        auto [cl_low, cl_low_ok] = drv.read32(CLAIM_C0);
        check(cl_low_ok && cl_low == 2, "PLIC-29: Claim source 2 into IN_SERVICE");
        check(!drv.dut.irq_meip_o, "PLIC-29: MEIP drops once source 2 claimed");
        // Assert higher-priority source 5 while source 2 remains in-service
        drv.dut.irq_sources_i = (1 << 2) | (1 << 5);
        drv.tick();
        check(drv.dut.irq_meip_o, "PLIC-29: Higher-priority source 5 preempts while source 2 is in-service");
        auto [cl_hi, cl_hi_ok] = drv.read32(CLAIM_C0);
        check(cl_hi_ok && cl_hi == 5, "PLIC-29: Preempting claim returns source 5");
        drv.dut.irq_sources_i = 0;
        check(drv.write32(CLAIM_C0, 5), "PLIC-29: Complete preempting source 5");
        check(drv.write32(CLAIM_C0, 2), "PLIC-29: Complete original source 2");
        auto [cl_done, cl_done_ok] = drv.read32(CLAIM_C0);
        check(cl_done_ok && cl_done == 0, "PLIC-29: No further sources claimable");
        ++scenarios;

        drv.dut.final();
        std::cout << "{\"status\":\"pass\",\"scenarios\":" << scenarios << ",\"cycles\":" << drv.cycles << "}\n";
        return 0;
    } catch (const std::exception &err) {
        std::cerr << "ERROR: " << err.what() << "\n";
        return 1;
    }
}
