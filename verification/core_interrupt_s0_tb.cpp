#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>

static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
static uint32_t slli_insn(unsigned rd, unsigned rs1, unsigned shamt) {
    return (shamt << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13;
}
static uint32_t ori_insn(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm & 0xfff) << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x13;
}
static uint32_t lui(unsigned rd, uint32_t imm20) {
    return (imm20 << 12) | (rd << 7) | 0x37;
}
static uint32_t auipc(unsigned rd, uint32_t imm20) {
    return (imm20 << 12) | (rd << 7) | 0x17;
}
static uint32_t or_insn(unsigned rd, unsigned rs1, unsigned rs2) {
    return (rs2 << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x33;
}
static uint32_t csrsi(unsigned csr, unsigned uimm) {
    return (csr << 20) | ((uimm & 0x1f) << 15) | (6 << 12) | 0x73;
}
static uint32_t csrrw(unsigned rd, unsigned rs1, unsigned csr) {
    return (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73;
}
static uint32_t csrrs(unsigned rd, unsigned rs1, unsigned csr) {
    return (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73;
}
static uint32_t lw(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm & 0xfff) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03;
}
static uint32_t csrrc(unsigned rd, unsigned rs1, unsigned csr) {
    return (csr << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x73;
}
static uint32_t csrci(unsigned csr, unsigned uimm) {
    return (csr << 20) | ((uimm & 0x1f) << 15) | (7 << 12) | 0x73;
}
static uint32_t mret_insn() {
    return 0x30200073;
}
static uint32_t sret_insn() {
    return 0x10200073;
}
static uint32_t ecall_insn() {
    return 0x00000073;
}

struct TestSim {
    Vfursoy_s0_core dut;
    std::map<uint64_t, uint32_t> imem;
    std::map<uint64_t, uint64_t> dmem;

    bool imem_pending = false;
    uint32_t imem_insn = 0;
    bool next_imem_pending = false;
    uint32_t next_imem_insn = 0;
    int imem_delay = 0;
    int imem_delay_counter = 0;
    uint64_t imem_delay_addr = 0;

    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    bool next_dmem_rsp_pending = false;
    uint64_t next_dmem_rsp_data = 0;

    int dmem_delay = 0;
    int dmem_delay_counter = 0;

    uint64_t cycles = 0;
    uint64_t commits = 0;
    uint64_t traps = 0;

    uint64_t last_commit_pc = 0;
    uint32_t last_commit_insn = 0;
    uint8_t last_commit_rd = 0;
    uint64_t last_commit_rd_data = 0;
    bool last_commit_rd_write = false;
    uint64_t last_trap_pc = 0;
    uint64_t last_trap_cause = 0;
    uint64_t last_scause = 0;
    uint64_t last_mcause = 0;
    uint8_t last_trap_priv = 3;
    bool trap_this_cycle = false;
    bool commit_this_cycle = false;
    bool fence_i_this_cycle = false;

    void reset() {
        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.irq_software_i = 0;
        dut.irq_timer_i = 0;
        dut.irq_external_i = 0;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = 0;
        dut.dmem_req_ready_i = 1;
        dut.dmem_rsp_valid_i = 0;
        cycles = 0;
        commits = 0;
        traps = 0;
        last_commit_pc = 0;
        last_commit_insn = 0;
        last_commit_rd = 0;
        last_commit_rd_data = 0;
        last_commit_rd_write = false;
        last_trap_pc = 0;
        last_trap_cause = 0;
        last_scause = 0;
        last_mcause = 0;
        last_trap_priv = 3;
        trap_this_cycle = false;
        commit_this_cycle = false;
        fence_i_this_cycle = false;
        imem_pending = false;
        next_imem_pending = false;
        dmem_rsp_pending = false;
        next_dmem_rsp_pending = false;
        imem_delay = 0;
        imem_delay_counter = 0;
        dmem_delay = 0;
        dmem_delay_counter = 0;
        imem.clear();
        dmem.clear();
        dut.eval();
        for (int i = 0; i < 2; ++i) {
            dut.clk_i = 0; dut.rst_i = 1; dut.eval();
            dut.clk_i = 1; dut.rst_i = 1; dut.eval();
            ++cycles;
        }
        dut.rst_i = 0;
        dut.eval();
        dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_cfg_q[0] = 0x1f;
        dut.rootp->fursoy_s0_core__DOT__pmp__DOT__pmp_addr_q[0] = 0x3fffffffffffffULL;
        dut.eval();
    }

    void tick() {
        // Phase 1: Clock low
        dut.clk_i = 0;
        dut.rst_i = 0;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = imem_pending;
        dut.imem_rsp_insn_i = imem_insn;
        dut.dmem_req_ready_i = 1;
        dut.dmem_rsp_valid_i = dmem_rsp_pending;
        dut.dmem_rsp_data_i = dmem_rsp_data;
        dut.eval();

        bool imem_rsp_fire = imem_pending && dut.imem_rsp_ready_o;
        bool dmem_rsp_fire = dmem_rsp_pending && dut.dmem_rsp_ready_o;
        bool imem_req_fire = dut.imem_req_valid_o && dut.imem_req_ready_i;
        bool dmem_req_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;

        next_imem_pending = imem_pending;
        next_imem_insn = imem_insn;
        next_dmem_rsp_pending = dmem_rsp_pending;
        next_dmem_rsp_data = dmem_rsp_data;

        if (imem_rsp_fire) {
            next_imem_pending = false;
        }
        if (imem_req_fire) {
            uint64_t addr = dut.imem_req_addr_o;
            if (imem_delay > 0) {
                imem_delay_counter = imem_delay;
                imem_delay_addr = addr;
            } else {
                next_imem_insn = imem.count(addr) ? imem[addr] :
                                 (imem.count(addr & 0xffffffffULL) ? imem[addr & 0xffffffffULL] : 0x00000013);
                next_imem_pending = true;
            }
        }

        if (imem_delay_counter > 0 && --imem_delay_counter == 0) {
            next_imem_insn = imem.count(imem_delay_addr) ? imem[imem_delay_addr] :
                             (imem.count(imem_delay_addr & 0xffffffffULL) ? imem[imem_delay_addr & 0xffffffffULL] : 0x00000013);
            next_imem_pending = true;
        }

        if (dmem_rsp_fire) {
            next_dmem_rsp_pending = false;
        }
        if (dmem_req_fire) {
            uint64_t addr = dut.dmem_req_addr_o;
            uint64_t lookup_addr = dmem.count(addr) ? addr :
                                   (dmem.count(addr & 0xffffffffULL) ? (addr & 0xffffffffULL) : addr);
            if (dut.dmem_req_store_o) {
                dmem[lookup_addr] = dut.dmem_req_store_data_o;
            } else {
                if (dmem_delay > 0) {
                    dmem_delay_counter = dmem_delay;
                } else {
                    next_dmem_rsp_data = dmem.count(lookup_addr) ? dmem[lookup_addr] : 0;
                    next_dmem_rsp_pending = true;
                }
            }
        }

        if (dmem_delay_counter > 0) {
            if (--dmem_delay_counter == 0) {
                uint64_t addr = dut.dmem_req_addr_o;
                uint64_t lookup_addr = dmem.count(addr) ? addr :
                                       (dmem.count(addr & 0xffffffffULL) ? (addr & 0xffffffffULL) : addr);
                next_dmem_rsp_data = dmem.count(lookup_addr) ? dmem[lookup_addr] : 0;
                next_dmem_rsp_pending = true;
            }
        }

        commit_this_cycle = bool(dut.commit_valid_o);
        fence_i_this_cycle = bool(dut.fence_i_valid_o);
        if (commit_this_cycle) {
            ++commits;
            last_commit_pc = dut.commit_pc_o;
            last_commit_insn = dut.commit_insn_o;
            last_commit_rd = dut.commit_rd_o;
            last_commit_rd_data = dut.commit_rd_data_o;
            last_commit_rd_write = dut.commit_rd_write_o;
        }

        trap_this_cycle = bool(dut.trap_valid_o);
        if (trap_this_cycle) {
            ++traps;
            last_trap_pc = dut.trap_pc_o;
        }

        // Phase 2: Clock high
        dut.clk_i = 1;
        dut.eval();
        ++cycles;

        if (trap_this_cycle) {
            last_mcause = uint64_t(dut.csr_mcause_o);
            last_scause = uint64_t(dut.csr_scause_o);
            last_trap_priv = uint8_t(dut.priv_mode_o);
            last_trap_cause = (last_trap_priv == 1) ? last_scause : last_mcause;
        }

        imem_pending = next_imem_pending;
        imem_insn = next_imem_insn;
        dmem_rsp_pending = next_dmem_rsp_pending;
        dmem_rsp_data = next_dmem_rsp_data;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto check = [](bool cond, const char* msg) {
        if (!cond) throw std::runtime_error(msg);
    };

    try {
        // Test 1: Global MIE masking (mstatus.MIE = 0 suppresses interrupt)
        {
            TestSim sim;
            sim.reset();
            // Set mie with MTIE=1 (bit 7 = 0x80)
            sim.dut.irq_timer_i = 1;
            // Execute 10 cycles of NOPs
            for (int i = 0; i < 20; ++i) sim.tick();
            check(sim.traps == 0, "Test 1 failed: interrupt taken while mstatus.MIE=0");
            check(uint64_t(sim.dut.csr_mip_o) == 0x80, "Test 1 failed: mip does not reflect irq_timer_i");
        }

        // Test 2: Per-interrupt MIE masking (mstatus.MIE = 1, but mie = 0)
        {
            TestSim sim;
            sim.reset();
            // Enable global MIE via csrsi mstatus, 8
            sim.imem[0x80000000] = csrsi(0x300, 8);
            sim.dut.irq_timer_i = 1;
            sim.dut.irq_software_i = 1;
            sim.dut.irq_external_i = 1;
            for (int i = 0; i < 20; ++i) sim.tick();
            check(sim.traps == 0, "Test 2 failed: interrupt taken while mie=0");
        }

        // Test 3: Timer interrupt entry, precise mepc, mcause, mtval, and mret return
        {
            TestSim sim;
            sim.reset();
            uint64_t handler_addr = 0xffffffff80000100ULL;
            sim.imem[0x80000000] = lui(5, 0x80000);
            sim.imem[0x80000004] = addi(5, 5, 0x100);
            sim.imem[0x80000008] = csrrw(0, 5, 0x305);
            sim.imem[0x8000000c] = addi(1, 0, 0x80);
            sim.imem[0x80000010] = csrrs(0, 1, 0x304);
            sim.imem[0x80000014] = csrsi(0x300, 8);
            sim.imem[0x80000018] = addi(2, 0, 20);
            sim.imem[handler_addr] = mret_insn();

            while (sim.commits < 6) sim.tick();

            sim.dut.irq_timer_i = 1;

            bool saw_irq = false;
            for (int i = 0; i < 40; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 7))) {
                    saw_irq = true;
                    check(sim.last_trap_pc == 0x80000018, "Test 3: mepc mismatch on timer interrupt");
                    check(uint64_t(sim.dut.csr_mepc_o) == 0x80000018, "Test 3: csr_mepc_o mismatch");
                    check(uint64_t(sim.dut.csr_mtval_o) == 0, "Test 3: mtval must be 0 for interrupt");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x88) == 0x80, "Test 3: MPIE=1, MIE=0 expected");
                    // Deassert IRQ in handler
                    sim.dut.irq_timer_i = 0;
                }
            }
            check(saw_irq, "Test 3 failed: timer interrupt was not taken");
        }

        // Test 4: Software interrupt cause (cause = (1ULL << 63) | 3)
        {
            TestSim sim;
            sim.reset();
            uint64_t handler_addr = 0x80000100;
            sim.imem[0x80000000] = csrsi(0x300, 8);     // MIE
            sim.imem[0x80000004] = csrsi(0x304, 0x08);    // MSIE = 0x08
            sim.imem[handler_addr] = mret_insn();

            while (sim.commits < 2) sim.tick();

            sim.dut.irq_software_i = 1;
            bool saw_sw_irq = false;
            for (int i = 0; i < 30; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 3))) {
                    saw_sw_irq = true;
                    sim.dut.irq_software_i = 0;
                }
            }
            check(saw_sw_irq, "Test 4 failed: software interrupt was not taken with cause=3");
        }

        // Test 5: Interrupt prioritization (MEI > MSI > MTI)
        {
            TestSim sim;
            sim.reset();
            // Load 0x888 into mie via addi/slli/ori
            sim.imem[0x80000000] = addi(1, 0, 0x88);
            sim.imem[0x80000004] = slli_insn(1, 1, 4);   // x1 = 0x880
            sim.imem[0x80000008] = ori_insn(1, 1, 8);    // x1 = 0x888
            sim.imem[0x8000000c] = csrrs(0, 1, 0x304);   // mie |= 0x888
            sim.imem[0x80000010] = csrsi(0x300, 8);      // mstatus.MIE = 1
            while (sim.commits < 5) sim.tick();

            // Assert all three sources: MEI must beat both MSI and MTI.
            sim.dut.irq_external_i = 1;
            sim.dut.irq_software_i = 1;
            sim.dut.irq_timer_i = 1;
            bool saw_priority = false;
            for (int i = 0; i < 30; ++i) {
                sim.tick();
                if (sim.trap_this_cycle) {
                    check(sim.last_trap_cause == ((1ULL << 63) | 11), "Test 5: MEI must have higher priority than MTI");
                    saw_priority = true;
                    break;
                }
            }
            check(saw_priority, "Test 5 failed: MEI priority trap not seen");

            // Now test MSI > MTI
            TestSim sim2;
            sim2.reset();
            sim2.imem[0x80000000] = addi(1, 0, 0x88);
            sim2.imem[0x80000004] = slli_insn(1, 1, 4);
            sim2.imem[0x80000008] = ori_insn(1, 1, 8);
            sim2.imem[0x8000000c] = csrrs(0, 1, 0x304);
            sim2.imem[0x80000010] = csrsi(0x300, 8);
            while (sim2.commits < 5) sim2.tick();
            sim2.dut.irq_software_i = 1;
            sim2.dut.irq_timer_i = 1;
            bool saw_msi_priority = false;
            for (int i = 0; i < 30; ++i) {
                sim2.tick();
                if (sim2.trap_this_cycle) {
                    check(sim2.last_trap_cause == ((1ULL << 63) | 3), "Test 5: MSI must have higher priority than MTI");
                    saw_msi_priority = true;
                    break;
                }
            }
            check(saw_msi_priority, "Test 5 failed: MSI priority trap not seen");
        }

        // Test 6: Synchronous exception priority over pending interrupt
        {
            TestSim sim;
            sim.reset();
            sim.imem[0x80000000] = addi(1, 0, 0x80);
            sim.imem[0x80000004] = csrrs(0, 1, 0x304);   // MTIE
            sim.imem[0x80000008] = csrsi(0x300, 8);      // MIE
            sim.imem[0x8000000c] = ecall_insn();         // ECALL instruction causes sync trap
            while (sim.commits < 3) sim.tick();

            // First buffer ECALL, then assert the timer while that synchronous
            // exception is ready to execute.
            sim.tick();
            sim.tick();
            sim.dut.irq_timer_i = 1;
            bool saw_sync_win = false;
            for (int i = 0; i < 30; ++i) {
                sim.tick();
                if (sim.trap_this_cycle) {
                    check(sim.last_trap_cause == 11, "Test 6: ECALL sync exception must beat pending interrupt");
                    saw_sync_win = true;
                    break;
                }
            }
            check(saw_sync_win, "Test 6 failed: sync exception did not take priority");
        }

        // Test 7: Vectored mtvec mode
        {
            TestSim sim;
            sim.reset();
            sim.imem[0x80000000] = lui(1, 0x80000);
            sim.imem[0x80000004] = addi(1, 1, 0x201);
            sim.imem[0x80000008] = csrrw(0, 1, 0x305);
            sim.imem[0x8000000c] = addi(2, 0, 0x80);
            sim.imem[0x80000010] = csrrs(0, 2, 0x304);
            sim.imem[0x80000014] = csrsi(0x300, 8);
            sim.imem[0x80000018] = addi(3, 0, 5);
            sim.imem[0x8000021c] = mret_insn();
            sim.imem[0xffffffff8000021cULL] = mret_insn();

            while (sim.commits < 6) sim.tick();

            sim.dut.irq_timer_i = 1;
            bool saw_vectored_redirect = false;
            for (int i = 0; i < 40; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 7))) {
                    saw_vectored_redirect = true;
                    sim.dut.irq_timer_i = 0;
                    while (!sim.dut.imem_req_valid_o) sim.tick();
                    check(uint32_t(sim.dut.imem_req_addr_o) == 0x8000021c, "Test 7: vectored PC must redirect to BASE + 4 * 7");
                    break;
                }
            }
            check(saw_vectored_redirect, "Test 7 failed: vectored interrupt redirect not seen");
        }

        // Test 8: Interrupt arriving during outstanding memory load (must complete load first)
        {
            TestSim sim;
            sim.reset();
            sim.dmem_delay = 3; // 3 cycles memory delay
            sim.imem[0x80000000] = addi(1, 0, 0x80);
            sim.imem[0x80000004] = csrrs(0, 1, 0x304);   // MTIE
            sim.imem[0x80000008] = csrsi(0x300, 8);      // MIE
            sim.imem[0x8000000c] = lw(5, 0, 0x40);       // load word from 0x40
            sim.imem[0x80000010] = addi(6, 5, 1);        // next instruction
            sim.dmem[0x40] = 100;

            // Wait until LW has issued a dmem request (LSU in-flight)
            while (!sim.dut.dmem_req_valid_o) sim.tick();

            // Assert timer IRQ while LSU is in-flight waiting for memory response
            sim.dut.irq_timer_i = 1;
            bool load_committed = false;
            bool irq_taken_after = false;

            for (int i = 0; i < 40; ++i) {
                sim.tick();
                if (sim.commit_this_cycle) {
                    if (sim.last_commit_pc == 0x8000000c) {
                        load_committed = true;
                        check(sim.traps == 0, "Test 8: interrupt must not interrupt in-flight load");
                    }
                }
                if (sim.trap_this_cycle) {
                    if (load_committed) {
                        check(sim.last_trap_cause == ((1ULL << 63) | 7), "Test 8: timer interrupt cause expected");
                        check(sim.last_trap_pc == 0x80000010, "Test 8: mepc must point to instruction AFTER load");
                        irq_taken_after = true;
                        break;
                    }
                }
            }
            check(load_committed && irq_taken_after, "Test 8 failed: in-flight load not completed cleanly before interrupt");
        }

        // Test 9: A level interrupt remains pending across MRET and is retaken.
        {
            TestSim sim;
            sim.reset();
            sim.imem[0x80000000] = lui(5, 0x80000);
            sim.imem[0x80000004] = addi(5, 5, 0x100);
            sim.imem[0x80000008] = csrrw(0, 5, 0x305);
            sim.imem[0x8000000c] = addi(1, 0, 0x80);
            sim.imem[0x80000010] = csrrs(0, 1, 0x304);
            sim.imem[0x80000014] = csrsi(0x300, 8);
            sim.imem[0x80000018] = addi(2, 0, 20);
            sim.imem[0xffffffff80000100ULL] = mret_insn();
            while (sim.commits < 6) sim.tick();
            sim.dut.irq_timer_i = 1;
            unsigned timer_traps = 0;
            for (int i = 0; i < 100 && timer_traps < 2; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && sim.last_trap_cause == ((1ULL << 63) | 7)) {
                    ++timer_traps;
                    check(sim.last_trap_pc == 0x80000018, "Test 9: persistent timer mepc mismatch");
                }
            }
            sim.dut.irq_timer_i = 0;
            check(timer_traps == 2, "Test 9 failed: level interrupt was not retaken after mret");
        }

        // Test 10: An interrupt during a delayed instruction response redirects
        // to the trap vector without committing the stale fetched instruction.
        {
            TestSim sim;
            sim.reset();
            sim.imem[0x80000000] = addi(1, 0, 0x80);
            sim.imem[0x80000004] = csrrs(0, 1, 0x304);
            sim.imem[0x80000008] = csrsi(0x300, 8);
            sim.imem[0x8000000c] = addi(2, 0, 9);
            while (sim.commits < 3) sim.tick();
            sim.imem_delay = 4;
            sim.tick(); // Issue the next fetch and enter RESPONSE with no reply.
            sim.dut.irq_timer_i = 1;
            bool saw_fetch_stall_irq = false;
            for (int i = 0; i < 30; ++i) {
                sim.tick();
                if (sim.trap_this_cycle) {
                    check(sim.last_trap_cause == ((1ULL << 63) | 7), "Test 10: timer cause expected");
                    check(sim.last_trap_pc == 0x8000000c, "Test 10: mepc must name delayed next instruction");
                    check(!sim.commit_this_cycle, "Test 10: interrupt and commit must not coincide");
                    saw_fetch_stall_irq = true;
                    sim.dut.irq_timer_i = 0;
                    break;
                }
            }
            check(saw_fetch_stall_irq, "Test 10 failed: delayed fetch blocked interrupt entry");
        }

        // Test 11: The same redirect rule applies when the interrupt coincides
        // with acceptance of the next instruction request.
        {
            TestSim sim;
            sim.reset();
            sim.imem[0x80000000] = addi(1, 0, 0x80);
            sim.imem[0x80000004] = csrrs(0, 1, 0x304);
            sim.imem[0x80000008] = csrsi(0x300, 8);
            sim.imem[0x8000000c] = addi(2, 0, 9);
            while (sim.commits < 3) sim.tick();
            sim.imem_delay = 4;
            sim.dut.irq_timer_i = 1;
            sim.tick();
            check(sim.trap_this_cycle && sim.last_trap_cause == ((1ULL << 63) | 7),
                  "Test 11: request-boundary timer interrupt expected");
            check(sim.last_trap_pc == 0x8000000c && !sim.commit_this_cycle,
                  "Test 11: stale request must not commit before trap");
            sim.dut.irq_timer_i = 0;
            sim.imem_delay = 0; // Only the stale request is intentionally delayed.
            for (int i = 0; i < 12; ++i) sim.tick();
            check(sim.commits > 3,
                  "Test 11: stale response was not drained after redirect");
        }

        // Helper: setup M-mode to configure delegation, enables, stvec, mtvec, and switch to S-mode at 0x80000060
        auto setup_smode_env = [&](TestSim& sim, bool sie_enable, uint64_t stvec_addr,
                                   uint64_t mtvec_addr = 0x80000100ULL,
                                   uint64_t extra_mie = 0,
                                   uint64_t inject_mip = 0,
                                   uint64_t mideleg_val = 0x222) {
            // 1. Configure mideleg = mideleg_val
            sim.imem[0x80000000] = addi(1, 0, int(mideleg_val & 0xfff));
            sim.imem[0x80000004] = addi(0, 0, 0);
            sim.imem[0x80000008] = addi(0, 0, 0);
            sim.imem[0x8000000c] = csrrw(0, 1, 0x303);     // mideleg = mideleg_val

            // 2. Configure mie |= 0x222 | extra_mie
            if (extra_mie != 0) {
                sim.imem[0x80000010] = addi(2, 0, int(extra_mie & 0xfff));
                sim.imem[0x80000014] = or_insn(1, 1, 2);
            } else {
                sim.imem[0x80000010] = addi(0, 0, 0);
                sim.imem[0x80000014] = addi(0, 0, 0);
            }
            sim.imem[0x80000018] = csrrs(0, 1, 0x304);     // mie |= x1

            // 3. Configure stvec = stvec_addr
            sim.imem[0x8000001c] = auipc(2, 0);
            sim.imem[0x80000020] = addi(2, 2, int((stvec_addr & 0xffffffffULL) - 0x8000001cULL));
            sim.imem[0x80000024] = csrrw(0, 2, 0x105);     // stvec = stvec_addr

            // 4. Configure mtvec = mtvec_addr
            sim.imem[0x80000028] = auipc(2, 0);
            sim.imem[0x8000002c] = addi(2, 2, int((mtvec_addr & 0xffffffffULL) - 0x80000028ULL));
            sim.imem[0x80000030] = csrrw(0, 2, 0x305);     // mtvec = mtvec_addr

            // 5. Configure mepc = 0x80000060 (S-mode entry point)
            sim.imem[0x80000034] = auipc(3, 0);
            sim.imem[0x80000038] = addi(3, 3, int(0x80000060ULL - 0x80000034ULL));
            sim.imem[0x8000003c] = csrrw(0, 3, 0x341);     // mepc = 0x80000060

            // 6. Set mstatus.MPP = S (clear bit 12)
            sim.imem[0x80000040] = addi(4, 0, 1);
            sim.imem[0x80000044] = slli_insn(4, 4, 12);    // x4 = 0x1000
            sim.imem[0x80000048] = csrrc(0, 4, 0x300);     // clear bit 12 -> MPP=S (0x800)

            // 7. Configure sstatus.SIE via mstatus bit 1
            sim.imem[0x8000004c] = sie_enable ? csrsi(0x300, 2) : addi(0, 0, 0); // SIE

            // 8. Injected mip bits if requested
            if (inject_mip != 0) {
                sim.imem[0x80000050] = addi(8, 0, int(inject_mip & 0xfff));
                sim.imem[0x80000054] = csrrs(0, 8, 0x344); // mip |= inject_mip
            } else {
                sim.imem[0x80000050] = addi(0, 0, 0);
                sim.imem[0x80000054] = addi(0, 0, 0);
            }

            // 9. Enter S-mode via mret
            sim.imem[0x80000058] = addi(0, 0, 0);
            sim.imem[0x8000005c] = mret_insn();            // enter S-mode at 0x80000060
        };

        // Test 12: Delegated SSIP delivery to S-mode, exact trap bank state, sip.SSIP clear, and sret
        {
            TestSim sim;
            sim.reset();
            setup_smode_env(sim, true, 0x80000200);
            // S-mode code at 0x80000060:
            sim.imem[0x80000060] = addi(5, 0, 10);
            sim.imem[0x80000064] = csrsi(0x144, 2);         // set sip.SSIP (bit 1)
            sim.imem[0x80000068] = addi(6, 0, 20);         // interrupted before this commits
            sim.imem[0x8000006c] = addi(7, 6, 1);
            // S-mode handler at 0x80000200:
            sim.imem[0x80000200] = csrci(0x144, 2);         // clear sip.SSIP
            sim.imem[0x80000204] = sret_insn();             // returns to 0x80000068

            bool saw_ssip = false;
            for (int i = 0; i < 120; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 1))) {
                    saw_ssip = true;
                    check(sim.last_trap_priv == 1, "Test 12: must trap to S-mode");
                    check(sim.last_trap_pc == 0x80000068, "Test 12: sepc must name interrupted instruction 0x80000068");
                    check(uint64_t(sim.dut.csr_stval_o) == 0, "Test 12: stval must be 0 for interrupt");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x122) == 0x120, "Test 12: SPP=1, SPIE=1, SIE=0 expected");
                    check(uint64_t(sim.dut.csr_mcause_o) == 0, "Test 12: mcause must be untouched");
                }
            }
            check(saw_ssip, "Test 12 failed: delegated SSIP was not taken");
        }

        // Test 13: Delegated STIP delivery to S-mode, M-mode software injection, and S-mode read-only alias
        {
            TestSim sim;
            sim.reset();
            setup_smode_env(sim, true, 0x80000200, 0x80000300, 0, 0x20); // inject STIP (bit 5)

            // S-mode code at 0x80000060 (interrupted immediately since STIP is pending and SIE=1)
            sim.imem[0x80000060] = addi(5, 0, 10);

            // S-mode handler at 0x80000200:
            // Attempt to clear STIP via sip (bit 5): should be ignored (read-only alias!)
            sim.imem[0x80000200] = addi(8, 0, 0x20);
            sim.imem[0x80000204] = csrrc(0, 8, 0x144);       // clear bit 5 via sip (ignored!)
            sim.imem[0x80000208] = csrrs(9, 0, 0x144);       // read sip into x9 (bit 5 must still be 1)
            // Call M-mode via ECALL to clear STIP
            sim.imem[0x8000020c] = ecall_insn();
            sim.imem[0x80000210] = sret_insn();

            // M-mode mtvec handler at 0x80000300:
            sim.imem[0x80000300] = csrrc(0, 8, 0x344);       // clear mip.STIP
            sim.imem[0x80000304] = csrrw(11, 0, 0x341);
            sim.imem[0x80000308] = addi(11, 11, 4);          // advance mepc past ecall
            sim.imem[0x8000030c] = csrrw(0, 11, 0x341);
            sim.imem[0x80000310] = mret_insn();

            bool saw_stip = false;
            bool saw_stip_sip_preserved = false;
            bool saw_x9_stip_set = false;
            bool saw_m_cleared_stip = false;
            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 5))) {
                    saw_stip = true;
                    check(sim.last_trap_priv == 1, "Test 13: STIP must trap to S-mode");
                    check(uint64_t(sim.dut.csr_stval_o) == 0, "Test 13: stval must be 0");
                }
                if (sim.commit_this_cycle) {
                    if (sim.last_commit_pc == 0x80000204) {
                        check((uint64_t(sim.dut.csr_sip_o) & 0x20) == 0x20,
                              "Test 13: STIP in sip must remain 1 after clear attempt via sip");
                        check((uint64_t(sim.dut.csr_mip_o) & 0x20) == 0x20,
                              "Test 13: STIP in backing mip must remain 1 after clear attempt via sip");
                        saw_stip_sip_preserved = true;
                    }
                    if (sim.last_commit_pc == 0x80000208) {
                        check(sim.last_commit_rd == 9 && (sim.last_commit_rd_data & 0x20) == 0x20,
                              "Test 13: x9 readback of sip must have STIP bit 5 set");
                        saw_x9_stip_set = true;
                    }
                    if (sim.last_commit_pc == 0x80000300) {
                        check((uint64_t(sim.dut.csr_mip_o) & 0x20) == 0,
                              "Test 13: STIP in mip must be cleared by M-mode write");
                        check((uint64_t(sim.dut.csr_sip_o) & 0x20) == 0,
                              "Test 13: STIP in sip alias must be cleared by M-mode write");
                        saw_m_cleared_stip = true;
                    }
                }
            }
            check(saw_stip, "Test 13 failed: delegated STIP was not taken");
            check(saw_stip_sip_preserved, "Test 13 failed: STIP sip preservation check did not commit");
            check(saw_x9_stip_set, "Test 13 failed: STIP sip readback into x9 did not commit");
            check(saw_m_cleared_stip, "Test 13 failed: M-mode STIP clear did not commit");
        }

        // Test 14: Delegated SEIP delivery to S-mode, M-mode software injection, and S-mode read-only alias
        {
            TestSim sim;
            sim.reset();
            setup_smode_env(sim, true, 0x80000200, 0x80000300, 0, 0x200); // inject SEIP (bit 9 = 0x200)

            sim.imem[0x80000060] = addi(5, 0, 10);

            // S-mode handler at 0x80000200:
            sim.imem[0x80000200] = addi(8, 0, 0x20);
            sim.imem[0x80000204] = slli_insn(8, 8, 4);       // x8 = 0x200
            sim.imem[0x80000208] = csrrc(0, 8, 0x144);       // try clearing SEIP via sip (must be ignored)
            sim.imem[0x8000020c] = csrrs(9, 0, 0x144);       // read sip into x9 (bit 9 must still be 1)
            sim.imem[0x80000210] = ecall_insn();
            sim.imem[0x80000214] = sret_insn();

            // M-mode mtvec handler at 0x80000300:
            sim.imem[0x80000300] = csrrc(0, 8, 0x344);       // M-mode clears mip.SEIP
            sim.imem[0x80000304] = csrrw(11, 0, 0x341);
            sim.imem[0x80000308] = addi(11, 11, 4);
            sim.imem[0x8000030c] = csrrw(0, 11, 0x341);
            sim.imem[0x80000310] = mret_insn();

            bool saw_seip = false;
            bool saw_seip_sip_preserved = false;
            bool saw_x9_seip_set = false;
            bool saw_m_cleared_seip = false;
            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 9))) {
                    saw_seip = true;
                    check(sim.last_trap_priv == 1, "Test 14: SEIP must trap to S-mode");
                    check(uint64_t(sim.dut.csr_stval_o) == 0, "Test 14: stval must be 0");
                }
                if (sim.commit_this_cycle) {
                    if (sim.last_commit_pc == 0x80000208) {
                        check((uint64_t(sim.dut.csr_sip_o) & 0x200) == 0x200,
                              "Test 14: SEIP in sip must remain 1 after clear attempt via sip");
                        check((uint64_t(sim.dut.csr_mip_o) & 0x200) == 0x200,
                              "Test 14: SEIP in backing mip must remain 1 after clear attempt via sip");
                        saw_seip_sip_preserved = true;
                    }
                    if (sim.last_commit_pc == 0x8000020c) {
                        check(sim.last_commit_rd == 9 && (sim.last_commit_rd_data & 0x200) == 0x200,
                              "Test 14: x9 readback of sip must have SEIP bit 9 set");
                        saw_x9_seip_set = true;
                    }
                    if (sim.last_commit_pc == 0x80000300) {
                        check((uint64_t(sim.dut.csr_mip_o) & 0x200) == 0,
                              "Test 14: SEIP in mip must be cleared by M-mode write");
                        check((uint64_t(sim.dut.csr_sip_o) & 0x200) == 0,
                              "Test 14: SEIP in sip alias must be cleared by M-mode write");
                        saw_m_cleared_seip = true;
                    }
                }
            }
            check(saw_seip, "Test 14 failed: delegated SEIP was not taken");
            check(saw_seip_sip_preserved, "Test 14 failed: SEIP sip preservation check did not commit");
            check(saw_x9_seip_set, "Test 14 failed: SEIP sip readback into x9 did not commit");
            check(saw_m_cleared_seip, "Test 14 failed: M-mode SEIP clear did not commit");
        }

        // Test 15: Non-delegated supervisor interrupt source routing to M-mode
        {
            TestSim sim;
            sim.reset();
            // In M-mode: mideleg = 0, mie.SSIE = 1 (bit 1), mstatus.MIE = 1, set mip.SSIP = 1
            sim.imem[0x80000000] = csrci(0x303, 0x1f);       // mideleg = 0
            sim.imem[0x80000004] = csrsi(0x304, 2);          // mie |= 2 (SSIE)
            sim.imem[0x80000008] = csrsi(0x300, 8);          // mstatus.MIE = 1
            sim.imem[0x8000000c] = csrsi(0x344, 2);          // mip.SSIP = 1
            sim.imem[0x80000010] = addi(5, 0, 100);         // <-- interrupted here
            sim.imem[0x80000100] = csrci(0x344, 2);          // M-handler clears mip.SSIP
            sim.imem[0x80000104] = mret_insn();

            bool saw_nondeleg_m = false;
            for (int i = 0; i < 30; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 1))) {
                    saw_nondeleg_m = true;
                    check(sim.last_trap_priv == 3, "Test 15: non-delegated SSIP must trap to M-mode");
                    check(sim.last_mcause == ((1ULL << 63) | 1), "Test 15: mcause must be 1");
                    check(uint64_t(sim.dut.csr_scause_o) == 0, "Test 15: scause must be untouched");
                }
            }
            check(saw_nondeleg_m, "Test 15 failed: non-delegated SSIP did not trap to M-mode");
        }

        // Test 16: Delegated interrupt while CPU is in M-mode does NOT trap downward to S-mode
        {
            TestSim sim;
            sim.reset();
            // In M-mode: mideleg |= 2, mie |= 2, mstatus.MIE = 1, set mip.SSIP = 1
            sim.imem[0x80000000] = csrsi(0x303, 2);          // mideleg.SSIP = 1
            sim.imem[0x80000004] = csrsi(0x304, 2);          // mie.SSIE = 1
            sim.imem[0x80000008] = csrsi(0x300, 8);          // mstatus.MIE = 1
            sim.imem[0x8000000c] = csrsi(0x344, 2);          // mip.SSIP = 1
            sim.imem[0x80000010] = addi(5, 0, 1);
            sim.imem[0x80000014] = addi(6, 5, 2);
            sim.imem[0x80000018] = addi(7, 6, 3);

            for (int i = 0; i < 30; ++i) sim.tick();
            check(sim.traps == 0, "Test 16 failed: delegated SSIP must not trap while executing in M-mode");
            check(sim.commits >= 6, "Test 16 failed: M-mode instructions must commit normally");
        }

        // Test 17: S global enable (sstatus.SIE) and individual sie gating
        {
            TestSim sim;
            sim.reset();
            // Start S-mode with SIE = 0, but sie.SSIE = 1
            setup_smode_env(sim, false, 0x80000200);
            sim.imem[0x80000060] = csrsi(0x144, 2);         // set sip.SSIP with SIE=0
            sim.imem[0x80000064] = addi(5, 0, 1);
            sim.imem[0x80000068] = addi(6, 5, 2);
            sim.imem[0x8000006c] = csrsi(0x100, 2);         // NOW enable sstatus.SIE = 1!
            sim.imem[0x80000070] = addi(7, 6, 3);          // <-- interrupted here
            sim.imem[0x80000200] = csrci(0x144, 2);         // clear sip.SSIP
            sim.imem[0x80000204] = sret_insn();

            bool saw_sie_gated_trap = false;
            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 1))) {
                    saw_sie_gated_trap = true;
                    check(sim.last_trap_pc == 0x80000070, "Test 17: interrupt must fire only after sstatus.SIE=1");
                }
            }
            check(saw_sie_gated_trap, "Test 17 failed: trap not taken after sstatus.SIE enabled");
        }

        // Test 18: S interrupt eligibility when current mode is U versus S
        {
            TestSim sim;
            sim.reset();
            // In S-mode: configure SPP=0 (U-mode), sstatus.SIE=0, sepc=0x80000080, sret to U-mode
            setup_smode_env(sim, false, 0x80000200);
            // S-mode at 0x80000060 sets up U-mode return:
            sim.imem[0x80000060] = csrci(0x100, 0x100);     // clear sstatus.SPP (SPP = 0 -> U-mode)
            sim.imem[0x80000064] = auipc(5, 0);
            sim.imem[0x80000068] = addi(5, 5, int(0x80000080ULL - 0x80000064ULL));
            sim.imem[0x8000006c] = csrrw(0, 5, 0x141);      // sepc = 0x80000080
            sim.imem[0x80000070] = csrsi(0x144, 2);         // set sip.SSIP = 1 (while SIE=0)
            sim.imem[0x80000074] = sret_insn();             // enter U-mode at 0x80000080
            sim.imem[0x80000080] = addi(6, 0, 42);          // interrupted upon entering U-mode!
            sim.imem[0x80000200] = csrci(0x144, 2);         // S-handler clears SSIP
            sim.imem[0x80000204] = sret_insn();

            bool saw_u_mode_irq = false;
            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 1))) {
                    saw_u_mode_irq = true;
                    check(sim.last_trap_priv == 1, "Test 18: must trap to S-mode from U-mode");
                    check((uint64_t(sim.dut.csr_mstatus_o) & 0x100) == 0, "Test 18: SPP must be 0 (from U-mode)");
                    check(sim.last_trap_pc == 0x80000080, "Test 18: sepc must be 0x80000080");
                }
            }
            check(saw_u_mode_irq, "Test 18 failed: S-target interrupt not taken in U-mode with SIE=0");
        }

        // Test 19: Vectored stvec for supervisor interrupts
        {
            TestSim sim;
            sim.reset();
            // stvec = 0x80000401 (BASE = 0x80000400, MODE = 1 Vectored)
            setup_smode_env(sim, true, 0x80000401);
            sim.imem[0x80000060] = csrsi(0x144, 2);         // trigger SSIP (cause 1)
            sim.imem[0x80000064] = addi(5, 0, 10);
            // Vectored handler at BASE + 4 * 1 = 0x80000404:
            sim.imem[0x80000404] = csrci(0x144, 2);         // clear SSIP
            sim.imem[0x80000408] = sret_insn();

            bool saw_vectored_s = false;
            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && (sim.last_trap_cause == ((1ULL << 63) | 1))) {
                    saw_vectored_s = true;
                    while (!sim.dut.imem_req_valid_o) sim.tick();
                    check(uint32_t(sim.dut.imem_req_addr_o) == 0x80000404,
                          "Test 19: vectored stvec must redirect to BASE + 4 * 1 = 0x80000404");
                    break;
                }
            }
            check(saw_vectored_s, "Test 19 failed: vectored stvec redirect not seen");
        }

        // Test 20: Synchronous exception priority over pending delegated interrupt in S-mode
        {
            TestSim sim;
            sim.reset();
            setup_smode_env(sim, true, 0x80000200);
            sim.imem[0x80000060] = addi(5, 0, 10);
            sim.imem[0x80000064] = 0xffffffff;              // illegal instruction (cause 2)
            sim.imem[0x80000200] = addi(0, 0, 0);

            while (sim.dut.priv_mode_o != 1) sim.tick();
            while (sim.last_commit_pc != 0x80000060) sim.tick();
            sim.tick();
            sim.tick();
            sim.dut.rootp->fursoy_s0_core__DOT__ssip_q = 1;
            sim.dut.eval();

            bool saw_sync_win_s = false;
            for (int i = 0; i < 30; ++i) {
                sim.tick();
                if (sim.trap_this_cycle) {
                    check(sim.last_trap_cause == 2, "Test 20: sync exception (cause 2) must beat pending SSIP");
                    saw_sync_win_s = true;
                    break;
                }
            }
            check(saw_sync_win_s, "Test 20 failed: sync exception did not take priority in S-mode");
        }

        // Test 21: Interrupt priority when multiple M and S interrupt classes are pending
        {
            // Part A: In S-mode, non-delegated MTIP beats delegated SSIP
            {
                TestSim sim;
                sim.reset();
                setup_smode_env(sim, true, 0x80000200, 0x80000100, 0x80); // enable MTIE in M-mode
                sim.imem[0x80000060] = csrsi(0x144, 2);      // assert SSIP (delegated)
                sim.imem[0x80000064] = addi(5, 0, 10);
                sim.imem[0x80000100] = mret_insn();

                while (sim.dut.priv_mode_o != 1) sim.tick();
                // Assert MTIP hardware input while SSIP is pending in S-mode:
                sim.dut.irq_timer_i = 1;

                bool saw_m_over_s = false;
                for (int i = 0; i < 50; ++i) {
                    sim.tick();
                    if (sim.trap_this_cycle) {
                        check(sim.last_trap_priv == 3, "Test 21A: MTIP must trap to M-mode");
                        check(sim.last_mcause == ((1ULL << 63) | 7), "Test 21A: mcause must be MTIP (7)");
                        saw_m_over_s = true;
                        break;
                    }
                }
                check(saw_m_over_s, "Test 21A failed: M-target interrupt did not beat S-target interrupt");
            }

            // Part B: Within S-mode: SEI (9) > SSI (1) > STI (5)
            {
                TestSim sim;
                sim.reset();
                setup_smode_env(sim, true, 0x80000200, 0x80000100, 0, 0x222); // inject SEIP, STIP, SSIP
                sim.imem[0x80000060] = addi(5, 0, 10);
                sim.imem[0x80000200] = csrci(0x144, 2);      // clear SSIP
                sim.imem[0x80000204] = sret_insn();

                bool saw_sei_first = false;
                for (int i = 0; i < 150; ++i) {
                    sim.tick();
                    if (sim.trap_this_cycle) {
                        check(sim.last_scause == ((1ULL << 63) | 9),
                              "Test 21B: SEI (cause 9) must have highest priority in S-mode");
                        saw_sei_first = true;
                        break;
                    }
                }
                check(saw_sei_first, "Test 21B failed: SEI priority trap not seen");
            }

            // Part C: Within S-mode: SSI (1) > STI (5) when SEI is 0
            {
                TestSim sim;
                sim.reset();
                setup_smode_env(sim, true, 0x80000200, 0x80000100, 0, 0x22); // inject STIP (0x20) and SSIP (0x2)
                sim.imem[0x80000060] = addi(5, 0, 10);
                sim.imem[0x80000200] = csrci(0x144, 2);      // clear SSIP
                sim.imem[0x80000204] = sret_insn();

                bool saw_ssi_before_sti = false;
                for (int i = 0; i < 150; ++i) {
                    sim.tick();
                    if (sim.trap_this_cycle) {
                        check(sim.last_scause == ((1ULL << 63) | 1),
                              "Test 21C: SSI (cause 1) must have priority over STI (cause 5) in S-mode");
                        saw_ssi_before_sti = true;
                        break;
                    }
                }
                check(saw_ssi_before_sti, "Test 21C failed: SSI priority over STI not observed");
            }

            // Part D: M-target SEI vs S-target SSI: M-target strictly preempts S-target
            {
                TestSim sim;
                sim.reset();
                // mideleg = 0x2 (only SSIP delegated, SEIP non-delegated)
                // extra_mie = 0x200 (SEIE in mie)
                // inject_mip = 0x202 (both SEIP and SSIP pending)
                setup_smode_env(sim, true, 0x80000200, 0x80000100, 0x200, 0x202, 0x2);

                sim.imem[0x80000060] = addi(5, 0, 10);
                sim.imem[0x80000100] = mret_insn();

                bool saw_m_sei_over_s_ssi = false;
                for (int i = 0; i < 150; ++i) {
                    sim.tick();
                    if (sim.trap_this_cycle) {
                        check(sim.last_trap_priv == 3, "Test 21D: M-target SEI must trap to M-mode");
                        check(sim.last_mcause == ((1ULL << 63) | 9),
                              "Test 21D: mcause must be SEI (9), beating S-target SSIP");
                        saw_m_sei_over_s_ssi = true;
                        break;
                    }
                }
                check(saw_m_sei_over_s_ssi, "Test 21D failed: M-target SEI did not beat S-target SSI");
            }
        }

        // Test 22: Persistent level/pending S interrupt retrigger after sret
        {
            TestSim sim;
            sim.reset();
            setup_smode_env(sim, true, 0x80000200);
            sim.imem[0x80000060] = csrsi(0x144, 2);         // set SSIP
            sim.imem[0x80000064] = addi(5, 0, 10);
            // Handler at 0x80000200 executes sret WITHOUT clearing SSIP:
            sim.imem[0x80000200] = sret_insn();

            unsigned s_traps = 0;
            for (int i = 0; i < 150 && s_traps < 2; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && sim.last_trap_cause == ((1ULL << 63) | 1)) {
                    ++s_traps;
                    check(sim.last_trap_pc == 0x80000064, "Test 22: persistent SSIP sepc mismatch");
                }
            }
            check(s_traps == 2, "Test 22 failed: persistent SSIP was not retaken after sret");
        }

        // Test 23: S-mode delayed fetch and in-flight LSU precision
        {
            // Case A: Delayed fetch in S-mode
            {
                TestSim sim;
                sim.reset();
                setup_smode_env(sim, true, 0x80000200);
                sim.imem[0x80000060] = addi(5, 0, 10);
                sim.imem[0x80000064] = addi(6, 0, 20);
                sim.imem[0x80000200] = csrci(0x144, 2);
                sim.imem[0x80000204] = sret_insn();

                while (sim.dut.priv_mode_o != 1) sim.tick(); // Reach S-mode execution
                sim.imem_delay = 4;
                sim.tick(); // Issue fetch and enter response stall
                sim.dut.rootp->fursoy_s0_core__DOT__ssip_q = 1; // Assert SSIP during fetch delay
                sim.dut.eval();

                bool saw_fetch_stall_irq = false;
                for (int i = 0; i < 30; ++i) {
                    sim.tick();
                    if (sim.trap_this_cycle) {
                        check(sim.last_trap_cause == ((1ULL << 63) | 1), "Test 23A: SSIP cause expected");
                        check(sim.last_trap_priv == 1, "Test 23A: must trap to S-mode");
                        check(!sim.commit_this_cycle, "Test 23A: interrupt and commit must not coincide");
                        saw_fetch_stall_irq = true;
                        break;
                    }
                }
                check(saw_fetch_stall_irq, "Test 23A failed: delayed fetch blocked S interrupt entry");
            }

            // Case B: In-flight LSU load in S-mode
            {
                TestSim sim;
                sim.reset();
                setup_smode_env(sim, true, 0x80000200);
                sim.dmem_delay = 3;
                sim.imem[0x80000060] = lw(5, 0, 0x40);          // load word from 0x40 in S-mode
                sim.imem[0x80000064] = addi(6, 5, 1);
                sim.dmem[0x40] = 777;
                sim.imem[0x80000200] = csrci(0x144, 2);         // handler clears SSIP
                sim.imem[0x80000204] = sret_insn();

                while (sim.dut.priv_mode_o != 1) sim.tick();
                while (!sim.dut.dmem_req_valid_o) sim.tick();
                // Assert SSIP while LSU load is in-flight:
                sim.dut.rootp->fursoy_s0_core__DOT__ssip_q = 1;
                sim.dut.eval();

                // Wait until load commits:
                bool s_load_committed = false;
                for (int i = 0; i < 30; ++i) {
                    sim.tick();
                    if (sim.commit_this_cycle && sim.last_commit_pc == 0x80000060) {
                        s_load_committed = true;
                        break;
                    }
                }
                check(s_load_committed, "Test 23B failed: in-flight S load must commit cleanly");
                // Verify interrupt taken at exact instruction boundary (0x80000064):
                bool saw_boundary_irq = false;
                for (int i = 0; i < 20; ++i) {
                    sim.tick();
                    if (sim.trap_this_cycle && sim.last_trap_cause == ((1ULL << 63) | 1)) {
                        check(sim.last_trap_pc == 0x80000064, "Test 23B: sepc must be 0x80000064");
                        saw_boundary_irq = true;
                        break;
                    }
                }
                check(saw_boundary_irq, "Test 23B failed: SSIP not taken at instruction boundary after load");
            }
        }

        // Test 24: SRET returning to U-mode and S-mode
        {
            TestSim sim;
            sim.reset();
            // In S-mode: test return to S (SPP=1)
            setup_smode_env(sim, false, 0x80000200);
            sim.imem[0x80000060] = addi(4, 0, 0x100);
            sim.imem[0x80000064] = csrrs(0, 4, 0x100);       // sstatus.SPP = 1 (S-mode)
            sim.imem[0x80000068] = auipc(5, 0);
            sim.imem[0x8000006c] = addi(5, 5, int(0x80000080ULL - 0x80000068ULL));
            sim.imem[0x80000070] = csrrw(0, 5, 0x141);      // sepc = 0x80000080
            sim.imem[0x80000074] = sret_insn();             // returns to 0x80000080 in S-mode
            sim.imem[0x80000080] = addi(6, 0, 11);

            bool saw_s_return = false;
            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.commit_this_cycle && sim.last_commit_pc == 0x80000080) {
                    check(sim.dut.priv_mode_o == 1, "Test 24: SRET with SPP=1 must return to S-mode");
                    saw_s_return = true;
                    break;
                }
            }
            check(saw_s_return, "Test 24 failed: SRET with SPP=1 did not commit at sepc");
        }

        // Test 25: Preempted FENCE.I under supervisor interrupt emits NO spurious fence_i_valid_o
        {
            TestSim sim;
            sim.reset();
            setup_smode_env(sim, true, 0x80000200);

            // S-mode instructions:
            // 0x80000060: addi x5, x0, 1
            sim.imem[0x80000060] = addi(5, 0, 1);
            // 0x80000064: FENCE.I (0x0000100f)
            sim.imem[0x80000064] = 0x0000100f;
            // 0x80000068: addi x6, x0, 2
            sim.imem[0x80000068] = addi(6, 0, 2);

            // S-mode trap handler at 0x80000200:
            // Clear SSIP in sip, then sret
            sim.imem[0x80000200] = csrci(0x144, 2);          // clear SSIP
            sim.imem[0x80000204] = sret_insn();

            unsigned spurious_fi = 0;
            unsigned committed_fi = 0;
            bool saw_fence_preempt_trap = false;

            // Step until x5 commits at 0x80000060:
            while (!sim.commit_this_cycle || sim.last_commit_pc != 0x80000060) {
                sim.tick();
            }

            // FENCE.I is being fetched/decoded: assert SSIP to preempt FENCE.I!
            sim.dut.rootp->fursoy_s0_core__DOT__ssip_q = 1;
            sim.dut.eval();

            for (int i = 0; i < 60; ++i) {
                sim.tick();
                if (sim.trap_this_cycle && sim.last_trap_pc == 0x80000064) {
                    saw_fence_preempt_trap = true;
                    check(!sim.fence_i_this_cycle, "Test 25: Spurious fence_i_valid_o on preempted FENCE.I!");
                    check(!sim.commit_this_cycle, "Test 25: commit_valid_o must be 0 on preempted trap cycle");
                }
                if (sim.fence_i_this_cycle) {
                    if (!sim.commit_this_cycle) {
                        ++spurious_fi;
                    } else {
                        ++committed_fi;
                    }
                }
            }

            check(saw_fence_preempt_trap, "Test 25 failed: FENCE.I preemption trap not observed");
            check(spurious_fi == 0, "Test 25 failed: Spurious fence_i_valid_o detected");
            check(committed_fi == 1, "Test 25 failed: FENCE.I must commit exactly once upon return");
        }

        // Test 26: Individual sie enable gating
        // Proves a pending delegated interrupt is suppressed when its individual sie bit
        // is clear, independently of sstatus.SIE, and taken when enabled.
        {
            TestSim sim;
            sim.reset();
            // Setup S-mode with sstatus.SIE = 1, but clear mie/sie SSIP bit 1:
            setup_smode_env(sim, true, 0x80000200, 0x80000100, 0, 0); // extra_mie = 0, inject_mip = 0
            // Clear sie.SSIE (bit 1):
            sim.imem[0x80000060] = csrci(0x104, 2);          // clear sie.SSIE
            // Set SSIP (bit 1):
            sim.imem[0x80000064] = csrsi(0x144, 2);          // sip.SSIP = 1
            // S-mode work:
            sim.imem[0x80000068] = addi(5, 0, 10);
            sim.imem[0x8000006c] = addi(5, 5, 1);
            // Now enable sie.SSIE:
            sim.imem[0x80000070] = csrsi(0x104, 2);          // sie.SSIE = 1 -> interrupt must trigger!
            sim.imem[0x80000074] = addi(6, 0, 99);          // interrupted before this!

            // S-mode handler at 0x80000200:
            sim.imem[0x80000200] = csrci(0x144, 2);          // clear SSIP
            sim.imem[0x80000204] = sret_insn();

            bool saw_suppressed_exec = false;
            bool saw_enabled_trap = false;

            for (int i = 0; i < 150; ++i) {
                sim.tick();
                if (sim.commit_this_cycle && sim.last_commit_pc == 0x8000006c) {
                    saw_suppressed_exec = true; // Proves code executed with SSIP pending while sie.SSIE=0!
                }
                if (sim.trap_this_cycle && sim.last_trap_cause == ((1ULL << 63) | 1)) {
                    saw_enabled_trap = true;
                    check(sim.last_trap_pc == 0x80000074,
                          "Test 26: trap must occur right after sie.SSIE is set, at PC 0x80000074");
                    check(sim.last_trap_priv == 1, "Test 26: must trap to S-mode");
                }
            }

            check(saw_suppressed_exec, "Test 26 failed: individual sie bit did not suppress interrupt");
            check(saw_enabled_trap, "Test 26 failed: interrupt was not taken after setting sie.SSIE");
        }

        // Test 27: Dynamic delegation alias preservation
        // Proves that clearing/restoring mideleg dynamically changes sie/sip visibility
        // while the hidden backing mie/mip state survives unchanged.
        {
            TestSim sim;
            sim.reset();
            // In M-mode:
            // 1. Enable mie.SSIE (bit 1) and mideleg.SSIP (bit 1)
            sim.imem[0x80000000] = csrsi(0x304, 2);          // mie |= 2
            sim.imem[0x80000004] = csrsi(0x303, 2);          // mideleg |= 2
            // 2. Set mip.SSIP (bit 1)
            sim.imem[0x80000008] = csrsi(0x344, 2);          // mip.SSIP = 1
            sim.imem[0x8000000c] = addi(5, 0, 1);
            // 3. Clear mideleg.SSIP dynamically:
            sim.imem[0x80000010] = csrci(0x303, 2);          // mideleg.SSIP = 0
            sim.imem[0x80000014] = addi(5, 0, 2);
            // 4. Restore mideleg.SSIP dynamically:
            sim.imem[0x80000018] = csrsi(0x303, 2);          // mideleg.SSIP = 1
            sim.imem[0x8000001c] = addi(5, 0, 3);

            bool verified_init = false;
            bool verified_hidden = false;
            bool verified_restored = false;

            for (int i = 0; i < 60; ++i) {
                sim.tick();
                if (sim.commit_this_cycle) {
                    if (sim.last_commit_pc == 0x8000000c) {
                        // Initial state: delegated
                        check((uint64_t(sim.dut.csr_mideleg_o) & 2) == 2, "Test 27: mideleg.SSIP must be 1");
                        check((uint64_t(sim.dut.csr_sie_o) & 2) == 2, "Test 27: sie.SSIE must be visible");
                        check((uint64_t(sim.dut.csr_sip_o) & 2) == 2, "Test 27: sip.SSIP must be visible");
                        check((uint64_t(sim.dut.csr_mie_o) & 2) == 2, "Test 27: backing mie.SSIE must be 1");
                        check((uint64_t(sim.dut.csr_mip_o) & 2) == 2, "Test 27: backing mip.SSIP must be 1");
                        verified_init = true;
                    }
                    if (sim.last_commit_pc == 0x80000014) {
                        // Dynamically undelegated:
                        check((uint64_t(sim.dut.csr_mideleg_o) & 2) == 0, "Test 27: mideleg.SSIP must be 0");
                        check((uint64_t(sim.dut.csr_sie_o) & 2) == 0, "Test 27: sie.SSIE must be hidden (0)");
                        check((uint64_t(sim.dut.csr_sip_o) & 2) == 0, "Test 27: sip.SSIP must be hidden (0)");
                        check((uint64_t(sim.dut.csr_mie_o) & 2) == 2, "Test 27: backing mie.SSIE must survive unchanged!");
                        check((uint64_t(sim.dut.csr_mip_o) & 2) == 2, "Test 27: backing mip.SSIP must survive unchanged!");
                        verified_hidden = true;
                    }
                    if (sim.last_commit_pc == 0x8000001c) {
                        // Dynamically restored:
                        check((uint64_t(sim.dut.csr_mideleg_o) & 2) == 2, "Test 27: mideleg.SSIP must be 1 again");
                        check((uint64_t(sim.dut.csr_sie_o) & 2) == 2, "Test 27: sie.SSIE must be visible again");
                        check((uint64_t(sim.dut.csr_sip_o) & 2) == 2, "Test 27: sip.SSIP must be visible again");
                        check((uint64_t(sim.dut.csr_mie_o) & 2) == 2, "Test 27: backing mie.SSIE still 1");
                        check((uint64_t(sim.dut.csr_mip_o) & 2) == 2, "Test 27: backing mip.SSIP still 1");
                        verified_restored = true;
                    }
                }
            }

            check(verified_init, "Test 27 failed: initial state check not reached");
            check(verified_hidden, "Test 27 failed: hidden alias state check not reached");
            check(verified_restored, "Test 27 failed: restored alias state check not reached");
        }

        std::cout << "{\"status\":\"pass\",\"tests\":27}\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "CORE_INTERRUPT_S0_MISMATCH: " << e.what() << '\n';
        return 1;
    }
}
