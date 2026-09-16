#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

constexpr uint64_t RAM_BASE = 0x80000000ULL;
constexpr uint64_t RAM_SIZE = 128 * 1024ULL; // 128 KiB
constexpr uint64_t TOHOST_ADDR = 0x80010000ULL;
constexpr uint64_t SIG_ADDR = 0x80010010ULL;

struct ElfLoader {
    static void load(const std::string& path, std::vector<uint8_t>& ram, uint64_t& entry) {
        std::ifstream file(path, std::ios::binary);
        if (!file.is_open()) {
            throw std::runtime_error("Cannot open ELF: " + path);
        }
        std::vector<uint8_t> blob((std::istreambuf_iterator<char>(file)),
                                   std::istreambuf_iterator<char>());
        if (blob.size() < 64) {
            throw std::runtime_error("File too small for ELF64 header");
        }
        if (blob[0] != 0x7f || blob[1] != 'E' || blob[2] != 'L' || blob[3] != 'F' ||
            blob[4] != 2 || blob[5] != 1) {
            throw std::runtime_error("Not little-endian ELF64");
        }
        auto read16 = [&](size_t offset) -> uint16_t {
            return blob[offset] | (uint16_t(blob[offset + 1]) << 8);
        };
        auto read32 = [&](size_t offset) -> uint32_t {
            return blob[offset] | (uint32_t(blob[offset + 1]) << 8) |
                   (uint32_t(blob[offset + 2]) << 16) | (uint32_t(blob[offset + 3]) << 24);
        };
        auto read64 = [&](size_t offset) -> uint64_t {
            uint64_t val = 0;
            for (int i = 0; i < 8; ++i) val |= uint64_t(blob[offset + i]) << (8 * i);
            return val;
        };

        uint16_t machine = read16(18);
        if (machine != 243) {
            throw std::runtime_error("Unexpected machine type, expected RISC-V (243)");
        }
        entry = read64(24);
        uint64_t phoff = read64(32);
        uint16_t phentsize = read16(54);
        uint16_t phnum = read16(56);

        if (phentsize < 56) {
            throw std::runtime_error("Program header size too small");
        }

        for (uint16_t i = 0; i < phnum; ++i) {
            size_t off = phoff + i * phentsize;
            if (off + 56 > blob.size()) {
                throw std::runtime_error("Program header table overflow");
            }
            uint32_t p_type = read32(off);
            if (p_type != 1) continue; // PT_LOAD only
            uint64_t p_offset = read64(off + 8);
            uint64_t p_paddr = read64(off + 24);
            uint64_t p_filesz = read64(off + 32);
            uint64_t p_memsz = read64(off + 40);

            if (p_paddr < RAM_BASE || p_memsz > RAM_SIZE || (p_paddr - RAM_BASE) > RAM_SIZE - p_memsz) {
                throw std::runtime_error("PT_LOAD segment outside RAM bounds");
            }
            if (p_offset + p_filesz > blob.size()) {
                throw std::runtime_error("Segment file size exceeds ELF file size");
            }
            uint64_t ram_off = p_paddr - RAM_BASE;
            for (uint64_t b = 0; b < p_filesz; ++b) {
                ram[ram_off + b] = blob[p_offset + b];
            }
            // Memory between p_filesz and p_memsz remains zero.
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <elf_path> [max_cycles]\n";
        return 1;
    }
    std::string elf_path = argv[1];
    uint64_t max_cycles = (argc > 2) ? std::stoull(argv[2]) : 50000ULL;

    std::vector<uint8_t> ram(RAM_SIZE, 0);
    uint64_t entry_point = 0;
    try {
        ElfLoader::load(elf_path, ram, entry_point);
    } catch (const std::exception& e) {
        std::cerr << "ELF_LOAD_ERROR: " << e.what() << '\n';
        return 1;
    }

    Vfursoy_s0_core dut;
    dut.clk_i = 0;
    dut.rst_i = 1;
    dut.irq_software_i = 0;
    dut.irq_timer_i = 0;
    dut.irq_external_i = 0;
    dut.imem_req_ready_i = 1;
    dut.imem_rsp_valid_i = 0;
    dut.imem_rsp_data_i = 0;
    dut.imem_rsp_error_i = 0;
    dut.dmem_req_ready_i = 1;
    dut.dmem_req_error_i = 0;
    dut.dmem_rsp_valid_i = 0;
    dut.dmem_rsp_data_i = 0;
    dut.dmem_rsp_error_i = 0;
    dut.irq_seip_i = 0;
    dut.eval();

    bool imem_pending = false;
    uint64_t imem_data = 0;
    bool next_imem_pending = false;
    uint64_t next_imem_data = 0;

    bool dmem_rsp_pending = false;
    uint64_t dmem_rsp_data = 0;
    bool next_dmem_rsp_pending = false;
    uint64_t next_dmem_rsp_data = 0;

    uint64_t cycles = 0;
    uint64_t commits = 0;
    uint64_t last_commit_pc = 0;
    uint64_t traps = 0;
    uint64_t last_trap_pc = 0;
    uint32_t last_trap_insn = 0;
    uint64_t last_trap_cause = 0;

    uint64_t tohost = 0;
    bool tohost_seen = false;
    int settle_cycles = 0;

    auto read_imem64 = [&](uint64_t addr) -> uint64_t {
        if (addr < RAM_BASE || (addr - RAM_BASE) > RAM_SIZE - 8 || (addr % 8 != 0)) {
            std::ostringstream oss;
            oss << "Out-of-range or unaligned instruction fetch: addr=0x" << std::hex << addr;
            throw std::runtime_error(oss.str());
        }
        uint64_t off = addr - RAM_BASE;
        uint64_t data = 0;
        for (unsigned i = 0; i < 8; ++i) {
            data |= uint64_t(ram[off + i]) << (8 * i);
        }
        return data;
    };

    auto read_dmem = [&](uint64_t addr, unsigned size) -> uint64_t {
        if (size > 3) {
            std::ostringstream oss;
            oss << "Invalid data read size: " << size;
            throw std::runtime_error(oss.str());
        }
        unsigned bytes = 1 << size;
        if (addr < RAM_BASE || (addr - RAM_BASE) > RAM_SIZE - bytes || (addr & (bytes - 1)) != 0) {
            std::ostringstream oss;
            oss << "Out-of-range or unaligned data read: addr=0x" << std::hex << addr << " size=" << std::dec << size;
            throw std::runtime_error(oss.str());
        }
        uint64_t off = addr - RAM_BASE;
        uint64_t data = 0;
        for (unsigned i = 0; i < bytes; ++i) {
            data |= uint64_t(ram[off + i]) << (8 * i);
        }
        return data;
    };

    auto write_dmem = [&](uint64_t addr, unsigned size, uint64_t data) {
        if (size > 3) {
            std::ostringstream oss;
            oss << "Invalid data write size: " << size;
            throw std::runtime_error(oss.str());
        }
        unsigned bytes = 1 << size;
        if (addr < RAM_BASE || (addr - RAM_BASE) > RAM_SIZE - bytes || (addr & (bytes - 1)) != 0) {
            std::ostringstream oss;
            oss << "Out-of-range or unaligned data write: addr=0x" << std::hex << addr << " size=" << std::dec << size;
            throw std::runtime_error(oss.str());
        }
        uint64_t off = addr - RAM_BASE;
        for (unsigned i = 0; i < bytes; ++i) {
            ram[off + i] = uint8_t((data >> (8 * i)) & 0xff);
        }
    };

    // Reset pulse
    for (int r = 0; r < 2; ++r) {
        dut.clk_i = 0; dut.rst_i = 1; dut.eval();
        dut.clk_i = 1; dut.rst_i = 1; dut.eval();
        ++cycles;
    }

    try {
        while (cycles < max_cycles) {
            // Phase 1: Clock falling edge
            dut.clk_i = 0;
            dut.rst_i = 0;
            dut.imem_req_ready_i = 1;
            dut.imem_rsp_valid_i = imem_pending;
            dut.imem_rsp_data_i = imem_data;
            dut.imem_rsp_error_i = 0;
            dut.dmem_req_ready_i = 1;
            dut.dmem_rsp_valid_i = dmem_rsp_pending;
            dut.dmem_rsp_data_i = dmem_rsp_data;
            dut.eval();

            bool imem_rsp_fire = imem_pending && dut.imem_rsp_ready_o;
            bool dmem_rsp_fire = dmem_rsp_pending && dut.dmem_rsp_ready_o;
            bool imem_req_fire = dut.imem_req_valid_o && dut.imem_req_ready_i;
            bool dmem_req_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;

            next_imem_pending = imem_pending;
            next_imem_data = imem_data;
            next_dmem_rsp_pending = dmem_rsp_pending;
            next_dmem_rsp_data = dmem_rsp_data;

            if (imem_rsp_fire) {
                next_imem_pending = false;
            }
            if (imem_req_fire) {
                next_imem_data = read_imem64(dut.imem_req_addr_o);
                next_imem_pending = true;
            }

            if (dmem_rsp_fire) {
                next_dmem_rsp_pending = false;
            }
            if (dmem_req_fire) {
                uint64_t daddr = dut.dmem_req_addr_o;
                unsigned dsize = dut.dmem_req_size_o;
                if (dut.dmem_req_store_o) {
                    uint64_t sdata = dut.dmem_req_store_data_o;
                    write_dmem(daddr, dsize, sdata);
                    if (daddr >= TOHOST_ADDR && daddr < TOHOST_ADDR + 8) {
                        if (daddr != TOHOST_ADDR || dsize != 3) {
                            std::ostringstream oss;
                            oss << "Invalid tohost write: non-64-bit or unaligned store (addr=0x"
                                << std::hex << daddr << " size=" << std::dec << dsize << ")";
                            throw std::runtime_error(oss.str());
                        }
                        tohost = sdata;
                        tohost_seen = true;
                    }
                } else {
                    next_dmem_rsp_data = read_dmem(daddr, dsize);
                    next_dmem_rsp_pending = true;
                }
            }

            bool trap_cycle = false;
            if (dut.commit_valid_o) {
                ++commits;
                last_commit_pc = dut.commit_pc_o;
                if (dut.rootp->fursoy_s0_core__DOT__is_ordinary_dram_store) {
                    uint64_t daddr = dut.rootp->fursoy_s0_core__DOT__dtrans_pa;
                    unsigned dsize = dut.rootp->fursoy_s0_core__DOT__lsu_size;
                    uint64_t sdata = dut.rootp->fursoy_s0_core__DOT__lsu_store_data;
                    if (daddr >= TOHOST_ADDR && daddr < TOHOST_ADDR + 8) {
                        if (daddr != TOHOST_ADDR || dsize != 3) {
                            std::ostringstream oss;
                            oss << "Invalid tohost write: non-64-bit or unaligned store (addr=0x"
                                << std::hex << daddr << " size=" << std::dec << dsize << ")";
                            throw std::runtime_error(oss.str());
                        }
                        tohost = sdata;
                        tohost_seen = true;
                    }
                }
            }
            if (dut.trap_valid_o) {
                ++traps;
                last_trap_pc = dut.trap_pc_o;
                last_trap_insn = dut.trap_insn_o;
                trap_cycle = true;
            }

            // Phase 2: Clock rising edge
            dut.clk_i = 1;
            dut.eval();
            ++cycles;

            if (trap_cycle) {
                last_trap_cause = dut.csr_mcause_o;
            }

            imem_pending = next_imem_pending;
            imem_data = next_imem_data;
            dmem_rsp_pending = next_dmem_rsp_pending;
            dmem_rsp_data = next_dmem_rsp_data;

            if (tohost_seen) {
                if (++settle_cycles >= 10) break;
            }
        }
    } catch (const std::exception& e) {
        dut.final();
        std::cerr << "CORE_BAREMETAL_S0_ERROR: " << e.what() << '\n';
        std::cout << "{\n";
        std::cout << "  \"status\": \"error\",\n";
        std::cout << "  \"error\": \"" << e.what() << "\",\n";
        std::cout << "  \"cycles\": " << cycles << ",\n";
        std::cout << "  \"commits\": " << commits << ",\n";
        std::cout << "  \"traps\": " << traps << "\n";
        std::cout << "}\n";
        return 1;
    }

    auto read_mem_cached = [&](uint64_t addr, unsigned size) -> uint64_t {
        uint64_t aligned_pa = addr & ~7ULL;
        uint32_t set = (aligned_pa >> 6) & 0x3f;
        uint64_t tag = aligned_pa >> 12;
        for (int w = 0; w < 4; w++) {
            if (dut.rootp->fursoy_s0_core__DOT__l1d__DOT__valid_q[set][w] &&
                dut.rootp->fursoy_s0_core__DOT__l1d__DOT__tag_q[set][w] == tag) {
                uint64_t dword = dut.rootp->fursoy_s0_core__DOT__l1d__DOT__data_q[set][w][(aligned_pa >> 3) & 7];
                unsigned shift = (addr & 7) * 8;
                unsigned bytes = 1 << size;
                uint64_t mask = (bytes == 8) ? ~0ULL : ((1ULL << (bytes * 8)) - 1ULL);
                return (dword >> shift) & mask;
            }
        }
        return read_dmem(addr, size);
    };

    // Read 8 words of signature
    std::vector<uint64_t> signature(8, 0);
    for (int i = 0; i < 8; ++i) {
        signature[i] = read_mem_cached(SIG_ADDR + i * 8, 3); // size 3 = 8 bytes
    }

    dut.final();

    bool pass = tohost_seen && (tohost == 1) && (signature[2] == 1) &&
                (signature[0] == 0x465552534f593031ULL);

    std::cout << "{\n";
    std::cout << "  \"status\": \"" << (pass ? "pass" : "fail") << "\",\n";
    std::cout << "  \"tohost\": " << tohost << ",\n";
    std::cout << "  \"tohost_seen\": " << (tohost_seen ? "true" : "false") << ",\n";
    std::cout << "  \"cycles\": " << cycles << ",\n";
    std::cout << "  \"commits\": " << commits << ",\n";
    std::cout << "  \"traps\": " << traps << ",\n";
    std::cout << "  \"last_trap_cause\": " << last_trap_cause << ",\n";
    std::cout << "  \"last_trap_pc\": \"0x" << std::hex << last_trap_pc << "\",\n";
    std::cout << "  \"last_commit_pc\": \"0x" << std::hex << last_commit_pc << "\",\n";
    std::cout << "  \"signature\": [\n";
    for (int i = 0; i < 8; ++i) {
        std::cout << "    \"0x" << std::hex << std::setfill('0') << std::setw(16)
                  << signature[i] << "\"" << (i < 7 ? "," : "") << "\n";
    }
    std::cout << "  ]\n";
    std::cout << "}\n";

    return pass ? 0 : 1;
}
