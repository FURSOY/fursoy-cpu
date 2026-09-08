#include "Vfursoy_s0_core.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>

static uint32_t addi(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x13;
}
static uint32_t beq(unsigned rs1, unsigned rs2, int offset) {
    uint32_t u = uint32_t(offset);
    return ((u >> 12 & 1) << 31) | ((u >> 5 & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) |
           ((u >> 1 & 0xf) << 8) | ((u >> 11 & 1) << 7) | 0x63;
}
static uint32_t jal(unsigned rd, int offset) {
    uint32_t u = uint32_t(offset);
    return ((u >> 20 & 1) << 31) | ((u >> 1 & 0x3ff) << 21) | ((u >> 11 & 1) << 20) |
           ((u >> 12 & 0xff) << 12) | (rd << 7) | 0x6f;
}
struct Commit { uint64_t pc; uint32_t insn; bool write; unsigned rd; uint64_t data; };

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_core dut;
    const std::array<uint32_t, 7> program = {
        addi(1, 0, 5), beq(1, 1, 8), addi(2, 0, 99), jal(3, 8),
        addi(4, 0, 99), addi(5, 3, -9), 0x00100073};
    const std::array<Commit, 4> expected = {{
        {0x80000000ULL, program[0], true, 1, 5}, {0x80000004ULL, program[1], false, 0, 0},
        {0x8000000cULL, program[3], true, 3, 0x80000010ULL}, {0x80000014ULL, program[5], true, 5, 0x80000007ULL}}};
    bool response_pending = false;
    bool response_fire = false;
    uint32_t response_insn = 0;
    unsigned commits = 0, cycles = 0;
    bool trapped = false;
    bool check_trap_csrs = false;
    auto check = [](bool ok, const char* what) { if (!ok) throw std::runtime_error(what); };
    auto half = [&](bool rising, bool reset) {
        dut.clk_i = rising;
        dut.rst_i = reset;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = response_pending;
        dut.imem_rsp_insn_i = response_insn;
        dut.eval();
        if (!rising && dut.imem_req_valid_o && dut.imem_req_ready_i) {
            const uint64_t address = dut.imem_req_addr_o;
            check(address >= 0x80000000ULL && ((address - 0x80000000ULL) % 4 == 0), "invalid fetch address");
            const unsigned word = unsigned((address - 0x80000000ULL) / 4);
            check(word < program.size(), "unexpected fetch after program");
            response_insn = program[word]; response_pending = true;
        }
        if (!rising) response_fire = response_pending && dut.imem_rsp_ready_o && dut.imem_rsp_valid_i;
        if (!rising && dut.commit_valid_o) {
            check(commits < expected.size(), "too many commits");
            const auto& item = expected[commits++];
            const bool matches = uint64_t(dut.commit_pc_o) == item.pc && uint32_t(dut.commit_insn_o) == item.insn &&
                                 bool(dut.commit_rd_write_o) == item.write && unsigned(dut.commit_rd_o) == item.rd &&
                                 uint64_t(dut.commit_rd_data_o) == item.data;
            if (!matches) {
                std::cerr << " expected_pc=" << std::hex << item.pc << " actual_pc=" << uint64_t(dut.commit_pc_o)
                          << " expected_data=" << item.data << " actual_data=" << uint64_t(dut.commit_rd_data_o) << std::dec;
            }
            check(matches, "commit trace mismatch");
        }
        if (!rising && dut.trap_valid_o) {
            check(!trapped && uint64_t(dut.trap_pc_o) == 0x80000018ULL &&
                  uint32_t(dut.trap_insn_o) == 0x00100073, "EBREAK trap event");
            trapped = true; check_trap_csrs = true;
        }
        if (rising && response_fire) response_pending = false;
        if (rising && check_trap_csrs) {
            check(uint64_t(dut.csr_mstatus_o) == 0x0000000a00001800ULL && uint64_t(dut.csr_mie_o) == 0 &&
                  uint64_t(dut.csr_mtvec_o) == 0 && uint64_t(dut.csr_mepc_o) == 0x80000018ULL &&
                  uint64_t(dut.csr_mcause_o) == 3 && uint64_t(dut.csr_mtval_o) == 0,
                  "M-mode EBREAK trap CSRs");
            check_trap_csrs = false;
        }
    };
    try {
        half(false, true); half(true, true); ++cycles;
        check(uint64_t(dut.csr_mstatus_o) == 0x0000000a00001800ULL && uint64_t(dut.csr_mie_o) == 0 &&
              uint64_t(dut.csr_mtvec_o) == 0 && uint64_t(dut.csr_mepc_o) == 0 &&
              uint64_t(dut.csr_mcause_o) == 0 && uint64_t(dut.csr_mtval_o) == 0,
              "Slice-0 reset CSR state");
        for (; cycles < 80 && !trapped; ++cycles) { half(false, false); half(true, false); }
        check(commits == expected.size(), "program commit count");
        check(trapped, "EBREAK must enter trap boundary");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"cycles\":" << cycles << ",\"commits\":" << commits << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "CORE_S0_MISMATCH cycle=" << cycles << " reason=" << error.what() << '\n';
        return 1;
    }
}
