#include "Vfursoy_s0_lsu_port.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv); Vfursoy_s0_lsu_port d; unsigned cycles=0;
    auto check=[](bool ok,const char* why){if(!ok)throw std::runtime_error(why);};
    auto step=[&](bool reset,bool issue,bool store,uint64_t addr,unsigned size,bool unsign,
                  uint64_t data,unsigned rd,bool req_ready,bool req_error,bool rsp_valid,
                  bool rsp_error,uint64_t rsp_data){
        d.clk_i=0; d.rst_i=reset; d.issue_valid_i=issue; d.issue_store_i=store;
        d.issue_addr_i=addr; d.issue_size_i=size; d.issue_unsigned_i=unsign;
        d.issue_store_data_i=data; d.issue_rd_i=rd; d.issue_pc_i=0x80000100;
        d.issue_insn_i=store?0x0020a023:0x0000a283; d.dmem_req_ready_i=req_ready;
        d.dmem_req_error_i=req_error; d.dmem_rsp_valid_i=rsp_valid;
        d.dmem_rsp_error_i=rsp_error; d.dmem_rsp_data_i=rsp_data;
        d.eval(); d.clk_i=1; d.eval(); ++cycles;
    };
    try {
        step(1,0,0,0,0,0,0,0,0,0,0,0,0);
        step(0,1,1,0x100,2,0,0x11223344,0,0,0,0,0,0);
        d.clk_i=0; d.eval(); check(d.dmem_req_valid_o&&!d.retire_valid_o,"store wait");
        step(0,0,0,0,0,0,0,0,1,0,0,0,0);
        step(0,1,0,0x108,1,0,0,5,0,0,0,0,0);
        step(0,0,0,0,0,0,0,0,1,0,0,0,0);
        d.clk_i=0; d.dmem_rsp_valid_i=1; d.dmem_rsp_data_i=0xff80; d.eval();
        check(d.retire_valid_o&&uint64_t(d.retire_rd_data_o)==0xffffffffffffff80ULL,"signed load");
        d.clk_i=1; d.eval(); ++cycles;
        step(0,1,1,0x200,3,0,0,0,0,0,0,0,0);
        d.clk_i=0; d.dmem_req_ready_i=1; d.dmem_req_error_i=1; d.eval();
        check(d.fault_valid_o&&d.fault_store_o&&!d.retire_valid_o&&uint64_t(d.fault_addr_o)==0x200,"store fault");
        d.clk_i=1; d.eval(); ++cycles;
        step(0,1,0,0x208,3,0,0,6,0,0,0,0,0);
        step(0,0,0,0,0,0,0,0,1,0,0,0,0);
        d.clk_i=0; d.dmem_rsp_valid_i=1; d.dmem_rsp_error_i=1; d.eval();
        check(d.fault_valid_o&&!d.fault_store_o&&!d.retire_valid_o&&uint64_t(d.fault_addr_o)==0x208,"load fault");
        d.final(); std::cout<<"{\"status\":\"pass\",\"cycles\":"<<cycles<<",\"fault_checks\":2}\n"; return 0;
    } catch(const std::exception& e) {
        std::cerr<<"LSU_PORT_S0_MISMATCH cycle="<<cycles<<" reason="<<e.what()<<'\n'; return 1;
    }
}
