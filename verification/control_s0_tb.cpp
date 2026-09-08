#include "Vfursoy_s0_control.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

static uint32_t branch(unsigned f3, unsigned rs1, unsigned rs2, int offset) {
    uint32_t u = uint32_t(offset);
    return ((u >> 12 & 1) << 31) | ((u >> 5 & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) |
           (f3 << 12) | ((u >> 1 & 0xf) << 8) | ((u >> 11 & 1) << 7) | 0x63;
}
static uint32_t jal(unsigned rd, int offset) {
    uint32_t u = uint32_t(offset);
    return ((u >> 20 & 1) << 31) | ((u >> 1 & 0x3ff) << 21) | ((u >> 11 & 1) << 20) |
           ((u >> 12 & 0xff) << 12) | (rd << 7) | 0x6f;
}
static uint32_t jalr(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x67;
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_control dut;
    unsigned checks = 0;
    auto expect = [&](uint32_t insn, uint64_t a, uint64_t b, bool valid, bool write, unsigned rd, uint64_t link, uint64_t target, bool misaligned) {
        dut.insn_valid_i = 1; dut.pc_i = 0x80000040ULL; dut.insn_i = insn; dut.rs1_i = a; dut.rs2_i = b; dut.eval(); ++checks;
        if (bool(dut.control_valid_o) != valid || bool(dut.rd_write_o) != write || unsigned(dut.rd_o) != rd ||
            uint64_t(dut.rd_data_o) != link || uint64_t(dut.target_pc_o) != target || bool(dut.target_misaligned_o) != misaligned)
            throw std::runtime_error("control decode/target");
    };
    try {
        expect(branch(0, 1, 2, 8), 7, 7, true, false, 0, 0, 0x80000048ULL, false);
        expect(branch(0, 1, 2, 8), 7, 8, true, false, 0, 0, 0x80000044ULL, false);
        expect(branch(4, 1, 2, -8), 0xffffffffffffffffULL, 1, true, false, 0, 0, 0x80000038ULL, false);
        expect(branch(6, 1, 2, 8), 0xffffffffffffffffULL, 1, true, false, 0, 0, 0x80000044ULL, false);
        expect(jal(5, -16), 0, 0, true, true, 5, 0x80000044ULL, 0x80000030ULL, false);
        expect(jalr(6, 1, 3), 0x80000049ULL, 0, true, true, 6, 0x80000044ULL, 0x8000004cULL, false);
        expect(jalr(0, 1, 2), 0x80000041ULL, 0, true, false, 0, 0, 0x80000042ULL, true);
        expect(0xffffffff, 0, 0, false, false, 0, 0, 0, false);
        dut.insn_valid_i = 0; dut.insn_i = jal(1, 8); dut.eval(); ++checks;
        if (dut.control_valid_o || dut.rd_write_o || dut.target_pc_o) throw std::runtime_error("invalid gate");
        dut.final(); std::cout << "{\"status\":\"pass\",\"checks\":" << checks << "}\n"; return 0;
    } catch (const std::exception& error) {
        std::cerr << "CONTROL_S0_MISMATCH check=" << checks << " reason=" << error.what() << '\n'; return 1;
    }
}
