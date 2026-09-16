// Focused L1I-ER v1 (Early Restart & Streaming) Adversarial Verification Suite
// Normative Baseline: docs/architecture/l1i-refill-opt-v1.md (Milestone A — Frozen)
// Tests: REFILL-ADV-01 through REFILL-ADV-16

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
static uint32_t ld(uint32_t rd, uint32_t rs1, int32_t imm) {
    return (uint32_t(imm & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
}
static uint32_t sd(uint32_t rs2, uint32_t rs1, int32_t imm) {
    uint32_t uimm = uint32_t(imm);
    return ((uimm >> 5) & 0x7f) << 25 | (rs2 << 20) | (rs1 << 15) | (3 << 12) | (uimm & 0x1f) << 7 | 0x23;
}
static uint32_t fence_i() {
    return 0x0000100f;
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

    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    bool dmem_rsp_error = false;
    int dmem_delay_counter = 0;

    unsigned imem_refill_requests = 0;
    unsigned imem_rsp_count = 0;
    uint64_t cycles = 0;
    uint64_t commits = 0;

    bool inject_imem_error_on_beat = false;
    int inject_error_beat_idx = -1;
    int dmem_stall_cycles = 0;

    // Telemetry counts
    unsigned early_restart_events = 0;
    unsigned streaming_hit_events = 0;
    unsigned refill_abort_events = 0;

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

    uint8_t get_set_plru(int set_idx) {
        int bit_offset = set_idx * 3;
        int word_idx = bit_offset / 32;
        int sub_bit = bit_offset % 32;
        uint64_t w0 = dut.rootp->fursoy_s0_core__DOT__l1i__DOT__plru_q[word_idx];
        uint64_t w1 = (word_idx + 1 < 6) ? dut.rootp->fursoy_s0_core__DOT__l1i__DOT__plru_q[word_idx + 1] : 0;
        uint64_t combined = (w1 << 32) | w0;
        return (combined >> sub_bit) & 7;
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
        imem_refill_requests = 0;
        imem_rsp_count = 0;
        commits = 0;
        inject_imem_error_on_beat = false;
        inject_error_beat_idx = -1;
        dmem_stall_cycles = 0;
        early_restart_events = 0;
        streaming_hit_events = 0;
        refill_abort_events = 0;
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

        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_early_restart_event_o) ++early_restart_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_streaming_hit_event_o) ++streaming_hit_events;
        if (dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_refill_abort_event_o)  ++refill_abort_events;

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
            ++imem_refill_requests;
            uint64_t req_addr = dut.imem_req_addr_o;
            imem_rsp_data = read_dram_dword(req_addr);
            imem_rsp_pending = true;

            int cur_beat = int((req_addr >> 3) & 7);
            imem_rsp_error = (inject_imem_error_on_beat && cur_beat == inject_error_beat_idx);
            imem_delay_counter = 0;
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
                dmem_delay_counter = dmem_stall_cycles;
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

    Event step_until_commit(int max_cycles = 100) {
        for (int i = 0; i < max_cycles; i++) {
            Event ev = tick();
            if (ev.commit || ev.trap) return ev;
        }
        throw std::runtime_error("Timeout waiting for commit/trap");
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    CoreSim s;
    unsigned passed = 0;
    std::cout << "Starting L1I-ER v1 Adversarial Verification Suite (REFILL-ADV-01..16)...\n";

    // -------------------------------------------------------------------------
    // REFILL-ADV-01: Stage-E Stalled when Critical Beat Arrives
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B, addi(5, 0, 123));
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        // Step until Beat 0 is about to arrive
        s.tick(); // FETCH_REQ -> FETCH_CHECK
        s.tick(); // FETCH_CHECK -> REFILL_REQ
        s.tick(); // REFILL_REQ -> REFILL_RSP
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__state_q == 4, "ADV-01: Must be in REFILL_RSP");

        // When Beat 0 arrives:
        s.tick(); // Beat 0 arrives and registers into held_*
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q == 1, "ADV-01: Critical beat must be held");
        uint32_t insn_captured = s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_insn_q;
        check(insn_captured == addi(5, 0, 123), "ADV-01: Held instruction must match word 0");

        // Verify trailing beats continue to handshake
        unsigned rsp_start = s.imem_rsp_count;
        for (int i = 0; i < 14; i++) s.tick();
        check(s.imem_rsp_count > rsp_start, "ADV-01: Trailing beats must continue handshaking");

        // Verify line installs on Beat 7
        check(s.is_line_valid(0, 0), "ADV-01: Line must install after trailing beats finish");
        ++passed;
        std::cout << "REFILL-ADV-01 PASS: Stage-E Stalled on Critical Beat Arrival\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-02: Critical Instruction Commits, Trailing Beat Errors
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 11)); // Word 0 commits at Beat 0
        s.write_dram_word(B + 0x04, jal(0, 0x40));   // Jump away to safe line before error
        for (int w = 2; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        // Safe landing line
        constexpr uint64_t SAFE = B + 0x40;
        s.write_dram_word(SAFE, addi(2, 0, 22));
        for (int w = 1; w < 16; w++) s.write_dram_word(SAFE + w * 4, NOP);

        // Inject bus error on Beat 5 of line B
        s.inject_imem_error_on_beat = true;
        s.inject_error_beat_idx = 5;

        Event ev1 = s.step_until_commit();
        check(ev1.commit && ev1.rd == 1 && ev1.rd_data == 11, "ADV-02: Critical insn must commit cleanly");
        check(!ev1.trap, "ADV-02: No trap on early restart");

        // Let burst finish
        for (int i = 0; i < 30; i++) s.tick();

        // Line must NOT be installed due to error on Beat 5
        check(!s.is_line_valid(0, 0), "ADV-02: Erroneous line must NOT be installed in cache");
        s.inject_imem_error_on_beat = false;
        ++passed;
        std::cout << "REFILL-ADV-02 PASS: Critical Commits, Trailing Beat Errors, Line Discarded\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-03: Poisoned Trailing Beat Later Demanded (Precise Fault)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 1)); // Beat 0
        s.write_dram_word(B + 0x04, addi(2, 0, 2)); // Beat 0
        s.write_dram_word(B + 0x08, addi(3, 0, 3)); // Beat 1
        s.write_dram_word(B + 0x0C, addi(4, 0, 4)); // Beat 1
        s.write_dram_word(B + 0x10, addi(5, 0, 5)); // Beat 2: POISONED!
        for (int w = 5; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.inject_imem_error_on_beat = true;
        s.inject_error_beat_idx = 2; // Beat 2 error

        // Word 0 commits
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd_data == 1, "ADV-03: Word 0 must commit");
        ev = s.step_until_commit();
        check(ev.commit && ev.rd_data == 2, "ADV-03: Word 1 must commit");
        ev = s.step_until_commit();
        check(ev.commit && ev.rd_data == 3, "ADV-03: Word 2 must commit");
        ev = s.step_until_commit();
        check(ev.commit && ev.rd_data == 4, "ADV-03: Word 3 must commit");

        // Demanding Word 4 (Beat 2) must raise precise Instruction Access Fault
        ev = s.step_until_commit();
        check(ev.trap, "ADV-03: Demanding poisoned beat must raise synchronous trap");
        check(ev.pc == B + 0x10, "ADV-03: Trap PC must precisely match poisoned instruction PC");
        check(s.dut.csr_mcause_o == 1, "ADV-03: Trap mcause must be 1 (Instruction Access Fault)");
        check(s.dut.csr_mtval_o == B + 0x10, "ADV-03: mtval must match exact poisoned PC");

        s.inject_imem_error_on_beat = false;
        ++passed;
        std::cout << "REFILL-ADV-03 PASS: Poisoned Trailing Beat Later Demanded (Precise Fault)\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-04: Poisoned Trailing Beat Never Demanded
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, jal(0, 0x40)); // Word 0 jumps away immediately
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        constexpr uint64_t TARGET = B + 0x40;
        s.write_dram_word(TARGET, addi(1, 0, 55));
        for (int w = 1; w < 16; w++) s.write_dram_word(TARGET + w * 4, NOP);

        // Inject error on Beat 4 of line B
        s.inject_imem_error_on_beat = true;
        s.inject_error_beat_idx = 4;

        Event ev = s.step_until_commit(); // jal commits
        check(!ev.trap, "ADV-04: JAL must not trap");

        ev = s.step_until_commit(); // TARGET addi commits
        check(ev.commit && ev.rd == 1 && ev.rd_data == 55, "ADV-04: Target instruction must commit");
        check(!ev.trap, "ADV-04: Target must commit without any retroactive exception");

        // Line B must not be valid
        check(!s.is_line_valid(0, 0), "ADV-04: Poisoned line B must not be installed");
        s.inject_imem_error_on_beat = false;
        ++passed;
        std::cout << "REFILL-ADV-04 PASS: Poisoned Trailing Beat Never Demanded (Zero Trap)\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-05: Maintenance Before Critical Beat
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL; // Line 0
        constexpr uint64_t C = 0x80000040ULL; // Line 1
        for (int w = 0; w < 15; w++) s.write_dram_word(B + w * 4, NOP);
        // Word 15 of Line 0 jumps to Line 1 at offset 0x20 (Beat 4)
        s.write_dram_word(B + 0x3C, jal(0, 0x24)); // 0x8000003C + 0x24 = 0x80000060

        s.write_dram_word(C + 0x20, addi(1, 0, 88)); // Beat 4 is critical beat of Line 1
        for (int w = 0; w < 16; w++) {
            if (w != 8) s.write_dram_word(C + w * 4, NOP);
        }

        // Execute Line 0 cleanly to Beat 7
        for (int w = 0; w < 16; w++) {
            Event ev = s.step_until_commit();
            check(ev.commit, "ADV-05: Line 0 instruction commits");
        }
        check(s.is_line_valid(0, 0), "ADV-05: Line 0 must be installed");

        // Wait until Line 1 starts refill
        while (s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__state_q != 3) s.tick(); // REFILL_REQ for Line 1
        s.tick(); // Beat 0 rsp wait
        s.tick(); // Beat 0 rsp / Beat 1 req
        s.tick(); // Beat 1 rsp wait

        // On Beat 1 (before critical beat 4), simulate FENCE.I / PMP flush abort
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_abort_q = 1;
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q = 0;
        for (int i = 0; i < 8; i++) s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__valid_q[i] = 0;

        // Step until Beat 4 arrives
        for (int i = 0; i < 6; i++) s.tick();

        // Verify early restart was suppressed
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__early_restarted_q == 0,
              "ADV-05: Early restart must be suppressed after abort");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q == 0,
              "ADV-05: held_valid_q must remain 0");

        // Drain burst
        for (int i = 0; i < 20; i++) s.tick();
        check(!s.is_line_valid(1, 0), "ADV-05: Aborted line must not be installed");
        ++passed;
        std::cout << "REFILL-ADV-05 PASS: Maintenance Before Critical Beat (Suppressed Early Restart)\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-06: Maintenance while Critical Instruction Buffered under Stall
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 99));
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.tick(); // FETCH_REQ -> FETCH_CHECK
        s.tick(); // FETCH_CHECK -> REFILL_REQ
        s.tick(); // REFILL_REQ -> REFILL_RSP
        s.tick(); // Clock Beat 0 -> held_* becomes valid!
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q == 1,
              "ADV-06: Critical instruction must be buffered");

        // While buffered in held_*, simulate FENCE.I abort
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_abort_q = 1;
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q = 0;
        for (int i = 0; i < 8; i++) s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__valid_q[i] = 0;
        s.tick();

        // Verify held_valid_q was immediately revoked
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q == 0,
              "ADV-06: held_valid_q must be immediately revoked by FENCE.I");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_abort_q == 1,
              "ADV-06: refill_abort_q must be asserted");

        // Drain remaining beats
        for (int i = 0; i < 20; i++) s.tick();
        check(!s.is_line_valid(0, 0), "ADV-06: Aborted line must not install");
        ++passed;
        std::cout << "REFILL-ADV-06 PASS: Maintenance Revokes Buffered Instruction Immediately\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-07: Maintenance after Early Restart
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        constexpr uint64_t C = 0x80000040ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 33)); // Early restart at Beat 0
        s.write_dram_word(B + 0x04, fence_i());      // FENCE.I executes during refill
        s.write_dram_word(B + 0x08, jal(0, 0x40));   // Jump to Line 1 (0x80000048)
        for (int w = 3; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.write_dram_word(C + 0x08, addi(2, 0, 44));
        for (int w = 0; w < 16; w++) {
            if (w != 2) s.write_dram_word(C + w * 4, NOP);
        }

        Event ev1 = s.step_until_commit();
        check(ev1.commit && ev1.rd == 1 && ev1.rd_data == 33, "ADV-07: Early restart insn commits");

        // FENCE.I commits
        Event ev2 = s.step_until_commit();
        check(ev2.commit && ev2.insn == fence_i(), "ADV-07: FENCE.I commits during refill");
        check(!s.is_line_valid(0, 0), "ADV-07: Cache valid cleared by FENCE.I");

        // Next instruction (JAL at B + 0x08)
        Event ev3 = s.step_until_commit();
        check(ev3.commit, "ADV-07: JAL commits");

        // Drain Line 0 original burst
        for (int i = 0; i < 25; i++) s.tick();

        // Line 0 must NOT have been installed by the aborted refill
        check(!s.is_line_valid(0, 0), "ADV-07: Refilling line must NOT install after FENCE.I");
        ++passed;
        std::cout << "REFILL-ADV-07 PASS: Maintenance After Early Restart (Discards Refill)\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-08: Branch Redirect Immediately After Early Restart
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, beq(0, 0, 0x40)); // Taken branch at Word 0
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        constexpr uint64_t TARGET = B + 0x40;
        s.write_dram_word(TARGET, addi(2, 0, 44));
        for (int w = 1; w < 16; w++) s.write_dram_word(TARGET + w * 4, NOP);

        Event ev = s.step_until_commit(); // beq commits
        check(ev.commit, "ADV-08: Branch must commit");

        // Per Option A, taken branch redirect during refill discards line B at Beat 7
        while (s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__state_q == 3 ||
               s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__state_q == 4) {
            s.tick();
        }

        check(!s.is_line_valid(0, 0), "ADV-08: Option A requires discarding line on redirect");

        // Target executes cleanly
        Event ev2 = s.step_until_commit();
        check(ev2.commit && ev2.rd == 2 && ev2.rd_data == 44, "ADV-08: Target must commit");
        ++passed;
        std::cout << "REFILL-ADV-08 PASS: Branch Redirect Immediately After Early Restart (Option A)\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-09: Branch Redirect while Critical Instruction Held Under Stall
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 55));
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.tick(); // REQ -> CHECK
        s.tick(); // CHECK -> REFILL_REQ
        s.tick(); // REFILL_REQ -> REFILL_RSP
        s.tick(); // Beat 0 arrives -> held_valid_q == 1
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q == 1, "ADV-09: Instruction held");

        // Simulate redirect abort while instruction is held
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_abort_q = 1;
        s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q = 0;
        s.tick();

        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__held_valid_q == 0,
              "ADV-09: Buffered instruction must be revoked on redirect");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_abort_q == 1,
              "ADV-09: refill_abort_q must be asserted");

        // Drain burst
        for (int i = 0; i < 20; i++) s.tick();
        check(!s.is_line_valid(0, 0), "ADV-09: Aborted line must not install");
        ++passed;
        std::cout << "REFILL-ADV-09 PASS: Redirect while Critical Instruction Held Under Stall\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-10: Full-Line Install Prohibited on Error (Tree-PLRU Untouched)
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 66));
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        uint8_t plru_before = s.get_set_plru(0);

        // Beat 6 bus error
        s.inject_imem_error_on_beat = true;
        s.inject_error_beat_idx = 6;

        Event ev = s.step_until_commit(); // Word 0 commits early
        check(ev.commit && ev.rd == 1 && ev.rd_data == 66, "ADV-10: Early restart commits");

        // Wait for Beat 7
        for (int i = 0; i < 25; i++) s.tick();

        check(!s.is_line_valid(0, 0), "ADV-10: Line must NOT be installed");
        uint8_t plru_after = s.get_set_plru(0);
        check(plru_after == plru_before, "ADV-10: Tree-PLRU must NOT update on error line");
        s.inject_imem_error_on_beat = false;
        ++passed;
        std::cout << "REFILL-ADV-10 PASS: Full-Line Install Prohibited on Error (Tree-PLRU Untouched)\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-11: Hardware Reset During Partial Refill
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 77));
        for (int w = 1; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.tick(); // REQ -> CHECK
        s.tick(); // CHECK -> REFILL_REQ
        s.tick(); // REFILL_REQ -> REFILL_RSP
        s.tick(); // Beat 0
        s.tick(); // Beat 1 req
        s.tick(); // Beat 1 rsp
        s.tick(); // Beat 2 req
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_beat_cnt == 2,
              "ADV-11: Refill in flight at Beat 2");

        // Assert reset
        s.dut.rst_i = 1;
        s.tick();
        check(s.dut.imem_req_valid_o == 0, "ADV-11: imem_req_valid_o must be 0 in reset");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__state_q == 0, "ADV-11: State must be FETCH_REQ");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__refill_beat_valid_q == 0, "ADV-11: Beat valids cleared");

        // Deassert reset
        s.dut.rst_i = 0;
        s.tick();
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__state_q == 1, "ADV-11: Transition to FETCH_CHECK on RESET_PC");
        ++passed;
        std::cout << "REFILL-ADV-11 PASS: Hardware Reset During Partial Refill Returns Cleanly\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-12: Back-to-Back Demand Misses
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL; // Set 0
        constexpr uint64_t C = 0x80000040ULL; // Set 1
        for (int w = 0; w < 16; w++) s.write_dram_word(B + w * 4, addi(1, 1, 1));
        s.write_dram_word(C + 0x00, addi(2, 0, 99));
        for (int w = 1; w < 16; w++) s.write_dram_word(C + w * 4, NOP);

        // Execute line B
        for (int w = 0; w < 16; w++) {
            Event ev = s.step_until_commit();
            check(ev.commit, "ADV-12: Line B sequential insn commits");
        }
        check(s.is_line_valid(0, 0), "ADV-12: Line B must be installed");

        // Immediate demand miss on Line C
        Event ev = s.step_until_commit();
        check(ev.commit && ev.rd == 2 && ev.rd_data == 99, "ADV-12: Line C first insn commits");

        // Drain line C refill
        while (!s.is_line_valid(1, 0)) s.tick();
        check(s.is_line_valid(1, 0), "ADV-12: Line C must be installed");
        ++passed;
        std::cout << "REFILL-ADV-12 PASS: Back-to-Back Demand Misses Clean Handoff\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-13: Exactly-Once Telemetry Under Long Stage-E Stall
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        // Word 0 is LD which stalls Stage E
        s.write_dram_word(B + 0x00, ld(1, 0, 0x80001000ULL));
        s.write_dram_word(B + 0x04, addi(2, 0, 200));
        for (int w = 2; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        // Delay DMEM by 60 cycles to stall Stage E
        s.dmem_stall_cycles = 60;

        // Step to critical beat arrival
        s.tick(); // REQ -> CHECK
        s.tick(); // CHECK -> REFILL_REQ
        s.tick(); // REFILL_REQ -> REFILL_RSP
        s.early_restart_events = 0;

        s.tick(); // Beat 0 arrives -> early restart strobe fires
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_early_restart_event_o == 1,
              "ADV-13: Early restart strobe must assert on Cycle T+1");
        check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_early_restart_saved_cycles_o == 14,
              "ADV-13: Saved cycles for Beat 0 must be 14");

        // Simulate 50 cycles of stall
        for (int i = 0; i < 50; i++) {
            s.tick();
            check(s.dut.rootp->fursoy_s0_core__DOT__l1i__DOT__l1i_early_restart_event_o == 0,
                  "ADV-13: Early restart strobe must NEVER re-assert during stall");
        }
        check(s.early_restart_events == 1, "ADV-13: Early restart event count must be EXACTLY 1");
        s.dmem_stall_cycles = 0;
        ++passed;
        std::cout << "REFILL-ADV-13 PASS: Exactly-Once Telemetry Under 50-Cycle Stall\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-14: Tree-PLRU Updated Exactly Once on Clean Beat 7
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        for (int w = 0; w < 16; w++) s.write_dram_word(B + w * 4, addi(1, 0, w));

        check(s.get_set_plru(0) == 0, "ADV-14: Initial PLRU is 0");

        // Let refill complete to Beat 7
        while (!s.is_line_valid(0, 0)) s.tick();

        // Installed into Way 0 -> PLRU updates for way 0: bits {plru[0]=1, plru[1]=1} -> plru = 3
        uint8_t plru_after = s.get_set_plru(0);
        check(plru_after == 3, "ADV-14: Tree-PLRU must update to 3 for Way 0 installation");

        // Step 10 more cycles with no new accesses; PLRU must remain 3
        for (int i = 0; i < 10; i++) s.tick();
        check(s.get_set_plru(0) == 3, "ADV-14: Tree-PLRU must remain stable");
        ++passed;
        std::cout << "REFILL-ADV-14 PASS: Tree-PLRU Updated Exactly Once on Clean Beat 7\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-15: Stale Refill Identity Across SATP Write
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        constexpr uint64_t C = 0x80000040ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 1));
        // Word 1 writes to satp CSR (csr 0x180)
        s.write_dram_word(B + 0x04, csrw(0x180, 0));
        // Word 2 jumps to Line 1 so Line 0 is not re-fetched
        s.write_dram_word(B + 0x08, jal(0, 0x40));
        for (int w = 3; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.write_dram_word(C + 0x08, addi(2, 0, 99));
        for (int w = 0; w < 16; w++) {
            if (w != 2) s.write_dram_word(C + w * 4, NOP);
        }

        Event ev1 = s.step_until_commit(); // Word 0 commits
        check(ev1.commit, "ADV-15: Word 0 commits");

        Event ev2 = s.step_until_commit(); // CSR satp commits, flushes pipeline & aborts Line 0
        check(ev2.commit, "ADV-15: satp CSR commits");

        Event ev3 = s.step_until_commit(); // JAL commits
        check(ev3.commit, "ADV-15: JAL commits");

        // Drain refill burst of Line 0
        for (int i = 0; i < 30; i++) s.tick();

        check(!s.is_line_valid(0, 0), "ADV-15: Line must NOT be installed across satp CSR write");
        ++passed;
        std::cout << "REFILL-ADV-15 PASS: Stale Refill Discarded Across SATP Write\n";
    }

    // -------------------------------------------------------------------------
    // REFILL-ADV-16: Sequential Streaming Hit in Refill Buffer
    // -------------------------------------------------------------------------
    {
        s.reset();
        constexpr uint64_t B = 0x80000000ULL;
        s.write_dram_word(B + 0x00, addi(1, 0, 10));
        s.write_dram_word(B + 0x04, addi(2, 0, 20));
        s.write_dram_word(B + 0x08, addi(3, 0, 30));
        for (int w = 3; w < 16; w++) s.write_dram_word(B + w * 4, NOP);

        s.streaming_hit_events = 0;

        // Step Word 0
        Event ev0 = s.step_until_commit();
        check(ev0.commit && ev0.rd == 1 && ev0.rd_data == 10, "ADV-16: Word 0 commits via early restart");

        // Step Word 1: should commit immediately from Beat 0 in refill_buf_q
        Event ev1 = s.step_until_commit();
        check(ev1.commit && ev1.rd == 2 && ev1.rd_data == 20, "ADV-16: Word 1 commits via streaming hit");
        check(s.streaming_hit_events >= 1, "ADV-16: Streaming hit event must fire");

        // Step Word 2: waits for Beat 1, then commits
        Event ev2 = s.step_until_commit();
        check(ev2.commit && ev2.rd == 3 && ev2.rd_data == 30, "ADV-16: Word 2 commits after pending beat arrival");

        // Allow rest of line to install
        while (!s.is_line_valid(0, 0)) s.tick();
        check(s.is_line_valid(0, 0), "ADV-16: Full line installs cleanly at Beat 7");
        ++passed;
        std::cout << "REFILL-ADV-16 PASS: Sequential Streaming Hit in Refill Buffer\n";
    }

    std::cout << "\n======================================================\n";
    std::cout << "ALL 16 L1I-ER ADVERSARIAL SCENARIOS PASSED!\n";
    std::cout << "======================================================\n";
    return 0;
}
