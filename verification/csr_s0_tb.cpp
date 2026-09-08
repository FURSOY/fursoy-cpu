#include "Vfursoy_s0_csr.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

static uint32_t csr(unsigned f,unsigned rd,unsigned rs1,unsigned addr){return(addr<<20)|(rs1<<15)|(f<<12)|(rd<<7)|0x73;}
struct Expected{bool valid,illegal,write,rd_write;uint64_t write_data,rd_data;};
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);Vfursoy_s0_csr d;unsigned checks=0;
    auto run=[&](uint32_t insn,uint64_t rs1,Expected e){
        d.insn_valid_i=1;d.insn_i=insn;d.rs1_i=rs1;
        d.eval();++checks;
        if(bool(d.csr_valid_o)!=e.valid||bool(d.csr_illegal_o)!=e.illegal||
           bool(d.csr_write_o)!=e.write||bool(d.rd_write_o)!=e.rd_write||
           (e.write&&uint64_t(d.csr_write_data_o)!=e.write_data)||
           (e.rd_write&&uint64_t(d.rd_data_o)!=e.rd_data))throw std::runtime_error("CSR result mismatch");
    };
    try{
        // Default CSR inputs: M-mode privilege (3)
        d.priv_mode_i=3;
        d.mstatus_i=0x0000000a00001888ULL;d.mie_i=0x88;
        d.mtvec_i=0x101;d.mscratch_i=0x55;d.mepc_i=0x204;d.mcause_i=2;
        d.mtval_i=0xffffffff;d.mip_i=0x888;d.cycle_i=123;
        d.medeleg_i=0xb3ff;d.mideleg_i=0x222;d.mcounteren_i=0;d.menvcfg_i=1;
        d.stvec_i=0x200;d.scounteren_i=0;d.sscratch_i=0x77;d.sepc_i=0x400;d.scause_i=9;d.stval_i=0xbad;
        d.senvcfg_i=1;d.satp_i=0x8000000000012345ULL;

        // Existing M-mode CSR checks
        run(csr(1,5,1,0x340),0xaa,{1,0,1,1,0xaa,0x55});             // CSRRW
        run(csr(1,0,0,0x340),0,{1,0,1,0,0,0});                      // rd=x0 still writes
        run(csr(2,5,0,0x340),0,{1,0,0,1,0,0x55});                   // CSRRS rs1=x0
        run(csr(3,0,1,0x340),1,{1,0,1,0,0x54,0});                   // CSRRC rd=x0
        run(csr(5,5,31,0x340),0,{1,0,1,1,31,0x55});                 // CSRRWI
        run(csr(6,5,0,0x340),0,{1,0,0,1,0,0x55});                   // CSRRSI zimm=0
        run(csr(7,5,0,0x340),0,{1,0,0,1,0,0x55});                   // CSRRCI zimm=0
        run(csr(6,5,0,0xc00),0,{1,0,0,1,0,123});                    // read-only legal read in M-mode
        run(csr(1,0,0,0xc00),0,{1,1,0,0,0,0});                      // CSRRW zero still writes
        run(csr(3,5,1,0x344),1,{1,0,1,1,0x888,0x888});              // mip write legal (RW register with software latches)
        run(csr(2,5,0,0x344),0,{1,0,0,1,0,0x888});                  // mip zero-source read
        run(csr(2,5,1,0x340),0,{1,0,1,1,0x55,0x55});                // CSRRS non-x0 runtime zero
        run(csr(3,5,1,0x340),0,{1,0,1,1,0x55,0x55});                // CSRRC non-x0 runtime zero
        run(csr(2,5,1,0xc00),0,{1,1,0,0,0,0});                      // read-only CSRRS intent
        run(csr(3,5,1,0xc00),0,{1,1,0,0,0,0});                      // read-only CSRRC intent
        run(csr(4,5,1,0x340),1,{1,1,0,0,0,0});                      // reserved funct3
        run(csr(2,5,0,0x999),0,{1,1,0,0,0,0});                      // unknown even no write
        run(0x13,0,{0,0,0,0,0,0});

        // Base CSRs from M-mode
        run(csr(2,5,0,0xf14),0,{1,0,0,1,0,0});                      // mhartid: read returns 0
        run(csr(1,5,1,0xf14),1,{1,1,0,0,0,0});                      // mhartid: write illegal
        run(csr(2,5,0,0xf11),0,{1,0,0,1,0,0});                      // mvendorid: read returns 0
        run(csr(1,5,1,0xf11),1,{1,1,0,0,0,0});                      // mvendorid: write illegal
        run(csr(2,5,0,0x301),0,{1,0,0,1,0,0});                      // misa: read returns 0
        run(csr(1,5,1,0x301),1,{1,0,1,1,1,0});                      // misa: WARL write legal (core ignores write)
        run(csr(2,5,0,0x30a),0,{1,0,0,1,0,1});                      // menvcfg.FIOM read
        run(csr(1,5,1,0x30a),1,{1,0,1,1,1,1});                      // menvcfg write calculation
        run(csr(2,5,0,0x302),0,{1,0,0,1,0,0xb3ff});                 // medeleg: read
        run(csr(1,5,1,0x302),0x155,{1,0,1,1,0x155,0xb3ff});         // medeleg: write
        run(csr(2,5,0,0x303),0,{1,0,0,1,0,0x222});                  // mideleg: read
        run(csr(1,5,1,0x303),0x222,{1,0,1,1,0x222,0x222});          // mideleg: write
        run(csr(2,5,0,0x306),0,{1,0,0,1,0,0});                      // mcounteren: read returns 0

        // S-mode CSRs from M-mode (legal)
        d.mie_i=0xaaa; d.mip_i=0xaaa; d.mideleg_i=0x222;
        run(csr(2,5,0,0x100),0,{1,0,0,1,0,0x0000000200000000ULL}); // sstatus alias read (MPIE/MIE hidden)
        run(csr(1,5,1,0x100),0x122,{1,0,1,1,0x122,0x0000000200000000ULL}); // sstatus write
        run(csr(2,5,0,0x104),0,{1,0,0,1,0,0x222});                  // sie read (mie & mideleg & 0x222)
        run(csr(1,5,1,0x104),0x222,{1,0,1,1,0x222,0x222});          // sie write from M-mode
        run(csr(2,5,0,0x105),0,{1,0,0,1,0,0x200});                  // stvec read
        run(csr(2,5,0,0x140),0,{1,0,0,1,0,0x77});                   // sscratch read
        run(csr(2,5,0,0x141),0,{1,0,0,1,0,0x400});                  // sepc read
        run(csr(2,5,0,0x142),0,{1,0,0,1,0,9});                      // scause read
        run(csr(2,5,0,0x143),0,{1,0,0,1,0,0xbad});                  // stval read
        run(csr(2,5,0,0x144),0,{1,0,0,1,0,0x222});                  // sip read (mip & mideleg & 0x222)
        run(csr(1,5,1,0x144),0x2,{1,0,1,1,0x2,0x222});              // sip write from M-mode
        run(csr(2,5,0,0x180),0,{1,0,0,1,0,0x8000000000012345ULL});  // satp read
        run(csr(1,5,1,0x180),0,{1,0,1,1,0,0x8000000000012345ULL});  // satp write calculation
        run(csr(2,5,0,0x10a),0,{1,0,0,1,0,1});                      // senvcfg.FIOM read

        // Privilege gating from S-mode (priv_mode_i = 1)
        d.priv_mode_i=1;
        run(csr(2,5,0,0x300),0,{1,1,0,0,0,0});                      // mstatus from S-mode -> illegal
        run(csr(2,5,0,0x340),0,{1,1,0,0,0,0});                      // mscratch from S-mode -> illegal
        run(csr(2,5,0,0x302),0,{1,1,0,0,0,0});                      // medeleg from S-mode -> illegal
        run(csr(2,5,0,0x303),0,{1,1,0,0,0,0});                      // mideleg from S-mode -> illegal
        run(csr(2,5,0,0x304),0,{1,1,0,0,0,0});                      // mie from S-mode -> illegal
        run(csr(2,5,0,0x344),0,{1,1,0,0,0,0});                      // mip from S-mode -> illegal
        run(csr(2,5,0,0xf14),0,{1,1,0,0,0,0});                      // mhartid from S-mode -> illegal
        run(csr(2,5,0,0x100),0,{1,0,0,1,0,0x0000000200000000ULL}); // sstatus from S-mode -> legal
        run(csr(2,5,0,0x104),0,{1,0,0,1,0,0x222});                  // sie from S-mode -> legal
        run(csr(1,5,1,0x104),0x222,{1,0,1,1,0x222,0x222});          // sie write from S-mode -> legal
        run(csr(2,5,0,0x140),0,{1,0,0,1,0,0x77});                   // sscratch from S-mode -> legal
        run(csr(2,5,0,0x144),0,{1,0,0,1,0,0x222});                  // sip from S-mode -> legal
        run(csr(1,5,1,0x144),0x2,{1,0,1,1,0x2,0x222});              // sip write from S-mode -> legal
        run(csr(2,5,0,0x180),0,{1,0,0,1,0,0x8000000000012345ULL});  // satp from S-mode -> legal
        d.mstatus_i |= (1ULL<<20);
        run(csr(2,5,0,0x180),0,{1,1,0,0,0,0});                      // TVM intercepts S satp access
        d.mstatus_i &= ~(1ULL<<20);

        // Dynamic alias hiding: clearing mideleg hides sie and sip state without clearing backing state
        d.mideleg_i=0;
        run(csr(2,5,0,0x104),0,{1,0,0,1,0,0});                      // sie reads 0 when mideleg=0
        run(csr(2,5,0,0x144),0,{1,0,0,1,0,0});                      // sip reads 0 when mideleg=0
        d.mideleg_i=0x222;

        // Privilege gating from U-mode (priv_mode_i = 0)
        d.priv_mode_i=0;
        run(csr(2,5,0,0x340),0,{1,1,0,0,0,0});                      // mscratch from U-mode -> illegal
        run(csr(2,5,0,0x100),0,{1,1,0,0,0,0});                      // sstatus from U-mode -> illegal
        run(csr(2,5,0,0x104),0,{1,1,0,0,0,0});                      // sie from U-mode -> illegal
        run(csr(2,5,0,0x140),0,{1,1,0,0,0,0});                      // sscratch from U-mode -> illegal
        run(csr(2,5,0,0x144),0,{1,1,0,0,0,0});                      // sip from U-mode -> illegal
        run(csr(2,5,0,0x180),0,{1,1,0,0,0,0});                      // satp from U-mode -> illegal
        run(csr(2,5,0,0x10a),0,{1,1,0,0,0,0});                      // senvcfg from U-mode -> illegal

        // Counter gating for cycle (0xc00)
        // From S-mode:
        d.priv_mode_i=1; d.mcounteren_i=0;
        run(csr(2,5,0,0xc00),0,{1,1,0,0,0,0});                      // cycle with mcounteren.CY=0 -> illegal
        d.mcounteren_i=1;
        run(csr(2,5,0,0xc00),0,{1,0,0,1,0,123});                    // cycle with mcounteren.CY=1 -> legal
        // From U-mode:
        d.priv_mode_i=0; d.mcounteren_i=1; d.scounteren_i=0;
        run(csr(2,5,0,0xc00),0,{1,1,0,0,0,0});                      // cycle with scounteren.CY=0 -> illegal
        d.scounteren_i=1;
        run(csr(2,5,0,0xc00),0,{1,0,0,1,0,123});                    // cycle with both CY=1 -> legal

        // time CSR (0xc01) is deliberately deferred in Bare milestone
        d.priv_mode_i=3;
        run(csr(2,5,0,0xc01),0,{1,1,0,0,0,0});                      // time CSR -> illegal

        d.insn_valid_i=0;d.insn_i=csr(1,1,1,0x340);d.eval();++checks;
        if(d.csr_valid_o||d.csr_illegal_o||d.csr_write_o||d.rd_write_o)throw std::runtime_error("valid gate");
        d.final();std::cout<<"{\"status\":\"pass\",\"checks\":"<<checks<<"}\n";return 0;
    }catch(const std::exception&e){std::cerr<<"CSR_S0_MISMATCH check="<<checks<<" reason="<<e.what()<<'\n';return 1;}
}
