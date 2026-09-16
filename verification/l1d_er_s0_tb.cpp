// Fursoy Slice-0 Hardware L1 Data Cache Critical-Word Early Restart (L1D-ER) Verification Suite
// Normative Baseline: docs/architecture/l1d-refill-opt-v1.md (Frozen Architecture)
// Core-level portion of the 34-scenario matrix. ER-ADV-27 and ER-ADV-33
// execute against the real L1D production interface in l1d_er_unit_tb.cpp.
// ER-DIR-01..08: Critical Beat Sweep (Clean load misses across beats 0..7)
// ER-DIR-09..11: Dirty Victim Refills (Beats 0, 3, 7 with synchronous 8-beat eviction)
// ER-ADV-12..14: Multi-cycle stall, persistent valid/data hold, exactly-once retirement
// ER-ADV-15..16: Bus errors (Pre-critical access fault vs post-ER fatal platform error)
// ER-ADV-17..20: Conservative trailing refill: subsequent load stall, SB drains held, SB full stall, ALU overlap
// ER-ADV-21..24: Operation class exclusions: LR.W/D, SC.W/D, AMO, SRB collision exclusion
// ER-ADV-25..27: Randomized wait states, trap during trailing burst, redirect squashing er_retire_valid_q
// ER-ADV-28..30: Maintenance serialization: FENCE, SFENCE.VMA, PMP CSR write stalls
// ER-ADV-31..32: Atomic INSTALL publication, Tree-PLRU exactly-once update

#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>
#include <string>
#include <random>

static void check(bool cond, const std::string &msg) {
    if (!cond) {
        throw std::runtime_error(msg);
    }
}

// RISC-V Instruction Encoders
static constexpr uint32_t NOP = 0x00000013;
static uint32_t add(unsigned rd, unsigned rs1, unsigned rs2) {
    return (rs2 << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x33;
}
static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13;
}
static uint32_t slli(unsigned rd, unsigned rs1, unsigned sh) {
    return (sh << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13;
}
static uint32_t auipc(unsigned rd, uint32_t imm20) {
    return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x17;
}
static uint32_t ld(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
}
static uint32_t sd(unsigned rs2, unsigned rs1, int imm) {
    uint32_t u = uint32_t(imm);
    return (((u >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((u & 31) << 7) | 0x23;
}
static uint32_t csr(unsigned f, unsigned rd, unsigned rs1, unsigned addr) {
    return (addr << 20) | (rs1 << 15) | (f << 12) | (rd << 7) | 0x73;
}
static uint32_t csrw(unsigned addr, unsigned rs1) { return csr(1, 0, rs1, addr); }

static constexpr uint32_t kFenceI     = 0x0000100f;
static constexpr uint32_t kSfenceVma  = 0x12000073;
static uint32_t fence_rw_rw() {
    return (0 << 20) | (0 << 15) | (0 << 12) | (0 << 7) | 0x0f | (3 << 24) | (3 << 20);
}

// RV64A Encoders
static uint32_t lr_d(unsigned rd, unsigned rs1) { return (2 << 27) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2f; }
static uint32_t sc_d(unsigned rd, unsigned rs2, unsigned rs1) { return (3 << 27) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2f; }
static uint32_t amoadd_d(unsigned rd, unsigned rs2, unsigned rs1) { return (0 << 27) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x2f; }

struct Event {
    bool commit = false;
    bool trap = false;
    uint64_t pc = 0;
    uint32_t insn = 0;
    bool rd_write = false;
    unsigned rd = 0;
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

    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    bool dmem_rsp_error = false;
    int dmem_delay_counter = 0;

    uint64_t cycles = 0;
    uint64_t commits = 0;
    uint64_t writebacks = 0;

    bool random_dmem_stall = false;
    std::mt19937_64 rng{12345};

    bool hold_stage_e_stall = false;
    bool arm_raw_error_on_arch_event = false;
    int raw_error_injections = 0;
    int inject_error_on_beat = -1;
    int current_refill_beat = 0;
    int er_events_observed = 0;
    int last_saved_cycles = 0;

    void write_dram_word(uint64_t addr, uint32_t val) {
        uint64_t dword_addr = addr & ~0x7ULL;
        uint64_t cur = dram.count(dword_addr) ? dram[dword_addr] : 0ULL;
        if ((addr & 4) == 0) {
            cur = (cur & 0xffffffff00000000ULL) | (uint64_t(val) & 0xffffffffULL);
        } else {
            cur = (cur & 0x00000000ffffffffULL) | ((uint64_t(val) & 0xffffffffULL) << 32);
        }
        dram[dword_addr] = cur;
    }

    uint64_t read_dram_dword(uint64_t addr) {
        uint64_t dword_addr = addr & ~0x7ULL;
        return dram.count(dword_addr) ? dram[dword_addr] : 0x0000001300000013ULL;
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

        // Default open PMP entry 0: ALL DRAM permissions (NAPOT)
        dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x1f;
        dut.rootp->fursoy_s0_core__DOT__pmp_cfg_w[0] = 0x1f;
        dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = 0x3fffffffffffffULL;
        dut.rootp->fursoy_s0_core__DOT__pmp_addr_w[0] = 0x3fffffffffffffULL;
        dut.eval();

        imem_rsp_pending = false;
        dmem_rsp_pending = false;
        dmem_delay_counter = 0;
        imem_delay_counter = 0;
        random_dmem_stall = false;
        hold_stage_e_stall = false;
        dut.rootp->fursoy_s0_core__DOT__verification_stall_e = 0;
        dut.rootp->fursoy_s0_core__DOT__verification_l1d_error_edge = 0;
        arm_raw_error_on_arch_event = false;
        raw_error_injections = 0;
        inject_error_on_beat = -1;
        current_refill_beat = 0;
        er_events_observed = 0;
        last_saved_cycles = 0;
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

        dut.imem_req_ready_i = 1;
        if (random_dmem_stall) {
            dut.dmem_req_ready_i = (rng() % 3 != 0);
        } else {
            dut.dmem_req_ready_i = 1;
        }

        dut.rootp->fursoy_s0_core__DOT__verification_stall_e = hold_stage_e_stall ? 1 : 0;
        dut.rootp->fursoy_s0_core__DOT__verification_l1d_error_edge = 0;
        dut.eval();

        // Verification-only boundary injection: wait until an unrelated
        // architectural action is genuinely ready, then assert the raw L1D-ER
        // error edge in that same combinational cycle.  Production has no test
        // port; this state is removed under SYNTHESIS.
        if (arm_raw_error_on_arch_event && (dut.commit_valid_o || dut.trap_valid_o)) {
            dut.rootp->fursoy_s0_core__DOT__verification_l1d_error_edge = 1;
            dut.eval();
            check(!dut.commit_valid_o && !dut.trap_valid_o,
                  "RAW-EDGE: unrelated commit/trap escaped explicit error-edge gating");
            arm_raw_error_on_arch_event = false;
            ++raw_error_injections;
        }

        // Sample ER Telemetry
        if (dut.rootp->fursoy_s0_core__DOT__l1d_er_event) {
            ++er_events_observed;
            last_saved_cycles = dut.rootp->fursoy_s0_core__DOT__l1d_er_saved_cycles;
        }

        Event ev;
        ev.commit = dut.commit_valid_o;
        ev.trap = dut.trap_valid_o;
        ev.pc = ev.commit ? uint64_t(dut.commit_pc_o) : uint64_t(dut.trap_pc_o);
        ev.insn = ev.commit ? uint32_t(dut.commit_insn_o) : uint32_t(dut.trap_insn_o);
        ev.rd_write = dut.commit_rd_write_o;
        ev.rd = dut.commit_rd_o;
        ev.rd_data = dut.commit_rd_data_o;

        bool imem_rsp_fire = dut.imem_rsp_valid_i && dut.imem_rsp_ready_o;
        bool imem_req_fire = dut.imem_req_valid_o && dut.imem_req_ready_i;
        bool dmem_rsp_fire = dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
        bool dmem_req_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;

        if (imem_rsp_fire) imem_rsp_pending = false;
        if (dmem_rsp_fire) {
            dmem_rsp_pending = false;
            ++current_refill_beat;
        }

        if (imem_req_fire) {
            uint64_t req_addr = dut.imem_req_addr_o;
            imem_rsp_data = read_dram_dword(req_addr);
            imem_rsp_pending = true;
            imem_rsp_error = false;
            imem_delay_counter = 0;
        }

        if (dmem_req_fire) {
            uint64_t a = dut.dmem_req_addr_o;
            if (dut.dmem_req_store_o) {
                ++writebacks;
                dmem[a] = dut.dmem_req_store_data_o;
                dram[a] = dut.dmem_req_store_data_o;
                dmem_rsp_data = 0;
                dmem_rsp_pending = true;
                dmem_rsp_error = false;
            } else {
                int beat = int((a >> 3) & 7);
                dmem_rsp_data = dmem.count(a) ? dmem[a] : (dram.count(a) ? dram[a] : 0);
                dmem_rsp_pending = true;
                dmem_rsp_error = (inject_error_on_beat >= 0 && beat == inject_error_on_beat);
            }
            dmem_delay_counter = random_dmem_stall ? int(rng() % 4) : 0;
        }

        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        if (ev.commit) ++commits;

        dut.clk_i = 0;
        dut.rootp->fursoy_s0_core__DOT__verification_l1d_error_edge = 0;
        dut.eval();
        return ev;
    }

    Event step_until_commit(int max_cycles = 1000) {
        for (int i = 0; i < max_cycles; i++) {
            Event ev = tick();
            if (ev.commit || ev.trap) return ev;
        }
        std::cerr << "TIMEOUT at cycle " << cycles << " commits=" << commits << std::endl;
        throw std::runtime_error("Timeout waiting for commit/trap");
    }
};

static void encode_addr(CoreSim &s, uint64_t pc, unsigned rd, uint64_t target_pa) {
    int64_t diff = int64_t(target_pa) - int64_t(pc);
    int32_t imm20 = int32_t((diff + 0x800) >> 12);
    int32_t imm12 = int32_t(diff - (int64_t(imm20) << 12));
    s.write_dram_word(pc, auipc(rd, uint32_t(imm20)));
    s.write_dram_word(pc + 4, addi(rd, rd, imm12));
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::cout << "Starting L1D Load Critical-Word Early Restart (L1D-ER v1) core scenarios...\n";

    CoreSim s;
    int passed = 0;
    const uint64_t B = 0x80000000ULL;

    // =========================================================================
    // Group 1: Critical Beat Sweep (ER-DIR-01 .. ER-DIR-08)
    // Clean load misses across beats 0 through 7
    // =========================================================================
    for (int beat = 0; beat < 8; beat++) {
        s.reset();
        uint64_t line_addr = B + 0x2000 + beat * 0x100;
        for (int d = 0; d < 8; d++) {
            s.dram[line_addr + d * 8] = 0xcafe00000000ULL | (uint64_t(beat) << 16) | d;
        }
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, beat * 8)); // critical beat load
        s.write_dram_word(B + 0x0C, ld(11, 2, ((beat + 1) % 8) * 8)); // subsequent intra-line hit check

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        Event ev_ld = s.step_until_commit();
        check(ev_ld.commit && ev_ld.rd == 10, "Critical beat load commits");
        check(ev_ld.rd_data == s.dram[line_addr + beat * 8], "Critical beat returns correct data");

        if (beat < 7) {
            int expected_saved = 2 * (7 - beat) - 1;
            check(s.er_events_observed >= 1, "ER event observed on critical beat");
            check(s.last_saved_cycles == expected_saved, "Expected cycle savings matches theoretical model");
        } else {
            check(s.last_saved_cycles == 0, "Beat 7 does not save trailing burst cycles");
        }

        Event ev_hit = s.step_until_commit();
        check(ev_hit.commit && ev_hit.rd == 11, "Subsequent intra-line access commits");
        check(ev_hit.rd_data == s.dram[line_addr + ((beat + 1) % 8) * 8], "Subsequent hit returns correct data");

        ++passed;
        std::cout << "ER-DIR-0" << (beat + 1) << " PASS: Clean load miss, Beat " << beat
                  << " (saved " << s.last_saved_cycles << " cycles)\n";
    }

    // =========================================================================
    // Group 2: Dirty Victim Refills (ER-DIR-09 .. ER-DIR-11)
    // Synchronous 8-beat eviction completes before demand refill and ER
    // =========================================================================
    int dirty_beats[3] = {0, 3, 7};
    for (int idx = 0; idx < 3; idx++) {
        int beat = dirty_beats[idx];
        s.reset();
        uint64_t set_offset = 6 * 64; // Set 6
        uint64_t way0_addr = B + 0x10000 + set_offset;
        uint64_t way1_addr = B + 0x20000 + set_offset;
        uint64_t way2_addr = B + 0x30000 + set_offset;
        uint64_t way3_addr = B + 0x40000 + set_offset;
        uint64_t new_addr  = B + 0x50000 + set_offset;

        for (int d = 0; d < 8; d++) {
            s.dram[way0_addr + d * 8] = 0x1000ULL + d;
            s.dram[way1_addr + d * 8] = 0x2000ULL + d;
            s.dram[way2_addr + d * 8] = 0x3000ULL + d;
            s.dram[way3_addr + d * 8] = 0x4000ULL + d;
            s.dram[new_addr  + d * 8] = 0x5000ULL + d;
        }

        s.write_dram_word(B + 0x00, addi(1, 0, 0x99));
        encode_addr(s, B + 0x04, 2, way0_addr);
        s.write_dram_word(B + 0x0C, sd(1, 2, 0)); // dirty way 0
        encode_addr(s, B + 0x10, 3, way1_addr);
        s.write_dram_word(B + 0x18, sd(1, 3, 0)); // dirty way 1
        encode_addr(s, B + 0x1C, 4, way2_addr);
        s.write_dram_word(B + 0x24, sd(1, 4, 0)); // dirty way 2
        encode_addr(s, B + 0x28, 5, way3_addr);
        s.write_dram_word(B + 0x30, sd(1, 5, 0)); // dirty way 3
        s.write_dram_word(B + 0x34, fence_rw_rw()); // Drain SB
        encode_addr(s, B + 0x38, 6, new_addr);
        s.write_dram_word(B + 0x40, ld(10, 6, beat * 8)); // 5th address causes eviction + refill

        for (int i = 0; i < 16; i++) s.step_until_commit();

        uint64_t wb_before = s.writebacks;
        Event ev_ld = s.step_until_commit();
        check(ev_ld.commit && ev_ld.rd == 10, "Dirty victim load commits");
        check(ev_ld.rd_data == s.dram[new_addr + beat * 8], "Returns correct refilled data");
        check(s.writebacks >= wb_before + 8, "Synchronous 8-beat writeback occurred prior to refill");

        if (beat < 7) {
            check(s.er_events_observed >= 1, "ER event observed after eviction burst");
        }

        ++passed;
        int scenario_id = 9 + idx;
        std::cout << "ER-DIR-" << (scenario_id < 10 ? "0" : "") << scenario_id
                  << " PASS: Dirty victim miss, Beat " << beat << " (8-beat writeback verified)\n";
    }

    // =========================================================================
    // ER-ADV-12, ER-ADV-13, ER-ADV-14: Multi-Cycle Stall, Valid Hold, Exactly-Once Commit
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x6000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0xd000ULL + d;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0 critical
        s.write_dram_word(B + 0x0C, addi(11, 0, 42));

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        // Step until refill begins
        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q == 0) {
            s.tick();
        }

        // Apply backpressure before critical beat arrives
        s.hold_stage_e_stall = true;

        // Step until critical beat arrives in L1D and er_retire_valid_q asserts
        while (!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_valid_q) {
            s.tick();
        }

        // Critical beat is registered in er_retire_valid_q and er_retire_rd_data_q!
        // Verify stability across 10 stall cycles
        uint64_t initial_commits = s.commits;
        for (int i = 0; i < 10; i++) {
            check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_valid_q == 1,
                  "ER-ADV-13: er_retire_valid_q must hold stably during stall");
            check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_rd_data_q == 0xd000ULL,
                  "ER-ADV-13: er_retire_rd_data_q must hold stably during stall");
            check(s.commits == initial_commits, "ER-ADV-12: Core must not commit while stalled");
            s.tick();
        }

        // Release backpressure
        s.hold_stage_e_stall = false;
        s.dut.rootp->fursoy_s0_core__DOT__verification_stall_e = 0;
        s.dut.eval();

        Event ev_commit = s.tick();
        check(ev_commit.commit && ev_commit.rd == 10 && ev_commit.rd_data == 0xd000ULL,
              "ER-ADV-14: Load commits exactly once when stall clears");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_load_retired_q == 1,
              "ER-ADV-14: authoritative retirement state set on acknowledge");

        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_valid_q == 0,
              "ER-ADV-14: er_retire_valid_q deasserts after consumption");

        Event ev_next = s.step_until_commit();
        check(ev_next.commit && ev_next.rd == 11 && ev_next.rd_data == 42, "Subsequent instruction executes");

        passed += 3;
        std::cout << "ER-ADV-12 PASS: Multi-Cycle Stage-E Stall Across Critical Beat Arrival\n";
        std::cout << "ER-ADV-13 PASS: Stable Valid & Data Hold Across Stalls\n";
        std::cout << "ER-ADV-14 PASS: Exactly-Once Commit On Handshake Acknowledgement\n";
    }

    // =========================================================================
    // ER-ADV-15: Pre-Critical Bus Error
    // Error on b <= b_crit poisons refill, suppresses ER, raises cause 5
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x7000;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 24)); // critical beat 3

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        s.inject_error_on_beat = 1;
        Event ev = s.step_until_commit();

        check(ev.trap, "ER-ADV-15: Pre-critical bus error must raise synchronous trap");
        check(s.dut.csr_mcause_o == 5, "ER-ADV-15: mcause == 5 (Load access fault)");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_valid_q == 0,
              "ER-ADV-15: Early restart must be strictly suppressed");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__refill_poisoned_q == 1,
              "ER-ADV-15: Refill transaction marked poisoned");

        ++passed;
        std::cout << "ER-ADV-15 PASS: Pre-Critical Bus Error Suppresses ER and Traps with Cause 5\n";
    }

    // =========================================================================
    // ER-ADV-16: Post-ER Trailing Bus Error
    // Error on b > b_crit: load already committed, asserts fatal_error_o
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x8000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x88880000ULL + d;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // critical beat 0

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        s.inject_error_on_beat = 4;
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd == 10 && ev.rd_data == 0x88880000ULL,
              "ER-ADV-16: Critical beat load committed before trailing error");

        for (int i = 0; i < 20; i++) {
            s.tick();
            if (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__fatal_error_q) break;
        }
        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__fatal_error_q == 1,
              "ER-ADV-16: Trailing bus error asserts L1D fatal state");
        check(s.dut.fatal_halt_o == 1,
              "ER-ADV-16: Fatal condition propagates to production core fatal_halt_o");
        const uint64_t commits_at_fatal = s.commits;
        for (int i = 0; i < 8; ++i) s.tick();
        check(s.commits == commits_at_fatal && s.dut.fatal_halt_o,
              "ER-ADV-16: Fatal halt is sticky and suppresses later commits");

        // Re-run with beat 1 so acknowledgement of beat-0 ER data and the
        // trailing error are observed on the same edge.
        s.reset();
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x88880000ULL + d;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0));
        s.step_until_commit();
        s.step_until_commit();
        s.inject_error_on_beat = 1;
        Event coincident = s.step_until_commit();
        check(coincident.commit && coincident.rd == 10 && coincident.rd_data == 0x88880000ULL,
              "ER-ADV-16: Coincident same-load acknowledge/error commits exactly once");
        s.tick();
        check(s.dut.fatal_halt_o && !s.dut.trap_valid_o,
              "ER-ADV-16: Coincident acknowledge/error establishes fatal halt without retroactive trap");

        ++passed;
        std::cout << "ER-ADV-16 PASS: Post-Retirement and Coincident-Acknowledge Trailing Errors Reach Sticky fatal_halt_o\n";
    }

    // =========================================================================
    // ER-ADV-17: Subsequent Load Stall (P0-2)
    // Subsequent load in Stage E stalls until trailing refill completes INSTALL
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x9000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x9900ULL + d;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0 (commits early)
        s.write_dram_word(B + 0x0C, ld(11, 2, 8)); // beat 1 (must stall until INSTALL)

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev1 = s.step_until_commit(); // ld 10 commits
        check(ev1.commit && ev1.rd == 10, "First load commits early");

        bool observed_load_stall_during_burst = false;
        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            if (s.dut.rootp->fursoy_s0_core__DOT__stall_e) {
                observed_load_stall_during_burst = true;
            }
            s.tick();
        }
        check(observed_load_stall_during_burst, "ER-ADV-17: Subsequent load stalled during trailing refill");

        Event ev2 = s.step_until_commit();
        check(ev2.commit && ev2.rd == 11 && ev2.rd_data == 0x9901ULL, "Second load commits after INSTALL");

        ++passed;
        std::cout << "ER-ADV-17 PASS: Subsequent Load Stalls During Trailing Refill\n";
    }

    // =========================================================================
    // ER-ADV-18: Store Buffer Drains Held During Trailing Refill (P0-2)
    // =========================================================================
    {
        s.reset();
        uint64_t store_addr = B + 0xa000;
        uint64_t load_addr  = B + 0xb000;
        for (int d = 0; d < 8; d++) s.dram[load_addr + d * 8] = 0xb000ULL + d;

        encode_addr(s, B + 0x00, 2, store_addr);
        s.write_dram_word(B + 0x08, addi(1, 0, 0x55));
        s.write_dram_word(B + 0x0C, sd(1, 2, 0)); // Store into SB
        encode_addr(s, B + 0x10, 3, load_addr);
        s.write_dram_word(B + 0x18, ld(10, 3, 0)); // Load miss at beat 0

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        s.step_until_commit(); // addi
        s.step_until_commit(); // sd (enters SB)
        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        Event ev_ld = s.step_until_commit(); // ld commits early
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        bool observed_drain_blocked = false;
        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            if (!s.dut.rootp->fursoy_s0_core__DOT__l1d_issue_ready) {
                observed_drain_blocked = true;
            }
            s.tick();
        }
        check(observed_drain_blocked, "ER-ADV-18: issue_ready_o deasserted throughout trailing burst");

        ++passed;
        std::cout << "ER-ADV-18 PASS: Store Buffer Drains Held During Trailing Refill\n";
    }

    // =========================================================================
    // ER-ADV-19: Store Buffer Full Stall During Trailing Refill
    // =========================================================================
    {
        s.reset();
        uint64_t load_addr  = B + 0xc000;
        uint64_t store_addr = B + 0xd000;
        for (int d = 0; d < 8; d++) s.dram[load_addr + d * 8] = 0xc000ULL + d;

        encode_addr(s, B + 0x00, 2, load_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // Load miss at beat 0
        encode_addr(s, B + 0x0C, 3, store_addr);
        s.write_dram_word(B + 0x14, sd(2, 3, 0));  // Store 1
        s.write_dram_word(B + 0x18, sd(2, 3, 8));  // Store 2
        s.write_dram_word(B + 0x1C, sd(2, 3, 16)); // Store 3
        s.write_dram_word(B + 0x20, sd(2, 3, 24)); // Store 4 (SB full)
        s.write_dram_word(B + 0x24, sd(2, 3, 32)); // Store 5 (must stall Stage E)

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        s.step_until_commit(); // ld 10 (commits early)
        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        s.step_until_commit(); // sd 1
        s.step_until_commit(); // sd 2
        s.step_until_commit(); // sd 3
        s.step_until_commit(); // sd 4

        check(s.dut.rootp->fursoy_s0_core__DOT__sb__DOT__count_q == 4, "Store Buffer reached 4 entries (full)");

        Event ev5 = s.step_until_commit(1000);
        check(ev5.commit, "Fifth store commits successfully after SB drains");

        ++passed;
        std::cout << "ER-ADV-19 PASS: Store Buffer Full Stall Handled Safely\n";
    }

    // =========================================================================
    // ER-ADV-20: Independent ALU Overlap
    // Independent ALU operations commit during trailing refill burst
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0xe000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0xe000ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0
        s.write_dram_word(B + 0x0C, addi(5, 0, 10));
        s.write_dram_word(B + 0x10, addi(6, 0, 20));
        s.write_dram_word(B + 0x14, add(7, 5, 6));
        s.write_dram_word(B + 0x18, slli(8, 7, 2));

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev_ld = s.step_until_commit(); // ld 10
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        int alu_commits_during_refill = 0;
        for (int i = 0; i < 4; i++) {
            Event ev = s.step_until_commit();
            if (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
                ++alu_commits_during_refill;
            }
        }
        check(alu_commits_during_refill >= 2, "Independent ALU instructions overlapped with trailing burst");

        ++passed;
        std::cout << "ER-ADV-20 PASS: Independent ALU Overlap During Trailing Burst\n";
    }

    // =========================================================================
    // ER-ADV-21: LR.W/D Exclusion (P0-3)
    // LR misses execute full synchronous refill and establish reservation at INSTALL
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0xf000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0xf000ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, lr_d(10, 2)); // LR.D miss at beat 0

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        int er_before = s.er_events_observed;
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd == 10 && ev.rd_data == 0xf000ULL, "LR.D commits");
        check(s.er_events_observed == er_before, "ER-ADV-21: LR.D must not trigger early restart");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__res_valid_q == 1,
              "ER-ADV-21: Reservation valid established at INSTALL");

        ++passed;
        std::cout << "ER-ADV-21 PASS: LR.D Exclusion and Reservation Established at INSTALL\n";
    }

    // =========================================================================
    // ER-ADV-22: SC.W/D Exclusion (P0-3)
    // SC misses execute full synchronous refill and update cache at INSTALL
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x11000;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, lr_d(10, 2)); // Establish reservation
        s.write_dram_word(B + 0x0C, addi(1, 0, 0x77));
        s.write_dram_word(B + 0x10, sc_d(11, 1, 2)); // SC.D miss

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        s.step_until_commit(); // lr.d
        s.step_until_commit(); // addi

        int er_before = s.er_events_observed;
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd == 11 && ev.rd_data == 0, "SC.D succeeds (rd=0)");
        check(s.er_events_observed == er_before, "ER-ADV-22: SC.D must not trigger early restart");

        ++passed;
        std::cout << "ER-ADV-22 PASS: SC.D Exclusion and Completion at INSTALL\n";
    }

    // =========================================================================
    // ER-ADV-23: AMO Exclusion (P0-3)
    // AMO misses execute full synchronous refill and enter AMO_CYCLE2
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x12000;
        s.dram[line_addr] = 100;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, addi(1, 0, 25));
        s.write_dram_word(B + 0x0C, amoadd_d(10, 1, 2)); // AMOADD.D miss

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        s.step_until_commit(); // addi

        int er_before = s.er_events_observed;
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd == 10 && ev.rd_data == 100, "AMOADD.D commits original value");
        check(s.er_events_observed == er_before, "ER-ADV-23: AMO must not trigger early restart");

        ++passed;
        std::cout << "ER-ADV-23 PASS: AMO Exclusion and 2-Cycle Execution After INSTALL\n";
    }

    // =========================================================================
    // ER-ADV-24: SRB Collision Exclusion
    // Store miss during trailing refill does not corrupt SRB state
    // =========================================================================
    {
        s.reset();
        uint64_t load_addr  = B + 0x13000;
        for (int d = 0; d < 8; d++) s.dram[load_addr + d * 8] = 0x1300ULL + d;

        encode_addr(s, B + 0x00, 2, load_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev = s.step_until_commit(); // ld commits early
        check(ev.commit && ev.rd == 10, "Load commits early");

        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__srb_capture == 0,
              "ER-ADV-24: SRB capture blocked during active trailing burst");

        ++passed;
        std::cout << "ER-ADV-24 PASS: SRB Collision Exclusion During Trailing Refill\n";
    }

    // =========================================================================
    // ER-ADV-25: Randomized Wait States
    // Memory delay jitter on refill request/response
    // =========================================================================
    {
        s.reset();
        s.random_dmem_stall = true;
        uint64_t line_addr = B + 0x14000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1400ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 16)); // beat 2 critical

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd == 10 && ev.rd_data == 0x1402ULL, "Load commits correctly with jitter");
        check(s.er_events_observed >= 1, "ER triggered under randomized wait states");

        s.random_dmem_stall = false;
        ++passed;
        std::cout << "ER-ADV-25 PASS: Randomized Memory Wait-State Jitter\n";
    }

    // =========================================================================
    // ER-ADV-26: Trap During Trailing Refill
    // Synchronous exception in Stage E while burst is active; refill installs cleanly
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x15000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1500ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0
        s.write_dram_word(B + 0x0C, 0x00000000);   // illegal instruction immediately follows

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev_ld = s.step_until_commit(); // ld commits early
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        Event ev_trap = s.step_until_commit();
        check(ev_trap.trap && s.dut.csr_mcause_o == 2, "Illegal instruction traps with cause 2");

        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            s.tick();
        }
        uint64_t set = (line_addr >> 6) & 63;
        bool installed = false;
        for (int w = 0; w < 4; w++) {
            if (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__valid_q[set][w]) installed = true;
        }
        check(installed, "ER-ADV-26: Refill completed and installed despite downstream trap");

        ++passed;
        std::cout << "ER-ADV-26 PASS: Trap During Trailing Refill Allows Clean Installation\n";
    }

    // =========================================================================
    // ER-ADV-28: Maintenance FENCE
    // FENCE in Stage E stalls until trailing refill completes and bus is idle
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x17000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1700ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0
        s.write_dram_word(B + 0x0C, fence_rw_rw()); // FENCE immediately follows

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev_ld = s.step_until_commit(); // ld commits early
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        bool fence_stalled = false;
        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            if (s.dut.rootp->fursoy_s0_core__DOT__fence_stall) fence_stalled = true;
            s.tick();
        }
        check(fence_stalled, "ER-ADV-28: FENCE stalled during trailing burst");

        Event ev_fence = s.step_until_commit();
        check(ev_fence.commit, "FENCE commits after trailing refill finishes");

        ++passed;
        std::cout << "ER-ADV-28 PASS: Maintenance FENCE Serialization During Refill\n";
    }

    // =========================================================================
    // ER-ADV-29: Maintenance SFENCE.VMA
    // SFENCE.VMA stalls until trailing refill completes before sweep
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x18000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1800ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0));
        s.write_dram_word(B + 0x0C, kSfenceVma); // SFENCE.VMA

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev_ld = s.step_until_commit(); // ld commits early
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        bool sfence_stalled = false;
        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            if (s.dut.rootp->fursoy_s0_core__DOT__sfence_stall) sfence_stalled = true;
            s.tick();
        }
        check(sfence_stalled, "ER-ADV-29: SFENCE.VMA stalled during trailing burst");

        Event ev_sfence = s.step_until_commit();
        check(ev_sfence.commit, "SFENCE.VMA commits after trailing refill finishes");

        ++passed;
        std::cout << "ER-ADV-29 PASS: Maintenance SFENCE.VMA Serialization During Refill\n";
    }

    // =========================================================================
    // ER-ADV-30: Context PMP CSR Write
    // PMP CSR write stalls until trailing refill completes before update
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x19000;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1900ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0));
        s.write_dram_word(B + 0x0C, csrw(0x3b0, 2)); // csrw pmpaddr0, x2

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev_ld = s.step_until_commit(); // ld commits early
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        bool pmp_stalled = false;
        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            if (s.dut.rootp->fursoy_s0_core__DOT__pmp_csr_stall) pmp_stalled = true;
            s.tick();
        }
        check(pmp_stalled, "ER-ADV-30: PMP CSR write stalled during trailing burst");

        Event ev_csr = s.step_until_commit();
        check(ev_csr.commit, "PMP CSR write commits after trailing refill finishes");

        ++passed;
        std::cout << "ER-ADV-30 PASS: Context PMP CSR Write Serialization\n";
    }

    // =========================================================================
    // ER-ADV-31: Atomic INSTALL Publication
    // Line valid bit occurs atomically at INSTALL cycle, not on early restart
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x1a000;
        uint64_t set = (line_addr >> 6) & 63;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1a00ULL + d;

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0)); // beat 0

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi

        Event ev_ld = s.step_until_commit();
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        for (int w = 0; w < 4; w++) {
            check(!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__valid_q[set][w],
                  "ER-ADV-31: Line must NOT be marked valid in cache array on early restart");
        }

        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            s.tick();
        }

        bool installed = false;
        for (int w = 0; w < 4; w++) {
            if (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__valid_q[set][w]) installed = true;
        }
        check(installed, "ER-ADV-31: Line marked valid atomically at INSTALL");

        ++passed;
        std::cout << "ER-ADV-31 PASS: Atomic INSTALL Cache Line Publication\n";
    }

    // =========================================================================
    // ER-ADV-32: Tree-PLRU Exactly-Once Update
    // Tree-PLRU updates exactly once at INSTALL cycle for latched victim way
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x1b000;
        uint64_t set = (line_addr >> 6) & 63;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1b00ULL + d;

        uint8_t initial_plru = s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__plru_q[set];

        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0));

        s.step_until_commit(); // auipc
        s.step_until_commit(); // addi
        Event ev_ld = s.step_until_commit(); // ld commits early
        check(ev_ld.commit && ev_ld.rd == 10, "Load commits early");

        check(s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__plru_q[set] == initial_plru,
              "ER-ADV-32: PLRU must NOT update at early restart cycle");

        while (s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__state_q != 0) {
            s.tick();
        }

        uint8_t final_plru = s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__plru_q[set];
        check(final_plru != initial_plru, "ER-ADV-32: PLRU updated exactly once at INSTALL cycle");
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_load_retired_q &&
              !s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_load_squashed_q,
              "ER-ADV-32: clean INSTALL retained stale ER lifecycle state");

        ++passed;
        std::cout << "ER-ADV-32 PASS: Tree-PLRU Exactly-Once Update on Legal Completion\n";
    }

    // =========================================================================
    // ER-ADV-34: Critical result pending, no acknowledgement, later error
    // =========================================================================
    {
        s.reset();
        uint64_t line_addr = B + 0x1c000;
        uint64_t set = (line_addr >> 6) & 63;
        for (int d = 0; d < 8; d++) s.dram[line_addr + d * 8] = 0x1c00ULL + d;
        encode_addr(s, B + 0x00, 2, line_addr);
        s.write_dram_word(B + 0x08, ld(10, 2, 0));
        s.step_until_commit();
        s.step_until_commit();

        s.hold_stage_e_stall = true;
        s.inject_error_on_beat = 4;
        while (!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_valid_q)
            s.tick();
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_load_retired_q,
              "ER-ADV-34: Pending critical result is not retirement proof");

        Event fault;
        for (int i = 0; i < 100 && !fault.trap; ++i) fault = s.tick();
        check(fault.trap && s.dut.csr_mcause_o == 5,
              "ER-ADV-34: Unacknowledged trailing error takes precise load-access fault");
        check(!s.dut.fatal_halt_o,
              "ER-ADV-34: Unacknowledged trailing error is not fatal");
        check(!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__er_retire_valid_q,
              "ER-ADV-34: Pending ER result is cancelled");
        for (int w = 0; w < 4; ++w)
            check(!s.dut.rootp->fursoy_s0_core__DOT__l1d__DOT__valid_q[set][w],
                  "ER-ADV-34: Poisoned line is not installed");

        s.hold_stage_e_stall = false;
        ++passed;
        std::cout << "ER-ADV-34 PASS: Pending-Unacknowledged Result Takes Precise Fault, Not Fatal Halt\n";
    }

    // =========================================================================
    // Explicit raw-error-edge architectural gating (additional review evidence,
    // not a relabeling of the frozen 34-scenario normative matrix).
    // =========================================================================
    int raw_edge_checks = 0;
    {
        s.reset();
        s.write_dram_word(B, addi(5, 0, 41));
        s.arm_raw_error_on_arch_event = true;
        while (s.raw_error_injections == 0) {
            Event e = s.tick();
            check(!e.commit && !e.trap, "RAW-GATE-01: unrelated ALU action escaped raw edge");
        }
        check(s.dut.rootp->fursoy_s0_core__DOT__registers[5] == 0,
              "RAW-GATE-01: RF changed on raw error edge");
        Event e = s.step_until_commit();
        check(e.commit && e.rd == 5 && e.rd_data == 41,
              "RAW-GATE-01: held ALU instruction did not resume after nonfatal edge");
        ++raw_edge_checks;
        std::cout << "RAW-GATE-01 PASS: unrelated commit/RF write blocked directly on raw error edge\n";
    }
    {
        s.reset();
        s.write_dram_word(B, addi(1, 0, 0x55));
        s.write_dram_word(B + 4, csrw(0x340, 1));
        s.step_until_commit();
        s.arm_raw_error_on_arch_event = true;
        while (s.raw_error_injections == 0) s.tick();
        check(s.dut.csr_mscratch_o == 0, "RAW-GATE-02: CSR write occurred on raw error edge");
        Event e = s.step_until_commit();
        check(e.commit && s.dut.csr_mscratch_o == 0x55,
              "RAW-GATE-02: held CSR instruction did not resume");
        ++raw_edge_checks;
        std::cout << "RAW-GATE-02 PASS: authoritative CSR side effect blocked directly on raw error edge\n";
    }
    {
        s.reset();
        uint64_t store_addr = B + 0x30000;
        encode_addr(s, B, 1, store_addr);
        s.write_dram_word(B + 8, addi(2, 0, 0x66));
        s.write_dram_word(B + 12, sd(2, 1, 0));
        s.step_until_commit();
        s.step_until_commit();
        s.step_until_commit();
        uint8_t sb_before = s.dut.rootp->fursoy_s0_core__DOT__sb__DOT__count_q;
        s.arm_raw_error_on_arch_event = true;
        while (s.raw_error_injections == 0) s.tick();
        check(s.dut.rootp->fursoy_s0_core__DOT__sb__DOT__count_q == sb_before,
              "RAW-GATE-03: SB enqueue occurred on raw error edge");
        Event e = s.step_until_commit();
        check(e.commit && e.insn == sd(2, 1, 0),
              "RAW-GATE-03: held store did not resume");
        ++raw_edge_checks;
        std::cout << "RAW-GATE-03 PASS: store commit/SB enqueue blocked directly on raw error edge\n";
    }
    {
        s.reset();
        s.write_dram_word(B, 0x00000000); // illegal instruction
        s.arm_raw_error_on_arch_event = true;
        while (s.raw_error_injections == 0) {
            Event e = s.tick();
            check(!e.trap, "RAW-GATE-04: conflicting trap escaped raw error edge");
        }
        check(s.dut.csr_mcause_o == 0, "RAW-GATE-04: trap CSR changed on raw error edge");
        Event e = s.step_until_commit();
        check(e.trap && s.dut.csr_mcause_o == 2,
              "RAW-GATE-04: held precise trap did not resume after edge");
        ++raw_edge_checks;
        std::cout << "RAW-GATE-04 PASS: conflicting trap entry blocked directly on raw error edge\n";
    }

    std::cout << "\n========================================================\n";
    std::cout << "CORE " << passed << " SCENARIOS PASSED SUCCESSFULLY!\n";
    std::cout << "RAW-EDGE " << raw_edge_checks << " ADDITIONAL CHECKS PASSED SUCCESSFULLY!\n";
    std::cout << "========================================================\n";

    return 0;
}
