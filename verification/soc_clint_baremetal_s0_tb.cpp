#include "Vfursoy_s0_soc.h"
#include "verilated.h"
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static constexpr uint64_t RAM_BASE=0x80000000ULL, RAM_SIZE=128*1024ULL;
static constexpr uint64_t TOHOST=0x80010000ULL, SIGNATURE=0x80010010ULL;

static uint64_t get64(const std::vector<uint8_t>& b,size_t o){uint64_t v=0;for(int i=0;i<8;i++)v|=uint64_t(b[o+i])<<(8*i);return v;}
static uint32_t get32(const std::vector<uint8_t>& b,size_t o){return uint32_t(get64(b,o)&0xffffffff);}
static uint16_t get16(const std::vector<uint8_t>& b,size_t o){return uint16_t(b[o]|(uint16_t(b[o+1])<<8));}
static void load_elf(const char* path,std::vector<uint8_t>& ram){
    std::ifstream f(path,std::ios::binary); if(!f)throw std::runtime_error("cannot open ELF");
    std::vector<uint8_t>b((std::istreambuf_iterator<char>(f)),{});
    if(b.size()<64||get32(b,0)!=0x464c457f||b[4]!=2||b[5]!=1||get16(b,18)!=243)throw std::runtime_error("invalid ELF64");
    uint64_t phoff=get64(b,32); uint16_t entsz=get16(b,54), count=get16(b,56);
    for(unsigned i=0;i<count;i++){
        size_t o=phoff+i*entsz; if(o+56>b.size())throw std::runtime_error("bad program headers");
        if(get32(b,o)!=1)continue; uint64_t fileoff=get64(b,o+8),addr=get64(b,o+24);
        uint64_t filesz=get64(b,o+32),memsz=get64(b,o+40);
        if(addr<RAM_BASE||memsz>RAM_SIZE||addr-RAM_BASE>RAM_SIZE-memsz||fileoff+filesz>b.size())throw std::runtime_error("segment outside RAM");
        for(uint64_t j=0;j<filesz;j++)ram[addr-RAM_BASE+j]=b[fileoff+j];
    }
}
static uint64_t read_mem(const std::vector<uint8_t>& ram,uint64_t addr,unsigned size){
    unsigned n=1u<<size; if(size>3||addr<RAM_BASE||addr-RAM_BASE>RAM_SIZE-n||addr&(n-1))throw std::runtime_error("bad RAM read");
    uint64_t v=0;for(unsigned i=0;i<n;i++)v|=uint64_t(ram[addr-RAM_BASE+i])<<(8*i);return v;
}
static void write_mem(std::vector<uint8_t>& ram,uint64_t addr,unsigned size,uint64_t value){
    unsigned n=1u<<size; if(size>3||addr<RAM_BASE||addr-RAM_BASE>RAM_SIZE-n||addr&(n-1))throw std::runtime_error("bad RAM write");
    for(unsigned i=0;i<n;i++)ram[addr-RAM_BASE+i]=uint8_t(value>>(8*i));
}

int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv); if(argc<7){std::cerr<<"ELF and five fault PCs required\n";return 1;}
    try {
        std::vector<uint8_t> ram(RAM_SIZE); load_elf(argv[1],ram); Vfursoy_s0_soc d;
        std::vector<uint64_t> fault_pc; for(int i=2;i<7;i++)fault_pc.push_back(std::stoull(argv[i],nullptr,0));
        bool ip=false,dp=false,derr=false,reset_next=false,forced_stall=false; int ddelay=0,irq_countdown=0; uint32_t ii=0;
        uint64_t ia=0,dd=0,commits=0,cycles=0,traps=0;
        uint64_t ram_stalls=0,delayed_loads=0,held_responses=0,same_cycle_responses=0;
        uint64_t fault_commits=0,reset_flushes=0,eligible_irq_faults=0,nonzero_error_responses=0;
        d.clk_i=0;d.rst_i=1;d.imem_req_ready_i=1;d.imem_rsp_valid_i=0;d.imem_rsp_error_i=0;
        d.ram_req_ready_i=1;d.ram_req_error_i=0;d.ram_rsp_valid_i=1;d.ram_rsp_data_i=0xdeadbeef;
        d.ram_rsp_error_i=0;d.irq_external_i=0;d.eval();
        if(!d.ram_rsp_ready_o)throw std::runtime_error("reset did not drain stale RAM response");
        for(int r=0;r<2;r++){d.clk_i=1;d.eval();d.clk_i=0;d.eval();++cycles;}
        d.rst_i=0;
        uint64_t tohost=0;
        while(cycles<20000&&tohost==0){
            if(reset_next){
                d.clk_i=0;d.rst_i=1;d.imem_rsp_valid_i=0;d.ram_rsp_valid_i=1;d.ram_rsp_data_i=0xdeadbeef;d.eval();
                if(!d.ram_rsp_ready_o)throw std::runtime_error("outstanding response not flushed on reset");
                d.clk_i=1;d.eval();++cycles;d.clk_i=0;d.rst_i=0;d.ram_rsp_valid_i=0;d.eval();
                ip=false;dp=false;derr=false;ddelay=0;irq_countdown=0;d.irq_external_i=0;
                reset_next=false;++reset_flushes;continue;
            }
            d.clk_i=0;d.imem_req_ready_i=1;d.imem_rsp_valid_i=ip;d.imem_rsp_insn_i=ii;d.imem_rsp_error_i=0;
            bool ram_ready=true;
            d.ram_req_ready_i=1;d.ram_req_error_i=0;d.ram_rsp_valid_i=dp;d.ram_rsp_data_i=dd;d.ram_rsp_error_i=derr;d.eval();
            if(!forced_stall&&d.ram_req_valid_o){ram_ready=false;forced_stall=true;d.ram_req_ready_i=0;d.eval();}
            bool inject_error=reset_flushes&&d.ram_req_valid_o&&ram_ready&&!d.ram_req_store_o&&uint64_t(d.ram_req_addr_o)==SIGNATURE+56;
            bool inject_same_cycle=inject_error||(reset_flushes&&same_cycle_responses==0&&d.ram_req_valid_o&&ram_ready&&!d.ram_req_store_o);
            if(inject_same_cycle){dd=inject_error?0xfeedfacecafebeefULL:read_mem(ram,d.ram_req_addr_o,d.ram_req_size_o);
                d.ram_rsp_valid_i=1;d.ram_rsp_data_i=dd;d.ram_rsp_error_i=inject_error;d.eval();++same_cycle_responses;
                if(inject_error)++nonzero_error_responses;}
            bool response_presented=dp||inject_same_cycle;
            bool ifire=ip&&d.imem_rsp_ready_o, dfire=response_presented&&d.ram_rsp_ready_o;
            bool ireq=d.imem_req_valid_o&&d.imem_req_ready_i, dreq=d.ram_req_valid_o&&d.ram_req_ready_i;
            bool nip=ip,ndp=response_presented,nderr=inject_same_cycle?inject_error:derr;uint32_t nii=ii;uint64_t nia=ia,ndd=dd;
            if(d.ram_req_valid_o&&!ram_ready)++ram_stalls;
            if(response_presented&&!d.ram_rsp_ready_o)++held_responses;
            if(ifire)nip=false;if(dfire){ndp=false;nderr=false;}
            if(ifire&&ia==fault_pc[3])irq_countdown=2;
            if(ireq){nia=d.imem_req_addr_o;nii=uint32_t(read_mem(ram,nia,2));nip=true;}
            if(dreq){uint64_t a=d.ram_req_addr_o;unsigned s=d.ram_req_size_o;
                if(d.ram_req_store_o){write_mem(ram,a,s,d.ram_req_store_data_o);if(a==TOHOST){tohost=d.ram_req_store_data_o;}}
                else if(!inject_same_cycle){ndd=read_mem(ram,a,s);nderr=false;ddelay=3;++delayed_loads;if(!reset_flushes)reset_next=true;}
            }
            if(ddelay>0&&--ddelay==0)ndp=true;
            if(d.commit_valid_o){++commits;for(auto pc:fault_pc)if(uint64_t(d.commit_pc_o)==pc)++fault_commits;}
            bool clear_irq=false;
            if(d.trap_valid_o){++traps;if(uint64_t(d.trap_pc_o)==fault_pc[3]){
                if((uint64_t(d.csr_mstatus_o)&8)==0||(uint64_t(d.csr_mie_o)&0x800)==0||
                   (uint64_t(d.csr_mip_o)&0x800)==0)throw std::runtime_error("fault did not coincide with eligible IRQ");
                ++eligible_irq_faults;clear_irq=true;
            }}
            d.clk_i=1;d.eval();++cycles;ip=nip;ii=nii;ia=nia;dp=ndp;derr=nderr;dd=ndd;
            if(irq_countdown>0&&--irq_countdown==0)d.irq_external_i=1;
            if(clear_irq)d.irq_external_i=0;
        }
        auto sig=[&](unsigned i){return read_mem(ram,SIGNATURE+8*i,3);};
        if(tohost!=1||traps!=7||fault_commits||!ram_stalls||!delayed_loads||!held_responses||
           same_cycle_responses!=2||nonzero_error_responses!=1||reset_flushes!=1||eligible_irq_faults!=1||
           sig(0)!=1||sig(1)!=1||sig(2)!=1||sig(3)!=1||sig(4)!=1||sig(5)!=1||sig(6)!=1||sig(7)!=1){
            std::cerr<<"DEBUG tohost="<<tohost<<" traps="<<traps<<" fault_commits="<<fault_commits
                <<" stalls="<<ram_stalls<<" delayed="<<delayed_loads<<" sig=";
            for(unsigned i=0;i<8;i++)std::cerr<<sig(i)<<",";std::cerr<<"\n";
            throw std::runtime_error("architectural result mismatch");
        }
        d.final();std::cout<<"{\"status\":\"pass\",\"cycles\":"<<cycles<<",\"commits\":"<<commits
            <<",\"traps\":"<<traps<<",\"software_irqs\":"<<sig(0)<<",\"timer_irqs\":"<<sig(1)
            <<",\"store_faults\":"<<sig(2)<<",\"width_load_faults\":"<<sig(3)
            <<",\"unmapped_load_faults\":"<<sig(4)<<",\"misaligned_load_faults\":"<<sig(5)
            <<",\"pending_irq_faults\":"<<sig(6)<<",\"ram_request_stalls\":"<<ram_stalls
            <<",\"delayed_ram_loads\":"<<delayed_loads<<",\"held_ram_response_cycles\":"<<held_responses
            <<",\"same_cycle_ram_responses\":"<<same_cycle_responses<<",\"eligible_irq_faults\":"<<eligible_irq_faults
            <<",\"nonzero_error_responses\":"<<nonzero_error_responses
            <<",\"reset_response_flushes\":"<<reset_flushes
            <<",\"faulting_commits\":"<<fault_commits<<"}\n";return 0;
    } catch(const std::exception&e){std::cerr<<"SOC_CLINT_BAREMETAL_MISMATCH: "<<e.what()<<'\n';return 1;}
}
