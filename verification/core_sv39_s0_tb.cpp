#include "Vfursoy_s0_core.h"
#include "Vfursoy_s0_core___024root.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>

static void check(bool v,const char*m){if(!v)throw std::runtime_error(m);}
static uint32_t addi(unsigned rd,unsigned rs1,int imm){return((uint32_t(imm)&0xfff)<<20)|(rs1<<15)|(rd<<7)|0x13;}
static uint32_t slli(unsigned rd,unsigned rs1,unsigned sh){return(sh<<20)|(rs1<<15)|(1<<12)|(rd<<7)|0x13;}
static uint32_t ori(unsigned rd,unsigned a,unsigned b){return(b<<20)|(a<<15)|(6<<12)|(rd<<7)|0x33;}
static uint32_t csr(unsigned f,unsigned rd,unsigned rs1,unsigned a){return(a<<20)|(rs1<<15)|(f<<12)|(rd<<7)|0x73;}
static uint32_t auipc(unsigned rd){return(rd<<7)|0x17;}
static uint32_t ld(unsigned rd,unsigned rs1,int imm){return((uint32_t(imm)&0xfff)<<20)|(rs1<<15)|(3<<12)|(rd<<7)|3;}
static uint32_t sd(unsigned rs2,unsigned rs1,int imm){uint32_t u=imm;return((u>>5&0x7f)<<25)|(rs2<<20)|(rs1<<15)|(3<<12)|((u&31)<<7)|0x23;}
static constexpr uint32_t MRET=0x30200073,SFENCE=0x12000073;

struct Event{bool commit=false,trap=false,rsp_fire=false,ptw_fire=false;uint64_t pc=0,rsp_pc=0,rd_data=0;unsigned rd=0;};
struct Sim{
 Vfursoy_s0_core d;std::unordered_map<uint64_t,uint32_t> imem;std::unordered_map<uint64_t,uint64_t> dmem;
 bool ip=false,dp=false;uint64_t ia=0,dd=0;uint64_t ii=0;unsigned stores=0;
 void reset(){d.clk_i=0;d.rst_i=1;d.imem_req_ready_i=1;d.imem_rsp_valid_i=0;d.imem_rsp_data_i=0;d.imem_rsp_error_i=0;d.dmem_req_ready_i=1;d.dmem_req_error_i=0;d.dmem_rsp_valid_i=0;d.dmem_rsp_data_i=0;d.dmem_rsp_error_i=0;d.irq_software_i=d.irq_timer_i=d.irq_external_i=d.irq_seip_i=0;d.eval();d.clk_i=1;d.eval();d.clk_i=0;d.rst_i=0;d.eval();ip=dp=false;stores=0;}
 Event tick(){d.clk_i=0;d.imem_req_ready_i=1;d.imem_rsp_valid_i=ip;d.imem_rsp_data_i=ii;d.imem_rsp_error_i=0;d.dmem_req_ready_i=1;d.dmem_req_error_i=0;d.dmem_rsp_valid_i=dp;d.dmem_rsp_data_i=dd;d.dmem_rsp_error_i=0;d.eval();
  Event e;e.commit=d.commit_valid_o;e.trap=d.trap_valid_o;e.pc=e.commit?uint64_t(d.commit_pc_o):uint64_t(d.trap_pc_o);e.rd=d.commit_rd_o;e.rd_data=d.commit_rd_data_o;e.rsp_fire=ip&&d.imem_rsp_ready_o;e.rsp_pc=ia;e.ptw_fire=d.dmem_req_valid_o&&d.dmem_req_ready_i&&d.dmem_req_ptw_o;
  bool ir=e.rsp_fire,iq=d.imem_req_valid_o&&d.imem_req_ready_i,dr=dp&&d.dmem_rsp_ready_o,dq=d.dmem_req_valid_o&&d.dmem_req_ready_i;uint64_t nqa=d.imem_req_addr_o,nda=d.dmem_req_addr_o;bool nstore=d.dmem_req_store_o;
  d.clk_i=1;d.eval();if(ir)ip=false;if(iq){ia=nqa;uint64_t w0=imem.count(ia)?uint64_t(imem[ia]):0x13;uint64_t w1=imem.count(ia+4)?uint64_t(imem[ia+4]):0x13;ii=(w1<<32)|(w0&0xFFFFFFFFULL);ip=true;}if(dr)dp=false;if(dq){if(nstore){++stores;dmem[nda]=d.dmem_req_store_data_o;}else{dd=dmem.count(nda)?dmem[nda]:0;dp=true;}}d.clk_i=0;d.eval();return e;}
 Event until_trap(unsigned n=300){for(unsigned i=0;i<n;i++){auto e=tick();if(e.trap)return e;}throw std::runtime_error("trap timeout");}
 Event until_commit(uint64_t pc,unsigned n=300){for(unsigned i=0;i<n;i++){auto e=tick();if(e.commit&&e.pc==pc)return e;}throw std::runtime_error("commit timeout");}
};

static constexpr uint64_t B=0x80000000ULL,MTV=B+0x300,STV=B+0x200,ROOT=0x100;
static void root_map(Sim&s){s.dmem[(ROOT<<12)+2*8]=(0x80000ULL<<10)|0xcf;}
static void setup_s(Sim&s,uint64_t target,unsigned delegate=0,bool tvm=false,bool meie=false){
 unsigned o=0;
 s.imem[B+o]=addi(10,0,-1);o+=4;s.imem[B+o]=csr(1,0,10,0x3b0);o+=4;
 s.imem[B+o]=addi(11,0,0x1f);o+=4;s.imem[B+o]=csr(1,0,11,0x3a0);o+=4;
 s.imem[B+o]=addi(1,0,8);o+=4;s.imem[B+o]=slli(1,1,60);o+=4;s.imem[B+o]=addi(2,0,ROOT);o+=4;s.imem[B+o]=ori(1,1,2);o+=4;s.imem[B+o]=csr(1,0,1,0x180);o+=4;
 if(delegate){s.imem[B+o]=addi(3,0,1);o+=4;s.imem[B+o]=slli(3,3,delegate);o+=4;s.imem[B+o]=csr(1,0,3,0x302);o+=4;}
 s.imem[B+o]=auipc(4);uint64_t pc=B+o;o+=4;s.imem[B+o]=addi(4,4,int(STV-pc));o+=4;s.imem[B+o]=csr(1,0,4,0x105);o+=4;
 if(meie){s.imem[B+o]=addi(7,0,1);o+=4;s.imem[B+o]=slli(7,7,11);o+=4;s.imem[B+o]=csr(2,0,7,0x304);o+=4;}
 if(target==0)s.imem[B+o]=addi(4,0,0);else{s.imem[B+o]=auipc(4);pc=B+o;s.imem[B+o+4]=addi(4,4,int(target-pc));o+=4;}o+=4;s.imem[B+o]=csr(1,0,4,0x341);o+=4;
 s.imem[B+o]=addi(5,0,3);o+=4;s.imem[B+o]=slli(5,5,11);o+=4;s.imem[B+o]=csr(3,0,5,0x300);o+=4;s.imem[B+o]=addi(5,0,1);o+=4;s.imem[B+o]=slli(5,5,11);o+=4;s.imem[B+o]=csr(2,0,5,0x300);o+=4;
 if(tvm){s.imem[B+o]=addi(6,0,1);o+=4;s.imem[B+o]=slli(6,6,20);o+=4;s.imem[B+o]=csr(2,0,6,0x300);o+=4;}s.imem[B+o]=MRET;
}
static void irq_setup(Sim&s,uint32_t target_insn,uint64_t &target){
 unsigned o=0;s.imem[B+o]=addi(1,0,1);o+=4;s.imem[B+o]=slli(1,1,11);o+=4;s.imem[B+o]=csr(2,0,1,0x304);o+=4;s.imem[B+o]=addi(1,0,8);o+=4;s.imem[B+o]=csr(2,0,1,0x300);o+=4;target=B+o;s.imem[target]=target_insn;s.imem[MTV]=addi(31,0,1);
}

int main(int argc,char**argv){Verilated::commandArgs(argc,argv);unsigned scenarios=0;try{
 {Sim s;s.reset();s.imem[B]=addi(1,0,8);s.imem[B+4]=slli(1,1,60);s.imem[B+8]=addi(2,0,ROOT);s.imem[B+12]=ori(1,1,2);s.imem[B+16]=addi(4,0,1);s.imem[B+20]=slli(4,4,44);s.imem[B+24]=ori(1,1,4);s.imem[B+28]=csr(1,0,1,0x180);s.imem[B+32]=addi(1,0,9);s.imem[B+36]=slli(1,1,60);s.imem[B+40]=csr(1,0,1,0x180);s.imem[B+44]=csr(1,0,0,0x180);s.until_commit(B+40);check(uint64_t(s.d.csr_satp_o)==(0x8000000000000000ULL|ROOT),"unsupported satp.MODE or ASID WARL");s.until_commit(B+44);check(uint64_t(s.d.csr_satp_o)==0,"Sv39 to Bare transition");++scenarios;}
 {Sim s;s.reset();s.imem[B]=addi(1,0,1);s.imem[B+4]=csr(1,0,1,0x180);s.until_commit(B+4);check(uint64_t(s.d.csr_satp_o)==0,"Bare satp write did not coerce whole CSR to zero");++scenarios;}
 {Sim s;s.reset();s.imem[B]=SFENCE;auto e=s.until_commit(B);check(!e.trap,"M SFENCE.VMA legality");++scenarios;}
 {Sim s;s.reset();s.imem[B]=addi(1,0,1);s.imem[B+4]=addi(2,0,2);s.imem[B+8]=SFENCE|(1u<<15)|(2u<<20);auto e=s.until_commit(B+8);check(!e.trap,"SFENCE.VMA rs1/rs2 scoped form legality");++scenarios;}
 {Sim s;s.reset();s.imem[B]=SFENCE|(1u<<7);auto e=s.until_trap();check(e.pc==B&&uint64_t(s.d.csr_mcause_o)==2,"reserved SFENCE.VMA rd encoding");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,0,false);s.imem[B+0x100]=SFENCE;auto e=s.until_commit(B+0x100);check(!e.trap&&s.d.priv_mode_o==1,"S SFENCE.VMA legality");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,0,true);s.imem[B+0x100]=SFENCE;auto e=s.until_trap();check(e.pc==B+0x100&&uint64_t(s.d.csr_mcause_o)==2,"TVM SFENCE interception");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,0,true);s.imem[B+0x100]=csr(2,1,0,0x180);auto e=s.until_trap();check(e.pc==B+0x100&&uint64_t(s.d.csr_mcause_o)==2,"TVM satp CSR interception");++scenarios;}
 {Sim s;s.reset();s.imem[B]=addi(10,0,-1);s.imem[B+4]=csr(1,0,10,0x3b0);s.imem[B+8]=addi(11,0,0x1f);s.imem[B+12]=csr(1,0,11,0x3a0);s.imem[B+16]=auipc(1);s.imem[B+20]=addi(1,1,0x30);s.imem[B+24]=csr(1,0,1,0x341);s.imem[B+28]=addi(2,0,3);s.imem[B+32]=slli(2,2,11);s.imem[B+36]=csr(3,0,2,0x300);s.imem[B+40]=MRET;s.imem[B+0x40]=SFENCE;auto e=s.until_trap();check(e.pc==B+0x40&&uint64_t(s.d.csr_mcause_o)==2,"U SFENCE privilege check");++scenarios;}
 {Sim s;s.reset();s.imem[B]=addi(1,0,-1);s.imem[B+4]=csr(1,0,1,0x30a);s.imem[B+8]=csr(1,0,1,0x10a);s.until_commit(B+8);check(uint64_t(s.d.csr_menvcfg_o)==1&&uint64_t(s.d.csr_senvcfg_o)==1,"FIOM WARL and ADUE/PBMTE RO0");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,13);s.imem[B+0x100]=ld(6,0,0);auto e=s.until_trap();check(e.pc==B+0x100&&s.d.priv_mode_o==1&&uint64_t(s.d.csr_scause_o)==13&&uint64_t(s.d.csr_stval_o)==0&&uint64_t(s.d.csr_sepc_o)==B+0x100,"delegated load page fault");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100);s.imem[B+0x100]=addi(6,0,0x5a);s.imem[B+0x104]=ld(6,0,0);s.imem[MTV]=addi(7,6,0);auto e=s.until_trap();check(e.pc==B+0x104&&uint64_t(s.d.csr_mcause_o)==13&&uint64_t(s.d.csr_mtval_o)==0&&uint64_t(s.d.csr_mepc_o)==B+0x104,"nondelegated load page fault metadata");auto h=s.until_commit(MTV);check(h.rd==7&&h.rd_data==0x5a,"page-faulting load changed destination");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100);s.imem[B+0x100]=addi(6,0,1);s.imem[B+0x104]=sd(6,0,0);auto e=s.until_trap();check(e.pc==B+0x104&&uint64_t(s.d.csr_mcause_o)==15&&s.stores==0,"page-faulting store side effect");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,13);s.imem[B+0x100]=addi(6,0,1);s.imem[B+0x104]=slli(6,6,38);s.imem[B+0x108]=ld(7,6,0);auto e=s.until_trap();check(e.pc==B+0x108&&s.d.priv_mode_o==1&&uint64_t(s.d.csr_scause_o)==13&&uint64_t(s.d.csr_stval_o)==0x0000004000000000ULL&&uint64_t(s.d.csr_sepc_o)==B+0x108,"noncanonical load boundary 1 metadata");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,13);s.imem[B+0x100]=addi(6,0,1);s.imem[B+0x104]=slli(6,6,39);s.imem[B+0x108]=ld(7,6,0);auto e=s.until_trap();check(e.pc==B+0x108&&s.d.priv_mode_o==1&&uint64_t(s.d.csr_scause_o)==13&&uint64_t(s.d.csr_stval_o)==0x0000008000000000ULL&&uint64_t(s.d.csr_sepc_o)==B+0x108,"noncanonical load boundary 2 metadata");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,15);s.imem[B+0x100]=addi(6,0,1);s.imem[B+0x104]=slli(6,6,38);s.imem[B+0x108]=sd(5,6,0);auto e=s.until_trap();check(e.pc==B+0x108&&s.d.priv_mode_o==1&&uint64_t(s.d.csr_scause_o)==15&&uint64_t(s.d.csr_stval_o)==0x0000004000000000ULL&&uint64_t(s.d.csr_sepc_o)==B+0x108&&s.stores==0,"noncanonical store metadata and suppression");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,0);s.imem[MTV]=addi(7,0,1);auto e=s.until_trap();check(e.pc==0&&uint64_t(s.d.csr_mcause_o)==12&&uint64_t(s.d.csr_mtval_o)==0,"instruction page fault metadata");++scenarios;}
 for(unsigned kind=0;kind<3;kind++){Sim s;s.reset();uint64_t target;unsigned o=0;
   if(kind==0){s.imem[B+o]=addi(2,0,8);o+=4;s.imem[B+o]=slli(2,2,60);o+=4;s.imem[B+o]=addi(3,0,ROOT);o+=4;s.imem[B+o]=ori(2,2,3);o+=4;s.imem[B+o]=csr(1,0,2,0x180);o+=4;}
   if(kind==1){s.imem[B+o]=addi(2,0,7);o+=4;s.imem[B+o]=slli(2,2,18);o+=4;}
   s.imem[B+o]=addi(1,0,1);o+=4;s.imem[B+o]=slli(1,1,11);o+=4;s.imem[B+o]=csr(2,0,1,0x304);o+=4;
   s.imem[B+o]=addi(1,0,8);s.imem[B+o+4]=csr(2,0,1,0x300);o+=8;target=B+o;
   s.imem[target]=kind==0?csr(1,0,0,0x180):(kind==1?csr(2,0,2,0x300):SFENCE);s.imem[MTV]=addi(31,0,1);
   bool at=false;for(int i=0;i<150&&!at;i++){auto e=s.tick();at=(s.d.rootp->fursoy_s0_core__DOT__fe_valid_w&&s.d.rootp->fursoy_s0_core__DOT__fe_pc_w==target);}check(at,"target response boundary");uint64_t satp_before=s.d.csr_satp_o;s.d.irq_external_i=1;auto e=s.until_trap();check(e.pc==target&&(uint64_t(s.d.csr_mcause_o)>>63)&&((uint64_t(s.d.csr_mcause_o)&63)==11),"pending interrupt did not preempt boundary");if(kind==0)check(satp_before!=0&&uint64_t(s.d.csr_satp_o)==satp_before,"preempted satp write committed");if(kind==1)check((uint64_t(s.d.csr_mstatus_o)&(7ULL<<18))==0,"preempted SUM/MXR/TVM write committed");++scenarios;}
 {Sim s;s.reset();root_map(s);setup_s(s,B+0x100,0,false,true);s.imem[B+0x100]=addi(8,0,1);s.imem[MTV]=addi(9,0,1);bool walk=false;for(int i=0;i<300&&!walk;i++){auto e=s.tick();walk=e.ptw_fire;}check(walk,"instruction PTW did not start");s.d.irq_external_i=1;auto e=s.until_trap();check((uint64_t(s.d.csr_mcause_o)>>63)&&((uint64_t(s.d.csr_mcause_o)&63)==11)&&e.pc==B+0x100,"interrupt during instruction PTW");s.d.irq_external_i=0;s.until_commit(MTV);++scenarios;}
 std::cout<<"{\"status\":\"pass\",\"scenarios\":"<<scenarios<<"}\n";return 0;}catch(const std::exception&e){std::cerr<<"CORE_SV39_S0_MISMATCH scenario="<<scenarios+1<<" reason="<<e.what()<<"\n";return 1;}}
