#include "Vfursoy_s0_core.h"
#include "verilated.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>

static void check(bool ok, const char* msg) {
    if (!ok) throw std::runtime_error(msg);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    constexpr uint64_t B = 0x80000000ULL;

    try {
        // ====================================================================
        // Scenario 1: Normal committed FENCE and FENCE.I
        // ====================================================================
        unsigned s1_commits = 0;
        unsigned s1_fi = 0;
        {
            Vfursoy_s0_core d;
            std::array<uint32_t, 3> p = {0x0ff0000f, 0x0000100f, 0x00100073};
            bool iv = false, fire = false, tr = false;
            uint32_t id = 0;
            unsigned cy = 0;

            d.clk_i = 0; d.rst_i = 1;
            d.imem_req_ready_i = 0; d.imem_rsp_valid_i = 0;
            d.dmem_req_ready_i = 0; d.dmem_rsp_valid_i = 0; d.dmem_rsp_data_i = 0;
            d.irq_software_i = 0; d.irq_timer_i = 0; d.irq_external_i = 0;
            d.eval(); d.clk_i = 1; d.eval(); ++cy;

            for (; cy < 30 && !tr;) {
                d.clk_i = 0; d.rst_i = 0;
                d.imem_req_ready_i = 1; d.imem_rsp_valid_i = iv; d.imem_rsp_insn_i = id;
                d.eval();
                if (d.imem_req_valid_o && !iv) {
                    auto x = (uint64_t(d.imem_req_addr_o) - B) / 4;
                    check(x < p.size(), "imem out of bounds");
                    id = p[x]; iv = true;
                    d.imem_rsp_valid_i = 1; d.imem_rsp_insn_i = id; d.eval();
                }
                if (d.commit_valid_o) {
                    check(s1_commits < 2 && uint64_t(d.commit_pc_o) == B + 4 * s1_commits &&
                          uint32_t(d.commit_insn_o) == p[s1_commits] && !d.commit_rd_write_o,
                          "fence commit mismatch");
                    ++s1_commits;
                }
                if (d.fence_i_valid_o) {
                    check(s1_commits == 2, "fence.i event ordering");
                    ++s1_fi;
                }
                if (d.trap_valid_o) {
                    check(s1_commits == 2 && uint64_t(d.trap_pc_o) == B + 8, "ebreak trap");
                    tr = true;
                }
                fire = iv && d.imem_rsp_ready_o;
                d.clk_i = 1; d.eval(); ++cy;
                if (fire) iv = false;
            }
            check(tr && s1_commits == 2 && s1_fi == 1, "Scenario 1 normal flow incomplete");
            d.final();
        }

        // ====================================================================
        // Scenario 2: Preempted FENCE.I does NOT emit spurious fence_i_valid_o
        // ====================================================================
        unsigned s2_fi_preempted_spurious = 0;
        unsigned s2_fi_committed = 0;
        {
            Vfursoy_s0_core d;
            std::unordered_map<uint64_t, uint32_t> mem;
            // Setup mtvec = B + 0x100, mie.MTIE=1, mstatus.MIE=1
            // 0x80000000: auipc x2, 0
            mem[B + 0x00] = 0x00000117;
            // 0x80000004: addi x2, x2, 0x100
            mem[B + 0x04] = 0x10010113;
            // 0x80000008: csrrw x0, x2, 0x305 (mtvec = B + 0x100)
            mem[B + 0x08] = 0x30511073;
            // 0x8000000c: addi x1, x0, 0x80
            mem[B + 0x0c] = 0x08000093;
            // 0x80000010: csrrw x0, x1, 0x304 (mie.MTIE = 1)
            mem[B + 0x10] = 0x30409073;
            // 0x80000014: csrrsi x0, 8, 0x300 (mstatus.MIE = 1)
            mem[B + 0x14] = 0x30046073;
            // 0x80000018: FENCE.I
            mem[B + 0x18] = 0x0000100f;
            // 0x8000001c: ebreak
            mem[B + 0x1c] = 0x00100073;

            // Trap vector mtvec = 0x80000100:
            // Clear MTIP in testbench and mret:
            mem[B + 0x100] = 0x30200073; // mret

            bool iv = false, fire = false, done = false;
            uint32_t id = 0;
            unsigned cy = 0;
            bool timer_injected = false;
            bool saw_preempt_trap = false;

            d.clk_i = 0; d.rst_i = 1;
            d.imem_req_ready_i = 0; d.imem_rsp_valid_i = 0;
            d.dmem_req_ready_i = 0; d.dmem_rsp_valid_i = 0; d.dmem_rsp_data_i = 0;
            d.irq_software_i = 0; d.irq_timer_i = 0; d.irq_external_i = 0;
            d.eval(); d.clk_i = 1; d.eval(); ++cy;

            for (; cy < 80 && !done;) {
                d.clk_i = 0; d.rst_i = 0;
                d.imem_req_ready_i = 1; d.imem_rsp_valid_i = iv; d.imem_rsp_insn_i = id;
                d.eval();

                if (d.imem_req_valid_o && !iv) {
                    uint64_t addr = d.imem_req_addr_o;
                    check(mem.count(addr) > 0, "unmapped imem address in Scenario 2");
                    id = mem[addr];
                    iv = true;
                    d.imem_rsp_valid_i = 1; d.imem_rsp_insn_i = id;
                    d.eval();

                    // When FENCE.I at B + 0x18 is requested/supplied, inject timer interrupt!
                    if (addr == B + 0x18 && !timer_injected) {
                        d.irq_timer_i = 1;
                        timer_injected = true;
                    }
                }

                // Check trap
                if (d.trap_valid_o) {
                    if (uint64_t(d.trap_pc_o) == B + 0x18) {
                        // Preempted FENCE.I!
                        saw_preempt_trap = true;
                        // Prove NO spurious fence_i_valid_o!
                        check(!d.fence_i_valid_o, "Spurious fence_i_valid_o on preempted FENCE.I!");
                        check(!d.commit_valid_o, "No commit allowed on preempted trap cycle");
                        // Clear interrupt so handler mret returns to FENCE.I cleanly
                        d.irq_timer_i = 0;
                    } else if (uint64_t(d.trap_pc_o) == B + 0x1c) {
                        // Final ebreak
                        done = true;
                    }
                }

                if (d.fence_i_valid_o) {
                    if (!d.commit_valid_o) {
                        ++s2_fi_preempted_spurious;
                    } else {
                        ++s2_fi_committed;
                    }
                }

                fire = iv && d.imem_rsp_ready_o;
                d.clk_i = 1; d.eval(); ++cy;
                if (fire) iv = false;
            }

            check(saw_preempt_trap, "Scenario 2: Preemption trap on FENCE.I was not observed");
            check(s2_fi_preempted_spurious == 0, "Scenario 2: Spurious FENCE.I events observed");
            check(s2_fi_committed == 1, "Scenario 2: FENCE.I must commit exactly once after interrupt return");
            d.final();
        }

        std::cout << "{\"status\":\"pass\",\"commits\":" << s1_commits
                  << ",\"fence_i_events\":" << s1_fi
                  << ",\"preempted_spurious_events\":" << s2_fi_preempted_spurious
                  << ",\"resumed_fence_i_events\":" << s2_fi_committed << "}\n";
        return 0;
    } catch (const std::exception& x) {
        std::cerr << "CORE_FENCE_S0_MISMATCH reason=" << x.what() << '\n';
        return 1;
    }
}

