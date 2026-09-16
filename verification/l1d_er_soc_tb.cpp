#include "Vfursoy_s0_soc.h"
#include "Vfursoy_s0_soc___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <unordered_map>

static void check(bool v, const std::string& msg) {
    if (!v) throw std::runtime_error(msg);
}

static uint32_t auipc(unsigned rd, uint32_t imm20) {
    return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x17;
}
static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
static uint32_t ld(unsigned rd, unsigned rs1, int imm) {
    return ((uint32_t(imm) & 0xfff) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03;
}

struct SocSim {
    Vfursoy_s0_soc dut;
    std::unordered_map<uint64_t, uint64_t> mem;
    bool imem_pending = false;
    uint64_t imem_data = 0;
    bool ram_pending = false;
    uint64_t ram_data = 0;
    bool ram_error = false;
    bool enable_trailing_error = false;
    int error_beat = 6;
    uint64_t commits = 0;
    uint64_t cycles = 0;
    uint64_t ram_requests = 0;
    uint64_t ram_responses = 0;
    bool saw_owned_error = false;

    void put32(uint64_t addr, uint32_t insn) {
        uint64_t a = addr & ~7ULL;
        uint64_t d = mem.count(a) ? mem[a] : 0x0000001300000013ULL;
        if (addr & 4) d = (d & 0xffffffffULL) | (uint64_t(insn) << 32);
        else d = (d & 0xffffffff00000000ULL) | insn;
        mem[a] = d;
    }

    uint64_t read64(uint64_t addr) const {
        auto it = mem.find(addr & ~7ULL);
        return it == mem.end() ? 0x0000001300000013ULL : it->second;
    }

    void reset() {
        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = 0;
        dut.imem_rsp_data_i = 0;
        dut.imem_rsp_error_i = 0;
        dut.ram_req_ready_i = 1;
        dut.ram_req_error_i = 0;
        dut.ram_rsp_valid_i = 0;
        dut.ram_rsp_data_i = 0;
        dut.ram_rsp_error_i = 0;
        dut.irq_sources_i = 0;
        dut.irq_external_i = 0;
        dut.eval();
        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        dut.clk_i = 0;
        dut.rst_i = 0;
        dut.eval();
        imem_pending = false;
        ram_pending = false;
        enable_trailing_error = false;
    }

    void tick() {
        dut.clk_i = 0;
        dut.rst_i = 0;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = imem_pending;
        dut.imem_rsp_data_i = imem_data;
        dut.imem_rsp_error_i = 0;
        dut.ram_req_ready_i = 1;
        dut.ram_req_error_i = 0;
        dut.ram_rsp_valid_i = ram_pending;
        dut.ram_rsp_data_i = ram_data;
        dut.ram_rsp_error_i = ram_pending && ram_error;
        dut.eval();

        bool if_rsp_fire = imem_pending && dut.imem_rsp_ready_o;
        bool if_req_fire = dut.imem_req_valid_o && dut.imem_req_ready_i;
        bool ram_rsp_fire = ram_pending && dut.ram_rsp_ready_o;
        bool ram_req_fire = dut.ram_req_valid_o && dut.ram_req_ready_i;
        bool next_if_pending = imem_pending;
        bool next_ram_pending = ram_pending;
        uint64_t next_if_data = imem_data;
        uint64_t next_ram_data = ram_data;
        bool next_ram_error = ram_error;

        if (if_rsp_fire) next_if_pending = false;
        if (if_req_fire) {
            next_if_data = read64(dut.imem_req_addr_o);
            next_if_pending = true;
        }
        if (ram_rsp_fire) {
            check(dut.rootp->fursoy_s0_soc__DOT__rsp_owner_q == 1,
                  "SOC-CASE-D: RAM response consumed without RSP_RAM ownership");
            if (ram_error) saw_owned_error = true;
            next_ram_pending = false;
            ++ram_responses;
        }
        if (ram_req_fire) {
            check(!dut.ram_req_store_o && !dut.ram_req_ptw_o,
                  "SOC-CASE-D: unexpected store/PTW request");
            check(!next_ram_pending, "SOC-CASE-D: more than one RAM response outstanding");
            int beat = int((uint64_t(dut.ram_req_addr_o) >> 3) & 7);
            next_ram_data = read64(dut.ram_req_addr_o);
            next_ram_error = enable_trailing_error && beat == error_beat;
            next_ram_pending = true;
            ++ram_requests;
        }

        bool commit = dut.commit_valid_o;
        unsigned rd = dut.commit_rd_o;
        uint64_t rd_data = dut.commit_rd_data_o;
        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        if (commit) {
            ++commits;
            if (rd == 10 && rd_data == 0xfeedfacecafebeefULL)
                enable_trailing_error = true;
        }
        imem_pending = next_if_pending;
        imem_data = next_if_data;
        ram_pending = next_ram_pending;
        ram_data = next_ram_data;
        ram_error = next_ram_error;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    try {
        constexpr uint64_t B = 0x80000000ULL;
        constexpr uint64_t target = B + 0x1020;
        constexpr uint64_t line = target & ~63ULL;
        constexpr unsigned set = (line >> 6) & 63;
        SocSim s;
        s.put32(B, auipc(1, 1));
        s.put32(B + 4, addi(1, 1, 0x20));
        s.put32(B + 8, ld(10, 1, 0));
        s.put32(B + 12, addi(11, 0, 7));
        for (int i = 0; i < 8; ++i) s.mem[line + 8 * i] = 0x1100000000000000ULL + i;
        s.mem[target] = 0xfeedfacecafebeefULL;
        s.reset();

        uint8_t plru_before = s.dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__plru_q[set];
        for (int i = 0; i < 1000 && !s.enable_trailing_error; ++i) s.tick();
        check(s.enable_trailing_error, "SOC-CASE-D: qualifying load did not retire early");
        uint64_t commits_at_load = s.commits;
        check(commits_at_load == 3, "SOC-CASE-D: unexpected commit count before trailing error");

        for (int i = 0; i < 1000 && !s.dut.fatal_halt_o; ++i) s.tick();
        check(s.dut.fatal_halt_o, "SOC-CASE-D: top-level fatal_halt_o did not assert");
        check(s.saw_owned_error, "SOC-CASE-D: error response did not exercise owned SoC RAM path");
        check(s.dut.rootp->fursoy_s0_soc__DOT__rsp_owner_q == 0,
              "SOC-CASE-D: response owner did not drain to RSP_NONE");
        check(!s.ram_pending && s.ram_requests == s.ram_responses,
              "SOC-CASE-D: orphan RAM request/response remains");
        for (int w = 0; w < 4; ++w)
            check(!s.dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__valid_q[set][w],
                  "SOC-CASE-D: poisoned/incomplete line installed");
        check(s.dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__plru_q[set] == plru_before,
              "SOC-CASE-D: PLRU published success for poisoned refill");

        uint64_t commits_at_fatal = s.commits;
        uint64_t requests_at_fatal = s.ram_requests;
        for (int i = 0; i < 12; ++i) {
            s.tick();
            check(s.dut.fatal_halt_o, "SOC-CASE-D: fatal_halt_o was not sticky");
            check(s.commits == commits_at_fatal, "SOC-CASE-D: execution continued after fatal halt");
            check(s.ram_requests == requests_at_fatal, "SOC-CASE-D: new RAM work began after fatal halt");
            check(s.dut.rootp->fursoy_s0_soc__DOT__rsp_owner_q == 0,
                  "SOC-CASE-D: owner reappeared after drain");
        }

        s.dut.clk_i = 0;
        s.dut.rst_i = 1;
        s.dut.eval();
        s.dut.clk_i = 1;
        s.dut.eval();
        check(!s.dut.fatal_halt_o, "SOC-CASE-D: reset did not clear fatal halt");
        check(s.dut.rootp->fursoy_s0_soc__DOT__rsp_owner_q == 0,
              "SOC-CASE-D: reset did not restore RSP_NONE");
        s.dut.rst_i = 0;
        s.dut.imem_req_ready_i = 0;
        s.dut.imem_rsp_valid_i = 0;
        s.dut.ram_rsp_valid_i = 0;
        for (int i = 0; i < 4 && !s.dut.imem_req_valid_o; ++i) {
            s.dut.clk_i = 0;
            s.dut.eval();
            s.dut.clk_i = 1;
            s.dut.eval();
        }
        s.dut.clk_i = 0;
        s.dut.eval();
        check(s.dut.imem_req_valid_o && uint64_t(s.dut.imem_req_addr_o) == B,
              "SOC-CASE-D: reset did not restore defined reset fetch behavior");

        std::cout << "SOC-CASE-D PASS: production SoC fatal path, ownership drain, poison, stickiness, and reset verified\n";
        std::cout << "{\"status\":\"pass\",\"commits_before_fatal\":" << commits_at_fatal
                  << ",\"ram_requests\":" << s.ram_requests
                  << ",\"ram_responses\":" << s.ram_responses << "}\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "L1D_ER_SOC_MISMATCH: " << e.what() << "\n";
        return 1;
    }
}
