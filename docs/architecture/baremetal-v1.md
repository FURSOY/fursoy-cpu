# Bare-metal test platformu v1

Bu harita test ortamına aittir; sunucu SoC haritası ve silikon reset vektörü değildir.
Tek hart, M-mode, little-endian RV64I_Zicsr_Zifencei. Yükleyici ELF PT_LOAD segmentlerini
yerleştirir ve BSS için memsz/filesz farkını sıfırlar; başlangıç kodu da BSS'yi sıfırlar.
Program giriş adresi 0x80000000. Referansın reset ROM'u varsa bu girişe devir yapar.

| Adres | Kullanım |
|---|---|
| 0x80000000–0x8000ffff | Kod ve sabit veri; ELF RX segmenti |
| 0x80010000 | 64-bit tohost |
| 0x80010008 | 64-bit fromhost, başlangıçta 0 |
| 0x80010010–0x8001004f | Sekiz 64-bit sonuç alanı |
| 0x80011000 ve sonrası | Veri/BSS; ELF RW segmenti |
| 0x8001f000–0x8001ffff | 4 KiB stack rezervi; başlangıç SP=0x80020000 |

ELF izinleri M-mode bellek korumasını kendiliğinden kurmaz. İlk ortam bu RAM'e
erişime izin verir; PMP/MMIO ve gerçek platform koruması ayrı test edilecektir.

Sonuç alanları sırayla: magic=0x465552534f593031, sürüm=1, durum, test kimliği,
mcause, mepc, mtval, beklenen trap sayısı. Durum 0=çalışıyor, 1=başarılı, 2=hatalı.
tohost=1 başarı bildirimi, tohost=3 başarısızlık bildirimi adayıdır; Spike adaptörü
ile uyumu çalıştırılarak ayrıca doğrulanacaktır. Mailbox sonucu ve imza birlikte
kontrol edilir. Timeout, sessizlik veya park döngüsü başarı değildir.

Başarı imzası: durum=1, test kimliği=0, mcause=11, mepc=ecall_probe,
mtval=0, trap sayısı=1. ECALL'den mepc+4 ile dönüş beklenir. Her farklı trap veya
tekrarlı ECALL test kimliği 100 ile başarısız olur. Handler normal bir OS handler'ı
değildir: yalnızca bu tek ECALL noktasında geçici register'ları bozabilir; diğer
trap'ler terminal başarısızlıktır. C test kimlikleri 1=BSS, 2=toplam, 3=trap sayısı.

Derleme sabitleri: -march=rv64i_zicsr_zifencei -mabi=lp64 -mcmodel=medany,
relaxation ve PIC kapalı; libc/startup yok. Linker assert'leri kod/mailbox ve
veri/stack çakışmalarını reddeder. [GNU ld](https://sourceware.org/binutils/docs/ld/Scripts.html)

Bu program ISA uyumluluk paketi değildir. CPU RTL'i henüz yok; önce referansta,
sonra DUT'ta aynı ELF ve imzayı kontrol etmek için hazırlanmıştır.
