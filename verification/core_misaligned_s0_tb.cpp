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

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_core dut;
    constexpr uint64_t base = 0x80000000ULL;
    unsigned cycles = 0, traps = 0, dmem_requests = 0;
    auto check = [](bool ok, const char* why) { if (!ok) throw std::runtime_error(why); };

    try {
        for (unsigned scenario = 0; scenario < 2; ++scenario) {
            const std::array<uint32_t, 2> program = {
                addi(1, 0, 65), scenario == 0 ? lw(2, 1) : sw(1, 2)};
            bool imem_valid = false, imem_fire = false, trapped = false;
            uint32_t imem_data = 0;
            dut.clk_i = 0; dut.rst_i = 1; dut.imem_req_ready_i = 0;
            dut.imem_rsp_valid_i = 0; dut.dmem_req_ready_i = 1;
            dut.dmem_rsp_valid_i = 0; dut.dmem_rsp_data_i = 0; dut.eval();
            dut.clk_i = 1; dut.eval(); ++cycles;

            for (unsigned limit = 0; limit < 30 && !trapped; ++limit) {
                dut.clk_i = 0; dut.rst_i = 0; dut.imem_req_ready_i = 1;
                dut.imem_rsp_valid_i = imem_valid; dut.imem_rsp_insn_i = imem_data; dut.eval();
                if (dut.imem_req_valid_o && !imem_valid) {
                    uint64_t pc = dut.imem_req_addr_o;
                    check(pc >= base && (pc-base)/4 < program.size(), "instruction address");
                    imem_data = program[(pc-base)/4]; imem_valid = true;
                    dut.imem_rsp_valid_i = 1; dut.imem_rsp_insn_i = imem_data; dut.eval();
                }
                if (dut.dmem_req_valid_o) ++dmem_requests;
                if (dut.trap_valid_o) {
                    check(uint64_t(dut.trap_pc_o) == base+4 && uint32_t(dut.trap_insn_o) == program[1],
                          "misaligned trap event");
                    trapped = true; ++traps;
                }
                imem_fire = imem_valid && dut.imem_rsp_ready_o;
                dut.clk_i = 1; dut.eval(); ++cycles;
                if (imem_fire) imem_valid = false;
                if (trapped) {
                    check(uint64_t(dut.csr_mepc_o) == base+4 &&
                          uint64_t(dut.csr_mcause_o) == (scenario == 0 ? 4 : 6) &&
                          uint64_t(dut.csr_mtval_o) == 65, "misaligned trap CSRs");
                }
            }
            check(trapped, "missing misaligned trap");
        }
        check(traps == 2 && dmem_requests == 0, "misaligned access reached dmem");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"cycles\":" << cycles
                  << ",\"traps\":" << traps << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "CORE_MISALIGNED_S0_MISMATCH cycle=" << cycles
                  << " traps=" << traps << " dmem_requests=" << dmem_requests
                  << " reason=" << error.what() << '\n';
        return 1;
    }
}
