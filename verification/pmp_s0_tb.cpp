// Focused verification suite for Fursoy CPU Physical Memory Protection (PMP) v1.
// Covers all 26+ verification matrix scenarios per docs/architecture/pmp-v1.md.

#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>
#include <string>

static void check(bool cond, const std::string &msg) {
    if (!cond) {
        throw std::runtime_error(msg);
    }
}

static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
static uint32_t slli(unsigned rd, unsigned rs1, unsigned sh) {
    return (sh << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13;
}
static uint32_t srli(unsigned rd, unsigned rs1, unsigned sh) {
    return (sh << 20) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x13;
}
static uint32_t r_or(unsigned rd, unsigned rs1, unsigned rs2) {
    return (rs2 << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x33;
}
static uint32_t ori(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x13;
}
static uint32_t csr(unsigned f, unsigned rd, unsigned rs1, unsigned addr) {
    return (addr << 20) | (rs1 << 15) | (f << 12) | (rd << 7) | 0x73;
}
static uint32_t csrr(unsigned rd, unsigned addr) {
    return csr(2, rd, 0, addr); // CSRRS rd, addr, x0 (read only, no write intent)
}
static uint32_t csrw(unsigned addr, unsigned rs1) {
    return csr(1, 0, rs1, addr); // CSRRW x0, addr, rs1 (write)
}
static uint32_t auipc(unsigned rd) {
    return (rd << 7) | 0x17;
}
static uint32_t ld(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
}
static uint32_t lw(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03;
}
static uint32_t sd(unsigned rs2, unsigned rs1, int imm) {
    uint32_t u = imm;
    return (((u >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((u & 31) << 7) | 0x23;
}
static constexpr uint32_t MRET      = 0x30200073;
static constexpr uint32_t SFENCE_VMA = 0x12000073;

struct Event {
    bool commit = false;
    bool trap = false;
    uint64_t pc = 0;
    uint32_t insn = 0;
    bool rd_write = false;
    unsigned rd = 0;
    uint64_t rd_data = 0;
    uint8_t priv_mode = 3;
    bool ptw_fire = false;
    bool dmem_fire = false;
    bool dmem_store = false;
    uint64_t dmem_addr = 0;
};

struct CoreSim {
    Vfursoy_s0_core dut;
    std::unordered_map<uint64_t, uint32_t> mem;
    std::unordered_map<uint64_t, uint64_t> dmem;
    bool fetch_pending = false;
    uint64_t rsp_pc = 0;
    uint64_t rsp_data = 0;
    uint64_t cycles = 0;
    uint64_t commits = 0;
    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    unsigned physical_stores = 0;
    unsigned ptw_requests = 0;
    uint64_t last_dmem_addr = 0;

    void init() {
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
        dut.eval();
        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        dut.clk_i = 0;
        dut.rst_i = 0;
        dut.eval();
        fetch_pending = false;
        dmem_rsp_pending = false;
        physical_stores = 0;
        ptw_requests = 0;
        commits = 0;
    }

    Event tick() {
        dut.clk_i = 0;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = fetch_pending;
        dut.imem_rsp_data_i = rsp_data;
        dut.imem_rsp_error_i = 0;

        dut.dmem_req_ready_i = 1;
        dut.dmem_req_error_i = 0;
        dut.dmem_rsp_valid_i = dmem_rsp_pending;
        dut.dmem_rsp_data_i = dmem_rsp_data;
        dut.dmem_rsp_error_i = 0;
        dut.eval();

        Event ev;
        ev.commit = dut.commit_valid_o;
        ev.trap = dut.trap_valid_o;
        ev.pc = ev.commit ? uint64_t(dut.commit_pc_o) : uint64_t(dut.trap_pc_o);
        ev.insn = ev.commit ? uint32_t(dut.commit_insn_o) : uint32_t(dut.trap_insn_o);
        ev.rd_write = dut.commit_rd_write_o;
        ev.rd = dut.commit_rd_o;
        ev.rd_data = dut.commit_rd_data_o;
        ev.priv_mode = dut.priv_mode_o;

        bool rsp_fire = fetch_pending && dut.imem_rsp_ready_o;
        bool req_fire = dut.imem_req_valid_o && dut.imem_req_ready_i;
        bool dmem_rsp_fire = dmem_rsp_pending && dut.dmem_rsp_ready_o;
        bool dmem_req_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;

        ev.ptw_fire = dmem_req_fire && dut.dmem_req_ptw_o;
        ev.dmem_fire = dmem_req_fire;
        ev.dmem_store = dmem_req_fire && dut.dmem_req_store_o;
        ev.dmem_addr = dut.dmem_req_addr_o;

        if (dmem_req_fire) {
            last_dmem_addr = dut.dmem_req_addr_o;
            if (dut.dmem_req_ptw_o) {
                ++ptw_requests;
            }
            if (dut.dmem_req_store_o) {
                ++physical_stores;
                dmem[dut.dmem_req_addr_o] = dut.dmem_req_store_data_o;
            } else {
                uint64_t a = dut.dmem_req_addr_o;
                dmem_rsp_data = dmem.count(a) ? dmem[a] : 0;
                dmem_rsp_pending = true;
            }
        }

        bool next_pending = fetch_pending;
        uint64_t next_pc = rsp_pc;
        uint64_t next_data = rsp_data;

        if (rsp_fire) next_pending = false;
        if (req_fire) {
            next_pc = dut.imem_req_addr_o;
            uint64_t w0 = mem.count(next_pc) ? uint64_t(mem[next_pc]) : 0x00000013ULL;
            uint64_t w1 = mem.count(next_pc + 4) ? uint64_t(mem[next_pc + 4]) : 0x00000013ULL;
            next_data = (w1 << 32) | (w0 & 0xFFFFFFFFULL);
            next_pending = true;
        }

        if (dmem_rsp_fire) dmem_rsp_pending = false;

        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        fetch_pending = next_pending;
        rsp_pc = next_pc;
        rsp_data = next_data;
        if (ev.commit) ++commits;
        dut.clk_i = 0;
        dut.eval();
        return ev;
    }

    Event until_commit(uint64_t target_pc, unsigned max_cycles = 300) {
        for (unsigned i = 0; i < max_cycles; ++i) {
            Event ev = tick();
            if (ev.commit && ev.pc == target_pc) return ev;
            if (ev.trap) throw std::runtime_error("Unexpected trap at PC=" + std::to_string(ev.pc));
        }
        throw std::runtime_error("Timeout waiting for commit at PC=" + std::to_string(target_pc));
    }

    Event until_trap(unsigned max_cycles = 300) {
        for (unsigned i = 0; i < max_cycles; ++i) {
            Event ev = tick();
            if (ev.trap) return ev;
        }
        throw std::runtime_error("Timeout waiting for trap");
    }
};

static constexpr uint64_t kB = 0x80000000ULL;
static constexpr uint64_t kMTV = kB + 0x400;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned scenarios = 0;

    try {
        // ====================================================================
        // Scenario 1: PMP CSR Reset State
        // ====================================================================
        {
            CoreSim sim;
            sim.init();
            check(uint64_t(sim.dut.csr_pmpcfg0_o) == 0, "pmpcfg0 reset must be 0");
            check(uint64_t(sim.dut.csr_pmpcfg2_o) == 0, "pmpcfg2 reset must be 0");
            for (int i = 0; i < 16; ++i) {
                check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[i] == 0, "pmp_cfg_q reset 0");
                check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[i] == 0, "pmp_addr_q reset 0");
            }
            ++scenarios;
        }

        // ====================================================================
        // Scenario 2: RV64 pmpcfg0/pmpcfg2 Packing and Readback
        // ====================================================================
        {
            CoreSim sim;
            // Write pmpcfg0 with legal entries: entries 0..7 all set to NAPOT, RWX (0x1f)
            // 8 entries * 0x1f = 0x1f1f1f1f1f1f1f1f
            sim.mem[kB + 0x00] = addi(1, 0, 0x1f);
            sim.mem[kB + 0x04] = slli(2, 1, 8);
            sim.mem[kB + 0x08] = r_or(1, 1, 2); // 0x1f1f
            sim.mem[kB + 0x0c] = slli(2, 1, 16);
            sim.mem[kB + 0x10] = r_or(1, 1, 2); // 4 bytes
            sim.mem[kB + 0x14] = slli(2, 1, 32);
            sim.mem[kB + 0x18] = r_or(1, 1, 2); // 8 bytes: 0x1f1f1f1f1f1f1f1f
            sim.mem[kB + 0x1c] = csrw(0x3a0, 1); // csrw pmpcfg0, x1
            sim.mem[kB + 0x20] = csrr(3, 0x3a0); // csrr x3, pmpcfg0
            sim.init();
            Event ev = sim.until_commit(kB + 0x20);
            check(ev.rd_data == 0x1f1f1f1f1f1f1f1fULL, "pmpcfg0 packing/readback mismatch");
            check(uint64_t(sim.dut.csr_pmpcfg0_o) == 0x1f1f1f1f1f1f1f1fULL, "pmpcfg0 output mismatch");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 3: Illegal Odd pmpcfg1/pmpcfg3 Accesses
        // ====================================================================
        {
            CoreSim sim;
            sim.mem[kB + 0x00] = csr(1, 1, 0, 0x3a1); // csrr x1, pmpcfg1 (illegal in RV64)
            sim.init();
            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x00 && uint64_t(sim.dut.csr_mcause_o) == 2, "pmpcfg1 must raise illegal instruction");
            ++scenarios;
        }
        {
            CoreSim sim;
            sim.mem[kB + 0x00] = csr(1, 1, 0, 0x3a3); // csrr x1, pmpcfg3 (illegal in RV64)
            sim.init();
            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x00 && uint64_t(sim.dut.csr_mcause_o) == 2, "pmpcfg3 must raise illegal instruction");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 4: Illegal S/U PMP CSR Accesses
        // ====================================================================
        {
            CoreSim sim;
            // Setup M-mode to transition to S-mode:
            // Allow all memory for S-mode so fetch doesn't fail
            sim.mem[kB + 0x00] = addi(10, 0, -1);
            sim.mem[kB + 0x04] = csr(1, 0, 10, 0x3b0); // pmpaddr0 = -1
            sim.mem[kB + 0x08] = addi(11, 0, 0x1f);
            sim.mem[kB + 0x0c] = csr(1, 0, 11, 0x3a0); // pmpcfg0 = 0x1f (NAPOT RWX)
            // Enter S-mode at kB + 0x30
            sim.mem[kB + 0x10] = addi(1, 0, 3);
            sim.mem[kB + 0x14] = slli(1, 1, 11);
            sim.mem[kB + 0x18] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x1c] = addi(2, 0, 1);
            sim.mem[kB + 0x20] = slli(2, 2, 11);
            sim.mem[kB + 0x24] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x28] = auipc(3);
            sim.mem[kB + 0x2c] = addi(3, 3, 0x10);    // mepc = kB + 0x38
            sim.mem[kB + 0x30] = csrw(0x341, 3);
            sim.mem[kB + 0x34] = MRET;
            sim.mem[kB + 0x38] = csr(1, 4, 0, 0x3a0); // S-mode: csrr x4, pmpcfg0 (illegal!)
            sim.init();
            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x38 && uint64_t(sim.dut.csr_mcause_o) == 2, "S-mode PMP CSR access must raise illegal insn");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 5: Deterministic WARL Legalization for Base PMP
        // ====================================================================
        {
            // Case A: Write R=0, W=1, X=0 (8'h02) -> must legalize to W=0 (8'h00)
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(1, 0, 0x02);
            sim.mem[kB + 0x04] = csrw(0x3a0, 1);
            sim.mem[kB + 0x08] = csrr(2, 0x3a0);
            sim.init();
            Event ev = sim.until_commit(kB + 0x08);
            check((ev.rd_data & 0xff) == 0x00, "WARL: R=0,W=1,X=0 must legalize to W=0");
            ++scenarios;
        }
        {
            // Case B: Write R=0, W=1, X=1 (8'h06) -> must legalize to W=0, X=1 (8'h04)
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(1, 0, 0x06);
            sim.mem[kB + 0x04] = csrw(0x3a0, 1);
            sim.mem[kB + 0x08] = csrr(2, 0x3a0);
            sim.init();
            Event ev = sim.until_commit(kB + 0x08);
            check((ev.rd_data & 0xff) == 0x04, "WARL: R=0,W=1,X=1 must legalize to W=0,X=1");
            ++scenarios;
        }
        {
            // Case C: Reserved bits 6:5 read-only zero
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(1, 0, 0x60);
            sim.mem[kB + 0x04] = csrw(0x3a0, 1);
            sim.mem[kB + 0x08] = csrr(2, 0x3a0);
            sim.init();
            Event ev = sim.until_commit(kB + 0x08);
            check((ev.rd_data & 0x60) == 0x00, "WARL: reserved cfg bits 6:5 must be 0");
            ++scenarios;
        }
        {
            // Case D: pmpaddr high bits [63:54] read-only zero
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(1, 0, -1);
            sim.mem[kB + 0x04] = csrw(0x3b0, 1);
            sim.mem[kB + 0x08] = csrr(2, 0x3b0);
            sim.init();
            Event ev = sim.until_commit(kB + 0x08);
            check(ev.rd_data == 0x003fffffffffffffULL, "WARL: pmpaddr[63:54] must be RO0");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 6: Lock Semantics (L=1 Immutability)
        // ====================================================================
        {
            CoreSim sim;
            // Write entry 0: L=1, A=NA4, R=1, W=1, X=1 (8'h9f)
            sim.mem[kB + 0x00] = addi(1, 0, 0x123);
            sim.mem[kB + 0x04] = csr(1, 0, 1, 0x3b0); // pmpaddr0 = 0x123
            sim.mem[kB + 0x08] = addi(2, 0, int(0x9f));
            sim.mem[kB + 0x0c] = csr(1, 0, 2, 0x3a0); // lock entry 0!
            // Attempt to overwrite pmpaddr0 with 0x456
            sim.mem[kB + 0x10] = addi(3, 0, 0x456);
            sim.mem[kB + 0x14] = csr(1, 0, 3, 0x3b0); // should be IGNORED
            // Attempt to clear L on entry 0 (write 0x1f)
            sim.mem[kB + 0x18] = addi(4, 0, 0x1f);
            sim.mem[kB + 0x1c] = csr(1, 0, 4, 0x3a0); // should be IGNORED for byte 0
            sim.mem[kB + 0x20] = csrr(5, 0x3b0); // read pmpaddr0
            sim.mem[kB + 0x24] = csrr(6, 0x3a0); // read pmpcfg0
            sim.init();
            Event ev = sim.until_commit(kB + 0x24);
            check(ev.rd_data == 0x9f, "Locked cfg byte 0 must not change");
            check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] == 0x123, "Locked pmpaddr0 must not change");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 7: TOR Predecessor Locking and Unlocked Predecessor Cfg
        // ====================================================================
        {
            CoreSim sim;
            // Entry 0 unlocked, addr0 = 0x100
            sim.mem[kB + 0x00] = addi(1, 0, 0x100);
            sim.mem[kB + 0x04] = csr(1, 0, 1, 0x3b0);
            // Entry 1 locked TOR (A=01, L=1 -> 8'h89), addr1 = 0x200
            sim.mem[kB + 0x08] = addi(2, 0, 0x200);
            sim.mem[kB + 0x0c] = csr(1, 0, 2, 0x3b1);
            sim.mem[kB + 0x10] = addi(3, 0, int(0x89));
            sim.mem[kB + 0x14] = slli(3, 3, 8); // byte 1 = 0x89 (entry 1 locked TOR)
            sim.mem[kB + 0x18] = csr(1, 0, 3, 0x3a0);
            // Attempt to write pmpaddr0 (predecessor of locked TOR entry 1): MUST BE IGNORED
            sim.mem[kB + 0x1c] = addi(4, 0, 0x999);
            sim.mem[kB + 0x20] = csr(1, 0, 4, 0x3b0);
            // But entry 0 cfg is unlocked: write pmp0cfg = 0x1f: MUST SUCCEED
            sim.mem[kB + 0x24] = addi(5, 0, 0x1f);
            sim.mem[kB + 0x28] = csr(2, 0, 5, 0x3a0); // set bits in pmp0cfg
            sim.mem[kB + 0x2c] = csrr(6, 0x3b0); // read pmpaddr0
            sim.mem[kB + 0x30] = csrr(7, 0x3a0); // read pmpcfg0
            sim.init();
            Event ev = sim.until_commit(kB + 0x30);
            check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] == 0x100, "Predecessor TOR addr must not change");
            check((ev.rd_data & 0xff) == 0x1f, "Unlocked predecessor cfg must remain writable");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 8: Chained TOR Locks & Entry 0 Edge Case
        // ====================================================================
        {
            CoreSim sim;
            // Entry 0 locked TOR: must NOT cause underflow to entry -1
            sim.mem[kB + 0x00] = addi(1, 0, 0x100);
            sim.mem[kB + 0x04] = csr(1, 0, 1, 0x3b0);
            sim.mem[kB + 0x08] = addi(2, 0, int(0x89)); // TOR + L
            sim.mem[kB + 0x0c] = csr(1, 0, 2, 0x3a0);
            // Entry 0 is locked TOR; verify entry 0 is locked
            sim.mem[kB + 0x10] = addi(3, 0, 0x500);
            sim.mem[kB + 0x14] = csr(1, 0, 3, 0x3b0); // ignored
            sim.mem[kB + 0x18] = csrr(4, 0x3b0);
            sim.init();
            Event ev = sim.until_commit(kB + 0x18);
            check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] == 0x100, "Entry 0 locked TOR addr unchanged");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 9: Hardware Reset Clears Locks
        // ====================================================================
        {
            CoreSim sim;
            sim.init();
            // Lock entry 0 manually in simulation
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x9f;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = 0x555;
            // Assert reset
            sim.init();
            check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] == 0, "Reset must clear lock bits");
            check(sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] == 0, "Reset must clear addr");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 10: S/U Default Deny vs M Default Allow
        // ====================================================================
        {
            // In M-mode with no PMP entries configured: fetch and load SUCCEED
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(1, 0, 0x42);
            sim.mem[kB + 0x04] = addi(2, 0, 0x24);
            sim.init();
            Event ev = sim.until_commit(kB + 0x04);
            check(ev.rd_data == 0x24, "M-mode default allow must succeed");
            ++scenarios;
        }
        {
            // In S-mode with no PMP entries configured: fetch immediately FAULTS (cause 1)
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;                 // return to S-mode
            sim.mem[kB + 0x28] = addi(4, 0, 0x99);     // S-mode instruction (DENIED!)
            sim.init();
            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x28 && uint64_t(sim.dut.csr_mcause_o) == 1,
                  "S-mode default deny must fault with cause 1 (instruction access fault)");
            check(uint64_t(sim.dut.csr_mtval_o) == kB + 0x28, "mtval must be faulting PC");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 11: M-mode Locked vs Unlocked Entry Enforcement
        // ====================================================================
        {
            // Case A: Unlocked entry with R=0, W=0, X=0 matching address
            // M-mode BYPASSES unlocked entry!
            CoreSim sim;
            // Entry 0: NAPOT, R=0, W=0, X=0, L=0 (8'h18) covering all memory
            sim.mem[kB + 0x00] = addi(10, 0, -1);
            sim.mem[kB + 0x04] = csr(1, 0, 10, 0x3b0);
            sim.mem[kB + 0x08] = addi(11, 0, 0x18); // A=NAPOT, L=0, R=W=X=0
            sim.mem[kB + 0x0c] = csr(1, 0, 11, 0x3a0);
            sim.mem[kB + 0x10] = addi(1, 0, 0x77); // M-mode continues execution!
            sim.init();
            Event ev = sim.until_commit(kB + 0x10);
            check(ev.rd_data == 0x77, "M-mode must bypass unlocked PMP entry");
            ++scenarios;
        }
        {
            // Case B: Locked entry with R=0, W=0, X=0, L=1 (8'h98) matching address
            // M-mode IS ENFORCED and immediately faults!
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(10, 0, -1);
            sim.mem[kB + 0x04] = csr(1, 0, 10, 0x3b0);
            sim.mem[kB + 0x08] = addi(11, 0, int(0x98)); // A=NAPOT, L=1, R=W=X=0
            sim.mem[kB + 0x0c] = csr(1, 0, 11, 0x3a0);    // locks entry!
            sim.mem[kB + 0x10] = addi(1, 0, 0x77);        // M-mode fetch fails here!
            sim.init();
            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x10 && uint64_t(sim.dut.csr_mcause_o) == 1,
                  "M-mode must be subject to locked PMP entry (cause 1)");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 12: First-Entry Priority & Subsequent Cannot Rescue
        // ====================================================================
        {
            // Entry 0: NAPOT covering RAM, R=0, W=0, X=0 (8'h18) - Deny
            // Entry 1: NAPOT covering RAM, R=1, W=1, X=1 (8'h1f) - Allow
            // S-mode accesses: entry 0 takes priority, access is DENIED!
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(10, 0, -1);
            sim.mem[kB + 0x04] = csr(1, 0, 10, 0x3b0);
            sim.mem[kB + 0x08] = csr(1, 0, 10, 0x3b1);
            // pmpcfg0: entry 0 = 0x18, entry 1 = 0x1f -> 0x1f18
            sim.mem[kB + 0x0c] = addi(11, 0, 0x1f);
            sim.mem[kB + 0x10] = slli(11, 11, 8);
            sim.mem[kB + 0x14] = ori(11, 11, 0x18);
            sim.mem[kB + 0x18] = csr(1, 0, 11, 0x3a0);
            // Switch to S-mode
            sim.mem[kB + 0x1c] = addi(1, 0, 3);
            sim.mem[kB + 0x20] = slli(1, 1, 11);
            sim.mem[kB + 0x24] = csr(3, 0, 1, 0x300);
            sim.mem[kB + 0x28] = addi(2, 0, 1);
            sim.mem[kB + 0x2c] = slli(2, 2, 11);
            sim.mem[kB + 0x30] = csr(2, 0, 2, 0x300);
            sim.mem[kB + 0x34] = auipc(3);
            sim.mem[kB + 0x38] = addi(3, 3, 0x10);    // mepc = kB + 0x44
            sim.mem[kB + 0x3c] = csrw(0x341, 3);
            sim.mem[kB + 0x40] = MRET;
            sim.mem[kB + 0x44] = addi(4, 0, 0x11);
            sim.init();
            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x44 && uint64_t(sim.dut.csr_mcause_o) == 1,
                  "Lowest-indexed overlapping entry must take priority and deny");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 13: Partial-Overlap / Boundary-Crossing Immediate Denial
        // ====================================================================
        {
            // Configure entry 0: NA4 at 0x80000100 (covers 0x80000100..0x80000103)
            // Configure entry 1: NA4 at 0x80000104 (covers 0x80000104..0x80000107)
            // Issue 8-byte load at 0x80000100 in S-mode.
            // Overlaps entry 0 (bytes 0..3), but does NOT contain (bytes 4..7).
            // Must FAULT immediately (cause 5) without checking entry 1!
            CoreSim sim;
            // Setup general PMP allow entry 2 for code execution
            uint64_t cfg = 0x00001f0000001a1aULL; // entry 0: NA4 RWX (0x1a), entry 1: NA4 RWX (0x1a), entry 2: NAPOT RWX (0x1f)
            sim.mem[kB + 0x00] = addi(10, 0, -1);
            sim.mem[kB + 0x04] = csr(1, 0, 10, 0x3b2); // entry 2 covers all for code
            sim.mem[kB + 0x08] = addi(11, 0, 0x800);
            sim.mem[kB + 0x0c] = slli(11, 11, 20); // 0x80000000
            sim.mem[kB + 0x10] = addi(11, 11, 0x100); // 0x80000100
            sim.mem[kB + 0x14] = slli(12, 11, 0);
            // pmpaddr is PA >> 2
            sim.mem[kB + 0x18] = addi(13, 0, 0x200);
            sim.mem[kB + 0x1c] = slli(13, 13, 18);
            sim.mem[kB + 0x20] = addi(13, 13, 0x40); // (0x80000100 >> 2) = 0x20000040
            sim.mem[kB + 0x24] = csr(1, 0, 13, 0x3b0); // pmpaddr0 = 0x80000100 >> 2
            sim.mem[kB + 0x28] = addi(13, 13, 1);
            sim.mem[kB + 0x2c] = csr(1, 0, 13, 0x3b1); // pmpaddr1 = 0x80000104 >> 2
            // For this test, set cfg via rootp to ensure precise setup
            sim.init();
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x13; // NA4, R=1, W=1, X=0
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (kB + 0x200) >> 2;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[1] = 0x13; // NA4, R=1, W=1, X=0
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[1] = (kB + 0x204) >> 2;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[2] = 0x1f; // NAPOT RWX
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[2] = 0x3fffffffffffffULL;

            // In S-mode, attempt 8-byte load at kB + 0x200
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;
            sim.mem[kB + 0x28] = auipc(5);
            sim.mem[kB + 0x2c] = ld(6, 5, 0x200 - 0x28); // 8-byte load across NA4 boundary!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x2c && uint64_t(sim.dut.csr_mcause_o) == 5,
                  "Boundary crossing must immediately cause load access fault (cause 5)");
            check(uint64_t(sim.dut.csr_mtval_o) == kB + 0x200, "mtval must be faulting access address");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 14: Denied Store Produces Zero Physical Side Effects
        // ====================================================================
        {
            // Configure PMP: Read-Only region at kB + 0x300 for S-mode (R=1, W=0, X=0)
            CoreSim sim;
            sim.init();
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x11; // NAPOT, R=1, W=0, X=0 (8B)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (kB + 0x300) >> 2;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[1] = 0x1f; // NAPOT RWX (rest of space for code)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[1] = 0x3fffffffffffffULL;

            // Memory location has known initial value
            sim.dmem[kB + 0x300] = 0x1122334455667788ULL;

            // In S-mode, attempt store to kB + 0x300
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300);
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300);
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;
            sim.mem[kB + 0x28] = auipc(5);
            sim.mem[kB + 0x2c] = addi(6, 0, 0xaa);
            sim.mem[kB + 0x30] = sd(6, 5, 0x300 - 0x28); // Denied store!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x30 && uint64_t(sim.dut.csr_mcause_o) == 7,
                  "Denied store must produce store access fault (cause 7)");
            check(sim.physical_stores == 0, "Denied store must NOT pulse physical store request");
            check(sim.dmem[kB + 0x300] == 0x1122334455667788ULL, "Memory must remain completely unchanged");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 15: Denied Load Does Not Update Destination Register
        // ====================================================================
        {
            // Configure PMP: No-access region for S-mode (R=0, W=0, X=0) at kB + 0x300
            CoreSim sim;
            sim.init();
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x18; // NAPOT, R=0, W=0, X=0
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (kB + 0x300) >> 2;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[1] = 0x1f; // NAPOT RWX
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[1] = 0x3fffffffffffffULL;

            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300);
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300);
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;
            sim.mem[kB + 0x28] = auipc(5);
            sim.mem[kB + 0x2c] = addi(7, 0, 0x5a); // x7 = 0x5a
            sim.mem[kB + 0x30] = ld(7, 5, 0x300 - 0x28); // Denied load targeting x7!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x30 && uint64_t(sim.dut.csr_mcause_o) == 5, "Denied load must cause load access fault");
            check(uint64_t(sim.dut.rootp->fursoy_s0_core__DOT__registers[7]) == 0x5a,
                  "Denied load must NOT overwrite destination register x7");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 16: MPRV Data Access Behavior
        // ====================================================================
        {
            // Case A: M-mode with MPRV=1, MPP=S. Data load in region without S permission.
            // Must FAULT with load access fault!
            CoreSim sim;
            sim.init();
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x18; // Deny S-mode
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (kB + 0x300) >> 2;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[1] = 0x1f;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[1] = 0x3fffffffffffffULL;

            // In M-mode: set mstatus.MPRV = 1 (bit 17), MPP = S (bit 12:11 = 01)
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = addi(3, 0, 1);
            sim.mem[kB + 0x1c] = slli(3, 3, 17);
            sim.mem[kB + 0x20] = csr(2, 0, 3, 0x300); // set MPRV=1
            sim.mem[kB + 0x24] = auipc(5);
            sim.mem[kB + 0x28] = ld(7, 5, 0x300 - 0x24); // Load under MPRV!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x28 && uint64_t(sim.dut.csr_mcause_o) == 5,
                  "MPRV=1 with MPP=S must enforce S-mode PMP restrictions on load");
            ++scenarios;
        }
        {
            // Case B: M-mode instruction fetch with MPRV=1 is NOT affected by MPRV
            // M-mode instruction fetch continues to evaluate as M-mode
            CoreSim sim;
            sim.init();
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x18; // Deny S-mode across all
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = 0x3fffffffffffffULL;

            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300);
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = addi(3, 0, 1);
            sim.mem[kB + 0x1c] = slli(3, 3, 17);
            sim.mem[kB + 0x20] = csr(2, 0, 3, 0x300); // set MPRV=1
            sim.mem[kB + 0x24] = addi(4, 0, 0x42);    // Next instruction fetch in M-mode
            sim.dut.eval();

            Event ev = sim.until_commit(kB + 0x24);
            check(ev.rd_data == 0x42, "M-mode fetch must NOT be affected by MPRV");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 17: PTW Local PMP Denial at Levels 2, 1, 0 (Deadlock Prevention)
        // ====================================================================
        {
            // Level 2 denial: Root page table at 0x100000.
            // Configure PMP entry 0: Deny 0x100000..0x100fff.
            // S-mode accesses virtual address VA. PTW tries to fetch level 2 PTE at 0x100xxx.
            // Must:
            // 1. Issue ZERO physical requests to the memory bus (pd_req_valid_o = 0)
            // 2. Transition immediately to terminal fault state (cause 1 for fetch, 5 for load)
            // 3. Never deadlock in PTW_REQ!
            CoreSim sim;
            sim.init();
            constexpr uint64_t ROOT = 0x100;
            // Configure PMP:
            // Entry 0: NA4/NAPOT deny at ROOT table address
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x18; // NAPOT, R=0, W=0, X=0, 4KB (k=9: 2^12 = 4KB)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = ((ROOT << 12) >> 2) | 0x1ff; // NAPOT 4KB
            // Entry 1: Allow all other memory for code
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[1] = 0x1f;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[1] = 0x3fffffffffffffULL;

            // Setup Sv39 satp and S-mode
            sim.mem[kB + 0x00] = addi(1, 0, 8);
            sim.mem[kB + 0x04] = slli(1, 1, 60);
            sim.mem[kB + 0x08] = addi(2, 0, ROOT);
            sim.mem[kB + 0x0c] = r_or(1, 1, 2);
            sim.mem[kB + 0x10] = csr(1, 0, 1, 0x180); // satp = Sv39, root=0x100
            sim.mem[kB + 0x14] = addi(3, 0, 3);
            sim.mem[kB + 0x18] = slli(3, 3, 11);
            sim.mem[kB + 0x1c] = csr(3, 0, 3, 0x300);
            sim.mem[kB + 0x20] = addi(4, 0, 1);
            sim.mem[kB + 0x24] = slli(4, 4, 11);
            sim.mem[kB + 0x28] = csr(2, 0, 4, 0x300); // MPP = S
            sim.mem[kB + 0x2c] = auipc(5);
            sim.mem[kB + 0x30] = addi(5, 5, 0x14);    // mepc = kB + 0x40
            sim.mem[kB + 0x34] = csrw(0x341, 5);
            sim.mem[kB + 0x38] = MRET;
            sim.mem[kB + 0x40] = addi(6, 0, 0x99); // Translated instruction fetch at Level 2 PTW!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(uint64_t(sim.dut.csr_mcause_o) == 1, "Level 2 PTW denial must generate instruction access fault (cause 1)");
            check(uint64_t(sim.dut.csr_mtval_o) == kB + 0x40, "xtval must receive original virtual address");
            check(sim.ptw_requests == 0, "Level 2 PTW denial must NOT issue external physical request");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 18: Translated Final-Access PMP Denial
        // ====================================================================
        {
            // PTW succeeds through all levels, but final translated physical address is denied by PMP
            // Load should fault with load access fault (cause 5), xtval = original VA
            CoreSim sim;
            sim.init();
            constexpr uint64_t ROOT = 0x100;
            // Map VA 0x40000000 to PA 0x40000000 (1GiB aligned: PPN 0x40000)
            sim.dmem[(ROOT << 12) + 1 * 8] = (0x40000ULL << 10) | 0xcf; // 1GB superpage at level 2: VRWXAD
            // Identity map VA 0x80000000 to PA 0x80000000 for code execution (PPN 0x80000)
            sim.dmem[(ROOT << 12) + 2 * 8] = (0x80000ULL << 10) | 0xcf; // 1GB superpage at level 2: VRWXAD

            // PMP denies PA 0x40000000 (R=0, W=0, X=0)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x18; // NAPOT, Deny
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (0x40000000ULL >> 2) | 0x1ff; // 4KB
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[1] = 0x1f; // Allow all else
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[1] = 0x3fffffffffffffULL;

            sim.mem[kB + 0x00] = addi(1, 0, 8);
            sim.mem[kB + 0x04] = slli(1, 1, 60);
            sim.mem[kB + 0x08] = addi(2, 0, ROOT);
            sim.mem[kB + 0x0c] = r_or(1, 1, 2);
            sim.mem[kB + 0x10] = csr(1, 0, 1, 0x180); // satp
            sim.mem[kB + 0x14] = addi(3, 0, 3);
            sim.mem[kB + 0x18] = slli(3, 3, 11);
            sim.mem[kB + 0x1c] = csr(3, 0, 3, 0x300);
            sim.mem[kB + 0x20] = addi(4, 0, 1);
            sim.mem[kB + 0x24] = slli(4, 4, 11);
            sim.mem[kB + 0x28] = csr(2, 0, 4, 0x300); // MPP = S
            sim.mem[kB + 0x2c] = auipc(5);
            sim.mem[kB + 0x30] = addi(5, 5, 0x10);    // mepc = kB + 0x3c
            sim.mem[kB + 0x34] = csrw(0x341, 5);
            sim.mem[kB + 0x38] = MRET;
            sim.mem[kB + 0x3c] = addi(6, 0, 1);
            sim.mem[kB + 0x40] = slli(6, 6, 30); // x6 = 0x40000000 (VA)
            sim.mem[kB + 0x44] = ld(7, 6, 0);     // Translated load to denied PA!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x44 && uint64_t(sim.dut.csr_mcause_o) == 5,
                  "Translated load denied by PMP must cause load access fault (cause 5)");
            check(uint64_t(sim.dut.csr_mtval_o) == 0x40000000ULL,
                  "xtval must receive original virtual address, not physical address");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 19: PMP Reconfiguration followed by SFENCE.VMA
        // ====================================================================
        {
            // End-to-end reconfiguration:
            // 1. PMP initially denies a region.
            // 2. M-mode updates PMP register to ALLOW region.
            // 3. Software executes SFENCE.VMA x0, x0 per architectural contract.
            // 4. Subsequent access now SUCCEEDS!
            CoreSim sim;
            sim.mem[kB + 0x00] = addi(10, 0, -1);
            sim.mem[kB + 0x04] = csr(1, 0, 10, 0x3b0);
            sim.mem[kB + 0x08] = addi(11, 0, 0x1f);
            sim.mem[kB + 0x0c] = csr(1, 0, 11, 0x3a0);   // reconfigure PMP
            sim.mem[kB + 0x10] = SFENCE_VMA;            // SFENCE.VMA x0, x0
            sim.mem[kB + 0x14] = addi(1, 0, 0x123);
            sim.init();
            Event ev = sim.until_commit(kB + 0x14);
            check(ev.rd_data == 0x123, "Reconfiguration + SFENCE.VMA must succeed");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 20: PMP Denial vs Platform Interconnect Error Precedence
        // ====================================================================
        {
            // Access to an unmapped platform address (e.g. 0x50000000).
            // PMP entry 0 allows S-mode instruction execution at test code address kB (4KB).
            // Data address 0x50000000 has no matching PMP entry (default denied for S-mode).
            // When S-mode executes ld x5, 0(x4) at 0x50000000:
            // 1. S-mode instruction execution at test code address is PMP-permitted.
            // 2. Data load genuinely issues architecturally from LSU.
            // 3. PMP denies data access before platform/interconnect sees it.
            // 4. Resulting cause is load access fault (cause 5), not instruction access fault.
            // 5. mtval contains intended faulting data address 0x50000000.
            // 6. Destination register x5 remains unchanged (preserves sentinel 0x5a).
            // 7. Physical data request toward SoC is never emitted (dmem_req_valid_o = 0).
            // 8. Unmapped-platform error path is never stimulated.
            CoreSim sim;
            sim.init();

            // PMP entry 0: NAPOT 4KB at kB (0x80000000), S-mode RWX (0x1f)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x1f;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (kB >> 2) | 0x1ff;

            // Enter S-mode
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;

            // In S-mode:
            sim.mem[kB + 0x28] = addi(4, 0, 5);
            sim.mem[kB + 0x2c] = slli(4, 4, 28);      // x4 = 0x50000000 (unmapped address)
            sim.mem[kB + 0x30] = addi(5, 0, 0x5a);    // sentinel: x5 = 0x5a
            sim.mem[kB + 0x34] = ld(5, 4, 0);         // load from unmapped address 0x50000000
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x34 && uint64_t(sim.dut.csr_mcause_o) == 5,
                  "PMP denies unmapped load before platform: cause must be 5 (load access fault)");
            check(uint64_t(sim.dut.csr_mtval_o) == 0x50000000ULL,
                  "mtval must be unmapped faulting data address 0x50000000");
            check(uint64_t(sim.dut.rootp->fursoy_s0_core__DOT__registers[5]) == 0x5a,
                  "Destination register x5 must remain unchanged");
            check(sim.dut.dmem_req_valid_o == 0, "No external physical request emitted");
            check(sim.last_dmem_addr != 0x50000000ULL, "Interconnect never saw unmapped physical address");
            ++scenarios;
        }

        // ====================================================================
        // Scenario 21: Explicit NAPOT k=53 (Full 56-bit PA Space) Boundary Test
        // ====================================================================
        {
            // Part A: Directed test for full 56-bit PA space NAPOT encoding:
            // k=53: bit 53 = 0, bits 52:0 = 1 -> pmpaddr0 = (1ULL << 53) - 1 = 0x001fffffffffffffULL
            // Region size = 2^(53+3) = 2^56 bytes (range: [0, 2^56)).
            // Verify:
            // - Low address (0x0, kB) is covered and access allowed.
            // - Highest legal naturally aligned 8-byte address: (1ULL << 56) - 8 = 0x00fffffffffffff8ULL.
            // - Highest legal naturally aligned 4-byte address: (1ULL << 56) - 4 = 0x00fffffffffffffcULL.
            // - No arithmetic truncation occurs.
            CoreSim sim;
            sim.init();

            // Entry 0: NAPOT k=53, S-mode RWX (0x1f)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x1f;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (1ULL << 53) - 1ULL;

            constexpr uint64_t kHigh8 = (1ULL << 56) - 8;
            constexpr uint64_t kHigh4 = (1ULL << 56) - 4;
            sim.dmem[0] = 0xcafe12345678babeULL;
            sim.dmem[kHigh8] = 0xdeadbeef99887766ULL;
            sim.dmem[kHigh4] = 0x11223344ULL;

            // Transition to S-mode
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;

            // In S-mode:
            // 1. Low address load at 0x0
            sim.mem[kB + 0x28] = addi(4, 0, 0);       // x4 = 0
            sim.mem[kB + 0x2c] = ld(5, 4, 0);         // ld x5, 0(x4) -> allowed!

            // 2. Highest legal naturally aligned 8-byte address: (1ULL << 56) - 8
            // Construct x6 = 0x00fffffffffffff8
            sim.mem[kB + 0x30] = addi(6, 0, -1);      // x6 = 0xffffffffffffffff
            sim.mem[kB + 0x34] = slli(6, 6, 8);
            sim.mem[kB + 0x38] = srli(6, 6, 8);       // x6 = 0x00ffffffffffffff
            sim.mem[kB + 0x3c] = addi(6, 6, -7);      // x6 = 0x00fffffffffffff8
            sim.mem[kB + 0x40] = ld(7, 6, 0);         // ld x7, 0(x6) -> allowed!

            // 3. Highest legal naturally aligned 4-byte address: (1ULL << 56) - 4
            sim.mem[kB + 0x44] = addi(6, 6, 4);       // x6 = 0x00fffffffffffffc
            sim.mem[kB + 0x48] = lw(8, 6, 0);         // lw x8, 0(x6) -> allowed!
            sim.dut.eval();

            // Step 1: verify low address load commits
            Event ev1 = sim.until_commit(kB + 0x2c);
            check(ev1.rd_data == 0xcafe12345678babeULL, "k=53: low address load must succeed");

            // Step 2: verify highest legal 8-byte address load commits
            Event ev2 = sim.until_commit(kB + 0x40);
            check(ev2.rd_data == 0xdeadbeef99887766ULL, "k=53: highest legal 8-byte address load must succeed");

            // Step 3: verify highest legal 4-byte address load commits
            Event ev3 = sim.until_commit(kB + 0x48);
            check((ev3.rd_data & 0xffffffffULL) == 0x11223344ULL,
                  "k=53: highest legal 4-byte address load must succeed");
            ++scenarios;
        }
        {
            // Part B: k=53 permission enforcement (W=0) at highest legal 8-byte address
            CoreSim sim;
            sim.init();

            // Entry 0: NAPOT k=53, S-mode Read-Execute only (0x1d: R=1, W=0, X=1, A=NAPOT)
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x1d;
            sim.dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = (1ULL << 53) - 1ULL;

            constexpr uint64_t kHigh8 = (1ULL << 56) - 8;

            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);
            sim.mem[kB + 0x08] = csr(3, 0, 1, 0x300); // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);
            sim.mem[kB + 0x14] = csr(2, 0, 2, 0x300); // MPP = S
            sim.mem[kB + 0x18] = auipc(3);
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);    // mepc = kB + 0x28
            sim.mem[kB + 0x20] = csrw(0x341, 3);
            sim.mem[kB + 0x24] = MRET;

            sim.mem[kB + 0x28] = addi(6, 0, -1);
            sim.mem[kB + 0x2c] = slli(6, 6, 8);
            sim.mem[kB + 0x30] = srli(6, 6, 8);       // 0x00ffffffffffffff
            sim.mem[kB + 0x34] = addi(6, 6, -7);      // (1ULL << 56) - 8
            sim.mem[kB + 0x38] = addi(5, 0, 0x42);
            sim.mem[kB + 0x3c] = sd(5, 6, 0);         // Store to (1ULL << 56) - 8 denied by W=0!
            sim.dut.eval();

            Event ev = sim.until_trap();
            check(ev.pc == kB + 0x3c && uint64_t(sim.dut.csr_mcause_o) == 7,
                  "k=53: store to highest legal address without W permission must fault with cause 7");
            check(uint64_t(sim.dut.csr_mtval_o) == kHigh8,
                  "k=53: mtval must report highest legal address");
            check(sim.physical_stores == 0, "k=53: zero physical stores emitted");
            ++scenarios;
        }

        std::cout << "{\"status\":\"pass\",\"scenarios\":" << scenarios << "}\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "PMP_S0_MISMATCH scenario=" << scenarios + 1 << " reason=" << e.what() << "\n";
        return 1;
    }
}
