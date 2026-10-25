# Passlune — Privacy Policy

*Last updated: October 25, 2026*

[Türkçe](#türkçe)

Passlune is a password manager for Android, Windows and browsers (Chrome, Edge, Firefox). It is built so that nobody but you can read your vault — including us.

## Where your data is kept

- Everything in your vault (sites, usernames, passwords, notes) is encrypted on your device with **AES-256-GCM**. The key is derived from your master password with **Argon2id** and is never written to disk.
- Your master password is never sent anywhere.
- If you turn on **Google Drive sync**, Passlune uploads only the encrypted vault file to the app's private Drive area (`drive.appdata` scope). That area doesn't show in your Drive and only Passlune can reach it. We can't read it.

## Leaked-password check (optional)

When you start the check, Passlune hashes each password with SHA-1 and sends **only the first 5 characters** of the hash to the Have I Been Pwned "Pwned Passwords" service (`api.pwnedpasswords.com`). The service returns a list of matching hash endings, and the comparison happens on your device. Your passwords, and their full hashes, never leave the device. Results are kept in memory only.

## Autofill on Android (optional)

If you choose Passlune as your autofill service, Android shows it the login fields of the app or site you're using. Passlune reads them only to offer your saved login, or to save a new one when you ask it to. A new login waits on the device, encrypted with an Android Keystore key, until you open Passlune, which then adds it to your vault.

## What we don't collect

- No ads, analytics or tracking.
- No account with us. We have no servers.
- Your Google account is used only to sign in to Drive sync, by Google.

## Removing your data

- Delete the app, or the extension, to remove the local vault.
- To remove the synced copy, open Google Drive on the web → Settings → **Manage apps** → Passlune → **Delete hidden app data**. You can also stop sync in the app, or remove Passlune's access on [Google account permissions](https://myaccount.google.com/permissions).

## Contact

passlune.app@gmail.com

---

## Türkçe

*Son güncelleme: 25 Ekim 2026*

Passlune; Android, Windows ve tarayıcılar (Chrome, Edge, Firefox) için bir şifre yöneticisidir. Kasanızı sizden başka kimse, biz de dahil, okuyamaz.

### Verileriniz nerede

- Kasadaki her şey (site, kullanıcı adı, şifre, not) cihazınızda **AES-256-GCM** ile şifrelenir. Anahtar, ana şifrenizden **Argon2id** ile türetilir ve diske hiç yazılmaz.
- Ana şifreniz hiçbir yere gönderilmez.
- **Google Drive senkronu**nu açarsanız Passlune yalnızca şifreli kasa dosyasını Drive'daki uygulamaya özel gizli alana (`drive.appdata`) yükler. Bu alan Drive'ınızda görünmez, yalnızca Passlune erişebilir. Biz okuyamayız.

### Sızıntı kontrolü (isteğe bağlı)

Kontrolü başlattığınızda Passlune her şifrenin SHA-1 özetini çıkarır ve Have I Been Pwned "Pwned Passwords" servisine (`api.pwnedpasswords.com`) bu özetin **yalnızca ilk 5 karakterini** gönderir. Servis eşleşen özet sonlarını döndürür, karşılaştırma cihazınızda yapılır. Şifreleriniz ve tam özetleri cihazdan çıkmaz. Sonuçlar yalnızca bellekte tutulur.

### Android'de otomatik doldurma (isteğe bağlı)

Passlune'u otomatik doldurma hizmeti seçerseniz Android, kullandığınız uygulama ya da sitenin giriş alanlarını ona gösterir. Passlune bunları yalnızca kayıtlı girişinizi önermek ya da siz istediğinizde yenisini kaydetmek için okur. Yeni giriş, Passlune'u açana kadar cihazda Android Keystore anahtarıyla şifreli bekler, sonra kasanıza eklenir.

### Toplamadıklarımız

- Reklam, analitik ya da takip yok.
- Bizde hesap yok, sunucumuz yok.
- Google hesabınız yalnızca Drive senkronuna giriş için, Google tarafından kullanılır.

### Verilerinizi silmek

- Uygulamayı ya da eklentiyi kaldırmak yerel kasayı siler.
- Senkron kopyayı silmek için Google Drive'ı web'de açın → Ayarlar → **Uygulamaları yönet** → Passlune → **Gizli uygulama verilerini sil**. Ayrıca senkronu uygulamada kapatabilir ya da [Google hesap izinleri](https://myaccount.google.com/permissions) sayfasından Passlune'un erişimini kaldırabilirsiniz.

### İletişim

passlune.app@gmail.com
