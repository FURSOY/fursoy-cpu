#include "Vfursoy_s0_core.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv); Vfursoy_s0_core d;
    constexpr uint64_t BASE=0x80000000ULL,TARGET=0x40000000ULL,HANDLER=0x80000100ULL;
    bool pending=false,error=false;uint32_t insn=0;uint64_t cycles=0,commits=0;
    auto check=[](bool ok,const char*why){if(!ok)throw std::runtime_error(why);};
    try {
        d.clk_i=0;d.rst_i=1;d.imem_req_ready_i=1;d.imem_rsp_valid_i=0;d.imem_rsp_error_i=0;
        d.dmem_req_ready_i=1;d.dmem_req_error_i=0;d.dmem_rsp_valid_i=0;d.dmem_rsp_data_i=0;
        d.dmem_rsp_error_i=0;d.irq_software_i=0;d.irq_timer_i=0;d.irq_external_i=0;d.eval();
        d.clk_i=1;d.eval();d.clk_i=0;d.rst_i=0;d.eval();++cycles;
        bool trapped=false,handler_commit=false;
        while(cycles<40&&!handler_commit){
            d.clk_i=0;d.imem_req_ready_i=1;d.imem_rsp_valid_i=pending;
            d.imem_rsp_insn_i=insn;d.imem_rsp_error_i=error;d.eval();
            bool rsp_fire=pending&&d.imem_rsp_ready_o;
            bool req_fire=d.imem_req_valid_o&&d.imem_req_ready_i;
            bool next_pending=pending,next_error=error;uint32_t next_insn=insn;
            if(rsp_fire)next_pending=false;
            if(req_fire){uint64_t a=d.imem_req_addr_o;next_pending=true;
                if(a==BASE){next_insn=0x400000b7;next_error=false;}
                else if(a==BASE+4){next_insn=0x00008067;next_error=false;}
                else if(a==TARGET){next_insn=0x00100313;next_error=true;}
                else if(a==HANDLER){next_insn=0x00030393;next_error=false;}
                else throw std::runtime_error("unexpected fetch address");
            }
            if(d.commit_valid_o){++commits;check(uint64_t(d.commit_pc_o)!=TARGET,"faulting fetch committed");
                if(uint64_t(d.commit_pc_o)==HANDLER){check(d.commit_rd_write_o&&d.commit_rd_o==7&&uint64_t(d.commit_rd_data_o)==0,
                    "errored fetch modified encoded destination x6");handler_commit=true;}}
            bool trap_now=d.trap_valid_o;
            if(trap_now){check(!d.commit_valid_o&&uint64_t(d.trap_pc_o)==TARGET&&uint32_t(d.trap_insn_o)==0,"precise fetch trap event");trapped=true;}
            d.clk_i=1;d.eval();++cycles;pending=next_pending;error=next_error;insn=next_insn;
            if(trap_now)check(uint64_t(d.csr_mcause_o)==1&&uint64_t(d.csr_mepc_o)==TARGET&&uint64_t(d.csr_mtval_o)==TARGET,"fetch access-fault CSRs");
        }
        check(trapped&&handler_commit&&commits==3,"fetch-fault flow");d.final();
        std::cout<<"{\"status\":\"pass\",\"cycles\":"<<cycles<<",\"commits\":"<<commits<<",\"fetch_faults\":1}\n";return 0;
    }catch(const std::exception&e){std::cerr<<"CORE_FETCH_FAULT_S0_MISMATCH cycle="<<cycles<<" reason="<<e.what()<<'\n';return 1;}
}
