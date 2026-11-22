# Google Drive sync for your own build

[Türkçe](#türkçe)

The official Passlune builds sign in to Google with clients of our Google Cloud project. Those are not in this repository, so a build from source starts without Google:

- **Android and Windows app:** everything works (vault, autofill, encrypted backups, folder sync) except "Sync with Google Drive", which stays hidden.
- **Browser extensions:** they keep the vault only on Google Drive, so they need the steps below.

It is free and takes about 20 minutes. You only need the parts for the platforms you use.

## 1. Create a project and turn on the Drive API

1. Open https://console.cloud.google.com and sign in with your Google account.
2. In the project picker at the top, choose **New project**, give it any name (for example "My Passlune") and click **Create**. Make sure the new project is selected at the top.
3. Open the menu (☰) → **APIs & Services** → **Library**, search for **Google Drive API**, open it and click **Enable**.

## 2. Set up the sign-in screen

1. Menu (☰) → **Google Auth Platform**. If you see **Get started**, click it.
2. **App information:** an app name (if you publish your build, don't call it "Passlune") and your e-mail as the support e-mail. **Next**.
3. **Audience:** choose **External**. **Next**.
4. **Contact information:** your e-mail. **Next**, agree to the policy, **Create**.
5. On the left, **Data Access** → **Add or remove scopes**. Type `drive.appdata` in the filter, tick `.../auth/drive.appdata` and click **Update**, then **Save**.
6. On the left, **Audience** → **Publish app** → **Confirm**. The status becomes **In production**.

Why step 6: while the app is "Testing", only the test users you add can sign in, and every sign-in expires after 7 days. `drive.appdata` is a non-sensitive scope, so publishing needs no review by Google.

## 3. Which clients you need

| You use | Client type to create | Where its values go |
|---|---|---|
| Android app | **Android** and **Web application** | Web client ID → `lib/config.dart` (`googleWebClientId`) |
| Windows app | **Desktop app** | `lib/config.dart` (`googleDesktopClientId`, `googleDesktopClientSecret`) |
| Firefox extension | **Web application** | `extension/firefox/lib/config.js` |
| Edge extension | **Web application** | `extension/chrome/lib/config.js` |
| Chrome extension | **Chrome Extension** | `extension/chrome/manifest.json` (`oauth2.client_id`) |

One Web application client serves Android, Firefox and Edge together.

Clients are created under menu (☰) → **Google Auth Platform** → **Clients** → **Create client**.

## 4. Web application client (Android, Firefox, Edge)

1. **Create client** → Application type **Web application** → any name → **Create**. Leave "Authorized redirect URIs" empty for now (Firefox and Edge add theirs in steps 7 and 8).
2. Copy the **Client ID** and the **Client secret** shown in the dialog. You can open the client later to see them again.

## 5. Android

1. Run `flutter pub get` once in the project folder, then in a terminal:
   ```bash
   cd android
   gradlew signingReport
   ```
   (`./gradlew signingReport` on macOS/Linux.) Copy the **SHA1** line under `Variant: debug`. If you also make release builds with your own `android/key.properties`, copy the SHA1 under `Variant: release` too.
2. If you will publish your build, first change `applicationId = "app.passlune"` in `android/app/build.gradle.kts` to your own (for example `com.yourname.passwords`). Leave `namespace` as it is.
3. **Create client** → **Android** → **Package name** = the application ID (`app.passlune` if you didn't change it) → **SHA-1** = the value from step 1 → **Create**. Create one more Android client for the release SHA1 if you have one. There is nothing to copy from Android clients; Google recognises the app by package name and SHA-1.
4. In `lib/config.dart` set `googleWebClientId` to the **Web application** client ID from step 4.

## 6. Windows

1. **Create client** → **Desktop app** → any name → **Create**.
2. Copy its Client ID and Client secret into `lib/config.dart`: `googleDesktopClientId` and `googleDesktopClientSecret`.

Nothing else is needed: the app signs in through your browser and catches the answer on `http://127.0.0.1`.

## 7. Firefox

1. If you will publish the add-on yourself, change `"id": "passlune@passlune.app"` in `extension/firefox/manifest.json` to your own (for example `passwords@yourname.example`). The sign-in address below depends on it.
2. In `extension/firefox/lib/config.js` set `webClientId` and `webClientSecret` to the **Web application** client values from step 4.
3. In Firefox open `about:debugging#/runtime/this-firefox` → **Load Temporary Add-on…** → choose `extension/firefox/manifest.json`.
4. Click the Passlune toolbar button → **Show this browser's redirect address** and copy it. It looks like `https://0123456789abcdef.extensions.allizom.org/`.
5. In Google Cloud open your **Web application** client → **Authorized redirect URIs** → **Add URI** → paste → **Save**. Give it a few minutes.
6. Back in the Passlune popup: **Connect with Google**.

A temporary add-on disappears when Firefox restarts. To keep it, sign it as an unlisted add-on on addons.mozilla.org (free).

## 8. Edge

1. In `extension/chrome/lib/config.js` set `webClientId` and `webClientSecret` to the **Web application** client values from step 4.
2. Open `edge://extensions` → turn on **Developer mode** → **Load unpacked** → choose the `extension/chrome` folder.
3. Passlune toolbar button → **Show this browser's redirect address**, copy it (`https://<extension id>.chromiumapp.org/`).
4. Add it to the **Web application** client's **Authorized redirect URIs** in Google Cloud and **Save**.
5. Passlune popup → **Connect with Google**.

The extension keeps the same ID as long as its folder stays in the same place. If you move the folder, add the new address too.

## 9. Chrome

Chrome signs in with the Google account of the Chrome profile, through its own client type.

1. Open `chrome://extensions` → turn on **Developer mode** → **Load unpacked** → choose the `extension/chrome` folder. Copy the **ID** shown on the Passlune card.
2. In Google Cloud: **Create client** → **Chrome Extension** → **Item ID** = that ID → **Create**. Copy the **Client ID**.
3. In `extension/chrome/manifest.json`, under `"oauth2"`, replace `YOUR_CHROME_EXTENSION_CLIENT_ID.apps.googleusercontent.com` with it.
4. Back in `chrome://extensions`, click the reload arrow on the Passlune card, then in the popup **Connect with Google**.

Same as Edge: keep the folder where it is, or the ID changes.

## 10. Build and connect

- App: `flutter run` (or a release build), then Settings → **Sync with Google Drive**.
- On a second device, use **Get my vault from Google Drive** on the first screen and unlock with the same master password.

## If something goes wrong

| Message | Cause and fix |
|---|---|
| `redirect_uri_mismatch` | The extension's redirect address isn't in the Web application client yet (steps 7 and 8), or it was added minutes ago: wait and retry. |
| `invalid_client` | The client ID or secret in the config file is wrong, or belongs to another client type. |
| `access_denied` / "has not completed the Google verification process" | The app is still in **Testing** (step 2.6), or your account isn't a test user. |
| Android: sign-in window closes at once, nothing happens | The Android client's package name or SHA-1 doesn't match the build you installed (step 5), or `googleWebClientId` is empty. |
| Firefox/Edge ask to connect again after 7 days | The app is still in **Testing** (step 2.6). |
| Chrome: "OAuth2 request failed" / "bad client id" | `oauth2.client_id` in the manifest isn't a **Chrome Extension** client made for this extension's ID (step 9). |

Every user signs in with their own Google account. The vault goes to that account's hidden app folder (`drive.appdata`), still encrypted; you, as the owner of the Google project, can't read it.

---

## Türkçe

Resmi Passlune sürümleri Google'a, bizim Google Cloud projemizin istemcileriyle bağlanır. Bunlar bu depoda yoktur, bu yüzden kaynaktan derlenen bir sürüm Google olmadan başlar:

- **Android ve Windows uygulaması:** "Google Drive ile senkronize et" dışında her şey çalışır (kasa, otomatik doldurma, şifreli yedek, klasör senkronu). O düğme gizli kalır.
- **Tarayıcı eklentileri:** kasayı yalnızca Google Drive'da tuttukları için aşağıdaki adımlar gerekir.

Ücretsizdir ve yaklaşık 20 dakika sürer. Yalnızca kullandığınız platformların adımlarını yapmanız yeterli.

### 1. Proje açın ve Drive API'yi etkinleştirin

1. https://console.cloud.google.com adresini açın ve Google hesabınızla giriş yapın.
2. Üstteki proje seçicide **New project** deyin, bir ad verin (örneğin "Benim Passlune'um") ve **Create**'e basın. Üstte yeni projenin seçili olduğundan emin olun.
3. Menü (☰) → **APIs & Services** → **Library**, **Google Drive API** aratın, açın ve **Enable**'a basın.

### 2. Giriş ekranını kurun

1. Menü (☰) → **Google Auth Platform**. **Get started** görürseniz basın.
2. **App information:** bir uygulama adı (sürümünüzü yayınlayacaksanız "Passlune" demeyin) ve destek e-postası olarak kendi adresiniz. **Next**.
3. **Audience:** **External** seçin. **Next**.
4. **Contact information:** e-postanız. **Next**, politikayı onaylayın, **Create**.
5. Solda **Data Access** → **Add or remove scopes**. Filtreye `drive.appdata` yazın, `.../auth/drive.appdata` satırını işaretleyip **Update**, sonra **Save**.
6. Solda **Audience** → **Publish app** → **Confirm**. Durum **In production** olur.

6. adımın nedeni: uygulama "Testing" durumundayken yalnızca eklediğiniz test kullanıcıları giriş yapabilir ve her giriş 7 gün sonra düşer. `drive.appdata` hassas olmayan bir kapsamdır; yayına almak Google incelemesi gerektirmez.

### 3. Hangi istemcilere ihtiyacınız var

| Kullandığınız | Oluşturulacak istemci türü | Değerlerin gideceği yer |
|---|---|---|
| Android uygulaması | **Android** ve **Web application** | Web client ID → `lib/config.dart` (`googleWebClientId`) |
| Windows uygulaması | **Desktop app** | `lib/config.dart` (`googleDesktopClientId`, `googleDesktopClientSecret`) |
| Firefox eklentisi | **Web application** | `extension/firefox/lib/config.js` |
| Edge eklentisi | **Web application** | `extension/chrome/lib/config.js` |
| Chrome eklentisi | **Chrome Extension** | `extension/chrome/manifest.json` (`oauth2.client_id`) |

Tek bir Web application istemcisi Android, Firefox ve Edge için birlikte kullanılır.

İstemciler menü (☰) → **Google Auth Platform** → **Clients** → **Create client** ile oluşturulur.

### 4. Web application istemcisi (Android, Firefox, Edge)

1. **Create client** → Application type **Web application** → bir ad → **Create**. "Authorized redirect URIs" şimdilik boş kalsın (Firefox ve Edge kendi adreslerini 7. ve 8. adımda ekler).
2. Pencerede görünen **Client ID** ve **Client secret** değerlerini kopyalayın. Sonradan istemciyi açıp yeniden görebilirsiniz.

### 5. Android

1. Proje klasöründe bir kez `flutter pub get` çalıştırın, sonra bir terminalde:
   ```bash
   cd android
   gradlew signingReport
   ```
   (macOS/Linux'ta `./gradlew signingReport`.) `Variant: debug` altındaki **SHA1** satırını kopyalayın. Kendi `android/key.properties` dosyanızla release build de alıyorsanız `Variant: release` altındaki SHA1'i de alın.
2. Sürümünüzü yayınlayacaksanız önce `android/app/build.gradle.kts` içindeki `applicationId = "app.passlune"` satırını kendinize ait bir kimlikle değiştirin (örneğin `com.adiniz.sifreler`). `namespace` satırına dokunmayın.
3. **Create client** → **Android** → **Package name** = uygulama kimliği (değiştirmediyseniz `app.passlune`) → **SHA-1** = 1. adımdaki değer → **Create**. Release SHA1'iniz varsa onun için bir Android istemcisi daha oluşturun. Android istemcisinden kopyalanacak bir değer yoktur; Google uygulamayı paket adı ve SHA-1 ile tanır.
4. `lib/config.dart` içinde `googleWebClientId` değerine 4. adımdaki **Web application** istemcisinin Client ID'sini yazın.

### 6. Windows

1. **Create client** → **Desktop app** → bir ad → **Create**.
2. Client ID ve Client secret değerlerini `lib/config.dart` içindeki `googleDesktopClientId` ve `googleDesktopClientSecret` satırlarına yazın.

Başka bir şey gerekmez: uygulama tarayıcınız üzerinden giriş yapar ve cevabı `http://127.0.0.1` üzerinden alır.

### 7. Firefox

1. Eklentiyi kendiniz yayınlayacaksanız `extension/firefox/manifest.json` içindeki `"id": "passlune@passlune.app"` değerini kendinize ait bir kimlikle değiştirin (örneğin `sifreler@adiniz.example`). Aşağıdaki giriş adresi bu kimliğe bağlıdır.
2. `extension/firefox/lib/config.js` içinde `webClientId` ve `webClientSecret` değerlerine 4. adımdaki **Web application** istemcisinin değerlerini yazın.
3. Firefox'ta `about:debugging#/runtime/this-firefox` → **Geçici Eklenti Yükle…** → `extension/firefox/manifest.json` dosyasını seçin.
4. Araç çubuğundaki Passlune düğmesine basın → **Bu tarayıcının yönlendirme adresini göster** ve adresi kopyalayın. `https://0123456789abcdef.extensions.allizom.org/` gibi görünür.
5. Google Cloud'da **Web application** istemcinizi açın → **Authorized redirect URIs** → **Add URI** → yapıştırın → **Save**. Birkaç dakika bekleyin.
6. Passlune penceresinde **Google ile bağlan**.

Geçici eklenti Firefox yeniden başlayınca kaybolur. Kalıcı olması için addons.mozilla.org'da liste dışı (unlisted) olarak ücretsiz imzalatabilirsiniz.

### 8. Edge

1. `extension/chrome/lib/config.js` içinde `webClientId` ve `webClientSecret` değerlerine 4. adımdaki **Web application** istemcisinin değerlerini yazın.
2. `edge://extensions` açın → **Geliştirici modu**'nu açın → **Paketlenmemiş öğe yükle** → `extension/chrome` klasörünü seçin.
3. Passlune düğmesi → **Bu tarayıcının yönlendirme adresini göster**, adresi kopyalayın (`https://<eklenti kimliği>.chromiumapp.org/`).
4. Google Cloud'da **Web application** istemcisinin **Authorized redirect URIs** listesine ekleyip **Save** deyin.
5. Passlune penceresinde **Google ile bağlan**.

Klasör aynı yerde kaldıkça eklentinin kimliği değişmez. Klasörü taşırsanız yeni adresi de ekleyin.

### 9. Chrome

Chrome, Chrome profilindeki Google hesabıyla ve kendine ait bir istemci türüyle giriş yapar.

1. `chrome://extensions` açın → **Geliştirici modu**'nu açın → **Paketlenmemiş öğe yükle** → `extension/chrome` klasörünü seçin. Passlune kartında görünen **Kimlik** (ID) değerini kopyalayın.
2. Google Cloud'da: **Create client** → **Chrome Extension** → **Item ID** = bu kimlik → **Create**. **Client ID**'yi kopyalayın.
3. `extension/chrome/manifest.json` içinde `"oauth2"` altındaki `YOUR_CHROME_EXTENSION_CLIENT_ID.apps.googleusercontent.com` değerini bununla değiştirin.
4. `chrome://extensions` sayfasında Passlune kartındaki yenile okuna basın, sonra Passlune penceresinde **Google ile bağlan**.

Edge'deki gibi: klasörü yerinde tutun, yoksa kimlik değişir.

### 10. Derleyin ve bağlanın

- Uygulama: `flutter run` (ya da release build), sonra Ayarlar → **Google Drive ile senkronize et**.
- İkinci cihazda ilk ekranda **Google Drive'daki kasayı al** deyip aynı ana şifreyle kilidi açın.

### Bir şey ters giderse

| Mesaj | Neden ve çözüm |
|---|---|
| `redirect_uri_mismatch` | Eklentinin yönlendirme adresi Web application istemcisine henüz eklenmemiş (7. ve 8. adım) ya da birkaç dakika önce eklendi: bekleyip tekrar deneyin. |
| `invalid_client` | Yapılandırma dosyasındaki Client ID ya da secret yanlış veya başka türde bir istemciye ait. |
| `access_denied` / "Google doğrulama sürecini tamamlamadı" | Uygulama hâlâ **Testing** durumunda (2.6. adım) ya da hesabınız test kullanıcısı değil. |
| Android: giriş penceresi hemen kapanıyor, bir şey olmuyor | Android istemcisinin paket adı ya da SHA-1'i kurduğunuz build'le eşleşmiyor (5. adım) ya da `googleWebClientId` boş. |
| Firefox/Edge 7 gün sonra yeniden bağlanmak istiyor | Uygulama hâlâ **Testing** durumunda (2.6. adım). |
| Chrome: "OAuth2 request failed" / "bad client id" | Manifest'teki `oauth2.client_id`, bu eklentinin kimliği için oluşturulmuş bir **Chrome Extension** istemcisi değil (9. adım). |

Her kullanıcı kendi Google hesabıyla giriş yapar. Kasa o hesabın gizli uygulama klasörüne (`drive.appdata`) şifreli olarak gider; Google projesinin sahibi olarak siz bile onu okuyamazsınız.
