#ifndef FURSOY_S2_SWMR_SCOREBOARD_H
#define FURSOY_S2_SWMR_SCOREBOARD_H

// =============================================================================
// Fursoy Slice-2 Cycle-by-Cycle SWMR Coherence & Inclusion Scoreboard
// =============================================================================
// Probes per-hart L1D (valid_array, dirty_array, coh_state_array, tag_array,
// bank_data, wbb_q) and shared L2 directory (valid_arr, tag_arr, dir_state_arr,
// sharer_arr, l2_dirty_arr, data_arr) every rising edge after reset.
// =============================================================================

#include <array>
#include <cstdint>
#include <cstring>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "Vfursoy_s2_soc___024root.h"

static constexpr uint8_t SB_MESI_I = 0;
static constexpr uint8_t SB_MESI_S = 1;
static constexpr uint8_t SB_MESI_E = 2;
static constexpr uint8_t SB_MESI_M = 3;

struct SbStats {
  uint64_t cycle_checks = 0;
  uint64_t swmr_violations = 0;
  uint64_t metadata_violations = 0;
  uint64_t inclusion_violations = 0;
  uint64_t data_coherence_violations = 0;
  uint64_t max_live_l1d_lines = 0;
  uint64_t seen_mesi_s_multi_hart = 0;
  uint64_t seen_mesi_e = 0;
  uint64_t seen_mesi_m = 0;
  uint64_t seen_wbb_dirty = 0;
  std::string first_error;
};

template <int NH>
class S2SwmrScoreboard {
 public:
  SbStats stats{};

  struct HartL1DView {
    const VlUnpacked<VlUnpacked<CData/*0:0*/, 4>, 64> *valid;
    const VlUnpacked<VlUnpacked<CData/*0:0*/, 4>, 64> *dirty;
    const VlUnpacked<VlUnpacked<CData/*1:0*/, 4>, 64> *coh_state;
    const VlUnpacked<VlUnpacked<QData/*43:0*/, 4>, 64> *tag;
    const VlUnpacked<VlUnpacked<VlUnpacked<QData/*63:0*/, 4>, 64>, 8> *bank_data;
    const VlUnpacked<VlWide<20>/*628:0*/, 2> *wbb_q;
    const CData/*0:0*/ *refill_busy;
    const CData/*2:0*/ *rsp_fifo_count;
  };

  void bind(Vfursoy_s2_soc___024root *rootp) {
    root_ = rootp;
    bind_harts();
  }

  bool check_cycle(uint64_t cycle) {
    if (!root_) return false;
    stats.cycle_checks++;

    struct LineCopy {
      int hart;
      uint8_t state;
      uint8_t dirty;
      bool refill_busy;
      std::array<uint64_t, 8> words;
    };

    struct WbbCopy {
      int hart;
      bool draining;
      bool dirty;
      std::array<uint64_t, 8> words;
    };

    std::unordered_map<uint64_t, std::vector<LineCopy>> by_line;
    std::unordered_map<uint64_t, std::vector<WbbCopy>> wbb_by_line;
    by_line.reserve(256);
    wbb_by_line.reserve(16);

    uint64_t live_lines = 0;

    for (int h = 0; h < NH; h++) {
      const auto &v = harts_[h];
      bool rbusy = (*(v.refill_busy) != 0) || (*(v.rsp_fifo_count) != 0);
      for (int s = 0; s < 64; s++) {
        uint64_t seen_tags[4]{};
        int seen_cnt = 0;
        for (int w = 0; w < 4; w++) {
          uint8_t val = (*v.valid)[s][w];
          uint8_t dir = (*v.dirty)[s][w];
          uint8_t st  = (*v.coh_state)[s][w];
          uint64_t tag = (*v.tag)[s][w];

          if (!val) {
            if (dir != 0 || st != SB_MESI_I) {
              record_meta(cycle, "Invalid L1D line has dirty=" + std::to_string(dir) + " state=" + std::to_string(st));
              return false;
            }
            continue;
          }

          if (st == SB_MESI_I) {
            record_meta(cycle, "Valid L1D line has MESI_I state");
            return false;
          }
          if (dir && st != SB_MESI_M) {
            record_meta(cycle, "Dirty L1D line is not MESI_M (state=" + std::to_string(st) + ")");
            return false;
          }
          for (int k = 0; k < seen_cnt; k++) {
            if (seen_tags[k] == tag) {
              record_meta(cycle, "Duplicate tag in L1D set " + std::to_string(s) + " hart " + std::to_string(h));
              return false;
            }
          }
          seen_tags[seen_cnt++] = tag;

          if (st == SB_MESI_E) stats.seen_mesi_e++;
          if (st == SB_MESI_M) stats.seen_mesi_m++;
          live_lines++;

          uint64_t line_addr = ((tag & ((1ULL << 44) - 1)) << 6) | uint64_t(s);
          LineCopy lc{};
          lc.hart = h;
          lc.state = st;
          lc.dirty = dir;
          lc.refill_busy = rbusy;
          for (int b = 0; b < 8; b++) {
            lc.words[b] = (*v.bank_data)[b][s][w];
          }
          by_line[line_addr].push_back(lc);
        }
      }

      // Check WBB entries: wbb_entry_t = {valid[628], dirty[627], line_addr[626:577], data[576:65], dirty_mask[64:1], draining[0]}
      for (int i = 0; i < 2; i++) {
        const auto &wbb = (*v.wbb_q)[i];
        bool wvalid    = extract_bit(wbb, 628);
        bool wdirty    = extract_bit(wbb, 627);
        bool wdraining = extract_bit(wbb, 0);
        if (!wvalid) continue;

        if (!wdraining && !wdirty) {
          record_meta(cycle, "Non-draining clean entry leaked in WBB slot " + std::to_string(i) + " hart " + std::to_string(h));
          return false;
        }
        uint64_t wline_addr = extract_u64(wbb, 577, 50);
        WbbCopy wc{};
        wc.hart = h;
        wc.draining = wdraining;
        wc.dirty = wdirty;
        for (int b = 0; b < 8; b++) {
          wc.words[b] = extract_u64(wbb, 65 + 64 * b, 64);
        }
        if (wdirty) {
          stats.seen_wbb_dirty++;
          wbb_by_line[wline_addr].push_back(wc);
        }
      }
    }

    if (live_lines > stats.max_live_l1d_lines) {
      stats.max_live_l1d_lines = live_lines;
    }

    // Static bit-layout helpers for dir_mshr_entry_t parameterized by NH
    constexpr int hw = (NH > 2) ? 2 : ((NH == 2) ? 1 : 1);
    constexpr int mshr_w = 1147 + 2 * hw + 3 * NH;
    constexpr int valid_bit = mshr_w - 1;
    constexpr int line_lsb = mshr_w - (1 + 3 + 2 + hw + 2 + 2 + 1 + 50);
    constexpr int vic_act_bit = line_lsb - (3 + 1 + 1 + 512 + 1 + 2 + NH + hw + 1);
    constexpr int vic_addr_lsb = vic_act_bit - 1 - 50;

    for (const auto &kv : by_line) {
      uint64_t line_addr = kv.first;
      const auto &copies = kv.second;
      int m_cnt = 0, e_cnt = 0, s_cnt = 0;
      const LineCopy *first_s = nullptr;

      for (const auto &c : copies) {
        if (c.state == SB_MESI_M) m_cnt++;
        else if (c.state == SB_MESI_E) e_cnt++;
        else if (c.state == SB_MESI_S) {
          s_cnt++;
          if (!first_s && !c.refill_busy) first_s = &c;
        }
      }
      if (s_cnt >= 2) stats.seen_mesi_s_multi_hart++;

      // SWMR: At most one writer/exclusive, and no sharers alongside writer/exclusive
      if ((m_cnt + e_cnt) > 1 || ((m_cnt + e_cnt) == 1 && s_cnt > 0)) {
        std::ostringstream oss;
        oss << "SWMR violated on line 0x" << std::hex << (line_addr << 6)
            << std::dec << ": M=" << m_cnt << " E=" << e_cnt << " S=" << s_cnt;
        record_swmr(cycle, oss.str());
        return false;
      }

      // Cross-hart Shared copy data equality
      if (first_s) {
        for (const auto &c : copies) {
          if (c.state == SB_MESI_S && !c.refill_busy && c.words != first_s->words) {
            std::ostringstream oss;
            oss << "MESI_S data divergence on line 0x" << std::hex << (line_addr << 6)
                << " between hart " << first_s->hart << " and hart " << c.hart;
            record_data(cycle, oss.str());
            return false;
          }
        }
      }

      // L2 lookup for inclusion & E/S L2 freshness (skip if line_addr in active DIR_MSHR or Stage C1)
      uint64_t l2_set = line_addr & 0x1FFULL;
      uint64_t l2_tag = (line_addr >> 9) & ((1ULL << 41) - 1);
      int l2_way = -1;
      for (int w = 0; w < 8; w++) {
        if (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__valid_arr[l2_set][w] &&
            (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__tag_arr[l2_set][w] == l2_tag)) {
          l2_way = w;
          break;
        }
      }

      bool c1_match = (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c1_valid_q != 0) &&
                      (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c1_addr_q == line_addr);
      bool c2_match = (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_valid_q != 0) &&
                      (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_addr_q == line_addr);
      bool any_mshr = c1_match || c2_match;
      if (!any_mshr) {
        for (int m = 0; m < 8; m++) {
          const auto &me = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__dir_mshr_q[m];
          if (!extract_bit(me, valid_bit)) continue;
          if (extract_u64(me, line_lsb, 50) == line_addr) {
            any_mshr = true;
            break;
          }
        }
      }

      if (l2_way < 0) {
        // Might be under victim eviction inside Stage C2 or a DIR_MSHR; check victim_addr
        bool vic_evicting = (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_valid_q != 0) &&
                            (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_vic_active_q != 0) &&
                            (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_vic_addr_q == line_addr);
        for (int m = 0; m < 8 && !vic_evicting; m++) {
          const auto &me = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__dir_mshr_q[m];
          if (!extract_bit(me, valid_bit)) continue;
          if (extract_bit(me, vic_act_bit) && extract_u64(me, vic_addr_lsb, 50) == line_addr) {
            vic_evicting = true;
            break;
          }
        }
        if (!vic_evicting) {
          std::ostringstream oss;
          oss << "L2 inclusion violated on line 0x" << std::hex << (line_addr << 6);
          record_inc(cycle, oss.str());
          return false;
        }
      } else if (!any_mshr) {
        // Verify L2 directory metadata matches L1D SWMR ownership when quiescent in Hub
        uint8_t l2_dst = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__dir_state_arr[l2_set][l2_way];
        uint8_t l2_sv  = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__sharer_arr[l2_set][l2_way];
        uint8_t l2_own = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__owner_arr[l2_set][l2_way];

        if (m_cnt == 1) {
          int mh = -1;
          for (const auto &c : copies) if (c.state == SB_MESI_M) mh = c.hart;
          if (!((l2_dst == 3 /*DIR_M*/ || l2_dst == 2 /*DIR_E*/) && (l2_own == mh) && (l2_sv == (1u << mh)))) {
            std::ostringstream oss;
            oss << "L2 DIR_M/E owner mismatch on line 0x" << std::hex << (line_addr << 6)
                << std::dec << ": L1D M hart=" << mh << " vs L2 dst=" << int(l2_dst)
                << " own=" << int(l2_own) << " sv=" << int(l2_sv);
            record_meta(cycle, oss.str());
            return false;
          }
        } else if (e_cnt == 1) {
          int eh = -1;
          for (const auto &c : copies) if (c.state == SB_MESI_E) eh = c.hart;
          if (!((l2_dst == 2 /*DIR_E*/) && (l2_own == eh) && (l2_sv == (1u << eh)))) {
            std::ostringstream oss;
            oss << "L2 DIR_E owner mismatch on line 0x" << std::hex << (line_addr << 6)
                << std::dec << ": L1D E hart=" << eh << " vs L2 dst=" << int(l2_dst)
                << " own=" << int(l2_own) << " sv=" << int(l2_sv);
            record_meta(cycle, oss.str());
            return false;
          }
        } else if (s_cnt >= 1) {
          uint8_t smask = 0;
          int sh0 = -1;
          bool sh0_rbusy = false;
          for (const auto &c : copies) {
            if (c.state == SB_MESI_S) {
              smask |= uint8_t(1u << c.hart);
              sh0 = c.hart;
              sh0_rbusy = c.refill_busy;
            }
          }
          bool s_ok = (l2_dst == 1 /*DIR_S*/ && ((l2_sv & smask) == smask)) ||
                      (s_cnt == 1 && sh0_rbusy && l2_dst == 3 /*DIR_M*/ && l2_own == sh0 && l2_sv == (1u << sh0));
          if (!s_ok) {
            std::ostringstream oss;
            oss << "L2 DIR_S sharer mismatch on line 0x" << std::hex << (line_addr << 6)
                << std::dec << ": L1D smask=" << int(smask) << " vs L2 dst=" << int(l2_dst)
                << " sv=" << int(l2_sv);
            record_meta(cycle, oss.str());
            return false;
          }
        }

        if (m_cnt == 0) {
          // No M-owner and no in-flight MSHR: L2 data must match any E or S L1D copy!
          const auto &l2d = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__data_arr[l2_set][l2_way];
          std::array<uint64_t, 8> l2_words{};
          for (int b = 0; b < 8; b++) {
            l2_words[b] = uint64_t(l2d[2 * b]) | (uint64_t(l2d[2 * b + 1]) << 32);
          }
          for (const auto &c : copies) {
            if ((c.state == SB_MESI_E || c.state == SB_MESI_S) && !c.refill_busy && c.words != l2_words) {
              std::ostringstream oss;
              oss << "Clean L1D (" << (c.state == SB_MESI_E ? "E" : "S") << ") hart " << c.hart
                  << " diverges from L2 data on line 0x" << std::hex << (line_addr << 6);
              record_data(cycle, oss.str());
              return false;
            }
          }
        }
      }
    }

    // Verify dirty WBB SWMR exclusivity, inclusion, and L2 DIR_M ownership consistency
    for (const auto &wkv : wbb_by_line) {
      uint64_t wline_addr = wkv.first;
      const auto &wcopies = wkv.second;
      if (wcopies.size() > 1) {
        std::ostringstream oss;
        oss << "Multiple dirty WBB copies on line 0x" << std::hex << (wline_addr << 6);
        record_swmr(cycle, oss.str());
        return false;
      }
      if (by_line.find(wline_addr) != by_line.end()) {
        std::ostringstream oss;
        oss << "Dirty WBB overlaps live L1D copy on line 0x" << std::hex << (wline_addr << 6);
        record_swmr(cycle, oss.str());
        return false;
      }

      uint64_t l2_set = wline_addr & 0x1FFULL;
      uint64_t l2_tag = (wline_addr >> 9) & ((1ULL << 41) - 1);
      int l2_way = -1;
      for (int w = 0; w < 8; w++) {
        if (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__valid_arr[l2_set][w] &&
            (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__tag_arr[l2_set][w] == l2_tag)) {
          l2_way = w;
          break;
        }
      }

      bool c1_match = (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c1_valid_q != 0) &&
                      (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c1_addr_q == wline_addr);
      bool c2_match = (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_valid_q != 0) &&
                      (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_addr_q == wline_addr);
      bool any_mshr = c1_match || c2_match;
      bool vic_evicting = (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_valid_q != 0) &&
                          (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_vic_active_q != 0) &&
                          (root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__c2_vic_addr_q == wline_addr);
      for (int m = 0; m < 8; m++) {
        const auto &me = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__dir_mshr_q[m];
        if (!extract_bit(me, valid_bit)) continue;
        if (extract_u64(me, line_lsb, 50) == wline_addr) any_mshr = true;
        if (extract_bit(me, vic_act_bit) && extract_u64(me, vic_addr_lsb, 50) == wline_addr) vic_evicting = true;
      }

      if (l2_way < 0) {
        if (!vic_evicting) {
          std::ostringstream oss;
          oss << "L2 inclusion violated for dirty WBB line 0x" << std::hex << (wline_addr << 6);
          record_inc(cycle, oss.str());
          return false;
        }
      } else if (!any_mshr) {
        uint8_t l2_dst = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__dir_state_arr[l2_set][l2_way];
        uint8_t l2_sv  = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__sharer_arr[l2_set][l2_way];
        uint8_t l2_own = root_->fursoy_s2_soc__DOT__gen_coherence__DOT__u_coherence_mgr__DOT__u_l2__DOT__owner_arr[l2_set][l2_way];
        int wh = wcopies[0].hart;
        if (!((l2_dst == 3 /*DIR_M*/ || l2_dst == 2 /*DIR_E*/) && (l2_own == wh) && (l2_sv == (1u << wh)))) {
          std::ostringstream oss;
          oss << "L2 DIR_M/E mismatch for dirty WBB hart " << wh << " line 0x" << std::hex << (wline_addr << 6)
              << std::dec << ": L2 dst=" << int(l2_dst) << " own=" << int(l2_own) << " sv=" << int(l2_sv);
          record_meta(cycle, oss.str());
          return false;
        }
      }
    }
    return true;
  }

 private:
  Vfursoy_s2_soc___024root *root_ = nullptr;
  std::array<HartL1DView, NH> harts_{};

  template <typename WideT>
  static bool extract_bit(const WideT &w, int bit) {
    return ((w[bit / 32] >> (bit % 32)) & 1U) != 0;
  }

  template <typename WideT>
  static uint64_t extract_u64(const WideT &w, int lsb, int width) {
    uint64_t out = 0;
    for (int i = 0; i < width; i++) {
      if (extract_bit(w, lsb + i)) out |= (1ULL << i);
    }
    return out;
  }

  void record_swmr(uint64_t cyc, const std::string &msg) {
    stats.swmr_violations++;
    if (stats.first_error.empty()) stats.first_error = "[cyc " + std::to_string(cyc) + "] " + msg;
  }
  void record_meta(uint64_t cyc, const std::string &msg) {
    stats.metadata_violations++;
    if (stats.first_error.empty()) stats.first_error = "[cyc " + std::to_string(cyc) + "] " + msg;
  }
  void record_inc(uint64_t cyc, const std::string &msg) {
    stats.inclusion_violations++;
    if (stats.first_error.empty()) stats.first_error = "[cyc " + std::to_string(cyc) + "] " + msg;
  }
  void record_data(uint64_t cyc, const std::string &msg) {
    stats.data_coherence_violations++;
    if (stats.first_error.empty()) stats.first_error = "[cyc " + std::to_string(cyc) + "] " + msg;
  }

  void bind_harts();
};

template <>
inline void S2SwmrScoreboard<2>::bind_harts() {
  harts_[0] = {
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__dirty_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__coh_state_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__wbb_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q,
  };
  harts_[1] = {
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__dirty_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__coh_state_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__wbb_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q,
  };
}

#if NUM_HARTS == 4
template <>
inline void S2SwmrScoreboard<4>::bind_harts() {
  harts_[0] = {
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__dirty_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__coh_state_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__wbb_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__0__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q,
  };
  harts_[1] = {
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__dirty_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__coh_state_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__wbb_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__1__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q,
  };
  harts_[2] = {
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__dirty_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__coh_state_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__wbb_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__2__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q,
  };
  harts_[3] = {
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__valid_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__dirty_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__coh_state_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__tag_array,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__bank_data,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__wbb_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__refill_busy_q,
    &root_->fursoy_s2_soc__DOT__gen_harts__BRA__3__KET____DOT__u_core__DOT__u_backend__DOT__u_lsu__DOT__u_l1d__DOT__rsp_fifo_count_q,
  };
}
#endif

#endif // FURSOY_S2_SWMR_SCOREBOARD_H
