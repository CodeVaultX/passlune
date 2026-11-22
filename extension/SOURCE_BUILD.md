# Passlune — Firefox eklentisi kaynak kodu ve build talimatları

## Genel bakış

Bu eklentideki tüm kendi kodumuz (background.js, content.js, popup.js,
popup.html, popup.css, content.css, manifest.json, lib/crypto.js,
lib/domain.js, lib/kv.js, lib/drive.js, lib/config.js) **derlenmemiş, küçültülmemiş, elle yazılmış
düz JavaScript/HTML/CSS**'tir. Herhangi bir bundler (webpack vb.),
transpiler, minifier veya kod üreteci kullanılmamıştır. Bu dosyalar
zaten yayınlanan sürümle birebir aynıdır — ekstra bir build adımı
gerektirmez.

## Tek istisna: lib/argon2.umd.min.js

Bu dosya, açık kaynaklı **hash-wasm** npm paketinin (MIT lisanslı,
sürüm 4.12.0) resmi, değiştirilmemiş build çıktısıdır. Kendi kodumuz
değildir ve Firefox Eklenti Atölyesi kurallarının "açık kaynaklı üçüncü
taraf kitaplıklar" istisnasına girer.

Bu dosyayı yeniden üretmek için:

```bash
npm install hash-wasm@4.12.0
cp node_modules/hash-wasm/dist/argon2.umd.min.js lib/argon2.umd.min.js
```

Kaynak: https://www.npmjs.com/package/hash-wasm/v/4.12.0

## Üretilmiş veri: lib/psl-data.js

Bu dosya kod değil, veridir: Mozilla'nın **Public Suffix List**'inin
(MPL-2.0, https://publicsuffix.org/list/public_suffix_list.dat) kurallarının
tek bir JavaScript dizesine dönüştürülmüş hâlidir. `lib/domain.js` bunu,
bir sitenin kayıtlı alan adını bulmak için kullanır (örn. `garanti.com.tr`
ile `baska-site.com.tr`'nin farklı siteler olduğunu bilmek için).

Yeniden üretmek için (eklenti klasörünün bir üstündeki `tools/` klasöründen):

```bash
curl -o public_suffix_list.dat https://publicsuffix.org/list/public_suffix_list.dat
node tools/build-psl.js public_suffix_list.dat   # chrome/lib/psl-data.js yazar
node tools/sync-shared.js                         # ortak dosyaları firefox/'a kopyalar
```

`tools/build-psl.js` yalnızca yorum/boş satırları atar ve Unicode alan
adlarını Node'un `url.domainToASCII` fonksiyonuyla punycode'a çevirir.

## Ortam gereksinimleri

- Yalnızca `lib/argon2.umd.min.js`'i yeniden üretmek isterseniz: Node.js
  18+ ve npm.
- Eklentinin kendisini çalıştırmak/yüklemek için ek bir araç gerekmez;
  bu klasör doğrudan "Paketlenmemiş öğe yükle" / "Geçici Eklenti Yükle"
  ile kullanılabilir.

## Paketi oluşturmak

Yayınlanan .xpi, bu klasördeki dosyaların (icons/ dahil) doğrudan
zip'lenmesiyle oluşturulur; ekstra bir derleme adımı yoktur.
