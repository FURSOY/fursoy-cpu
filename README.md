# Fursoy CPU

Tek soketli, 4→8 çekirdekli Linux sunucusunu hedefleyen özgün CPU projesi.
Mimari hedefler ve geçiş koşulları: [ana plan](CPU_MASTER_PLAN.md).
Sunucu kararı ve ECC/RAS öncelikleri: [ADR-001](docs/decisions/001-server-target.md).

## Mevcut durum

Proje, çalışan ve doğrulanmış sıralı **Slice-0** çekirdeği aşamasındadır:

- **Çekirdek mimarisi:** RV64I tamsayı komut kümesi, Zicsr ve FENCE.I desteği sunan in-order `fursoy_s0_core`.
- **Ayrıcalık ve CSR:** İncelenmiş ve dondurulmuş M-mode temeli; açık M/S/U ayrıcalık durum makinesi, CSR adres yetki denetimi (`csr_addr[9:8] <= priv_mode`), salt-okunur CSR koruması, WARL alanları ve trap/hata anında yan etki (side-effect) bastırması.
- **İlk S-mode Bare RTL paketi:** Bağımsız incelemeden geçmiş ve dondurulmuştur (ACCEPT AND FREEZE). S-mode trap bankası (`stvec`, `sscratch`, `sepc`, `scause`, `stval`), `sstatus` maskeli alias'ı, `medeleg` ile senkron exception yönlendirmesi, `mret`/`sret` kuralları, `wfi`, Bare `sfence.vma` ve sayaç erişim denetimi (`mcounteren`/`scounteren`) içerir.
- **Kesmeler ve SoC entegrasyonu:** Tek-hart CLINT (MTIP/MSIP) ve harici kesme (MEIP) desteği; SoC bellek haritası ve MMIO veri yolu entegrasyonu (`fursoy_s0_soc`).
- **Doğrulama ve referans:** 11 bare-metal ELF testi hem Spike referans simülatöründe hem Verilator DUT simülasyonunda çalışmakta ve imza karşılaştırmasından geçmektedir (`tools/run_core_baremetal_s0.py`). S-mode trap ve yetki senaryoları odaklı entegrasyon testleriyle (57 CSR birim kontrolü, 9 uçtan uca senaryo) doğrulanmıştır.

Henüz uygulanmamış ve eksik olan temel bileşenler:
- Supervisor kesme yönlendirmesi (`mideleg`, `sie`, `sip`, SSIP/STIP/SEIP).
- Sv39 sayfalama / MMU / PTW / TLB.
- PMP (Fiziksel Bellek Koruması).
- PLIC (Platform Düzeyinde Kesme Denetleyicisi).
- Önbellekler (L1I/L1D ve L2/L3 cache yapıları).
- Çok çekirdek / çok-hart desteği.
- Linux açılışı (boot).
- Fiziksel PPA (alan, frekans, güç) sonuçları.

## Ortam kontrolü

Ubuntu WSL içinde, depo kökünde:

```bash
python3 tools/check_environment.py --require bootstrap --output results/environment-wsl.json
python3 -m unittest discover -s verification -v
```

Betik araç kurmaz. Bulunan araçların sürüm/yardım komutlarını çalıştırır.
Bir profilin `ready` olması yalnızca bu çağrıların geçtiğini gösterir;
birbirleriyle uyum, donanım simülasyonu veya üretim uygunluğu göstermez.
JSON bir gözlem kaydıdır, kilitlenmiş araç zinciri değildir.

Örneğin `--require rtl` donanım simülasyon araçları eksik veya bozuksa
sıfırdan farklı çıkış kodu verir. Birden fazla `--require` kullanılabilir.
`--require` olmadan yalnızca envanter toplar; eksikler yine raporda görünür.

## Gerçek RTL simülasyonu

Ubuntu içinde depo kökünde:

```bash
python3 tools/run_fifo.py
```

Verilator ve G++ gerekir. Betik dört FIFO konfigürasyonu ve bir bozuk RTL kopyası
derler; derleme paralelliği 2 ile sınırlıdır. Kaynak RTL değiştirilmez.
İlk hata sıfırdan farklı çıkış kodu verir. Sonuç ve kaynak SHA-256 değerleri
`results/fifo.json`, derleme/koşu logları `build/fifo/` altında tutulur.
Bu bir RTL araç zinciri ve FIFO işlev kontrolüdür; formal/PPA doğrulaması değildir.

Arayüz ve kapsam: [FIFO sözleşmesi](docs/architecture/fifo.md).
Kanıt ve sınırlar: [RTL pilot raporu](docs/progress/002-rtl-pilot.md).

## Sıradaki işler

1. Supervisor kesme yönlendirmesi paketi (`mideleg`, `sie`, `sip`, SSIP/STIP/SEIP).
2. Sv39 / MMU mimari sözleşmesi ve donanım tasarımı.
3. PMP, PLIC ve önbellek entegrasyonu.

Mevcut donanım, eksikler ve doğrulama kanıtı:
[ilk ortam kaydı](docs/progress/001-environment.md).

ISA/platform kapsamı: [sözleşme](docs/requirements/isa-platform.md),
[gereksinim tablosu](docs/requirements/isa-platform.csv).
Tablo kontrolü: `python3 tools/check_requirements.py`.

## Bare-metal derleme ve DUT yürütme

Ubuntu içinde `python3 tools/build_baremetal.py` çalıştırılır. RISC-V GCC/binutils
gerekir. ELF ve ayrıntılı loglar `build/baremetal/`, kalıcı özet ve kaynak hash'leri
`results/baremetal-build.json` altında oluşur.
Derlenen ELF'ler Spike üzerinde `python3 tools/run_spike.py` ve Verilator DUT üzerinde
`python3 tools/run_core_baremetal_s0.py` ile çalıştırılarak imzalar doğrulanır.
Test sözleşmesi: [bare-metal v1](docs/architecture/baremetal-v1.md).
Komut, CSR ve trap alt sözleşmesi: [slice-0](docs/requirements/slice-0.md).

## Spike referans hazırlığı

Resmî kaynak commit'i `tools/spike-lock.json` içinde sabittir. Kaynak ve derleme
proje içindeki `build/` altındadır; sistem PATH'i değiştirilmez.
Ubuntu bağımlılıkları: `device-tree-compiler libboost-regex-dev libboost-system-dev`.
Kurulduktan sonra Ubuntu'da sırasıyla:

```bash
python3 tools/setup_spike.py
python3 tools/build_baremetal.py
python3 tools/run_spike.py
```

Setup derleme logları `build/spike-build/` altında tutulur; 4 derleme işi kullanır.
Çalıştırıcı gerçek başarı yanında beklenmeyen trap, bozuk imza ve timeout
senaryolarını denetler. Spike referans koşuları ve altın imza üretim altyapısı
doğrulanmış olup regresyonlarda kullanılmaktadır (`results/spike.json`).
