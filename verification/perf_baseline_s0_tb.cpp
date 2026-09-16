// Pre-Optimization Performance Baseline Testbench for Fursoy Slice-0.
// Observational-only architectural instrumentation for full Linux boot & micro-workloads.
// Strictly non-intrusive: zero RTL modification, zero behavioral side effects.

#include "Vfursoy_s0_soc.h"
#include "Vfursoy_s0_soc___024root.h"
#include "verilated.h"
#include <algorithm>
#include <cstdint>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

static constexpr uint64_t RAM_BASE = 0x80000000ULL;
static constexpr uint64_t RAM_SIZE = 256 * 1024 * 1024ULL; // Full 256 MiB platform DRAM

static uint64_t get64(const std::vector<uint8_t>& b, size_t o) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= uint64_t(b[o + i]) << (8 * i);
    return v;
}
static uint32_t get32(const std::vector<uint8_t>& b, size_t o) {
    return uint32_t(get64(b, o) & 0xffffffff);
}
static uint16_t get16(const std::vector<uint8_t>& b, size_t o) {
    return uint16_t(b[o] | (uint16_t(b[o + 1]) << 8));
}

static size_t load_raw_bin(const char* path, std::vector<uint8_t>& ram, uint64_t load_addr) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error(std::string("cannot open binary: ") + path);
    std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
    if (load_addr < RAM_BASE || load_addr - RAM_BASE + b.size() > RAM_SIZE) {
        throw std::runtime_error(std::string("binary placement outside RAM: ") + path);
    }
    for (size_t i = 0; i < b.size(); i++) {
        ram[load_addr - RAM_BASE + i] = b[i];
    }
    return b.size();
}

static size_t load_elf(const char* path, std::vector<uint8_t>& ram) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error(std::string("cannot open ELF: ") + path);
    std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), {});
    if (b.size() < 64 || get32(b, 0) != 0x464c457f || b[4] != 2 || b[5] != 1 || get16(b, 18) != 243)
        throw std::runtime_error("invalid ELF64");
    uint64_t phoff = get64(b, 32);
    uint16_t entsz = get16(b, 54), count = get16(b, 56);
    size_t total_loaded = 0;
    for (unsigned i = 0; i < count; i++) {
        size_t o = phoff + i * entsz;
        if (o + 56 > b.size()) throw std::runtime_error("bad program headers");
        if (get32(b, o) != 1) continue; // PT_LOAD
        uint64_t fileoff = get64(b, o + 8), addr = get64(b, o + 24);
        uint64_t filesz = get64(b, o + 32), memsz = get64(b, o + 40);
        if (addr < RAM_BASE || memsz > RAM_SIZE || addr - RAM_BASE > RAM_SIZE - memsz || fileoff + filesz > b.size())
            throw std::runtime_error("segment outside RAM");
        for (uint64_t j = 0; j < filesz; j++) ram[addr - RAM_BASE + j] = b[fileoff + j];
        for (uint64_t j = filesz; j < memsz; j++) ram[addr - RAM_BASE + j] = 0;
        total_loaded += memsz;
    }
    return total_loaded;
}

static inline uint64_t read_mem(const std::vector<uint8_t>& ram, uint64_t addr, unsigned size_shift) {
    uint64_t val = 0;
    size_t bytes = 1u << size_shift;
    uint64_t offset = addr - RAM_BASE;
    for (size_t i = 0; i < bytes; i++) {
        val |= (uint64_t(ram[offset + i]) << (8 * i));
    }
    return val;
}

static inline void write_mem(std::vector<uint8_t>& ram, uint64_t addr, unsigned size_shift, uint64_t val) {
    size_t bytes = 1u << size_shift;
    uint64_t offset = addr - RAM_BASE;
    for (size_t i = 0; i < bytes; i++) {
        ram[offset + i] = uint8_t((val >> (8 * i)) & 0xff);
    }
}

static inline bool check_l1d_victim_dirty(Vfursoy_s0_soc& dut, uint64_t pa) {
    uint32_t set = (pa >> 6) & 0x3f;
    uint8_t plru = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__plru_q[set];
    uint8_t val = (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__valid_q[set][3] << 3) |
                  (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__valid_q[set][2] << 2) |
                  (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__valid_q[set][1] << 1) |
                  (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__valid_q[set][0]);
    int victim = 0;
    if (!(val & 1)) victim = 0;
    else if (!(val & 2)) victim = 1;
    else if (!(val & 4)) victim = 2;
    else if (!(val & 8)) victim = 3;
    else {
        switch (plru) {
            case 0: case 1: victim = 3; break;
            case 2: case 3: victim = 2; break;
            case 4: case 6: victim = 1; break;
            default: victim = 0; break;
        }
    }
    return dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__valid_q[set][victim] &&
           dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__dirty_q[set][victim];
}

static inline bool is_l1i_cached(Vfursoy_s0_soc& dut, uint64_t pa) {
    uint32_t set = (pa >> 6) & 0x3f;
    uint64_t tag = pa >> 12;
    for (int w = 0; w < 4; w++) {
        int bit = set * 4 + w;
        bool v = (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__valid_q[bit / 32] >> (bit % 32)) & 1;
        if (v && (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__tag_q[set][w] == tag)) {
            return true;
        }
    }
    return false;
}

// Complete performance counter record
struct PerfRecord {
    uint64_t cycles = 0;
    uint64_t commits = 0;

    // Privilege mode cycle breakdown
    uint64_t cycles_m = 0;
    uint64_t cycles_s = 0;
    uint64_t cycles_u = 0;

    // Fetch and pipeline stalls
    uint64_t fetch_wait_cycles = 0;
    uint64_t lsu_busy_cycles = 0;
    uint64_t lsu_req_wait_cycles = 0;
    uint64_t lsu_rsp_wait_cycles = 0;
    uint64_t lsu_amo_wait_cycles = 0;

    // Control-flow penalty
    uint64_t branch_commits = 0;
    uint64_t branch_penalty_cycles = 0;

    // MMU / PTW detailed metrics
    uint64_t ptw_walks_total = 0;
    uint64_t ptw_walks_insn = 0;
    uint64_t ptw_walks_load = 0;
    uint64_t ptw_walks_store = 0;
    uint64_t ptw_walks_amo = 0;
    uint64_t ptw_cycles_total = 0;
    uint64_t ptw_cycles_insn = 0;
    uint64_t ptw_cycles_data = 0;
    uint64_t ptw_memory_accesses = 0;

    // TLB metrics
    uint64_t itlb_hit_count = 0;
    uint64_t itlb_miss_count = 0;
    uint64_t itlb_refill_count = 0;
    uint64_t dtlb_hit_count = 0;
    uint64_t dtlb_miss_count = 0;
    uint64_t dtlb_refill_count = 0;

    // L1I cache metrics
    uint64_t l1i_hit_count = 0;
    uint64_t l1i_miss_count = 0;
    uint64_t l1i_refill_count = 0;
    uint64_t l1i_early_restart_count = 0;
    uint64_t l1i_streaming_hit_count = 0;
    uint64_t l1i_refill_abort_count = 0;

    // L1I-NLP v1 Hardware Telemetry Metrics (15 authoritatively exported strobes)
    uint64_t l1i_nlp_candidate_events = 0;
    uint64_t l1i_nlp_issued_events = 0;
    uint64_t l1i_nlp_suppressed_page_events = 0;
    uint64_t l1i_nlp_suppressed_pmp_events = 0;
    uint64_t l1i_nlp_suppressed_resident_events = 0;
    uint64_t l1i_nlp_suppressed_duplicate_events = 0;
    uint64_t l1i_nlp_useful_hit_events = 0;
    uint64_t l1i_nlp_streaming_hit_events = 0;
    uint64_t l1i_nlp_preempted_events = 0;
    uint64_t l1i_nlp_dormant_abandon_events = 0;
    uint64_t l1i_nlp_discard_redirect_events = 0;
    uint64_t l1i_nlp_discard_maint_events = 0;
    uint64_t l1i_nlp_discard_error_events = 0;
    uint64_t l1i_nlp_promote_events = 0;
    uint64_t l1i_nlp_hidden_cycles_total = 0;

    // L1D cache metrics
    uint64_t l1d_hit_count = 0;
    uint64_t l1d_miss_count = 0;
    uint64_t l1d_refill_count = 0;
    uint64_t l1d_evict_count = 0;
    uint64_t l1d_load_hit_count = 0;
    uint64_t l1d_load_miss_count = 0;
    uint64_t l1d_store_hit_count = 0;
    uint64_t l1d_store_miss_count = 0;
    uint64_t l1d_er_events = 0;
    uint64_t l1d_er_saved_cycles_total = 0;

    // Timing-neutral, overlapping diagnostics for the post-retirement refill window.
    uint64_t l1d_er_trailing_active_cycles = 0;
    uint64_t l1d_er_trailing_useful_commit_cycles = 0;
    uint64_t l1d_er_trailing_blocked_load_cycles = 0;
    uint64_t l1d_er_trailing_blocked_store_cycles = 0;
    uint64_t l1d_er_trailing_blocked_serialization_cycles = 0;
    uint64_t l1d_er_trailing_other_zero_retire_cycles = 0;
    uint64_t l1d_er_trailing_sb_nonempty_cycles = 0;
    uint64_t l1d_er_trailing_sb_full_cycles = 0;
    uint64_t l1d_refill_error_edge_cycles = 0;
    uint64_t fatal_halt_cycles = 0;

    // Interrupts, Traps, and System Calls
    uint64_t sbi_ecall_count = 0;
    uint64_t user_ecall_count = 0;
    uint64_t mtip_count = 0;
    uint64_t stip_count = 0;
    uint64_t seip_count = 0;
    uint64_t sync_trap_count = 0;
    uint64_t trap_overhead_cycles = 0;

    // Detailed Bottleneck & Disjoint Partition Metrics (Mutually Exclusive Partition)
    uint64_t cycles_useful_retire = 0;
    uint64_t cycles_zero_retire = 0;
    uint64_t cycles_l1i_miss_refill = 0;
    uint64_t cycles_l1i_hit_fetch_stall = 0;
    uint64_t cycles_lsu_stall = 0;
    uint64_t cycles_lsu_issue_stall = 0;
    uint64_t cycles_lsu_mem_rsp_wait = 0;
    uint64_t cycles_lsu_amo_wait = 0;
    uint64_t cycles_load_stall = 0;
    uint64_t cycles_store_stall = 0;
    uint64_t cycles_amo_lr_sc_stall = 0;
    uint64_t cycles_ptw_stall = 0;
    uint64_t cycles_itlb_ptw_stall = 0;
    uint64_t cycles_dtlb_ptw_stall = 0;
    uint64_t cycles_itlb_translation_latency = 0;
    uint64_t cycles_branch_redirect_bubble = 0;
    uint64_t cycles_csr_serialization_flush = 0;
    uint64_t cycles_trap_entry_drain = 0;
    uint64_t cycles_trap_vector_bubble = 0;
    uint64_t cycles_mret_sret_redirect_bubble = 0;
    uint64_t cycles_sfence_vma_serialization = 0;
    uint64_t cycles_fence_i_serialization = 0;
    uint64_t cycles_refill_handoff_bubble = 0;
    uint64_t cycles_residual_unclassified = 0;

    // Store Buffer Disjoint Partition Categories
    uint64_t cycles_sb_full_stall = 0;
    uint64_t cycles_sb_raw_load_stall = 0;
    uint64_t cycles_srb_raw_load_stall = 0;
    uint64_t cycles_sb_arbitration_load_stall = 0;
    uint64_t cycles_srb_sec_load_stall = 0;
    uint64_t cycles_sb_drain_visible_stall = 0;

    // Mutually Exclusive Stage-E Load Stall Categories (Authoritative Disjoint Telemetry)
    uint64_t cycles_l1d_load_structural_arb_stall = 0;
    uint64_t cycles_srb_install_bubble_stall = 0;
    uint64_t cycles_l1d_load_clean_miss_refill_stall = 0;
    uint64_t cycles_l1d_load_dirty_evict_stall = 0;
    uint64_t cycles_l1d_load_dirty_refill_stall = 0;

    // Latency Distribution Trackers (Task 2)
    uint64_t lat_clean_miss_count = 0;
    uint64_t lat_clean_miss_total = 0;
    uint64_t lat_clean_miss_min = UINT64_MAX;
    uint64_t lat_clean_miss_max = 0;

    uint64_t lat_dirty_evict_count = 0;
    uint64_t lat_dirty_evict_total = 0;
    uint64_t lat_dirty_evict_min = UINT64_MAX;
    uint64_t lat_dirty_evict_max = 0;

    uint64_t lat_dirty_refill_count = 0;
    uint64_t lat_dirty_refill_total = 0;
    uint64_t lat_dirty_refill_min = UINT64_MAX;
    uint64_t lat_dirty_refill_max = 0;

    uint64_t lat_dirty_total_count = 0;
    uint64_t lat_dirty_total_cycles = 0;
    uint64_t lat_dirty_total_min = UINT64_MAX;
    uint64_t lat_dirty_total_max = 0;

    uint64_t lat_install_count = 0;
    uint64_t lat_install_total = 0;
    uint64_t lat_install_min = UINT64_MAX;
    uint64_t lat_install_max = 0;

    uint64_t lat_sb_drain_collision_count = 0;
    uint64_t lat_sb_drain_collision_total = 0;
    uint64_t lat_sb_drain_collision_min = UINT64_MAX;
    uint64_t lat_sb_drain_collision_max = 0;

    // Section A: Store Buffer Full Characterization
    uint64_t sb_full_episodes = 0;
    uint64_t sb_full_consecutive_cycles_min = UINT64_MAX;
    uint64_t sb_full_consecutive_cycles_max = 0;
    uint64_t sb_full_consecutive_cycles_total = 0;
    uint64_t sb_full_duration_buckets[6] = {0, 0, 0, 0, 0, 0}; // 1-4, 5-10, 11-20, 21-50, 51-100, 101+
    uint64_t sb_full_drain_completions = 0;
    uint64_t sb_full_blocked_l1d_busy = 0;
    uint64_t sb_full_blocked_srb_busy = 0;
    uint64_t sb_full_blocked_dram_bus = 0;
    uint64_t sb_full_hit_drain_active = 0;
    uint64_t sb_full_coalesce_same_dword_cycles = 0;
    uint64_t sb_full_coalesce_exact_addr_cycles = 0;
    uint64_t shadow_sb_full_stall_cycles_d10 = 0;
    uint64_t shadow_sb_full_stall_cycles_d12 = 0;
    uint64_t shadow_sb_full_stall_cycles_d16 = 0;

    // Section B: L1I Next-Line Prefetch Opportunity Characterization
    uint64_t l1i_demand_refills_total = 0;
    uint64_t l1i_seq_next_line_refills = 0;
    uint64_t l1i_nlp_same_page_candidates = 0;
    uint64_t l1i_nlp_already_cached_filtered = 0;
    uint64_t l1i_nlp_issued_candidates = 0;
    uint64_t l1i_nlp_useful_prefetches = 0;
    uint64_t l1i_nlp_useless_prefetches = 0;
    uint64_t l1i_nlp_lead_time_min = UINT64_MAX;
    uint64_t l1i_nlp_lead_time_max = 0;
    uint64_t l1i_nlp_lead_time_total = 0;
    uint64_t l1i_nlp_lead_time_buckets[4] = {0, 0, 0, 0}; // <18, 18-50, 50-200, 200+
    uint64_t l1i_nlp_cycles_hidden = 0;
    uint64_t l1i_nlp_bus_idle_cycles = 0;
    uint64_t l1i_nlp_bus_conflicts_l1d = 0;
    uint64_t l1i_nlp_redirects_before_use = 0;

    // Section C: Store-to-Load Forwarding Characterization
    uint64_t raw_sb_exact_dword_match_cycles = 0;
    uint64_t raw_sb_single_entry_full_cov_cycles = 0;
    uint64_t raw_sb_multi_entry_merge_cycles = 0;
    uint64_t raw_sb_partial_overlap_cycles = 0;
    uint64_t raw_srb_store_payload_hit_cycles = 0;
    uint64_t raw_srb_refill_line_wait_cycles = 0;
    uint64_t raw_load_width_byte_cycles = 0;
    uint64_t raw_load_width_half_cycles = 0;
    uint64_t raw_load_width_word_cycles = 0;
    uint64_t raw_load_width_dword_cycles = 0;
    uint64_t raw_forwardable_simple_single_entry_cycles = 0;
    uint64_t raw_forwardable_byte_merge_cycles = 0;
    uint64_t raw_forwardable_full_with_srb_line_cycles = 0;

    void sample_sb_full_episode(uint64_t len) {
        sb_full_episodes++;
        sb_full_consecutive_cycles_total += len;
        if (len < sb_full_consecutive_cycles_min) sb_full_consecutive_cycles_min = len;
        if (len > sb_full_consecutive_cycles_max) sb_full_consecutive_cycles_max = len;
        if (len <= 4) sb_full_duration_buckets[0]++;
        else if (len <= 10) sb_full_duration_buckets[1]++;
        else if (len <= 20) sb_full_duration_buckets[2]++;
        else if (len <= 50) sb_full_duration_buckets[3]++;
        else if (len <= 100) sb_full_duration_buckets[4]++;
        else sb_full_duration_buckets[5]++;
    }

    void sample_nlp_lead_time(uint64_t lead) {
        l1i_nlp_useful_prefetches++;
        l1i_nlp_lead_time_total += lead;
        if (lead < l1i_nlp_lead_time_min) l1i_nlp_lead_time_min = lead;
        if (lead > l1i_nlp_lead_time_max) l1i_nlp_lead_time_max = lead;
        if (lead < 18) l1i_nlp_lead_time_buckets[0]++;
        else if (lead <= 50) l1i_nlp_lead_time_buckets[1]++;
        else if (lead <= 200) l1i_nlp_lead_time_buckets[2]++;
        else l1i_nlp_lead_time_buckets[3]++;
        l1i_nlp_cycles_hidden += std::min((uint64_t)18, lead);
    }

    void sample_clean_miss(uint64_t lat) {
        lat_clean_miss_count++;
        lat_clean_miss_total += lat;
        if (lat < lat_clean_miss_min) lat_clean_miss_min = lat;
        if (lat > lat_clean_miss_max) lat_clean_miss_max = lat;
    }
    void sample_dirty_evict(uint64_t lat) {
        lat_dirty_evict_count++;
        lat_dirty_evict_total += lat;
        if (lat < lat_dirty_evict_min) lat_dirty_evict_min = lat;
        if (lat > lat_dirty_evict_max) lat_dirty_evict_max = lat;
    }
    void sample_dirty_refill(uint64_t lat) {
        lat_dirty_refill_count++;
        lat_dirty_refill_total += lat;
        if (lat < lat_dirty_refill_min) lat_dirty_refill_min = lat;
        if (lat > lat_dirty_refill_max) lat_dirty_refill_max = lat;
    }
    void sample_dirty_total(uint64_t lat) {
        lat_dirty_total_count++;
        lat_dirty_total_cycles += lat;
        if (lat < lat_dirty_total_min) lat_dirty_total_min = lat;
        if (lat > lat_dirty_total_max) lat_dirty_total_max = lat;
    }
    void sample_install(uint64_t lat) {
        lat_install_count++;
        lat_install_total += lat;
        if (lat < lat_install_min) lat_install_min = lat;
        if (lat > lat_install_max) lat_install_max = lat;
    }
    void sample_sb_collision(uint64_t lat) {
        lat_sb_drain_collision_count++;
        lat_sb_drain_collision_total += lat;
        if (lat < lat_sb_drain_collision_min) lat_sb_drain_collision_min = lat;
        if (lat > lat_sb_drain_collision_max) lat_sb_drain_collision_max = lat;
    }

    // SRB Telemetry
    uint64_t srb_active_cycles = 0;
    uint64_t srb_installs = 0;
    uint64_t srb_clean_victims = 0;
    uint64_t srb_dirty_victims = 0;

    // Store Buffer Telemetry
    uint64_t sb_total_ordinary_stores = 0;
    uint64_t sb_enqueues = 0;
    uint64_t sb_tail_merges = 0;
    uint64_t sb_max_occupancy = 0;
    uint64_t sb_occ_cycles[9] = {0, 0, 0, 0, 0, 0, 0, 0, 0};
    uint64_t sb_full_stall_cycles = 0;
    uint64_t sb_raw_conflict_stall_cycles = 0;
    uint64_t sb_drain_requests = 0;
    uint64_t sb_drain_completions = 0;
    uint64_t sb_drain_hits = 0;
    uint64_t sb_drain_clean_misses = 0;
    uint64_t sb_drain_dirty_misses = 0;
    uint64_t sb_hidden_drain_cycles = 0;
    uint64_t sb_total_drain_latency_cycles = 0;

    // Fine-grained L1D / LSU load breakdown
    uint64_t cycles_load_hit_latency = 0;
    uint64_t cycles_load_clean_refill = 0;
    uint64_t cycles_load_dirty_evict = 0;
    uint64_t cycles_load_dirty_refill = 0;

    // Fine-grained L1D / LSU store breakdown
    uint64_t cycles_store_hit_latency = 0;
    uint64_t cycles_store_clean_refill = 0;
    uint64_t cycles_store_dirty_evict = 0;
    uint64_t cycles_store_dirty_refill = 0;

    // L1D maintenance breakdown
    uint64_t cycles_maint_sfence_vma = 0;
    uint64_t cycles_maint_fence_i = 0;
    uint64_t cycles_maint_pmp = 0;

    // MMIO & Arbitration
    uint64_t cycles_mmio_stall = 0;
    uint64_t cycles_arbitration_contention = 0;

    // Sub-breakdowns
    uint64_t fetch_req_wait_cycles = 0;
    uint64_t fetch_rsp_wait_cycles = 0;
    uint64_t cycles_lsu_req_wait = 0;
    uint64_t cycles_lsu_rsp_wait = 0;

    // Physical Memory and MMIO Transaction Counts
    uint64_t trans_imem_req = 0;
    uint64_t trans_dmem_load = 0;
    uint64_t trans_dmem_store = 0;
    uint64_t trans_ptw_req = 0;
    uint64_t trans_clint_mmio = 0;
    uint64_t trans_plic_mmio = 0;
    uint64_t trans_uart_mmio = 0;

    // Instruction Mix by Opcode
    uint64_t insn_alu_count = 0;
    uint64_t insn_load_count = 0;
    uint64_t insn_store_count = 0;
    uint64_t insn_amo_count = 0;
    uint64_t insn_branch_cond_count = 0;
    uint64_t insn_jal_count = 0;
    uint64_t insn_jalr_count = 0;
    uint64_t insn_system_count = 0;
    uint64_t branch_taken_count = 0;
    uint64_t branch_untaken_count = 0;

    // UART MMIO accesses
    uint64_t uart_access_count = 0;

    // Branch Prediction Unit (BPU) metrics
    uint64_t bpu_branch_count = 0;
    uint64_t bpu_branch_taken_count = 0;
    uint64_t bpu_branch_correct_count = 0;
    uint64_t bpu_branch_mispred_count = 0;
    uint64_t bpu_jal_count = 0;
    uint64_t bpu_jal_correct_count = 0;
    uint64_t bpu_jalr_count = 0;
    uint64_t bpu_jalr_correct_count = 0;
    uint64_t bpu_ras_push_count = 0;
    uint64_t bpu_ras_pop_count = 0;
    uint64_t bpu_ras_correct_count = 0;
    uint64_t bpu_btb_hit_count = 0;
    uint64_t bpu_btb_miss_count = 0;
    uint64_t bpu_false_hit_count = 0;
    uint64_t bpu_bubbles_saved = 0;
};

static PerfRecord diff_records(const PerfRecord& end, const PerfRecord& start) {
    PerfRecord r;
    r.cycles = end.cycles >= start.cycles ? end.cycles - start.cycles : 0;
    r.commits = end.commits >= start.commits ? end.commits - start.commits : 0;
    r.cycles_m = end.cycles_m >= start.cycles_m ? end.cycles_m - start.cycles_m : 0;
    r.cycles_s = end.cycles_s >= start.cycles_s ? end.cycles_s - start.cycles_s : 0;
    r.cycles_u = end.cycles_u >= start.cycles_u ? end.cycles_u - start.cycles_u : 0;
    r.fetch_wait_cycles = end.fetch_wait_cycles >= start.fetch_wait_cycles ? end.fetch_wait_cycles - start.fetch_wait_cycles : 0;
    r.lsu_busy_cycles = end.lsu_busy_cycles >= start.lsu_busy_cycles ? end.lsu_busy_cycles - start.lsu_busy_cycles : 0;
    r.lsu_req_wait_cycles = end.lsu_req_wait_cycles >= start.lsu_req_wait_cycles ? end.lsu_req_wait_cycles - start.lsu_req_wait_cycles : 0;
    r.lsu_rsp_wait_cycles = end.lsu_rsp_wait_cycles >= start.lsu_rsp_wait_cycles ? end.lsu_rsp_wait_cycles - start.lsu_rsp_wait_cycles : 0;
    r.lsu_amo_wait_cycles = end.lsu_amo_wait_cycles >= start.lsu_amo_wait_cycles ? end.lsu_amo_wait_cycles - start.lsu_amo_wait_cycles : 0;
    r.branch_commits = end.branch_commits >= start.branch_commits ? end.branch_commits - start.branch_commits : 0;
    r.branch_penalty_cycles = end.branch_penalty_cycles >= start.branch_penalty_cycles ? end.branch_penalty_cycles - start.branch_penalty_cycles : 0;
    r.ptw_walks_total = end.ptw_walks_total >= start.ptw_walks_total ? end.ptw_walks_total - start.ptw_walks_total : 0;
    r.ptw_walks_insn = end.ptw_walks_insn >= start.ptw_walks_insn ? end.ptw_walks_insn - start.ptw_walks_insn : 0;
    r.ptw_walks_load = end.ptw_walks_load >= start.ptw_walks_load ? end.ptw_walks_load - start.ptw_walks_load : 0;
    r.ptw_walks_store = end.ptw_walks_store >= start.ptw_walks_store ? end.ptw_walks_store - start.ptw_walks_store : 0;
    r.ptw_walks_amo = end.ptw_walks_amo >= start.ptw_walks_amo ? end.ptw_walks_amo - start.ptw_walks_amo : 0;
    r.ptw_cycles_total = end.ptw_cycles_total >= start.ptw_cycles_total ? end.ptw_cycles_total - start.ptw_cycles_total : 0;
    r.ptw_cycles_insn = end.ptw_cycles_insn >= start.ptw_cycles_insn ? end.ptw_cycles_insn - start.ptw_cycles_insn : 0;
    r.ptw_cycles_data = end.ptw_cycles_data >= start.ptw_cycles_data ? end.ptw_cycles_data - start.ptw_cycles_data : 0;
    r.ptw_memory_accesses = end.ptw_memory_accesses >= start.ptw_memory_accesses ? end.ptw_memory_accesses - start.ptw_memory_accesses : 0;
    r.itlb_hit_count = end.itlb_hit_count >= start.itlb_hit_count ? end.itlb_hit_count - start.itlb_hit_count : 0;
    r.itlb_miss_count = end.itlb_miss_count >= start.itlb_miss_count ? end.itlb_miss_count - start.itlb_miss_count : 0;
    r.itlb_refill_count = end.itlb_refill_count >= start.itlb_refill_count ? end.itlb_refill_count - start.itlb_refill_count : 0;
    r.dtlb_hit_count = end.dtlb_hit_count >= start.dtlb_hit_count ? end.dtlb_hit_count - start.dtlb_hit_count : 0;
    r.dtlb_miss_count = end.dtlb_miss_count >= start.dtlb_miss_count ? end.dtlb_miss_count - start.dtlb_miss_count : 0;
    r.dtlb_refill_count = end.dtlb_refill_count >= start.dtlb_refill_count ? end.dtlb_refill_count - start.dtlb_refill_count : 0;
    r.l1i_hit_count = end.l1i_hit_count >= start.l1i_hit_count ? end.l1i_hit_count - start.l1i_hit_count : 0;
    r.l1i_miss_count = end.l1i_miss_count >= start.l1i_miss_count ? end.l1i_miss_count - start.l1i_miss_count : 0;
    r.l1i_refill_count = end.l1i_refill_count >= start.l1i_refill_count ? end.l1i_refill_count - start.l1i_refill_count : 0;
    r.l1i_early_restart_count = end.l1i_early_restart_count >= start.l1i_early_restart_count ? end.l1i_early_restart_count - start.l1i_early_restart_count : 0;
    r.l1i_streaming_hit_count = end.l1i_streaming_hit_count >= start.l1i_streaming_hit_count ? end.l1i_streaming_hit_count - start.l1i_streaming_hit_count : 0;
    r.l1i_refill_abort_count = end.l1i_refill_abort_count >= start.l1i_refill_abort_count ? end.l1i_refill_abort_count - start.l1i_refill_abort_count : 0;
    r.l1i_nlp_candidate_events = end.l1i_nlp_candidate_events >= start.l1i_nlp_candidate_events ? end.l1i_nlp_candidate_events - start.l1i_nlp_candidate_events : 0;
    r.l1i_nlp_issued_events = end.l1i_nlp_issued_events >= start.l1i_nlp_issued_events ? end.l1i_nlp_issued_events - start.l1i_nlp_issued_events : 0;
    r.l1i_nlp_suppressed_page_events = end.l1i_nlp_suppressed_page_events >= start.l1i_nlp_suppressed_page_events ? end.l1i_nlp_suppressed_page_events - start.l1i_nlp_suppressed_page_events : 0;
    r.l1i_nlp_suppressed_pmp_events = end.l1i_nlp_suppressed_pmp_events >= start.l1i_nlp_suppressed_pmp_events ? end.l1i_nlp_suppressed_pmp_events - start.l1i_nlp_suppressed_pmp_events : 0;
    r.l1i_nlp_suppressed_resident_events = end.l1i_nlp_suppressed_resident_events >= start.l1i_nlp_suppressed_resident_events ? end.l1i_nlp_suppressed_resident_events - start.l1i_nlp_suppressed_resident_events : 0;
    r.l1i_nlp_suppressed_duplicate_events = end.l1i_nlp_suppressed_duplicate_events >= start.l1i_nlp_suppressed_duplicate_events ? end.l1i_nlp_suppressed_duplicate_events - start.l1i_nlp_suppressed_duplicate_events : 0;
    r.l1i_nlp_useful_hit_events = end.l1i_nlp_useful_hit_events >= start.l1i_nlp_useful_hit_events ? end.l1i_nlp_useful_hit_events - start.l1i_nlp_useful_hit_events : 0;
    r.l1i_nlp_streaming_hit_events = end.l1i_nlp_streaming_hit_events >= start.l1i_nlp_streaming_hit_events ? end.l1i_nlp_streaming_hit_events - start.l1i_nlp_streaming_hit_events : 0;
    r.l1i_nlp_preempted_events = end.l1i_nlp_preempted_events >= start.l1i_nlp_preempted_events ? end.l1i_nlp_preempted_events - start.l1i_nlp_preempted_events : 0;
    r.l1i_nlp_dormant_abandon_events = end.l1i_nlp_dormant_abandon_events >= start.l1i_nlp_dormant_abandon_events ? end.l1i_nlp_dormant_abandon_events - start.l1i_nlp_dormant_abandon_events : 0;
    r.l1i_nlp_discard_redirect_events = end.l1i_nlp_discard_redirect_events >= start.l1i_nlp_discard_redirect_events ? end.l1i_nlp_discard_redirect_events - start.l1i_nlp_discard_redirect_events : 0;
    r.l1i_nlp_discard_maint_events = end.l1i_nlp_discard_maint_events >= start.l1i_nlp_discard_maint_events ? end.l1i_nlp_discard_maint_events - start.l1i_nlp_discard_maint_events : 0;
    r.l1i_nlp_discard_error_events = end.l1i_nlp_discard_error_events >= start.l1i_nlp_discard_error_events ? end.l1i_nlp_discard_error_events - start.l1i_nlp_discard_error_events : 0;
    r.l1i_nlp_promote_events = end.l1i_nlp_promote_events >= start.l1i_nlp_promote_events ? end.l1i_nlp_promote_events - start.l1i_nlp_promote_events : 0;
    r.l1i_nlp_hidden_cycles_total = end.l1i_nlp_hidden_cycles_total >= start.l1i_nlp_hidden_cycles_total ? end.l1i_nlp_hidden_cycles_total - start.l1i_nlp_hidden_cycles_total : 0;
    r.l1d_hit_count = end.l1d_hit_count >= start.l1d_hit_count ? end.l1d_hit_count - start.l1d_hit_count : 0;
    r.l1d_miss_count = end.l1d_miss_count >= start.l1d_miss_count ? end.l1d_miss_count - start.l1d_miss_count : 0;
    r.l1d_refill_count = end.l1d_refill_count >= start.l1d_refill_count ? end.l1d_refill_count - start.l1d_refill_count : 0;
    r.l1d_evict_count = end.l1d_evict_count >= start.l1d_evict_count ? end.l1d_evict_count - start.l1d_evict_count : 0;
    r.l1d_load_hit_count = end.l1d_load_hit_count >= start.l1d_load_hit_count ? end.l1d_load_hit_count - start.l1d_load_hit_count : 0;
    r.l1d_load_miss_count = end.l1d_load_miss_count >= start.l1d_load_miss_count ? end.l1d_load_miss_count - start.l1d_load_miss_count : 0;
    r.l1d_store_hit_count = end.l1d_store_hit_count >= start.l1d_store_hit_count ? end.l1d_store_hit_count - start.l1d_store_hit_count : 0;
    r.l1d_store_miss_count = end.l1d_store_miss_count >= start.l1d_store_miss_count ? end.l1d_store_miss_count - start.l1d_store_miss_count : 0;
    r.l1d_er_events = end.l1d_er_events >= start.l1d_er_events ? end.l1d_er_events - start.l1d_er_events : 0;
    r.l1d_er_saved_cycles_total = end.l1d_er_saved_cycles_total >= start.l1d_er_saved_cycles_total ? end.l1d_er_saved_cycles_total - start.l1d_er_saved_cycles_total : 0;
    r.l1d_er_trailing_active_cycles = end.l1d_er_trailing_active_cycles >= start.l1d_er_trailing_active_cycles ? end.l1d_er_trailing_active_cycles - start.l1d_er_trailing_active_cycles : 0;
    r.l1d_er_trailing_useful_commit_cycles = end.l1d_er_trailing_useful_commit_cycles >= start.l1d_er_trailing_useful_commit_cycles ? end.l1d_er_trailing_useful_commit_cycles - start.l1d_er_trailing_useful_commit_cycles : 0;
    r.l1d_er_trailing_blocked_load_cycles = end.l1d_er_trailing_blocked_load_cycles >= start.l1d_er_trailing_blocked_load_cycles ? end.l1d_er_trailing_blocked_load_cycles - start.l1d_er_trailing_blocked_load_cycles : 0;
    r.l1d_er_trailing_blocked_store_cycles = end.l1d_er_trailing_blocked_store_cycles >= start.l1d_er_trailing_blocked_store_cycles ? end.l1d_er_trailing_blocked_store_cycles - start.l1d_er_trailing_blocked_store_cycles : 0;
    r.l1d_er_trailing_blocked_serialization_cycles = end.l1d_er_trailing_blocked_serialization_cycles >= start.l1d_er_trailing_blocked_serialization_cycles ? end.l1d_er_trailing_blocked_serialization_cycles - start.l1d_er_trailing_blocked_serialization_cycles : 0;
    r.l1d_er_trailing_other_zero_retire_cycles = end.l1d_er_trailing_other_zero_retire_cycles >= start.l1d_er_trailing_other_zero_retire_cycles ? end.l1d_er_trailing_other_zero_retire_cycles - start.l1d_er_trailing_other_zero_retire_cycles : 0;
    r.l1d_er_trailing_sb_nonempty_cycles = end.l1d_er_trailing_sb_nonempty_cycles >= start.l1d_er_trailing_sb_nonempty_cycles ? end.l1d_er_trailing_sb_nonempty_cycles - start.l1d_er_trailing_sb_nonempty_cycles : 0;
    r.l1d_er_trailing_sb_full_cycles = end.l1d_er_trailing_sb_full_cycles >= start.l1d_er_trailing_sb_full_cycles ? end.l1d_er_trailing_sb_full_cycles - start.l1d_er_trailing_sb_full_cycles : 0;
    r.l1d_refill_error_edge_cycles = end.l1d_refill_error_edge_cycles >= start.l1d_refill_error_edge_cycles ? end.l1d_refill_error_edge_cycles - start.l1d_refill_error_edge_cycles : 0;
    r.fatal_halt_cycles = end.fatal_halt_cycles >= start.fatal_halt_cycles ? end.fatal_halt_cycles - start.fatal_halt_cycles : 0;
    r.sbi_ecall_count = end.sbi_ecall_count >= start.sbi_ecall_count ? end.sbi_ecall_count - start.sbi_ecall_count : 0;
    r.user_ecall_count = end.user_ecall_count >= start.user_ecall_count ? end.user_ecall_count - start.user_ecall_count : 0;
    r.mtip_count = end.mtip_count >= start.mtip_count ? end.mtip_count - start.mtip_count : 0;
    r.stip_count = end.stip_count >= start.stip_count ? end.stip_count - start.stip_count : 0;
    r.seip_count = end.seip_count >= start.seip_count ? end.seip_count - start.seip_count : 0;
    r.sync_trap_count = end.sync_trap_count >= start.sync_trap_count ? end.sync_trap_count - start.sync_trap_count : 0;
    r.trap_overhead_cycles = end.trap_overhead_cycles >= start.trap_overhead_cycles ? end.trap_overhead_cycles - start.trap_overhead_cycles : 0;

    r.cycles_useful_retire = end.cycles_useful_retire >= start.cycles_useful_retire ? end.cycles_useful_retire - start.cycles_useful_retire : 0;
    r.cycles_zero_retire = end.cycles_zero_retire >= start.cycles_zero_retire ? end.cycles_zero_retire - start.cycles_zero_retire : 0;
    r.cycles_l1i_miss_refill = end.cycles_l1i_miss_refill >= start.cycles_l1i_miss_refill ? end.cycles_l1i_miss_refill - start.cycles_l1i_miss_refill : 0;
    r.cycles_l1i_hit_fetch_stall = end.cycles_l1i_hit_fetch_stall >= start.cycles_l1i_hit_fetch_stall ? end.cycles_l1i_hit_fetch_stall - start.cycles_l1i_hit_fetch_stall : 0;
    r.cycles_lsu_stall = end.cycles_lsu_stall >= start.cycles_lsu_stall ? end.cycles_lsu_stall - start.cycles_lsu_stall : 0;
    r.cycles_lsu_issue_stall = end.cycles_lsu_issue_stall >= start.cycles_lsu_issue_stall ? end.cycles_lsu_issue_stall - start.cycles_lsu_issue_stall : 0;
    r.cycles_lsu_mem_rsp_wait = end.cycles_lsu_mem_rsp_wait >= start.cycles_lsu_mem_rsp_wait ? end.cycles_lsu_mem_rsp_wait - start.cycles_lsu_mem_rsp_wait : 0;
    r.cycles_lsu_amo_wait = end.cycles_lsu_amo_wait >= start.cycles_lsu_amo_wait ? end.cycles_lsu_amo_wait - start.cycles_lsu_amo_wait : 0;
    r.cycles_load_stall = end.cycles_load_stall >= start.cycles_load_stall ? end.cycles_load_stall - start.cycles_load_stall : 0;
    r.cycles_store_stall = end.cycles_store_stall >= start.cycles_store_stall ? end.cycles_store_stall - start.cycles_store_stall : 0;
    r.cycles_amo_lr_sc_stall = end.cycles_amo_lr_sc_stall >= start.cycles_amo_lr_sc_stall ? end.cycles_amo_lr_sc_stall - start.cycles_amo_lr_sc_stall : 0;
    r.cycles_ptw_stall = end.cycles_ptw_stall >= start.cycles_ptw_stall ? end.cycles_ptw_stall - start.cycles_ptw_stall : 0;
    r.cycles_itlb_ptw_stall = end.cycles_itlb_ptw_stall >= start.cycles_itlb_ptw_stall ? end.cycles_itlb_ptw_stall - start.cycles_itlb_ptw_stall : 0;
    r.cycles_dtlb_ptw_stall = end.cycles_dtlb_ptw_stall >= start.cycles_dtlb_ptw_stall ? end.cycles_dtlb_ptw_stall - start.cycles_dtlb_ptw_stall : 0;
    r.cycles_itlb_translation_latency = end.cycles_itlb_translation_latency >= start.cycles_itlb_translation_latency ? end.cycles_itlb_translation_latency - start.cycles_itlb_translation_latency : 0;
    r.cycles_branch_redirect_bubble = end.cycles_branch_redirect_bubble >= start.cycles_branch_redirect_bubble ? end.cycles_branch_redirect_bubble - start.cycles_branch_redirect_bubble : 0;
    r.cycles_csr_serialization_flush = end.cycles_csr_serialization_flush >= start.cycles_csr_serialization_flush ? end.cycles_csr_serialization_flush - start.cycles_csr_serialization_flush : 0;
    r.cycles_trap_entry_drain = end.cycles_trap_entry_drain >= start.cycles_trap_entry_drain ? end.cycles_trap_entry_drain - start.cycles_trap_entry_drain : 0;
    r.cycles_trap_vector_bubble = end.cycles_trap_vector_bubble >= start.cycles_trap_vector_bubble ? end.cycles_trap_vector_bubble - start.cycles_trap_vector_bubble : 0;
    r.cycles_mret_sret_redirect_bubble = end.cycles_mret_sret_redirect_bubble >= start.cycles_mret_sret_redirect_bubble ? end.cycles_mret_sret_redirect_bubble - start.cycles_mret_sret_redirect_bubble : 0;
    r.cycles_sfence_vma_serialization = end.cycles_sfence_vma_serialization >= start.cycles_sfence_vma_serialization ? end.cycles_sfence_vma_serialization - start.cycles_sfence_vma_serialization : 0;
    r.cycles_fence_i_serialization = end.cycles_fence_i_serialization >= start.cycles_fence_i_serialization ? end.cycles_fence_i_serialization - start.cycles_fence_i_serialization : 0;
    r.cycles_refill_handoff_bubble = end.cycles_refill_handoff_bubble >= start.cycles_refill_handoff_bubble ? end.cycles_refill_handoff_bubble - start.cycles_refill_handoff_bubble : 0;
    r.cycles_residual_unclassified = end.cycles_residual_unclassified >= start.cycles_residual_unclassified ? end.cycles_residual_unclassified - start.cycles_residual_unclassified : 0;

    r.cycles_load_hit_latency = end.cycles_load_hit_latency >= start.cycles_load_hit_latency ? end.cycles_load_hit_latency - start.cycles_load_hit_latency : 0;
    r.cycles_load_clean_refill = end.cycles_load_clean_refill >= start.cycles_load_clean_refill ? end.cycles_load_clean_refill - start.cycles_load_clean_refill : 0;
    r.cycles_load_dirty_evict = end.cycles_load_dirty_evict >= start.cycles_load_dirty_evict ? end.cycles_load_dirty_evict - start.cycles_load_dirty_evict : 0;
    r.cycles_load_dirty_refill = end.cycles_load_dirty_refill >= start.cycles_load_dirty_refill ? end.cycles_load_dirty_refill - start.cycles_load_dirty_refill : 0;

    r.cycles_store_hit_latency = end.cycles_store_hit_latency >= start.cycles_store_hit_latency ? end.cycles_store_hit_latency - start.cycles_store_hit_latency : 0;
    r.cycles_store_clean_refill = end.cycles_store_clean_refill >= start.cycles_store_clean_refill ? end.cycles_store_clean_refill - start.cycles_store_clean_refill : 0;
    r.cycles_store_dirty_evict = end.cycles_store_dirty_evict >= start.cycles_store_dirty_evict ? end.cycles_store_dirty_evict - start.cycles_store_dirty_evict : 0;
    r.cycles_store_dirty_refill = end.cycles_store_dirty_refill >= start.cycles_store_dirty_refill ? end.cycles_store_dirty_refill - start.cycles_store_dirty_refill : 0;

    r.cycles_maint_sfence_vma = end.cycles_maint_sfence_vma >= start.cycles_maint_sfence_vma ? end.cycles_maint_sfence_vma - start.cycles_maint_sfence_vma : 0;
    r.cycles_maint_fence_i = end.cycles_maint_fence_i >= start.cycles_maint_fence_i ? end.cycles_maint_fence_i - start.cycles_maint_fence_i : 0;
    r.cycles_maint_pmp = end.cycles_maint_pmp >= start.cycles_maint_pmp ? end.cycles_maint_pmp - start.cycles_maint_pmp : 0;

    r.cycles_mmio_stall = end.cycles_mmio_stall >= start.cycles_mmio_stall ? end.cycles_mmio_stall - start.cycles_mmio_stall : 0;
    r.cycles_arbitration_contention = end.cycles_arbitration_contention >= start.cycles_arbitration_contention ? end.cycles_arbitration_contention - start.cycles_arbitration_contention : 0;

    r.fetch_req_wait_cycles = end.fetch_req_wait_cycles >= start.fetch_req_wait_cycles ? end.fetch_req_wait_cycles - start.fetch_req_wait_cycles : 0;
    r.fetch_rsp_wait_cycles = end.fetch_rsp_wait_cycles >= start.fetch_rsp_wait_cycles ? end.fetch_rsp_wait_cycles - start.fetch_rsp_wait_cycles : 0;
    r.cycles_lsu_req_wait = end.cycles_lsu_req_wait >= start.cycles_lsu_req_wait ? end.cycles_lsu_req_wait - start.cycles_lsu_req_wait : 0;
    r.cycles_lsu_rsp_wait = end.cycles_lsu_rsp_wait >= start.cycles_lsu_rsp_wait ? end.cycles_lsu_rsp_wait - start.cycles_lsu_rsp_wait : 0;
    r.cycles_lsu_amo_wait = end.cycles_lsu_amo_wait >= start.cycles_lsu_amo_wait ? end.cycles_lsu_amo_wait - start.cycles_lsu_amo_wait : 0;

    r.trans_imem_req = end.trans_imem_req >= start.trans_imem_req ? end.trans_imem_req - start.trans_imem_req : 0;
    r.trans_dmem_load = end.trans_dmem_load >= start.trans_dmem_load ? end.trans_dmem_load - start.trans_dmem_load : 0;
    r.trans_dmem_store = end.trans_dmem_store >= start.trans_dmem_store ? end.trans_dmem_store - start.trans_dmem_store : 0;
    r.trans_ptw_req = end.trans_ptw_req >= start.trans_ptw_req ? end.trans_ptw_req - start.trans_ptw_req : 0;
    r.trans_clint_mmio = end.trans_clint_mmio >= start.trans_clint_mmio ? end.trans_clint_mmio - start.trans_clint_mmio : 0;
    r.trans_plic_mmio = end.trans_plic_mmio >= start.trans_plic_mmio ? end.trans_plic_mmio - start.trans_plic_mmio : 0;
    r.trans_uart_mmio = end.trans_uart_mmio >= start.trans_uart_mmio ? end.trans_uart_mmio - start.trans_uart_mmio : 0;

    r.insn_alu_count = end.insn_alu_count >= start.insn_alu_count ? end.insn_alu_count - start.insn_alu_count : 0;
    r.insn_load_count = end.insn_load_count >= start.insn_load_count ? end.insn_load_count - start.insn_load_count : 0;
    r.insn_store_count = end.insn_store_count >= start.insn_store_count ? end.insn_store_count - start.insn_store_count : 0;
    r.insn_amo_count = end.insn_amo_count >= start.insn_amo_count ? end.insn_amo_count - start.insn_amo_count : 0;
    r.insn_branch_cond_count = end.insn_branch_cond_count >= start.insn_branch_cond_count ? end.insn_branch_cond_count - start.insn_branch_cond_count : 0;
    r.insn_jal_count = end.insn_jal_count >= start.insn_jal_count ? end.insn_jal_count - start.insn_jal_count : 0;
    r.insn_jalr_count = end.insn_jalr_count >= start.insn_jalr_count ? end.insn_jalr_count - start.insn_jalr_count : 0;
    r.insn_system_count = end.insn_system_count >= start.insn_system_count ? end.insn_system_count - start.insn_system_count : 0;
    r.branch_taken_count = end.branch_taken_count >= start.branch_taken_count ? end.branch_taken_count - start.branch_taken_count : 0;
    r.branch_untaken_count = end.branch_untaken_count >= start.branch_untaken_count ? end.branch_untaken_count - start.branch_untaken_count : 0;

    r.uart_access_count = end.uart_access_count >= start.uart_access_count ? end.uart_access_count - start.uart_access_count : 0;

    r.cycles_sb_full_stall = end.cycles_sb_full_stall >= start.cycles_sb_full_stall ? end.cycles_sb_full_stall - start.cycles_sb_full_stall : 0;
    r.cycles_sb_raw_load_stall = end.cycles_sb_raw_load_stall >= start.cycles_sb_raw_load_stall ? end.cycles_sb_raw_load_stall - start.cycles_sb_raw_load_stall : 0;
    r.cycles_srb_raw_load_stall = end.cycles_srb_raw_load_stall >= start.cycles_srb_raw_load_stall ? end.cycles_srb_raw_load_stall - start.cycles_srb_raw_load_stall : 0;
    r.cycles_sb_arbitration_load_stall = end.cycles_sb_arbitration_load_stall >= start.cycles_sb_arbitration_load_stall ? end.cycles_sb_arbitration_load_stall - start.cycles_sb_arbitration_load_stall : 0;
    r.cycles_l1d_load_structural_arb_stall = end.cycles_l1d_load_structural_arb_stall >= start.cycles_l1d_load_structural_arb_stall ? end.cycles_l1d_load_structural_arb_stall - start.cycles_l1d_load_structural_arb_stall : 0;
    r.cycles_srb_install_bubble_stall = end.cycles_srb_install_bubble_stall >= start.cycles_srb_install_bubble_stall ? end.cycles_srb_install_bubble_stall - start.cycles_srb_install_bubble_stall : 0;
    r.cycles_l1d_load_clean_miss_refill_stall = end.cycles_l1d_load_clean_miss_refill_stall >= start.cycles_l1d_load_clean_miss_refill_stall ? end.cycles_l1d_load_clean_miss_refill_stall - start.cycles_l1d_load_clean_miss_refill_stall : 0;
    r.cycles_l1d_load_dirty_evict_stall = end.cycles_l1d_load_dirty_evict_stall >= start.cycles_l1d_load_dirty_evict_stall ? end.cycles_l1d_load_dirty_evict_stall - start.cycles_l1d_load_dirty_evict_stall : 0;
    r.cycles_l1d_load_dirty_refill_stall = end.cycles_l1d_load_dirty_refill_stall >= start.cycles_l1d_load_dirty_refill_stall ? end.cycles_l1d_load_dirty_refill_stall - start.cycles_l1d_load_dirty_refill_stall : 0;
    r.cycles_srb_sec_load_stall = end.cycles_srb_sec_load_stall >= start.cycles_srb_sec_load_stall ? end.cycles_srb_sec_load_stall - start.cycles_srb_sec_load_stall : 0;
    r.cycles_sb_drain_visible_stall = end.cycles_sb_drain_visible_stall >= start.cycles_sb_drain_visible_stall ? end.cycles_sb_drain_visible_stall - start.cycles_sb_drain_visible_stall : 0;

    r.lat_clean_miss_count = end.lat_clean_miss_count >= start.lat_clean_miss_count ? end.lat_clean_miss_count - start.lat_clean_miss_count : 0;
    r.lat_clean_miss_total = end.lat_clean_miss_total >= start.lat_clean_miss_total ? end.lat_clean_miss_total - start.lat_clean_miss_total : 0;
    r.lat_clean_miss_min = end.lat_clean_miss_min != UINT64_MAX ? end.lat_clean_miss_min : 0;
    r.lat_clean_miss_max = end.lat_clean_miss_max;

    r.lat_dirty_evict_count = end.lat_dirty_evict_count >= start.lat_dirty_evict_count ? end.lat_dirty_evict_count - start.lat_dirty_evict_count : 0;
    r.lat_dirty_evict_total = end.lat_dirty_evict_total >= start.lat_dirty_evict_total ? end.lat_dirty_evict_total - start.lat_dirty_evict_total : 0;
    r.lat_dirty_evict_min = end.lat_dirty_evict_min != UINT64_MAX ? end.lat_dirty_evict_min : 0;
    r.lat_dirty_evict_max = end.lat_dirty_evict_max;

    r.lat_dirty_refill_count = end.lat_dirty_refill_count >= start.lat_dirty_refill_count ? end.lat_dirty_refill_count - start.lat_dirty_refill_count : 0;
    r.lat_dirty_refill_total = end.lat_dirty_refill_total >= start.lat_dirty_refill_total ? end.lat_dirty_refill_total - start.lat_dirty_refill_total : 0;
    r.lat_dirty_refill_min = end.lat_dirty_refill_min != UINT64_MAX ? end.lat_dirty_refill_min : 0;
    r.lat_dirty_refill_max = end.lat_dirty_refill_max;

    r.lat_dirty_total_count = end.lat_dirty_total_count >= start.lat_dirty_total_count ? end.lat_dirty_total_count - start.lat_dirty_total_count : 0;
    r.lat_dirty_total_cycles = end.lat_dirty_total_cycles >= start.lat_dirty_total_cycles ? end.lat_dirty_total_cycles - start.lat_dirty_total_cycles : 0;
    r.lat_dirty_total_min = end.lat_dirty_total_min != UINT64_MAX ? end.lat_dirty_total_min : 0;
    r.lat_dirty_total_max = end.lat_dirty_total_max;

    r.lat_install_count = end.lat_install_count >= start.lat_install_count ? end.lat_install_count - start.lat_install_count : 0;
    r.lat_install_total = end.lat_install_total >= start.lat_install_total ? end.lat_install_total - start.lat_install_total : 0;
    r.lat_install_min = end.lat_install_min != UINT64_MAX ? end.lat_install_min : 0;
    r.lat_install_max = end.lat_install_max;

    r.lat_sb_drain_collision_count = end.lat_sb_drain_collision_count >= start.lat_sb_drain_collision_count ? end.lat_sb_drain_collision_count - start.lat_sb_drain_collision_count : 0;
    r.lat_sb_drain_collision_total = end.lat_sb_drain_collision_total >= start.lat_sb_drain_collision_total ? end.lat_sb_drain_collision_total - start.lat_sb_drain_collision_total : 0;
    r.lat_sb_drain_collision_min = end.lat_sb_drain_collision_min != UINT64_MAX ? end.lat_sb_drain_collision_min : 0;
    r.lat_sb_drain_collision_max = end.lat_sb_drain_collision_max;

    r.srb_active_cycles = end.srb_active_cycles >= start.srb_active_cycles ? end.srb_active_cycles - start.srb_active_cycles : 0;
    r.srb_installs = end.srb_installs >= start.srb_installs ? end.srb_installs - start.srb_installs : 0;
    r.srb_clean_victims = end.srb_clean_victims >= start.srb_clean_victims ? end.srb_clean_victims - start.srb_clean_victims : 0;
    r.srb_dirty_victims = end.srb_dirty_victims >= start.srb_dirty_victims ? end.srb_dirty_victims - start.srb_dirty_victims : 0;

    r.sb_total_ordinary_stores = end.sb_total_ordinary_stores >= start.sb_total_ordinary_stores ? end.sb_total_ordinary_stores - start.sb_total_ordinary_stores : 0;
    r.sb_enqueues = end.sb_enqueues >= start.sb_enqueues ? end.sb_enqueues - start.sb_enqueues : 0;
    r.sb_tail_merges = end.sb_tail_merges >= start.sb_tail_merges ? end.sb_tail_merges - start.sb_tail_merges : 0;
    r.sb_max_occupancy = std::max(end.sb_max_occupancy, start.sb_max_occupancy);
    for (int i = 0; i < 9; i++) {
        r.sb_occ_cycles[i] = end.sb_occ_cycles[i] >= start.sb_occ_cycles[i] ? end.sb_occ_cycles[i] - start.sb_occ_cycles[i] : 0;
    }
    r.sb_full_stall_cycles = end.sb_full_stall_cycles >= start.sb_full_stall_cycles ? end.sb_full_stall_cycles - start.sb_full_stall_cycles : 0;
    r.sb_raw_conflict_stall_cycles = end.sb_raw_conflict_stall_cycles >= start.sb_raw_conflict_stall_cycles ? end.sb_raw_conflict_stall_cycles - start.sb_raw_conflict_stall_cycles : 0;
    r.sb_drain_requests = end.sb_drain_requests >= start.sb_drain_requests ? end.sb_drain_requests - start.sb_drain_requests : 0;
    r.sb_drain_completions = end.sb_drain_completions >= start.sb_drain_completions ? end.sb_drain_completions - start.sb_drain_completions : 0;
    r.sb_drain_hits = end.sb_drain_hits >= start.sb_drain_hits ? end.sb_drain_hits - start.sb_drain_hits : 0;
    r.sb_drain_clean_misses = end.sb_drain_clean_misses >= start.sb_drain_clean_misses ? end.sb_drain_clean_misses - start.sb_drain_clean_misses : 0;
    r.sb_drain_dirty_misses = end.sb_drain_dirty_misses >= start.sb_drain_dirty_misses ? end.sb_drain_dirty_misses - start.sb_drain_dirty_misses : 0;
    r.sb_hidden_drain_cycles = end.sb_hidden_drain_cycles >= start.sb_hidden_drain_cycles ? end.sb_hidden_drain_cycles - start.sb_hidden_drain_cycles : 0;
    r.sb_total_drain_latency_cycles = end.sb_total_drain_latency_cycles >= start.sb_total_drain_latency_cycles ? end.sb_total_drain_latency_cycles - start.sb_total_drain_latency_cycles : 0;

    r.sb_full_episodes = end.sb_full_episodes >= start.sb_full_episodes ? end.sb_full_episodes - start.sb_full_episodes : 0;
    r.sb_full_consecutive_cycles_total = end.sb_full_consecutive_cycles_total >= start.sb_full_consecutive_cycles_total ? end.sb_full_consecutive_cycles_total - start.sb_full_consecutive_cycles_total : 0;
    r.sb_full_consecutive_cycles_min = end.sb_full_consecutive_cycles_min != UINT64_MAX ? end.sb_full_consecutive_cycles_min : 0;
    r.sb_full_consecutive_cycles_max = end.sb_full_consecutive_cycles_max;
    for (int i = 0; i < 6; i++) {
        r.sb_full_duration_buckets[i] = end.sb_full_duration_buckets[i] >= start.sb_full_duration_buckets[i] ? end.sb_full_duration_buckets[i] - start.sb_full_duration_buckets[i] : 0;
    }
    r.sb_full_drain_completions = end.sb_full_drain_completions >= start.sb_full_drain_completions ? end.sb_full_drain_completions - start.sb_full_drain_completions : 0;
    r.sb_full_blocked_l1d_busy = end.sb_full_blocked_l1d_busy >= start.sb_full_blocked_l1d_busy ? end.sb_full_blocked_l1d_busy - start.sb_full_blocked_l1d_busy : 0;
    r.sb_full_blocked_srb_busy = end.sb_full_blocked_srb_busy >= start.sb_full_blocked_srb_busy ? end.sb_full_blocked_srb_busy - start.sb_full_blocked_srb_busy : 0;
    r.sb_full_blocked_dram_bus = end.sb_full_blocked_dram_bus >= start.sb_full_blocked_dram_bus ? end.sb_full_blocked_dram_bus - start.sb_full_blocked_dram_bus : 0;
    r.sb_full_hit_drain_active = end.sb_full_hit_drain_active >= start.sb_full_hit_drain_active ? end.sb_full_hit_drain_active - start.sb_full_hit_drain_active : 0;
    r.sb_full_coalesce_same_dword_cycles = end.sb_full_coalesce_same_dword_cycles >= start.sb_full_coalesce_same_dword_cycles ? end.sb_full_coalesce_same_dword_cycles - start.sb_full_coalesce_same_dword_cycles : 0;
    r.sb_full_coalesce_exact_addr_cycles = end.sb_full_coalesce_exact_addr_cycles >= start.sb_full_coalesce_exact_addr_cycles ? end.sb_full_coalesce_exact_addr_cycles - start.sb_full_coalesce_exact_addr_cycles : 0;
    r.shadow_sb_full_stall_cycles_d10 = end.shadow_sb_full_stall_cycles_d10 >= start.shadow_sb_full_stall_cycles_d10 ? end.shadow_sb_full_stall_cycles_d10 - start.shadow_sb_full_stall_cycles_d10 : 0;
    r.shadow_sb_full_stall_cycles_d12 = end.shadow_sb_full_stall_cycles_d12 >= start.shadow_sb_full_stall_cycles_d12 ? end.shadow_sb_full_stall_cycles_d12 - start.shadow_sb_full_stall_cycles_d12 : 0;
    r.shadow_sb_full_stall_cycles_d16 = end.shadow_sb_full_stall_cycles_d16 >= start.shadow_sb_full_stall_cycles_d16 ? end.shadow_sb_full_stall_cycles_d16 - start.shadow_sb_full_stall_cycles_d16 : 0;

    r.l1i_demand_refills_total = end.l1i_demand_refills_total >= start.l1i_demand_refills_total ? end.l1i_demand_refills_total - start.l1i_demand_refills_total : 0;
    r.l1i_seq_next_line_refills = end.l1i_seq_next_line_refills >= start.l1i_seq_next_line_refills ? end.l1i_seq_next_line_refills - start.l1i_seq_next_line_refills : 0;
    r.l1i_nlp_same_page_candidates = end.l1i_nlp_same_page_candidates >= start.l1i_nlp_same_page_candidates ? end.l1i_nlp_same_page_candidates - start.l1i_nlp_same_page_candidates : 0;
    r.l1i_nlp_already_cached_filtered = end.l1i_nlp_already_cached_filtered >= start.l1i_nlp_already_cached_filtered ? end.l1i_nlp_already_cached_filtered - start.l1i_nlp_already_cached_filtered : 0;
    r.l1i_nlp_issued_candidates = end.l1i_nlp_issued_candidates >= start.l1i_nlp_issued_candidates ? end.l1i_nlp_issued_candidates - start.l1i_nlp_issued_candidates : 0;
    r.l1i_nlp_useful_prefetches = end.l1i_nlp_useful_prefetches >= start.l1i_nlp_useful_prefetches ? end.l1i_nlp_useful_prefetches - start.l1i_nlp_useful_prefetches : 0;
    r.l1i_nlp_useless_prefetches = end.l1i_nlp_useless_prefetches >= start.l1i_nlp_useless_prefetches ? end.l1i_nlp_useless_prefetches - start.l1i_nlp_useless_prefetches : 0;
    r.l1i_nlp_lead_time_min = end.l1i_nlp_lead_time_min != UINT64_MAX ? end.l1i_nlp_lead_time_min : 0;
    r.l1i_nlp_lead_time_max = end.l1i_nlp_lead_time_max;
    r.l1i_nlp_lead_time_total = end.l1i_nlp_lead_time_total >= start.l1i_nlp_lead_time_total ? end.l1i_nlp_lead_time_total - start.l1i_nlp_lead_time_total : 0;
    for (int i = 0; i < 4; i++) {
        r.l1i_nlp_lead_time_buckets[i] = end.l1i_nlp_lead_time_buckets[i] >= start.l1i_nlp_lead_time_buckets[i] ? end.l1i_nlp_lead_time_buckets[i] - start.l1i_nlp_lead_time_buckets[i] : 0;
    }
    r.l1i_nlp_cycles_hidden = end.l1i_nlp_cycles_hidden >= start.l1i_nlp_cycles_hidden ? end.l1i_nlp_cycles_hidden - start.l1i_nlp_cycles_hidden : 0;
    r.l1i_nlp_bus_idle_cycles = end.l1i_nlp_bus_idle_cycles >= start.l1i_nlp_bus_idle_cycles ? end.l1i_nlp_bus_idle_cycles - start.l1i_nlp_bus_idle_cycles : 0;
    r.l1i_nlp_bus_conflicts_l1d = end.l1i_nlp_bus_conflicts_l1d >= start.l1i_nlp_bus_conflicts_l1d ? end.l1i_nlp_bus_conflicts_l1d - start.l1i_nlp_bus_conflicts_l1d : 0;
    r.l1i_nlp_redirects_before_use = end.l1i_nlp_redirects_before_use >= start.l1i_nlp_redirects_before_use ? end.l1i_nlp_redirects_before_use - start.l1i_nlp_redirects_before_use : 0;

    r.raw_sb_exact_dword_match_cycles = end.raw_sb_exact_dword_match_cycles >= start.raw_sb_exact_dword_match_cycles ? end.raw_sb_exact_dword_match_cycles - start.raw_sb_exact_dword_match_cycles : 0;
    r.raw_sb_single_entry_full_cov_cycles = end.raw_sb_single_entry_full_cov_cycles >= start.raw_sb_single_entry_full_cov_cycles ? end.raw_sb_single_entry_full_cov_cycles - start.raw_sb_single_entry_full_cov_cycles : 0;
    r.raw_sb_multi_entry_merge_cycles = end.raw_sb_multi_entry_merge_cycles >= start.raw_sb_multi_entry_merge_cycles ? end.raw_sb_multi_entry_merge_cycles - start.raw_sb_multi_entry_merge_cycles : 0;
    r.raw_sb_partial_overlap_cycles = end.raw_sb_partial_overlap_cycles >= start.raw_sb_partial_overlap_cycles ? end.raw_sb_partial_overlap_cycles - start.raw_sb_partial_overlap_cycles : 0;
    r.raw_srb_store_payload_hit_cycles = end.raw_srb_store_payload_hit_cycles >= start.raw_srb_store_payload_hit_cycles ? end.raw_srb_store_payload_hit_cycles - start.raw_srb_store_payload_hit_cycles : 0;
    r.raw_srb_refill_line_wait_cycles = end.raw_srb_refill_line_wait_cycles >= start.raw_srb_refill_line_wait_cycles ? end.raw_srb_refill_line_wait_cycles - start.raw_srb_refill_line_wait_cycles : 0;
    r.raw_load_width_byte_cycles = end.raw_load_width_byte_cycles >= start.raw_load_width_byte_cycles ? end.raw_load_width_byte_cycles - start.raw_load_width_byte_cycles : 0;
    r.raw_load_width_half_cycles = end.raw_load_width_half_cycles >= start.raw_load_width_half_cycles ? end.raw_load_width_half_cycles - start.raw_load_width_half_cycles : 0;
    r.raw_load_width_word_cycles = end.raw_load_width_word_cycles >= start.raw_load_width_word_cycles ? end.raw_load_width_word_cycles - start.raw_load_width_word_cycles : 0;
    r.raw_load_width_dword_cycles = end.raw_load_width_dword_cycles >= start.raw_load_width_dword_cycles ? end.raw_load_width_dword_cycles - start.raw_load_width_dword_cycles : 0;
    r.raw_forwardable_simple_single_entry_cycles = end.raw_forwardable_simple_single_entry_cycles >= start.raw_forwardable_simple_single_entry_cycles ? end.raw_forwardable_simple_single_entry_cycles - start.raw_forwardable_simple_single_entry_cycles : 0;
    r.raw_forwardable_byte_merge_cycles = end.raw_forwardable_byte_merge_cycles >= start.raw_forwardable_byte_merge_cycles ? end.raw_forwardable_byte_merge_cycles - start.raw_forwardable_byte_merge_cycles : 0;
    r.raw_forwardable_full_with_srb_line_cycles = end.raw_forwardable_full_with_srb_line_cycles >= start.raw_forwardable_full_with_srb_line_cycles ? end.raw_forwardable_full_with_srb_line_cycles - start.raw_forwardable_full_with_srb_line_cycles : 0;

    r.bpu_branch_count = end.bpu_branch_count >= start.bpu_branch_count ? end.bpu_branch_count - start.bpu_branch_count : 0;
    r.bpu_branch_taken_count = end.bpu_branch_taken_count >= start.bpu_branch_taken_count ? end.bpu_branch_taken_count - start.bpu_branch_taken_count : 0;
    r.bpu_branch_correct_count = end.bpu_branch_correct_count >= start.bpu_branch_correct_count ? end.bpu_branch_correct_count - start.bpu_branch_correct_count : 0;
    r.bpu_branch_mispred_count = end.bpu_branch_mispred_count >= start.bpu_branch_mispred_count ? end.bpu_branch_mispred_count - start.bpu_branch_mispred_count : 0;
    r.bpu_jal_count = end.bpu_jal_count >= start.bpu_jal_count ? end.bpu_jal_count - start.bpu_jal_count : 0;
    r.bpu_jal_correct_count = end.bpu_jal_correct_count >= start.bpu_jal_correct_count ? end.bpu_jal_correct_count - start.bpu_jal_correct_count : 0;
    r.bpu_jalr_count = end.bpu_jalr_count >= start.bpu_jalr_count ? end.bpu_jalr_count - start.bpu_jalr_count : 0;
    r.bpu_jalr_correct_count = end.bpu_jalr_correct_count >= start.bpu_jalr_correct_count ? end.bpu_jalr_correct_count - start.bpu_jalr_correct_count : 0;
    r.bpu_ras_push_count = end.bpu_ras_push_count >= start.bpu_ras_push_count ? end.bpu_ras_push_count - start.bpu_ras_push_count : 0;
    r.bpu_ras_pop_count = end.bpu_ras_pop_count >= start.bpu_ras_pop_count ? end.bpu_ras_pop_count - start.bpu_ras_pop_count : 0;
    r.bpu_ras_correct_count = end.bpu_ras_correct_count >= start.bpu_ras_correct_count ? end.bpu_ras_correct_count - start.bpu_ras_correct_count : 0;
    r.bpu_btb_hit_count = end.bpu_btb_hit_count >= start.bpu_btb_hit_count ? end.bpu_btb_hit_count - start.bpu_btb_hit_count : 0;
    r.bpu_btb_miss_count = end.bpu_btb_miss_count >= start.bpu_btb_miss_count ? end.bpu_btb_miss_count - start.bpu_btb_miss_count : 0;
    r.bpu_false_hit_count = end.bpu_false_hit_count >= start.bpu_false_hit_count ? end.bpu_false_hit_count - start.bpu_false_hit_count : 0;
    r.bpu_bubbles_saved = end.bpu_bubbles_saved >= start.bpu_bubbles_saved ? end.bpu_bubbles_saved - start.bpu_bubbles_saved : 0;

    return r;
}

static std::string dump_json_record(const PerfRecord& r, const std::string& indent = "    ") {
    double ipc = r.cycles > 0 ? double(r.commits) / double(r.cycles) : 0.0;
    double cpi = r.commits > 0 ? double(r.cycles) / double(r.commits) : 0.0;
    std::ostringstream os;
    os << std::fixed << std::setprecision(6);
    os << indent << "\"total_cycles\": " << r.cycles << ",\n"
       << indent << "\"committed_instructions\": " << r.commits << ",\n"
       << indent << "\"ipc\": " << ipc << ",\n"
       << indent << "\"cpi\": " << cpi << ",\n"
       << indent << "\"privilege_mode_cycles\": {\n"
       << indent << "  \"m_mode\": " << r.cycles_m << ",\n"
       << indent << "  \"s_mode\": " << r.cycles_s << ",\n"
       << indent << "  \"u_mode\": " << r.cycles_u << "\n"
       << indent << "},\n"
       << indent << "\"instruction_fetch_wait_cycles\": " << r.fetch_wait_cycles << ",\n"
       << indent << "\"load_store_stall_cycles\": " << r.lsu_busy_cycles << ",\n"
       << indent << "\"lsu_detail\": {\n"
       << indent << "  \"req_wait_cycles\": " << r.lsu_req_wait_cycles << ",\n"
       << indent << "  \"rsp_wait_cycles\": " << r.lsu_rsp_wait_cycles << ",\n"
       << indent << "  \"amo_wait_cycles\": " << r.lsu_amo_wait_cycles << "\n"
       << indent << "},\n"
       << indent << "\"branch_control_flow\": {\n"
       << indent << "  \"commits\": " << r.branch_commits << ",\n"
       << indent << "  \"penalty_cycles\": " << r.branch_penalty_cycles << "\n"
       << indent << "},\n"
       << indent << "\"mmu_ptw\": {\n"
       << indent << "  \"walk_count_total\": " << r.ptw_walks_total << ",\n"
       << indent << "  \"walk_count_insn\": " << r.ptw_walks_insn << ",\n"
       << indent << "  \"walk_count_load\": " << r.ptw_walks_load << ",\n"
       << indent << "  \"walk_count_store\": " << r.ptw_walks_store << ",\n"
       << indent << "  \"walk_count_amo\": " << r.ptw_walks_amo << ",\n"
       << indent << "  \"total_ptw_cycles\": " << r.ptw_cycles_total << ",\n"
       << indent << "  \"ptw_cycles_insn\": " << r.ptw_cycles_insn << ",\n"
       << indent << "  \"ptw_cycles_data\": " << r.ptw_cycles_data << ",\n"
       << indent << "  \"page_table_memory_accesses\": " << r.ptw_memory_accesses << ",\n"
       << indent << "  \"translation_stall_cycles\": " << r.ptw_cycles_total << "\n"
       << indent << "},\n"
       << indent << "\"tlb\": {\n"
       << indent << "  \"itlb_hits\": " << r.itlb_hit_count << ",\n"
       << indent << "  \"itlb_misses\": " << r.itlb_miss_count << ",\n"
       << indent << "  \"itlb_refills\": " << r.itlb_refill_count << ",\n"
       << indent << "  \"itlb_hit_rate\": " << ((r.itlb_hit_count + r.itlb_miss_count) > 0 ? double(r.itlb_hit_count) / double(r.itlb_hit_count + r.itlb_miss_count) : 0.0) << ",\n"
       << indent << "  \"dtlb_hits\": " << r.dtlb_hit_count << ",\n"
       << indent << "  \"dtlb_misses\": " << r.dtlb_miss_count << ",\n"
       << indent << "  \"dtlb_refills\": " << r.dtlb_refill_count << ",\n"
       << indent << "  \"dtlb_hit_rate\": " << ((r.dtlb_hit_count + r.dtlb_miss_count) > 0 ? double(r.dtlb_hit_count) / double(r.dtlb_hit_count + r.dtlb_miss_count) : 0.0) << "\n"
       << indent << "},\n"
       << indent << "\"l1i\": {\n"
       << indent << "  \"l1i_hits\": " << r.l1i_hit_count << ",\n"
       << indent << "  \"l1i_misses\": " << r.l1i_miss_count << ",\n"
       << indent << "  \"l1i_refills\": " << r.l1i_refill_count << ",\n"
       << indent << "  \"l1i_refills_clean_installed\": " << r.l1i_refill_count << ",\n"
       << indent << "  \"l1i_refills_aborted\": " << r.l1i_refill_abort_count << ",\n"
       << indent << "  \"l1i_refills_initiated_total\": " << (r.l1i_refill_count + r.l1i_refill_abort_count) << ",\n"
       << indent << "  \"l1i_early_restarts\": " << r.l1i_early_restart_count << ",\n"
       << indent << "  \"l1i_pre_critical_aborts\": " << ((r.l1i_refill_count + r.l1i_refill_abort_count) >= r.l1i_early_restart_count ? (r.l1i_refill_count + r.l1i_refill_abort_count) - r.l1i_early_restart_count : 0) << ",\n"
       << indent << "  \"l1i_streaming_hits\": " << r.l1i_streaming_hit_count << ",\n"
       << indent << "  \"l1i_hit_rate\": " << ((r.l1i_hit_count + r.l1i_miss_count) > 0 ? double(r.l1i_hit_count) / double(r.l1i_hit_count + r.l1i_miss_count) : 0.0) << ",\n"
       << indent << "  \"l1i_nlp_hardware_telemetry\": {\n"
       << indent << "    \"candidate_events\": " << r.l1i_nlp_candidate_events << ",\n"
       << indent << "    \"issued_events\": " << r.l1i_nlp_issued_events << ",\n"
       << indent << "    \"suppressed_page_events\": " << r.l1i_nlp_suppressed_page_events << ",\n"
       << indent << "    \"suppressed_pmp_events\": " << r.l1i_nlp_suppressed_pmp_events << ",\n"
       << indent << "    \"suppressed_resident_events\": " << r.l1i_nlp_suppressed_resident_events << ",\n"
       << indent << "    \"suppressed_duplicate_events\": " << r.l1i_nlp_suppressed_duplicate_events << ",\n"
       << indent << "    \"useful_hit_events\": " << r.l1i_nlp_useful_hit_events << ",\n"
       << indent << "    \"streaming_hit_events\": " << r.l1i_nlp_streaming_hit_events << ",\n"
       << indent << "    \"preempted_events\": " << r.l1i_nlp_preempted_events << ",\n"
       << indent << "    \"dormant_abandon_events\": " << r.l1i_nlp_dormant_abandon_events << ",\n"
       << indent << "    \"discard_redirect_events\": " << r.l1i_nlp_discard_redirect_events << ",\n"
       << indent << "    \"discard_maint_events\": " << r.l1i_nlp_discard_maint_events << ",\n"
       << indent << "    \"discard_error_events\": " << r.l1i_nlp_discard_error_events << ",\n"
       << indent << "    \"promote_events\": " << r.l1i_nlp_promote_events << ",\n"
       << indent << "    \"hidden_cycles_total\": " << r.l1i_nlp_hidden_cycles_total << "\n"
       << indent << "  }\n"
       << indent << "},\n"
       << indent << "\"l1d\": {\n"
       << indent << "  \"l1d_hits\": " << r.l1d_hit_count << ",\n"
       << indent << "  \"l1d_misses\": " << r.l1d_miss_count << ",\n"
       << indent << "  \"l1d_refills\": " << r.l1d_refill_count << ",\n"
       << indent << "  \"l1d_evictions\": " << r.l1d_evict_count << ",\n"
       << indent << "  \"l1d_load_hits\": " << r.l1d_load_hit_count << ",\n"
       << indent << "  \"l1d_load_misses\": " << r.l1d_load_miss_count << ",\n"
       << indent << "  \"l1d_store_hits\": " << r.l1d_store_hit_count << ",\n"
       << indent << "  \"l1d_store_misses\": " << r.l1d_store_miss_count << ",\n"
       << indent << "  \"l1d_er_events\": " << r.l1d_er_events << ",\n"
       << indent << "  \"l1d_er_saved_cycles_total\": " << r.l1d_er_saved_cycles_total << ",\n"
       << indent << "  \"l1d_hit_rate\": " << ((r.l1d_hit_count + r.l1d_miss_count) > 0 ? double(r.l1d_hit_count) / double(r.l1d_hit_count + r.l1d_miss_count) : 0.0) << ",\n"
       << indent << "  \"l1d_load_hit_rate\": " << ((r.l1d_load_hit_count + r.l1d_load_miss_count) > 0 ? double(r.l1d_load_hit_count) / double(r.l1d_load_hit_count + r.l1d_load_miss_count) : 0.0) << ",\n"
       << indent << "  \"l1d_store_hit_rate\": " << ((r.l1d_store_hit_count + r.l1d_store_miss_count) > 0 ? double(r.l1d_store_hit_count) / double(r.l1d_store_hit_count + r.l1d_store_miss_count) : 0.0) << "\n"
       << indent << "},\n"
       << indent << "\"l1d_er_trailing_refill_diagnostics\": {\n"
       << indent << "  \"accounting_note\": \"overlapping diagnostic; excluded from disjoint_cycle_partition\",\n"
       << indent << "  \"active_cycles\": " << r.l1d_er_trailing_active_cycles << ",\n"
       << indent << "  \"active_pct\": " << (r.cycles > 0 ? (100.0 * double(r.l1d_er_trailing_active_cycles) / double(r.cycles)) : 0.0) << ",\n"
       << indent << "  \"useful_commit_cycles\": " << r.l1d_er_trailing_useful_commit_cycles << ",\n"
       << indent << "  \"blocked_later_load_cycles\": " << r.l1d_er_trailing_blocked_load_cycles << ",\n"
       << indent << "  \"blocked_store_cycles\": " << r.l1d_er_trailing_blocked_store_cycles << ",\n"
       << indent << "  \"blocked_serialization_cycles\": " << r.l1d_er_trailing_blocked_serialization_cycles << ",\n"
       << indent << "  \"other_zero_retire_cycles\": " << r.l1d_er_trailing_other_zero_retire_cycles << ",\n"
       << indent << "  \"zero_retire_subcategory_sum\": " << (r.l1d_er_trailing_blocked_load_cycles + r.l1d_er_trailing_blocked_store_cycles + r.l1d_er_trailing_blocked_serialization_cycles + r.l1d_er_trailing_other_zero_retire_cycles) << ",\n"
       << indent << "  \"active_cycle_exact_match\": " << ((r.l1d_er_trailing_useful_commit_cycles + r.l1d_er_trailing_blocked_load_cycles + r.l1d_er_trailing_blocked_store_cycles + r.l1d_er_trailing_blocked_serialization_cycles + r.l1d_er_trailing_other_zero_retire_cycles) == r.l1d_er_trailing_active_cycles ? "true" : "false") << ",\n"
       << indent << "  \"sb_nonempty_cycles\": " << r.l1d_er_trailing_sb_nonempty_cycles << ",\n"
       << indent << "  \"sb_full_cycles\": " << r.l1d_er_trailing_sb_full_cycles << ",\n"
       << indent << "  \"refill_error_edge_cycles\": " << r.l1d_refill_error_edge_cycles << ",\n"
       << indent << "  \"fatal_halt_cycles\": " << r.fatal_halt_cycles << "\n"
       << indent << "},\n"
       << indent << "\"platform_events\": {\n"
       << indent << "  \"sbi_ecall_count\": " << r.sbi_ecall_count << ",\n"
       << indent << "  \"user_ecall_count\": " << r.user_ecall_count << ",\n"
       << indent << "  \"mtip_count\": " << r.mtip_count << ",\n"
       << indent << "  \"stip_count\": " << r.stip_count << ",\n"
       << indent << "  \"seip_count\": " << r.seip_count << ",\n"
       << indent << "  \"sync_trap_count\": " << r.sync_trap_count << ",\n"
       << indent << "  \"trap_overhead_cycles\": " << r.trap_overhead_cycles << "\n"
       << indent << "},\n"
       << indent << "\"uart_mmio\": {\n"
       << indent << "  \"access_count\": " << r.uart_access_count << "\n"
       << indent << "},\n"
       << indent << "\"retirement_taxonomy\": {\n"
       << indent << "  \"cycles_useful_retire\": " << r.cycles_useful_retire << ",\n"
       << indent << "  \"cycles_useful_retire_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_useful_retire) / double(r.cycles)) : 0.0) << ",\n"
       << indent << "  \"cycles_zero_retire\": " << r.cycles_zero_retire << ",\n"
       << indent << "  \"cycles_zero_retire_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_zero_retire) / double(r.cycles)) : 0.0) << "\n"
       << indent << "},\n";

        double merge_rate = r.sb_total_ordinary_stores > 0 ? (100.0 * double(r.sb_tail_merges) / double(r.sb_total_ordinary_stores)) : 0.0;
        double avg_drain_lat = r.sb_drain_completions > 0 ? (double(r.sb_total_drain_latency_cycles) / double(r.sb_drain_completions)) : 0.0;
        os << indent << "\"store_buffer_telemetry\": {\n"
           << indent << "  \"total_ordinary_stores\": " << r.sb_total_ordinary_stores << ",\n"
           << indent << "  \"sb_enqueues\": " << r.sb_enqueues << ",\n"
           << indent << "  \"sb_tail_merges\": " << r.sb_tail_merges << ",\n"
           << indent << "  \"merge_rate_pct\": " << merge_rate << ",\n"
           << indent << "  \"max_occupancy\": " << r.sb_max_occupancy << ",\n"
           << indent << "  \"occupancy_distribution\": {\n"
           << indent << "    \"occ_0_cycles\": " << r.sb_occ_cycles[0] << ",\n"
           << indent << "    \"occ_0_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[0]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_1_cycles\": " << r.sb_occ_cycles[1] << ",\n"
           << indent << "    \"occ_1_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[1]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_2_cycles\": " << r.sb_occ_cycles[2] << ",\n"
           << indent << "    \"occ_2_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[2]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_3_cycles\": " << r.sb_occ_cycles[3] << ",\n"
           << indent << "    \"occ_3_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[3]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_4_cycles\": " << r.sb_occ_cycles[4] << ",\n"
           << indent << "    \"occ_4_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[4]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_5_cycles\": " << r.sb_occ_cycles[5] << ",\n"
           << indent << "    \"occ_5_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[5]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_6_cycles\": " << r.sb_occ_cycles[6] << ",\n"
           << indent << "    \"occ_6_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[6]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_7_cycles\": " << r.sb_occ_cycles[7] << ",\n"
           << indent << "    \"occ_7_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[7]) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"occ_8_cycles\": " << r.sb_occ_cycles[8] << ",\n"
           << indent << "    \"occ_8_pct\": " << (r.cycles > 0 ? (100.0 * double(r.sb_occ_cycles[8]) / double(r.cycles)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"full_buffer_stall_cycles\": " << r.sb_full_stall_cycles << ",\n"
           << indent << "  \"raw_conflict_stall_cycles\": " << r.sb_raw_conflict_stall_cycles << ",\n"
           << indent << "  \"arbitration_load_stall_cycles\": " << r.cycles_sb_arbitration_load_stall << ",\n"
           << indent << "  \"visible_drain_stall_cycles\": " << r.cycles_sb_drain_visible_stall << ",\n"
           << indent << "  \"drain_requests\": " << r.sb_drain_requests << ",\n"
           << indent << "  \"drain_completions\": " << r.sb_drain_completions << ",\n"
           << indent << "  \"drain_hits\": " << r.sb_drain_hits << ",\n"
           << indent << "  \"drain_clean_misses\": " << r.sb_drain_clean_misses << ",\n"
           << indent << "  \"drain_dirty_misses\": " << r.sb_drain_dirty_misses << ",\n"
           << indent << "  \"cycles_hidden_behind_useful_execution\": " << r.sb_hidden_drain_cycles << ",\n"
           << indent << "  \"average_drain_latency_cycles\": " << avg_drain_lat << "\n"
           << indent << "},\n";

        os << indent << "\"srb_telemetry\": {\n"
           << indent << "  \"srb_active_cycles\": " << r.srb_active_cycles << ",\n"
           << indent << "  \"srb_active_pct\": " << (r.cycles > 0 ? (100.0 * double(r.srb_active_cycles) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"srb_installs\": " << r.srb_installs << ",\n"
           << indent << "  \"srb_clean_victims\": " << r.srb_clean_victims << ",\n"
           << indent << "  \"srb_dirty_victims\": " << r.srb_dirty_victims << ",\n"
           << indent << "  \"srb_raw_load_stall_cycles\": " << r.cycles_srb_raw_load_stall << ",\n"
           << indent << "  \"srb_secondary_load_miss_stall_cycles\": " << r.cycles_srb_sec_load_stall << "\n"
           << indent << "},\n";

        os << indent << "\"bpu_telemetry\": {\n"
           << indent << "  \"branch_count\": " << r.bpu_branch_count << ",\n"
           << indent << "  \"branch_taken_count\": " << r.bpu_branch_taken_count << ",\n"
           << indent << "  \"branch_correct_count\": " << r.bpu_branch_correct_count << ",\n"
           << indent << "  \"branch_mispred_count\": " << r.bpu_branch_mispred_count << ",\n"
           << indent << "  \"branch_accuracy_pct\": " << (r.bpu_branch_count > 0 ? (100.0 * double(r.bpu_branch_correct_count) / double(r.bpu_branch_count)) : 0.0) << ",\n"
           << indent << "  \"jal_count\": " << r.bpu_jal_count << ",\n"
           << indent << "  \"jal_correct_count\": " << r.bpu_jal_correct_count << ",\n"
           << indent << "  \"jalr_count\": " << r.bpu_jalr_count << ",\n"
           << indent << "  \"jalr_correct_count\": " << r.bpu_jalr_correct_count << ",\n"
           << indent << "  \"ras_push_count\": " << r.bpu_ras_push_count << ",\n"
           << indent << "  \"ras_pop_count\": " << r.bpu_ras_pop_count << ",\n"
           << indent << "  \"ras_correct_count\": " << r.bpu_ras_correct_count << ",\n"
           << indent << "  \"btb_hit_count\": " << r.bpu_btb_hit_count << ",\n"
           << indent << "  \"btb_miss_count\": " << r.bpu_btb_miss_count << ",\n"
           << indent << "  \"false_hit_count\": " << r.bpu_false_hit_count << ",\n"
           << indent << "  \"bubbles_saved\": " << r.bpu_bubbles_saved << "\n"
           << indent << "},\n";

        os << indent << "\"l1d_fsm_latency_distributions\": {\n"
           << indent << "  \"clean_load_miss\": {\n"
           << indent << "    \"count\": " << r.lat_clean_miss_count << ",\n"
           << indent << "    \"min_cycles\": " << (r.lat_clean_miss_count > 0 && r.lat_clean_miss_min != UINT64_MAX ? r.lat_clean_miss_min : 0) << ",\n"
           << indent << "    \"avg_cycles\": " << (r.lat_clean_miss_count > 0 ? double(r.lat_clean_miss_total) / double(r.lat_clean_miss_count) : 0.0) << ",\n"
           << indent << "    \"max_cycles\": " << r.lat_clean_miss_max << "\n"
           << indent << "  },\n"
           << indent << "  \"dirty_victim_eviction\": {\n"
           << indent << "    \"count\": " << r.lat_dirty_evict_count << ",\n"
           << indent << "    \"min_cycles\": " << (r.lat_dirty_evict_count > 0 && r.lat_dirty_evict_min != UINT64_MAX ? r.lat_dirty_evict_min : 0) << ",\n"
           << indent << "    \"avg_cycles\": " << (r.lat_dirty_evict_count > 0 ? double(r.lat_dirty_evict_total) / double(r.lat_dirty_evict_count) : 0.0) << ",\n"
           << indent << "    \"max_cycles\": " << r.lat_dirty_evict_max << "\n"
           << indent << "  },\n"
           << indent << "  \"dirty_victim_refill\": {\n"
           << indent << "    \"count\": " << r.lat_dirty_refill_count << ",\n"
           << indent << "    \"min_cycles\": " << (r.lat_dirty_refill_count > 0 && r.lat_dirty_refill_min != UINT64_MAX ? r.lat_dirty_refill_min : 0) << ",\n"
           << indent << "    \"avg_cycles\": " << (r.lat_dirty_refill_count > 0 ? double(r.lat_dirty_refill_total) / double(r.lat_dirty_refill_count) : 0.0) << ",\n"
           << indent << "    \"max_cycles\": " << r.lat_dirty_refill_max << "\n"
           << indent << "  },\n"
           << indent << "  \"dirty_victim_total\": {\n"
           << indent << "    \"count\": " << r.lat_dirty_total_count << ",\n"
           << indent << "    \"min_cycles\": " << (r.lat_dirty_total_count > 0 && r.lat_dirty_total_min != UINT64_MAX ? r.lat_dirty_total_min : 0) << ",\n"
           << indent << "    \"avg_cycles\": " << (r.lat_dirty_total_count > 0 ? double(r.lat_dirty_total_cycles) / double(r.lat_dirty_total_count) : 0.0) << ",\n"
           << indent << "    \"max_cycles\": " << r.lat_dirty_total_max << "\n"
           << indent << "  },\n"
           << indent << "  \"install_duration\": {\n"
           << indent << "    \"count\": " << r.lat_install_count << ",\n"
           << indent << "    \"min_cycles\": " << (r.lat_install_count > 0 && r.lat_install_min != UINT64_MAX ? r.lat_install_min : 0) << ",\n"
           << indent << "    \"avg_cycles\": " << (r.lat_install_count > 0 ? double(r.lat_install_total) / double(r.lat_install_count) : 0.0) << ",\n"
           << indent << "    \"max_cycles\": " << r.lat_install_max << "\n"
           << indent << "  },\n"
           << indent << "  \"sb_drain_structural_collision\": {\n"
           << indent << "    \"count\": " << r.lat_sb_drain_collision_count << ",\n"
           << indent << "    \"min_cycles\": " << (r.lat_sb_drain_collision_count > 0 && r.lat_sb_drain_collision_min != UINT64_MAX ? r.lat_sb_drain_collision_min : 0) << ",\n"
           << indent << "    \"avg_cycles\": " << (r.lat_sb_drain_collision_count > 0 ? double(r.lat_sb_drain_collision_total) / double(r.lat_sb_drain_collision_count) : 0.0) << ",\n"
           << indent << "    \"max_cycles\": " << r.lat_sb_drain_collision_max << "\n"
           << indent << "  }\n"
           << indent << "},\n";

        uint64_t load_dirty_total = r.cycles_l1d_load_dirty_evict_stall + r.cycles_l1d_load_dirty_refill_stall;
        uint64_t store_dirty_total = r.cycles_store_dirty_evict + r.cycles_store_dirty_refill;
        uint64_t trap_overhead_total = r.cycles_trap_entry_drain + r.cycles_trap_vector_bubble + r.cycles_mret_sret_redirect_bubble;
        uint64_t ptw_tlb_total = r.cycles_ptw_stall + r.cycles_itlb_translation_latency;
        uint64_t maint_total = r.cycles_maint_sfence_vma + r.cycles_maint_fence_i + r.cycles_maint_pmp;
        uint64_t l1i_total = r.cycles_l1i_miss_refill + r.cycles_l1i_hit_fetch_stall;
        uint64_t disjoint_sum = r.cycles_useful_retire +
                                r.cycles_store_stall +
                                r.cycles_sb_raw_load_stall +
                                r.cycles_srb_raw_load_stall +
                                r.cycles_l1d_load_structural_arb_stall +
                                r.cycles_srb_install_bubble_stall +
                                r.cycles_srb_sec_load_stall +
                                r.cycles_sb_drain_visible_stall +
                                r.cycles_load_stall +
                                r.cycles_amo_lr_sc_stall +
                                r.cycles_mmio_stall +
                                r.cycles_arbitration_contention +
                                maint_total +
                                r.cycles_l1i_miss_refill +
                                r.cycles_l1i_hit_fetch_stall +
                                ptw_tlb_total +
                                r.cycles_branch_redirect_bubble +
                                trap_overhead_total +
                                r.cycles_csr_serialization_flush +
                                r.cycles_refill_handoff_bubble +
                                r.cycles_residual_unclassified;

        os << indent << "\"disjoint_cycle_partition\": {\n"
           << indent << "  \"useful_commit_cycles\": " << r.cycles_useful_retire << ",\n"
           << indent << "  \"useful_commit_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_useful_retire) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"store_buffer_stall_cycles\": " << r.cycles_store_stall << ",\n"
           << indent << "  \"store_buffer_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_store_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"sb_full_backpressure_cycles\": " << r.cycles_sb_full_stall << ",\n"
           << indent << "  \"sb_full_backpressure_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_sb_full_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"raw_load_stall_cycles\": " << r.cycles_sb_raw_load_stall << ",\n"
           << indent << "  \"raw_load_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_sb_raw_load_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"srb_raw_load_stall_cycles\": " << r.cycles_srb_raw_load_stall << ",\n"
           << indent << "  \"srb_raw_load_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_srb_raw_load_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_structural_arb_stall_cycles\": " << r.cycles_l1d_load_structural_arb_stall << ",\n"
           << indent << "  \"l1d_load_structural_arb_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1d_load_structural_arb_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"srb_install_bubble_stall_cycles\": " << r.cycles_srb_install_bubble_stall << ",\n"
           << indent << "  \"srb_install_bubble_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_srb_install_bubble_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"srb_secondary_load_miss_stall_cycles\": " << r.cycles_srb_sec_load_stall << ",\n"
           << indent << "  \"srb_secondary_load_miss_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_srb_sec_load_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"arbitration_load_stall_cycles\": " << r.cycles_l1d_load_structural_arb_stall << ",\n"
           << indent << "  \"arbitration_load_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1d_load_structural_arb_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_clean_miss_refill_stall_cycles\": " << r.cycles_l1d_load_clean_miss_refill_stall << ",\n"
           << indent << "  \"l1d_load_clean_miss_refill_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1d_load_clean_miss_refill_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_dirty_evict_stall_cycles\": " << r.cycles_l1d_load_dirty_evict_stall << ",\n"
           << indent << "  \"l1d_load_dirty_evict_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1d_load_dirty_evict_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_dirty_refill_stall_cycles\": " << r.cycles_l1d_load_dirty_refill_stall << ",\n"
           << indent << "  \"l1d_load_dirty_refill_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1d_load_dirty_refill_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_hit_latency_cycles\": " << r.cycles_load_hit_latency << ",\n"
           << indent << "  \"l1d_load_hit_latency_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_load_hit_latency) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"visible_drain_stall_cycles\": " << r.cycles_sb_drain_visible_stall << ",\n"
           << indent << "  \"visible_drain_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_sb_drain_visible_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_stall_cycles\": " << r.cycles_load_stall << ",\n"
           << indent << "  \"l1d_load_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_load_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_load_detail\": {\n"
           << indent << "    \"hit_path_latency_cycles\": " << r.cycles_load_hit_latency << ",\n"
           << indent << "    \"clean_miss_refill_cycles\": " << r.cycles_l1d_load_clean_miss_refill_stall << ",\n"
           << indent << "    \"dirty_victim_evict_cycles\": " << r.cycles_l1d_load_dirty_evict_stall << ",\n"
           << indent << "    \"dirty_victim_refill_cycles\": " << r.cycles_l1d_load_dirty_refill_stall << ",\n"
           << indent << "    \"dirty_victim_total_contribution_cycles\": " << load_dirty_total << "\n"
           << indent << "  },\n"
           << indent << "  \"l1d_store_stall_cycles\": " << r.cycles_store_stall << ",\n"
           << indent << "  \"l1d_store_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_store_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_store_detail\": {\n"
           << indent << "    \"hit_path_latency_cycles\": " << r.cycles_store_hit_latency << ",\n"
           << indent << "    \"clean_miss_refill_cycles\": " << r.cycles_store_clean_refill << ",\n"
           << indent << "    \"dirty_evict_cycles\": " << r.cycles_store_dirty_evict << ",\n"
           << indent << "    \"dirty_refill_cycles\": " << r.cycles_store_dirty_refill << ",\n"
           << indent << "    \"dirty_eviction_plus_refill_cycles\": " << store_dirty_total << "\n"
           << indent << "  },\n"
           << indent << "  \"amo_lr_sc_stall_cycles\": " << r.cycles_amo_lr_sc_stall << ",\n"
           << indent << "  \"amo_lr_sc_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_amo_lr_sc_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1i_hit_fetch_stall_cycles\": " << r.cycles_l1i_hit_fetch_stall << ",\n"
           << indent << "  \"l1i_hit_fetch_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1i_hit_fetch_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1i_miss_refill_cycles\": " << r.cycles_l1i_miss_refill << ",\n"
           << indent << "  \"l1i_miss_refill_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_l1i_miss_refill) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1i_total_stall_cycles\": " << l1i_total << ",\n"
           << indent << "  \"l1i_total_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(l1i_total) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"branch_redirect_bubble_cycles\": " << r.cycles_branch_redirect_bubble << ",\n"
           << indent << "  \"branch_redirect_bubble_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_branch_redirect_bubble) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"csr_serialization_flush_cycles\": " << r.cycles_csr_serialization_flush << ",\n"
           << indent << "  \"csr_serialization_flush_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_csr_serialization_flush) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"trap_return_overhead_cycles\": " << trap_overhead_total << ",\n"
           << indent << "  \"trap_return_overhead_pct\": " << (r.cycles > 0 ? (100.0 * double(trap_overhead_total) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"trap_return_detail\": {\n"
           << indent << "    \"trap_entry_drain_cycles\": " << r.cycles_trap_entry_drain << ",\n"
           << indent << "    \"trap_vector_bubble_cycles\": " << r.cycles_trap_vector_bubble << ",\n"
           << indent << "    \"mret_sret_redirect_bubble_cycles\": " << r.cycles_mret_sret_redirect_bubble << "\n"
           << indent << "  },\n"
           << indent << "  \"ptw_tlb_stall_cycles\": " << ptw_tlb_total << ",\n"
           << indent << "  \"ptw_tlb_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(ptw_tlb_total) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"ptw_tlb_detail\": {\n"
           << indent << "    \"itlb_ptw_cycles\": " << r.cycles_itlb_ptw_stall << ",\n"
           << indent << "    \"dtlb_ptw_cycles\": " << r.cycles_dtlb_ptw_stall << ",\n"
           << indent << "    \"itlb_translation_latency_cycles\": " << r.cycles_itlb_translation_latency << "\n"
           << indent << "  },\n"
           << indent << "  \"l1d_maintenance_cycles\": " << maint_total << ",\n"
           << indent << "  \"l1d_maintenance_pct\": " << (r.cycles > 0 ? (100.0 * double(maint_total) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"l1d_maintenance_detail\": {\n"
           << indent << "    \"sfence_vma_cycles\": " << r.cycles_maint_sfence_vma << ",\n"
           << indent << "    \"fence_i_cycles\": " << r.cycles_maint_fence_i << ",\n"
           << indent << "    \"pmp_maintenance_cycles\": " << r.cycles_maint_pmp << "\n"
           << indent << "  },\n"
           << indent << "  \"mmio_stall_cycles\": " << r.cycles_mmio_stall << ",\n"
           << indent << "  \"mmio_stall_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_mmio_stall) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"arbitration_contention_cycles\": " << r.cycles_arbitration_contention << ",\n"
           << indent << "  \"arbitration_contention_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_arbitration_contention) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"refill_handoff_bubble_cycles\": " << r.cycles_refill_handoff_bubble << ",\n"
           << indent << "  \"refill_handoff_bubble_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_refill_handoff_bubble) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"residual_unclassified_cycles\": " << r.cycles_residual_unclassified << ",\n"
           << indent << "  \"residual_unclassified_pct\": " << (r.cycles > 0 ? (100.0 * double(r.cycles_residual_unclassified) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "  \"disjoint_sum_cycles\": " << disjoint_sum << ",\n"
           << indent << "  \"total_cycles\": " << r.cycles << ",\n"
           << indent << "  \"disjoint_exact_match\": " << (disjoint_sum == r.cycles ? "true" : "false") << "\n"
           << indent << "},\n"
           << indent << "\"dram_traffic_summary\": {\n"
           << indent << "  \"imem_fetch_requests\": " << r.trans_imem_req << ",\n"
           << indent << "  \"dmem_load_requests\": " << r.trans_dmem_load << ",\n"
           << indent << "  \"dmem_store_requests\": " << r.trans_dmem_store << ",\n"
           << indent << "  \"l1d_refill_beats\": " << (r.l1d_refill_count * 8) << ",\n"
           << indent << "  \"l1d_writeback_beats\": " << (r.l1d_evict_count * 8) << ",\n"
           << indent << "  \"l1i_refill_beats\": " << (r.l1i_refill_count * 8) << ",\n"
           << indent << "  \"ptw_memory_requests\": " << r.trans_ptw_req << ",\n"
           << indent << "  \"total_ram_requests\": " << (r.trans_imem_req + r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req) << ",\n"
           << indent << "  \"uart_mmio_requests\": " << r.trans_uart_mmio << ",\n"
           << indent << "  \"clint_mmio_requests\": " << r.trans_clint_mmio << ",\n"
           << indent << "  \"plic_mmio_requests\": " << r.trans_plic_mmio << ",\n"
           << indent << "  \"total_mmio_requests\": " << (r.trans_uart_mmio + r.trans_clint_mmio + r.trans_plic_mmio) << ",\n"
           << indent << "  \"instruction_traffic_pct\": " << ((r.trans_imem_req + r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req) > 0 ? (100.0 * double(r.trans_imem_req) / double(r.trans_imem_req + r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req)) : 0.0) << ",\n"
           << indent << "  \"data_traffic_pct\": " << ((r.trans_imem_req + r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req) > 0 ? (100.0 * double(r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req) / double(r.trans_imem_req + r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req)) : 0.0) << "\n"
           << indent << "},\n"
           << indent << "\"ranked_optimization_candidates\": {\n"
           << indent << "  \"rank_1_store_path_improvement\": {\n"
           << indent << "    \"directly_addressable_cycle_pool\": " << r.cycles_store_stall << ",\n"
           << indent << "    \"dirty_eviction_plus_refill_pool\": " << store_dirty_total << ",\n"
           << indent << "    \"description\": \"Store stall optimization via write buffer, write merging, or write-no-allocate evaluation\"\n"
           << indent << "  },\n"
           << indent << "  \"rank_2_l1i_refill_prefetch\": {\n"
           << indent << "    \"directly_addressable_cycle_pool\": " << r.cycles_l1i_miss_refill << ",\n"
           << indent << "    \"description\": \"Next-line prefetch or streaming refill to mitigate DRAM refill latency\"\n"
           << indent << "  },\n"
           << indent << "  \"rank_3_btb_branch_prediction\": {\n"
           << indent << "    \"directly_addressable_cycle_pool\": " << r.cycles_branch_redirect_bubble << ",\n"
           << indent << "    \"taken_control_flow_count\": " << (r.branch_taken_count + r.insn_jal_count + r.insn_jalr_count) << ",\n"
           << indent << "    \"description\": \"Predicting branch target in Stage F to eliminate 1-cycle redirect bubble\"\n"
           << indent << "  },\n"
           << indent << "  \"rank_4_l1d_load_path\": {\n"
           << indent << "    \"directly_addressable_cycle_pool\": " << r.cycles_load_stall << ",\n"
           << indent << "    \"description\": \"Load stall optimization via hit pipelining and early restart\"\n"
           << indent << "  },\n"
           << indent << "  \"rank_5_maintenance_flush_opt\": {\n"
           << indent << "    \"directly_addressable_cycle_pool\": " << maint_total << ",\n"
           << indent << "    \"description\": \"Selective range-based SFENCE.VMA and selective FENCE.I flush\"\n"
           << indent << "  },\n"
           << indent << "  \"rank_6_ptw_translation_opt\": {\n"
           << indent << "    \"directly_addressable_cycle_pool\": " << ptw_tlb_total << ",\n"
           << indent << "    \"description\": \"Negligible bottleneck with 99.99% TLB hit rates\"\n"
           << indent << "  }\n"
           << indent << "},\n"
           << indent << "\"overlap_explanation\": {\n"
           << indent << "  \"description\": \"Raw fetch_wait_cycles and lsu_busy_cycles overlap because in Slice-0, fetch is held in REQUEST waiting for lsu_issue_ready while LSU transactions are inflight. Summing raw counters produces >100%. The disjoint_cycle_partition provides the exact non-overlapping distribution.\",\n"
           << indent << "  \"raw_fetch_wait_cycles\": " << r.fetch_wait_cycles << ",\n"
           << indent << "  \"raw_lsu_busy_cycles\": " << r.lsu_busy_cycles << ",\n"
           << indent << "  \"overlap_cycles\": " << (r.fetch_wait_cycles >= r.cycles_l1i_miss_refill ? r.fetch_wait_cycles - r.cycles_l1i_miss_refill : 0) << "\n"
           << indent << "},\n"
       << indent << "\"memory_transactions\": {\n"
       << indent << "  \"imem_fetch_requests\": " << r.trans_imem_req << ",\n"
       << indent << "  \"dmem_load_requests\": " << r.trans_dmem_load << ",\n"
       << indent << "  \"dmem_store_requests\": " << r.trans_dmem_store << ",\n"
       << indent << "  \"total_ram_requests\": " << (r.trans_imem_req + r.trans_dmem_load + r.trans_dmem_store + r.trans_ptw_req) << ",\n"
       << indent << "  \"uart_mmio_requests\": " << r.trans_uart_mmio << ",\n"
       << indent << "  \"clint_mmio_requests\": " << r.trans_clint_mmio << ",\n"
       << indent << "  \"plic_mmio_requests\": " << r.trans_plic_mmio << ",\n"
       << indent << "  \"total_mmio_requests\": " << (r.trans_uart_mmio + r.trans_clint_mmio + r.trans_plic_mmio) << "\n"
       << indent << "},\n"
       << indent << "\"instruction_mix\": {\n"
       << indent << "  \"alu_instructions\": " << r.insn_alu_count << ",\n"
       << indent << "  \"load_instructions\": " << r.insn_load_count << ",\n"
       << indent << "  \"store_instructions\": " << r.insn_store_count << ",\n"
       << indent << "  \"amo_instructions\": " << r.insn_amo_count << ",\n"
       << indent << "  \"branch_conditional\": " << r.insn_branch_cond_count << ",\n"
           << indent << "  \"branch_taken\": " << r.branch_taken_count << ",\n"
           << indent << "  \"branch_untaken\": " << r.branch_untaken_count << ",\n"
           << indent << "  \"branch_taken_pct\": " << (r.insn_branch_cond_count > 0 ? (100.0 * double(r.branch_taken_count) / double(r.insn_branch_cond_count)) : 0.0) << ",\n"
           << indent << "  \"jal_unconditional\": " << r.insn_jal_count << ",\n"
           << indent << "  \"jalr_indirect\": " << r.insn_jalr_count << ",\n"
           << indent << "  \"system_instructions\": " << r.insn_system_count << "\n"
           << indent << "},\n"
           << indent << "\"store_buffer_full_characterization\": {\n"
           << indent << "  \"target_cycle_pool\": " << r.cycles_sb_full_stall << ",\n"
           << indent << "  \"total_full_episodes\": " << r.sb_full_episodes << ",\n"
           << indent << "  \"consecutive_full_cycles\": {\n"
           << indent << "    \"min\": " << (r.sb_full_episodes > 0 && r.sb_full_consecutive_cycles_min != UINT64_MAX ? r.sb_full_consecutive_cycles_min : 0) << ",\n"
           << indent << "    \"avg\": " << (r.sb_full_episodes > 0 ? (double(r.sb_full_consecutive_cycles_total) / double(r.sb_full_episodes)) : 0.0) << ",\n"
           << indent << "    \"max\": " << r.sb_full_consecutive_cycles_max << "\n"
           << indent << "  },\n"
           << indent << "  \"episode_duration_distribution\": {\n"
           << indent << "    \"episodes_1_to_4_cycles\": " << r.sb_full_duration_buckets[0] << ",\n"
           << indent << "    \"episodes_5_to_10_cycles\": " << r.sb_full_duration_buckets[1] << ",\n"
           << indent << "    \"episodes_11_to_20_cycles\": " << r.sb_full_duration_buckets[2] << ",\n"
           << indent << "    \"episodes_21_to_50_cycles\": " << r.sb_full_duration_buckets[3] << ",\n"
           << indent << "    \"episodes_51_to_100_cycles\": " << r.sb_full_duration_buckets[4] << ",\n"
           << indent << "    \"episodes_over_100_cycles\": " << r.sb_full_duration_buckets[5] << "\n"
           << indent << "  },\n"
           << indent << "  \"drain_throughput_while_full\": {\n"
           << indent << "    \"drain_completions_while_full\": " << r.sb_full_drain_completions << ",\n"
           << indent << "    \"completions_per_full_cycle\": " << (r.cycles_sb_full_stall > 0 ? (double(r.sb_full_drain_completions) / double(r.cycles_sb_full_stall)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"blocker_distribution_while_full\": {\n"
           << indent << "    \"blocked_by_l1d_fsm_busy_cycles\": " << r.sb_full_blocked_l1d_busy << ",\n"
           << indent << "    \"blocked_by_l1d_fsm_busy_pct\": " << (r.cycles_sb_full_stall > 0 ? (100.0 * double(r.sb_full_blocked_l1d_busy) / double(r.cycles_sb_full_stall)) : 0.0) << ",\n"
           << indent << "    \"blocked_by_srb_busy_cycles\": " << r.sb_full_blocked_srb_busy << ",\n"
           << indent << "    \"blocked_by_srb_busy_pct\": " << (r.cycles_sb_full_stall > 0 ? (100.0 * double(r.sb_full_blocked_srb_busy) / double(r.cycles_sb_full_stall)) : 0.0) << ",\n"
           << indent << "    \"blocked_by_dram_bus_contention_cycles\": " << r.sb_full_blocked_dram_bus << ",\n"
           << indent << "    \"blocked_by_dram_bus_contention_pct\": " << (r.cycles_sb_full_stall > 0 ? (100.0 * double(r.sb_full_blocked_dram_bus) / double(r.cycles_sb_full_stall)) : 0.0) << ",\n"
           << indent << "    \"drain_request_granted_active_cycles\": " << r.sb_full_hit_drain_active << ",\n"
           << indent << "    \"drain_request_granted_active_pct\": " << (r.cycles_sb_full_stall > 0 ? (100.0 * double(r.sb_full_hit_drain_active) / double(r.cycles_sb_full_stall)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"store_production_vs_drain_rates\": {\n"
           << indent << "    \"total_stores_enqueued_or_merged\": " << r.sb_total_ordinary_stores << ",\n"
           << indent << "    \"total_drain_completions\": " << r.sb_drain_completions << ",\n"
           << indent << "    \"store_arrival_rate_per_cycle\": " << (r.cycles > 0 ? (double(r.sb_total_ordinary_stores) / double(r.cycles)) : 0.0) << ",\n"
           << indent << "    \"drain_completion_rate_per_cycle\": " << (r.cycles > 0 ? (double(r.sb_drain_completions) / double(r.cycles)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"coalescing_opportunities\": {\n"
           << indent << "    \"same_doubleword_match_cycles\": " << r.sb_full_coalesce_same_dword_cycles << ",\n"
           << indent << "    \"same_doubleword_match_pct\": " << (r.cycles_sb_full_stall > 0 ? (100.0 * double(r.sb_full_coalesce_same_dword_cycles) / double(r.cycles_sb_full_stall)) : 0.0) << ",\n"
           << indent << "    \"exact_address_match_cycles\": " << r.sb_full_coalesce_exact_addr_cycles << ",\n"
           << indent << "    \"exact_address_match_pct\": " << (r.cycles_sb_full_stall > 0 ? (100.0 * double(r.sb_full_coalesce_exact_addr_cycles) / double(r.cycles_sb_full_stall)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"shadow_fifo_depth_evaluation\": {\n"
           << indent << "    \"depth_8_baseline_stall_cycles\": " << r.cycles_sb_full_stall << ",\n"
           << indent << "    \"depth_10_shadow_stall_cycles\": " << r.shadow_sb_full_stall_cycles_d10 << ",\n"
           << indent << "    \"depth_10_avoided_cycles\": " << (r.cycles_sb_full_stall >= r.shadow_sb_full_stall_cycles_d10 ? r.cycles_sb_full_stall - r.shadow_sb_full_stall_cycles_d10 : 0) << ",\n"
           << indent << "    \"depth_12_shadow_stall_cycles\": " << r.shadow_sb_full_stall_cycles_d12 << ",\n"
           << indent << "    \"depth_12_avoided_cycles\": " << (r.cycles_sb_full_stall >= r.shadow_sb_full_stall_cycles_d12 ? r.cycles_sb_full_stall - r.shadow_sb_full_stall_cycles_d12 : 0) << ",\n"
           << indent << "    \"depth_16_shadow_stall_cycles\": " << r.shadow_sb_full_stall_cycles_d16 << ",\n"
           << indent << "    \"depth_16_avoided_cycles\": " << (r.cycles_sb_full_stall >= r.shadow_sb_full_stall_cycles_d16 ? r.cycles_sb_full_stall - r.shadow_sb_full_stall_cycles_d16 : 0) << "\n"
           << indent << "  }\n"
           << indent << "},\n"
           << indent << "\"l1i_next_line_prefetch_characterization\": {\n"
           << indent << "  \"target_cycle_pool\": " << r.cycles_l1i_miss_refill << ",\n"
           << indent << "  \"demand_refills_total\": " << r.l1i_demand_refills_total << ",\n"
           << indent << "  \"sequential_transitions\": {\n"
           << indent << "    \"sequential_next_line_refills\": " << r.l1i_seq_next_line_refills << ",\n"
           << indent << "    \"sequential_next_line_pct\": " << (r.l1i_demand_refills_total > 0 ? (100.0 * double(r.l1i_seq_next_line_refills) / double(r.l1i_demand_refills_total)) : 0.0) << ",\n"
           << indent << "    \"same_4k_page_eligible_candidates\": " << r.l1i_nlp_same_page_candidates << ",\n"
           << indent << "    \"same_4k_page_eligible_pct\": " << (r.l1i_demand_refills_total > 0 ? (100.0 * double(r.l1i_nlp_same_page_candidates) / double(r.l1i_demand_refills_total)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"candidate_filtering\": {\n"
           << indent << "    \"already_cached_filtered\": " << r.l1i_nlp_already_cached_filtered << ",\n"
           << indent << "    \"issued_candidates\": " << r.l1i_nlp_issued_candidates << "\n"
           << indent << "  },\n"
           << indent << "  \"usefulness_and_accuracy\": {\n"
           << indent << "    \"useful_prefetches\": " << r.l1i_nlp_useful_prefetches << ",\n"
           << indent << "    \"useful_prefetch_pct\": " << (r.l1i_nlp_issued_candidates > 0 ? (100.0 * double(r.l1i_nlp_useful_prefetches) / double(r.l1i_nlp_issued_candidates)) : 0.0) << ",\n"
           << indent << "    \"useless_prefetches\": " << r.l1i_nlp_useless_prefetches << ",\n"
           << indent << "    \"useless_prefetch_pct\": " << (r.l1i_nlp_issued_candidates > 0 ? (100.0 * double(r.l1i_nlp_useless_prefetches) / double(r.l1i_nlp_issued_candidates)) : 0.0) << ",\n"
           << indent << "    \"redirects_before_use\": " << r.l1i_nlp_redirects_before_use << "\n"
           << indent << "  },\n"
           << indent << "  \"lead_time_distribution\": {\n"
           << indent << "    \"min_lead_time_cycles\": " << (r.l1i_nlp_useful_prefetches > 0 && r.l1i_nlp_lead_time_min != UINT64_MAX ? r.l1i_nlp_lead_time_min : 0) << ",\n"
           << indent << "    \"avg_lead_time_cycles\": " << (r.l1i_nlp_useful_prefetches > 0 ? (double(r.l1i_nlp_lead_time_total) / double(r.l1i_nlp_useful_prefetches)) : 0.0) << ",\n"
           << indent << "    \"max_lead_time_cycles\": " << r.l1i_nlp_lead_time_max << ",\n"
           << indent << "    \"under_18_cycles_partial_hide\": " << r.l1i_nlp_lead_time_buckets[0] << ",\n"
           << indent << "    \"18_to_50_cycles_fully_hidden\": " << r.l1i_nlp_lead_time_buckets[1] << ",\n"
           << indent << "    \"51_to_200_cycles_fully_hidden\": " << r.l1i_nlp_lead_time_buckets[2] << ",\n"
           << indent << "    \"over_200_cycles_fully_hidden\": " << r.l1i_nlp_lead_time_buckets[3] << "\n"
           << indent << "  },\n"
           << indent << "  \"bus_opportunity_and_removable_pool\": {\n"
           << indent << "    \"bus_idle_cycles\": " << r.l1i_nlp_bus_idle_cycles << ",\n"
           << indent << "    \"bus_conflicts_with_l1d\": " << r.l1i_nlp_bus_conflicts_l1d << ",\n"
           << indent << "    \"theoretical_cycles_hidden\": " << r.l1i_nlp_cycles_hidden << ",\n"
           << indent << "    \"pct_of_target_pool_hidden\": " << (r.cycles_l1i_miss_refill > 0 ? (100.0 * double(r.l1i_nlp_cycles_hidden) / double(r.cycles_l1i_miss_refill)) : 0.0) << "\n"
           << indent << "  }\n"
           << indent << "},\n"
           << indent << "\"store_to_load_forwarding_characterization\": {\n"
           << indent << "  \"target_cycle_pool\": {\n"
           << indent << "    \"srb_raw_stall_cycles\": " << r.cycles_srb_raw_load_stall << ",\n"
           << indent << "    \"sb_raw_stall_cycles\": " << r.cycles_sb_raw_load_stall << ",\n"
           << indent << "    \"total_raw_stall_cycles\": " << (r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall) << "\n"
           << indent << "  },\n"
           << indent << "  \"sb_raw_classification\": {\n"
           << indent << "    \"exact_64bit_dword_match_cycles\": " << r.raw_sb_exact_dword_match_cycles << ",\n"
           << indent << "    \"single_entry_full_coverage_cycles\": " << r.raw_sb_single_entry_full_cov_cycles << ",\n"
           << indent << "    \"multi_entry_merged_coverage_cycles\": " << r.raw_sb_multi_entry_merge_cycles << ",\n"
           << indent << "    \"partial_overlap_cycles\": " << r.raw_sb_partial_overlap_cycles << "\n"
           << indent << "  },\n"
           << indent << "  \"srb_raw_classification\": {\n"
           << indent << "    \"srb_store_payload_hit_cycles\": " << r.raw_srb_store_payload_hit_cycles << ",\n"
           << indent << "    \"srb_refill_line_wait_cycles\": " << r.raw_srb_refill_line_wait_cycles << ",\n"
           << indent << "    \"srb_store_payload_pct\": " << ((r.cycles_srb_raw_load_stall) > 0 ? (100.0 * double(r.raw_srb_store_payload_hit_cycles) / double(r.cycles_srb_raw_load_stall)) : 0.0) << ",\n"
           << indent << "    \"srb_refill_line_wait_pct\": " << ((r.cycles_srb_raw_load_stall) > 0 ? (100.0 * double(r.raw_srb_refill_line_wait_cycles) / double(r.cycles_srb_raw_load_stall)) : 0.0) << "\n"
           << indent << "  },\n"
           << indent << "  \"load_width_distribution\": {\n"
           << indent << "    \"byte_loads\": " << r.raw_load_width_byte_cycles << ",\n"
           << indent << "    \"halfword_loads\": " << r.raw_load_width_half_cycles << ",\n"
           << indent << "    \"word_loads\": " << r.raw_load_width_word_cycles << ",\n"
           << indent << "    \"dword_loads\": " << r.raw_load_width_dword_cycles << "\n"
           << indent << "  },\n"
           << indent << "  \"removable_cycle_pools\": {\n"
           << indent << "    \"tier_1_simple_single_entry_cycles\": " << r.raw_forwardable_simple_single_entry_cycles << ",\n"
           << indent << "    \"tier_1_pct_of_raw_pool\": " << ((r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall) > 0 ? (100.0 * double(r.raw_forwardable_simple_single_entry_cycles) / double(r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall)) : 0.0) << ",\n"
           << indent << "    \"tier_2_byte_mask_merge_cycles\": " << r.raw_forwardable_byte_merge_cycles << ",\n"
           << indent << "    \"tier_2_pct_of_raw_pool\": " << ((r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall) > 0 ? (100.0 * double(r.raw_forwardable_byte_merge_cycles) / double(r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall)) : 0.0) << ",\n"
           << indent << "    \"tier_3_full_with_srb_line_cycles\": " << r.raw_forwardable_full_with_srb_line_cycles << ",\n"
           << indent << "    \"tier_3_pct_of_raw_pool\": " << ((r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall) > 0 ? (100.0 * double(r.raw_forwardable_full_with_srb_line_cycles) / double(r.cycles_srb_raw_load_stall + r.cycles_sb_raw_load_stall)) : 0.0) << "\n"
           << indent << "  }\n"
           << indent << "}";
    return os.str();
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0] << " <sbi_firmware.elf> <kernel.img> <dtb.bin> [max_cycles] [disable_l1d_er]\n";
        return 1;
    }

    const char* fw_elf = argv[1];
    const char* kernel_img = argv[2];
    const char* dtb_bin = argv[3];
    uint64_t max_cycles = (argc > 4) ? std::stoull(argv[4]) : 250000000ULL;
    bool disable_l1d_er = (argc > 5) && (std::string(argv[5]) == "1");

    try {
        std::vector<uint8_t> ram(RAM_SIZE, 0);

        // 1. Load SBI firmware ELF at 0x8000_0000
        size_t fw_sz = load_elf(fw_elf, ram);

        // 2. Load Linux Image at 0x8020_0000 (S-mode entry)
        size_t kernel_sz = load_raw_bin(kernel_img, ram, 0x80200000ULL);

        // 3. Load Canonical DTB at 0x8200_0000
        size_t dtb_sz = load_raw_bin(dtb_bin, ram, 0x82000000ULL);

        if (0x80200000ULL + kernel_sz > 0x82000000ULL) {
            throw std::runtime_error("Kernel image overlaps with DTB at 0x8200_0000");
        }
        if (0x82000000ULL + dtb_sz > 0x82100000ULL) {
            throw std::runtime_error("DTB exceeds 1 MiB aperture");
        }

        std::cerr << "[PERF_TB] Firmware: " << fw_sz << " bytes\n"
                  << "[PERF_TB] Kernel:   " << kernel_sz << " bytes at 0x8020_0000\n"
                  << "[PERF_TB] DTB:      " << dtb_sz << " bytes at 0x8200_0000\n"
                  << "[PERF_TB] DRAM:     256 MiB\n"
                  << "[PERF_TB] Max cycl: " << max_cycles << "\n"
                  << "[PERF_TB] L1D-ER:   " << (disable_l1d_er ? "disabled (A/B baseline)" : "enabled") << "\n";

        Vfursoy_s0_soc dut;
        std::string uart_output;

        dut.clk_i = 0;
        dut.rst_i = 1;
        dut.imem_req_ready_i = 1;
        dut.imem_rsp_valid_i = 0;
        dut.imem_rsp_error_i = 0;
        dut.ram_req_ready_i = 1;
        dut.ram_req_error_i = 0;
        dut.ram_rsp_valid_i = 0;
        dut.ram_rsp_error_i = 0;
        dut.irq_sources_i = 0;
        dut.irq_external_i = 0;
        dut.eval();
        dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__verification_disable_er = disable_l1d_er ? 1 : 0;

        for (int r = 0; r < 10; r++) {
            dut.clk_i = 1; dut.eval();
            dut.clk_i = 0; dut.eval();
        }
        dut.rst_i = 0;

        bool ip = false, dp = false;
        uint64_t ii = 0;
        uint64_t dd = 0;

        PerfRecord cur;
        PerfRecord rec_boot_start;
        PerfRecord rec_init_reached;
        PerfRecord rec_cpu_start, rec_cpu_end;
        PerfRecord rec_mem_start, rec_mem_end;

        bool seen_reset = false;
        bool seen_handoff = false;
        bool seen_satp_sv39 = false;
        bool seen_earlycon = false;
        bool seen_init_banner = false;
        bool seen_cpu_start = false;
        bool seen_cpu_end = false;
        bool seen_mem_start = false;
        bool seen_mem_end = false;
        bool seen_bench_complete = false;

        uint64_t cycle_handoff = 0;
        uint64_t cycle_init_banner = 0;
        uint64_t cycle_bench_complete = 0;
        uint64_t last_satp_val = 0;
        uint64_t last_mtimecmp = 0;

        int prev_mmu_state = 0;
        bool in_trap = false;

        enum BubbleSource {
            BUBBLE_NONE = 0,
            BUBBLE_BRANCH,
            BUBBLE_MRET_SRET,
            BUBBLE_TRAP,
            BUBBLE_CSR,
            BUBBLE_FENCE_I,
            BUBBLE_SFENCE,
            BUBBLE_REFILL_HANDOFF
        };
        BubbleSource pending_bubble = BUBBLE_NONE;

        uint64_t last_commit_pc = 0;
        uint32_t last_commit_insn = 0;
        bool in_dirty_miss = false;
        uint64_t drain_start_cycle = 0;
        bool drain_in_progress = false;
        bool drain_saw_evict = false;

        bool in_clean_load_miss = false;
        uint64_t clean_miss_start_cycle = 0;

        bool in_dirty_evict_meas = false;
        uint64_t dirty_evict_start_cycle = 0;
        uint64_t dirty_miss_start_cycle = 0;
        bool in_dirty_miss_meas = false;
        bool in_dirty_refill_meas = false;
        uint64_t dirty_refill_start_cycle = 0;

        int prev_l_state = 0;
        uint64_t install_start_cycle = 0;
        bool in_install_meas = false;

        bool in_sb_collision = false;
        uint64_t sb_collision_start_cycle = 0;

        // Section A: Store Buffer Full episode trackers
        uint64_t curr_sb_full_len = 0;

        // Section B: L1I Next-Line Prefetch trackers
        uint64_t prev_l1i_demand_line = 0;
        struct PrefetchCandidate {
            uint64_t line_pa;
            uint64_t cycle_issued;
            bool valid;
        };
        std::deque<PrefetchCandidate> nlp_candidates;

        while (cur.cycles < max_cycles) {
            dut.clk_i = 0;
            dut.irq_sources_i = 0;
            dut.irq_external_i = 0;
            dut.imem_req_ready_i = 1;
            dut.imem_rsp_valid_i = ip;
            dut.imem_rsp_data_i = ii;
            dut.imem_rsp_error_i = 0;

            dut.ram_req_ready_i = 1;
            dut.ram_req_error_i = 0;
            dut.ram_rsp_valid_i = dp;
            dut.ram_rsp_data_i = dd;
            dut.ram_rsp_error_i = 0;
            dut.eval();

            bool ifire = ip && dut.imem_rsp_ready_o;
            bool dfire = dp && dut.ram_rsp_ready_o;
            bool ireq = dut.imem_req_valid_o && dut.imem_req_ready_i;
            bool dreq = dut.ram_req_valid_o && dut.ram_req_ready_i;

            bool nip = ip, ndp = false;
            uint64_t nii = ii;
            uint64_t ndd = 0;

            if (ifire) nip = false;
            if (dfire) ndp = false;

            if (ireq) {
                uint64_t addr = dut.imem_req_addr_o;
                if (addr >= RAM_BASE && addr + 8 <= RAM_BASE + RAM_SIZE) {
                    nii = read_mem(ram, addr, 3);
                    nip = true;
                }
                cur.trans_imem_req++;

                bool is_beat0 = (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__refill_beat_cnt == 0);
                if (is_beat0) {
                    uint64_t dline = addr & ~63ULL;
                    for (auto& cand : nlp_candidates) {
                        if (cand.valid && cand.line_pa == dline) {
                            uint64_t lead = cur.cycles >= cand.cycle_issued ? (cur.cycles - cand.cycle_issued) : 0;
                            cur.sample_nlp_lead_time(lead);
                            cand.valid = false;
                            break;
                        }
                    }
                    cur.l1i_demand_refills_total++;
                    uint64_t cur_lidx = dline >> 6;
                    if (prev_l1i_demand_line != 0 && cur_lidx == prev_l1i_demand_line + 1) {
                        cur.l1i_seq_next_line_refills++;
                    }
                    prev_l1i_demand_line = cur_lidx;

                    uint64_t nline = dline + 64;
                    bool same_page = (dline >> 12) == (nline >> 12);
                    if (same_page) {
                        cur.l1i_nlp_same_page_candidates++;
                        if (is_l1i_cached(dut, nline)) {
                            cur.l1i_nlp_already_cached_filtered++;
                        } else {
                            cur.l1i_nlp_issued_candidates++;
                            nlp_candidates.push_back({nline, cur.cycles, true});
                            if (nlp_candidates.size() > 128) {
                                if (nlp_candidates.front().valid) cur.l1i_nlp_useless_prefetches++;
                                nlp_candidates.pop_front();
                            }
                        }
                    }
                }
            }

            if (dreq) {
                uint64_t a = dut.ram_req_addr_o;
                unsigned s = dut.ram_req_size_o;
                if (a >= RAM_BASE && a + (1u << s) <= RAM_BASE + RAM_SIZE) {
                    if (dut.ram_req_store_o) {
                        write_mem(ram, a, s, dut.ram_req_store_data_o);
                    } else {
                        ndd = read_mem(ram, a, s);
                        ndp = true;
                    }
                }
                if (dut.ram_req_ptw_o) {
                    cur.ptw_memory_accesses++;
                    cur.trans_ptw_req++;
                } else if (dut.ram_req_store_o) {
                    cur.trans_dmem_store++;
                } else {
                    cur.trans_dmem_load++;
                }
            }

            // Monitor MMIO writes / requests
            if (dut.rootp->fursoy_s0_soc__DOT__uart__DOT__req_fire) {
                cur.uart_access_count++;
                cur.trans_uart_mmio++;
            }
            if (dut.rootp->fursoy_s0_soc__DOT__clint__DOT__req_fire) {
                cur.trans_clint_mmio++;
            }
            if (dut.rootp->fursoy_s0_soc__DOT__plic__DOT__req_fire) {
                cur.trans_plic_mmio++;
            }

            // Monitor Store Buffer occupancy
            uint8_t sb_occ = dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__count_q;
            if (sb_occ > cur.sb_max_occupancy) cur.sb_max_occupancy = sb_occ;
            if (sb_occ <= 8) cur.sb_occ_cycles[sb_occ]++;

            // Monitor SRB
            bool srb_busy_val = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_busy_o;
            if (srb_busy_val) cur.srb_active_cycles++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_install_event_o) {
                cur.srb_installs++;
                if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_victim_dirty_o) cur.srb_dirty_victims++;
                else cur.srb_clean_victims++;
            }

            // Monitor Store Buffer drain completion
            int l_state_chk = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__state_q;
            bool store_ack = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_store_ack;
            bool srb_capture = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_capture;
            if (store_ack) {
                cur.sb_drain_completions++;
                if (drain_in_progress) {
                    cur.sb_total_drain_latency_cycles += (cur.cycles >= drain_start_cycle ? (cur.cycles - drain_start_cycle + 1) : 1);
                    drain_in_progress = false;
                } else {
                    cur.sb_total_drain_latency_cycles += 1;
                }
                if (l_state_chk == 0 /* IDLE */ && !srb_capture) {
                    cur.sb_drain_hits++;
                } else {
                    if (drain_saw_evict || (srb_capture && dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_victim_dirty_o)) {
                        cur.sb_drain_dirty_misses++;
                        drain_saw_evict = false;
                    } else {
                        cur.sb_drain_clean_misses++;
                    }
                }
            }

            // Monitor Store Buffer drain issue
            bool drain_req_issued = dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb_drain_req_valid &&
                                    dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_issue_ready;
            if (drain_req_issued && !drain_in_progress) {
                cur.sb_drain_requests++;
                drain_in_progress = true;
                drain_start_cycle = cur.cycles;
                drain_saw_evict = false;
            }

            if (drain_in_progress) {
                if (l_state_chk == 2 /* EVICT_REQ */ || l_state_chk == 3 /* EVICT_BURST */) {
                    drain_saw_evict = true;
                }
                if (dut.commit_valid_o) {
                    cur.sb_hidden_drain_cycles++;
                }
            }

            // Monitor CLINT mtimecmp
            uint64_t cur_mtimecmp = dut.rootp->fursoy_s0_soc__DOT__clint__DOT__mtimecmp_q;
            if (cur_mtimecmp != last_mtimecmp) {
                last_mtimecmp = cur_mtimecmp;
            }

            // Monitor UART transmissions and detect workload milestones
            if (dut.uart_tx_valid_o) {
                char ch = char(dut.uart_tx_data_o);
                uart_output += ch;
                std::cout << ch << std::flush;
                if (!seen_earlycon) {
                    seen_earlycon = true;
                }

                if (!seen_init_banner && uart_output.find("[INIT]") != std::string::npos) {
                    seen_init_banner = true;
                    cycle_init_banner = cur.cycles;
                    rec_init_reached = cur;
                }

                if (!seen_cpu_start && uart_output.find("[PERF] CPU_WORKLOAD_START") != std::string::npos) {
                    seen_cpu_start = true;
                    rec_cpu_start = cur;
                }
                if (!seen_cpu_end && uart_output.find("[PERF] CPU_WORKLOAD_END") != std::string::npos) {
                    seen_cpu_end = true;
                    rec_cpu_end = cur;
                }

                if (!seen_mem_start && uart_output.find("[PERF] MEM_WORKLOAD_START") != std::string::npos) {
                    seen_mem_start = true;
                    rec_mem_start = cur;
                }
                if (!seen_mem_end && uart_output.find("[PERF] MEM_WORKLOAD_END") != std::string::npos) {
                    seen_mem_end = true;
                    rec_mem_end = cur;
                }

                if (!seen_bench_complete && uart_output.find("[PERF] ALL_BENCHMARKS_COMPLETE") != std::string::npos) {
                    seen_bench_complete = true;
                    cycle_bench_complete = cur.cycles;
                }
            }

            // Milestone inspection & instruction accounting
            bool is_commit = dut.commit_valid_o;
            if (is_commit) {
                cur.commits++;
                cur.cycles_useful_retire++;
                last_commit_pc = dut.commit_pc_o;
                last_commit_insn = dut.commit_insn_o;
                if (last_commit_pc == 0x80000000ULL) seen_reset = true;
                if (last_commit_pc == 0x80200000ULL && !seen_handoff) {
                    seen_handoff = true;
                    cycle_handoff = cur.cycles;
                    rec_boot_start = cur;
                }

                // Decode instruction mix
                uint32_t insn = dut.commit_insn_o;
                uint32_t opcode = insn & 0x7f;
                if (opcode == 0x63) { // Branch
                    cur.insn_branch_cond_count++;
                    if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__control_target != (dut.commit_pc_o + 4)) {
                        cur.branch_taken_count++;
                    } else {
                        cur.branch_untaken_count++;
                    }
                } else if (opcode == 0x6f) { // JAL
                    cur.insn_jal_count++;
                } else if (opcode == 0x67) { // JALR
                    cur.insn_jalr_count++;
                } else if (opcode == 0x03) { // Load
                    cur.insn_load_count++;
                } else if (opcode == 0x23) { // Store
                    cur.insn_store_count++;
                    if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__is_ordinary_dram_store) {
                        if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__sb_merge_event_o) {
                            cur.sb_tail_merges++;
                        } else {
                            cur.sb_enqueues++;
                        }
                        cur.sb_total_ordinary_stores = cur.sb_enqueues + cur.sb_tail_merges;
                    }
                } else if (opcode == 0x2f) { // AMO
                    cur.insn_amo_count++;
                } else if (opcode == 0x73) { // SYSTEM
                    cur.insn_system_count++;
                } else { // ALU / other
                    cur.insn_alu_count++;
                }

                // Branch detection
                bool is_branch_taken = (opcode == 0x63 && (dut.rootp->fursoy_s0_soc__DOT__core__DOT__control_target != (dut.commit_pc_o + 4))) ||
                                       (opcode == 0x6f) || (opcode == 0x67);
                if (is_branch_taken) {
                    cur.branch_commits++;
                }

                // Trap return clears in_trap
                if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__mret_valid ||
                    dut.rootp->fursoy_s0_soc__DOT__core__DOT__sret_valid) {
                    in_trap = false;
                }
            } else {
                cur.cycles_zero_retire++;
            }

            // Track satp transitions to Sv39
            uint64_t satp = dut.rootp->fursoy_s0_soc__DOT__core__DOT__satp_q;
            if (satp != last_satp_val) {
                last_satp_val = satp;
                if ((satp >> 60) == 8 && !seen_satp_sv39) {
                    seen_satp_sv39 = true;
                }
            }


            // Stop condition: panic
            if (uart_output.find("Kernel panic") != std::string::npos ||
                uart_output.find("---[ end Kernel panic") != std::string::npos) {
                static int panic_drain = 0;
                if (++panic_drain > 5000) break;
            }

            bool took_trap = dut.trap_valid_o;
            bool to_s = dut.rootp->fursoy_s0_soc__DOT__core__DOT__trap_to_s;

            // Privilege mode breakdown
            int priv = dut.rootp->fursoy_s0_soc__DOT__core__DOT__priv_mode_q;
            if (priv == 3) cur.cycles_m++;
            else if (priv == 1) cur.cycles_s++;
            else if (priv == 0) cur.cycles_u++;

            // Fetch wait cycles
            int f_state = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__state_q;
            bool l1i_refilling = (f_state == 3 /* REFILL_REQ */ || f_state == 4 /* REFILL_RSP */);
            if (l1i_refilling || (f_state == 0 /* FETCH_REQ */)) {
                cur.fetch_wait_cycles++;
                if (f_state == 3) cur.fetch_req_wait_cycles++;
                else if (f_state == 4) cur.fetch_rsp_wait_cycles++;
            }

            // LSU stall cycles
            int l_state = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__state_q;
            if (l_state != 0 /* IDLE */) {
                cur.lsu_busy_cycles++;
                if (l_state == 1 /* AMO_CYCLE2 */) {
                    cur.lsu_amo_wait_cycles++;
                } else if (l_state == 2 /* EVICT_REQ */ || l_state == 4 /* REFILL_REQ */ ||
                           l_state == 7 /* MMIO_REQ */ || l_state == 10 /* FLUSH_REQ */) {
                    cur.lsu_req_wait_cycles++;
                    cur.cycles_lsu_req_wait++;
                } else {
                    cur.lsu_rsp_wait_cycles++;
                    cur.cycles_lsu_rsp_wait++;
                }
            }

            // MMU / PTW walk tracking
            int mmu_state = dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__state_q;
            int mmu_owner = dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__owner_q;
            if (prev_mmu_state == 0 /* IDLE */ && mmu_state == 1 /* PTW_REQ */) {
                cur.ptw_walks_total++;
                if (mmu_owner == 0) cur.ptw_walks_insn++;
                else if (mmu_owner == 1) cur.ptw_walks_load++;
                else if (mmu_owner == 2) cur.ptw_walks_store++;
                else if (mmu_owner == 3) cur.ptw_walks_amo++;
            }
            if (mmu_state == 1 /* PTW_REQ */ || mmu_state == 2 /* PTW_RSP */) {
                cur.ptw_cycles_total++;
                if (mmu_owner == 0) cur.ptw_cycles_insn++;
                else cur.ptw_cycles_data++;
            }
            prev_mmu_state = mmu_state;

            // Observational Stage E Inspection
            bool fe_valid = dut.rootp->fursoy_s0_soc__DOT__core__DOT__fe_valid_w;
            uint64_t fe_pc = dut.rootp->fursoy_s0_soc__DOT__core__DOT__fe_pc_w;
            uint32_t fe_insn = dut.rootp->fursoy_s0_soc__DOT__core__DOT__fe_insn_w;
            uint32_t fe_opcode = fe_insn & 0x7f;
            uint32_t fe_csr_addr = fe_insn >> 20;

            bool red_trap = took_trap || dut.rootp->fursoy_s0_soc__DOT__core__DOT__irq_take;
            bool red_mret = fe_valid && (dut.rootp->fursoy_s0_soc__DOT__core__DOT__mret_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__mret_legal);
            bool red_sret = fe_valid && (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sret_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__sret_legal);
            bool red_branch = dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_redirect_branch;
            bool red_fence_i = fe_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__fence_i;
            bool red_sfence = fe_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__sfence_legal && (mmu_state == 0);
            bool red_csr = fe_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__csr_valid && !dut.rootp->fursoy_s0_soc__DOT__core__DOT__csr_illegal && dut.rootp->fursoy_s0_soc__DOT__core__DOT__csr_write && ((fe_csr_addr == 0x180) || (fe_csr_addr == 0x300) || (fe_csr_addr == 0x100) || (fe_csr_addr == 0x3a0) || (fe_csr_addr == 0x3a2) || (fe_csr_addr >= 0x3b0 && fe_csr_addr <= 0x3bf));

            // BPU telemetry pulse accumulation
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_branch_count) cur.bpu_branch_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_branch_taken) cur.bpu_branch_taken_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_branch_correct) cur.bpu_branch_correct_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_branch_mispred) cur.bpu_branch_mispred_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_jal_count) cur.bpu_jal_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_jal_correct) cur.bpu_jal_correct_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_jalr_count) cur.bpu_jalr_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_jalr_correct) cur.bpu_jalr_correct_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_ras_push_count) cur.bpu_ras_push_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_ras_pop_count) cur.bpu_ras_pop_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_ras_correct) cur.bpu_ras_correct_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_btb_hit_count) cur.bpu_btb_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_btb_miss_count) cur.bpu_btb_miss_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_false_hit_count) cur.bpu_false_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__bpu_bubble_saved) cur.bpu_bubbles_saved++;

            bool stall_e = dut.rootp->fursoy_s0_soc__DOT__core__DOT__stall_e;
            bool is_load_miss_detect = false;
            bool is_dirty_victim = false;
            bool true_arb_stall = false;
            bool sb_full_this_cycle = false;

            // Disjoint Cycle Partition (100% mutually exclusive classification, Sum == total cycles)
            if (is_commit) {
                // Useful Commit Cycle (cur.cycles_useful_retire counted on line 713)
                pending_bubble = BUBBLE_NONE;
            } else if (took_trap) {
                // Trap or interrupt entry drain in Stage E
                cur.cycles_trap_entry_drain++;
            } else if (mmu_state == 1 || mmu_state == 2) {
                // MMU PTW is actively walking page tables
                cur.cycles_ptw_stall++;
                if (mmu_owner == 0) cur.cycles_itlb_ptw_stall++;
                else cur.cycles_dtlb_ptw_stall++;
            } else if (stall_e) {
                bool is_maint = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_maintenance_active ||
                                (l_state >= 9 /* FLUSH_SWEEP..FLUSH_DONE */) ||
                                (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sfence_vma && dut.rootp->fursoy_s0_soc__DOT__core__DOT__sfence_legal) ||
                                (fe_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__fence_i) ||
                                (fe_valid && (fe_csr_addr >= 0x3a0 && fe_csr_addr <= 0x3bf));

                bool is_sb_empty = dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb_empty;
                bool srb_is_busy = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_busy_q;
                bool mem_drained = is_sb_empty && !srb_is_busy && (l_state == 0 /* IDLE */);
                bool is_fence = fe_valid && (fe_opcode == 0x0f);
                bool is_fence_stall = is_fence && !mem_drained;
                bool is_drain_stall = (is_fence_stall) ||
                                      (red_mret && !mem_drained) ||
                                      (red_sret && !mem_drained) ||
                                      (red_csr && !mem_drained) ||
                                      (red_trap && !mem_drained);

                bool is_load_insn = fe_valid && (fe_opcode == 0x03);
                bool is_store_insn = fe_valid && (fe_opcode == 0x23);
                bool sb_full_stall = is_store_insn && dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb_enqueue_stall;
                bool srb_raw_stall = is_load_insn && dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__srb_raw_hazard_o;
                bool sb_raw_stall = is_load_insn && !srb_raw_stall && dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__load_raw_hazard_o;
                bool srb_install_stall = is_load_insn && !srb_raw_stall && !sb_raw_stall && (l_state == 0) && dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_install_event_o;
                true_arb_stall = is_load_insn && !srb_raw_stall && !sb_raw_stall && !srb_install_stall && (l_state == 0) && dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_req_is_sb_drain_w;
                bool srb_sec_stall = is_load_insn && !srb_raw_stall && !sb_raw_stall && !srb_install_stall && !true_arb_stall && dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_sec_load_stall_o;

                is_load_miss_detect = is_load_insn && (l_state == 0) && !srb_raw_stall && !sb_raw_stall && !srb_install_stall && !true_arb_stall && !srb_sec_stall && dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_load_miss_o;
                if (is_load_miss_detect) {
                    uint64_t pa = dut.rootp->fursoy_s0_soc__DOT__core__DOT__dtrans_pa;
                    is_dirty_victim = check_l1d_victim_dirty(dut, pa);
                }

                if (is_maint) {
                    if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__flush_is_fence_i_q || (fe_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__fence_i)) {
                        cur.cycles_maint_fence_i++;
                    } else if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__flush_is_pmp_q || (fe_valid && (fe_csr_addr >= 0x3a0 && fe_csr_addr <= 0x3bf))) {
                        cur.cycles_maint_pmp++;
                    } else {
                        cur.cycles_maint_sfence_vma++;
                    }
                } else if (is_drain_stall) {
                    cur.cycles_sb_drain_visible_stall++;
                } else if (l_state == 7 /* MMIO_REQ */ || l_state == 8 /* MMIO_RSP */) {
                    cur.cycles_mmio_stall++;
                } else if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_dmem_req_valid && dut.rootp->fursoy_s0_soc__DOT__core__DOT__ptw_grant) {
                    cur.cycles_arbitration_contention++;
                } else if (sb_full_stall) {
                    cur.cycles_store_stall++;
                    cur.cycles_sb_full_stall++;
                    cur.sb_full_stall_cycles++;
                    sb_full_this_cycle = true;
                } else if (srb_raw_stall) {
                    cur.cycles_srb_raw_load_stall++;
                    uint64_t load_pa = dut.rootp->fursoy_s0_soc__DOT__core__DOT__dtrans_pa;
                    uint32_t funct3 = (fe_insn >> 12) & 7;
                    int load_sz = (funct3 == 0 || funct3 == 4) ? 0 : ((funct3 == 1 || funct3 == 5) ? 1 : ((funct3 == 2 || funct3 == 6) ? 2 : 3));
                    uint8_t load_bo = load_pa & 7;
                    uint8_t load_m = (load_sz == 0) ? (1 << load_bo) : ((load_sz == 1) ? (3 << (load_bo & ~1)) : ((load_sz == 2) ? (0x0F << (load_bo & ~3)) : 0xFF));
                    if (load_sz == 0) cur.raw_load_width_byte_cycles++;
                    else if (load_sz == 1) cur.raw_load_width_half_cycles++;
                    else if (load_sz == 2) cur.raw_load_width_word_cycles++;
                    else cur.raw_load_width_dword_cycles++;

                    uint32_t load_w = (load_pa >> 3) & 7;
                    uint32_t srb_w = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_word_offset_q;
                    uint8_t srb_m = dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__srb_store_mask_q;
                    if (load_w == srb_w && (srb_m & load_m) == load_m) {
                        cur.raw_srb_store_payload_hit_cycles++;
                        cur.raw_forwardable_simple_single_entry_cycles++;
                        cur.raw_forwardable_byte_merge_cycles++;
                        cur.raw_forwardable_full_with_srb_line_cycles++;
                    } else {
                        cur.raw_srb_refill_line_wait_cycles++;
                    }
                } else if (sb_raw_stall) {
                    cur.cycles_sb_raw_load_stall++;
                    cur.sb_raw_conflict_stall_cycles++;
                    uint64_t load_pa = dut.rootp->fursoy_s0_soc__DOT__core__DOT__dtrans_pa;
                    uint32_t funct3 = (fe_insn >> 12) & 7;
                    int load_sz = (funct3 == 0 || funct3 == 4) ? 0 : ((funct3 == 1 || funct3 == 5) ? 1 : ((funct3 == 2 || funct3 == 6) ? 2 : 3));
                    uint8_t load_bo = load_pa & 7;
                    uint8_t load_m = (load_sz == 0) ? (1 << load_bo) : ((load_sz == 1) ? (3 << (load_bo & ~1)) : ((load_sz == 2) ? (0x0F << (load_bo & ~3)) : 0xFF));
                    if (load_sz == 0) cur.raw_load_width_byte_cycles++;
                    else if (load_sz == 1) cur.raw_load_width_half_cycles++;
                    else if (load_sz == 2) cur.raw_load_width_word_cycles++;
                    else cur.raw_load_width_dword_cycles++;

                    uint8_t comb_m = 0;
                    bool single_cov = false;
                    bool exact_dw = false;
                    for (int i = 0; i < 8; i++) {
                        if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__valid_q[i] &&
                            (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__paddr_q[i] == (load_pa >> 3))) {
                            uint8_t em = dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__byte_mask_q[i];
                            comb_m |= em;
                            if ((em & load_m) == load_m) {
                                single_cov = true;
                                if (load_sz == 3 && em == 0xFF) exact_dw = true;
                            }
                        }
                    }
                    if (exact_dw) cur.raw_sb_exact_dword_match_cycles++;
                    if (single_cov) {
                        cur.raw_sb_single_entry_full_cov_cycles++;
                        cur.raw_forwardable_simple_single_entry_cycles++;
                        cur.raw_forwardable_byte_merge_cycles++;
                        cur.raw_forwardable_full_with_srb_line_cycles++;
                    } else if ((comb_m & load_m) == load_m) {
                        cur.raw_sb_multi_entry_merge_cycles++;
                        cur.raw_forwardable_byte_merge_cycles++;
                        cur.raw_forwardable_full_with_srb_line_cycles++;
                    } else {
                        cur.raw_sb_partial_overlap_cycles++;
                    }
                } else if (srb_install_stall) {
                    cur.cycles_srb_install_bubble_stall++;
                } else if (true_arb_stall) {
                    cur.cycles_l1d_load_structural_arb_stall++;
                    cur.cycles_sb_arbitration_load_stall++;
                } else if (srb_sec_stall) {
                    cur.cycles_srb_sec_load_stall++;
                } else if (is_load_insn) {
                    cur.cycles_load_stall++;
                    if (l_state == 2 || l_state == 3) {
                        cur.cycles_l1d_load_dirty_evict_stall++;
                        cur.cycles_load_dirty_evict++;
                    } else if (l_state == 4 || l_state == 5 || l_state == 6) {
                        if (in_dirty_miss) {
                            cur.cycles_l1d_load_dirty_refill_stall++;
                            cur.cycles_load_dirty_refill++;
                        } else {
                            cur.cycles_l1d_load_clean_miss_refill_stall++;
                            cur.cycles_load_clean_refill++;
                        }
                    } else if (l_state == 0) {
                        if (is_load_miss_detect) {
                            if (is_dirty_victim) {
                                cur.cycles_l1d_load_dirty_evict_stall++;
                                cur.cycles_load_dirty_evict++;
                            } else {
                                cur.cycles_l1d_load_clean_miss_refill_stall++;
                                cur.cycles_load_clean_refill++;
                            }
                        } else {
                            cur.cycles_load_hit_latency++;
                        }
                    } else {
                        cur.cycles_load_hit_latency++;
                    }
                } else if (fe_opcode == 0x2f || l_state == 1 || dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__target_is_amo_q || dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__target_is_lr_q || dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__target_is_sc_q) {
                    cur.cycles_amo_lr_sc_stall++;
                } else if (is_store_insn) {
                    cur.cycles_store_stall++;
                    cur.cycles_sb_full_stall++;
                    cur.sb_full_stall_cycles++;
                    sb_full_this_cycle = true;
                } else {
                    cur.cycles_load_stall++;
                    if (l_state == 2 || l_state == 3) {
                        cur.cycles_l1d_load_dirty_evict_stall++;
                        cur.cycles_load_dirty_evict++;
                    } else if (l_state == 4 || l_state == 5 || l_state == 6) {
                        if (in_dirty_miss) {
                            cur.cycles_l1d_load_dirty_refill_stall++;
                            cur.cycles_load_dirty_refill++;
                        } else {
                            cur.cycles_l1d_load_clean_miss_refill_stall++;
                            cur.cycles_load_clean_refill++;
                        }
                    } else if (l_state == 0) {
                        if (is_load_miss_detect) {
                            if (is_dirty_victim) {
                                cur.cycles_l1d_load_dirty_evict_stall++;
                                cur.cycles_load_dirty_evict++;
                            } else {
                                cur.cycles_l1d_load_clean_miss_refill_stall++;
                                cur.cycles_load_clean_refill++;
                            }
                        } else {
                            cur.cycles_load_hit_latency++;
                        }
                    } else {
                        cur.cycles_load_hit_latency++;
                    }
                }
            } else if (f_state == 3 && dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_dmem_req_valid) {
                // L1I refill request backpressured by L1D bus priority
                cur.cycles_arbitration_contention++;
                pending_bubble = BUBBLE_NONE;
            } else if (f_state == 3 || f_state == 4) {
                // L1I miss / refill stall
                cur.cycles_l1i_miss_refill++;
                pending_bubble = BUBBLE_NONE;
            } else if (f_state == 2 || f_state == 0) {
                // L1I fetch hold / fetch request setup
                cur.cycles_l1i_hit_fetch_stall++;
            } else if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__itrans_busy || !dut.rootp->fursoy_s0_soc__DOT__core__DOT__itrans_valid) {
                // ITLB translation latency wait
                cur.cycles_itlb_translation_latency++;
            } else if (!fe_valid && pending_bubble != BUBBLE_NONE) {
                // Stage E bubble caused by prior redirect or refill handoff
                switch (pending_bubble) {
                    case BUBBLE_BRANCH:
                        cur.cycles_branch_redirect_bubble++;
                        break;
                    case BUBBLE_MRET_SRET:
                        cur.cycles_mret_sret_redirect_bubble++;
                        break;
                    case BUBBLE_TRAP:
                        cur.cycles_trap_vector_bubble++;
                        break;
                    case BUBBLE_CSR:
                        cur.cycles_csr_serialization_flush++;
                        break;
                    case BUBBLE_FENCE_I:
                        cur.cycles_maint_fence_i++;
                        break;
                    case BUBBLE_SFENCE:
                        cur.cycles_maint_sfence_vma++;
                        break;
                    case BUBBLE_REFILL_HANDOFF:
                        cur.cycles_refill_handoff_bubble++;
                        break;
                    default:
                        cur.cycles_residual_unclassified++;
                        break;
                }
                pending_bubble = BUBBLE_NONE;
            } else if (!fe_valid && f_state == 1) {
                // L1I hit-path lookup latency while Stage E is empty (pipeline fill / fetch latency)
                cur.cycles_l1i_hit_fetch_stall++;
            } else {
                cur.cycles_residual_unclassified++;
                if (cur.cycles_residual_unclassified <= 10) {
                    std::cerr << "[RESIDUAL] cycle=" << cur.cycles
                              << " fe_valid=" << fe_valid
                              << " l1i_st=" << f_state
                              << " lsu_st=" << l_state
                              << " mmu_st=" << mmu_state
                              << " stall_e=" << (int)stall_e
                              << " is_commit=" << (int)is_commit
                              << " bubble_src=" << (int)pending_bubble
                              << " pc=0x" << std::hex << fe_pc << std::dec << "\n";
                }
            }

            // Overlapping L1D-ER diagnostic only. The primary cycle taxonomy above
            // remains mutually exclusive and is not modified by these counters.
            bool er_trailing_active =
                dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__er_load_retired_q &&
                (l_state == 4 /* REFILL_REQ */ || l_state == 5 /* REFILL_RSP */ ||
                 l_state == 6 /* INSTALL */);
            if (er_trailing_active) {
                cur.l1d_er_trailing_active_cycles++;
                if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__count_q != 0)
                    cur.l1d_er_trailing_sb_nonempty_cycles++;
                if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__count_q == 8)
                    cur.l1d_er_trailing_sb_full_cycles++;

                if (is_commit) {
                    cur.l1d_er_trailing_useful_commit_cycles++;
                } else if (stall_e && fe_valid && fe_opcode == 0x03) {
                    cur.l1d_er_trailing_blocked_load_cycles++;
                } else if (stall_e && fe_valid && fe_opcode == 0x23) {
                    cur.l1d_er_trailing_blocked_store_cycles++;
                } else if (stall_e && (red_trap || red_mret || red_sret || red_csr ||
                                       (fe_valid && fe_opcode == 0x0f))) {
                    cur.l1d_er_trailing_blocked_serialization_cycles++;
                } else {
                    cur.l1d_er_trailing_other_zero_retire_cycles++;
                }
            }
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_refill_error_edge)
                cur.l1d_refill_error_edge_cycles++;
            if (dut.fatal_halt_o)
                cur.fatal_halt_cycles++;

            // Section A: Store Buffer Full episode and blocker tracking
            if (sb_full_this_cycle) {
                curr_sb_full_len++;
                if (l_state != 0) cur.sb_full_blocked_l1d_busy++;
                if (srb_busy_val) cur.sb_full_blocked_srb_busy++;
                if (!dut.ram_req_ready_i) cur.sb_full_blocked_dram_bus++;
                if (drain_req_issued) cur.sb_full_hit_drain_active++;
                if (store_ack) cur.sb_full_drain_completions++;

                uint64_t store_pa = dut.rootp->fursoy_s0_soc__DOT__core__DOT__dtrans_pa;
                uint32_t s_funct3 = (fe_insn >> 12) & 7;
                int s_sz = s_funct3 & 3;
                uint8_t s_bo = store_pa & 7;
                uint8_t s_mask = (s_sz == 0) ? (1 << s_bo) : ((s_sz == 1) ? (3 << (s_bo & ~1)) : ((s_sz == 2) ? (0x0F << (s_bo & ~3)) : 0xFF));
                bool match_dw = false, match_ex = false;
                for (int i = 0; i < 8; i++) {
                    if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__valid_q[i]) {
                        uint64_t epa = (uint64_t)dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__paddr_q[i] << 3;
                        if ((epa >> 3) == (store_pa >> 3)) match_dw = true;
                        if (epa == (store_pa & ~7ULL)) {
                            uint8_t em = dut.rootp->fursoy_s0_soc__DOT__core__DOT__sb__DOT__byte_mask_q[i];
                            if (em == s_mask) match_ex = true;
                        }
                    }
                }
                if (match_dw) cur.sb_full_coalesce_same_dword_cycles++;
                if (match_ex) cur.sb_full_coalesce_exact_addr_cycles++;
            } else {
                if (curr_sb_full_len > 0) {
                    cur.sample_sb_full_episode(curr_sb_full_len);
                    cur.shadow_sb_full_stall_cycles_d10 += (curr_sb_full_len > 2 ? curr_sb_full_len - 2 : 0);
                    cur.shadow_sb_full_stall_cycles_d12 += (curr_sb_full_len > 4 ? curr_sb_full_len - 4 : 0);
                    cur.shadow_sb_full_stall_cycles_d16 += (curr_sb_full_len > 8 ? curr_sb_full_len - 8 : 0);
                    curr_sb_full_len = 0;
                }
            }

            // Section B: Bus-idle and redirect tracking for L1I Next-Line Prefetch
            bool bus_idle = (f_state == 1 || f_state == 0) && (l_state == 0) && !srb_busy_val && (mmu_state == 0) && dut.ram_req_ready_i;
            if (bus_idle) cur.l1i_nlp_bus_idle_cycles++;
            if (!bus_idle && f_state == 3) cur.l1i_nlp_bus_conflicts_l1d++;
            if (red_branch || red_trap || red_mret || red_sret || red_fence_i || red_sfence) {
                for (auto& c : nlp_candidates) {
                    if (c.valid) cur.l1i_nlp_redirects_before_use++;
                }
            }

            if (l_state == 2 /* EVICT_REQ */ || (is_load_miss_detect && is_dirty_victim)) {
                in_dirty_miss = true;
            } else if (l_state == 0 /* IDLE */ && !is_load_miss_detect) {
                in_dirty_miss = false;
            }

            // Sample FSM latency distributions (Task 2)
            if (is_load_miss_detect) {
                if (is_dirty_victim) {
                    dirty_evict_start_cycle = cur.cycles;
                    dirty_miss_start_cycle = cur.cycles;
                    in_dirty_evict_meas = true;
                    in_dirty_miss_meas = true;
                } else {
                    clean_miss_start_cycle = cur.cycles;
                    in_clean_load_miss = true;
                }
            }

            if (in_clean_load_miss && (l_state == 6 /* INSTALL */) && (prev_l_state != 6)) {
                uint64_t lat = cur.cycles - clean_miss_start_cycle + 1;
                cur.sample_clean_miss(lat);
                in_clean_load_miss = false;
            }

            if (in_dirty_evict_meas && (l_state == 3 /* EVICT_BURST */) &&
                (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__beat_cnt_q == 7) &&
                dut.ram_req_valid_o && dut.ram_req_ready_i) {
                uint64_t lat = cur.cycles - dirty_evict_start_cycle + 1;
                cur.sample_dirty_evict(lat);
                in_dirty_evict_meas = false;
                dirty_refill_start_cycle = cur.cycles + 1;
                in_dirty_refill_meas = true;
            }

            if (in_dirty_refill_meas && (l_state == 6 /* INSTALL */) && (prev_l_state != 6)) {
                uint64_t lat = cur.cycles - dirty_refill_start_cycle + 1;
                cur.sample_dirty_refill(lat);
                in_dirty_refill_meas = false;
            }

            if (in_dirty_miss_meas && (l_state == 6 /* INSTALL */) && (prev_l_state != 6)) {
                uint64_t lat = cur.cycles - dirty_miss_start_cycle + 1;
                cur.sample_dirty_total(lat);
                in_dirty_miss_meas = false;
            }

            if (l_state == 6 /* INSTALL */) {
                if (prev_l_state != 6) {
                    install_start_cycle = cur.cycles;
                    in_install_meas = true;
                }
            } else if (in_install_meas) {
                uint64_t lat = cur.cycles - install_start_cycle;
                cur.sample_install(lat);
                in_install_meas = false;
            }

            if (true_arb_stall) {
                if (!in_sb_collision) {
                    sb_collision_start_cycle = cur.cycles;
                    in_sb_collision = true;
                }
            } else if (in_sb_collision) {
                uint64_t lat = cur.cycles - sb_collision_start_cycle;
                cur.sample_sb_collision(lat);
                in_sb_collision = false;
            }

            prev_l_state = l_state;

            // Update pending bubble for next cycle if redirect or refill completion occurred
            if (red_trap) {
                pending_bubble = BUBBLE_TRAP;
            } else if (red_mret || red_sret) {
                pending_bubble = BUBBLE_MRET_SRET;
            } else if (red_branch) {
                pending_bubble = BUBBLE_BRANCH;
            } else if (red_fence_i) {
                pending_bubble = BUBBLE_FENCE_I;
            } else if (red_sfence) {
                pending_bubble = BUBBLE_SFENCE;
            } else if (red_csr) {
                pending_bubble = BUBBLE_CSR;
            } else if (f_state == 4 && dut.imem_rsp_valid_i && (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__refill_beat_cnt == 7)) {
                pending_bubble = BUBBLE_REFILL_HANDOFF;
            }

            // Trap tracking
            if (in_trap) {
                cur.trap_overhead_cycles++;
            }

            // TLB event tracking
            bool itlb_hit = dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__itlb_lookup_valid &&
                            (dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__itlb__DOT__match != 0) &&
                            dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__itlb_perm_ok &&
                            dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__pmp_allow_itlb_hit;
            bool itlb_miss = dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__itlb_lookup_valid &&
                             (dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__itlb__DOT__match == 0);
            bool dtlb_hit = dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__dtlb_lookup_valid &&
                            (dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__dtlb__DOT__match != 0) &&
                            dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__dtlb_perm_ok &&
                            dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__pmp_allow_dtlb_hit;
            bool dtlb_miss = dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__dtlb_lookup_valid &&
                             (dut.rootp->fursoy_s0_soc__DOT__core__DOT__mmu__DOT__dtlb__DOT__match == 0);

            if (itlb_hit) cur.itlb_hit_count++;
            if (itlb_miss) { cur.itlb_miss_count++; cur.itlb_refill_count++; }
            if (dtlb_hit) cur.dtlb_hit_count++;
            if (dtlb_miss) { cur.dtlb_miss_count++; cur.dtlb_refill_count++; }

            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__l1i_hit_event_o) cur.l1i_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__l1i_miss_event_o) cur.l1i_miss_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i__DOT__l1i_refill_event_o) cur.l1i_refill_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_early_restart_event) cur.l1i_early_restart_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_streaming_hit_event) cur.l1i_streaming_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_refill_abort_event) cur.l1i_refill_abort_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_candidate_event) cur.l1i_nlp_candidate_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_issued_event) cur.l1i_nlp_issued_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_suppressed_page) cur.l1i_nlp_suppressed_page_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_suppressed_pmp) cur.l1i_nlp_suppressed_pmp_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_suppressed_resident) cur.l1i_nlp_suppressed_resident_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_suppressed_duplicate) cur.l1i_nlp_suppressed_duplicate_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_useful_hit_event) cur.l1i_nlp_useful_hit_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_streaming_hit_event) cur.l1i_nlp_streaming_hit_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_preempted_event) cur.l1i_nlp_preempted_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_dormant_abandon_event) cur.l1i_nlp_dormant_abandon_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_discard_redirect) cur.l1i_nlp_discard_redirect_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_discard_maint) cur.l1i_nlp_discard_maint_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_discard_error) cur.l1i_nlp_discard_error_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_promote_event) cur.l1i_nlp_promote_events++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_hidden_cycles) cur.l1i_nlp_hidden_cycles_total += dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1i_nlp_hidden_cycles;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_hit_event_o) cur.l1d_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_miss_event_o) cur.l1d_miss_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_evict_event_o) cur.l1d_evict_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_refill_event_o) cur.l1d_refill_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_load_hit_o) cur.l1d_load_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_load_miss_o) cur.l1d_load_miss_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_store_hit_o) cur.l1d_store_hit_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d__DOT__l1d_store_miss_o) cur.l1d_store_miss_count++;
            if (dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_er_event) {
                cur.l1d_er_events++;
                cur.l1d_er_saved_cycles_total += dut.rootp->fursoy_s0_soc__DOT__core__DOT__l1d_er_saved_cycles;
            }

            dut.clk_i = 1;
            dut.eval();
            cur.cycles++;

            // Trap arrival
            if (took_trap) {
                in_trap = true;
                if (!to_s) {
                    uint64_t mcause = dut.csr_mcause_o;
                    if (mcause == 9) cur.sbi_ecall_count++;
                    else if (mcause == 0x8000000000000007ULL) cur.mtip_count++;
                    else cur.sync_trap_count++;
                } else {
                    uint64_t scause = dut.rootp->fursoy_s0_soc__DOT__core__DOT__scause_q;
                    if (scause == 0x8000000000000005ULL) cur.stip_count++;
                    else if (scause == 0x8000000000000009ULL) cur.seip_count++;
                    else if (scause == 8) cur.user_ecall_count++;
                    else cur.sync_trap_count++;
                }
            }

            // Periodic heartbeat
            if (cur.cycles > 0 && cur.cycles % 5000000 == 0) {
                std::cerr << "[PERF_HEARTBEAT] cycle=" << cur.cycles << " commits=" << cur.commits
                          << " ipc=" << std::fixed << std::setprecision(4)
                          << (double(cur.commits) / double(cur.cycles))
                          << " pc=0x" << std::hex << last_commit_pc
                          << " sbi=" << std::dec << cur.sbi_ecall_count
                          << " mtip=" << cur.mtip_count
                          << " stip=" << cur.stip_count
                          << " seip=" << cur.seip_count
                          << " ptw_walks=" << cur.ptw_walks_total
                          << " ptw_cycles=" << cur.ptw_cycles_total
                          << " itlb_h=" << cur.itlb_hit_count
                          << " dtlb_h=" << cur.dtlb_hit_count
                          << " l1i_h=" << cur.l1i_hit_count
                          << " l1i_m=" << cur.l1i_miss_count
                          << " l1i_refill=" << cur.cycles_l1i_miss_refill
                          << " l1d_h=" << cur.l1d_hit_count
                          << " l1d_m=" << cur.l1d_miss_count
                          << " lsu_stall=" << cur.cycles_lsu_stall << "\n";
            }

            ip = nip;
            ii = nii;
            dp = ndp;
            dd = ndd;

            // Stop condition: all benchmarks complete + settling
            if (seen_bench_complete && cur.cycles >= cycle_bench_complete + 2001) {
                break;
            }
        }

        if (curr_sb_full_len > 0) {
            cur.sample_sb_full_episode(curr_sb_full_len);
            cur.shadow_sb_full_stall_cycles_d10 += (curr_sb_full_len > 2 ? curr_sb_full_len - 2 : 0);
            cur.shadow_sb_full_stall_cycles_d12 += (curr_sb_full_len > 4 ? curr_sb_full_len - 4 : 0);
            cur.shadow_sb_full_stall_cycles_d16 += (curr_sb_full_len > 8 ? curr_sb_full_len - 8 : 0);
            curr_sb_full_len = 0;
        }
        for (const auto& c : nlp_candidates) {
            if (c.valid) cur.l1i_nlp_useless_prefetches++;
        }

        std::cerr << "\n[PERF_TB] Completed at cycle=" << cur.cycles << " commits=" << cur.commits << "\n";

        // Calculate phase deltas
        PerfRecord boot_delta = diff_records(rec_init_reached, rec_boot_start);
        PerfRecord cpu_delta = diff_records(rec_cpu_end, rec_cpu_start);
        PerfRecord mem_delta = diff_records(rec_mem_end, rec_mem_start);

        bool pass = seen_init_banner && seen_bench_complete;

        // Emit formatted machine-readable JSON
        std::cout << "\n--- PERF JSON REPORT ---\n";
        std::cout << "{\n"
                  << "  \"status\": \"" << (pass ? "pass" : "fail") << "\",\n"
                  << "  \"scope\": \"Store Buffer v2 (SB8) performance profiling (Fursoy Slice-0)\",\n"
                  << "  \"l1d_er_enabled\": " << (disable_l1d_er ? "false" : "true") << ",\n"
                  << "  \"seen_reset\": " << (seen_reset ? "true" : "false") << ",\n"
                  << "  \"seen_handoff\": " << (seen_handoff ? "true" : "false") << ",\n"
                  << "  \"seen_satp_sv39\": " << (seen_satp_sv39 ? "true" : "false") << ",\n"
                  << "  \"seen_init_banner\": " << (seen_init_banner ? "true" : "false") << ",\n"
                  << "  \"seen_cpu_workload\": " << (seen_cpu_end ? "true" : "false") << ",\n"
                  << "  \"seen_mem_workload\": " << (seen_mem_end ? "true" : "false") << ",\n"
                  << "  \"seen_benchmarks_complete\": " << (seen_bench_complete ? "true" : "false") << ",\n"
                  << "  \"cycle_handoff\": " << cycle_handoff << ",\n"
                  << "  \"cycle_init_banner\": " << cycle_init_banner << ",\n"
                  << "  \"cycle_bench_complete\": " << cycle_bench_complete << ",\n"
                  << "  \"full_execution\": {\n"
                  << dump_json_record(cur, "    ") << "\n"
                  << "  },\n"
                  << "  \"boot_phase\": {\n"
                  << dump_json_record(boot_delta, "    ") << "\n"
                  << "  },\n"
                  << "  \"cpu_heavy_workload\": {\n"
                  << dump_json_record(cpu_delta, "    ") << "\n"
                  << "  },\n"
                  << "  \"memory_heavy_workload\": {\n"
                  << dump_json_record(mem_delta, "    ") << "\n"
                  << "  }\n"
                  << "}\n";

    } catch (const std::exception& e) {
        std::cerr << "ERROR: " << e.what() << "\n";
        return 1;
    }

    return 0;
}
