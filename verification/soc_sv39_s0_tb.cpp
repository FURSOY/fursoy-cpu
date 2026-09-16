#include "Vfursoy_s0_soc.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
static uint32_t addi(unsigned d,unsigned s,int i){return((uint32_t(i)&0xfff)<<20)|(s<<15)|(d<<7)|0x13;}
static uint32_t slli(unsigned d,unsigned s,unsigned n){return(n<<20)|(s<<15)|(1<<12)|(d<<7)|0x13;}
static uint32_t ori(unsigned d,unsigned a,unsigned b){return(b<<20)|(a<<15)|(6<<12)|(d<<7)|0x33;}
static uint32_t csr(unsigned f,unsigned d,unsigned s,unsigned a){return(a<<20)|(s<<15)|(f<<12)|(d<<7)|0x73;}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);constexpr uint64_t B=0x80000000ULL,T=B+0x80;Vfursoy_s0_soc d;std::unordered_map<uint64_t,uint32_t>m;
 m[B]=addi(1,0,8);m[B+4]=slli(1,1,60);m[B+8]=addi(2,0,1);m[B+12]=slli(2,2,13);m[B+16]=ori(1,1,2);m[B+20]=csr(1,0,1,0x180);
 m[B+24]=(3<<7)|0x17;m[B+28]=addi(3,3,0x68);m[B+32]=csr(1,0,3,0x341);m[B+36]=addi(4,0,3);m[B+40]=slli(4,4,11);m[B+44]=csr(3,0,4,0x300);m[B+48]=addi(4,0,1);m[B+52]=slli(4,4,11);m[B+56]=csr(2,0,4,0x300);m[B+60]=0x30200073;
 d.clk_i=0;d.rst_i=1;d.imem_req_ready_i=1;d.imem_rsp_valid_i=0;d.imem_rsp_data_i=0;d.imem_rsp_error_i=0;d.ram_req_ready_i=1;d.ram_req_error_i=0;d.ram_rsp_valid_i=0;d.ram_rsp_data_i=0;d.ram_rsp_error_i=0;d.irq_external_i=0;d.eval();d.clk_i=1;d.eval();d.clk_i=0;d.rst_i=0;bool pending=false;uint64_t rsp_data=0;unsigned ram_reqs=0;
 try{for(int cycle=0;cycle<600;cycle++){d.clk_i=0;d.imem_rsp_valid_i=pending;d.imem_rsp_data_i=rsp_data;d.eval();bool ir=pending&&d.imem_rsp_ready_o,iq=d.imem_req_valid_o&&d.imem_req_ready_i;if(d.ram_req_valid_o&&d.ram_req_ready_i)++ram_reqs;if(d.trap_valid_o){d.clk_i=1;d.eval();if(uint64_t(d.csr_mcause_o)!=1||uint64_t(d.csr_mtval_o)!=T||uint64_t(d.csr_mepc_o)!=T)throw std::runtime_error("PTW rejection metadata cause="+std::to_string(uint64_t(d.csr_mcause_o))+" tval="+std::to_string(uint64_t(d.csr_mtval_o))+" epc="+std::to_string(uint64_t(d.csr_mepc_o)));if(ram_reqs!=0)throw std::runtime_error("CLINT-window PTW escaped to RAM");if((uint64_t(d.csr_mip_o)&0x888)!=0)throw std::runtime_error("rejected PTW changed CLINT interrupt state");std::cout<<"{\"status\":\"pass\",\"scenarios\":1}\n";return 0;}uint64_t na=d.imem_req_addr_o;d.clk_i=1;d.eval();if(ir)pending=false;if(iq){uint64_t w0=m.count(na)?uint64_t(m[na]):0x00000013ULL;uint64_t w1=m.count(na+4)?uint64_t(m[na+4]):0x00000013ULL;rsp_data=(w1<<32)|(w0&0xFFFFFFFFULL);pending=true;}d.clk_i=0;d.eval();}throw std::runtime_error("trap timeout");}catch(const std::exception&e){std::cerr<<"SOC_SV39_S0_MISMATCH "<<e.what()<<"\n";return 1;}}
