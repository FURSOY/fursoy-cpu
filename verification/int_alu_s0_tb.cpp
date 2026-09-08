#include "Vfursoy_s0_int_alu.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

static uint32_t op_imm(unsigned funct3, unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x13;
}
static uint32_t op(unsigned funct7, unsigned funct3, unsigned rd, unsigned rs1, unsigned rs2) {
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33;
}
static uint32_t op_imm_32(unsigned funct7, unsigned funct3, unsigned rd, unsigned rs1, unsigned shamt_or_imm) {
    return (funct7 << 25) | ((shamt_or_imm & 31) << 20) | (rs1 << 15) |
           (funct3 << 12) | (rd << 7) | 0x1b;
}
static uint32_t addiw(unsigned rd, unsigned rs1, int imm) {
    return (uint32_t(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x1b;
}
static uint32_t op_32(unsigned funct7, unsigned funct3, unsigned rd, unsigned rs1, unsigned rs2) {
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x3b;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_int_alu dut;
    unsigned checks = 0;
    auto expect = [&](uint32_t instruction, uint64_t a, uint64_t b, uint64_t result, bool legal = true) {
        dut.insn_valid_i = 1; dut.pc_i = 0x80000040ULL; dut.insn_i = instruction;
        dut.rs1_i = a; dut.rs2_i = b; dut.eval(); ++checks;
        if (bool(dut.illegal_o) == legal || bool(dut.retire_valid_o) != legal ||
            (legal && (uint64_t(dut.retire_pc_o) != 0x80000040ULL ||
                       uint32_t(dut.retire_insn_o) != instruction || uint64_t(dut.rd_data_o) != result))) {
            throw std::runtime_error("ALU result or commit metadata");
        }
    };
    try {
        expect(0x123452b7, 0, 0, 0x0000000012345000ULL); // LUI x5,0x12345
        expect(0xfffff297, 0, 0, 0x000000007ffff040ULL); // AUIPC x5,-1
        expect(op_imm(0, 5, 1, -1), 3, 0, 2);
        expect(op_imm(2, 5, 1, -1), 0x8000000000000000ULL, 0, 1);
        expect(op_imm(3, 5, 1, -1), 0, 0, 1);
        expect(op_imm(4, 5, 1, 0x55), 0xaa, 0, 0xff);
        expect(op_imm(6, 5, 1, 0x55), 0xaa, 0, 0xff);
        expect(op_imm(7, 5, 1, 0x55), 0xff, 0, 0x55);
        expect(op_imm(1, 5, 1, 63), 1, 0, 0x8000000000000000ULL);
        expect(op_imm(5, 5, 1, 0x400 | 63), 0x8000000000000000ULL, 0, 0xffffffffffffffffULL);
        expect(op(0, 0, 5, 1, 2), 4, 9, 13);
        expect(op(0x20, 0, 5, 1, 2), 4, 9, 0xfffffffffffffffbULL);
        expect(op(0, 1, 5, 1, 2), 1, 63, 0x8000000000000000ULL);
        expect(op(0, 2, 5, 1, 2), 0xffffffffffffffffULL, 1, 1);
        expect(op(0, 3, 5, 1, 2), 0xffffffffffffffffULL, 1, 0);
        expect(op(0x20, 5, 5, 1, 2), 0x8000000000000000ULL, 63, 0xffffffffffffffffULL);
        expect(op(0, 6, 5, 1, 2), 0xf0, 0x0f, 0xff);
        expect(op(0, 7, 5, 1, 2), 0xff, 0x0f, 0x0f);
        expect(addiw(5, 1, 1), 0x7fffffff, 0, 0xffffffff80000000ULL);
        expect(addiw(5, 1, -1), 0, 0, 0xffffffffffffffffULL);
        expect(op_imm_32(0, 1, 5, 1, 31), 1, 0, 0xffffffff80000000ULL);
        expect(op_imm_32(0, 5, 5, 1, 31), 0x80000000, 0, 1);
        expect(op_imm_32(0x20, 5, 5, 1, 31), 0x80000000, 0, 0xffffffffffffffffULL);
        expect(op_32(0, 0, 5, 1, 2), 0x7fffffff, 1, 0xffffffff80000000ULL);
        expect(op_32(0x20, 0, 5, 1, 2), 0, 1, 0xffffffffffffffffULL);
        expect(op_32(0, 1, 5, 1, 2), 1, 31, 0xffffffff80000000ULL);
        expect(op_32(0, 5, 5, 1, 2), 0x80000000, 31, 1);
        expect(op_32(0x20, 5, 5, 1, 2), 0x80000000, 31, 0xffffffffffffffffULL);
        // RV64M instructions
        // funct7 = 1, OP (0x33)
        expect(op(1, 0, 5, 1, 2), 3, 7, 21); // MUL
        expect(op(1, 0, 5, 1, 2), 0xffffffffffffffffULL, 2, 0xfffffffffffffffeULL); // MUL with negative
        expect(op(1, 1, 5, 1, 2), 0x7fffffffffffffffULL, 2, 0); // MULH
        expect(op(1, 1, 5, 1, 2), 0x8000000000000000ULL, 0x8000000000000000ULL, 0x4000000000000000ULL); // MULH
        expect(op(1, 2, 5, 1, 2), 0xffffffffffffffffULL, 2, 0xffffffffffffffffULL); // MULHSU
        expect(op(1, 3, 5, 1, 2), 0xffffffffffffffffULL, 0xffffffffffffffffULL, 0xfffffffffffffffeULL); // MULHU
        // Division and remainder
        expect(op(1, 4, 5, 1, 2), 20, 3, 6); // DIV
        expect(op(1, 4, 5, 1, 2), -20, 3, -6); // DIV signed
        expect(op(1, 5, 5, 1, 2), 20, 3, 6); // DIVU
        expect(op(1, 5, 5, 1, 2), 0xffffffffffffffffULL, 2, 0x7fffffffffffffffULL); // DIVU
        expect(op(1, 6, 5, 1, 2), 20, 3, 2); // REM
        expect(op(1, 6, 5, 1, 2), -20, 3, -2); // REM signed
        expect(op(1, 7, 5, 1, 2), 20, 3, 2); // REMU
        expect(op(1, 7, 5, 1, 2), 0xffffffffffffffffULL, 3, 0); // REMU
        // Division by zero corner cases (RISC-V spec)
        expect(op(1, 4, 5, 1, 2), 12345, 0, 0xffffffffffffffffULL); // DIV by 0 -> -1
        expect(op(1, 5, 5, 1, 2), 12345, 0, 0xffffffffffffffffULL); // DIVU by 0 -> 2^64-1
        expect(op(1, 6, 5, 1, 2), 12345, 0, 12345); // REM by 0 -> rs1
        expect(op(1, 7, 5, 1, 2), 12345, 0, 12345); // REMU by 0 -> rs1
        // Overflow corner cases
        expect(op(1, 4, 5, 1, 2), 0x8000000000000000ULL, 0xffffffffffffffffULL, 0x8000000000000000ULL); // DIV overflow
        expect(op(1, 6, 5, 1, 2), 0x8000000000000000ULL, 0xffffffffffffffffULL, 0); // REM overflow
        // 32-bit M instructions (OP-32: 0x3b)
        expect(op_32(1, 0, 5, 1, 2), 0x100000002ULL, 3, 6); // MULW
        expect(op_32(1, 4, 5, 1, 2), 20, 3, 6); // DIVW
        expect(op_32(1, 5, 5, 1, 2), 0x80000000ULL, 2, 0x40000000ULL); // DIVUW
        expect(op_32(1, 6, 5, 1, 2), 20, 3, 2); // REMW
        expect(op_32(1, 7, 5, 1, 2), 20, 3, 2); // REMUW
        expect(op_32(1, 4, 5, 1, 2), 12345, 0, 0xffffffffffffffffULL); // DIVW by 0 -> -1 (sign-extended)
        expect(op_32(1, 6, 5, 1, 2), 12345, 0, 12345); // REMW by 0 -> rs1
        expect(op_32(1, 4, 5, 1, 2), 0x80000000ULL, 0xffffffffffffffffULL, 0xffffffff80000000ULL); // DIVW overflow
        expect(op_32(1, 6, 5, 1, 2), 0x80000000ULL, 0xffffffffffffffffULL, 0); // REMW overflow

        expect(op_imm_32(1, 1, 5, 1, 0), 1, 0, 0, false); // reserved SLLIW encoding
        expect(0xffffffff, 0, 0, 0, false);
        dut.insn_valid_i = 0; dut.insn_i = 0xffffffff; dut.eval(); ++checks;
        if (dut.illegal_o || dut.retire_valid_o || dut.rd_write_o || dut.rd_o || dut.rd_data_o)
            throw std::runtime_error("invalid input must have no architectural effect");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"checks\":" << checks << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "INT_ALU_S0_MISMATCH check=" << checks << " reason=" << error.what() << '\n';
        return 1;
    }
}
