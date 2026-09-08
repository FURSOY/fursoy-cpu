#include "Vfursoy_s0_fetch.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vfursoy_s0_fetch dut;
    uint64_t cycles = 0;
    auto check = [](bool ok, const char* message) {
        if (!ok) throw std::runtime_error(message);
    };
    auto step = [&](bool reset, bool req_ready, bool rsp_valid, uint32_t instruction, bool error = false) {
        dut.clk_i = 0;
        dut.rst_i = reset;
        dut.fetch_enable_i = 1;
        dut.redirect_i = 0;
        dut.fetch_pc_i = 0x80000000ULL;
        dut.imem_req_ready_i = req_ready;
        dut.imem_rsp_valid_i = rsp_valid;
        dut.imem_rsp_insn_i = instruction;
        dut.imem_rsp_error_i = error;
        dut.fetched_ready_i = 0;
        dut.eval();
        dut.clk_i = 1;
        dut.eval();
        ++cycles;
    };
    try {
        step(true, true, true, 0xffffffff);
        dut.clk_i = 0; dut.rst_i = 1; dut.eval();
        check(!dut.imem_req_valid_o && !dut.imem_rsp_ready_o && !dut.fetched_valid_o,
              "reset must suppress transactions and fetched result");

        dut.clk_i = 0; dut.rst_i = 0; dut.fetch_enable_i = 0; dut.redirect_i = 0;
        dut.fetch_pc_i = 0x80000000ULL; dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = 0; dut.eval();
        check(!dut.imem_req_valid_o, "disabled fetch must not issue a request");
        dut.clk_i = 1; dut.eval(); ++cycles;
        dut.clk_i = 0; dut.fetch_enable_i = 1; dut.redirect_i = 0; dut.eval();
        check(dut.imem_req_valid_o && !dut.imem_rsp_ready_o,
              "ready without valid must not advance the request state");

        dut.rst_i = 0; dut.fetch_enable_i = 1; dut.redirect_i = 0; dut.fetch_pc_i = 0x80000000ULL; dut.imem_req_ready_i = 0; dut.imem_rsp_valid_i = 0; dut.eval();
        check(dut.imem_req_valid_o && dut.imem_req_addr_o == 0x80000000ULL,
              "first request must use Slice-0 reset PC");
        step(false, false, false, 0);
        dut.clk_i = 0; dut.fetch_enable_i = 1; dut.redirect_i = 0; dut.fetch_pc_i = 0x80000000ULL; dut.eval();
        check(dut.imem_req_valid_o && !dut.imem_rsp_ready_o && !dut.fetched_valid_o,
              "request must persist under backpressure");
        step(false, true, false, 0);
        dut.clk_i = 0; dut.fetch_enable_i = 1; dut.redirect_i = 0; dut.fetch_pc_i = 0x80000000ULL; dut.eval();
        check(!dut.imem_req_valid_o && dut.imem_rsp_ready_o && !dut.fetched_valid_o,
              "response must wait after accepted request");
        step(false, false, true, 0x00000013);
        dut.clk_i = 0; dut.fetch_enable_i = 1; dut.redirect_i = 0; dut.fetch_pc_i = 0x80000000ULL; dut.eval();
        check(dut.fetched_valid_o && dut.fetched_pc_o == 0x80000000ULL &&
              dut.fetched_insn_o == 0x00000013, "response must be retained exactly");
        check(!dut.imem_req_valid_o && !dut.imem_rsp_ready_o, "single request must complete cleanly");

        step(true, false, false, 0);
        step(false, true, false, 0);
        step(false, false, true, 0xffffffff, true);
        dut.clk_i=0; dut.rst_i=0; dut.imem_rsp_valid_i=0; dut.imem_rsp_error_i=0; dut.eval();
        check(dut.fetched_valid_o && dut.fetched_error_o &&
              uint64_t(dut.fetched_pc_o)==0x80000000ULL,
              "error response must retain the faulting request PC");

        // A pre-reset request's late response is invalidated by the producer on
        // reset, as required by the transaction contract.
        step(true, false, true, 0x00100313);
        dut.clk_i=0; dut.rst_i=1; dut.imem_rsp_valid_i=1; dut.imem_rsp_error_i=0; dut.eval();
        check(!dut.imem_rsp_ready_o&&!dut.fetched_valid_o,"late pre-reset response was not ignored");
        step(false, true, false, 0);
        step(false, false, true, 0x00200293);
        dut.clk_i=0; dut.rst_i=0; dut.imem_rsp_valid_i=0; dut.eval();
        check(dut.fetched_valid_o&&!dut.fetched_error_o&&dut.fetched_insn_o==0x00200293,
              "late pre-reset response was misattributed to new fetch");

        step(true, false, false, 0);
        dut.clk_i = 0; dut.rst_i = 0; dut.fetch_enable_i = 1; dut.redirect_i = 0; dut.fetch_pc_i = 0x80000000ULL; dut.eval();
        check(dut.imem_req_valid_o && !dut.fetched_valid_o,
              "reset during/after a transaction must restart at reset vector");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"cycles\":" << cycles << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FETCH_S0_MISMATCH cycle=" << cycles << " check=" << error.what() << '\n';
        return 1;
    }
}
