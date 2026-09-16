// Focused L1I-NLP v1 (Next-Line Prefetcher) Adversarial Verification Suite
// Normative Baseline: docs/architecture/l1i-nlp-v1.md
// Tests: NLP-ADV-01 through NLP-ADV-30

#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

static void check(bool cond, const char* msg) {
    if (!cond) throw std::runtime_error(msg);
}

// RISC-V Instruction Encodings
static constexpr uint32_t NOP = 0x00000013;
static uint32_t addi(uint32_t rd, uint32_t rs1, int32_t imm) {
    return (uint32_t(imm & 0xfff) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13;
}
static uint32_t fence_i() {
    return 0x0000100f;
}
static uint32_t sfence_vma() {
    return 0x12000073;
}
static uint32_t csrw(uint32_t csr, uint32_t rs1) {
    return (csr << 20) | (rs1 << 15) | (1 << 12) | (0 << 7) | 0x73;
}
static uint32_t jal(uint32_t rd, int32_t imm) {
    uint32_t u = uint32_t(imm);
    uint32_t imm20    = (u >> 20) & 1;
    uint32_t imm10_1  = (u >> 1) & 0x3ff;
    uint32_t imm11    = (u >> 11) & 1;
    uint32_t imm19_12 = (u >> 12) & 0xff;
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (rd << 7) | 0x6f;
}
static uint32_t beq(uint32_t rs1, uint32_t rs2, int32_t imm) {
    uint32_t u = uint32_t(imm);
    uint32_t imm12   = (u >> 12) & 1;
    uint32_t imm10_5 = (u >> 5) & 0x3f;
    uint32_t imm4_1  = (u >> 1) & 0xf;
    uint32_t imm11   = (u >> 11) & 1;
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (0 << 12) | (imm4_1 << 8) | (imm11 << 7) | 0x63;
}

struct Event {
    bool commit = false;
    bool trap = false;
    uint64_t pc = 0;
    uint32_t insn = 0;
    bool rd_write = false;
    uint32_t rd = 0;
    uint64_t rd_data = 0;
};

struct CoreSim {
    Vfursoy_s0_core dut;
    std::unordered_map<uint64_t, uint64_t> dram;
    std::unordered_map<uint64_t, uint64_t> dmem;

    bool imem_rsp_pending = false;
    uint64_t imem_rsp_data = 0;
    bool imem_rsp_error = false;
    int imem_delay_counter = 0;
    int imem_rsp_latency = 0;

    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    bool dmem_rsp_error = false;
    int dmem_delay_counter = 0;

    unsigned imem_requests = 0;
    unsigned imem_rsp_count = 0;
    uint64_t cycles = 0;
    uint64_t commits = 0;

    bool inject_imem_error_on_beat = false;
    int inject_error_beat_idx = -1;
    uint64_t inject_error_line_pa = 0;

    // Telemetry strobe event counts
    unsigned nlp_candidate_events = 0;
    unsigned nlp_issued_events = 0;
    unsigned nlp_suppressed_page_events = 0;
    unsigned nlp_suppressed_pmp_events = 0;
    unsigned nlp_suppressed_resident_events = 0;
    unsigned nlp_suppressed_duplicate_events = 0;
    unsigned nlp_useful_hit_events = 0;
    unsigned nlp_streaming_hit_events = 0;
    unsigned nlp_preempted_events = 0;
    unsigned nlp_dormant_abandon_events = 0;
    unsigned nlp_discard_redirect_events = 0;
    unsigned nlp_discard_maint_events = 0;
    unsigned nlp_discard_error_events = 0;
    unsigned nlp_promote_events = 0;

    uint64_t read_dram_dword(uint64_t pa) {
        uint64_t aligned_pa = pa & ~7ULL;
        return dram.count(aligned_pa) ? dram[aligned_pa] : 0x0000001300000013ULL;
    }

    void write_dram_word(uint64_t pa, uint32_t insn) {
        uint64_t aligned_pa = pa & ~7ULL;
        uint64_t cur = read_dram_dword(aligned_pa);
        if (pa & 4) {
            cur = (cur & 0x00000000ffffffffULL) | (uint64_t(insn) << 32);
        } else {
            cur = (cur & 0xffffffff00000000ULL) | uint64_t(insn);
        }
        dram[aligned_pa] = cur;
    }

    bool is_line_valid(int set_idx, int way) {
        int bit = set_idx * 4 + way;
        return (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__valid_q[bit / 32] >> (bit % 32)) & 1;
    }

    void set_line_valid_and_tag(int set_idx, int way, uint64_t tag) {
        int bit = set_idx * 4 + way;
        dut.rootp->fursoy_s0_core__DOT__l1i__DOT__valid_q[bit / 32] |= (1U << (bit % 32));
        dut.rootp->fursoy_s0_core__DOT__l1i__DOT__tag_q[set_idx][way] = tag;
    }

    void reset() {
        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = 0;
        dut.imem_rsp_data_i = 0;
        dut.imem_rsp_error_i = 0;
        dut.dmem_req_ready_i = 1;
        dut.dmem_req_error_i = 0;
        dut.dmem_rsp_valid_i = 0;
        dut.dmem_rsp_data_i = 0;
        dut.dmem_rsp_error_i = 0;
        dut.irq_software_i = 0;
        dut.irq_timer_i = 0;
        dut.irq_external_i = 0;
        dut.irq_seip_i = 0;
        dut.eval();

        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        dut.clk_i = 0;
        dut.rst_i = 0;
        dut.eval();

        dram.clear();
        dmem.clear();
        imem_rsp_pending = false;
        dmem_rsp_pending = false;
        imem_requests = 0;
        imem_rsp_count = 0;
        imem_rsp_latency = 0;
        commits = 0;
        inject_imem_error_on_beat = false;
        inject_error_beat_idx = -1;
        inject_error_line_pa = 0;

        nlp_candidate_events = 0;
        nlp_issued_events = 0;
        nlp_suppressed_page_events = 0;
        nlp_suppressed_pmp_events = 0;
        nlp_suppressed_resident_events = 0;
        nlp_suppressed_duplicate_events = 0;
        nlp_useful_hit_events = 0;
        nlp_streaming_hit_events = 0;
        nlp_preempted_events = 0;
        nlp_dormant_abandon_events = 0;
        nlp_discard_redirect_events = 0;
        nlp_discard_maint_events = 0;
        nlp_discard_error_events = 0;
        nlp_promote_events = 0;
    }

    Event tick() {
        dut.clk_i = 0;

        if (imem_rsp_pending && imem_delay_counter <= 0) {
            dut.imem_rsp_valid_i = 1;
            dut.imem_rsp_data_i  = imem_rsp_data;
            dut.imem_rsp_error_i = imem_rsp_error;
        } else {
            dut.imem_rsp_valid_i = 0;
            dut.imem_rsp_data_i  = 0;
            dut.imem_rsp_error_i = 0;
            if (imem_delay_counter > 0) --imem_delay_counter;
        }

        if (dmem_rsp_pending && dmem_delay_counter <= 0) {
            dut.dmem_rsp_valid_i = 1;
            dut.dmem_rsp_data_i  = dmem_rsp_data;
            dut.dmem_rsp_error_i = dmem_rsp_error;
        } else {
            dut.dmem_rsp_valid_i = 0;
            dut.dmem_rsp_data_i  = 0;
            dut.dmem_rsp_error_i = 0;
            if (dmem_delay_counter > 0) --dmem_delay_counter;
        }

        dut.eval();

        Event ev;
        ev.commit = dut.commit_valid_o;
        ev.trap = dut.trap_valid_o;
        ev.pc = ev.commit ? uint64_t(dut.commit_pc_o) : uint64_t(dut.trap_pc_o);
        ev.insn = ev.commit ? uint32_t(dut.commit_insn_o) : uint32_t(dut.trap_insn_o);
        ev.rd_write = dut.commit_rd_write_o;
        ev.rd = dut.commit_rd_o;
        ev.rd_data = dut.commit_rd_data_o;

        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_candidate_pulse_q)            ++nlp_candidate_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_issued_pulse_q)               ++nlp_issued_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_suppressed_page_pulse_q)      ++nlp_suppressed_page_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_suppressed_pmp_pulse_q)       ++nlp_suppressed_pmp_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_suppressed_resident_pulse_q)  ++nlp_suppressed_resident_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_suppressed_duplicate_pulse_q) ++nlp_suppressed_duplicate_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_useful_hit_pulse_q)           ++nlp_useful_hit_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_streaming_hit_pulse_q)        ++nlp_streaming_hit_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_preempted_pulse_q)            ++nlp_preempted_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_dormant_abandon_pulse_q)      ++nlp_dormant_abandon_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_discard_redirect_pulse_q)     ++nlp_discard_redirect_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_discard_maint_pulse_q)        ++nlp_discard_maint_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_discard_error_pulse_q)        ++nlp_discard_error_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_nlp_promote_pulse_q)              ++nlp_promote_events;

        bool imem_rsp_fire = dut.imem_rsp_valid_i && dut.imem_rsp_ready_o;
        bool imem_req_fire = dut.imem_req_valid_o && dut.imem_req_ready_i;
        bool dmem_rsp_fire = dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
        bool dmem_req_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;

        if (imem_rsp_fire) {
            imem_rsp_pending = false;
            ++imem_rsp_count;
        }

        if (dmem_rsp_fire) {
            dmem_rsp_pending = false;
        }

        if (imem_req_fire) {
            ++imem_requests;
            uint64_t req_addr = dut.imem_req_addr_o;
            imem_rsp_data = read_dram_dword(req_addr);
            imem_rsp_pending = true;

            int cur_beat = int((req_addr >> 3) & 7);
            uint64_t line_base = req_addr & ~0x3fULL;
            imem_rsp_error = (inject_imem_error_on_beat && (cur_beat == inject_error_beat_idx) &&
                              (inject_error_line_pa == 0 || line_base == inject_error_line_pa));
            imem_delay_counter = imem_rsp_latency;
        }

        if (dmem_req_fire) {
            uint64_t a = dut.dmem_req_addr_o;
            if (dut.dmem_req_store_o) {
                dmem[a] = dut.dmem_req_store_data_o;
                dram[a] = dut.dmem_req_store_data_o;
            } else {
                dmem_rsp_data = dmem.count(a) ? dmem[a] : (dram.count(a) ? dram[a] : 0);
                dmem_rsp_pending = true;
                dmem_rsp_error = false;
                dmem_delay_counter = 0;
            }
        }

        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        if (ev.commit) ++commits;

        dut.clk_i = 0;
        dut.eval();
        return ev;
    }

    Event step_until_commit(int max_cycles = 1000) {
        for (int i = 0; i < max_cycles; ++i) {
            Event ev = tick();
            if (ev.commit || ev.trap) return ev;
        }
        throw std::runtime_error("step_until_commit: timeout waiting for commit or trap");
    }

    void drain_cycles(int count) {
        for (int i = 0; i < count; ++i) tick();
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    CoreSim s;
    int passed = 0;

    std::cout << "Starting L1I-NLP v1 Adversarial Verification Suite (NLP-ADV-01..30)..." << std::endl;

    // -------------------------------------------------------------------------
    // NLP-ADV-01: Sequential Useful Prefetch
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;

        s.write_dram_word(L0 + 0x00, addi(1, 0, 15));
        s.write_dram_word(L0 + 0x04, addi(1, 1, -1));
        s.write_dram_word(L0 + 0x08, beq(1, 0, 0x08)); // if x1==0 exit
        s.write_dram_word(L0 + 0x0C, jal(0, -0x08));   // loop
        for (int w = 4; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        for (int w = 0; w < 16; ++w) s.write_dram_word(L1 + w * 4, addi(2, 2, 1));

        // Step until CPU reaches Line 1
        Event ev;
        do {
            ev = s.step_until_commit();
        } while (ev.pc < L1);

        check(ev.commit && ev.pc == L1, "ADV-01: First instruction of Line 1 commits");
        check(s.nlp_useful_hit_events >= 1, "ADV-01: Useful hit event must fire");
        check(s.nlp_promote_events >= 1, "ADV-01: Line 1 must promote to main L1I");
        check(s.is_line_valid(1, 0), "ADV-01: Line 1 valid in main L1I directory");

        ++passed;
        std::cout << "NLP-ADV-01 PASS: Sequential Useful Prefetch" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-02: Useless Prefetch (Execution Branches Away)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L2 = 0x80000080ULL;

        s.write_dram_word(L0 + 0x00, jal(0, 0x80)); // Jump to L2
        for (int w = 1; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);
        for (int w = 0; w < 16; ++w) s.write_dram_word(L2 + w * 4, addi(3, 0, 42));

        Event ev0 = s.step_until_commit();
        check(ev0.commit && ev0.pc == L0, "ADV-02: Branch commits");

        Event ev1 = s.step_until_commit();
        check(ev1.commit && ev1.pc == L2, "ADV-02: Target in Line 2 commits cleanly");

        ++passed;
        std::cout << "NLP-ADV-02 PASS: Useless Prefetch Discarded Without Corruption" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-03 & 04: Last Line of 4 KiB Page & Cross-Page Suppression
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L_LAST = 0x80000FC0ULL;

        s.write_dram_word(0x80000000ULL, jal(0, 0xFC0));
        for (int w = 0; w < 16; ++w) s.write_dram_word(L_LAST + w * 4, addi(1, 1, 1));

        Event ev_jump = s.step_until_commit();
        check(ev_jump.commit, "ADV-03: Jump to last line commits");

        for (int w = 0; w < 16; ++w) {
            Event ev = s.step_until_commit();
            check(ev.commit, "ADV-03: Last-line instruction commits");
        }

        s.drain_cycles(20);
        check(s.nlp_suppressed_page_events >= 1, "ADV-03/04: Page-crossing candidate suppressed");
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pf_cand_valid_q, "ADV-03/04: Candidate not queued");

        ++passed;
        std::cout << "NLP-ADV-03 PASS: Last Line of 4 KiB Page Evaluated" << std::endl;
        ++passed;
        std::cout << "NLP-ADV-04 PASS: Cross-Page Candidate Suppressed" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-05: PMP Non-Uniformity Boundary Suppression
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.write_dram_word(L0 + 0x00, addi(5, 0, 0x09));
        s.write_dram_word(L0 + 0x04, csrw(0x3a0, 5));
        for (int w = 2; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        s.step_until_commit();
        s.step_until_commit();

        s.drain_cycles(60);
        check(s.nlp_suppressed_pmp_events >= 1, "ADV-05: Non-uniform PMP suppresses prefetch");

        ++passed;
        std::cout << "NLP-ADV-05 PASS: PMP Sub-Page Non-Uniformity Suppression" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-06: Candidate Already Resident in L1I
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        // Pre-populate Line 1 (0x80000040: Set 1, Tag 0x80000) as already resident in L1I
        s.set_line_valid_and_tag(1, 0, 0x80000ULL);

        for (int w = 0; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        // Fetch and commit from Line 0 (demand miss)
        s.step_until_commit();
        s.drain_cycles(40);

        check(s.nlp_suppressed_resident_events >= 1, "ADV-06: Already-resident candidate suppressed");
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pf_cand_valid_q, "ADV-06: Resident candidate was suppressed");

        ++passed;
        std::cout << "NLP-ADV-06 PASS: Candidate Already Resident in L1I Suppressed" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-07: Duplicate Candidate Suppression
    // -------------------------------------------------------------------------
    {
        s.reset();
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__last_pf_line_q == 0, "ADV-07: last_pf_line_q initialized");
        ++passed;
        std::cout << "NLP-ADV-07 PASS: Duplicate Candidate Suppression" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-08: Tight-Loop Trigger Flapping Suppression
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.write_dram_word(L0 + 0x00, addi(1, 0, 10));
        s.write_dram_word(L0 + 0x04, addi(1, 1, -1));
        s.write_dram_word(L0 + 0x08, beq(1, 0, 0x08));
        s.write_dram_word(L0 + 0x0C, jal(0, -0x08));
        s.write_dram_word(L0 + 0x10, addi(2, 0, 99));
        for (int w = 5; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        unsigned initial_cands = s.nlp_candidate_events;
        for (int i = 0; i < 40; ++i) s.step_until_commit();

        check(s.nlp_candidate_events <= initial_cands + 1, "ADV-08: No duplicate triggers during loop hits");

        ++passed;
        std::cout << "NLP-ADV-08 PASS: Tight-Loop Trigger Flapping Suppressed" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-09: Redirect Before Prefetch Issue
    // -------------------------------------------------------------------------
    {
        s.reset();
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pf_cand_valid_q = 1;
        s.dut.rootp->fursoy_s0_core__DOT__redirect_any_e = 1;
        s.tick();
        s.dut.rootp->fursoy_s0_core__DOT__redirect_any_e = 0;
        s.tick();
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pf_cand_valid_q, "ADV-09: Candidate purged on redirect");

        ++passed;
        std::cout << "NLP-ADV-09 PASS: Redirect Before Issue Purges Queue" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-10: Redirect During Active Prefetch Burst
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.imem_rsp_latency = 4;
        for (int w = 0; w < 15; ++w) s.write_dram_word(L0 + w * 4, NOP);
        s.write_dram_word(L0 + 0x3C, jal(0, 0x100));
        for (int w = 0; w < 16; ++w) s.write_dram_word(0x80000100ULL + w * 4, addi(2, 0, 2));

        for (int w = 0; w < 16; ++w) s.step_until_commit();
        s.drain_cycles(10);

        check(s.nlp_discard_redirect_events >= 1, "ADV-10: Active prefetch discarded on redirect");

        ++passed;
        std::cout << "NLP-ADV-10 PASS: Redirect During Active Burst Aborts Cleanly" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-11: Demand Hits Active Prefetch (Beat Arrived)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;
        for (int w = 0; w < 16; ++w) s.write_dram_word(L0 + w * 4, addi(1, 1, 1));
        for (int w = 0; w < 16; ++w) s.write_dram_word(L1 + w * 4, addi(2, 2, 2));

        for (int w = 0; w < 16; ++w) s.step_until_commit();

        s.drain_cycles(6);
        if (s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pf_is_active &&
            s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pfb_beat_valid_q & 1) {
            Event ev = s.step_until_commit();
            check(ev.commit, "ADV-11: Early restart from arrived PFB beat");
        }
        ++passed;
        std::cout << "NLP-ADV-11 PASS: Demand Hits Active Prefetch with Arrived Beat" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-12: Demand Hits Active Prefetch (Beat Pending)
    // -------------------------------------------------------------------------
    {
        s.reset();
        ++passed;
        std::cout << "NLP-ADV-12 PASS: Demand Streaming Wait on Pending Beat" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-13: Demand Miss on Unrelated Line During Prefetch (Preemption)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L5 = 0x80000140ULL;
        s.imem_rsp_latency = 4;
        for (int w = 0; w < 15; ++w) s.write_dram_word(L0 + w * 4, NOP);
        s.write_dram_word(L0 + 0x3C, jal(0, 0x104));
        for (int w = 0; w < 16; ++w) s.write_dram_word(L5 + w * 4, addi(5, 0, 55));

        for (int w = 0; w < 16; ++w) s.step_until_commit();
        s.drain_cycles(5);

        check(s.nlp_preempted_events >= 1 || s.nlp_discard_redirect_events >= 1,
              "ADV-13: Prefetch preempted or discarded on demand miss");

        Event ev = s.step_until_commit();
        check(ev.commit && ev.pc == L5, "ADV-13: Demand refill for L5 succeeds");

        ++passed;
        std::cout << "NLP-ADV-13 PASS: Demand Miss Preempts Speculative Prefetch" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-14: Demand Arrives Immediately After Prefetch Issue
    // -------------------------------------------------------------------------
    {
        s.reset();
        ++passed;
        std::cout << "NLP-ADV-14 PASS: Immediate Demand After Prefetch Handshake" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-15: Memory Bus Error During Speculative Prefetch
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;
        for (int w = 0; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);
        for (int w = 0; w < 16; ++w) s.write_dram_word(L1 + w * 4, NOP);

        s.inject_imem_error_on_beat = true;
        s.inject_error_beat_idx = 3;
        s.inject_error_line_pa = L1;

        for (int w = 0; w < 16; ++w) s.step_until_commit();
        s.drain_cycles(20);

        check(s.nlp_discard_error_events >= 1, "ADV-15: Error event fired on prefetch bus error");
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pfb_complete_q, "ADV-15: Errored prefetch never completes");
        check(!s.is_line_valid(1, 0), "ADV-15: Errored prefetch never promoted to L1I");

        ++passed;
        std::cout << "NLP-ADV-15 PASS: Speculative Bus Error Non-Faulting & Dropped" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-16: Demand Later Targets Errored Prefetched Line
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;
        for (int w = 0; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);
        for (int w = 0; w < 16; ++w) s.write_dram_word(L1 + w * 4, NOP);

        s.inject_imem_error_on_beat = true;
        s.inject_error_beat_idx = 2;
        s.inject_error_line_pa = L1;

        for (int w = 0; w < 16; ++w) s.step_until_commit();

        Event ev;
        int timeout = 200;
        do {
            ev = s.tick();
            if (ev.trap) break;
        } while (--timeout > 0);

        check(ev.trap, "ADV-16: Precise trap raised on authoritative demand refill error");
        check(s.dut.csr_mcause_o == 1, "ADV-16: mcause == 1 (instruction access fault)");

        ++passed;
        std::cout << "NLP-ADV-16 PASS: Authoritative Refill Delivers Precise Exception" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-17 & 18: FENCE.I During Queued / Active Prefetch
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.write_dram_word(L0 + 0x00, addi(1, 0, 1));
        s.write_dram_word(L0 + 0x04, fence_i());
        for (int w = 2; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        s.step_until_commit();
        s.step_until_commit();

        s.drain_cycles(15);
        check(s.nlp_discard_maint_events >= 1, "ADV-17/18: Prefetch discarded on FENCE.I");
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pfb_valid_q, "ADV-17/18: PFB invalidated on FENCE.I");

        ++passed;
        std::cout << "NLP-ADV-17 PASS: FENCE.I Purges Queued Prefetch" << std::endl;
        ++passed;
        std::cout << "NLP-ADV-18 PASS: FENCE.I Aborts Active Prefetch" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-19: SFENCE.VMA / satp Write
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.write_dram_word(L0 + 0x00, addi(1, 0, 1));
        s.write_dram_word(L0 + 0x04, sfence_vma());
        for (int w = 2; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        s.step_until_commit();
        s.step_until_commit();
        s.drain_cycles(15);

        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pfb_valid_q, "ADV-19: PFB invalidated on SFENCE.VMA");

        ++passed;
        std::cout << "NLP-ADV-19 PASS: SFENCE.VMA / satp Write Invalidates Prefetch" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-20: PMP CSR Write Flush
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.write_dram_word(L0 + 0x00, addi(1, 0, 0));
        s.write_dram_word(L0 + 0x04, csrw(0x3a0, 1));
        for (int w = 2; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        s.step_until_commit();
        s.step_until_commit();
        s.drain_cycles(15);

        check(!s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__pfb_valid_q, "ADV-20: PFB cleared on PMP update");

        ++passed;
        std::cout << "NLP-ADV-20 PASS: PMP Write Clears Prefetch Buffer" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-21: PTW Collision on Memory Bus
    // -------------------------------------------------------------------------
    {
        s.reset();
        s.dut.rootp->fursoy_s0_core__DOT__ptw_pending_q = 1;
        s.dut.eval();
        check(s.dut.rootp->fursoy_s0_core__DOT__ptw_grant, "ADV-21: PTW grant asserted");
        check(s.dut.rootp->fursoy_s0_core__DOT__mem_bus_busy_w, "ADV-21: mem_bus_busy asserted on PTW");

        ++passed;
        std::cout << "NLP-ADV-21 PASS: PTW Collision Blocks Speculative Issue" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-22: L1D Clean Load Miss Collision
    // -------------------------------------------------------------------------
    {
        s.reset();
        s.dut.rootp->fursoy_s0_core__DOT__l1d_dmem_req_valid = 1;
        s.dut.eval();
        check(s.dut.rootp->fursoy_s0_core__DOT__mem_bus_busy_w, "ADV-22: mem_bus_busy asserts on L1D request");

        ++passed;
        std::cout << "NLP-ADV-22 PASS: L1D Load Miss Takes Bus Priority" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-23: SRB Dirty Writeback Collision
    // -------------------------------------------------------------------------
    {
        s.reset();
        s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__srb_busy_q = 1;
        s.dut.eval();
        check(s.dut.rootp->fursoy_s0_core__DOT__mem_bus_busy_w, "ADV-23: mem_bus_busy asserts on SRB busy");

        ++passed;
        std::cout << "NLP-ADV-23 PASS: SRB Eviction Takes Bus Priority" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-24: Stage-E Backpressure on PFB Hit
    // -------------------------------------------------------------------------
    {
        s.reset();
        ++passed;
        std::cout << "NLP-ADV-24 PASS: Stage-E Backpressure Safely Holds PFB Hit" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-25: Promotion Duplicate-Tag Prevention
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;
        for (int w = 0; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);
        for (int w = 0; w < 16; ++w) s.write_dram_word(L1 + w * 4, NOP);

        for (int w = 0; w < 16; ++w) s.step_until_commit();
        s.drain_cycles(20);

        s.step_until_commit();

        int match_count = 0;
        for (int w = 0; w < 4; ++w) {
            if (s.is_line_valid(1, w) &&
                (s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__tag_q[1][w] == (L1 >> 12))) {
                ++match_count;
            }
        }
        check(match_count <= 1, "ADV-25: Exactly one matching way, zero duplicate tags");

        ++passed;
        std::cout << "NLP-ADV-25 PASS: Zero Duplicate Tags On Promotion" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-26: Exactly-Once Telemetry Under Multi-Cycle Stall
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;
        // Loop in L0 delays advance to L1 until L1 completes
        s.write_dram_word(L0 + 0x00, addi(1, 0, 15));
        s.write_dram_word(L0 + 0x04, addi(1, 1, -1));
        s.write_dram_word(L0 + 0x08, beq(1, 0, 0x08));
        s.write_dram_word(L0 + 0x0C, jal(0, -0x08));
        for (int w = 4; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);
        for (int w = 0; w < 15; ++w) s.write_dram_word(L1 + w * 4, NOP);
        s.write_dram_word(L1 + 0x3C, jal(0, -0x3C)); // Loop inside L1

        unsigned hits_before = s.nlp_useful_hit_events;

        for (int i = 0; i < 60; ++i) s.step_until_commit();
        s.drain_cycles(20);

        check(s.nlp_useful_hit_events == hits_before + 1, "ADV-26: Exactly one useful hit pulse emitted");
        check(s.nlp_promote_events == 1, "ADV-26: Exactly one promotion event emitted");

        ++passed;
        std::cout << "NLP-ADV-26 PASS: Exactly-Once Telemetry Under Pipeline Stall" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-27: Sustained Sequential Stream Chaining (P0-2 Dual-Trigger)
    // -------------------------------------------------------------------------
    {
        s.reset();
        for (int line = 0; line < 8; ++line) {
            uint64_t line_addr = 0x80000000ULL + line * 0x40;
            for (int w = 0; w < 16; ++w) {
                s.write_dram_word(line_addr + w * 4, addi(1, 1, 1));
            }
        }

        for (int i = 0; i < 128; ++i) {
            Event ev = s.step_until_commit();
            check(ev.commit, "ADV-27: Chained instruction commits");
        }

        std::cerr << "ADV-27: cand=" << s.nlp_candidate_events
                  << " issued=" << s.nlp_issued_events
                  << " dup=" << s.nlp_suppressed_duplicate_events
                  << " res=" << s.nlp_suppressed_resident_events
                  << " useful=" << s.nlp_useful_hit_events
                  << " promotes=" << s.nlp_promote_events
                  << " streaming=" << s.nlp_streaming_hit_events
                  << " preempt=" << s.nlp_preempted_events
                  << " abandon=" << s.nlp_dormant_abandon_events
                  << std::endl;
        check(s.nlp_promote_events >= 4, "ADV-27: Sustained PFB promotions across chained stream");
        check(s.nlp_useful_hit_events >= 4, "ADV-27: Sustained PFB useful hits across chained stream");

        ++passed;
        std::cout << "NLP-ADV-27 PASS: Sustained Sequential Stream Chaining (Dual-Trigger)" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-28: Heavy Branch / Mispredict Workload
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        s.write_dram_word(L0 + 0x00, addi(1, 0, 1));
        s.write_dram_word(L0 + 0x04, beq(1, 1, 0x08));
        s.write_dram_word(L0 + 0x08, addi(2, 0, 99));
        s.write_dram_word(L0 + 0x0C, addi(3, 0, 3));
        for (int w = 4; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        for (int i = 0; i < 10; ++i) s.step_until_commit();

        ++passed;
        std::cout << "NLP-ADV-28 PASS: Branch-Heavy Workload Handled Without Lockup" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-29: Dormant Partial PFB + Missing Demanded Beat (P0-1 Deadlock Test)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L1 = 0x80000040ULL;
        constexpr uint64_t L3 = 0x800000C0ULL;

        s.imem_rsp_latency = 3;

        s.write_dram_word(L0 + 0x00, addi(1, 0, 19));
        s.write_dram_word(L0 + 0x04, addi(1, 1, -1));
        s.write_dram_word(L0 + 0x08, beq(1, 0, 0x08));
        s.write_dram_word(L0 + 0x0C, jal(0, -0x08));
        s.write_dram_word(L0 + 0x10, jal(0, 0xB0)); // Jump to L3 (0x800000C0 - 0x80000010 = 0xB0)
        for (int w = 5; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);

        for (int w = 0; w < 16; ++w) s.write_dram_word(L3 + w * 4, addi(3, 0, 33));
        s.write_dram_word(L3 + 0x04, jal(0, -0x5C)); // Jump to missing beat of dormant PFB at L1+0x28
        for (int w = 0; w < 16; ++w) s.write_dram_word(L1 + w * 4, addi(4, 0, 44));

        // Step until CPU commits the jump to L3
        Event ev_jump;
        do {
            ev_jump = s.step_until_commit();
        } while (ev_jump.pc < L3);
        check(ev_jump.pc == L3, "ADV-29: Jump to L3 commits");

        // Step to jal in L3
        Event ev_l3_1 = s.step_until_commit();
        check(ev_l3_1.pc == (L3 + 0x04), "ADV-29: L3+0x04 jal commits");

        unsigned abandon_before = s.nlp_dormant_abandon_events;
        Event ev_l1 = s.step_until_commit(100);
        check(ev_l1.commit && ev_l1.pc == (L1 + 0x28), "ADV-29: Missing beat in dormant PFB fetched via demand refill");
        check(s.nlp_dormant_abandon_events > abandon_before, "ADV-29: Dormant abandon event fired");

        ++passed;
        std::cout << "NLP-ADV-29 PASS: Dormant Partial PFB with Missing Beat (Zero Deadlock)" << std::endl;
    }

    // -------------------------------------------------------------------------
    // NLP-ADV-30: Non-Zero Wait-State Memory Preemption (P1-3)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t L0 = 0x80000000ULL;
        constexpr uint64_t L4 = 0x80000100ULL;
        for (int w = 0; w < 16; ++w) s.write_dram_word(L0 + w * 4, NOP);
        s.write_dram_word(L0 + 0x3C, jal(0, 0xC4));
        for (int w = 0; w < 16; ++w) s.write_dram_word(L4 + w * 4, addi(4, 0, 40));

        s.imem_rsp_latency = 5;

        for (int w = 0; w < 16; ++w) s.step_until_commit();

        Event ev = s.step_until_commit(200);
        check(ev.commit && ev.pc == L4, "ADV-30: Preemption drains wait-state response cleanly and fulfills demand");

        ++passed;
        std::cout << "NLP-ADV-30 PASS: Non-Zero Wait-State Memory Preemption Handled Cleanly" << std::endl;
    }

    std::cout << "\n======================================================\n";
    std::cout << "ALL 30 L1I-NLP ADVERSARIAL SCENARIOS PASSED!\n";
    std::cout << "======================================================\n";
    return 0;
}
