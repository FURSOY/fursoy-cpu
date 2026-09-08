# FIFO-001 — Tek saatli küçük kontrol kuyruğu

Durum: RTL laboratuvar pilotu. CPU ROB/LSQ tasarımı veya nihai fiziksel IP değildir.

Parametreler: WIDTH >= 1, DEPTH >= 1; ikinin kuvveti olmayan derinlikler desteklenir.
İşlemler yükselen saat kenarında gerçekleşir. Senkron aktif-yüksek reset, flush'tan
önceliklidir; ikisi de kuyruğu boşaltır. Reset/flush aktifken ready/valid sıfırdır;
o kenarda hiçbir aktarım kabul edilmez. Bellek bitleri resetlenmez, geçersiz veriler
çıkışa verilmez. Bu işlem fiziksel veri silme veya güvenlik temizliği değildir.

Enqueue yalnızca `in_valid && in_ready`, dequeue yalnızca `out_valid && out_ready`
ile gerçekleşir. Üretici, bekletilen geçerli veriyi kabul edilene veya reset/flush'a
kadar korur. Çıkış da beklerken kararlıdır; reset/flush bekleyen işlemi iptal eder.
Boş kuyrukta kombinasyonel bypass yoktur: ilk veri bir sonraki çevrimde geçerlidir.
Geçersiz çıkış verisi sıfırdır. Dolu kuyrukta aynı kenarda okuma yapılırsa yeni
veri kabul edilir; derinlik 1 dahil eski veri okunur, yeni veri saklanır.

Bu seçim `out_ready → in_ready` kombinasyonel yolu oluşturur. Entegrasyonda döngü
oluşturulamaz; uzun zincirler için register slice veya farklı kuyruk arayüzü gerekir.
Depolama asenkron okunan küçük register dizisidir; SRAM makrosu varsayılmamıştır.
Frekans/alan/güç henüz ölçülmedi; CPU'nun kritik yoluna yerleştirme onayı yoktur.

| Gereksinim | Kanıt yöntemi |
|---|---|
| FIFO-01 Veri sırası ve kayıpsızlık | Bağımsız C++ deque, her çevrim başındaki çıkış karşılaştırması |
| FIFO-02 Dolu/boş sınırlar | Yönlendirilmiş doldurma, bekletme, boşaltma |
| FIFO-03 Tam kapasitede eşzamanlı aktarım | Yönlendirilmiş ve rastgele full exchange |
| FIFO-04 Reset/flush iptali | Veri varken ve iki aktarım talebiyle kontrol |
| FIFO-05 İşaretçi sarılması | DEPTH=1/3/8, tekrarlı aktarımlar |
| FIFO-06 İç sınırlar | RTL assertion: sayaç ve işaretçi aralıkları |
| FIFO-07 Test düzeneğinin duyarlılığı | Ayrı kopyada veri bitini boz; scoreboard hatası zorunlu |

Simülasyon matrisi: WIDTH/DEPTH = 8/1, 32/3, 8/8, 32/8; her biri üç sabit tohum.
Rastgele girişte üreticinin bekleyen verisi korunur. Başarı için köşe durum
sayaçları da kontrol edilir. Bu kapsam bütün parametreler için formal kanıt değildir.
