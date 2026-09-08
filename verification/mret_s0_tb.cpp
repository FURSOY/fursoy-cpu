#include "Vfursoy_s0_core.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_core dut;
    constexpr uint64_t kBase = 0x80000000ULL, kVector = 0x80000020ULL;
    bool pending = false, trapped = false, returned = false, response_fire = false;
    uint32_t response = 0;
    unsigned cycles = 0;
    auto check = [](bool ok, const char* what) { if (!ok) throw std::runtime_error(what); };
    auto instruction_at = [&](uint64_t address) {
        if (address == kBase) return uint32_t(0x00000073);      // ECALL
        if (address == kVector) return uint32_t(0x30200073);    // MRET
        throw std::runtime_error("unexpected instruction fetch");
    };
    auto half = [&](bool rising, bool reset) {
        dut.clk_i = rising; dut.rst_i = reset; dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = pending; dut.imem_rsp_insn_i = response; dut.eval();
        if (!rising && dut.imem_req_valid_o && dut.imem_req_ready_i) {
            response = instruction_at(uint64_t(dut.imem_req_addr_o)); pending = true;
        }
        if (!rising) response_fire = pending && dut.imem_rsp_valid_i && dut.imem_rsp_ready_o;
        if (!rising && dut.trap_valid_o) {
            check(!trapped && uint64_t(dut.trap_pc_o) == kBase && uint32_t(dut.trap_insn_o) == 0x73,
                  "ECALL trap event");
            trapped = true;
        }
        if (!rising && dut.commit_valid_o) {
            check(trapped && !returned && uint64_t(dut.commit_pc_o) == kVector &&
                  uint32_t(dut.commit_insn_o) == 0x30200073 && !dut.commit_rd_write_o,
                  "MRET commit trace");
            returned = true;
        }
        if (rising && response_fire) pending = false;
        if (rising && trapped && !returned) {
            check(uint64_t(dut.csr_mepc_o) == kBase && uint64_t(dut.csr_mcause_o) == 11 &&
                  uint64_t(dut.csr_mstatus_o) == 0x0000000a00001800ULL, "trap CSR state before MRET");
        }
        if (rising && returned) {
            check(uint64_t(dut.csr_mstatus_o) == 0x0000000a00000080ULL, "MRET mstatus update");
        }
    };
    try {
        half(false, true); half(true, true); ++cycles;
        check(uint64_t(dut.csr_mtvec_o) == kVector, "test trap vector reset parameter");
        for (; cycles < 50 && !returned; ++cycles) { half(false, false); half(true, false); }
        check(trapped && returned, "ECALL to MRET flow");
        dut.clk_i = 0; dut.rst_i = 0; dut.imem_req_ready_i = 0; dut.imem_rsp_valid_i = 0; dut.eval();
        check(dut.imem_req_valid_o && uint64_t(dut.imem_req_addr_o) == kBase,
              "MRET must restart fetch at mepc");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"cycles\":" << cycles << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "MRET_S0_MISMATCH cycle=" << cycles << " reason=" << error.what() << '\n';
        return 1;
    }
}
