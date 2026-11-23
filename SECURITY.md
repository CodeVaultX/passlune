# Security

[Türkçe](#türkçe)

## Reporting a vulnerability

Please e-mail **passlune.app@gmail.com** with the details and, if you can, the steps to reproduce. Please don't open a public issue for a security problem. You'll get an answer within a few days.

## How the vault is protected

**The vault file** (`vault.kasa`) is JSON:

```json
{ "v": 1, "kdf": "argon2id", "salt": "…", "nonce": "…", "ct": "…", "mac": "…" }
```

- **Key:** derived from the master password with **Argon2id** (memory 19 MiB, 2 iterations, parallelism 1, 32-byte output) and a random **16-byte salt**. A new salt is made when a vault is created and whenever the master password changes.
- **Encryption:** **AES-256-GCM** over the whole list of entries, with a new random **12-byte nonce** on every save and the salt as additional authenticated data. A wrong password or a changed file fails the GCM check; nothing is decrypted.
- **The master password** is never written anywhere. While the vault is open it is kept in memory only, to open a synced copy that another device re-encrypted with a new salt.
- The app, the browser extensions and every device read and write the same format; the extensions use WebCrypto and hash-wasm with the same parameters.

**Sync:**
- **Google Drive:** only the encrypted file is uploaded, to the app's hidden folder (`drive.appdata` scope: Passlune can't see your other Drive files, and they can't see it). Google learns the file's size and when it changes. Each user signs in with their own account; the developer has no server and no access.
- **Folder sync** (Dropbox, OneDrive, Syncthing, ...): the same encrypted file in a folder you choose.
- Two copies are merged entry by entry (newer change wins, deletions kept as empty markers). A copy under a different master password is never overwritten; the app asks for that password.

**On the device:**
- Auto-lock after 1 hour without use (time in the background counts), or with one tap. The Android "Fill with Passlune" screen locks as soon as you leave it.
- Copied passwords are cleared from the clipboard after 20 seconds. On Android they are marked sensitive; on Windows they are kept out of clipboard history and cloud clipboard.
- Screenshots and screen recording are blocked (Android `FLAG_SECURE`, Windows `WDA_EXCLUDEFROMCAPTURE`).
- Logins saved by Android autofill while the vault is locked wait encrypted with an AES key in the Android Keystore (usable only while the phone is unlocked, Android 9+) until the vault is next opened.
- The Windows app's Google sign-in token is sealed with DPAPI (tied to your Windows account). The extensions keep theirs in their own IndexedDB, which web pages and content scripts can't read.

**Autofill and the extensions:**
- Android trusts the web address of a page only from known browsers; any other app is matched by its exact package name. Guessing a login from a package name (`com.example.app` → `example.com`) is done only for apps installed from Google Play or the system. Filling a login into an app or site it doesn't match asks first.
- The extensions identify a page by the address the browser reports, not by what the page says. A page can get only its own site's logins, only after you pick one, and never over plain `http` on a public host. Clicks on Passlune's fill and save boxes count only when the box is really visible and on top.

**Leaked-password check:** only when you start it. Each password's SHA-1 hash is cut to its first 5 characters before it is sent to Have I Been Pwned (k-anonymity, with padding); the comparison happens on your device.

## Limits you should know about

- Passlune has **not had an independent security audit**.
- The Argon2id settings are OWASP's recommended minimum. They are not stored in the file, so raising them will need a new file version.
- While the vault is open, the decrypted entries are in the app's memory. Malware on an unlocked device, a rooted phone or someone with your unlocked device can read what you can.
- If you forget the master password, the vault cannot be recovered. There is no reset and no backdoor.
- The Google OAuth client IDs (and for Windows and the Firefox/Edge sign-in, the client "secrets") inside the official apps are not secret; Google treats them as public for installed apps. They identify the app, not you, and give access to nothing without your own Google sign-in.
- Builds from this source don't include those Google clients; see [GOOGLE_SETUP.md](GOOGLE_SETUP.md).

---

## Türkçe

### Güvenlik açığı bildirme

Ayrıntıları ve mümkünse nasıl tekrarlanacağını **passlune.app@gmail.com** adresine yazın. Güvenlik sorunları için lütfen herkese açık bir issue açmayın. Birkaç gün içinde yanıt alırsınız.

### Kasa nasıl korunur

- **Anahtar:** ana şifreden **Argon2id** ile türetilir (19 MiB bellek, 2 tur, paralellik 1, 32 bayt) ve rastgele **16 baytlık salt** kullanır. Salt, kasa oluşturulurken ve ana şifre her değiştiğinde yenilenir.
- **Şifreleme:** kayıt listesinin tamamı **AES-256-GCM** ile, her kayıtta yeni rastgele **12 baytlık nonce** ve ek doğrulanan veri olarak salt ile şifrelenir. Yanlış şifre ya da değiştirilmiş dosya GCM kontrolünden geçemez; hiçbir şey çözülmez.
- **Ana şifre** hiçbir yere yazılmaz. Kasa açıkken yalnızca bellekte tutulur; başka bir cihazın yeni salt ile şifrelediği senkron kopyasını açmak için gerekir.
- Uygulama, eklentiler ve tüm cihazlar aynı biçimi okuyup yazar.
- **Senkron:** Google Drive'a yalnızca şifreli dosya, uygulamanın gizli klasörüne (`drive.appdata`) yüklenir; Google yalnızca dosyanın boyutunu ve değiştiği zamanı görür. Geliştiricinin sunucusu ve erişimi yoktur. Klasör senkronunda aynı şifreli dosya seçtiğiniz klasöre yazılır. Farklı ana şifreyle şifrelenmiş bir kopyanın üzerine asla yazılmaz.
- **Cihazda:** 1 saat kullanılmayınca otomatik kilit (arka planda geçen süre de sayılır); Android'deki "Passlune ile doldur" ekranı bırakılınca hemen kilitlenir. Kopyalanan şifre 20 saniye sonra panodan silinir. Ekran görüntüsü ve kayıt engellidir. Kasa kilitliyken otomatik doldurmayla kaydedilen girişler, Android Keystore'daki bir anahtarla şifreli bekler. Windows'taki Google oturumu DPAPI ile, eklentilerinki web sayfalarının okuyamadığı kendi IndexedDB'lerinde saklanır.
- **Otomatik doldurma ve eklentiler:** Android'de sitenin adresine yalnızca bilinen tarayıcılardan gelince güvenilir; diğer uygulamalar paket adıyla eşleşir. Eşleşmeyen bir yere doldurmadan önce sorulur. Eklentilerde bir sayfa yalnızca kendi sitesinin girişlerini, ancak siz seçince alabilir; herkese açık `http` sayfalarına giriş verilmez.
- **Sızıntı kontrolü:** yalnızca siz başlatınca çalışır; her şifrenin SHA-1 özetinin yalnızca ilk 5 karakteri gönderilir.

### Bilmeniz gereken sınırlar

- Passlune **bağımsız bir güvenlik denetiminden geçmedi**.
- Argon2id ayarları OWASP'ın önerdiği en alt düzeydedir ve dosyada saklanmaz; artırmak yeni bir dosya sürümü gerektirir.
- Kasa açıkken çözülmüş kayıtlar uygulamanın belleğindedir. Kilidi açık bir cihazdaki zararlı yazılım, root'lu bir telefon ya da cihazınızı kilitsiz ele geçiren biri sizin gördüğünüzü görebilir.
- Ana şifreyi unutursanız kasa kurtarılamaz; sıfırlama ya da arka kapı yoktur.
- Resmi uygulamaların içindeki Google istemci kimlikleri (ve Windows ile Firefox/Edge girişindeki istemci "secret"ları) gizli değildir; Google bunları kurulan uygulamalar için herkese açık sayar. Uygulamayı tanımlarlar, sizi değil; sizin Google girişiniz olmadan hiçbir şeye erişim vermezler.
