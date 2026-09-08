# ISA/platform sözleşmesi — taslak 0.2

Tarih: 6 Eylül 2026. W02 özelliğe göre ilk izlenebilir gereksinim dökümü.
Bu belge bir uyumluluk veya uygulanmış özellik beyanı değildir.

Ürün yönü: tek soketli 4→8 çekirdek Linux sunucusu. [ADR-001](../decisions/001-server-target.md)
ECC/RAS, DMA izolasyonu ve sürekli yük hedeflerini tanımlar. Bunlar ISA profilinden
ayrı proje gereksinimleridir; SRV-001…005 satırlarında izlenir.

## Hedef ve kaynak önceliği

Çalışma ISA'sı RISC-V; nihai hedef RVA23U64 + RVA23S64 v1.0 (2024-10-17).
Profilin kullanıcı, supervisor ve Sha bileşenleri makinece okunabilir envanterde
listelenmiştir. Profil için normatif kaynak [RVA23 v1.0](https://docs.riscv.org/reference/rva23/v1.0/_attachments/rva23-profile.pdf),
özellikle basılı sayfa 4–9'dur. Teknik adlar değiştirilmeden tutulur.

Komut/CSR ayrıntılarında [ISA Volume I](https://docs.riscv.org/reference/isa/v20260120/unpriv/unpriv-index.html)
ve [Volume II](https://docs.riscv.org/reference/isa/v20260120/priv/priv-index.html)
20260120 koleksiyonu referanstır. Koleksiyon tarihi uzantı sürümü değildir.
RVA23'ün Ss1p13 tabanı korunur; daha yeni bir koleksiyondaki ek özellikler otomatik
olarak zorunlu sayılmaz. Her komut/CSR alt belirtimi yazılırken ilgili uzantı
sürümü ayrıca sabitlenecek; uyuşmazlık varsa karar kaydı açılacaktır.

## Karar verilen ilk doğrulama dilimi

`slice-0`: RV64I + Zicsr + Zifencei için bare-metal test ortamı; little-endian,
XLEN=64, tek hart, M-mode, çevirisiz test RAM'i. Hedef derleme seçenekleri
`-march=rv64i_zicsr_zifencei -mabi=lp64`; başlangıçta libc gerekmez.
Bu bayraklarla ilk ELF derlendi ve yerleşimi kontrol edildi; program henüz
referansta yürütülmedi. [Test haritası](../architecture/baremetal-v1.md) sürüm 1'dir.
Program bitişi timeout ile başarı
sayılmayacak; açık sonuç imzası ve beklenen trap bilgisi kontrol edilecek.

Bu dilim Linux veya RVA23 uyumlu ürün değildir. İlk test ortamı, sonraki OoO
çekirdeğin de kullanacağı mimari sonuç/commit kontrolünü geliştirmek içindir.
Geçici in-order CPU veya daraltılmış nihai ISA kararı alınmadı.

İlk detaylandırma sırası: integer register/PC ve RV64I komutları; illegal opcode
ve ECALL/EBREAK; CSR erişim izinleri ve trap/return; RAM/fence; sonra M/A/C ve
supervisor bellek yönetimi. Her grup RTL'den önce opcode/CSR alt maddelerine ayrılır.

## Nihai platform kararları

| Başlık | Çalışma kararı | Açık ayrıntı |
|---|---|---|
| Modlar | M, S, U; nihai H/HS/VS/VU desteği | CSR WARL ve delegation tabloları |
| Adresleme | Svbare/Sv39 zorunlu hedef; Sv48 değerlendirme adayı | Fiziksel adres genişliği, ASID/VMID bitleri |
| Bellek sıralaması | RVWMO ve atomik ilerleme gereksinimleri | Litmus çalıştırıcı, çok hart model |
| Veri düzeni | Little-endian, XLEN=64 | Bellek haritası ve reset adresi |
| Vektör | VLEN=256 aday, fiziksel lane genişliği ayrı | ELEN/SEW, fiziksel RF ve test araç uyumu |
| RAM/MMIO | Ayrı PMA/izin politikası | RAM aralıkları, cihaz erişim genişlikleri |
| Kesmeler | Yazılım/timer/external yolları, nihai Sstc | AIA/denetleyici tercihi, adres haritası |
| Koruma | PMP ve çeviri izin kontrolleri | PMP giriş sayısı/granülü/lock davranışı |
| Boot/debug | Boot ROM, SBI yolu, debug erişimi | SBI/debug sürümü ve test platformu |
| İsteğe bağlı uzantılar | Hiçbiri henüz ürün taahhüdü değil | Sv48/Svadu/crypto/BF16 vb. ayrı karar |

Sv48 seçilirse guest çeviri desteğinin buna etkisi de ele alınır. Misaligned
erişim desteği, her erişimin atomik olduğu anlamına gelmez. Veri bağımsız gecikme
kuralları da bütün komutların sabit süreli olduğu varsayımına dönüştürülmez.
Zkt/Zvkt kapsamı komut düzeyinde çıkarılmadan yürütme gecikmeleri onaylanmaz.

## İzlenebilirlik ve durumlar

`isa-platform.csv` sütunları: sabit gereksinim kimliği, kapsanan özellik adları,
kaynak, hedef kapı, sorumlu tasarım bölümü ve planlanan doğrulama yöntemi.
CSV özellik grupları düzeyindedir; tüm opcode/CSR/PMA alt kurallarının tamamlanmış
listesi değildir. `rva23-inventory.json` profilin doğrudan zorunlu adlarını ve Sha
alt bileşenlerini ayrı tutar. Bağımlı uzantıların tüm geçişli açılımı henüz yoktur.

Tüm satırlar `planned`; hiçbir ISA/platform satırının yürütülmüş test kanıtı yok.
`verification` bir test planıdır, test sonucu değildir. `evidence` bu nedenle boş.
Durumlar: planned → implemented → verified. Verified için kanıt zorunludur;
kanıt dosyasının varlığı tek başına teknik yeterlilik onayı vermez.

Kontrol komutu:

```bash
python3 tools/check_requirements.py
python3 -m unittest discover -s verification -v
```

Kontrol, envanterdeki adların tabloda unutulmasını, tekrarlanan ID'yi, kaynak/hedef
hatalarını ve kanıtsız verified durumunu reddeder. Envanterin resmî kaynağa göre
doğruluğu manuel incelemedir; kendi JSON listemizi kontrol etmek sertifikasyon değildir.

## W02 kapanışı için açık işler

1. İlk dilimin opcode ve CSR erişim/trap tabloları, WARL davranışı ve reset değerleri.
2. B/A/C/V ve profil tanımlı adların bağımlılık/sürüm açılımı; referans araç kapsamı.
3. Bellek haritası, reset vektörü ve test bitiş/commit kayıt sözleşmesi.
4. Optional özellik kararları ve kesme/debug/SBI platform belirtim sürümleri.

Bu teslimat W02'nin ilk alt adımıdır; W02 veya G0 bütünüyle kapanmış sayılmaz.
