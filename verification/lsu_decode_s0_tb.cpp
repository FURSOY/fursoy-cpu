#include "Vfursoy_s0_lsu_decode.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
static uint32_t load(unsigned f3,unsigned rd,unsigned rs1,int imm){return (uint32_t(imm)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|3;}
static uint32_t store(unsigned f3,unsigned rs1,unsigned rs2,int imm){uint32_t u=uint32_t(imm);return ((u>>5)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((u&31)<<7)|0x23;}
int main(int argc,char** argv){Verilated::commandArgs(argc,argv);Vfursoy_s0_lsu_decode d;unsigned n=0;auto e=[&](uint32_t i,uint64_t base,uint64_t data,bool v,bool st,uint64_t a,unsigned sz,bool u,bool mis){d.insn_valid_i=1;d.insn_i=i;d.rs1_i=base;d.rs2_i=data;d.eval();++n;if(bool(d.lsu_valid_o)!=v||bool(d.lsu_store_o)!=st||uint64_t(d.address_o)!=a||unsigned(d.size_o)!=sz||bool(d.load_unsigned_o)!=u||uint64_t(d.store_data_o)!=(st?data:0)||bool(d.misaligned_o)!=mis)throw std::runtime_error("decode");};try{e(load(0,1,2,-1),0x80000101,0,true,false,0x80000100,0,false,false);e(load(5,1,2,2),0x100,0,true,false,0x102,1,true,false);e(load(2,1,2,0),0x101,0,true,false,0x101,2,false,true);e(store(3,2,3,-8),0x108,0x1122334455667788ULL,true,true,0x100,3,false,false);e(store(1,2,3,0),0x101,9,true,true,0x101,1,false,true);e(0xffffffff,0,0,false,false,0,0,false,false);d.final();std::cout<<"{\"status\":\"pass\",\"checks\":"<<n<<"}\n";return 0;}catch(const std::exception&x){std::cerr<<"LSU_DECODE_S0_MISMATCH check="<<n<<" reason="<<x.what()<<'\n';return 1;}}
