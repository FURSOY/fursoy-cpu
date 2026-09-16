// Focused TLB Architectural Verification Suite for Fursoy Slice-0
// Normative Baselines: docs/architecture/sv39-tlb-v1.md (Frozen)

#include "Vfursoy_s0_mmu.h"
#include "Vfursoy_s0_mmu___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

static void check(bool cond, const char* msg) {
    if (!cond) throw std::runtime_error(msg);
}

struct Response {
    uint64_t data = 0;
    bool error = false;
};

struct Snap {
    bool vi_req_fire, vi_rsp_valid, vi_rsp_error, vi_rsp_page;
    uint32_t vi_insn;
    bool vd_req_fire, vd_req_error, vd_req_page;
    bool vd_rsp_valid, vd_rsp_error, vd_rsp_page;
    uint64_t vd_data;
    bool pd_req_fire, pd_store, pd_ptw, pd_req_error;
    uint64_t pd_addr, pd_store_data;
    bool pi_req_fire;
    uint64_t pi_addr;
    bool itlb_hit, itlb_miss, itlb_refill;
    bool dtlb_hit, dtlb_miss, dtlb_refill;
};

struct Sim {
    Vfursoy_s0_mmu d;
    std::unordered_map<uint64_t, Response> pte;
    std::unordered_map<uint64_t, Response> data;
    std::unordered_map<uint64_t, Response> insn;
    bool pd_pending = false, pi_pending = false;
    Response pd_response{}, pi_response{};
    bool pd_ready = true, pi_ready = true, final_store_error = false;
    unsigned ptw_requests = 0, final_data_requests = 0, physical_stores = 0, final_i_requests = 0;
    unsigned itlb_hits = 0, itlb_misses = 0, itlb_refills = 0;
    unsigned dtlb_hits = 0, dtlb_misses = 0, dtlb_refills = 0;
    uint64_t last_final_pa = 0, last_ptw_pa = 0;

    void defaults() {
        d.clk_i = 0; d.rst_i = 0; d.redirect_i = 0; d.priv_mode_i = 1; d.mstatus_i = 0;
        d.satp_i = 0; d.vi_req_valid_i = 0; d.vi_req_addr_i = 0; d.vi_rsp_ready_i = 1;
        d.vd_req_valid_i = 0; d.vd_req_store_i = 0; d.vd_req_addr_i = 0;
        d.vd_req_size_i = 3; d.vd_req_store_data_i = 0; d.vd_rsp_ready_i = 1;
        d.vd_req_amo_i = 0; d.vd_req_sc_i = 0; d.res_valid_i = 0;
        d.res_exact_pa_i = 0; d.res_size_i = 3;
        d.vd_amo_write_valid_i = 0; d.vd_amo_write_data_i = 0;
        d.pi_req_ready_i = 1; d.pi_rsp_valid_i = 0; d.pi_rsp_insn_i = 0; d.pi_rsp_error_i = 0;
        d.pd_req_ready_i = 1; d.pd_req_error_i = 0; d.pd_rsp_valid_i = 0;
        d.pd_rsp_data_i = 0; d.pd_rsp_error_i = 0;
        d.sfence_vma_i = 0; d.sfence_all_i = 0; d.sfence_va_i = 0;

        // PMP default: entry 0 covers all 56-bit PA with RWX
        d.pmp_cfg_i[0] = 0x1f; // TOR, RWX
        d.pmp_addr_i[0] = 0x3fffffffffffffULL;
        for (int i = 1; i < 16; ++i) { d.pmp_cfg_i[i] = 0; d.pmp_addr_i[i] = 0; }
    }

    void reset() {
        defaults(); pte.clear(); data.clear(); insn.clear();
        pd_pending = pi_pending = false;
        ptw_requests = final_data_requests = physical_stores = final_i_requests = 0;
        itlb_hits = itlb_misses = itlb_refills = 0;
        dtlb_hits = dtlb_misses = dtlb_refills = 0;
        final_store_error = false;
        d.rst_i = 1; step(); step(); d.rst_i = 0; step();
    }

    Snap step() {
        d.pd_req_ready_i = pd_ready; d.pi_req_ready_i = pi_ready;
        d.pd_rsp_valid_i = pd_pending; d.pd_rsp_data_i = pd_response.data; d.pd_rsp_error_i = pd_response.error;
        d.pi_rsp_valid_i = pi_pending; d.pi_rsp_insn_i = uint32_t(pi_response.data); d.pi_rsp_error_i = pi_response.error;
        d.clk_i = 0; d.pd_req_error_i = 0; d.eval();

        if (final_store_error && d.pd_req_valid_o && d.pd_req_store_o && !d.pd_req_ptw_o) {
            d.pd_req_error_i = 1; d.eval();
        }

        Snap s{
            bool(d.vi_req_valid_i && d.vi_req_ready_o), bool(d.vi_rsp_valid_o), bool(d.vi_rsp_error_o),
            bool(d.vi_rsp_page_fault_o), uint32_t(d.vi_rsp_insn_o),
            bool(d.vd_req_valid_i && d.vd_req_ready_o), bool(d.vd_req_error_o), bool(d.vd_req_page_fault_o),
            bool(d.vd_rsp_valid_o), bool(d.vd_rsp_error_o), bool(d.vd_rsp_page_fault_o), uint64_t(d.vd_rsp_data_o),
            bool(d.pd_req_valid_o && d.pd_req_ready_i), bool(d.pd_req_store_o), bool(d.pd_req_ptw_o), bool(d.pd_req_error_i),
            uint64_t(d.pd_req_addr_o), uint64_t(d.pd_req_store_data_o),
            bool(d.pi_req_valid_o && d.pi_req_ready_i), uint64_t(d.pi_req_addr_o),
            bool(d.itlb_hit_event_o), bool(d.itlb_miss_event_o), bool(d.itlb_refill_event_o),
            bool(d.dtlb_hit_event_o), bool(d.dtlb_miss_event_o), bool(d.dtlb_refill_event_o)
        };

        if (s.itlb_hit) ++itlb_hits;
        if (s.itlb_miss) ++itlb_misses;
        if (s.itlb_refill) ++itlb_refills;
        if (s.dtlb_hit) ++dtlb_hits;
        if (s.dtlb_miss) ++dtlb_misses;
        if (s.dtlb_refill) ++dtlb_refills;

        bool pd_rsp_fire = d.pd_rsp_valid_i && d.pd_rsp_ready_o;
        bool pi_rsp_fire = d.pi_rsp_valid_i && d.pi_rsp_ready_o;

        d.clk_i = 1; d.eval();

        if (pd_rsp_fire) pd_pending = false;
        if (pi_rsp_fire) pi_pending = false;

        if (s.pd_req_fire) {
            if (s.pd_ptw) {
                ++ptw_requests; last_ptw_pa = s.pd_addr;
                auto it = pte.find(s.pd_addr);
                pd_response = (it == pte.end()) ? Response{0, true} : it->second;
                pd_pending = true;
            } else if (s.pd_store) {
                if (!s.pd_req_error) {
                    ++physical_stores;
                    data[s.pd_addr] = Response{s.pd_store_data, false};
                }
                ++final_data_requests; last_final_pa = s.pd_addr;
            } else {
                ++final_data_requests; last_final_pa = s.pd_addr;
                auto it = data.find(s.pd_addr);
                pd_response = (it == data.end()) ? Response{0, true} : it->second;
                pd_pending = true;
            }
        }

        if (s.pi_req_fire) {
            ++final_i_requests; last_final_pa = s.pi_addr;
            auto it = insn.find(s.pi_addr);
            pi_response = (it == insn.end()) ? Response{0, true} : it->second;
            pi_pending = true;
        }

        d.clk_i = 0; d.eval();
        return s;
    }
};

static uint64_t pte(uint64_t ppn, uint64_t flags) { return (ppn << 10) | flags; }
static uint64_t satp(uint64_t root) { return 0x8000000000000000ULL | root; }
static unsigned vpn(uint64_t va, unsigned level) { return unsigned((va >> (12 + 9 * level)) & 0x1ff); }
static uint64_t pte_addr(uint64_t ppn, unsigned index) { return (ppn << 12) + (uint64_t(index) << 3); }

static uint64_t install(Sim &s, uint64_t va, unsigned leaf_level, uint64_t leaf_ppn,
                        uint64_t leaf_flags, uint64_t root = 0x100) {
    uint64_t table = root;
    for (int level = 2; level > int(leaf_level); --level) {
        uint64_t next = root + unsigned(3 - level) + 1;
        s.pte[pte_addr(table, vpn(va, level))] = {pte(next, 1), false};
        table = next;
    }
    s.pte[pte_addr(table, vpn(va, leaf_level))] = {pte(leaf_ppn, leaf_flags), false};
    return root;
}

struct Result {
    bool error = false;
    bool page = false;
    uint64_t value = 0;
    bool early_store_ready = false;
    unsigned cycles = 0;
};

static Result instruction(Sim &s, uint64_t va, unsigned limit = 100) {
    s.d.vi_req_addr_i = va; s.d.vi_req_valid_i = 1;
    bool accepted = false;
    unsigned c = 0;
    for (unsigned i = 0; i < limit; i++) {
        c++;
        auto x = s.step();
        if (x.vi_req_fire) { accepted = true; s.d.vi_req_valid_i = 0; break; }
    }
    check(accepted, "instruction request not accepted");
    for (unsigned i = 0; i < limit; i++) {
        c++;
        auto x = s.step();
        if (x.vi_rsp_valid) return {x.vi_rsp_error, x.vi_rsp_page, x.vi_insn, false, c};
    }
    throw std::runtime_error("instruction response timeout");
}

static Result load(Sim &s, uint64_t va, unsigned limit = 100) {
    s.d.vd_req_addr_i = va; s.d.vd_req_store_i = 0; s.d.vd_req_amo_i = 0; s.d.vd_req_sc_i = 0;
    s.d.vd_req_valid_i = 1;
    bool accepted = false;
    unsigned c = 0;
    for (unsigned i = 0; i < limit; i++) {
        c++;
        auto x = s.step();
        if (x.vd_req_fire) { accepted = true; s.d.vd_req_valid_i = 0; break; }
    }
    check(accepted, "load request not accepted");
    for (unsigned i = 0; i < limit; i++) {
        c++;
        auto x = s.step();
        if (x.vd_rsp_valid) return {x.vd_rsp_error, x.vd_rsp_page, x.vd_data, false, c};
    }
    throw std::runtime_error("load response timeout");
}

static Result store(Sim &s, uint64_t va, uint64_t data = 0x55aa, bool is_sc = false, unsigned limit = 100) {
    s.d.vd_req_addr_i = va; s.d.vd_req_store_i = 1; s.d.vd_req_amo_i = 0; s.d.vd_req_sc_i = is_sc;
    s.d.vd_req_store_data_i = data; s.d.vd_req_valid_i = 1;
    bool saw_ptw = false;
    unsigned c = 0;
    for (unsigned i = 0; i < limit; i++) {
        c++;
        auto x = s.step();
        saw_ptw |= x.pd_req_fire && x.pd_ptw;
        if (x.vd_req_fire) {
            s.d.vd_req_valid_i = 0;
            return {x.vd_req_error, x.vd_req_page, 0, saw_ptw && s.physical_stores == 0 && !x.vd_req_error, c};
        }
    }
    throw std::runtime_error("store completion timeout");
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    unsigned scenarios = 0;
    constexpr uint64_t VA = 0x0000000041234567ULL;
    constexpr uint64_t VRWXAD = 0xcf, VRAD = 0xc3, VXAD = 0xc9, VRWXUAD = 0xdf;

    try {
        Sim s;

        // 1. DTLB cold miss -> PTW walk -> refill -> consecutive hit (0-stall)
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0x1234, false};
            s.data[pa + 8] = {0x5678, false};

            // First access: cold miss
            auto r1 = load(s, VA);
            check(!r1.error && r1.value == 0x1234, "DTLB cold load failed");
            check(s.ptw_requests == 3, "DTLB cold load must walk 3 levels");
            check(s.dtlb_misses == 1, "DTLB miss must increment");
            check(s.dtlb_refills == 1, "DTLB refill must increment");

            // Second access: TLB hit!
            unsigned ptw_before = s.ptw_requests;
            auto r2 = load(s, VA + 8);
            check(!r2.error && r2.value == 0x5678, "DTLB hit load failed");
            check(s.ptw_requests == ptw_before, "DTLB hit must not perform PTW walk");
            check(s.dtlb_hits == 1, "DTLB hit must increment");
            check(r2.cycles <= 3, "DTLB hit must be 0-stall forward");
            ++scenarios;
        }

        // 2. ITLB cold miss -> PTW walk -> refill -> consecutive hit (0-stall)
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x30000, VRWXAD));
            uint64_t pa = (0x30000ULL << 12) | (VA & 0xfff);
            s.insn[pa] = {0x00000013, false};     // nop
            s.insn[pa + 4] = {0x00000093, false};

            // First access: cold miss
            auto r1 = instruction(s, VA);
            check(!r1.error && r1.value == 0x13, "ITLB cold fetch failed");
            check(s.ptw_requests == 3, "ITLB cold fetch must walk 3 levels");
            check(s.itlb_misses == 1, "ITLB miss must increment");
            check(s.itlb_refills == 1, "ITLB refill must increment");

            // Second access: TLB hit!
            unsigned ptw_before = s.ptw_requests;
            auto r2 = instruction(s, VA + 4);
            check(!r2.error && r2.value == 0x93, "ITLB hit fetch failed");
            check(s.ptw_requests == ptw_before, "ITLB hit must not perform PTW walk");
            check(s.itlb_hits == 1, "ITLB hit must increment");
            ++scenarios;
        }

        // 3. DTLB store 0-stall hit
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0x1111, false};

            // Warm up DTLB via load
            auto r_warm = load(s, VA);
            check(!r_warm.error, "warmup load failed");

            // Store hit: must complete combinationally in cycle 0
            unsigned ptw_before = s.ptw_requests;
            auto r_store = store(s, VA, 0x9999);
            check(!r_store.error, "DTLB store hit failed");
            check(s.ptw_requests == ptw_before, "DTLB store hit must not walk");
            check(s.data[pa].data == 0x9999, "physical store data written");
            check(s.dtlb_hits >= 1, "DTLB store hit counted");
            ++scenarios;
        }

        // 4. 2 MiB megapage (level 1) hit across page
        {
            s.reset();
            uint64_t ppn = 0x24000;
            s.d.satp_i = satp(install(s, VA, 1, ppn, VRWXAD));
            uint64_t pa0 = (ppn << 12) | (VA & 0x1fffff);
            uint64_t pa_mid = (ppn << 12) | ((VA + 0x4000) & 0x1fffff);
            s.data[pa0] = {0x2001, false};
            s.data[pa_mid] = {0x2002, false};

            // Cold miss installs 2 MiB leaf
            auto r1 = load(s, VA);
            check(!r1.error && r1.value == 0x2001, "2M cold load failed");
            check(s.ptw_requests == 2, "2M walk must take 2 PTW reads");

            // Hit at offset +16 KiB within same 2 MiB megapage
            unsigned ptw_before = s.ptw_requests;
            auto r2 = load(s, VA + 0x4000);
            check(!r2.error && r2.value == 0x2002, "2M hit load failed");
            check(s.ptw_requests == ptw_before, "2M hit must not walk");
            ++scenarios;
        }

        // 5. 1 GiB gigapage (level 2) hit across page
        {
            s.reset();
            uint64_t ppn = 0x40000;
            s.d.satp_i = satp(install(s, VA, 2, ppn, VRWXAD));
            uint64_t pa0 = (ppn << 12) | (VA & 0x3fffffff);
            uint64_t pa_far = (ppn << 12) | ((VA + 0x1000000) & 0x3fffffff); // +16 MiB
            s.data[pa0] = {0x1001, false};
            s.data[pa_far] = {0x1002, false};

            // Cold miss installs 1 GiB leaf
            auto r1 = load(s, VA);
            check(!r1.error && r1.value == 0x1001, "1G cold load failed");
            check(s.ptw_requests == 1, "1G walk must take 1 PTW read");

            // Hit at offset +16 MiB within same 1 GiB gigapage
            unsigned ptw_before = s.ptw_requests;
            auto r2 = load(s, VA + 0x1000000);
            check(!r2.error && r2.value == 0x1002, "1G hit load failed");
            check(s.ptw_requests == ptw_before, "1G hit must not walk");
            ++scenarios;
        }

        // 6. True-LRU replacement: fill all 16 entries, verify 17th page insertion evicts entry 0
        {
            s.reset();
            uint64_t root = 0x500;
            s.d.satp_i = satp(root);

            // Install 17 distinct 4 KiB pages at VA = 0x10000000 + (i * 0x1000)
            for (unsigned i = 0; i < 17; i++) {
                uint64_t page_va = 0x10000000ULL + (uint64_t(i) << 12);
                uint64_t page_ppn = 0x60000ULL + i;
                install(s, page_va, 0, page_ppn, VRWXAD, root);
                s.data[(page_ppn << 12)] = {100ULL + i, false};
            }

            // Access first 16 pages sequentially: entries 0..15 allocated
            for (unsigned i = 0; i < 16; i++) {
                uint64_t page_va = 0x10000000ULL + (uint64_t(i) << 12);
                auto r = load(s, page_va);
                check(!r.error && r.value == 100ULL + i, "sequential load failed");
            }
            check(s.dtlb_refills == 16, "all 16 entries refilled");

            // Touch entries 1..15 so page 0 is strictly the least recently used
            for (unsigned i = 1; i < 16; i++) {
                uint64_t page_va = 0x10000000ULL + (uint64_t(i) << 12);
                auto r = load(s, page_va);
                check(!r.error, "touch load failed");
            }

            // Now access 17th page (index 16) -> must evict page 0 (True-LRU)
            unsigned ptw_before = s.ptw_requests;
            auto r16 = load(s, 0x10000000ULL + (16ULL << 12));
            check(!r16.error && r16.value == 116, "17th page load failed");
            check(s.ptw_requests > ptw_before, "17th page must miss and walk");
            check(s.dtlb_refills == 17, "refill count must reach 17");

            // Check that page 1 (which was touched) was NOT evicted: accessing page 1 must HIT!
            ptw_before = s.ptw_requests;
            auto r1 = load(s, 0x10000000ULL + (1ULL << 12));
            check(!r1.error && r1.value == 101, "page 1 load failed");
            check(s.ptw_requests == ptw_before, "page 1 must hit without walk");

            // Now check that page 0 was evicted: accessing page 0 must miss!
            ptw_before = s.ptw_requests;
            auto r0 = load(s, 0x10000000ULL);
            check(!r0.error && r0.value == 100, "page 0 load failed");
            check(s.ptw_requests > ptw_before, "evicted page 0 must miss and walk");
            ++scenarios;
        }

        // 7. Dynamic User/Supervisor permissions on existing hit
        {
            s.reset();
            // Install supervisor-only page (U=0)
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            s.data[(0x20000ULL << 12) | (VA & 0xfff)] = {0x77, false};

            // Warm up DTLB from S-mode
            s.d.priv_mode_i = 1;
            auto r_s = load(s, VA);
            check(!r_s.error && r_s.value == 0x77, "S-mode warmup failed");

            // Switch to U-mode dynamically without flush -> hit must raise Load Page Fault
            s.d.priv_mode_i = 0;
            auto r_u = load(s, VA);
            check(r_u.error && r_u.page, "U-mode accessing U=0 page must page fault on hit");
            ++scenarios;
        }

        // 8. Dynamic SUM toggle on existing hit
        {
            s.reset();
            // Install User data page (U=1)
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXUAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0x88, false};

            // In S-mode with SUM=1, warm up DTLB
            s.d.priv_mode_i = 1;
            s.d.mstatus_i = (1ULL << 18); // SUM=1
            auto r1 = load(s, VA);
            check(!r1.error && r1.value == 0x88, "SUM=1 load failed");

            // Next cycle: clear SUM=0 (no SFENCE.VMA!) -> hit must raise Page Fault
            s.d.mstatus_i = 0; // SUM=0
            auto r2 = load(s, VA);
            check(r2.error && r2.page, "SUM=0 must page fault on existing DTLB hit");

            // Next cycle: restore SUM=1 -> hit must succeed!
            s.d.mstatus_i = (1ULL << 18); // SUM=1
            auto r3 = load(s, VA);
            check(!r3.error && r3.value == 0x88, "restored SUM=1 must hit successfully");
            ++scenarios;
        }

        // 9. Dynamic MXR toggle on existing hit
        {
            s.reset();
            // Install Execute-only page (R=0, X=1)
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VXAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0x99, false};

            // In S-mode with MXR=1, warm up DTLB
            s.d.priv_mode_i = 1;
            s.d.mstatus_i = (1ULL << 19); // MXR=1
            auto r1 = load(s, VA);
            check(!r1.error && r1.value == 0x99, "MXR=1 load failed");

            // Next cycle: clear MXR=0 -> hit must raise Page Fault
            s.d.mstatus_i = 0; // MXR=0
            auto r2 = load(s, VA);
            check(r2.error && r2.page, "MXR=0 must page fault on existing DTLB hit");

            // Next cycle: restore MXR=1 -> hit must succeed!
            s.d.mstatus_i = (1ULL << 19); // MXR=1
            auto r3 = load(s, VA);
            check(!r3.error && r3.value == 0x99, "restored MXR=1 must hit successfully");
            ++scenarios;
        }

        // 10. MPRV behavior and MPP=M bypass (Clarification 2)
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            s.data[(0x20000ULL << 12) | (VA & 0xfff)] = {0xaa, false};
            s.data[VA] = {0xbb, false};

            // In M-mode with MPRV=1 and MPP=S (2'b01): explicit data access is translated
            s.d.priv_mode_i = 3;
            s.d.mstatus_i = (1ULL << 17) | (1ULL << 11); // MPRV=1, MPP=1 (S)
            auto r_mprv_s = load(s, VA);
            check(!r_mprv_s.error && r_mprv_s.value == 0xaa, "MPRV=1 MPP=S must translate");

            // Clarification 2: In M-mode with MPRV=1 and MPP=M (2'b11): explicit data access bypasses translation!
            s.d.mstatus_i = (1ULL << 17) | (3ULL << 11); // MPRV=1, MPP=3 (M)
            unsigned ptw_before = s.ptw_requests;
            auto r_mprv_m = load(s, VA);
            check(!r_mprv_m.error && r_mprv_m.value == 0xbb, "MPRV=1 MPP=M must bypass translation");
            check(s.ptw_requests == ptw_before, "MPRV=1 MPP=M must not perform PTW walk");
            ++scenarios;
        }

        // 11. Svade A=0 and D=0 hit faults
        {
            s.reset();
            // Install page with A=0
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD & ~0x40ULL));
            auto r_a0 = load(s, VA);
            check(r_a0.error && r_a0.page, "Svade A=0 must page fault");

            // Install page with A=1, D=0
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD & ~0x80ULL));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0x55, false};

            // Load on D=0 succeeds and warms DTLB
            auto r_d0_load = load(s, VA);
            check(!r_d0_load.error && r_d0_load.value == 0x55, "Svade D=0 load must succeed");

            // Store to same entry (hitting in DTLB) must detect D=0 and raise Page Fault!
            auto r_d0_store = store(s, VA);
            check(r_d0_store.error && r_d0_store.page && s.physical_stores == 0,
                  "Svade D=0 store hit must page fault with 0 physical stores");
            ++scenarios;
        }

        // 12. PMP denial after valid TLB hit (must raise Access Fault, NOT Page Fault)
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0xcc, false};

            // Warm up DTLB while PMP allows
            auto r_warm = load(s, VA);
            check(!r_warm.error && r_warm.value == 0xcc, "DTLB warmup failed");

            // Now lock PMP to deny physical address pa:
            // Entry 0 OFF, Entry 1 NA4 at pa with no permissions
            s.d.pmp_cfg_i[0] = 0x00; // OFF
            s.d.pmp_cfg_i[1] = 0x90; // Locked, NA4, no R/W/X
            s.d.pmp_addr_i[1] = pa >> 2;

            // Load on existing DTLB hit: PMP denies access!
            unsigned phys_before = s.final_data_requests;
            auto r_pmp = load(s, VA);
            check(r_pmp.error && !r_pmp.page, "PMP denial on DTLB hit must be access fault, NOT page fault");
            check(s.final_data_requests == phys_before, "PMP denial must suppress physical bus request");
            ++scenarios;
        }

        // 13. Global SFENCE.VMA (rs1=x0) invalidation
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            s.data[(0x20000ULL << 12) | (VA & 0xfff)] = {0xdd, false};

            // Warm up DTLB
            auto r_warm = load(s, VA);
            check(!r_warm.error && s.dtlb_refills == 1, "warmup failed");

            // Execute global SFENCE.VMA
            s.d.sfence_vma_i = 1;
            s.d.sfence_all_i = 1;
            s.step();
            s.d.sfence_vma_i = 0;
            s.d.sfence_all_i = 0;
            s.step();

            // Next access must MISS and walk!
            unsigned ptw_before = s.ptw_requests;
            auto r_post = load(s, VA);
            check(!r_post.error && r_post.value == 0xdd, "post-fence load failed");
            check(s.ptw_requests > ptw_before, "post-global-fence access must miss and walk");
            ++scenarios;
        }

        // 14. Address-selective SFENCE.VMA (rs1!=x0) invalidation
        {
            s.reset();
            uint64_t root = 0x700;
            s.d.satp_i = satp(root);

            uint64_t va_a = 0x10001000ULL;
            uint64_t va_b = 0x10002000ULL;
            install(s, va_a, 0, 0x31000, VRWXAD, root);
            install(s, va_b, 0, 0x32000, VRWXAD, root);
            s.data[0x31000ULL << 12] = {0x11, false};
            s.data[0x32000ULL << 12] = {0x22, false};

            // Warm up both entries
            load(s, va_a);
            load(s, va_b);
            check(s.dtlb_refills == 2, "both entries installed");

            // Address-selective flush of va_a only
            s.d.sfence_vma_i = 1;
            s.d.sfence_all_i = 0;
            s.d.sfence_va_i = va_a;
            s.step();
            s.d.sfence_vma_i = 0;
            s.step();

            // va_a must miss and walk
            unsigned ptw_before = s.ptw_requests;
            auto r_a = load(s, va_a);
            check(!r_a.error && r_a.value == 0x11, "va_a reload failed");
            check(s.ptw_requests > ptw_before, "va_a must miss after selective flush");

            // va_b must HIT without walk!
            ptw_before = s.ptw_requests;
            auto r_b = load(s, va_b);
            check(!r_b.error && r_b.value == 0x22, "va_b load failed");
            check(s.ptw_requests == ptw_before, "va_b must hit (preserved across selective flush)");
            ++scenarios;
        }

        // 15. satp change automatically invalidates TLBs
        {
            s.reset();
            uint64_t root1 = 0x800, root2 = 0x900;
            s.d.satp_i = satp(root1);
            install(s, VA, 0, 0x41000, VRWXAD, root1);
            install(s, VA, 0, 0x42000, VRWXAD, root2);
            s.data[(0x41000ULL << 12) | (VA & 0xfff)] = {0x51, false};
            s.data[(0x42000ULL << 12) | (VA & 0xfff)] = {0x52, false};

            // Access under root1
            auto r1 = load(s, VA);
            check(!r1.error && r1.value == 0x51, "root1 load failed");

            // Change satp to root2 (no SFENCE.VMA!)
            s.d.satp_i = satp(root2);
            s.step();

            // Access under root2: must invalidate old TLB and load from root2!
            auto r2 = load(s, VA);
            check(!r2.error && r2.value == 0x52, "satp change must invalidate and read from root2");
            ++scenarios;
        }

        // 16. Redirect during instruction PTW aborts without refilling ITLB (Clarification 1)
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x50000, VRWXAD));
            uint64_t pa = (0x50000ULL << 12) | (VA & 0xfff);
            s.insn[pa] = {0x00000013, false};

            // Start instruction fetch (cold miss)
            s.d.vi_req_addr_i = VA;
            s.d.vi_req_valid_i = 1;
            s.step(); // MMU accepts into PTW_REQ
            s.d.vi_req_valid_i = 0;

            // Assert redirect_i while walk is in progress!
            s.d.redirect_i = 1;
            // Step until MMU drains and returns to IDLE
            for (int i = 0; i < 20; i++) {
                s.step();
                if (s.d.idle_o) break;
            }
            s.d.redirect_i = 0;
            s.step();

            check(s.itlb_refills == 0, "aborted instruction walk must NEVER refill ITLB");

            // Next instruction fetch to VA must MISS and perform fresh walk
            unsigned ptw_before = s.ptw_requests;
            auto r_fresh = instruction(s, VA);
            check(!r_fresh.error && r_fresh.value == 0x13, "fresh instruction fetch failed");
            check(s.ptw_requests > ptw_before, "fetch after aborted walk must miss and walk");
            ++scenarios;
        }

        // 17. Competing I/D misses: LSU has strict priority
        {
            s.reset();
            uint64_t root = 0x950;
            s.d.satp_i = satp(root);
            uint64_t va_i = 0x20000000ULL, va_d = 0x30000000ULL;
            install(s, va_i, 0, 0x61000, VRWXAD, root);
            install(s, va_d, 0, 0x62000, VRWXAD, root);
            s.insn[0x61000ULL << 12] = {0x13, false};
            s.data[0x62000ULL << 12] = {0x777, false};

            // Both I and D valid in same cycle in IDLE
            s.d.vi_req_addr_i = va_i; s.d.vi_req_valid_i = 1;
            s.d.vd_req_addr_i = va_d; s.d.vd_req_store_i = 0; s.d.vd_req_valid_i = 1;
            auto snap = s.step();

            // LSU request accepted, instruction request held
            check(snap.vd_req_fire, "LSU data request must have priority");
            check(!snap.vi_req_fire, "Instruction request must wait for LSU");

            s.d.vd_req_valid_i = 0;
            // Complete data walk
            for (int i = 0; i < 20; i++) {
                auto x = s.step();
                if (x.vd_rsp_valid) break;
            }

            // Now instruction fetch can proceed
            for (int i = 0; i < 20; i++) {
                auto x = s.step();
                if (x.vi_req_fire) { s.d.vi_req_valid_i = 0; break; }
            }
            for (int i = 0; i < 20; i++) {
                auto x = s.step();
                if (x.vi_rsp_valid) break;
            }
            check(s.dtlb_refills == 1 && s.itlb_refills == 1, "both I and D serviced");
            ++scenarios;
        }

        // 18. Faulting PTW must never refill TLB
        {
            s.reset();
            // Point root to an invalid PTE (V=0)
            s.d.satp_i = satp(0x100);
            s.pte[pte_addr(0x100, vpn(VA, 2))] = {0, false}; // V=0

            auto r = load(s, VA);
            check(r.error && r.page, "invalid PTE must page fault");
            check(s.dtlb_refills == 0, "faulting walk must NEVER refill TLB");
            ++scenarios;
        }

        // 19. LR/SC through TLB
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0x42, false};

            // Warm up DTLB via LR (load reserved)
            s.d.vd_req_addr_i = VA; s.d.vd_req_store_i = 0; s.d.vd_req_valid_i = 1;
            auto r_lr = load(s, VA);
            check(!r_lr.error && r_lr.value == 0x42, "LR load failed");

            // SC with matching reservation: succeeds
            s.d.vd_req_addr_i = VA; s.d.vd_req_store_i = 1; s.d.vd_req_sc_i = 1;
            s.d.vd_req_store_data_i = 0x99;
            s.d.res_valid_i = 1; s.d.res_exact_pa_i = pa; s.d.res_size_i = 3;
            auto r_sc = store(s, VA, 0x99, true);
            check(!r_sc.error && s.d.vd_sc_success_o, "SC with matching reservation must succeed");
            check(s.data[pa].data == 0x99, "SC physical store committed");

            // SC with mismatched reservation: fails and suppresses physical store
            s.d.res_exact_pa_i = pa + 0x1000; // mismatched PA
            auto r_sc_fail = store(s, VA, 0xdead, true);
            check(!r_sc_fail.error && !s.d.vd_sc_success_o, "mismatched SC must report failure");
            check(s.data[pa].data == 0x99, "failed SC must not write physical memory");
            ++scenarios;
        }

        // 20. AMO through TLB
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.data[pa] = {10, false};

            // AMO at translated VA: Phase 1 read
            s.d.vd_req_addr_i = VA; s.d.vd_req_store_i = 0; s.d.vd_req_amo_i = 1;
            s.d.vd_req_valid_i = 1;
            s.step();
            s.d.vd_req_valid_i = 0;

            // Wait for Phase 1 read response
            for (int i = 0; i < 20; i++) {
                auto x = s.step();
                if (x.vd_rsp_valid) {
                    check(x.vd_data == 10, "AMO read data mismatch");
                    break;
                }
            }

            // Phase 2 write
            s.d.vd_amo_write_valid_i = 1;
            s.d.vd_amo_write_data_i = 15;
            for (int i = 0; i < 20; i++) {
                auto x = s.step();
                if (s.d.vd_amo_write_ready_o) {
                    s.d.vd_amo_write_valid_i = 0;
                    break;
                }
            }
            check(s.data[pa].data == 15, "AMO Phase 2 write committed to translated PA");
            ++scenarios;
        }

        std::cout << "TLB focused verification suite: pass (" << scenarios << " scenarios)\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "TLB focused verification suite: fail: " << e.what() << "\n";
        return 1;
    }
}
