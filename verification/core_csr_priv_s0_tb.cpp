#include "Vfursoy_s0_core.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

static uint32_t addi(unsigned rd,unsigned rs,int imm){return((uint32_t(imm)&0xfff)<<20)|(rs<<15)|(rd<<7)|0x13;}
static uint32_t slli(unsigned rd,unsigned rs,unsigned sh){return(sh<<20)|(rs<<15)|(1<<12)|(rd<<7)|0x13;}
static uint32_t csr(unsigned f,unsigned rd,unsigned rs,unsigned addr){return(addr<<20)|(rs<<15)|(f<<12)|(rd<<7)|0x73;}
struct Event{bool commit=false,trap=false,rsp=false,rd_write=false;uint64_t pc=0,rsp_pc=0,rd_data=0;uint32_t insn=0;unsigned rd=0;};
struct Sim{
    Vfursoy_s0_core d;std::unordered_map<uint64_t,uint32_t> mem;bool pending=false;uint64_t rsp_pc=0;uint32_t rsp_insn=0;uint64_t cycles=0,commits=0;
    void init(){d.clk_i=0;d.rst_i=1;d.imem_req_ready_i=1;d.imem_rsp_valid_i=0;d.imem_rsp_error_i=0;
        d.dmem_req_ready_i=1;d.dmem_req_error_i=0;d.dmem_rsp_valid_i=0;d.dmem_rsp_data_i=0;d.dmem_rsp_error_i=0;
        d.irq_software_i=0;d.irq_timer_i=0;d.irq_external_i=0;d.eval();d.clk_i=1;d.eval();++cycles;d.clk_i=0;d.rst_i=0;d.eval();}
    Event tick(){d.clk_i=0;d.imem_req_ready_i=1;d.imem_rsp_valid_i=pending;d.imem_rsp_insn_i=rsp_insn;d.imem_rsp_error_i=0;d.eval();
        Event e;e.commit=d.commit_valid_o;e.trap=d.trap_valid_o;e.pc=e.commit?uint64_t(d.commit_pc_o):uint64_t(d.trap_pc_o);e.insn=e.commit?uint32_t(d.commit_insn_o):uint32_t(d.trap_insn_o);
        e.rd_write=d.commit_rd_write_o;e.rd=d.commit_rd_o;e.rd_data=d.commit_rd_data_o;
        bool rf=pending&&d.imem_rsp_ready_o,rq=d.imem_req_valid_o&&d.imem_req_ready_i;e.rsp=rf;e.rsp_pc=rsp_pc;
        bool np=pending;uint64_t na=rsp_pc;uint32_t ni=rsp_insn;if(rf)np=false;
        if(rq){na=d.imem_req_addr_o;auto it=mem.find(na);if(it==mem.end())throw std::runtime_error("unexpected fetch");ni=it->second;np=true;}
        d.clk_i=1;d.eval();++cycles;pending=np;rsp_pc=na;rsp_insn=ni;if(e.commit)++commits;return e;}
};
static void check(bool ok,const char*why){if(!ok)throw std::runtime_error(why);}
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);constexpr uint64_t B=0x80000000ULL,V=0x80000100ULL;unsigned scenarios=0;
    try{
        { // WARL behavior and reserved funct3 suppression.
            Sim s;s.mem[B]=addi(1,0,-1);s.mem[B+4]=csr(1,2,1,0x300);s.mem[B+8]=csr(1,3,0,0x300);
            s.mem[B+12]=csr(1,0,1,0x304);s.mem[B+16]=addi(1,0,0x103);s.mem[B+20]=csr(1,0,1,0x305);
            s.mem[B+24]=addi(1,0,0x107);s.mem[B+28]=csr(1,0,1,0x341);s.mem[B+32]=csr(5,0,31,0x342);
            s.mem[B+36]=csr(5,0,31,0x343);s.mem[B+40]=csr(4,5,1,0x340);s.init();bool trapped=false;
            for(int i=0;i<80&&!trapped;i++){auto e=s.tick();if(e.commit){
                if(e.pc==B+4)check(uint64_t(s.d.csr_mstatus_o)==0x0000000a007e19aaULL&&e.rd_data==0x0000000a00001800ULL,"mstatus set/WARL");
                if(e.pc==B+8)check(uint64_t(s.d.csr_mstatus_o)==0x0000000a00000000ULL&&e.rd_data==0x0000000a007e19aaULL,"MPP coercion");
                if(e.pc==B+12)check(uint64_t(s.d.csr_mie_o)==0xaaa,"mie WARL");
                if(e.pc==B+20)check(uint64_t(s.d.csr_mtvec_o)==0x100,"mtvec WARL");
                if(e.pc==B+28)check(uint64_t(s.d.csr_mepc_o)==0x104,"mepc WARL");
                if(e.pc==B+32)check(uint64_t(s.d.csr_mcause_o)==31,"mcause write");
                if(e.pc==B+36)check(uint64_t(s.d.csr_mtval_o)==31,"mtval write");
            }if(e.trap){trapped=true;check(e.pc==B+40&&!s.d.commit_valid_o&&uint64_t(s.d.csr_mcause_o)==2&&
                uint64_t(s.d.csr_mepc_o)==B+40&&uint64_t(s.d.csr_mtval_o)==s.mem[B+40]&&uint64_t(s.d.csr_mscratch_o)==0,
                "reserved CSR trap suppression");}}
            check(trapped&&s.commits==10,"WARL scenario completion");++scenarios;
        }
        { // Read-only fault preserves the encoded destination register.
            Sim s;s.mem[B]=addi(5,0,0x5a);s.mem[B+4]=csr(2,5,1,0xc00);s.mem[V]=addi(6,5,0);s.init();bool trap=false,observed=false;
            for(int i=0;i<40&&!observed;i++){auto e=s.tick();if(e.trap){trap=true;check(e.pc==B+4&&uint64_t(s.d.csr_mcause_o)==2,"read-only trap");}
                if(e.commit&&e.pc==V){check(trap&&e.rd==6&&e.rd_data==0x5a,"faulting CSR changed x5");observed=true;}}
            check(observed&&s.commits==2,"read-only suppression completion");++scenarios;
        }
        { // Eligible interrupt preempts a CSR write; mret retries it exactly once.
            Sim s;s.mem[B]=addi(3,0,1);s.mem[B+4]=slli(3,3,11);s.mem[B+8]=csr(2,0,3,0x304);
            s.mem[B+12]=csr(6,0,8,0x300);s.mem[B+16]=addi(1,0,0x55);s.mem[B+20]=csr(1,2,1,0x340);s.mem[V]=0x30200073;s.init();
            bool armed=false,trapped=false,retried=false;unsigned target_commits=0;
            for(int i=0;i<100&&!retried;i++){auto e=s.tick();if(!trapped&&e.rsp&&e.rsp_pc==B+20){armed=true;s.d.irq_external_i=1;}
                if(e.trap){check(armed&&e.pc==B+20&&uint64_t(s.d.csr_mcause_o)==0x800000000000000bULL&&
                    uint64_t(s.d.csr_mscratch_o)==0,"interrupt did not suppress CSR");trapped=true;s.d.irq_external_i=0;}
                if(e.commit&&e.pc==B+20){++target_commits;check(trapped&&uint64_t(s.d.csr_mscratch_o)==0x55&&
                    uint64_t(s.d.csr_mstatus_o)==0x0000000a00000088ULL&&e.rd==2&&e.rd_data==0,"CSR retry/MRET state");retried=true;}}
            check(retried&&target_commits==1,"interrupt retry count");++scenarios;
        }
        { // Illegal CSR exception wins over an eligible interrupt.
            Sim s;s.mem[B]=addi(3,0,1);s.mem[B+4]=slli(3,3,11);s.mem[B+8]=csr(2,0,3,0x304);
            s.mem[B+12]=csr(6,0,8,0x300);s.mem[B+16]=csr(1,5,0,0xc00);s.init();bool trapped=false;
            for(int i=0;i<60&&!trapped;i++){auto e=s.tick();if(e.rsp&&e.rsp_pc==B+16)s.d.irq_external_i=1;
                if(e.trap){trapped=true;check(e.pc==B+16&&uint64_t(s.d.csr_mcause_o)==2&&
                    (uint64_t(s.d.csr_mip_o)&0x800)&&!s.d.commit_valid_o,"CSR exception priority");}}
            check(trapped&&s.commits==4,"exception-priority completion");++scenarios;
        }
        std::cout<<"{\"status\":\"pass\",\"scenarios\":"<<scenarios<<"}\n";return 0;
    }catch(const std::exception&e){std::cerr<<"CORE_CSR_PRIV_S0_MISMATCH scenario="<<scenarios+1<<" reason="<<e.what()<<'\n';return 1;}
}
