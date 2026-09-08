# İlk uçtan uca Slice-0 core sözleşmesi

`fursoy_s0_core`, tek talimatı aynı anda fetch/execute/commit eden in-order bir
DUT dilimidir. Fetch cevabı RV64I `OP-IMM`/`OP` ALU veya control-flow decoder'ın
tanıdığı talimatlarda tüketilir. ALU PC'yi dört bayt ilerletir; branch/JAL/JALR
hesaplanan hedefi seçer ve JAL/JALR link değerini register file'a yazar.

Commit-trace, `commit_valid`, PC, instruction, destination register write
niyeti ve verisinden oluşur. `x0` için geçerli bir ALU talimatı commit olur ama
register write niyeti kapalıdır; register dosyasının x0 girdisi sıfır tutulur.

Tanınmayan kodlama, M-mode `ECALL` veya `EBREAK`, `trap_valid` üretir ve fetch cevabı aynı
edge'de tüketilir. Trap girişi `mepc=PC` yazar; illegal için `mcause=2` ve
instruction'ı zero-extend ederek `mtval`, ECALL için `mcause=11`, EBREAK için
`mcause=3` ve her ikisi için `mtval=0`
kurar. `MPIE←MIE`, `MIE←0`, `MPP←M` uygulanır ve PC `mtvec`e yönlendirilir.
`mret` M-mode'da commit olur, PC'yi `mepc`e döndürür, `MIE←MPIE`, `MPIE←1` ve
M-only WARL gereği `MPP←M` uygular; U-mode'a geçiş yoktur. Normal Slice-0 reseti `mstatus=0x1800`,
`mie=mtvec=mepc=mcause=mtval=0` kurar. `RESET_MTVEC` yalnız doğrulama için
parametreleştirilebilir; ürün reset sözleşmesini değiştirmez.

Load/store decoder ve tek-outstanding LSU port core'a bağlıdır. LSU işlemi
sürerken fetch durur; store request kabulünde, load ise response kabulünde
commit olur. Veri belleği cevabı istenen genişliğe göre sağa yaslıdır. Bu sürüm
henüz cache veya çoklu outstanding bellek işlemi çalıştırmaz.

Başarılı store request handshake'i request zamanında commit olur; aynı handshake'deki
store error `mcause=7` trap'iyle işlemi sonlandırır. Load başarı ve hata dahil her
zaman response ile tamamlanır; hata response'u `mcause=5` üretir. Her iki access
fault için `mepc` hatalı komutu, `mtval` efektif adresi gösterir; hedef register ve
commit izi değişmez. Ayrıntılı handshake/reset kuralları `lsu-s0.md` içindedir.

`FENCE` sıralı, tek-outstanding LSU'da önceki bellek işlemi tamamlandıktan sonra
commit olur. `FENCE.I` ayrıca `fence_i_valid_o` olayı üretir. Slice-0'da I-cache
yoktur; gelecekteki I-cache bu olayı invalidate tamamlanana kadar bekletmek için
bir handshake'e dönüştürecektir.

Zicsr yolu `mstatus`, `mie`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mtval`
ve read-only `cycle` CSR'lerini işler. Core CSR write'larında Slice-0 WARL
maskelerini uygular; read-only veya tanımsız CSR erişimleri illegal-instruction
trap'ine gider.

Instruction-memory error response'u decode edilmez ve commit üretmez. İstekle
tutulan PC için `mcause=1`, `mepc=PC`, `mtval=PC` kurulur ve doğrudan `mtvec`e
gidilir. Böylece response veri bitleri geçerli bir talimat kodlasa bile mimari
yan etki oluşturamaz.
