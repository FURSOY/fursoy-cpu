#include "Vfursoy_s0_l1d.h"
#include "Vfursoy_s0_l1d___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

static void check(bool v, const std::string &m) {
    if (!v) throw std::runtime_error(m);
}

struct L1DSim {
    Vfursoy_s0_l1d d;
    bool rsp_pending = false;
    uint64_t rsp_data = 0;
    bool rsp_error = false;
    int error_beat = -1;

    void defaults() {
        d.req_valid_i = 0; d.req_store_i = 0; d.req_lr_i = 0; d.req_sc_i = 0;
        d.req_amo_i = 0; d.req_amo_op_i = 0; d.req_addr_i = 0; d.req_size_i = 3;
        d.req_unsigned_i = 0; d.req_store_data_i = 0; d.req_rd_i = 10;
        d.req_pc_i = 0x80000008ULL; d.req_insn_i = 0x00013503U;
        d.req_byte_mask_i = 0; d.req_is_sb_drain_i = 0; d.res_invalidate_i = 0;
        d.retire_ack_i = 0; d.redirect_i = 0; d.trans_valid_i = 1;
        d.trans_busy_i = 0; d.trans_pa_i = 0; d.trans_page_fault_i = 0;
        d.trans_pmp_allow_i = 1; d.fence_i_req_i = 0; d.sfence_vma_req_i = 0;
        d.pmp_flush_req_i = 0; d.fence_req_i = 0; d.dmem_req_ready_i = 1;
        d.dmem_req_error_i = 0; d.dmem_rsp_valid_i = 0; d.dmem_rsp_data_i = 0;
        d.dmem_rsp_error_i = 0;
    }

    void reset() {
        defaults(); rsp_pending = false; error_beat = -1;
        d.clk_i = 0; d.rst_i = 1; d.eval();
        d.clk_i = 1; d.eval();
        d.clk_i = 0; d.rst_i = 0; d.eval();
    }

    void tick() {
        d.clk_i = 0;
        d.dmem_rsp_valid_i = rsp_pending;
        d.dmem_rsp_data_i = rsp_data;
        d.dmem_rsp_error_i = rsp_pending && rsp_error;
        d.eval();

        const bool rsp_fire = d.dmem_rsp_valid_i && d.dmem_rsp_ready_o;
        const bool req_fire = d.dmem_req_valid_o && d.dmem_req_ready_i;
        if (rsp_fire) rsp_pending = false;
        if (req_fire && !d.dmem_req_store_o) {
            const int beat = int((uint64_t(d.dmem_req_addr_o) >> 3) & 7);
            rsp_data = 0xa500ULL + unsigned(beat);
            rsp_error = (beat == error_beat);
            rsp_pending = true;
        }

        d.clk_i = 1; d.eval();
        d.clk_i = 0; d.eval();
    }

    void allocate(uint64_t va, uint64_t pa) {
        d.req_valid_i = 1; d.req_addr_i = va; d.trans_pa_i = pa;
        tick();
        d.req_valid_i = 0;
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    try {
        L1DSim s;

        // ER-ADV-27: exercise the real production redirect_i input.
        s.reset();
        const uint64_t pa27 = 0x80016000ULL;
        s.allocate(0x0000000040016000ULL, pa27);
        for (int n = 0; n < 100 && !s.d.er_retire_pending_o; ++n) s.tick();
        check(s.d.er_retire_pending_o, "ER-ADV-27: registered ER result did not become pending");
        s.d.redirect_i = 1;
        s.tick();
        s.d.redirect_i = 0;
        check(!s.d.er_retire_pending_o, "ER-ADV-27: redirect did not cancel pending result");
        check(!s.d.er_load_retired_o, "ER-ADV-27: redirect was incorrectly treated as retirement");
        check(s.d.rootp->fursoy_s0_l1d__DOT__er_load_squashed_q,
              "ER-ADV-27: separate squash state was not recorded");
        s.error_beat = 4;
        for (int n = 0; n < 100 && s.d.rootp->fursoy_s0_l1d__DOT__state_q != 0; ++n) s.tick();
        check(!s.d.fault_valid_o && !s.d.fatal_error_o,
              "ER-ADV-27: post-squash cleanup error became precise or fatal");
        check(s.d.rootp->fursoy_s0_l1d__DOT__refill_poisoned_q,
              "ER-ADV-27: post-squash error did not poison refill");
        check(!s.d.rootp->fursoy_s0_l1d__DOT__er_load_retired_q &&
              !s.d.rootp->fursoy_s0_l1d__DOT__er_load_squashed_q,
              "ER-ADV-27: terminal error cleanup retained stale ER lifecycle state");
        std::cout << "ER-ADV-27 PASS: Real redirect_i Cancels ER Result and Later Error Is Silently Discarded\n";

        // ER-ADV-33: exact critical-beat error, with original VA != translated PA.
        s.reset();
        const uint64_t va33 = 0x0000000040023018ULL;
        const uint64_t pa33 = 0x0000000080023018ULL;
        const unsigned set33 = unsigned((pa33 >> 6) & 63);
        const uint8_t plru_before = s.d.rootp->fursoy_s0_l1d__DOT__plru_q[set33];
        s.error_beat = 3;
        s.allocate(va33, pa33);
        bool saw_fault = false;
        for (int n = 0; n < 100 && !saw_fault; ++n) {
            s.tick();
            saw_fault = s.d.fault_valid_o;
        }
        check(saw_fault, "ER-ADV-33: exact critical-beat error did not produce precise fault");
        check(!s.d.fault_store_o && !s.d.fault_page_o,
              "ER-ADV-33: fault classification is not load-access fault");
        check(uint64_t(s.d.fault_addr_o) == va33,
              "ER-ADV-33: xTVAL source is not original effective VA");
        check(uint64_t(s.d.fault_pc_o) == 0x80000008ULL,
              "ER-ADV-33: precise PC mismatch");
        check(!s.d.retire_valid_o && !s.d.er_retire_pending_o && !s.d.er_load_retired_o,
              "ER-ADV-33: erroneous critical data became architecturally consumable");
        check(!s.d.fatal_error_o && s.d.rootp->fursoy_s0_l1d__DOT__refill_poisoned_q,
              "ER-ADV-33: exact critical error must poison without fatal halt");
        for (int w = 0; w < 4; ++w)
            check(!s.d.rootp->fursoy_s0_l1d__DOT__valid_q[set33][w],
                  "ER-ADV-33: poisoned line was installed");
        check(s.d.rootp->fursoy_s0_l1d__DOT__plru_q[set33] == plru_before,
              "ER-ADV-33: PLRU changed after poisoned refill");
        check(!s.rsp_pending, "ER-ADV-33: accepted error response was not consumed");
        check(!s.d.rootp->fursoy_s0_l1d__DOT__er_load_retired_q &&
              !s.d.rootp->fursoy_s0_l1d__DOT__er_load_squashed_q,
              "ER-ADV-33: terminal precise-error cleanup retained stale ER lifecycle state");
        std::cout << "ER-ADV-33 PASS: Exact Critical-Beat Error Uses Original VA and Publishes No Line Metadata\n";
        std::cout << "UNIT 2 SCENARIOS PASSED SUCCESSFULLY!\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "L1D_ER_UNIT_MISMATCH: " << e.what() << '\n';
        return 1;
    }
}
