# Slice-0 mimari sözleşmesi

Durum: taslak 0.1. Bu, ilk bare-metal test platformunun sözleşmesidir;
nihai sunucu SoC reset davranışı veya RVA23 uyumluluk beyanı değildir.

## Başlangıç durumu

| Alan | Slice-0 değeri | Açıklama |
|---|---|---|
| Hart | 0 | Tek hart |
| PC | `0x8000_0000` | `_start` adresi |
| Ayrıcalık | M-mode | S/U/H kapalıdır |
| `mstatus` | MIE=0, MPIE=0, MPP=3 | Reset M-mode'a gelir; MXL ve diğer bitler sonraki alt tabloda |
| `mie` | `0x0` | Kesme kaynakları kapalı |
| `mtvec` | `0x0` | Başlangıç kodu ilk iş olarak yazar |
| `mepc`, `mcause`, `mtval` | `0x0` | İlk trap öncesi platform başlangıç değeri |
| RAM | `0x8000_0000`–`0x8001_ffff` | Test haritasına göre okunur/yazılır/yürütülür |
| Kesme | Yok | Test boyunca dış/yazılım/timer kesmesi enjekte edilmez |

`mhartid=0` kabul edilir. Kimlik CSR'ları (`mvendorid`, `marchid`, `mimpid`) bu
dilimde test edilmez ve ürün değerleri seçilmemiştir. `misa` ve PMP tanımı da
sonraki alt dilimdedir. Uygulanmamış standard CSR veya opcode, illegal-instruction
trap üretmelidir; bu davranış nihai profilde de önerilir.

## Kullanılan komutlar ve kesin davranış

| Grup | Kodlama ailesi | Slice-0 kuralı | İlk test |
|---|---|---|---|
| Integer | LUI, AUIPC, ADDI, ADD, SUB, BGEU, BNE, JAL, JALR | XLEN=64; sonuç mod 2^64; branch alınırsa hedef PC, alınmazsa PC+4 | ALU/branch sınırları, `ra` ve PC izleri |
| Load/store | LD, SD | 8 bayt hizalı RAM erişimi; `LD` 64 bit yükler, `SD` 64 bit yazar | BSS sıfırlama, dizi okuma/yazma |
| CSR | CSRRW, CSRRS, CSRRC, CSRWI/CSRRSI/CSRRCI | `rd=x0` okuma yan etkisini, `rs1=x0` veya `zimm=0` yazma yan etkisini bastırır | Her bastırma kombinasyonu ve izin reddi |
| System | ECALL, MRET | M-mode ECALL: `mcause=11`, `mepc=faulting PC`, `mtval=0`; `MRET` önceki MIE/MPIE/MPP sözleşmesine göre döner | Tek ECALL → handler → `mepc+4` → MRET |
| Fences | FENCE, FENCE.I | Slice-0 tek hart RAM'de FENCE mimari durum değiştirmez; FENCE.I önceki kod yazımının sonraki fetch'e görünmesini sağlar | self-modifying code testi |
| Hata | Illegal opcode / uygunsuz CSR | `mcause=2`; `mepc=faulting PC`; `mtval=faulting instruction`; daha genç hiçbir mimari yazma görünmez | Bilinen illegal 32-bit kodlama |

M-only `mret`, `MIE←MPIE`, `MPIE←1` uygular ve desteklenen tek WARL değer olduğu
için `MPP=M` bırakır. Bu sözleşme S/U dönüşü içermez; daha düşük privilege mode
eklenirse ayrı bir mimari kilometre taşında genişletilecektir.

## Trap önceliği ve görünürlük

Bir komut erişim hatası üretirse hedef register, store, CSR yazımı veya PC'nin
normal sonraki değeri görünür olmaz. Trap handler'a girerken `mepc` hatalı komutun
adresidir. Slice-0'da eşzamanlı kesme yoktur; exception ve kesme öncelik tablosu
sonraki platform sözleşmesinin işidir. RTL, mimari commit sırasıyla iz üretecek;
doğrulayıcı bunu Spike referansıyla karşılaştıracaktır.

## Test bağları

| Kimlik | Önkoşul | Beklenen sonuç | Kanıt durumu |
|---|---|---|---|
| S0-BOOT | reset durumu | `_start` M-mode'da doğru PC ve CSR başlangıcıyla görülür | Spike'da geçti; DUT planned |
| S0-ECALL | `mtvec=trap_handler` | `mcause=11`, `mepc=ecall_probe`, `mtval=0`, handler sayacı=1 | Spike geçti; DUT planned |
| S0-MEM | BSS ve RAM | 100 kelime sıfırdan 1…100'e, toplam 5050 | Spike geçti; DUT planned |
| S0-CSR | M-mode | CSR okuma/yazma bastırma ve illegal CSR davranışı | cycle'a yazma ve mscratch bastırma Spike'da geçti; DUT planned |
| S0-ILL | illegal 32-bit komut | cause=2, doğru `mepc`/`mtval`, görünür genç yazma yok | Spike'da geçti; DUT planned |
| S0-FI | RAM'de kod değişimi | FENCE.I sonrası yeni komut fetch edilir | Spike passed; DUT planned |

Spike sonucu, self-modifying-code sırasının mimari `FENCE.I` davranışını
doğrular. Fursoy'un gelecekteki I-cache invalidation uygulamasını kanıtlamaz;
bu, I-cache'li DUT üzerinde ayrıca doğrulanacaktır.

Kaynaklar: [RISC-V unprivileged ISA](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html),
[privileged ISA](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html).
Spike varsayımları test aracı içindir: `--isa=RV64I_Zicsr_Zifencei --priv=m`,
tek 128 KiB RAM bölgesi. Spike, Fursoy davranışının kanıtı değildir.
