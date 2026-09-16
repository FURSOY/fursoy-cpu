// Linux Boot Testbench for Fursoy Slice-0.
// Verifies end-to-end boot: Reset -> SBI Firmware -> S-mode Linux Entry -> Sv39 MMU -> Initramfs.
// Specification authority: docs/architecture/platform-sbi-v1.md (frozen v1)

#include "Vfursoy_s0_soc.h"
#include "Vfursoy_s0_soc___024root.h"
#include "verilated.h"
#include <cstdint>
#include <fstream>
#include <iostream>
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
        total_loaded += filesz;
    }
    return total_loaded;
}

static uint64_t read_mem(const std::vector<uint8_t>& ram, uint64_t addr, unsigned size) {
    unsigned n = 1u << size;
    if (size > 3 || addr < RAM_BASE || addr - RAM_BASE > RAM_SIZE - n || (addr & (n - 1)))
        throw std::runtime_error("bad RAM read at 0x" + std::to_string(addr));
    uint64_t v = 0;
    for (unsigned i = 0; i < n; i++) v |= uint64_t(ram[addr - RAM_BASE + i]) << (8 * i);
    return v;
}

static void write_mem(std::vector<uint8_t>& ram, uint64_t addr, unsigned size, uint64_t value) {
    unsigned n = 1u << size;
    if (size > 3 || addr < RAM_BASE || addr - RAM_BASE > RAM_SIZE - n || (addr & (n - 1)))
        throw std::runtime_error("bad RAM write at 0x" + std::to_string(addr));
    for (unsigned i = 0; i < n; i++) ram[addr - RAM_BASE + i] = uint8_t(value >> (8 * i));
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0] << " <fw_elf> <kernel_img> <dtb_bin> [max_cycles]\n";
        return 1;
    }

    const char* fw_elf = argv[1];
    const char* kernel_img = argv[2];
    const char* dtb_bin = argv[3];
    uint64_t max_cycles = (argc >= 5) ? std::stoull(argv[4], nullptr, 0) : 10000000ULL;

    try {
        std::vector<uint8_t> ram(RAM_SIZE, 0);

        // 1. Load Firmware at 0x8000_0000 (M-mode entry)
        size_t fw_sz = load_elf(fw_elf, ram);

        // 2. Load Linux Image at 0x8020_0000 (S-mode entry)
        size_t kernel_sz = load_raw_bin(kernel_img, ram, 0x80200000ULL);

        // 3. Load Canonical DTB at 0x8200_0000
        size_t dtb_sz = load_raw_bin(dtb_bin, ram, 0x82000000ULL);

        // Validate memory placement without overlap
        if (0x80200000ULL + kernel_sz > 0x82000000ULL) {
            throw std::runtime_error("Kernel image overlaps with DTB at 0x8200_0000");
        }
        if (0x82000000ULL + dtb_sz > 0x82100000ULL) {
            throw std::runtime_error("DTB exceeds 1 MiB aperture");
        }

        std::cerr << "[TB] Firmware loaded: " << fw_sz << " bytes\n"
                  << "[TB] Kernel loaded:   " << kernel_sz << " bytes at 0x8020_0000\n"
                  << "[TB] DTB loaded:      " << dtb_sz << " bytes at 0x8200_0000\n"
                  << "[TB] Simulation DRAM: 256 MiB (0x8000_0000..0x8FFF_FFFF)\n"
                  << "[TB] Max cycles:      " << max_cycles << "\n";

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

        for (int r = 0; r < 10; r++) {
            dut.clk_i = 1; dut.eval();
            dut.clk_i = 0; dut.eval();
        }
        dut.rst_i = 0;

        bool ip = false, dp = false;
        uint64_t ii = 0;
        uint64_t dd = 0;
        uint64_t cycles = 0, commits = 0;

        // Milestones
        bool seen_reset = false;
        bool seen_handoff = false;
        bool seen_satp_sv39 = false;
        bool seen_virt_pc = false;
        bool seen_earlycon = false;
        bool seen_init_banner = false;
        bool seen_userspace_begin = false;
        bool seen_userspace_pass = false;
        bool seen_userspace_fail = false;
        uint64_t cycle_handoff = 0;
        uint64_t cycle_satp = 0;
        uint64_t cycle_virt = 0;
        uint64_t cycle_earlycon = 0;
        uint64_t last_satp_val = 0;
        uint64_t last_commit_pc = 0;
        uint32_t last_commit_insn = 0;

        uint64_t sbi_ecall_count = 0;
        uint64_t mtimecmp_updates = 0;
        uint64_t last_mtimecmp = 0;
        uint64_t mtip_count = 0;
        uint64_t stip_count = 0;
        uint64_t seip_count = 0;
        uint64_t user_ecall_count = 0;
        uint64_t plic_c0_accesses = 0;
        uint64_t plic_c1_accesses = 0;

        while (cycles < max_cycles) {
            dut.clk_i = 0;
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
            }

            // Monitor PLIC context accesses
            if (dut.rootp->fursoy_s0_soc__DOT__plic__DOT__req_fire) {
                if (dut.rootp->fursoy_s0_soc__DOT__plic__DOT__is_threshold_c0 ||
                    dut.rootp->fursoy_s0_soc__DOT__plic__DOT__is_enable_c0_w0 ||
                    dut.rootp->fursoy_s0_soc__DOT__plic__DOT__claim_c0_fire) {
                    plic_c0_accesses++;
                }
                if (dut.rootp->fursoy_s0_soc__DOT__plic__DOT__is_threshold_c1 ||
                    dut.rootp->fursoy_s0_soc__DOT__plic__DOT__is_enable_c1_w0 ||
                    dut.rootp->fursoy_s0_soc__DOT__plic__DOT__claim_c1_fire) {
                    plic_c1_accesses++;
                }
            }

            // Monitor CLINT mtimecmp programming via SBI
            uint64_t cur_mtimecmp = dut.rootp->fursoy_s0_soc__DOT__clint__DOT__mtimecmp_q;
            if (cur_mtimecmp != last_mtimecmp) {
                last_mtimecmp = cur_mtimecmp;
                mtimecmp_updates++;
            }

            // Capture real-time UART transmissions
            if (dut.uart_tx_valid_o) {
                char ch = char(dut.uart_tx_data_o);
                uart_output += ch;
                std::cout << ch << std::flush;
                if (!seen_earlycon) {
                    seen_earlycon = true;
                    cycle_earlycon = cycles;
                }
                if (uart_output.find("[INIT]") != std::string::npos ||
                    uart_output.find("Userspace active") != std::string::npos) {
                    seen_init_banner = true;
                }
                if (uart_output.find("FURSOY_USERSPACE_BEGIN") != std::string::npos) {
                    seen_userspace_begin = true;
                }
                if (uart_output.find("FURSOY_USERSPACE_PASS") != std::string::npos) {
                    seen_userspace_pass = true;
                }
                if (uart_output.find("FURSOY_USERSPACE_FAIL") != std::string::npos) {
                    seen_userspace_fail = true;
                }
            }

            // Milestone and architectural state inspection
            if (dut.commit_valid_o) {
                commits++;
                last_commit_pc = dut.commit_pc_o;
                last_commit_insn = dut.commit_insn_o;
                if (last_commit_pc == 0x80000000ULL) seen_reset = true;
                if (last_commit_pc == 0x80200000ULL && !seen_handoff) {
                    seen_handoff = true;
                    cycle_handoff = cycles;
                }
                if ((last_commit_pc & 0xffffffff00000000ULL) == 0xffffffff00000000ULL ||
                    (last_commit_pc & 0xff60000000000000ULL) == 0xff60000000000000ULL) {
                    if (!seen_virt_pc) {
                        seen_virt_pc = true;
                        cycle_virt = cycles;
                    }
                }
            }

            // Track satp transitions to Sv39
            uint64_t satp = dut.rootp->fursoy_s0_soc__DOT__core__DOT__satp_q;
            if (satp != last_satp_val) {
                last_satp_val = satp;
                if ((satp >> 60) == 8 && !seen_satp_sv39) {
                    seen_satp_sv39 = true;
                    cycle_satp = cycles;
                }
            }

            // Stop condition: userspace test finished!
            if (seen_userspace_pass) {
                static int pass_drain = 0;
                if (++pass_drain > 10000) break;
            }
            if (seen_userspace_fail) {
                static int fail_drain = 0;
                if (++fail_drain > 10000) break;
            }

            // Stop condition: kernel panic or halt
            if (uart_output.find("Kernel panic") != std::string::npos ||
                uart_output.find("---[ end Kernel panic") != std::string::npos) {
                static int panic_drain = 0;
                if (++panic_drain > 5000) break;
            }

            bool took_trap = dut.trap_valid_o;
            bool to_s = dut.rootp->fursoy_s0_soc__DOT__core__DOT__trap_to_s;
            uint64_t trap_pc = dut.trap_pc_o;
            uint32_t trap_insn = dut.trap_insn_o;

            dut.clk_i = 1;
            dut.eval();
            cycles++;

            // Trap tracking after posedge update
            if (took_trap) {
                if (!to_s) {
                    uint64_t mcause = dut.csr_mcause_o;
                    if (mcause == 9) {
                        sbi_ecall_count++;
                    } else if (mcause == 0x8000000000000007ULL) {
                        mtip_count++;
                    } else {
                        static int unexp_m_count = 0;
                        if (unexp_m_count++ < 25) {
                            std::cerr << "[UNEXPECTED M TRAP " << unexp_m_count << "] cycle=" << cycles
                                      << " pc=0x" << std::hex << trap_pc
                                      << " insn=0x" << trap_insn
                                      << " mcause=0x" << mcause
                                      << " mtval=0x" << dut.csr_mtval_o
                                      << std::dec << "\n";
                        }
                    }
                } else {
                    uint64_t scause = dut.rootp->fursoy_s0_soc__DOT__core__DOT__scause_q;
                    if (scause == 0x8000000000000005ULL) {
                        stip_count++;
                    } else if (scause == 0x8000000000000009ULL) {
                        seip_count++;
                    } else if (scause == 8) {
                        user_ecall_count++;
                    } else {
                        static int unexp_s_count = 0;
                        if (unexp_s_count++ < 25) {
                            std::cerr << "[UNEXPECTED S TRAP " << unexp_s_count << "] cycle=" << cycles
                                      << " pc=0x" << std::hex << trap_pc
                                      << " insn=0x" << trap_insn
                                      << " scause=0x" << scause
                                      << " stval=0x" << dut.rootp->fursoy_s0_soc__DOT__core__DOT__stval_q
                                      << std::dec << "\n";
                        }
                    }
                }
            }

            // Periodic heartbeat
            if (cycles > 0 && cycles % 5000000 == 0) {
                uint64_t cur_ra = dut.rootp->fursoy_s0_soc__DOT__core__DOT__registers[1];
                uint64_t cur_sp = dut.rootp->fursoy_s0_soc__DOT__core__DOT__registers[2];
                uint64_t cur_tp = dut.rootp->fursoy_s0_soc__DOT__core__DOT__registers[4];
                std::cerr << "[HEARTBEAT] cycle=" << cycles << " commits=" << commits
                          << " pc=0x" << std::hex << last_commit_pc
                          << " ra=0x" << cur_ra << " sp=0x" << cur_sp << " tp=0x" << cur_tp
                          << " insn=0x" << last_commit_insn
                          << " sbi_calls=" << std::dec << sbi_ecall_count
                          << " mtimecmp_updates=" << mtimecmp_updates
                          << " mtip=" << mtip_count
                          << " stip=" << stip_count
                          << " seip=" << seip_count
                          << " plic_c1=" << plic_c1_accesses << "\n";
            }

            ip = nip;
            ii = nii;
            dp = ndp;
            dd = ndd;
        }

        std::cerr << "\n[TB] Simulation completed: cycles=" << cycles
                  << " commits=" << commits
                  << " last_commit_pc=0x" << std::hex << last_commit_pc
                  << " last_insn=0x" << last_commit_insn
                  << " mcause=0x" << dut.csr_mcause_o
                  << " mepc=0x" << dut.csr_mepc_o
                  << " mstatus=0x" << dut.csr_mstatus_o << std::dec
                  << " handoff=" << seen_handoff
                  << " satp_sv39=" << seen_satp_sv39
                  << " virt_pc=" << seen_virt_pc
                  << " earlycon=" << seen_earlycon
                  << " init=" << seen_init_banner
                  << " sbi_calls=" << sbi_ecall_count
                  << " mtimecmp_updates=" << mtimecmp_updates
                  << " mtip=" << mtip_count
                  << " stip=" << stip_count
                  << " seip=" << seip_count
                  << " plic_c0=" << plic_c0_accesses
                  << " plic_c1=" << plic_c1_accesses
                  << " user_ecall=" << user_ecall_count << "\n";

        // Output structured JSON report
        std::cerr << "--- JSON REPORT ---\n";
        std::string status = "fail";
        if (seen_userspace_pass && !seen_userspace_fail) {
            status = "pass";
        } else if (seen_userspace_fail) {
            status = "userspace_fail";
        } else if (seen_init_banner) {
            status = "init_reached";
        } else if (seen_earlycon) {
            status = "earlycon_pass";
        }

        std::cout << "{\n"
                  << "  \"status\": \"" << status << "\",\n"
                  << "  \"cycles\": " << cycles << ",\n"
                  << "  \"commits\": " << commits << ",\n"
                  << "  \"seen_reset\": " << (seen_reset ? "true" : "false") << ",\n"
                  << "  \"seen_handoff\": " << (seen_handoff ? "true" : "false") << ",\n"
                  << "  \"seen_satp_sv39\": " << (seen_satp_sv39 ? "true" : "false") << ",\n"
                  << "  \"seen_virt_pc\": " << (seen_virt_pc ? "true" : "false") << ",\n"
                  << "  \"seen_earlycon\": " << (seen_earlycon ? "true" : "false") << ",\n"
                  << "  \"seen_init_banner\": " << (seen_init_banner ? "true" : "false") << ",\n"
                  << "  \"seen_userspace_begin\": " << (seen_userspace_begin ? "true" : "false") << ",\n"
                  << "  \"seen_userspace_pass\": " << (seen_userspace_pass ? "true" : "false") << ",\n"
                  << "  \"seen_userspace_fail\": " << (seen_userspace_fail ? "true" : "false") << ",\n"
                  << "  \"cycle_handoff\": " << cycle_handoff << ",\n"
                  << "  \"cycle_satp\": " << cycle_satp << ",\n"
                  << "  \"cycle_virt\": " << cycle_virt << ",\n"
                  << "  \"cycle_earlycon\": " << cycle_earlycon << ",\n"
                  << "  \"sbi_ecall_count\": " << sbi_ecall_count << ",\n"
                  << "  \"mtimecmp_updates\": " << mtimecmp_updates << ",\n"
                  << "  \"mtip_count\": " << mtip_count << ",\n"
                  << "  \"stip_count\": " << stip_count << ",\n"
                  << "  \"seip_count\": " << seip_count << ",\n"
                  << "  \"plic_c0_accesses\": " << plic_c0_accesses << ",\n"
                  << "  \"plic_c1_accesses\": " << plic_c1_accesses << ",\n"
                  << "  \"user_ecall_count\": " << user_ecall_count << "\n"
                  << "}\n";

        return 0;
    } catch (const std::exception& e) {
        std::cerr << "LINUX_BOOT_EXCEPTION: " << e.what() << "\n";
        return 1;
    }
}
