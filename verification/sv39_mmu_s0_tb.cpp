#include "Vfursoy_s0_mmu.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <unordered_map>

static void check(bool v, const char *m) { if (!v) throw std::runtime_error(m); }

struct Response { uint64_t data = 0; bool error = false; };
struct Snap {
    bool vi_req_fire, vi_rsp_valid, vi_rsp_error, vi_rsp_page;
    uint32_t vi_insn;
    bool vd_req_fire, vd_req_error, vd_req_page;
    bool vd_rsp_valid, vd_rsp_error, vd_rsp_page;
    uint64_t vd_data;
    bool pd_req_fire, pd_store, pd_ptw, pd_req_error;
    uint64_t pd_addr;
    bool pi_req_fire;
    uint64_t pi_addr;
};

struct Sim {
    Vfursoy_s0_mmu d;
    std::unordered_map<uint64_t, Response> pte;
    std::unordered_map<uint64_t, Response> data;
    std::unordered_map<uint64_t, Response> insn;
    bool pd_pending = false, pi_pending = false;
    Response pd_response{}, pi_response{};
    bool pd_ready = true, pi_ready = true, final_store_error = false;
    unsigned ptw_requests = 0, final_data_requests = 0, physical_stores = 0, final_i_requests = 0;
    uint64_t last_final_pa = 0, last_ptw_pa = 0;

    void defaults() {
        d.clk_i=0; d.rst_i=0; d.redirect_i=0; d.priv_mode_i=1; d.mstatus_i=0;
        d.satp_i=0; d.vi_req_valid_i=0; d.vi_req_addr_i=0; d.vi_rsp_ready_i=1;
        d.vd_req_valid_i=0; d.vd_req_store_i=0; d.vd_req_addr_i=0;
        d.vd_req_size_i=3; d.vd_req_store_data_i=0; d.vd_rsp_ready_i=1;
        d.pi_req_ready_i=1; d.pi_rsp_valid_i=0; d.pi_rsp_insn_i=0; d.pi_rsp_error_i=0;
        d.pd_req_ready_i=1; d.pd_req_error_i=0; d.pd_rsp_valid_i=0;
        d.pd_rsp_data_i=0; d.pd_rsp_error_i=0;
        d.pmp_cfg_i[0]=0x1f; d.pmp_addr_i[0]=0x3fffffffffffffULL;
        for(int i=1;i<16;++i){d.pmp_cfg_i[i]=0;d.pmp_addr_i[i]=0;}
    }
    void reset() {
        defaults(); pte.clear(); data.clear(); insn.clear(); pd_pending=pi_pending=false;
        ptw_requests=final_data_requests=physical_stores=final_i_requests=0;final_store_error=false;
        d.rst_i=1; step(); step(); d.rst_i=0;
    }
    Snap step() {
        d.pd_req_ready_i=pd_ready; d.pi_req_ready_i=pi_ready;
        d.pd_rsp_valid_i=pd_pending; d.pd_rsp_data_i=pd_response.data; d.pd_rsp_error_i=pd_response.error;
        d.pi_rsp_valid_i=pi_pending; d.pi_rsp_insn_i=uint32_t(pi_response.data); d.pi_rsp_error_i=pi_response.error;
        d.clk_i=0; d.pd_req_error_i=0; d.eval();
        if(final_store_error&&d.pd_req_valid_o&&d.pd_req_store_o&&!d.pd_req_ptw_o){d.pd_req_error_i=1;d.eval();}
        Snap s{bool(d.vi_req_valid_i&&d.vi_req_ready_o),bool(d.vi_rsp_valid_o),bool(d.vi_rsp_error_o),
               bool(d.vi_rsp_page_fault_o),uint32_t(d.vi_rsp_insn_o),
               bool(d.vd_req_valid_i&&d.vd_req_ready_o),bool(d.vd_req_error_o),bool(d.vd_req_page_fault_o),
               bool(d.vd_rsp_valid_o),bool(d.vd_rsp_error_o),bool(d.vd_rsp_page_fault_o),uint64_t(d.vd_rsp_data_o),
               bool(d.pd_req_valid_o&&d.pd_req_ready_i),bool(d.pd_req_store_o),bool(d.pd_req_ptw_o),bool(d.pd_req_error_i),
               uint64_t(d.pd_req_addr_o),bool(d.pi_req_valid_o&&d.pi_req_ready_i),uint64_t(d.pi_req_addr_o)};
        bool pd_rsp_fire=d.pd_rsp_valid_i&&d.pd_rsp_ready_o;
        bool pi_rsp_fire=d.pi_rsp_valid_i&&d.pi_rsp_ready_o;
        d.clk_i=1; d.eval();
        if (pd_rsp_fire) pd_pending=false;
        if (pi_rsp_fire) pi_pending=false;
        if (s.pd_req_fire) {
            if (s.pd_ptw) {
                ++ptw_requests; last_ptw_pa=s.pd_addr;
                auto it=pte.find(s.pd_addr); pd_response=it==pte.end()?Response{0,true}:it->second;
                pd_pending=true;
            } else if (s.pd_store) {
                if(!s.pd_req_error) {
                    ++physical_stores;
                    data[s.pd_addr] = Response{d.pd_req_store_data_o, false};
                }
                ++final_data_requests; last_final_pa=s.pd_addr;
            } else {
                ++final_data_requests; last_final_pa=s.pd_addr;
                auto it=data.find(s.pd_addr); pd_response=it==data.end()?Response{0,true}:it->second;
                pd_pending=true;
            }
        }
        if (s.pi_req_fire) {
            ++final_i_requests; last_final_pa=s.pi_addr;
            auto it=insn.find(s.pi_addr); pi_response=it==insn.end()?Response{0,true}:it->second;
            pi_pending=true;
        }
        d.clk_i=0; d.eval();
        return s;
    }
};

static uint64_t pte(uint64_t ppn, uint64_t flags) { return (ppn<<10)|flags; }
static uint64_t satp(uint64_t root) { return 0x8000000000000000ULL|root; }
static unsigned vpn(uint64_t va, unsigned level) { return unsigned((va>>(12+9*level))&0x1ff); }
static uint64_t pte_addr(uint64_t ppn, unsigned index) { return (ppn<<12)+(uint64_t(index)<<3); }

static uint64_t install(Sim &s, uint64_t va, unsigned leaf_level, uint64_t leaf_ppn,
                        uint64_t leaf_flags, uint64_t root=0x100) {
    uint64_t table=root;
    for (int level=2; level>int(leaf_level); --level) {
        uint64_t next=root+unsigned(3-level)+1;
        s.pte[pte_addr(table,vpn(va,level))]={pte(next,1),false};
        table=next;
    }
    s.pte[pte_addr(table,vpn(va,leaf_level))]={pte(leaf_ppn,leaf_flags),false};
    return root;
}

struct Result { bool error=false, page=false; uint64_t value=0; bool early_store_ready=false; };
static Result instruction(Sim &s, uint64_t va, unsigned limit=100) {
    s.d.vi_req_addr_i=va; s.d.vi_req_valid_i=1; bool accepted=false;
    for(unsigned i=0;i<limit;i++){auto x=s.step();if(x.vi_req_fire){accepted=true;s.d.vi_req_valid_i=0;break;}}
    check(accepted,"instruction request not accepted");
    for(unsigned i=0;i<limit;i++){auto x=s.step();if(x.vi_rsp_valid)return{x.vi_rsp_error,x.vi_rsp_page,x.vi_insn};}
    throw std::runtime_error("instruction response timeout");
}
static Result load(Sim &s, uint64_t va, unsigned limit=100) {
    s.d.vd_req_addr_i=va;s.d.vd_req_store_i=0;s.d.vd_req_valid_i=1;bool accepted=false;
    for(unsigned i=0;i<limit;i++){auto x=s.step();if(x.vd_req_fire){accepted=true;s.d.vd_req_valid_i=0;break;}}
    check(accepted,"load request not accepted");
    for(unsigned i=0;i<limit;i++){auto x=s.step();if(x.vd_rsp_valid)return{x.vd_rsp_error,x.vd_rsp_page,x.vd_data};}
    throw std::runtime_error("load response timeout");
}
static Result store(Sim &s, uint64_t va, unsigned limit=100) {
    s.d.vd_req_addr_i=va;s.d.vd_req_store_i=1;s.d.vd_req_store_data_i=0x55aa;
    s.d.vd_req_valid_i=1;bool saw_ptw=false;
    for(unsigned i=0;i<limit;i++){
        auto x=s.step();saw_ptw|=x.pd_req_fire&&x.pd_ptw;
        if(x.vd_req_fire){s.d.vd_req_valid_i=0;return{x.vd_req_error,x.vd_req_page,0,saw_ptw&&s.physical_stores==0&&!x.vd_req_error};}
    }
    throw std::runtime_error("store completion timeout");
}

int main(int argc,char **argv){
    Verilated::commandArgs(argc,argv); unsigned scenarios=0;
    constexpr uint64_t VA=0x0000000041234567ULL;
    constexpr uint64_t VAP=VA&~0xfffULL;
    constexpr uint64_t VRWXAD=0xcf, VRAD=0xc3, VXAD=0xc9, VRWXUAD=0xdf;
    try {
        Sim s;
        { s.reset();s.d.priv_mode_i=1;s.insn[VA]={0x13,false};auto r=instruction(s,VA);
          check(!r.error&&r.value==0x13&&s.last_final_pa==VA&&s.ptw_requests==0,"Bare instruction equivalence");++scenarios; }
        { s.reset();s.d.priv_mode_i=1;s.data[VA]={0x1122,false};auto r=load(s,VA);
          check(!r.error&&r.value==0x1122&&s.last_final_pa==VA&&s.ptw_requests==0,"Bare load equivalence");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));s.insn[(0x20000ULL<<12)|(VA&0xfff)]={0x93,false};
          auto r=instruction(s,VA);check(!r.error&&r.value==0x93&&s.ptw_requests==3,"4K instruction walk");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20001,VRWXAD));uint64_t pa=(0x20001ULL<<12)|(VA&0xfff);s.data[pa]={0xa5a5,false};
          auto r=load(s,VA);check(!r.error&&r.value==0xa5a5&&s.ptw_requests==3&&s.last_final_pa==pa,"4K load walk");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20002,VRWXAD));uint64_t pa=(0x20002ULL<<12)|(VA&0xfff);
          auto r=store(s,VA);check(!r.error&&!r.early_store_ready&&s.physical_stores==1&&s.last_final_pa==pa,"4K store retirement boundary");++scenarios; }
        { s.reset();uint64_t ppn=0x24000;s.d.satp_i=satp(install(s,VA,1,ppn,VRWXAD));uint64_t pa=(ppn<<12)|(VA&0x1fffff);s.insn[pa]={0x13,false};
          auto r=instruction(s,VA);check(!r.error&&s.ptw_requests==2&&s.last_final_pa==pa,"2M superpage composition");++scenarios; }
        { s.reset();uint64_t ppn=0x40000;s.d.satp_i=satp(install(s,VA,2,ppn,VRWXAD));uint64_t pa=(ppn<<12)|(VA&0x3fffffff);s.data[pa]={7,false};
          auto r=load(s,VA);check(!r.error&&r.value==7&&s.ptw_requests==1&&s.last_final_pa==pa,"1G superpage composition");++scenarios; }
        for(unsigned level: {1u,2u}) { s.reset();uint64_t bad=level==1?0x24001:0x40001;s.d.satp_i=satp(install(s,VA,level,bad,VRWXAD));auto r=load(s,VA);
          check(r.error&&r.page&&s.final_data_requests==0,"misaligned superpage must page fault");++scenarios; }
        { s.reset();s.d.satp_i=satp(0x100);auto r=instruction(s,0x0000008000000000ULL);check(r.error&&r.page&&s.ptw_requests==0,"noncanonical instruction VA");++scenarios; }
        { s.reset();s.d.satp_i=satp(0x100);auto r=load(s,0x0000008000000000ULL);check(r.error&&r.page&&s.ptw_requests==0,"noncanonical load VA");++scenarios; }
        { s.reset();s.d.satp_i=satp(0x100);auto r=store(s,0x0000008000000000ULL);check(r.error&&r.page&&s.physical_stores==0,"noncanonical store suppression");++scenarios; }
        const uint64_t bad_ptes[] = {uint64_t(0),pte(0x20000,5),pte(0x20000,VRWXAD)|(uint64_t(1)<<54)};
        for(uint64_t raw: bad_ptes) {
          s.reset();s.d.satp_i=satp(0x100);s.pte[pte_addr(0x100,vpn(VA,2))]={raw,false};auto r=load(s,VA);
          check(r.error&&r.page&&s.final_data_requests==0,"invalid leaf PTE");++scenarios; }
        { s.reset();s.d.satp_i=satp(0x100);s.pte[pte_addr(0x100,vpn(VA,2))]={pte(0x101,0x11),false};auto r=load(s,VA);
          check(r.error&&r.page,"reserved nonleaf U bit");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRAD));auto r=instruction(s,VA);check(r.error&&r.page,"execute permission");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VXAD));auto r=load(s,VA);check(r.error&&r.page,"load permission");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRAD));auto r=store(s,VA);check(r.error&&r.page&&s.physical_stores==0,"store permission and side effects");++scenarios; }
        { s.reset();s.d.priv_mode_i=0;s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));auto r=load(s,VA);check(r.error&&r.page,"U access to supervisor page");++scenarios; }
        { s.reset();s.d.priv_mode_i=0;s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXUAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={9,false};auto r=load(s,VA);check(!r.error&&r.value==9,"U access to user page");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXUAD));auto r=load(s,VA);check(r.error&&r.page,"S SUM zero");++scenarios; }
        { s.reset();s.d.mstatus_i=1ULL<<18;s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXUAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={10,false};auto r=load(s,VA);check(!r.error&&r.value==10,"S SUM data enable");++scenarios; }
        { s.reset();s.d.mstatus_i=1ULL<<18;s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXUAD));auto r=instruction(s,VA);check(r.error&&r.page,"SUM never enables S fetch from U page");++scenarios; }
        { s.reset();s.d.mstatus_i=1ULL<<19;s.d.satp_i=satp(install(s,VA,0,0x20000,VXAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={11,false};auto r=load(s,VA);check(!r.error&&r.value==11,"MXR execute-only load");++scenarios; }
        { s.reset();s.d.priv_mode_i=3;s.d.mstatus_i=(1ULL<<17)|(1ULL<<11);s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={12,false};auto r=load(s,VA);check(!r.error&&s.ptw_requests==3,"MPRV/MPP S data translation");++scenarios; }
        { s.reset();s.d.priv_mode_i=3;s.d.satp_i=satp(0x100);s.insn[VA]={0x13,false};auto r=instruction(s,VA);check(!r.error&&s.ptw_requests==0&&s.last_final_pa==VA,"M fetch bypass");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD&~0x40ULL));auto r=load(s,VA);check(r.error&&r.page,"Svade A zero");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD&~0x80ULL));auto r=store(s,VA);check(r.error&&r.page&&s.physical_stores==0,"Svade store D zero");++scenarios; }
        { s.reset();s.d.satp_i=satp(0x100);s.pte[pte_addr(0x100,vpn(VA,2))]={0,true};auto r=load(s,VA);check(r.error&&!r.page,"PTW physical access fault taxonomy");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.insn[pa]={0,true};auto r=instruction(s,VA);check(r.error&&!r.page,"final instruction access fault taxonomy");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={0,true};auto r=load(s,VA);check(r.error&&!r.page,"final load access fault taxonomy");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));s.final_store_error=true;auto r=store(s,VA);check(r.error&&!r.page&&s.physical_stores==0,"final store access fault taxonomy/side effect");++scenarios; }
        { s.reset();constexpr uint64_t ROOT=(1ULL<<44)-1;s.d.satp_i=satp(ROOT);s.pte[pte_addr(ROOT,vpn(VA,2))]={pte(0x40000,VRWXAD),false};uint64_t pa=(0x40000ULL<<12)|(VA&0x3fffffff);s.insn[pa]={0x13,false};auto r=instruction(s,VA);
          check(!r.error&&s.last_ptw_pa==pte_addr(ROOT,vpn(VA,2))&&s.last_ptw_pa<=(1ULL<<56)-1,"maximum root PPN arithmetic");++scenarios; }
        { s.reset();constexpr uint64_t PPN=(1ULL<<44)-0x40000;s.d.satp_i=satp(install(s,VA,2,PPN,VRWXAD));uint64_t pa=(PPN<<12)|(VA&0x3fffffff);s.insn[pa]={0x13,false};auto r=instruction(s,VA);check(!r.error&&s.last_final_pa==pa&&pa>>56==0,"high PPN superpage composition");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));s.pd_ready=false;s.d.vd_req_addr_i=VA;s.d.vd_req_valid_i=1;auto x=s.step();check(x.vd_req_fire,"translated load allocation");s.d.vd_req_valid_i=0;for(int i=0;i<3;i++){x=s.step();check(!x.pd_req_fire,"PTW request backpressure");}s.pd_ready=true;uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={13,false};for(int i=0;i<100;i++){x=s.step();if(x.vd_rsp_valid)break;}check(x.vd_rsp_valid&&!x.vd_rsp_error,"PTW request backpressure completion");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.insn[pa]={0x13,false};s.d.vi_rsp_ready_i=0;s.d.vi_req_addr_i=VA;s.d.vi_req_valid_i=1;bool accepted=false;for(int i=0;i<10&&!accepted;i++){auto x=s.step();accepted=x.vi_req_fire;}s.d.vi_req_valid_i=0;Snap a{};for(int i=0;i<100;i++){a=s.step();if(a.vi_rsp_valid)break;}check(a.vi_rsp_valid&&a.vi_insn==0x13,"response backpressure arrival");for(int i=0;i<3;i++){auto b=s.step();check(b.vi_rsp_valid&&b.vi_insn==0x13,"response must remain valid/stable");}s.d.vi_rsp_ready_i=1;s.step();++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));s.pd_ready=false;s.d.vi_req_addr_i=VA;s.d.vi_req_valid_i=1;while(!s.step().vi_req_fire){}s.d.vi_req_valid_i=0;while(!s.d.pd_req_valid_o)s.step();s.d.redirect_i=1;s.pd_ready=true;Snap x=s.step();check(x.pd_req_fire&&x.pd_ptw,"redirect/PTW request exact-cycle acceptance");s.d.redirect_i=0;bool cancel=false;for(int i=0;i<20;i++){x=s.step();if(x.vi_rsp_valid){cancel=true;break;}}check(cancel&&s.final_i_requests==0,"redirect on accepted PTW request");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));s.d.vi_req_addr_i=VA;s.d.vi_req_valid_i=1;while(!s.step().vi_req_fire){}s.d.vi_req_valid_i=0;Snap x{};do{x=s.step();}while(!(x.pd_req_fire&&x.pd_ptw));s.d.redirect_i=1;x=s.step();s.d.redirect_i=0;bool cancel=false;for(int i=0;i<20;i++){x=s.step();if(x.vi_rsp_valid){cancel=true;break;}}check(cancel&&s.final_i_requests==0,"redirect on PTW response cycle");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,2,0x40000,VRWXAD));uint64_t pa=(0x40000ULL<<12)|(VA&0x3fffffff);s.insn[pa]={0x13,false};s.d.vi_req_addr_i=VA;s.d.vi_req_valid_i=1;while(!s.step().vi_req_fire){}s.d.vi_req_valid_i=0;Snap x{};do{x=s.step();}while(!x.pi_req_fire);s.d.redirect_i=1;x=s.step();s.d.redirect_i=0;check(x.vi_rsp_valid,"redirect/final response exact-cycle visibility");s.d.satp_i=0;s.insn[VA]={0x93,false};auto r=instruction(s,VA);check(!r.error&&r.value==0x93,"redirect final-response ownership release");++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));uint64_t pa=(0x20000ULL<<12)|(VA&0xfff);s.data[pa]={0x7788,false};s.d.vd_rsp_ready_i=0;s.d.vd_req_addr_i=VA;s.d.vd_req_valid_i=1;while(!s.step().vd_req_fire){}s.d.vd_req_valid_i=0;Snap x{};for(int i=0;i<100;i++){x=s.step();if(x.vd_rsp_valid)break;}check(x.vd_rsp_valid&&x.vd_data==0x7788,"load response backpressure arrival");for(int i=0;i<3;i++){x=s.step();check(x.vd_rsp_valid&&x.vd_data==0x7788,"load response must remain valid/stable");}s.d.vd_rsp_ready_i=1;s.step();++scenarios; }
        { s.reset();s.d.satp_i=satp(install(s,VA,0,0x20000,VRWXAD));s.d.vi_req_addr_i=VA;s.d.vi_req_valid_i=1;while(!s.step().vi_req_fire){}s.d.vi_req_valid_i=0;Snap x{};do{x=s.step();}while(!(x.pd_req_fire&&x.pd_ptw));s.d.rst_i=1;s.pd_pending=false;s.step();s.d.rst_i=0;s.d.satp_i=0;s.insn[VA]={0x93,false};auto r=instruction(s,VA);check(!r.error&&r.value==0x93&&s.d.idle_o,"reset cancels ownership with producer response invalidation");++scenarios; }

        // P1 #1: Stalled final translated store + reset + RAM becomes ready
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20002, VRWXAD));
            uint64_t pa = (0x20002ULL << 12) | (VA & 0xfff);
            s.data[pa] = {0xdeadbeefcafebabeULL, false};
            s.d.vd_req_addr_i = VA;
            s.d.vd_req_store_i = 1;
            s.d.vd_req_store_data_i = 0x55aa;
            s.d.vd_req_valid_i = 1;
            bool in_final_d = false;
            for (int i = 0; i < 50; i++) {
                if (s.ptw_requests == 3 && !s.pd_pending) {
                    s.pd_ready = false;
                }
                s.step();
                if (s.d.pd_req_valid_o && s.d.pd_req_store_o) {
                    in_final_d = true;
                    break;
                }
            }
            check(in_final_d, "store stalled in FINAL_D_REQ");

            s.d.rst_i = 1;
            s.d.vd_req_valid_i = 0;
            s.pd_ready = true;
            Snap x = s.step();
            check(!x.pd_req_fire, "no physical store handshake while reset is asserted");
            check(!s.d.pd_req_valid_o, "physical request valid must be deasserted during reset");
            check(s.data[pa].data == 0xdeadbeefcafebabeULL, "RAM image must remain unchanged after reset-aborted store");
            check(s.physical_stores == 0, "physical stores counter must be zero");

            s.d.rst_i = 0;
            s.step();
            check(s.d.idle_o, "MMU returns to IDLE after reset");
            s.d.satp_i = 0;
            s.data[VA] = {0x42, false};
            auto r = load(s, VA);
            check(!r.error && r.value == 0x42, "post-reset Bare load completed cleanly");
            ++scenarios;
        }

        // P1 #1: Stalled PTW request + reset + RAM becomes ready
        {
            s.reset();
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            s.pd_ready = false;
            s.d.vi_req_addr_i = VA;
            s.d.vi_req_valid_i = 1;
            bool in_ptw_req = false;
            for (int i = 0; i < 20; i++) {
                auto x = s.step();
                if (x.vi_req_fire) s.d.vi_req_valid_i = 0;
                if (s.d.pd_req_valid_o && s.d.pd_req_ptw_o) {
                    in_ptw_req = true;
                    break;
                }
            }
            check(in_ptw_req, "PTW request stalled in PTW_REQ");

            s.d.rst_i = 1;
            s.pd_ready = true;
            Snap x = s.step();
            check(!x.pd_req_fire, "no PTW request handshake while reset is asserted");
            check(!s.d.pd_req_valid_o, "pd_req_valid_o deasserted during reset");
            check(s.ptw_requests == 0, "no PTW request counted during reset");

            s.d.rst_i = 0;
            s.step();
            check(s.d.idle_o, "MMU returns to IDLE after reset");
            s.d.satp_i = 0;
            s.insn[VA] = {0x13, false};
            auto r = instruction(s, VA);
            check(!r.error && r.value == 0x13, "post-reset Bare fetch completed cleanly");
            ++scenarios;
        }

        // P1 #1: Stalled final instruction request + reset + I-mem becomes ready
        {
            s.reset();
            uint64_t pa = (0x20000ULL << 12) | (VA & 0xfff);
            s.d.satp_i = satp(install(s, VA, 0, 0x20000, VRWXAD));
            s.insn[pa] = {0x13, false};
            s.d.vi_req_addr_i = VA;
            s.d.vi_req_valid_i = 1;
            bool in_final_i = false;
            for (int i = 0; i < 50; i++) {
                if (s.ptw_requests == 3 && !s.pd_pending) {
                    s.pi_ready = false;
                }
                auto x = s.step();
                if (x.vi_req_fire) s.d.vi_req_valid_i = 0;
                if (s.d.pi_req_valid_o) {
                    in_final_i = true;
                    break;
                }
            }
            check(in_final_i, "instruction request stalled in FINAL_I_REQ");

            s.d.rst_i = 1;
            s.pi_ready = true;
            Snap x = s.step();
            check(!x.pi_req_fire, "no physical instruction handshake while reset is asserted");
            check(!s.d.pi_req_valid_o, "pi_req_valid_o deasserted during reset");
            check(s.final_i_requests == 0, "no final instruction request counted during reset");

            s.d.rst_i = 0;
            s.step();
            check(s.d.idle_o, "MMU returns to IDLE after reset");
            s.d.satp_i = 0;
            s.insn[VA] = {0x13, false};
            auto r = instruction(s, VA);
            check(!r.error && r.value == 0x13, "post-reset Bare fetch completed cleanly");
            ++scenarios;
        }

        // P1 #1: Stalled final load request + reset + RAM becomes ready
        {
            s.reset();
            uint64_t pa = (0x20001ULL << 12) | (VA & 0xfff);
            s.d.satp_i = satp(install(s, VA, 0, 0x20001, VRWXAD));
            s.data[pa] = {0x9999, false};
            s.d.vd_req_addr_i = VA;
            s.d.vd_req_store_i = 0;
            s.d.vd_req_valid_i = 1;
            bool in_final_d = false;
            for (int i = 0; i < 50; i++) {
                if (s.ptw_requests == 3 && !s.pd_pending) {
                    s.pd_ready = false;
                }
                auto x = s.step();
                if (x.vd_req_fire) s.d.vd_req_valid_i = 0;
                if (s.d.pd_req_valid_o && !s.d.pd_req_store_o && !s.d.pd_req_ptw_o) {
                    in_final_d = true;
                    break;
                }
            }
            check(in_final_d, "load request stalled in FINAL_D_REQ");

            s.d.rst_i = 1;
            s.pd_ready = true;
            Snap x = s.step();
            check(!x.pd_req_fire, "no physical load handshake while reset is asserted");
            check(!s.d.pd_req_valid_o, "pd_req_valid_o deasserted during reset");
            check(s.final_data_requests == 0, "no final load request counted during reset");

            s.d.rst_i = 0;
            s.step();
            check(s.d.idle_o, "MMU returns to IDLE after reset");
            s.d.satp_i = 0;
            s.data[VA] = {0x1234, false};
            auto r = load(s, VA);
            check(!r.error && r.value == 0x1234, "post-reset Bare load completed cleanly");
            ++scenarios;
        }

        // P1 #2: Held-response redirect lifecycle (exact 7 steps)
        {
            s.reset();
            uint64_t va_old = VA;
            uint64_t pa_old = (0x20000ULL << 12) | (va_old & 0xfff);
            s.d.satp_i = satp(install(s, va_old, 0, 0x20000, VRWXAD));
            s.insn[pa_old] = {0x1111, false};

            // 1. Translated instruction physical response becomes valid
            s.d.vi_req_addr_i = va_old;
            s.d.vi_req_valid_i = 1;
            bool accepted = false, req_fired = false;
            for (int i = 0; i < 50; i++) {
                auto x = s.step();
                if (x.vi_req_fire) { accepted = true; s.d.vi_req_valid_i = 0; }
                if (x.pi_req_fire) { req_fired = true; break; }
            }
            check(accepted && req_fired, "physical instruction request fired");

            // 2. Virtual/fetch consumer ready is low
            s.d.vi_rsp_ready_i = 0;
            s.step(); // MMU enters FINAL_I_RSP with pi_rsp_valid_i=1, vi_rsp_ready_i=0
            check(s.d.pi_rsp_valid_i, "1. physical response valid");
            check(!s.d.pi_rsp_ready_o, "2. physical ready low because consumer ready is low");

            // 3. Physical response remains held
            for (int i = 0; i < 3; i++) {
                s.step();
                check(s.d.pi_rsp_valid_i, "3. physical response remains held");
                check(!s.d.pi_rsp_ready_o, "3. physical ready remains low");
                check(s.pi_pending, "3. physical response pending in memory model");
            }

            // 4. Redirect occurs
            s.d.redirect_i = 1;
            s.step();
            s.d.redirect_i = 0;
            check(!s.d.idle_o, "4. MMU retains ownership in drain state and not IDLE");
            check(s.d.pi_rsp_ready_o, "4. MMU asserts pi_rsp_ready_o to drain response");

            // 5. Old response is drained with a real handshake
            s.step();
            check(!s.pi_pending, "5. old response drained with real handshake in memory model");
            check(s.d.idle_o, "5. MMU returns to IDLE after draining old response");

            // 6. A new fetch begins
            uint64_t va_new = 0x0000000045678000ULL;
            uint64_t pa_new = (0x20001ULL << 12) | (va_new & 0xfff);
            install(s, va_new, 0, 0x20001, VRWXAD);
            s.insn[pa_new] = {0x2222, false};
            s.d.vi_rsp_ready_i = 1;
            auto r = instruction(s, va_new);

            // 7. Prove the old response cannot complete/corrupt the new fetch
            check(!r.error && r.value == 0x2222 && s.last_final_pa == pa_new,
                  "7. new fetch returned its own instruction and was not corrupted by old response");
            ++scenarios;
        }

        // P1 #2: Same-cycle redirect when physical response first appears with consumer ready low
        {
            s.reset();
            uint64_t va_old = VA;
            uint64_t pa_old = (0x20000ULL << 12) | (va_old & 0xfff);
            s.d.satp_i = satp(install(s, va_old, 0, 0x20000, VRWXAD));
            s.insn[pa_old] = {0x3333, false};

            s.d.vi_req_addr_i = va_old;
            s.d.vi_req_valid_i = 1;
            bool accepted = false, req_fired = false;
            for (int i = 0; i < 50; i++) {
                auto x = s.step();
                if (x.vi_req_fire) { accepted = true; s.d.vi_req_valid_i = 0; }
                if (x.pi_req_fire) { req_fired = true; break; }
            }
            check(accepted && req_fired, "physical request fired");

            s.d.vi_rsp_ready_i = 0;
            s.d.redirect_i = 1;
            s.step();
            s.d.redirect_i = 0;
            check(!s.d.idle_o, "MMU enters drain state");
            check(s.d.pi_rsp_ready_o, "MMU asserts pi_rsp_ready_o in drain state");

            s.step();
            check(!s.pi_pending, "old response drained with real handshake");
            check(s.d.idle_o, "MMU returns to IDLE after drain");

            uint64_t va_new = 0x0000000045678000ULL;
            uint64_t pa_new = (0x20001ULL << 12) | (va_new & 0xfff);
            install(s, va_new, 0, 0x20001, VRWXAD);
            s.insn[pa_new] = {0x4444, false};
            s.d.vi_rsp_ready_i = 1;
            auto r = instruction(s, va_new);
            check(!r.error && r.value == 0x4444 && s.last_final_pa == pa_new,
                  "new fetch completed cleanly after same-cycle redirect/response drain");
            ++scenarios;
        }

        // Small hardening: noncanonical VA boundaries
        const uint64_t noncanonical_vas[] = {
            0x0000004000000000ULL, // bit 38=1, bits 63:39=0
            0x0000008000000000ULL, // bit 38=0, bit 39=1
            0xffffffbfffffffffULL  // bit 38=0, bits 63:39=1
        };
        for (uint64_t nc_va : noncanonical_vas) {
            s.reset(); s.d.satp_i = satp(0x100);
            auto ri = instruction(s, nc_va);
            check(ri.error && ri.page && s.ptw_requests == 0, "noncanonical boundary instruction page fault");
            auto rl = load(s, nc_va);
            check(rl.error && rl.page && s.ptw_requests == 0, "noncanonical boundary load page fault");
            auto rs = store(s, nc_va);
            check(rs.error && rs.page && s.physical_stores == 0, "noncanonical boundary store suppression");
            ++scenarios;
        }

        // Small hardening: walk level 1 malformed PTE and access error
        {
            s.reset(); s.d.satp_i = satp(0x100);
            s.pte[pte_addr(0x100, vpn(VA, 2))] = {pte(0x101, 1), false};
            s.pte[pte_addr(0x101, vpn(VA, 1))] = {pte(0x102, 0x11), false};
            auto r = load(s, VA);
            check(r.error && r.page && s.ptw_requests == 2, "level 1 nonleaf reserved bits page fault");
            ++scenarios;
        }
        {
            s.reset(); s.d.satp_i = satp(0x100);
            s.pte[pte_addr(0x100, vpn(VA, 2))] = {pte(0x101, 1), false};
            s.pte[pte_addr(0x101, vpn(VA, 1))] = {pte(0x20000, 5), false};
            auto r = load(s, VA);
            check(r.error && r.page && s.ptw_requests == 2, "level 1 reserved W=1 R=0 page fault");
            ++scenarios;
        }
        {
            s.reset(); s.d.satp_i = satp(0x100);
            s.pte[pte_addr(0x100, vpn(VA, 2))] = {pte(0x101, 1), false};
            s.pte[pte_addr(0x101, vpn(VA, 1))] = {0, true};
            auto r = load(s, VA);
            check(r.error && !r.page && s.ptw_requests == 2, "level 1 PTW access fault taxonomy");
            ++scenarios;
        }

        std::cout<<"{\"status\":\"pass\",\"scenarios\":"<<scenarios<<"}\n";return 0;
    } catch(const std::exception &e) { std::cerr<<"SV39_MMU_S0_MISMATCH scenario="<<scenarios+1<<" reason="<<e.what()<<"\n";return 1; }
}
