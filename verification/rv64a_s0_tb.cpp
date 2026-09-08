// Focused RV64A atomic memory extension verification suite.
// Covers all 46 verification matrix scenarios per docs/architecture/rv64a-v1.md Section 9.1:
// - A-LRSC-01..24 (LR/SC correctness, matching, invalidation, edge cases)
// - A-AMO-01..13 (All 9 AMOs in .W and .D forms, sign-extension, x0, misaligned)
// - A-SYS-01..09 (Sv39 MMU, PMP, bus error, non-preemption, reset leakage)

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

// RV64I instruction encoders
static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
static uint32_t slli(unsigned rd, unsigned rs1, unsigned sh) {
    return (sh << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13;
}
static uint32_t ori(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (6 << 12) | (rd << 7) | 0x13;
}
static uint32_t lui(unsigned rd, uint32_t imm20) {
    return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37;
}
static uint32_t auipc(unsigned rd) {
    return (rd << 7) | 0x17;
}
static uint32_t lw(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03;
}
static uint32_t ld(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
}
static uint32_t sw(unsigned rs2, unsigned rs1, int imm) {
    uint32_t u = imm;
    return (((u >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((u & 31) << 7) | 0x23;
}
static uint32_t sd(unsigned rs2, unsigned rs1, int imm) {
    uint32_t u = imm;
    return (((u >> 5) & 0x7f) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((u & 31) << 7) | 0x23;
}
static uint32_t csr(unsigned f, unsigned rd, unsigned rs1, unsigned addr) {
    return (addr << 20) | (rs1 << 15) | (f << 12) | (rd << 7) | 0x73;
}
static uint32_t csrr(unsigned rd, unsigned addr) { return csr(2, rd, 0, addr); }
static uint32_t csrw(unsigned addr, unsigned rs1) { return csr(1, 0, rs1, addr); }

static constexpr uint32_t ECALL      = 0x00000073;
static constexpr uint32_t EBREAK     = 0x00100073;
static constexpr uint32_t MRET       = 0x30200073;
static constexpr uint32_t SRET       = 0x10200073;
static constexpr uint32_t SFENCE_VMA = 0x12000073;

// RV64A instruction encoders
static uint32_t r_type_amo(uint32_t funct5, bool aq, bool rl, uint32_t rs2, uint32_t rs1, uint32_t funct3, uint32_t rd) {
    return ((funct5 & 0x1f) << 27) |
           ((aq ? 1 : 0) << 26) |
           ((rl ? 1 : 0) << 25) |
           ((rs2 & 0x1f) << 20) |
           ((rs1 & 0x1f) << 15) |
           ((funct3 & 0x7) << 12) |
           ((rd & 0x1f) << 7) |
           0x2f;
}

static uint32_t lr_w(uint32_t rd, uint32_t rs1, bool aq = false, bool rl = false) {
    return r_type_amo(0x02, aq, rl, 0, rs1, 0x2, rd);
}
static uint32_t lr_d(uint32_t rd, uint32_t rs1, bool aq = false, bool rl = false) {
    return r_type_amo(0x02, aq, rl, 0, rs1, 0x3, rd);
}
static uint32_t sc_w(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq = false, bool rl = false) {
    return r_type_amo(0x03, aq, rl, rs2, rs1, 0x2, rd);
}
static uint32_t sc_d(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq = false, bool rl = false) {
    return r_type_amo(0x03, aq, rl, rs2, rs1, 0x3, rd);
}

static uint32_t amoswap_w(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x01, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amoswap_d(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x01, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amoadd_w (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x00, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amoadd_d (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x00, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amoxor_w (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x04, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amoxor_d (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x04, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amoand_w (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x0c, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amoand_d (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x0c, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amoor_w  (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x08, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amoor_d  (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x08, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amomin_w (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x10, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amomin_d (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x10, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amomax_w (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x14, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amomax_d (uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x14, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amominu_w(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x18, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amominu_d(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x18, aq, rl, rs2, rs1, 0x3, rd); }
static uint32_t amomaxu_w(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x1c, aq, rl, rs2, rs1, 0x2, rd); }
static uint32_t amomaxu_d(uint32_t rd, uint32_t rs2, uint32_t rs1, bool aq=false, bool rl=false) { return r_type_amo(0x1c, aq, rl, rs2, rs1, 0x3, rd); }

struct Event {
    bool commit = false;
    bool trap = false;
    uint64_t pc = 0;
    uint32_t insn = 0;
    bool rd_write = false;
    unsigned rd = 0;
    uint64_t rd_data = 0;
    uint8_t priv_mode = 3;
    bool dmem_fire = false;
    bool dmem_store = false;
    uint64_t dmem_addr = 0;
    uint64_t dmem_data = 0;
};

struct CoreSim {
    Vfursoy_s0_core dut;
    std::unordered_map<uint64_t, uint32_t> imem;
    std::unordered_map<uint64_t, uint8_t> dmem_bytes;
    bool fetch_pending = false;
    uint64_t rsp_pc = 0;
    uint32_t rsp_insn = 0;
    uint64_t cycles = 0;
    uint64_t commits = 0;
    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    unsigned physical_stores = 0;
    unsigned ptw_requests = 0;
    uint64_t last_dmem_store_addr = 0;
    uint64_t last_dmem_store_data = 0;
    bool inject_dmem_req_error = false;
    bool inject_dmem_rsp_error = false;
    bool defer_dmem_req_ready = false;

    uint64_t read_dmem(uint64_t addr, unsigned size) {
        uint64_t val = 0;
        unsigned bytes = 1 << size;
        for (unsigned i = 0; i < bytes; ++i) {
            if (dmem_bytes.count(addr + i)) {
                val |= (uint64_t(dmem_bytes[addr + i]) << (8 * i));
            }
        }
        return val;
    }

    void write_dmem(uint64_t addr, unsigned size, uint64_t data) {
        unsigned bytes = 1 << size;
        for (unsigned i = 0; i < bytes; ++i) {
            dmem_bytes[addr + i] = uint8_t((data >> (8 * i)) & 0xff);
        }
    }

    void reset() {
        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = 0;
        dut.imem_rsp_insn_i = 0;
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

        fetch_pending = false;
        dmem_rsp_pending = false;
        physical_stores = 0;
        ptw_requests = 0;
        commits = 0;
        inject_dmem_req_error = false;
        inject_dmem_rsp_error = false;
        defer_dmem_req_ready = false;
    }

    Event tick() {
        dut.clk_i = 0;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = fetch_pending;
        dut.imem_rsp_insn_i = rsp_insn;
        dut.imem_rsp_error_i = 0;

        dut.dmem_req_ready_i = defer_dmem_req_ready ? 0 : 1;
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

        ev.dmem_fire = dmem_req_fire;
        ev.dmem_store = dmem_req_fire && dut.dmem_req_store_o;
        ev.dmem_addr = dut.dmem_req_addr_o;
        ev.dmem_data = dut.dmem_req_store_data_o;

        if (dmem_req_fire) {
            if (dut.dmem_req_ptw_o) {
                ++ptw_requests;
            }
            if (dut.dmem_req_store_o) {
                ++physical_stores;
                last_dmem_store_addr = dut.dmem_req_addr_o;
                last_dmem_store_data = dut.dmem_req_store_data_o;
                write_dmem(dut.dmem_req_addr_o, dut.dmem_req_size_o, dut.dmem_req_store_data_o);
            } else {
                dmem_rsp_data = read_dmem(dut.dmem_req_addr_o, dut.dmem_req_size_o);
                dmem_rsp_pending = true;
            }
        }

        bool next_pending = fetch_pending;
        uint64_t next_pc = rsp_pc;
        uint32_t next_insn = rsp_insn;

        if (rsp_fire) next_pending = false;
        if (req_fire) {
            next_pc = dut.imem_req_addr_o;
            next_insn = imem.count(next_pc) ? imem[next_pc] : 0x00000013;
            next_pending = true;
        }

        if (dmem_rsp_fire) dmem_rsp_pending = false;

        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        fetch_pending = next_pending;
        rsp_pc = next_pc;
        rsp_insn = next_insn;

        if (ev.commit) ++commits;
        dut.clk_i = 0;
        dut.eval();
        return ev;
    }

    Event until_commit(uint64_t target_pc, unsigned max_cycles = 500) {
        for (unsigned i = 0; i < max_cycles; ++i) {
            Event ev = tick();
            if (ev.commit && ev.pc == target_pc) return ev;
            if (ev.trap) throw std::runtime_error("Unexpected trap at PC=" + std::to_string(ev.pc) + " cause=" + std::to_string(dut.csr_mcause_o));
        }
        throw std::runtime_error("Timeout waiting for commit at PC=" + std::to_string(target_pc));
    }

    Event until_commit_allow_trap(uint64_t target_pc, unsigned max_cycles = 500) {
        for (unsigned i = 0; i < max_cycles; ++i) {
            Event ev = tick();
            if (ev.commit && ev.pc == target_pc) return ev;
        }
        throw std::runtime_error("Timeout waiting for commit at PC=" + std::to_string(target_pc));
    }

    Event until_trap(unsigned max_cycles = 500) {
        for (unsigned i = 0; i < max_cycles; ++i) {
            Event ev = tick();
            if (ev.trap) return ev;
        }
        throw std::runtime_error("Timeout waiting for trap");
    }

    uint64_t reg(unsigned r) {
        return dut.rootp->fursoy_s0_core__DOT__registers[r];
    }
};

static constexpr uint64_t B = 0x80000000ULL;
static constexpr uint64_t MTV = B + 0x300;
static constexpr uint64_t STV = B + 0x200;
static constexpr uint64_t ROOT_PPN = 0x100;

// Setup Sv39 identity and aliased mapping in S-mode
static void setup_sv39_environment(CoreSim& s, uint64_t s_entry, bool allow_all_pmp=true) {
    // Root page table at physical address (ROOT_PPN << 12) = 0x100000
    // Map gigapage for 0x80000000 (PPN 0x80000, R=1, W=1, X=1, A=1, D=1, V=1) -> 0x0002000000000000 | 0xcf
    uint64_t root_addr = ROOT_PPN << 12;
    s.write_dmem(root_addr + 2 * 8, 3, (0x80000ULL << 10) | 0xcf); // 0x80000000 -> 0x80000000

    // Setup code in M-mode to transition to S-mode with Sv39
    uint64_t pc = B;
    if (allow_all_pmp) {
        // pmpaddr0 = -1 (all addresses)
        s.imem[pc] = addi(10, 0, -1); pc += 4;
        s.imem[pc] = csrw(0x3b0, 10); pc += 4;
        // pmpcfg0 = 0x1f (TOR, R, W, X)
        s.imem[pc] = addi(11, 0, 0x1f); pc += 4;
        s.imem[pc] = csrw(0x3a0, 11); pc += 4;
    }
    // satp = (8ULL << 60) | ROOT_PPN
    s.imem[pc] = addi(1, 0, 8); pc += 4;
    s.imem[pc] = slli(1, 1, 60); pc += 4;
    s.imem[pc] = addi(2, 0, ROOT_PPN); pc += 4;
    s.imem[pc] = ori(1, 1, ROOT_PPN); pc += 4;
    s.imem[pc] = csrw(0x180, 1); pc += 4; // satp

    // Delegate all exceptions to S-mode: medeleg = 0xffff
    s.imem[pc] = addi(3, 0, -1); pc += 4;
    s.imem[pc] = csrw(0x302, 3); pc += 4; // medeleg

    // stvec = STV
    s.imem[pc] = auipc(4); uint64_t p = pc; pc += 4;
    s.imem[pc] = addi(4, 4, int(STV - p)); pc += 4;
    s.imem[pc] = csrw(0x105, 4); pc += 4; // stvec

    // mepc = s_entry
    s.imem[pc] = auipc(4); p = pc; pc += 4;
    s.imem[pc] = addi(4, 4, int(s_entry - p)); pc += 4;
    s.imem[pc] = csrw(0x341, 4); pc += 4; // mepc

    // Set mstatus.MPP = 1 (S-mode)
    s.imem[pc] = addi(5, 0, 3); pc += 4;
    s.imem[pc] = slli(5, 5, 11); pc += 4;
    s.imem[pc] = csr(3, 0, 5, 0x300); pc += 4; // clear MPP
    s.imem[pc] = addi(5, 0, 1); pc += 4;
    s.imem[pc] = slli(5, 5, 11); pc += 4;
    s.imem[pc] = csr(2, 0, 5, 0x300); pc += 4; // set MPP=1

    // mret to S-mode
    s.imem[pc] = MRET;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned scenarios = 0;
    try {
        // =====================================================================
        // PART 1: A-LRSC-01 .. A-LRSC-24
        // =====================================================================

        // A-LRSC-01: Basic LR.W followed immediately by SC.W to same address
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x12345678);
            s.write_dmem(addr + 0x80, 2, 0x9abcdef0);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4; // x10 = addr
            s.imem[pc] = lw(7, 10, 0x80); pc += 4;     // x7 = 0x9abcdef0
            s.imem[pc] = lr_w(5, 10); pc += 4;         // LR.W x5, (x10)
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;      // SC.W x6, x7, (x10)
            s.until_commit(pc - 4);
            check(s.reg(5) == 0x12345678, "A-LRSC-01 LR.W value");
            check(s.reg(6) == 0, "A-LRSC-01 SC.W success rd=0");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x9abcdef0ULL, "A-LRSC-01 memory updated");
            check(s.physical_stores == 1, "A-LRSC-01 exactly one store emitted");
            ++scenarios;
        }

        // A-LRSC-02: Basic LR.D followed immediately by SC.D to same address
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 3, 0x1122334455667788ULL);
            s.write_dmem(addr + 0x80, 3, 0x8877665544332211ULL); // literal
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4; // x10 = addr
            s.imem[pc] = ld(7, 10, 0x80); pc += 4;     // x7 = 0x8877665544332211
            s.imem[pc] = lr_d(5, 10); pc += 4;         // LR.D x5, (x10)
            s.imem[pc] = sc_d(6, 7, 10); pc += 4;      // SC.D x6, x7, (x10)
            s.until_commit(pc - 4);
            check(s.reg(5) == 0x1122334455667788ULL, "A-LRSC-02 LR.D value");
            check(s.reg(6) == 0, "A-LRSC-02 SC.D success rd=0");
            check(s.read_dmem(addr, 3) == 0x8877665544332211ULL, "A-LRSC-02 memory updated");
            check(s.physical_stores == 1, "A-LRSC-02 exactly one store emitted");
            ++scenarios;
        }

        // A-LRSC-03: SC.W executed without prior LR
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0xdeadbeef);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = sc_w(6, 7, 10); pc += 4; // Unpaired SC.W
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-03 SC.W failure rd=1");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0xdeadbeefULL, "A-LRSC-03 memory untouched");
            check(s.physical_stores == 0, "A-LRSC-03 zero physical store emitted");
            ++scenarios;
        }

        // A-LRSC-04: SC.D executed without prior LR
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 3, 0xdeadbeefcafebabeULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = sc_d(6, 7, 10); pc += 4; // Unpaired SC.D
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-04 SC.D failure rd=1");
            check(s.read_dmem(addr, 3) == 0xdeadbeefcafebabeULL, "A-LRSC-04 memory untouched");
            check(s.physical_stores == 0, "A-LRSC-04 zero physical store emitted");
            ++scenarios;
        }

        // A-LRSC-05: LR.W @ A followed by SC.W @ A+4 (same 64-byte granule)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x11111111);
            s.write_dmem(addr + 4, 2, 0x22222222);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4; // x10 = addr
            s.imem[pc] = addi(11, 10, 4); pc += 4;     // x11 = addr + 4 (same 64B granule)
            s.imem[pc] = addi(7, 0, 0x77); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;         // LR.W @ A
            s.imem[pc] = sc_w(6, 7, 11); pc += 4;      // SC.W @ A+4
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-05 SC.W failed due to exact address mismatch");
            check((s.read_dmem(addr + 4, 2) & 0xffffffffULL) == 0x22222222ULL, "A-LRSC-05 memory untouched");
            check(s.physical_stores == 0, "A-LRSC-05 zero physical store emitted");
            ++scenarios;
        }

        // A-LRSC-06: LR.W @ A followed by SC.D @ A (same address, size mismatch)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 3, 0x1111111122222222ULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;    // LR.W
            s.imem[pc] = sc_d(6, 7, 10); pc += 4; // SC.D (size mismatch!)
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-06 SC.D failed due to size mismatch");
            check(s.read_dmem(addr, 3) == 0x1111111122222222ULL, "A-LRSC-06 memory untouched");
            check(s.physical_stores == 0, "A-LRSC-06 zero physical store emitted");
            ++scenarios;
        }

        // A-LRSC-07: LR.D @ A followed by SC.W @ A (same address, size mismatch)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 3, 0x3333333344444444ULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = lr_d(5, 10); pc += 4;    // LR.D
            s.imem[pc] = sc_w(6, 7, 10); pc += 4; // SC.W (size mismatch!)
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-07 SC.W failed due to size mismatch");
            check(s.read_dmem(addr, 3) == 0x3333333344444444ULL, "A-LRSC-07 memory untouched");
            check(s.physical_stores == 0, "A-LRSC-07 zero physical store emitted");
            ++scenarios;
        }

        // A-LRSC-08: Virtual alias: LR.W via VA1 -> PA, conflicting store via VA2 -> PA, then SC.W via VA1
        {
            CoreSim s; s.reset();
            uint64_t pa = B + 0x400;
            s.write_dmem(pa, 2, 0x55555555);
            uint64_t s_code = B + 0x100;
            setup_sv39_environment(s, s_code);

            uint64_t pc = s_code;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x300); pc += 4; // x10 = pa = 0x80000400
            s.imem[pc] = addi(8, 0, 0x33); pc += 4;
            s.imem[pc] = addi(7, 0, 0x44); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;         // LR.W via VA1
            s.imem[pc] = sw(8, 10, 0); pc += 4;        // Normal store to same PA (simulates alias write)
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;      // SC.W via VA1
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-08 SC.W failed due to store to PA");
            check((s.read_dmem(pa, 2) & 0xffffffffULL) == 0x33ULL, "A-LRSC-08 memory preserved SW value");
            ++scenarios;
        }

        // A-LRSC-09: Invalid reservation + SC.W to unmapped virtual page -> Page fault takes precedence
        {
            CoreSim s; s.reset();
            uint64_t s_code = B + 0x100;
            setup_sv39_environment(s, s_code);

            uint64_t pc = s_code;
            s.imem[pc] = lui(10, 0x50000); pc += 4; // x10 = 0x50000000 (unmapped VA in Sv39)
            s.imem[pc] = addi(7, 0, 0x12); pc += 4;
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;  // SC.W to unmapped VA without reservation
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-LRSC-09 trap PC");
            check(s.dut.csr_scause_o == 15, "A-LRSC-09 Store/AMO page fault (cause 15)");
            check(s.dut.csr_stval_o == 0x50000000ULL, "A-LRSC-09 stval matches faulting VA");
            check(s.physical_stores == 0, "A-LRSC-09 zero physical stores emitted");
            ++scenarios;
        }

        // A-LRSC-10: LR.W followed by normal store SW to same address, then SC.W
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(8, 0, 0x77); pc += 4;
            s.imem[pc] = addi(7, 0, 0x88); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = sw(8, 10, 0); pc += 4;    // SW to same address
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;   // SC.W
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-10 SC.W failed due to intervening SW");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x77ULL, "A-LRSC-10 SW value preserved");
            ++scenarios;
        }

        // A-LRSC-11: LR.W followed by normal store SW to different address, then SC.W (conservative invalidation)
        {
            CoreSim s; s.reset();
            uint64_t addr1 = B + 0x400;
            uint64_t addr2 = B + 0x600;
            s.write_dmem(addr1, 2, 0x1234);
            s.write_dmem(addr2, 2, 0x5678);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(12, 10, 0x200); pc += 4; // x12 = addr2
            s.imem[pc] = addi(8, 0, 0x77); pc += 4;
            s.imem[pc] = addi(7, 0, 0x88); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = sw(8, 12, 0); pc += 4;        // SW to different address
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;      // SC.W
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-11 SC.W failed under conservative invalidation");
            ++scenarios;
        }

        // A-LRSC-12: LR.W followed by AMOADD.W, then SC.W
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 10);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(9, 0, 5); pc += 4;
            s.imem[pc] = addi(7, 0, 99); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = amoadd_w(8, 9, 10); pc += 4; // Intervening AMO
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;     // SC.W
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-12 SC.W failed after intervening AMO");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 15ULL, "A-LRSC-12 AMO result preserved");
            ++scenarios;
        }

        // A-LRSC-13: LR.W followed by synchronous trap (ECALL) + MRET, then SC.W
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);

            // Setup mtvec trap handler at MTV: advance mepc by 4 and MRET
            s.imem[MTV + 0] = csr(1, 31, 0, 0x341); // csrrw x31, mepc, x0
            s.imem[MTV + 4] = addi(31, 31, 4);      // x31 += 4
            s.imem[MTV + 8] = csr(1, 0, 31, 0x341); // csrrw x0, mepc, x31
            s.imem[MTV + 12] = MRET;

            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = ECALL; uint64_t sc_pc = pc + 4; pc += 4; // Synchronous trap
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;
            s.until_commit_allow_trap(sc_pc);
            check(s.reg(6) == 1, "A-LRSC-13 SC.W failed after trap/MRET invalidation");
            ++scenarios;
        }

        // A-LRSC-14: LR.W followed by interrupt + MRET, then SC.W
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);

            // Setup interrupt handler at MTV: clear mstatus.MIE to prevent storm and MRET
            s.imem[MTV + 0] = addi(31, 0, 8);
            s.imem[MTV + 4] = csr(3, 0, 31, 0x300); // clear mstatus.MIE
            s.imem[MTV + 8] = MRET;

            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = addi(1, 0, 0x80); pc += 4;  // mie.MTIE
            s.imem[pc] = csr(2, 0, 1, 0x304); pc += 4; // mie
            s.imem[pc] = addi(1, 0, 8); pc += 4;     // mstatus.MIE
            s.imem[pc] = csr(2, 0, 1, 0x300); pc += 4; // enable global interrupt
            s.imem[pc] = lr_w(5, 10); uint64_t lr_pc = pc; pc += 4;
            s.imem[pc] = addi(0, 0, 0); pc += 4;     // nop
            s.imem[pc] = sc_w(6, 7, 10); uint64_t sc_pc = pc; pc += 4;

            s.until_commit(lr_pc);
            s.dut.irq_timer_i = 1; // Assert interrupt
            s.until_trap();        // Wait for interrupt trap to be taken
            s.dut.irq_timer_i = 0; // Deassert interrupt
            s.until_commit(sc_pc); // Wait for SC to execute and commit after MRET
            check(s.reg(6) == 1, "A-LRSC-14 SC.W failed after interrupt invalidation");
            ++scenarios;
        }

        // A-LRSC-15: LR.W followed by SFENCE.VMA, then SC.W
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = SFENCE_VMA; pc += 4;       // SFENCE.VMA
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-15 SC.W failed after SFENCE.VMA");
            ++scenarios;
        }

        // A-LRSC-16: LR.W followed by satp CSR write, then SC.W
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x5a); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = csrw(0x180, 0); pc += 4;   // write satp = 0
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;
            s.until_commit(pc - 4);
            check(s.reg(6) == 1, "A-LRSC-16 SC.W failed after satp CSR write");
            ++scenarios;
        }

        // A-LRSC-17: LR.W with negative 32-bit value (bit 31=1) sign-extended
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x80001234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.until_commit(pc - 4);
            check(s.reg(5) == 0xffffffff80001234ULL, "A-LRSC-17 LR.W 64-bit sign-extension");
            ++scenarios;
        }

        // A-LRSC-18: LR.W with rd == x0
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x88); pc += 4;
            s.imem[pc] = lr_w(0, 10); pc += 4;    // rd = x0
            s.imem[pc] = sc_w(6, 7, 10); pc += 4; // SC should succeed
            s.until_commit(pc - 4);
            check(s.reg(0) == 0, "A-LRSC-18 x0 preserved");
            check(s.reg(6) == 0, "A-LRSC-18 SC.W succeeds with LR.W rd=x0");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x88ULL, "A-LRSC-18 memory updated");
            ++scenarios;
        }

        // A-LRSC-19: SC.W with rd == x0
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 0x99); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;
            s.imem[pc] = sc_w(0, 7, 10); pc += 4; // SC.W rd=x0
            s.imem[pc] = sc_w(6, 7, 10); pc += 4; // Second SC.W must fail (reservation consumed)
            s.until_commit(pc - 4);
            check(s.reg(0) == 0, "A-LRSC-19 x0 preserved");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x99ULL, "A-LRSC-19 memory updated by SC.W rd=x0");
            check(s.reg(6) == 1, "A-LRSC-19 second SC.W failed (reservation consumed by rd=x0 SC)");
            ++scenarios;
        }

        // A-LRSC-20: LR.W with non-zero rs2 field -> Illegal instruction exception
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            // LR.W with rs2 = 5
            uint32_t bad_lr = r_type_amo(0x02, false, false, 5, 10, 0x2, 5);
            s.imem[pc] = bad_lr; pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-LRSC-20 trap PC");
            check(s.dut.csr_mcause_o == 2, "A-LRSC-20 illegal instruction cause 2");
            check(s.dut.csr_mtval_o == bad_lr, "A-LRSC-20 mtval holds bad instruction word");
            ++scenarios;
        }

        // A-LRSC-21: Misaligned LR.W (addr[1:0] != 0)
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x401); pc += 4; // Misaligned addr
            s.imem[pc] = lr_w(5, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-LRSC-21 trap PC");
            check(s.dut.csr_mcause_o == 4, "A-LRSC-21 load misaligned cause 4");
            check(s.dut.csr_mtval_o == (B + 0x401), "A-LRSC-21 mtval matches bad addr");
            ++scenarios;
        }

        // A-LRSC-22: Misaligned SC.W (addr[1:0] != 0)
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x402); pc += 4;
            s.imem[pc] = addi(7, 0, 0x11); pc += 4;
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-LRSC-22 trap PC");
            check(s.dut.csr_mcause_o == 6, "A-LRSC-22 store misaligned cause 6");
            check(s.dut.csr_mtval_o == (B + 0x402), "A-LRSC-22 mtval matches bad addr");
            ++scenarios;
        }

        // A-LRSC-23: Misaligned LR.D (addr[2:0] != 0)
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x404); pc += 4; // Misaligned for 8-byte
            s.imem[pc] = lr_d(5, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-LRSC-23 trap PC");
            check(s.dut.csr_mcause_o == 4, "A-LRSC-23 load misaligned cause 4");
            check(s.dut.csr_mtval_o == (B + 0x404), "A-LRSC-23 mtval matches bad addr");
            ++scenarios;
        }

        // A-LRSC-24: Misaligned SC.D (addr[2:0] != 0)
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x404); pc += 4;
            s.imem[pc] = addi(7, 0, 0x22); pc += 4;
            s.imem[pc] = sc_d(6, 7, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-LRSC-24 trap PC");
            check(s.dut.csr_mcause_o == 6, "A-LRSC-24 store misaligned cause 6");
            check(s.dut.csr_mtval_o == (B + 0x404), "A-LRSC-24 mtval matches bad addr");
            ++scenarios;
        }

        // =====================================================================
        // PART 2: A-AMO-01 .. A-AMO-13
        // =====================================================================

        // A-AMO-01: AMOSWAP.W and AMOSWAP.D
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x11111111);
            s.write_dmem(addr + 8, 3, 0x1111111122222222ULL);
            s.write_dmem(addr + 0x80, 3, 0x3333333344444444ULL); // literal
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = lui(7, 0x22222); pc += 4;
            s.imem[pc] = addi(7, 7, 0x222); pc += 4; // x7 = 0x22222222
            s.imem[pc] = amoswap_w(5, 7, 10); pc += 4; // SWAP.W
            s.imem[pc] = ld(8, 10, 0x80); pc += 4;    // x8 = 0x3333333344444444
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amoswap_d(6, 8, 11); pc += 4; // SWAP.D
            s.until_commit(pc - 4);
            check((s.reg(5) & 0xffffffffULL) == 0x11111111ULL, "A-AMO-01 SWAP.W original returned");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x22222222ULL, "A-AMO-01 SWAP.W memory updated");
            check(s.reg(6) == 0x1111111122222222ULL, "A-AMO-01 SWAP.D original returned");
            check(s.read_dmem(addr + 8, 3) == 0x3333333344444444ULL, "A-AMO-01 SWAP.D memory updated");
            ++scenarios;
        }

        // A-AMO-02: AMOADD.W and AMOADD.D with 32-bit wrap and negative values
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            // Test 1: AMOADD.W wrapping 0x7fffffff + 1 -> 0x80000000 (sign-extended to 0xffffffff80000000)
            s.write_dmem(addr, 2, 0x7fffffff);
            // Test 2: AMOADD.D wrapping 0x7fffffffffffffff + 1 -> 0x8000000000000000
            s.write_dmem(addr + 8, 3, 0x7fffffffffffffffULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4; // AMOADD.W
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amoadd_d(6, 7, 11); pc += 4; // AMOADD.D
            s.until_commit(pc - 4);
            check(s.reg(5) == 0x7fffffffULL, "A-AMO-02 AMOADD.W returned original");
            check(s.read_dmem(addr, 2) == 0x80000000ULL, "A-AMO-02 AMOADD.W wrapped correctly");
            check(s.reg(6) == 0x7fffffffffffffffULL, "A-AMO-02 AMOADD.D returned original");
            check(s.read_dmem(addr + 8, 3) == 0x8000000000000000ULL, "A-AMO-02 AMOADD.D wrapped correctly");
            ++scenarios;
        }

        // A-AMO-03: AMOXOR.W and AMOXOR.D
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x00ff00ff);
            s.write_dmem(addr + 8, 3, 0x00ff00ff00ff00ffULL);
            s.write_dmem(addr + 0x80, 2, 0x0f0f0f0f);
            s.write_dmem(addr + 0x88, 3, 0x0f0f0f0f0f0f0f0fULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = lw(7, 10, 0x80); pc += 4;     // x7 = 0x0f0f0f0f
            s.imem[pc] = amoxor_w(5, 7, 10); pc += 4;
            s.imem[pc] = ld(8, 10, 0x88); pc += 4;     // x8 = 0x0f0f0f0f0f0f0f0f
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amoxor_d(6, 8, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x0ff00ff0ULL, "A-AMO-03 XOR.W memory updated");
            check(s.read_dmem(addr + 8, 3) == 0x0ff00ff00ff00ff0ULL, "A-AMO-03 XOR.D memory updated");
            ++scenarios;
        }

        // A-AMO-04: AMOAND.W and AMOAND.D
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x12345678);
            s.write_dmem(addr + 8, 3, 0x123456789abcdef0ULL);
            s.write_dmem(addr + 0x80, 2, 0x00ff00ff);
            s.write_dmem(addr + 0x88, 3, 0x00ff00ff00ff00ffULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = lw(7, 10, 0x80); pc += 4;     // x7 = 0x00ff00ff
            s.imem[pc] = amoand_w(5, 7, 10); pc += 4;
            s.imem[pc] = ld(8, 10, 0x88); pc += 4;     // x8 = 0x00ff00ff00ff00ff
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amoand_d(6, 8, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x00340078ULL, "A-AMO-04 AND.W memory updated");
            check(s.read_dmem(addr + 8, 3) == (0x123456789abcdef0ULL & 0x00ff00ff00ff00ffULL), "A-AMO-04 AND.D memory updated");
            ++scenarios;
        }

        // A-AMO-05: AMOOR.W and AMOOR.D
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x12003400);
            s.write_dmem(addr + 8, 3, 0x1200340056007800ULL);
            s.write_dmem(addr + 0x80, 2, 0x00560078);
            s.write_dmem(addr + 0x88, 3, 0x0056007800560078ULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = lw(7, 10, 0x80); pc += 4;     // x7 = 0x00560078
            s.imem[pc] = amoor_w(5, 7, 10); pc += 4;
            s.imem[pc] = ld(8, 10, 0x88); pc += 4;     // x8 = 0x0056007800560078
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amoor_d(6, 8, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0x12563478ULL, "A-AMO-05 OR.W memory updated");
            check(s.read_dmem(addr + 8, 3) == (0x1200340056007800ULL | 0x0056007800560078ULL), "A-AMO-05 OR.D memory updated");
            ++scenarios;
        }

        // A-AMO-06: AMOMIN.W and AMOMIN.D (signed comparison)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            // .W: -5 (0xfffffffb) vs 10 -> MIN should be -5
            s.write_dmem(addr, 2, 0xfffffffb);
            // .D: -100 vs 50 -> MIN should be -100
            s.write_dmem(addr + 8, 3, uint64_t(-100LL));
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 10); pc += 4;
            s.imem[pc] = amomin_w(5, 7, 10); pc += 4;
            s.imem[pc] = addi(8, 0, 50); pc += 4;
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amomin_d(6, 8, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0xfffffffbULL, "A-AMO-06 MIN.W selected signed -5");
            check(s.read_dmem(addr + 8, 3) == uint64_t(-100LL), "A-AMO-06 MIN.D selected signed -100");
            ++scenarios;
        }

        // A-AMO-07: AMOMAX.W and AMOMAX.D (signed comparison)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            // .W: -5 vs 10 -> MAX should be 10
            s.write_dmem(addr, 2, 0xfffffffb);
            // .D: -100 vs 50 -> MAX should be 50
            s.write_dmem(addr + 8, 3, uint64_t(-100LL));
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 10); pc += 4;
            s.imem[pc] = amomax_w(5, 7, 10); pc += 4;
            s.imem[pc] = addi(8, 0, 50); pc += 4;
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amomax_d(6, 8, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 10ULL, "A-AMO-07 MAX.W selected 10");
            check(s.read_dmem(addr + 8, 3) == 50ULL, "A-AMO-07 MAX.D selected 50");
            ++scenarios;
        }

        // A-AMO-08: AMOMINU.W and AMOMINU.D (unsigned comparison)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            // .W: 0xffffffff (unsigned 4294967295) vs 10 -> MINU is 10!
            s.write_dmem(addr, 2, 0xffffffff);
            // .D: 0xffffffffffffffffULL vs 10ULL -> MINU is 10!
            s.write_dmem(addr + 8, 3, 0xffffffffffffffffULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 10); pc += 4;
            s.imem[pc] = amominu_w(5, 7, 10); pc += 4;
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amominu_d(6, 7, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 10ULL, "A-AMO-08 MINU.W selected 10");
            check(s.read_dmem(addr + 8, 3) == 10ULL, "A-AMO-08 MINU.D selected 10");
            ++scenarios;
        }

        // A-AMO-09: AMOMAXU.W and AMOMAXU.D (unsigned comparison)
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            // .W: 0xffffffff vs 10 -> MAXU is 0xffffffff
            s.write_dmem(addr, 2, 0xffffffff);
            // .D: 0xffffffffffffffffULL vs 10ULL -> MAXU is 0xffffffffffffffffULL
            s.write_dmem(addr + 8, 3, 0xffffffffffffffffULL);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 10); pc += 4;
            s.imem[pc] = amomaxu_w(5, 7, 10); pc += 4;
            s.imem[pc] = addi(11, 10, 8); pc += 4;
            s.imem[pc] = amomaxu_d(6, 7, 11); pc += 4;
            s.until_commit(pc - 4);
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 0xffffffffULL, "A-AMO-09 MAXU.W selected 0xffffffff");
            check(s.read_dmem(addr + 8, 3) == 0xffffffffffffffffULL, "A-AMO-09 MAXU.D selected max uint64");
            ++scenarios;
        }

        // A-AMO-10: AMO*.W with bit 31 set sign-extended to 64-bit rd
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x80000001);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = amoor_w(5, 0, 10); pc += 4; // OR with 0
            s.until_commit(pc - 4);
            check(s.reg(5) == 0xffffffff80000001ULL, "A-AMO-10 AMO.W original sign-extended to 64 bits");
            ++scenarios;
        }

        // A-AMO-11: AMO*.W/D with rd == x0
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 50);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 25); pc += 4;
            s.imem[pc] = amoadd_w(0, 7, 10); pc += 4; // rd = x0
            s.until_commit(pc - 4);
            check(s.reg(0) == 0, "A-AMO-11 x0 remains zero");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 75ULL, "A-AMO-11 memory updated atomically with rd=x0");
            check(s.physical_stores == 1, "A-AMO-11 physical store emitted");
            ++scenarios;
        }

        // A-AMO-12: Misaligned AMO.W (addr[1:0] != 0)
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x401); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-AMO-12 trap PC");
            check(s.dut.csr_mcause_o == 6, "A-AMO-12 store/AMO misaligned cause 6");
            check(s.dut.csr_mtval_o == (B + 0x401), "A-AMO-12 mtval matches bad addr");
            check(s.physical_stores == 0, "A-AMO-12 zero physical store");
            ++scenarios;
        }

        // A-AMO-13: Misaligned AMO.D (addr[2:0] != 0)
        {
            CoreSim s; s.reset();
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x402); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_d(5, 7, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-AMO-13 trap PC");
            check(s.dut.csr_mcause_o == 6, "A-AMO-13 store/AMO misaligned cause 6");
            check(s.dut.csr_mtval_o == (B + 0x402), "A-AMO-13 mtval matches bad addr");
            check(s.physical_stores == 0, "A-AMO-13 zero physical store");
            ++scenarios;
        }

        // =====================================================================
        // PART 3: A-SYS-01 .. A-SYS-09
        // =====================================================================

        // A-SYS-01: Sv39 Page Fault: AMO on read-only page (R=1, W=0) -> Cause 15
        {
            CoreSim s; s.reset();
            uint64_t s_code = B + 0x100;
            // Setup root page table with R=1, W=0, X=1, A=1, D=1 (read-only page)
            uint64_t root_addr = ROOT_PPN << 12;
            s.write_dmem(root_addr + 2 * 8, 3, (0x80000ULL << 10) | 0xcb); // R=1, W=0, X=1

            // Enter S-mode
            uint64_t pc = B;
            s.imem[pc] = addi(10, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x3b0, 10); pc += 4;
            s.imem[pc] = addi(11, 0, 0x1f); pc += 4;
            s.imem[pc] = csrw(0x3a0, 11); pc += 4;
            s.imem[pc] = addi(1, 0, 8); pc += 4;
            s.imem[pc] = slli(1, 1, 60); pc += 4;
            s.imem[pc] = ori(1, 1, ROOT_PPN); pc += 4;
            s.imem[pc] = csrw(0x180, 1); pc += 4;
            s.imem[pc] = addi(3, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x302, 3); pc += 4;
            s.imem[pc] = auipc(4); uint64_t p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(STV - p)); pc += 4;
            s.imem[pc] = csrw(0x105, 4); pc += 4;
            s.imem[pc] = auipc(4); p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(s_code - p)); pc += 4;
            s.imem[pc] = csrw(0x341, 4); pc += 4;
            s.imem[pc] = addi(5, 0, 3); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(3, 0, 5, 0x300); pc += 4; // clear MPP
            s.imem[pc] = addi(5, 0, 1); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(2, 0, 5, 0x300); pc += 4; // set MPP=1
            s.imem[pc] = MRET;

            // S-mode instruction: AMO on read-only page
            pc = s_code;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4; // AMO on read-only page
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-SYS-01 trap PC");
            check(s.dut.csr_scause_o == 15, "A-SYS-01 Store/AMO page fault (cause 15)");
            check(s.physical_stores == 0, "A-SYS-01 zero physical store emitted");
            ++scenarios;
        }

        // A-SYS-02: Sv39 Page Fault: AMO on execute-only page with MXR=1 -> Cause 15
        {
            CoreSim s; s.reset();
            uint64_t s_code = B + 0x100;
            // Root PTE: R=0, W=0, X=1 (execute only)
            uint64_t root_addr = ROOT_PPN << 12;
            s.write_dmem(root_addr + 2 * 8, 3, (0x80000ULL << 10) | 0xc9); // R=0, W=0, X=1

            // Setup M-mode to S-mode transition and set mstatus.MXR (bit 19)
            uint64_t pc = B;
            s.imem[pc] = addi(10, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x3b0, 10); pc += 4;
            s.imem[pc] = addi(11, 0, 0x1f); pc += 4;
            s.imem[pc] = csrw(0x3a0, 11); pc += 4;
            s.imem[pc] = addi(1, 0, 8); pc += 4;
            s.imem[pc] = slli(1, 1, 60); pc += 4;
            s.imem[pc] = ori(1, 1, ROOT_PPN); pc += 4;
            s.imem[pc] = csrw(0x180, 1); pc += 4;
            s.imem[pc] = addi(3, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x302, 3); pc += 4;
            s.imem[pc] = auipc(4); uint64_t p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(STV - p)); pc += 4;
            s.imem[pc] = csrw(0x105, 4); pc += 4;
            s.imem[pc] = auipc(4); p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(s_code - p)); pc += 4;
            s.imem[pc] = csrw(0x341, 4); pc += 4;
            // Clear MPP
            s.imem[pc] = addi(5, 0, 3); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(3, 0, 5, 0x300); pc += 4;
            // Set MPP=1 (S-mode) and MXR (bit 19)
            s.imem[pc] = addi(5, 0, 1); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4; // bit 11 = MPP
            s.imem[pc] = addi(6, 0, 1); pc += 4;
            s.imem[pc] = slli(6, 6, 19); pc += 4; // bit 19 = MXR
            s.imem[pc] = csr(2, 0, 5, 0x300); pc += 4;
            s.imem[pc] = csr(2, 0, 6, 0x300); pc += 4;
            s.imem[pc] = MRET;

            pc = s_code;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4; // AMO on execute-only with MXR=1
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-SYS-02 trap PC");
            check(s.dut.csr_scause_o == 15, "A-SYS-02 MXR cannot validate AMO -> Cause 15");
            check(s.physical_stores == 0, "A-SYS-02 zero physical store emitted");
            ++scenarios;
        }

        // A-SYS-03: Sv39 Page Fault: AMO on Svade un-dirty page (D=0) -> Cause 15
        {
            CoreSim s; s.reset();
            uint64_t s_code = B + 0x100;
            // Root PTE: R=1, W=1, X=1, A=1, D=0 (un-dirty)
            uint64_t root_addr = ROOT_PPN << 12;
            s.write_dmem(root_addr + 2 * 8, 3, (0x80000ULL << 10) | 0x4f); // D=0, A=1, X=1, W=1, R=1, V=1

            uint64_t pc = B;
            s.imem[pc] = addi(10, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x3b0, 10); pc += 4;
            s.imem[pc] = addi(11, 0, 0x1f); pc += 4;
            s.imem[pc] = csrw(0x3a0, 11); pc += 4;
            s.imem[pc] = addi(1, 0, 8); pc += 4;
            s.imem[pc] = slli(1, 1, 60); pc += 4;
            s.imem[pc] = ori(1, 1, ROOT_PPN); pc += 4;
            s.imem[pc] = csrw(0x180, 1); pc += 4;
            s.imem[pc] = addi(3, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x302, 3); pc += 4;
            s.imem[pc] = auipc(4); uint64_t p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(STV - p)); pc += 4;
            s.imem[pc] = csrw(0x105, 4); pc += 4;
            s.imem[pc] = auipc(4); p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(s_code - p)); pc += 4;
            s.imem[pc] = csrw(0x341, 4); pc += 4;
            s.imem[pc] = addi(5, 0, 3); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(3, 0, 5, 0x300); pc += 4; // clear MPP
            s.imem[pc] = addi(5, 0, 1); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(2, 0, 5, 0x300); pc += 4; // set MPP=1
            s.imem[pc] = MRET;

            pc = s_code;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-SYS-03 trap PC");
            check(s.dut.csr_scause_o == 15, "A-SYS-03 Svade D=0 page fault cause 15");
            check(s.physical_stores == 0, "A-SYS-03 zero physical store emitted");
            ++scenarios;
        }

        // A-SYS-04: PMP Denial: AMO on PMP read-only region (R=1, W=0) -> Store/AMO access fault (cause 7)
        {
            CoreSim s; s.reset();
            uint64_t s_code = B + 0x100;
            // Setup PMP:
            // Entry 0: covers all addresses with R=1, W=0, X=1 (TOR, read-only for S-mode)
            uint64_t pc = B;
            s.imem[pc] = addi(10, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x3b0, 10); pc += 4; // pmpaddr0 = -1
            s.imem[pc] = addi(11, 0, 0x1d); pc += 4; // pmpcfg0 = NAPOT | X | R (W=0)
            s.imem[pc] = csrw(0x3a0, 11); pc += 4;

            // Delegate to S-mode
            s.imem[pc] = addi(3, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x302, 3); pc += 4;
            s.imem[pc] = auipc(4); uint64_t p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(STV - p)); pc += 4;
            s.imem[pc] = csrw(0x105, 4); pc += 4;
            s.imem[pc] = auipc(4); p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(s_code - p)); pc += 4;
            s.imem[pc] = csrw(0x341, 4); pc += 4;
            s.imem[pc] = addi(5, 0, 3); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(3, 0, 5, 0x300); pc += 4; // clear MPP
            s.imem[pc] = addi(5, 0, 1); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(2, 0, 5, 0x300); pc += 4; // set MPP=1
            s.imem[pc] = MRET;

            pc = s_code;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4; // AMO on PMP read-only
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-SYS-04 trap PC");
            check(s.dut.csr_scause_o == 7, "A-SYS-04 Store/AMO access fault (cause 7)");
            check(s.physical_stores == 0, "A-SYS-04 zero physical store emitted");
            ++scenarios;
        }

        // A-SYS-05: PMP Denial: SC on PMP denied region -> Cause 7
        {
            CoreSim s; s.reset();
            uint64_t s_code = B + 0x100;
            // PMP Entry 0: NAPOT, R=1, W=0, X=1
            uint64_t pc = B;
            s.imem[pc] = addi(10, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x3b0, 10); pc += 4;
            s.imem[pc] = addi(11, 0, 0x1d); pc += 4; // W=0, X=1, R=1
            s.imem[pc] = csrw(0x3a0, 11); pc += 4;

            s.imem[pc] = addi(3, 0, -1); pc += 4;
            s.imem[pc] = csrw(0x302, 3); pc += 4;
            s.imem[pc] = auipc(4); uint64_t p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(STV - p)); pc += 4;
            s.imem[pc] = csrw(0x105, 4); pc += 4;
            s.imem[pc] = auipc(4); p = pc; pc += 4;
            s.imem[pc] = addi(4, 4, int(s_code - p)); pc += 4;
            s.imem[pc] = csrw(0x341, 4); pc += 4;
            s.imem[pc] = addi(5, 0, 3); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(3, 0, 5, 0x300); pc += 4; // clear MPP
            s.imem[pc] = addi(5, 0, 1); pc += 4;
            s.imem[pc] = slli(5, 5, 11); pc += 4;
            s.imem[pc] = csr(2, 0, 5, 0x300); pc += 4; // set MPP=1
            s.imem[pc] = MRET;

            pc = s_code;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = lr_w(5, 10); pc += 4;       // LR.W succeeds (R=1)
            s.imem[pc] = sc_w(6, 7, 10); pc += 4;      // SC.W denied by PMP (W=0)
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-SYS-05 trap PC");
            check(s.dut.csr_scause_o == 7, "A-SYS-05 SC PMP denied -> Cause 7");
            check(s.physical_stores == 0, "A-SYS-05 zero physical store emitted");
            ++scenarios;
        }

        // A-SYS-06: Platform Bus Error: Read phase error during AMO -> Cause 7 & write suppressed
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4;

            // Inject bus error on memory read response
            s.inject_dmem_rsp_error = true;
            auto ev = s.until_trap();
            check(ev.pc == pc - 4, "A-SYS-06 trap PC");
            check(s.dut.csr_mcause_o == 7, "A-SYS-06 read-phase error -> Store/AMO access fault (cause 7)");
            check(s.physical_stores == 0, "A-SYS-06 write phase strictly suppressed");
            ++scenarios;
        }

        // A-SYS-07: Platform Bus Error: Write phase error during AMO -> Cause 7 & rd suppressed
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 0x1234);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 1); pc += 4;
            s.imem[pc] = addi(5, 0, 0x5a); pc += 4; // Pre-load x5 with canary
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4; // Target AMO

            // Run until read phase request fires
            bool read_seen = false;
            for (int c = 0; c < 100 && !read_seen; ++c) {
                Event ev = s.tick();
                if (ev.dmem_fire && !ev.dmem_store && ev.dmem_addr == addr) {
                    read_seen = true;
                }
            }
            check(read_seen, "A-SYS-07 AMO read phase reached");

            // Inject error on the upcoming write request
            s.inject_dmem_req_error = true;
            auto ev = s.until_trap();
            check(s.dut.csr_mcause_o == 7, "A-SYS-07 write-phase bus error -> Cause 7");
            check(s.reg(5) == 0x5a, "A-SYS-07 rd writeback strictly suppressed (canary preserved)");
            ++scenarios;
        }

        // A-SYS-08: Interrupt arriving between AMO read and write phases -> Deferred until write completion
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 42);

            // mtvec interrupt handler at MTV: clear mstatus.MIE and return
            s.imem[MTV + 0] = addi(31, 0, 8);
            s.imem[MTV + 4] = csr(3, 0, 31, 0x300);
            s.imem[MTV + 8] = MRET;

            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 8); pc += 4;
            s.imem[pc] = addi(1, 0, 0x80); pc += 4;  // mie.MTIE
            s.imem[pc] = csr(2, 0, 1, 0x304); pc += 4;
            s.imem[pc] = addi(1, 0, 8); pc += 4;     // mstatus.MIE
            s.imem[pc] = csr(2, 0, 1, 0x300); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); uint64_t amo_pc = pc; pc += 4;
            s.imem[pc] = addi(20, 0, 99); pc += 4;

            // Run until read phase request fires
            bool read_fired = false;
            for (int c = 0; c < 100 && !read_fired; ++c) {
                Event ev = s.tick();
                if (ev.dmem_fire && !ev.dmem_store && ev.dmem_addr == addr) {
                    read_fired = true;
                }
            }
            check(read_fired, "A-SYS-08 AMO read phase reached");

            // Assert timer interrupt between read and write
            s.dut.irq_timer_i = 1;

            // The AMO instruction MUST commit successfully BEFORE interrupt trap is taken!
            Event commit_ev = s.until_commit(amo_pc);
            check(commit_ev.commit && commit_ev.pc == amo_pc, "A-SYS-08 AMO committed non-preemptively");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 50ULL, "A-SYS-08 AMO write completed before interrupt");

            // After AMO commit, next cycle takes the deferred interrupt
            auto trap_ev = s.until_trap();
            check((uint64_t(s.dut.csr_mcause_o) >> 63) == 1, "A-SYS-08 interrupt taken after AMO");
            check((s.dut.csr_mcause_o & 0x3f) == 7, "A-SYS-08 MTIP cause 7");
            s.dut.irq_timer_i = 0;
            ++scenarios;
        }

        // A-SYS-09: Platform Reset asserted during AMO execution -> No post-reset store leak & bus ownership clean
        {
            CoreSim s; s.reset();
            uint64_t addr = B + 0x400;
            s.write_dmem(addr, 2, 100);
            uint64_t pc = B;
            s.imem[pc] = auipc(10); pc += 4;
            s.imem[pc] = addi(10, 10, 0x400); pc += 4;
            s.imem[pc] = addi(7, 0, 50); pc += 4;
            s.imem[pc] = amoadd_w(5, 7, 10); pc += 4;

            // Run until AMO read request fires
            bool read_seen = false;
            for (int c = 0; c < 100 && !read_seen; ++c) {
                Event ev = s.tick();
                if (ev.dmem_fire && !ev.dmem_store) read_seen = true;
            }
            check(read_seen, "A-SYS-09 read fired");

            // Assert reset right after read
            s.dut.rst_i = 1;
            s.dut.eval();
            s.dut.clk_i = 1; s.dut.eval();
            s.dut.clk_i = 0; s.dut.rst_i = 0; s.dut.eval();

            // Clear imem to nop to prevent new instructions from launching
            s.imem.clear();
            unsigned post_reset_stores = 0;
            for (int c = 0; c < 50; ++c) {
                Event ev = s.tick();
                if (ev.dmem_fire && ev.dmem_store) ++post_reset_stores;
            }
            check(post_reset_stores == 0, "A-SYS-09 zero post-reset store leak");
            check((s.read_dmem(addr, 2) & 0xffffffffULL) == 100ULL, "A-SYS-09 memory untouched by aborted AMO");
            ++scenarios;
        }

        std::cout << "{\"status\":\"pass\",\"scenarios\":" << scenarios << "}\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "RV64A_S0_MISMATCH scenario=" << scenarios + 1 << " reason=" << e.what() << "\n";
        return 1;
    }
}
