#include "Vfursoy_fifo.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <random>
#include <stdexcept>

#ifndef FIFO_DEPTH
#error FIFO_DEPTH required
#endif
#ifndef FIFO_WIDTH
#error FIFO_WIDTH required
#endif

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const uint32_t seed = argc > 1 ? std::stoul(argv[1]) : 1;
    const uint32_t mask = uint32_t((uint64_t(1) << FIFO_WIDTH) - 1);
    std::mt19937 rng(seed);
    Vfursoy_fifo dut;
    std::deque<uint32_t> reference;
    uint64_t cycles = 0, pushes = 0, pops = 0, full_exchange = 0;
    uint64_t stalled = 0, empty_read = 0, flushed = 0, reset_live = 0;
    auto check = [&](bool condition, const char* what) {
        if (!condition) {
            std::cerr << "FIFO_MISMATCH seed=" << seed << " cycle=" << cycles
                      << " depth=" << FIFO_DEPTH << " width=" << FIFO_WIDTH
                      << " occupancy=" << reference.size() << " check=" << what << '\n';
            throw std::runtime_error(what);
        }
    };
    auto step = [&](bool valid, uint32_t data, bool ready, bool flush, bool reset) {
        dut.clk_i = 0;
        dut.rst_i = reset;
        dut.flush_i = flush;
        dut.in_valid_i = valid;
        dut.in_data_i = data & mask;
        dut.out_ready_i = ready;
        dut.eval();
        const bool active = !reset && !flush;
        const bool expected_valid = active && !reference.empty();
        const bool expected_ready = active && (reference.size() < FIFO_DEPTH || ready);
        check(bool(dut.out_valid_o) == expected_valid, "out_valid");
        check(bool(dut.in_ready_o) == expected_ready, "in_ready");
        check(uint32_t(dut.out_data_o) == (expected_valid ? reference.front() : 0), "data");
        const bool take_in = valid && expected_ready;
        const bool take_out = ready && expected_valid;
        if (active && valid && !expected_ready) ++stalled;
        if (active && ready && reference.empty()) ++empty_read;
        if (take_in && take_out && reference.size() == FIFO_DEPTH) ++full_exchange;
        if (flush && !reset && !reference.empty()) ++flushed;
        if (reset && !reference.empty()) ++reset_live;
        if (!active) reference.clear();
        else {
            if (take_out) { reference.pop_front(); ++pops; }
            if (take_in) { reference.push_back(data & mask); ++pushes; }
        }
        dut.clk_i = 1;
        dut.eval();
        ++cycles;
        return take_in;
    };
    try {
        step(true, 99, true, true, true);
        step(false, 0, true, false, false);
        for (int i = 0; i < FIFO_DEPTH; ++i) step(true, i + 1, false, false, false);
        for (int i = 0; i < 4; ++i) step(true, 123, false, false, false);
        step(true, 123, true, false, false);
        for (int i = 0; i < FIFO_DEPTH * 4; ++i) step(true, i + 17, true, false, false);
        step(true, 77, true, true, false);
        step(true, 88, false, false, false);
        step(true, 99, true, false, true);
        bool pending = false;
        uint32_t pending_data = 0;
        for (int i = 0; i < 20000; ++i) {
            if (!pending && rng() % 4 != 0) { pending = true; pending_data = rng(); }
            const bool reset = rng() % 997 == 0;
            const bool flush = rng() % 127 == 0;
            const bool accepted = step(pending, pending_data, rng() % 3 != 0, flush, reset);
            if (accepted || reset || flush) pending = false;
        }
        if (pending) step(true, pending_data, true, false, false);
        while (!reference.empty()) step(false, 0, true, false, false);
        step(false, 0, true, false, false);
        check(pushes > FIFO_DEPTH * 10 && pops > FIFO_DEPTH * 10, "wrap coverage");
        check(full_exchange && stalled && empty_read && flushed && reset_live, "scenario coverage");
        dut.final();
        std::cout << "{\"status\":\"pass\",\"seed\":" << seed << ",\"cycles\":" << cycles
                  << ",\"pushes\":" << pushes << ",\"pops\":" << pops
                  << ",\"full_exchange\":" << full_exchange << ",\"stalled\":" << stalled
                  << ",\"empty_read\":" << empty_read << ",\"flushed\":" << flushed
                  << ",\"reset_live\":" << reset_live << "}\n";
        return 0;
    } catch (const std::exception&) { return 1; }
}
