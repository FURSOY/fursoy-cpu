#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>

static uint32_t addi(unsigned rd, unsigned rs, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs << 15) | (rd << 7) | 0x13;
}
static uint32_t slli(unsigned rd, unsigned rs, unsigned sh) {
    return (sh << 20) | (rs << 15) | (1 << 12) | (rd << 7) | 0x13;
}
static uint32_t csr(unsigned f, unsigned rd, unsigned rs, unsigned addr) {
    return (addr << 20) | (rs << 15) | (f << 12) | (rd << 7) | 0x73;
}
static uint32_t csrrw(unsigned rd, unsigned rs, unsigned addr) { return csr(1, rd, rs, addr); }
static uint32_t csrrs(unsigned rd, unsigned rs, unsigned addr) { return csr(2, rd, rs, addr); }
static uint32_t csrrc(unsigned rd, unsigned rs, unsigned addr) { return csr(3, rd, rs, addr); }
static uint32_t csrrwi(unsigned rd, unsigned uimm, unsigned addr) { return csr(5, rd, uimm, addr); }
static uint32_t csrrsi(unsigned rd, unsigned uimm, unsigned addr) { return csr(6, rd, uimm, addr); }
static uint32_t csrrci(unsigned rd, unsigned uimm, unsigned addr) { return csr(7, rd, uimm, addr); }

static uint32_t auipc(unsigned rd, uint32_t imm20) {
    return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x17;
}
static uint32_t ori_insn(unsigned rd, unsigned rs, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs << 15) | (6 << 12) | (rd << 7) | 0x13;
}
static uint32_t lw_insn(unsigned rd, unsigned rs, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs << 15) | (2 << 12) | (rd << 7) | 0x03;
}
static uint32_t sd_insn(unsigned rs2, unsigned rs1, int imm) {
    uint32_t uimm = uint32_t(imm);
    return (((uimm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((uimm & 0x1f) << 7) | 0x23;
}
static uint32_t sw_insn(unsigned rs2, unsigned rs1, int imm) {
    uint32_t uimm = uint32_t(imm);
    return (((uimm >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((uimm & 0x1f) << 7) | 0x23;
}

static constexpr uint32_t kEcall   = 0x00000073;
static constexpr uint32_t kEbreak  = 0x00100073;
static constexpr uint32_t kMret    = 0x30200073;
static constexpr uint32_t kSret    = 0x10200073;
static constexpr uint32_t kWfi     = 0x10500073;
static constexpr uint32_t kSfenceVma = 0x12000073; // sfence.vma x0, x0

struct Event {
    bool commit = false;
    bool trap = false;
    uint64_t pc = 0;
    uint32_t insn = 0;
    bool rd_write = false;
    unsigned rd = 0;
    uint64_t rd_data = 0;
    uint8_t priv_mode = 3;
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
    bool inject_dmem_rsp_error = false;
    bool inject_dmem_req_error = false;

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
        dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x1f;
        dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = 0x3fffffffffffffULL;
        dut.eval();
    }

    Event tick() {
        dut.clk_i = 0;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = fetch_pending;
        dut.imem_rsp_data_i = rsp_data;
        dut.imem_rsp_error_i = 0;

        dut.dmem_req_ready_i = 1;
        dut.dmem_req_error_i = inject_dmem_req_error ? 1 : 0;
        dut.dmem_rsp_valid_i = dmem_rsp_pending;
        dut.dmem_rsp_data_i = dmem_rsp_data;
        dut.dmem_rsp_error_i = (dmem_rsp_pending && inject_dmem_rsp_error) ? 1 : 0;
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

        bool next_dmem_pending = dmem_rsp_pending;
        uint64_t next_dmem_data = dmem_rsp_data;
        if (dmem_rsp_fire) {
            next_dmem_pending = false;
        }
        if (dmem_req_fire) {
            uint64_t addr = dut.dmem_req_addr_o;
            if (dut.dmem_req_store_o) {
                dmem[addr] = dut.dmem_req_store_data_o;
            } else {
                next_dmem_data = dmem.count(addr) ? dmem[addr] : 0;
                next_dmem_pending = true;
            }
        }

        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        fetch_pending = next_pending;
        rsp_pc = next_pc;
        rsp_data = next_data;

        dmem_rsp_pending = next_dmem_pending;
        dmem_rsp_data = next_dmem_data;

        if (ev.commit) ++commits;
        return ev;
    }

    Event step_until_commit_at(uint64_t expected_pc, unsigned max_cycles = 200) {
        for (unsigned c = 0; c < max_cycles; ++c) {
            Event e = tick();
            if (e.commit && e.pc == expected_pc) return e;
        }
        throw std::runtime_error("timeout waiting for commit");
    }

    Event step_until_trap(unsigned max_cycles = 200) {
        for (unsigned c = 0; c < max_cycles; ++c) {
            Event e = tick();
            if (e.trap) return e;
        }
        throw std::runtime_error("timeout waiting for trap");
    }
};

static void check(bool ok, const char* msg) {
    if (!ok) throw std::runtime_error(msg);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned scenarios_passed = 0;
    constexpr uint64_t kB = 0x80000000ULL;
    constexpr uint64_t kMVec = 0x80000100ULL;
    constexpr uint64_t kSVec = 0x80000200ULL;

    try {
        // ====================================================================
        // Scenario 1: Reset Privilege and CSR State
        // ====================================================================
        {
            CoreSim sim;
            sim.init();
            check(sim.dut.priv_mode_o == 3, "Reset privilege must be M-mode (3)");
            check(uint64_t(sim.dut.csr_mstatus_o) == 0x0000000a00001800ULL,
                  "Reset mstatus must be 0x0000000a00001800 (UXL=2, SXL=2, MPP=M)");
            check(uint64_t(sim.dut.csr_sstatus_o) == 0x0000000200000000ULL,
                  "Reset sstatus must be 0x0000000200000000 (UXL=2, SPP=0)");
            check(uint64_t(sim.dut.csr_mie_o) == 0, "Reset mie must be 0");
            check(uint64_t(sim.dut.csr_mtvec_o) == 0x80000100ULL, "Reset mtvec must match parameter");
            check(uint64_t(sim.dut.csr_mscratch_o) == 0, "Reset mscratch must be 0");
            check(uint64_t(sim.dut.csr_mepc_o) == 0, "Reset mepc must be 0");
            check(uint64_t(sim.dut.csr_mcause_o) == 0, "Reset mcause must be 0");
            check(uint64_t(sim.dut.csr_mtval_o) == 0, "Reset mtval must be 0");
            check(uint64_t(sim.dut.csr_medeleg_o) == 0, "Reset medeleg must be 0");
            check(uint64_t(sim.dut.csr_stvec_o) == 0, "Reset stvec must be 0");
            check(uint64_t(sim.dut.csr_sscratch_o) == 0, "Reset sscratch must be 0");
            check(uint64_t(sim.dut.csr_sepc_o) == 0, "Reset sepc must be 0");
            check(uint64_t(sim.dut.csr_scause_o) == 0, "Reset scause must be 0");
            check(uint64_t(sim.dut.csr_stval_o) == 0, "Reset stval must be 0");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 2: M -> S transition via MRET and M -> U transition via MRET
        // ====================================================================
        {
            CoreSim sim;
            // Setup M-mode code to return to S-mode:
            // 1. Clear MPP to 0: csrrci x0, mstatus, 0x1800 -> wait, zimm is only 5 bits.
            // Use CSRRC with register:
            // x1 = 0x1800 (MPP mask)
            // csrc mstatus, x1
            // x2 = 0x0800 (MPP = S = 1)
            // csrs mstatus, x2
            // x3 = kB + 0x28 (target in S-mode)
            // csrw mepc, x3
            // mret
            sim.mem[kB + 0x00] = addi(1, 0, 3);
            sim.mem[kB + 0x04] = slli(1, 1, 11);               // x1 = 0x1800
            sim.mem[kB + 0x08] = csrrc(0, 1, 0x300);            // clear MPP
            sim.mem[kB + 0x0c] = addi(2, 0, 1);
            sim.mem[kB + 0x10] = slli(2, 2, 11);               // x2 = 0x0800 (MPP=S)
            sim.mem[kB + 0x14] = csrrs(0, 2, 0x300);            // set MPP=S
            sim.mem[kB + 0x18] = auipc(3, 0);                  // x3 = kB + 0x18
            sim.mem[kB + 0x1c] = addi(3, 3, 0x10);             // x3 = kB + 0x28
            sim.mem[kB + 0x20] = csrrw(0, 3, 0x341);           // mepc = kB + 0x28
            sim.mem[kB + 0x24] = kMret;                        // MRET to S-mode at kB + 0x28!
            sim.mem[kB + 0x28] = addi(4, 0, 0x5a);             // S-mode instruction!
            sim.init();

            bool returned_to_s = false;
            for (int i = 0; i < 120; ++i) {
                Event e = sim.tick();
                if (e.commit && e.pc == kB + 0x24) {
                    // MRET commits
                    check(sim.dut.priv_mode_o == 1, "Privilege after MRET with MPP=S must be S-mode (1)");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x1800) == 0,
                          "mstatus.MPP must be cleared to U (0) on MRET");
                }
                if (e.commit && e.pc == kB + 0x28) {
                    check(sim.dut.priv_mode_o == 1, "Target instruction executed in S-mode");
                    check(e.rd == 4 && e.rd_data == 0x5a, "S-mode commit result correct");
                    returned_to_s = true;
                    break;
                }
            }
            check(returned_to_s, "Successfully executed in S-mode after MRET");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 3: CSR Access from S-mode and U-mode (Privilege Check & Suppression)
        // ====================================================================
        {
            CoreSim sim;
            // Setup:
            // In M-mode, set mtvec = kMVec.
            // Set mepc = kB + 0x20. Set MPP = S (0x800).
            // MRET into S-mode.
            // At kB + 0x20:
            // 1. Legal S-mode CSR: csrw sscratch, 0x77 (success)
            // 2. Legal S-mode CSR: csrr satp (returns 0, success)
            // 3. Illegal in S-mode: csrw mscratch, 0x55 (privilege fault -> cause 2)
            sim.mem[kB + 0x00] = addi(1, 0, 1);
            sim.mem[kB + 0x04] = slli(1, 1, 11);               // x1 = 0x800
            sim.mem[kB + 0x08] = csrrw(0, 1, 0x300);            // mstatus.MPP = S (coerced or direct)
            sim.mem[kB + 0x0c] = addi(2, 0, 0x20);             // mepc offset
            sim.mem[kB + 0x10] = addi(3, 0, 1);
            sim.mem[kB + 0x14] = slli(3, 3, 31);               // 0x80000000
            sim.mem[kB + 0x18] = csrrs(0, 3, 0x305);            // mtvec = kB (so trap goes to kB)
            sim.mem[kB + 0x18] = csrrw(0, 3, 0x305);            // mtvec = 0x80000000
            sim.mem[kB + 0x1c] = csrrw(0, 3, 0x341);            // mepc = 0x80000000
            // Wait, let's keep mtvec = kMVec and mepc = 0x80000030:
            // We can set registers cleanly:
            sim.init();

            // Set up registers via ticking instructions in M-mode:
            sim.mem[kB + 0x00] = addi(1, 0, 1);
            sim.mem[kB + 0x04] = slli(1, 1, 11);               // x1 = 0x800 (MPP=S)
            sim.mem[kB + 0x08] = csrrw(0, 1, 0x300);            // mstatus.MPP = S
            sim.mem[kB + 0x0c] = auipc(2, 0);                  // x2 = kB + 0x0c
            sim.mem[kB + 0x10] = addi(2, 2, 0x34);             // mepc = kB + 0x40
            sim.mem[kB + 0x14] = csrrw(0, 2, 0x341);
            sim.mem[kB + 0x18] = addi(3, 2, 0x40);             // mtvec = kB + 0x80 (handler)
            sim.mem[kB + 0x1c] = csrrw(0, 3, 0x305);
            sim.mem[kB + 0x20] = kMret;                        // enter S-mode at kB + 0x40

            // S-mode code at kB + 0x40:
            sim.mem[kB + 0x40] = csrrwi(0, 31, 0x140);         // csrw sscratch, 31 (legal in S)
            sim.mem[kB + 0x44] = csrrw(4, 0, 0x180);           // csrr x4, satp (legal in S)
            sim.mem[kB + 0x48] = addi(5, 0, 0x5a);             // x5 = 0x5a
            sim.mem[kB + 0x4c] = csrrw(5, 0, 0x340);           // csrrw x5, mscratch, x0 (ILLEGAL in S!)

            // M-mode handler at kB + 0x80:
            sim.mem[kB + 0x80] = addi(6, 5, 0);                // read x5 into x6 to verify preservation

            bool sscratch_written = false;
            bool satp_read = false;
            bool trap_observed = false;
            bool x5_preserved = false;

            for (int i = 0; i < 80; ++i) {
                Event e = sim.tick();
                if (e.commit && e.pc == kB + 0x40) {
                    check(sim.dut.priv_mode_o == 1, "sscratch executed in S-mode");
                    check(uint64_t(sim.dut.csr_sscratch_o) == 31, "sscratch written correctly");
                    sscratch_written = true;
                }
                if (e.commit && e.pc == kB + 0x44) {
                    check(e.rd == 4 && e.rd_data == 0, "satp read in S-mode returned 0");
                    satp_read = true;
                }
                if (e.trap) {
                    check(e.pc == kB + 0x4c, "Trap event PC must be kB + 0x4c (mscratch access)");
                    check(uint64_t(sim.dut.csr_mcause_o) == 2, "Trap cause must be 2 (illegal instruction)");
                    check(uint64_t(sim.dut.csr_mepc_o) == kB + 0x4c, "mepc must be faulting PC kB + 0x4c");
                    check(uint64_t(sim.dut.csr_mtval_o) == sim.mem[kB + 0x4c], "mtval must be faulting instruction");
                    check(uint64_t(sim.dut.csr_mscratch_o) == 0, "mscratch must NOT be modified");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x1800) == 0x800,
                          "mstatus.MPP must record origin privilege S (1)");
                    check(sim.dut.priv_mode_o == 3, "Trap must enter M-mode (3)");
                    trap_observed = true;
                }
                if (e.commit && e.pc == kB + 0x80) {
                    check(e.rd == 6 && e.rd_data == 0x5a,
                          "Faulting CSR instruction must NOT have modified destination register x5");
                    x5_preserved = true;
                    break;
                }
            }
            check(sscratch_written && satp_read && trap_observed && x5_preserved,
                  "S-mode CSR legality, privilege check, and side-effect suppression verified");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 4: Non-delegated vs Delegated Synchronous Exception Routing
        // ====================================================================
        {
            // First: Non-delegated U-mode ECALL (medeleg=0) -> must trap to M-mode with cause=8
            CoreSim sim;
            sim.init();

            // M-mode setup:
            // mtvec = kB + 0x100, stvec = kB + 0x200, medeleg = 0
            // mepc = kB + 0x40, MPP = U (0)
            // MRET to U-mode at kB + 0x40
            sim.mem[kB + 0x00] = auipc(1, 0);
            sim.mem[kB + 0x04] = addi(1, 1, 0x100);            // x1 = kB + 0x100
            sim.mem[kB + 0x08] = csrrw(0, 1, 0x305);           // mtvec = kB + 0x100
            sim.mem[kB + 0x0c] = addi(2, 1, 0x100);            // x2 = kB + 0x200
            sim.mem[kB + 0x10] = csrrw(0, 2, 0x105);           // stvec = kB + 0x200
            sim.mem[kB + 0x14] = addi(4, 0, 3);
            sim.mem[kB + 0x18] = slli(4, 4, 11);               // x4 = 0x1800
            sim.mem[kB + 0x1c] = csrrc(0, 4, 0x300);           // mstatus.MPP = 0 (U-mode)
            sim.mem[kB + 0x20] = auipc(3, 0);
            sim.mem[kB + 0x24] = addi(3, 3, 0x20);             // target PC = kB + 0x40
            sim.mem[kB + 0x28] = csrrw(0, 3, 0x341);           // mepc = kB + 0x40
            sim.mem[kB + 0x2c] = kMret;                        // MRET into U-mode

            // U-mode code at kB + 0x40:
            sim.mem[kB + 0x40] = kEcall;                       // ECALL in U-mode!

            bool trapped_to_m = false;
            for (int i = 0; i < 100; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x40, "Trap PC is kB + 0x40");
                    check(sim.dut.priv_mode_o == 3, "Trap went to M-mode");
                    check(uint64_t(sim.dut.csr_mcause_o) == 8, "mcause is 8 (U-mode ECALL)");
                    check(uint64_t(sim.dut.csr_mepc_o) == kB + 0x40, "mepc is kB + 0x40");
                    check(uint64_t(sim.dut.csr_mtval_o) == 0, "mtval is 0");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x1800) == 0, "MPP is U (0)");
                    // S-bank must remain 0:
                    check(uint64_t(sim.dut.csr_sepc_o) == 0, "sepc untouched");
                    check(uint64_t(sim.dut.csr_scause_o) == 0, "scause untouched");
                    check(uint64_t(sim.dut.csr_stval_o) == 0, "stval untouched");
                    trapped_to_m = true;
                    break;
                }
            }
            check(trapped_to_m, "Non-delegated U-mode ECALL routed to M-mode");

            // Second: Delegated U-mode ECALL (medeleg[8] = 1) -> must trap to S-mode with cause=8
            CoreSim sim2;
            sim2.init();
            sim2.mem[kB + 0x00] = addi(1, 0, 1);
            sim2.mem[kB + 0x04] = slli(1, 1, 8);               // x1 = 0x100 (bit 8 = cause 8)
            sim2.mem[kB + 0x08] = csrrw(0, 1, 0x302);          // medeleg[8] = 1
            sim2.mem[kB + 0x0c] = auipc(2, 0);
            sim2.mem[kB + 0x10] = addi(2, 2, 0x1f4);           // x2 = kB + 0x200
            sim2.mem[kB + 0x14] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            sim2.mem[kB + 0x18] = addi(4, 0, 3);
            sim2.mem[kB + 0x1c] = slli(4, 4, 11);              // x4 = 0x1800
            sim2.mem[kB + 0x20] = csrrc(0, 4, 0x300);          // mstatus.MPP = 0 (U-mode)
            sim2.mem[kB + 0x24] = auipc(3, 0);
            sim2.mem[kB + 0x28] = addi(3, 3, 0x1c);            // mepc = kB + 0x40
            sim2.mem[kB + 0x2c] = csrrw(0, 3, 0x341);
            sim2.mem[kB + 0x30] = kMret;                       // MRET into U-mode

            // U-mode code at kB + 0x40:
            sim2.mem[kB + 0x40] = kEcall;                      // ECALL in U-mode!

            bool trapped_to_s = false;
            for (int i = 0; i < 100; ++i) {
                Event e = sim2.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x40, "Trap PC is kB + 0x40");
                    check(sim2.dut.priv_mode_o == 1, "Delegated trap must enter S-mode (1)");
                    check(uint64_t(sim2.dut.csr_scause_o) == 8, "scause is 8 (U-mode ECALL)");
                    check(uint64_t(sim2.dut.csr_sepc_o) == kB + 0x40, "sepc is kB + 0x40");
                    check(uint64_t(sim2.dut.csr_stval_o) == 0, "stval is 0");
                    check((uint64_t(sim2.dut.csr_mstatus_o) & 0x100) == 0, "SPP is U (0)");
                    // M-bank must remain untouched:
                    check(uint64_t(sim2.dut.csr_mcause_o) == 0, "mcause untouched");
                    check(uint64_t(sim2.dut.csr_mtval_o) == 0, "mtval untouched");
                    trapped_to_s = true;
                    break;
                }
            }
            check(trapped_to_s, "Delegated U-mode ECALL routed to S-mode");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 5: S-mode Trap Entry and SRET Return
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // 1. M-mode setup:
            // medeleg[2] = 1 (illegal instruction delegated to S)
            // stvec = kB + 0x200
            // return to S-mode at kB + 0x40
            sim.mem[kB + 0x00] = addi(1, 0, 4);                // bit 2 = cause 2
            sim.mem[kB + 0x04] = csrrw(0, 1, 0x302);           // medeleg[2] = 1
            sim.mem[kB + 0x08] = auipc(2, 0);
            sim.mem[kB + 0x0c] = addi(2, 2, 0x1f8);            // x2 = kB + 0x200
            sim.mem[kB + 0x10] = csrrw(0, 2, 0x105);           // stvec = kB + 0x200
            sim.mem[kB + 0x14] = addi(3, 0, 1);
            sim.mem[kB + 0x18] = slli(3, 3, 11);              // x3 = 0x800 (MPP=S)
            sim.mem[kB + 0x1c] = csrrw(0, 3, 0x300);           // mstatus.MPP = S
            sim.mem[kB + 0x20] = auipc(4, 0);
            sim.mem[kB + 0x24] = addi(4, 4, 0x20);             // mepc = kB + 0x40
            sim.mem[kB + 0x28] = csrrw(0, 4, 0x341);
            sim.mem[kB + 0x2c] = kMret;                        // enter S-mode at kB + 0x40

            // S-mode code at kB + 0x40:
            // Trigger delegated illegal instruction (e.g. 0xffffffff)
            sim.mem[kB + 0x40] = 0xffffffff;

            // S-mode handler at kB + 0x200:
            // sepc has kB + 0x40. We advance sepc to kB + 0x44 and return via SRET:
            // x1 = sepc + 4
            // csrw sepc, x1
            // sret
            sim.mem[kB + 0x200] = csrrw(1, 0, 0x141);         // csrr x1, sepc
            sim.mem[kB + 0x204] = addi(1, 1, 4);              // x1 += 4
            sim.mem[kB + 0x208] = csrrw(0, 1, 0x141);         // csrw sepc, x1
            sim.mem[kB + 0x20c] = kSret;                      // SRET!

            // Target after SRET at kB + 0x44:
            sim.mem[kB + 0x44] = addi(7, 0, 0x33);

            bool trapped_to_s = false;
            bool sret_executed = false;
            bool resumed_after_sret = false;

            for (int i = 0; i < 120; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x40, "Trap PC is kB + 0x40");
                    check(sim.dut.priv_mode_o == 1, "Delegated trap to S-mode");
                    check(uint64_t(sim.dut.csr_scause_o) == 2, "scause is 2 (illegal insn)");
                    check(uint64_t(sim.dut.csr_sepc_o) == kB + 0x40, "sepc is kB + 0x40");
                    check(uint64_t(sim.dut.csr_stval_o) == 0xffffffff, "stval is faulting insn");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x100) == 0x100,
                          "mstatus.SPP is 1 (origin was S-mode)");
                    trapped_to_s = true;
                }
                if (e.commit && e.pc == kB + 0x20c) {
                    check(sim.dut.priv_mode_o == 1, "SRET executed from S-mode");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x100) == 0,
                          "mstatus.SPP must be cleared to U (0) on SRET");
                    sret_executed = true;
                }
                if (e.commit && e.pc == kB + 0x44) {
                    check(sim.dut.priv_mode_o == 1, "Resumed execution at sepc in S-mode");
                    check(e.rd == 7 && e.rd_data == 0x33, "Commit value after SRET correct");
                    resumed_after_sret = true;
                    break;
                }
            }
            check(trapped_to_s && sret_executed && resumed_after_sret,
                  "Delegated S-mode trap entry, handler, and SRET flow verified");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 6: Privileged Instruction Legality & Intercepts (MRET, SRET, WFI, SFENCE.VMA)
        // ====================================================================
        {
            // 6A: In U-mode: mret, sret, wfi, sfence.vma are ALL illegal!
            CoreSim sim;
            sim.init();

            // Setup: in M-mode, clear MPP to U and return to U-mode at kB + 0x40
            sim.mem[kB + 0x00] = addi(4, 0, 3);
            sim.mem[kB + 0x04] = slli(4, 4, 11);               // x4 = 0x1800
            sim.mem[kB + 0x08] = csrrc(0, 4, 0x300);           // mstatus.MPP = 0 (U-mode)
            sim.mem[kB + 0x0c] = auipc(1, 0);
            sim.mem[kB + 0x10] = addi(1, 1, 0x34);             // mepc = kB + 0x40
            sim.mem[kB + 0x14] = csrrw(0, 1, 0x341);
            sim.mem[kB + 0x18] = kMret;                        // enter U-mode

            // Test WFI in U-mode:
            sim.mem[kB + 0x40] = kWfi;

            sim.step_until_commit_at(kB + 0x18);
            check(sim.dut.priv_mode_o == 0, "Now in U-mode");
            Event trap_wfi = sim.step_until_trap();
            check(trap_wfi.pc == kB + 0x40 && uint64_t(sim.dut.csr_mcause_o) == 2,
                  "WFI in U-mode must raise illegal instruction (cause 2)");

            // 6B: In S-mode: TSR intercept for SRET
            CoreSim sim2;
            sim2.init();
            // Clear MPP to U, then set TSR (0x400000) and MPP=S (0x800)
            sim2.mem[kB + 0x00] = addi(4, 0, 3);
            sim2.mem[kB + 0x04] = slli(4, 4, 11);              // x4 = 0x1800
            sim2.mem[kB + 0x08] = csrrc(0, 4, 0x300);          // clear MPP to U
            sim2.mem[kB + 0x0c] = addi(1, 0, 4);
            sim2.mem[kB + 0x10] = slli(1, 1, 20);              // x1 = 0x400000 (TSR=1)
            sim2.mem[kB + 0x14] = addi(2, 0, 1);
            sim2.mem[kB + 0x18] = slli(2, 2, 11);              // x2 = 0x800 (MPP=S)
            sim2.mem[kB + 0x1c] = csrrs(0, 1, 0x300);          // set TSR
            sim2.mem[kB + 0x20] = csrrs(0, 2, 0x300);          // set MPP=S
            sim2.mem[kB + 0x24] = auipc(3, 0);
            sim2.mem[kB + 0x28] = addi(3, 3, 0x2c);            // mepc = kB + 0x50
            sim2.mem[kB + 0x2c] = csrrw(0, 3, 0x341);
            sim2.mem[kB + 0x30] = kMret;                       // enter S-mode at kB + 0x50

            // S-mode code at kB + 0x50:
            sim2.mem[kB + 0x50] = kSret;                       // SRET with TSR=1 -> must trap!

            sim2.step_until_commit_at(kB + 0x30);
            check(sim2.dut.priv_mode_o == 1, "Now in S-mode with TSR=1");
            Event trap_sret = sim2.step_until_trap();
            check(trap_sret.pc == kB + 0x50 && uint64_t(sim2.dut.csr_mcause_o) == 2,
                  "SRET in S-mode with TSR=1 must raise illegal instruction (cause 2)");

            // 6C: In S-mode: TW intercept for WFI
            CoreSim sim3;
            sim3.init();
            // Clear MPP to U, then set TW (0x200000) and MPP=S (0x800)
            sim3.mem[kB + 0x00] = addi(4, 0, 3);
            sim3.mem[kB + 0x04] = slli(4, 4, 11);              // x4 = 0x1800
            sim3.mem[kB + 0x08] = csrrc(0, 4, 0x300);          // clear MPP to U
            sim3.mem[kB + 0x0c] = addi(1, 0, 2);
            sim3.mem[kB + 0x10] = slli(1, 1, 20);              // x1 = 0x200000 (TW=1)
            sim3.mem[kB + 0x14] = addi(2, 0, 1);
            sim3.mem[kB + 0x18] = slli(2, 2, 11);              // x2 = 0x800 (MPP=S)
            sim3.mem[kB + 0x1c] = csrrs(0, 1, 0x300);          // set TW
            sim3.mem[kB + 0x20] = csrrs(0, 2, 0x300);          // set MPP=S
            sim3.mem[kB + 0x24] = auipc(3, 0);
            sim3.mem[kB + 0x28] = addi(3, 3, 0x3c);            // mepc = kB + 0x60
            sim3.mem[kB + 0x2c] = csrrw(0, 3, 0x341);
            sim3.mem[kB + 0x30] = kMret;                       // enter S-mode at kB + 0x60

            // S-mode code at kB + 0x60:
            sim3.mem[kB + 0x60] = kWfi;                        // WFI with TW=1 -> must trap!

            sim3.step_until_commit_at(kB + 0x30);
            check(sim3.dut.priv_mode_o == 1, "Now in S-mode with TW=1");
            Event trap_wfi_tw = sim3.step_until_trap();
            check(trap_wfi_tw.pc == kB + 0x60 && uint64_t(sim3.dut.csr_mcause_o) == 2,
                  "WFI in S-mode with TW=1 must raise illegal instruction (cause 2)");

            // 6D: SFENCE.VMA is legal in M-mode even when satp is Bare.
            CoreSim sim4;
            sim4.init();
            sim4.mem[kB + 0x00] = kSfenceVma;                  // SFENCE.VMA in M-mode
            Event commit_sfence = sim4.step_until_commit_at(kB + 0x00);
            check(commit_sfence.insn == kSfenceVma && !commit_sfence.rd_write,
                  "M-mode SFENCE.VMA must commit without a register write");

            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 7: M-Origin Exception Never Delegated
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // Set medeleg to all 1s (0x3ff)
            sim.mem[kB + 0x00] = addi(1, 0, 0x3ff);
            sim.mem[kB + 0x04] = csrrw(0, 1, 0x302);          // medeleg = 0x3ff
            sim.mem[kB + 0x08] = auipc(2, 0);
            sim.mem[kB + 0x0c] = addi(2, 2, 0x1f8);           // x2 = kB + 0x200
            sim.mem[kB + 0x10] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            // In M-mode, execute ECALL (cause 11)
            sim.mem[kB + 0x14] = kEcall;

            for (int i = 0; i < 80; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x14, "Trap PC must be kB + 0x14");
                    check(sim.dut.priv_mode_o == 3, "Trap must enter M-mode");
                    check(uint64_t(sim.dut.csr_mcause_o) == 11, "mcause must be 11 (M-mode ECALL)");
                    check(uint64_t(sim.dut.csr_mepc_o) == kB + 0x14, "mepc must be kB + 0x14");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x1800) == 0x1800, "MPP must be M (3)");
                    // S-bank must remain completely untouched:
                    check(uint64_t(sim.dut.csr_sepc_o) == 0, "sepc untouched");
                    check(uint64_t(sim.dut.csr_scause_o) == 0, "scause untouched");
                    break;
                }
            }
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 8: LSU Misaligned Trap Delegation to S-mode (Cause 4, Exact STVAL)
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // Delegate load misaligned (cause 4): bit 4 = 0x10
            sim.mem[kB + 0x00] = addi(1, 0, 0x10);            // bit 4
            sim.mem[kB + 0x04] = csrrw(0, 1, 0x302);          // medeleg[4] = 1
            sim.mem[kB + 0x08] = auipc(2, 0);
            sim.mem[kB + 0x0c] = addi(2, 2, 0x1f8);           // x2 = kB + 0x200
            sim.mem[kB + 0x10] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            sim.mem[kB + 0x14] = addi(4, 0, 3);
            sim.mem[kB + 0x18] = slli(4, 4, 11);              // x4 = 0x1800
            sim.mem[kB + 0x1c] = csrrc(0, 4, 0x300);          // clear MPP to U
            sim.mem[kB + 0x20] = addi(5, 0, 1);
            sim.mem[kB + 0x24] = slli(5, 5, 11);              // x5 = 0x800 (MPP=S)
            sim.mem[kB + 0x28] = csrrs(0, 5, 0x300);          // set MPP=S
            sim.mem[kB + 0x2c] = auipc(3, 0);
            sim.mem[kB + 0x30] = addi(3, 3, 0x14);            // mepc = kB + 0x40
            sim.mem[kB + 0x34] = csrrw(0, 3, 0x341);
            sim.mem[kB + 0x38] = kMret;                       // enter S-mode at kB + 0x40

            // S-mode code at kB + 0x40:
            // LW x6, 1(x0) -> misaligned load at address 1! (LW opcode: 0x00102303)
            sim.mem[kB + 0x40] = addi(6, 0, 0x55);            // init x6 = 0x55
            sim.mem[kB + 0x44] = 0x00102303;                  // lw x6, 1(x0) - misaligned!

            // S-mode handler at kB + 0x200:
            sim.mem[kB + 0x200] = addi(7, 6, 0);              // read x6 into x7

            bool trapped_to_s = false;
            bool x6_preserved = false;

            for (int i = 0; i < 120; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x44, "Trap PC must be kB + 0x44");
                    check(sim.dut.priv_mode_o == 1, "Trap must enter S-mode");
                    check(uint64_t(sim.dut.csr_scause_o) == 4, "scause must be 4 (load misaligned)");
                    check(uint64_t(sim.dut.csr_sepc_o) == kB + 0x44, "sepc must be kB + 0x44");
                    check(uint64_t(sim.dut.csr_stval_o) == 1, "stval must be faulting effective address 1");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x100) == 0x100, "SPP must be S (1)");
                    // M-bank untouched:
                    check(uint64_t(sim.dut.csr_mcause_o) == 0, "mcause untouched");
                    trapped_to_s = true;
                }
                if (e.commit && e.pc == kB + 0x200) {
                    check(e.rd == 7 && e.rd_data == 0x55,
                          "Destination register x6 of misaligned load must NOT be modified");
                    x6_preserved = true;
                    break;
                }
            }
            check(trapped_to_s && x6_preserved, "Delegated misaligned LSU trap to S-mode verified");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 9: Counter Enable Gating via mcounteren.CY in S-mode
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // Delegate illegal instruction (cause 2) to S:
            sim.mem[kB + 0x00] = addi(1, 0, 4);               // bit 2
            sim.mem[kB + 0x04] = csrrw(0, 1, 0x302);          // medeleg[2] = 1
            sim.mem[kB + 0x08] = auipc(2, 0);
            sim.mem[kB + 0x0c] = addi(2, 2, 0x1f8);           // x2 = kB + 0x200
            sim.mem[kB + 0x10] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            sim.mem[kB + 0x14] = addi(4, 0, 3);
            sim.mem[kB + 0x18] = slli(4, 4, 11);              // x4 = 0x1800
            sim.mem[kB + 0x1c] = csrrc(0, 4, 0x300);          // clear MPP to U
            sim.mem[kB + 0x20] = addi(5, 0, 1);
            sim.mem[kB + 0x24] = slli(5, 5, 11);              // x5 = 0x800 (MPP=S)
            sim.mem[kB + 0x28] = csrrs(0, 5, 0x300);          // set MPP=S
            sim.mem[kB + 0x2c] = auipc(3, 0);
            sim.mem[kB + 0x30] = addi(3, 3, 0x14);            // mepc = kB + 0x40
            sim.mem[kB + 0x34] = csrrw(0, 3, 0x341);
            sim.mem[kB + 0x38] = kMret;                       // enter S-mode at kB + 0x40

            // S-mode code at kB + 0x40:
            // csrr x6, cycle (0xc00) -> illegal because mcounteren.CY == 0!
            sim.mem[kB + 0x40] = csrrw(6, 0, 0xc00);

            // Handler at kB + 0x200:
            // SRET to kB + 0x44
            sim.mem[kB + 0x200] = csrrw(1, 0, 0x141);         // sepc
            sim.mem[kB + 0x204] = addi(1, 1, 4);
            sim.mem[kB + 0x208] = csrrw(0, 1, 0x141);         // sepc += 4
            sim.mem[kB + 0x20c] = kSret;

            bool cycle_trapped = false;
            for (int i = 0; i < 100; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x40 && uint64_t(sim.dut.csr_scause_o) == 2,
                          "cycle read in S-mode with mcounteren.CY=0 must trap to S (cause 2)");
                    cycle_trapped = true;
                    break;
                }
            }
            check(cycle_trapped, "mcounteren.CY=0 gating verified");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 10: Explicit SRET-to-U end-to-end execution
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // M-mode at kB:
            // 1. Set medeleg[8] = 1 (User ECALL delegated to S)
            // 2. Set stvec = kB + 0x200
            // 3. Set mepc = kB + 0x40 (S-mode entry point)
            // 4. Set mstatus.MPP = S (0x800) and mstatus.SPP = U (0)
            // 5. mret -> enters S-mode at kB + 0x40
            sim.mem[kB + 0x00] = addi(1, 0, 1);
            sim.mem[kB + 0x04] = slli(1, 1, 8);               // x1 = 0x100 (bit 8 = User ECALL)
            sim.mem[kB + 0x08] = csrrw(0, 1, 0x302);          // medeleg = 0x100
            sim.mem[kB + 0x0c] = auipc(2, 0);                 // x2 = kB + 0x0c
            sim.mem[kB + 0x10] = addi(2, 2, 0x1f4);           // x2 = kB + 0x200
            sim.mem[kB + 0x14] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            sim.mem[kB + 0x18] = auipc(3, 0);                 // x3 = kB + 0x18
            sim.mem[kB + 0x1c] = addi(3, 3, 0x28);            // x3 = kB + 0x40
            sim.mem[kB + 0x20] = csrrw(0, 3, 0x341);          // mepc = kB + 0x40
            sim.mem[kB + 0x24] = addi(4, 0, 3);
            sim.mem[kB + 0x28] = slli(4, 4, 11);              // x4 = 0x1800 (MPP mask)
            sim.mem[kB + 0x2c] = csrrc(0, 4, 0x300);          // clear MPP
            sim.mem[kB + 0x30] = addi(5, 0, 1);
            sim.mem[kB + 0x34] = slli(5, 5, 11);              // x5 = 0x800 (MPP=S)
            sim.mem[kB + 0x38] = csrrs(0, 5, 0x300);          // set MPP=S
            sim.mem[kB + 0x3c] = kMret;

            // S-mode at kB + 0x40:
            // Set sepc = kB + 0x80 (U-mode code)
            // Ensure sstatus.SPP == 0 (U-mode)
            // sret -> enters U-mode at kB + 0x80
            sim.mem[kB + 0x40] = auipc(6, 0);                 // x6 = kB + 0x40
            sim.mem[kB + 0x44] = addi(6, 6, 0x40);            // x6 = kB + 0x80
            sim.mem[kB + 0x48] = csrrw(0, 6, 0x141);          // sepc = kB + 0x80
            sim.mem[kB + 0x4c] = addi(7, 0, 1);
            sim.mem[kB + 0x50] = slli(7, 7, 8);               // x7 = 0x100 (SPP bit)
            sim.mem[kB + 0x54] = csrrc(0, 7, 0x100);          // clear sstatus.SPP (target U)
            sim.mem[kB + 0x58] = kSret;                       // enter U-mode at kB + 0x80

            // U-mode at kB + 0x80:
            sim.mem[kB + 0x80] = addi(8, 8, 42);              // x8 = 42
            sim.mem[kB + 0x84] = kEcall;                      // ecall from U-mode

            // S-mode trap handler at kB + 0x200:
            // 1. verify scause == 8, sepc == kB + 0x84, sstatus.SPP == 0
            // 2. advance sepc by 4
            // 3. sret back to U-mode at kB + 0x88
            sim.mem[kB + 0x200] = csrrw(9, 0, 0x141);         // x9 = sepc
            sim.mem[kB + 0x204] = addi(9, 9, 4);              // sepc += 4
            sim.mem[kB + 0x208] = csrrw(0, 9, 0x141);
            sim.mem[kB + 0x20c] = kSret;

            // U-mode resume at kB + 0x88:
            sim.mem[kB + 0x88] = addi(10, 0, 99);             // x10 = 99

            bool reached_u1 = false;
            bool trapped_to_s = false;
            bool returned_to_u = false;

            for (int i = 0; i < 150; ++i) {
                Event e = sim.tick();
                if (e.commit && e.pc == kB + 0x80) {
                    check(e.priv_mode == 0, "Must be in U-mode (0) at kB+0x80");
                    reached_u1 = true;
                }
                if (e.trap && e.pc == kB + 0x84) {
                    check(uint64_t(sim.dut.csr_scause_o) == 8, "scause must be 8 (User ECALL)");
                    check(uint64_t(sim.dut.csr_sepc_o) == kB + 0x84, "sepc must be kB+0x84");
                    check(uint64_t(sim.dut.csr_stval_o) == 0, "stval must be 0");
                    check((uint64_t(sim.dut.csr_sstatus_o) & 0x100) == 0, "sstatus.SPP must be 0 (came from U)");
                    trapped_to_s = true;
                }
                if (e.commit && e.pc == kB + 0x88) {
                    check(e.priv_mode == 0, "Must be back in U-mode (0) after SRET at kB+0x88");
                    returned_to_u = true;
                    break;
                }
            }
            check(reached_u1, "Must have reached U-mode");
            check(trapped_to_s, "Must have trapped to S-mode on ECALL");
            check(returned_to_u, "Must have returned to U-mode via SRET");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 11: Explicit S-mode sstatus write and M-mode field preservation
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // Setup in M-mode:
            // Set TW=1 (bit 21 = 0x00200000), MPIE=1 (bit 7 = 0x80), MPP=S (bit 11 = 0x800)
            // UXL and SXL are read-only 2 (bits 33:32 = 0x2_0000_0000, 35:34 = 0x8_0000_0000)
            sim.mem[kB + 0x00] = addi(1, 0, 1);
            sim.mem[kB + 0x04] = slli(1, 1, 21);              // x1 = 0x00200000 (TW)
            sim.mem[kB + 0x08] = addi(2, 0, 1);
            sim.mem[kB + 0x0c] = slli(2, 2, 7);               // x2 = 0x80 (MPIE)
            sim.mem[kB + 0x10] = csrrs(0, 1, 0x300);          // set TW
            sim.mem[kB + 0x14] = csrrs(0, 2, 0x300);          // set MPIE
            // Set MPP=S
            sim.mem[kB + 0x18] = addi(4, 0, 3);
            sim.mem[kB + 0x1c] = slli(4, 4, 11);              // x4 = 0x1800
            sim.mem[kB + 0x20] = csrrc(0, 4, 0x300);          // clear MPP
            sim.mem[kB + 0x24] = addi(5, 0, 1);
            sim.mem[kB + 0x28] = slli(5, 5, 11);              // x5 = 0x800 (MPP=S)
            sim.mem[kB + 0x2c] = csrrs(0, 5, 0x300);          // set MPP=S
            sim.mem[kB + 0x30] = auipc(3, 0);                 // x3 = kB + 0x30
            sim.mem[kB + 0x34] = addi(3, 3, 0x10);            // mepc = kB + 0x40
            sim.mem[kB + 0x38] = csrrw(0, 3, 0x341);
            sim.mem[kB + 0x3c] = kMret;                       // enter S-mode at kB + 0x40

            // S-mode at kB + 0x40:
            // Attempt to write all 1s to sstatus:
            // Writable sstatus bits include SIE, SPIE, SPP, SUM and MXR.
            // Bits like TW (bit 21), MPIE (bit 7), MPP (bits 12:11), MIE (bit 3) must NOT be changed!
            sim.mem[kB + 0x40] = addi(6, 0, -1);              // x6 = -1
            sim.mem[kB + 0x44] = csrrs(7, 6, 0x100);          // csrrs sstatus with all 1s; read old into x7
            sim.mem[kB + 0x48] = csrrs(8, 0, 0x100);          // read new sstatus into x8 (no write)
            // Now clear SIE and SPP in sstatus:
            sim.mem[kB + 0x4c] = addi(9, 0, 1);
            sim.mem[kB + 0x50] = slli(9, 9, 8);               // x9 = 0x100 (SPP)
            sim.mem[kB + 0x54] = ori_insn(9, 9, 2);           // x9 = 0x102 (SPP | SIE)
            sim.mem[kB + 0x58] = csrrc(10, 9, 0x100);         // clear SPP and SIE
            sim.mem[kB + 0x5c] = csrrs(11, 0, 0x100);         // read new sstatus into x11 (no write)
            sim.mem[kB + 0x60] = addi(12, 0, 1);              // done marker

            sim.step_until_commit_at(kB + 0x60, 200);

            // Check S-mode view of sstatus:
            // In S-mode: writable mask is 0x122 (SIE=1, SPIE=1, SPP=1)
            // After clearing SPP and SIE, SPP=0, SIE=0, SPIE=1
            check((uint64_t(sim.dut.csr_sstatus_o) & 0x122) == 0x020,
                  "sstatus SIE and SPP bits properly cleared, SPIE preserved");
            check((uint64_t(sim.dut.csr_sstatus_o) & 0xc0000) == 0xc0000,
                  "sstatus SUM and MXR writes must be preserved");

            // Check M-mode fields in mstatus:
            // TW (bit 21) must STILL BE 1!
            check((uint64_t(sim.dut.csr_mstatus_o) & (1ULL << 21)) != 0, "mstatus.TW must remain 1");
            // MPIE (bit 7) must STILL BE 1!
            check((uint64_t(sim.dut.csr_mstatus_o) & (1ULL << 7)) != 0, "mstatus.MPIE must remain 1");
            // SXL (bits 35:34) must STILL BE 2!
            check(((uint64_t(sim.dut.csr_mstatus_o) >> 34) & 3) == 2, "mstatus.SXL must remain 2");
            // UXL (bits 33:32) must STILL BE 2!
            check(((uint64_t(sim.dut.csr_mstatus_o) >> 32) & 3) == 2, "mstatus.UXL must remain 2");
            // MPP was set to U on MRET, must not be corrupted by S-mode write:
            check(((uint64_t(sim.dut.csr_mstatus_o) >> 11) & 3) == 0, "mstatus.MPP after MRET is U (0)");

            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 12: M-mode delegable sync trap with medeleg set still traps to M
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // In M-mode at kB:
            // Set medeleg = 0xffff (delegate all synchronous exceptions)
            // Set mtvec = kB + 0x100, stvec = kB + 0x200
            sim.mem[kB + 0x00] = addi(1, 0, -1);              // x1 = -1
            sim.mem[kB + 0x04] = csrrw(0, 1, 0x302);          // medeleg = 0x3ff
            sim.mem[kB + 0x08] = auipc(2, 0);                 // x2 = kB + 0x08
            sim.mem[kB + 0x0c] = addi(2, 2, 0xf8);            // x2 = kB + 0x100
            sim.mem[kB + 0x10] = csrrw(0, 2, 0x305);          // mtvec = kB + 0x100
            sim.mem[kB + 0x14] = addi(2, 2, 0x100);           // x2 = kB + 0x200
            sim.mem[kB + 0x18] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            // Execute ebreak in M-mode (cause 3, delegated in medeleg)
            sim.mem[kB + 0x1c] = kEbreak;

            // M-mode handler at kB + 0x100:
            sim.mem[kB + 0x100] = addi(3, 0, 1);              // marker

            bool trapped_to_m = false;
            for (int i = 0; i < 40; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x1c, "trap PC must be ebreak");
                    check(uint64_t(sim.dut.csr_mcause_o) == 3, "mcause must be 3 (Breakpoint)");
                    check(uint64_t(sim.dut.csr_mepc_o) == kB + 0x1c, "mepc must be ebreak PC");
                    check(sim.dut.priv_mode_o == 3, "Privilege must remain M-mode");
                    // Verify S-mode trap CSRs were NOT touched:
                    check(uint64_t(sim.dut.csr_scause_o) == 0, "scause must remain 0");
                    check(uint64_t(sim.dut.csr_sepc_o) == 0, "sepc must remain 0");
                    trapped_to_m = true;
                    break;
                }
            }
            check(trapped_to_m, "M-mode delegable exception must trap to M-mode");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 13: Delegated store-misaligned traps to S-mode (cause 6, stval = addr)
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // In M-mode at kB:
            // 1. Delegate store misaligned (bit 6): medeleg[6] = 1
            // 2. Set stvec = kB + 0x200
            // 3. mepc = kB + 0x40, MPP = S
            // 4. mret -> enter S-mode at kB + 0x40
            sim.mem[kB + 0x00] = addi(1, 0, 1);
            sim.mem[kB + 0x04] = slli(1, 1, 6);               // x1 = 0x40 (bit 6 = store misaligned)
            sim.mem[kB + 0x08] = csrrw(0, 1, 0x302);          // medeleg = 0x40
            sim.mem[kB + 0x0c] = auipc(2, 0);                 // x2 = kB + 0x0c
            sim.mem[kB + 0x10] = addi(2, 2, 0x1f4);           // x2 = kB + 0x200
            sim.mem[kB + 0x14] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            sim.mem[kB + 0x18] = auipc(3, 0);                 // x3 = kB + 0x18
            sim.mem[kB + 0x1c] = addi(3, 3, 0x28);            // x3 = kB + 0x40
            sim.mem[kB + 0x20] = csrrw(0, 3, 0x341);          // mepc = kB + 0x40
            sim.mem[kB + 0x24] = addi(4, 0, 3);
            sim.mem[kB + 0x28] = slli(4, 4, 11);              // x4 = 0x1800
            sim.mem[kB + 0x2c] = csrrc(0, 4, 0x300);          // clear MPP
            sim.mem[kB + 0x30] = addi(5, 0, 1);
            sim.mem[kB + 0x34] = slli(5, 5, 11);              // x5 = 0x800 (MPP=S)
            sim.mem[kB + 0x38] = csrrs(0, 5, 0x300);          // set MPP=S
            sim.mem[kB + 0x3c] = kMret;                       // enter S-mode at kB + 0x40

            // S-mode at kB + 0x40:
            // Execute misaligned store: sd x5, 1(x0) -> target address = 1 (misaligned for 8-byte store)
            sim.mem[kB + 0x40] = sd_insn(5, 0, 1);

            // Handler at kB + 0x200
            sim.mem[kB + 0x200] = addi(6, 0, 1);

            bool trapped_misaligned = false;
            for (int i = 0; i < 100; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x40, "trap PC must be misaligned store");
                    check(sim.dut.priv_mode_o == 1, "Must trap to S-mode");
                    check(uint64_t(sim.dut.csr_scause_o) == 6, "scause must be 6 (Store address misaligned)");
                    check(uint64_t(sim.dut.csr_stval_o) == 1, "stval must be 1 (faulting address)");
                    check(uint64_t(sim.dut.csr_sepc_o) == kB + 0x40, "sepc must be kB+0x40");
                    check((uint64_t(sim.dut.csr_sstatus_o) & 0x100) != 0, "sstatus.SPP must be 1 (came from S)");
                    trapped_misaligned = true;
                    break;
                }
            }
            check(trapped_misaligned, "Delegated store misaligned must trap to S-mode");
            ++scenarios_passed;
        }

        // ====================================================================
        // Scenario 14: Delegated load access fault (cause 5, stval = addr)
        // ====================================================================
        {
            CoreSim sim;
            sim.init();

            // In M-mode at kB:
            // 1. Delegate load access fault (bit 5): medeleg = 0x20
            // 2. Set stvec = kB + 0x200
            // 3. mepc = kB + 0x40, MPP = S
            // 4. mret -> enter S-mode at kB + 0x40
            sim.mem[kB + 0x00] = addi(1, 0, 2);
            sim.mem[kB + 0x04] = slli(1, 1, 4);               // x1 = 0x20 (bit 5)
            sim.mem[kB + 0x08] = csrrw(0, 1, 0x302);          // medeleg = 0x20
            sim.mem[kB + 0x0c] = auipc(2, 0);                 // x2 = kB + 0x0c
            sim.mem[kB + 0x10] = addi(2, 2, 0x1f4);           // x2 = kB + 0x200
            sim.mem[kB + 0x14] = csrrw(0, 2, 0x105);          // stvec = kB + 0x200
            sim.mem[kB + 0x18] = auipc(3, 0);                 // x3 = kB + 0x18
            sim.mem[kB + 0x1c] = addi(3, 3, 0x28);            // x3 = kB + 0x40
            sim.mem[kB + 0x20] = csrrw(0, 3, 0x341);          // mepc = kB + 0x40
            sim.mem[kB + 0x24] = addi(4, 0, 3);
            sim.mem[kB + 0x28] = slli(4, 4, 11);              // x4 = 0x1800
            sim.mem[kB + 0x2c] = csrrc(0, 4, 0x300);          // clear MPP
            sim.mem[kB + 0x30] = addi(5, 0, 1);
            sim.mem[kB + 0x34] = slli(5, 5, 11);              // x5 = 0x800 (MPP=S)
            sim.mem[kB + 0x38] = csrrs(0, 5, 0x300);          // set MPP=S
            sim.mem[kB + 0x3c] = kMret;                       // enter S-mode at kB + 0x40

            // S-mode at kB + 0x40:
            // Setup address x10 = 0x1000
            sim.mem[kB + 0x40] = addi(10, 0, 0x100);
            sim.mem[kB + 0x44] = slli(10, 10, 4);             // x10 = 0x1000
            sim.mem[kB + 0x48] = lw_insn(6, 10, 0);           // lw x6, 0(x10) -> faults

            // Inject error on dmem response for this load
            sim.inject_dmem_rsp_error = true;

            bool trapped_load_fault = false;
            for (int i = 0; i < 100; ++i) {
                Event e = sim.tick();
                if (e.trap) {
                    check(e.pc == kB + 0x48, "trap PC must be lw instruction");
                    check(sim.dut.priv_mode_o == 1, "Must trap to S-mode");
                    check(uint64_t(sim.dut.csr_scause_o) == 5, "scause must be 5 (Load access fault)");
                    check(uint64_t(sim.dut.csr_stval_o) == 0x1000, "stval must be 0x1000 (faulting address)");
                    check(uint64_t(sim.dut.csr_sepc_o) == kB + 0x48, "sepc must be kB+0x48");
                    check((uint64_t(sim.dut.csr_sstatus_o) & 0x100) != 0, "sstatus.SPP must be 1");
                    trapped_load_fault = true;
                    break;
                }
            }
            check(trapped_load_fault, "Delegated load access fault must trap to S-mode");
            ++scenarios_passed;
        }

        std::cout << "{\"status\":\"pass\",\"scenarios\":" << scenarios_passed << "}\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "CORE_SMODE_S0_MISMATCH scenario=" << scenarios_passed + 1
                  << " reason=" << e.what() << '\n';
        return 1;
    }
}
