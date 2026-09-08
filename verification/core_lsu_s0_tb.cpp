#include "Vfursoy_s0_core.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>

static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
static uint32_t lw(unsigned rd, unsigned rs1) {
    return (rs1 << 15) | (2 << 12) | (rd << 7) | 0x03;
}
static uint32_t sw(unsigned rs1, unsigned rs2) {
    return (rs2 << 20) | (rs1 << 15) | (2 << 12) | 0x23;
}
struct Commit { uint64_t pc; uint32_t insn; bool write; unsigned rd; uint64_t data; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_core dut;
    constexpr uint64_t base = 0x80000000, address = 0x40;
    const std::array<uint32_t, 6> program = {
        addi(1, 0, 64), addi(2, 0, 42), sw(1, 2), lw(3, 1), addi(4, 3, 1), 0x73};
    const std::array<Commit, 5> expected = {{{base, program[0], true, 1, address},
        {base+4, program[1], true, 2, 42}, {base+8, program[2], false, 0, 0},
        {base+12, program[3], true, 3, 42}, {base+16, program[4], true, 4, 43}}};
    bool imem_valid = false, dmem_response_valid = false, trapped = false;
    bool imem_fire = false, dmem_request_fire = false, dmem_response_fire = false;
    uint32_t imem_data = 0;
    uint64_t memory = 0;
    unsigned commits = 0, cycles = 0, dmem_requests = 0, dmem_responses = 0;

    auto check = [](bool ok, const char* why) { if (!ok) throw std::runtime_error(why); };
    auto eval_low = [&]() {
        dut.clk_i = 0; dut.rst_i = 0;
        dut.imem_req_ready_i = 1; dut.imem_rsp_valid_i = imem_valid; dut.imem_rsp_insn_i = imem_data;
        dut.dmem_req_ready_i = 1; dut.dmem_rsp_valid_i = dmem_response_valid; dut.dmem_rsp_data_i = memory;
        dut.eval();
        if (dut.imem_req_valid_o && !imem_valid) {
            uint64_t pc = dut.imem_req_addr_o;
            check(pc >= base && (pc-base)%4 == 0 && (pc-base)/4 < program.size(), "imem address");
            imem_data = program[(pc-base)/4]; imem_valid = true;
            dut.imem_rsp_valid_i = 1; dut.imem_rsp_insn_i = imem_data; dut.eval();
        }
        if (dut.commit_valid_o) {
            check(commits < expected.size(), "too many commits");
            auto x = expected[commits++];
            check(uint64_t(dut.commit_pc_o)==x.pc && uint32_t(dut.commit_insn_o)==x.insn &&
                  bool(dut.commit_rd_write_o)==x.write && unsigned(dut.commit_rd_o)==x.rd &&
                  uint64_t(dut.commit_rd_data_o)==x.data, "commit mismatch");
        }
        if (dut.trap_valid_o) { check(commits == expected.size(), "early trap"); trapped = true; }
        imem_fire = imem_valid && dut.imem_rsp_ready_o;
        dmem_request_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;
        dmem_response_fire = dmem_response_valid && dut.dmem_rsp_ready_o;
    };
    auto rise = [&](bool reset) {
        dut.rst_i = reset; dut.clk_i = 1; dut.eval(); ++cycles;
        if (imem_fire) imem_valid = false;
        if (dmem_request_fire) {
            ++dmem_requests;
            check(uint64_t(dut.dmem_req_addr_o)==address && unsigned(dut.dmem_req_size_o)==2, "dmem request");
            if (dut.dmem_req_store_o) memory = uint64_t(dut.dmem_req_store_data_o) & 0xffffffff;
            else dmem_response_valid = true;
        }
        if (dmem_response_fire) { ++dmem_responses; dmem_response_valid = false; }
    };
    try {
        dut.clk_i=0; dut.rst_i=1; dut.imem_req_ready_i=0; dut.imem_rsp_valid_i=0;
        dut.dmem_req_ready_i=0; dut.dmem_rsp_valid_i=0; dut.eval(); rise(true);
        for (; cycles < 80 && !trapped; ) { eval_low(); rise(false); }
        check(trapped && commits==expected.size() && memory==42, "LSU flow incomplete");
        check(dmem_requests==2 && dmem_responses==1, "dmem transaction counts");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"cycles\":" << cycles
                  << ",\"commits\":" << commits << ",\"dmem_requests\":" << dmem_requests << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "CORE_LSU_S0_MISMATCH cycle=" << cycles << " commits=" << commits
                  << " requests=" << dmem_requests << " responses=" << dmem_responses
                  << " imem_valid=" << imem_valid << " imem_req=" << bool(dut.imem_req_valid_o)
                  << " imem_addr=" << std::hex << uint64_t(dut.imem_req_addr_o) << std::dec
                  << " imem_rsp_ready=" << bool(dut.imem_rsp_ready_o)
                  << " dmem_req=" << bool(dut.dmem_req_valid_o)
                  << " dmem_rsp_ready=" << bool(dut.dmem_rsp_ready_o)
                  << " reason=" << error.what() << '\n';
        return 1;
    }
}
