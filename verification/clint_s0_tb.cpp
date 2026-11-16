#include "Vfursoy_s0_clint.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

static constexpr uint64_t BASE = 0x02000000ULL;
static constexpr uint64_t MSIP = BASE;
static constexpr uint64_t MTIMECMP = BASE + 0x4000;
static constexpr uint64_t MTIME = BASE + 0xbff8;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_clint dut;
    unsigned cycles = 0;
    auto check = [](bool value, const char* message) { if (!value) throw std::runtime_error(message); };
    auto step = [&](bool reset, bool valid, bool store, uint64_t addr, unsigned size, uint64_t data, bool rsp_ready) {
        dut.clk_i = 0; dut.rst_i = reset; dut.req_valid_i = valid; dut.req_store_i = store;
        dut.req_addr_i = addr; dut.req_size_i = size; dut.req_store_data_i = data; dut.rsp_ready_i = rsp_ready;
        dut.eval();
        bool accepted = dut.req_ready_o && valid;
        bool access_error = dut.access_error_o;
        dut.clk_i = 1; dut.eval(); ++cycles;
        return std::pair<bool, bool>{accepted, access_error};
    };
    try {
        step(true, false, false, 0, 0, 0, false);
        step(true, false, false, 0, 0, 0, false);
        dut.clk_i = 0; dut.rst_i = 0; dut.req_valid_i = 0; dut.rsp_ready_i = 0; dut.eval();
        check(!dut.irq_software_o && !dut.irq_timer_o, "reset interrupt state");

        auto set_msip = step(false, true, true, MSIP, 2, 1, true);
        check(set_msip.first && !set_msip.second, "aligned MSIP store accepted");
        dut.clk_i = 0; dut.eval();
        check(dut.rsp_valid_o && !dut.rsp_error_o, "CLINT store asserts rsp_valid_o cleanly");
        check(dut.irq_software_o, "MSIP set must assert level interrupt");
        step(false, false, false, 0, 0, 0, true);
        step(false, true, true, MSIP, 2, 0, true);
        dut.clk_i = 0; dut.eval();
        check(dut.rsp_valid_o && !dut.rsp_error_o, "CLINT clear store asserts rsp_valid_o cleanly");
        check(!dut.irq_software_o, "MSIP clear must deassert level interrupt");
        step(false, false, false, 0, 0, 0, true);

        auto bad_msip = step(false, true, true, MSIP, 3, 1, true);
        check(bad_msip.first && bad_msip.second && !dut.irq_software_o, "MSIP rejects non-word store");
        dut.clk_i = 0; dut.eval();
        check(dut.rsp_valid_o && dut.rsp_error_o, "rejected CLINT store reports rsp_error_o");
        step(false, false, false, 0, 0, 0, true);
        auto bad_align = step(false, true, true, MSIP + 2, 2, 1, true);
        check(bad_align.first && bad_align.second, "CLINT rejects unaligned address");
        dut.clk_i = 0; dut.eval();
        check(dut.rsp_valid_o && dut.rsp_error_o, "unaligned CLINT store reports rsp_error_o");
        step(false, false, false, 0, 0, 0, true);

        step(false, true, true, MTIME, 3, 10, true);
        step(false, false, false, 0, 0, 0, true);
        step(false, true, true, MTIMECMP, 3, 13, true);
        dut.clk_i = 0; dut.eval(); check(!dut.irq_timer_o, "timer remains low before threshold");
        step(false, false, false, 0, 0, 0, true);
        dut.clk_i = 0; dut.eval(); check(dut.irq_timer_o, "timer asserts at mtime >= mtimecmp");
        step(false, true, true, MTIMECMP, 3, 100, true);
        dut.clk_i = 0; dut.eval(); check(!dut.irq_timer_o, "timer clear follows raised compare");
        step(false, false, false, 0, 0, 0, true);

        step(false, true, false, MTIME, 3, 0, false);
        dut.clk_i = 0; dut.eval(); check(dut.rsp_valid_o && !dut.rsp_error_o && dut.rsp_data_o >= 10 && dut.rsp_data_o < 100, "64-bit mtime load response");
        step(false, false, false, 0, 0, 0, true);
        step(false, true, false, MTIME, 2, 0, false);
        dut.clk_i = 0; dut.eval(); check(dut.rsp_valid_o && dut.rsp_error_o, "mtime rejects narrow load");
        step(false, false, false, 0, 0, 0, true);
        dut.final();
        std::cout << "{\"status\":\"pass\",\"checks\":10,\"cycles\":" << cycles << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "CLINT_S0_MISMATCH cycle=" << cycles << " reason=" << error.what() << '\n';
        return 1;
    }
}
