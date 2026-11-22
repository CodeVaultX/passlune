# Building Passlune

[Türkçe](#türkçe)

## What is where

| Folder | Contents |
|---|---|
| `lib/` | The Flutter app (Android and Windows): vault, sync, autofill screens |
| `android/app/src/main/kotlin/` | Android autofill service and Keystore-encrypted queue |
| `windows/runner/` | Windows window, private clipboard, notification-area icon |
| `extension/chrome/` | Browser extension for Chrome and Edge (plain JavaScript, no bundler) |
| `extension/firefox/` | Firefox build; shared files are copied from `chrome/` by `extension/tools/sync-shared.js` |
| `test/`, `integration_test/` | Unit, widget and end-to-end tests |

The vault file (`vault.kasa`) holds only a salt, a nonce and AES-256-GCM ciphertext. The key comes from the master password through Argon2id (19 MiB, 2 iterations) and is never written to disk. The app, the extensions and every device read the same file.

## App (Android and Windows)

Needs the Flutter SDK (stable), and for Android the Android SDK with JDK 17, for Windows Visual Studio with "Desktop development with C++".

```bash
flutter pub get
flutter test
flutter run -d windows        # or an Android device
```

Release builds:

```bash
flutter build appbundle --release --obfuscate --split-debug-info=build/symbols
flutter build apk --release --obfuscate --split-debug-info=build/symbols
flutter build windows --release --obfuscate --split-debug-info=build/symbols
```

`tools/build-release.ps1 [-Windows]` runs these and keeps each version's symbols in `release-symbols/<version>/`. Android release builds need `android/key.properties` (never committed):

```properties
storeFile=C:/path/to/upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

If you publish your own build, change the application ID (`app.passlune` in `android/app/build.gradle.kts`), the name and the icon.

## Browser extensions

`extension/chrome` is the source; after changing a shared file run `node extension/tools/sync-shared.js` to copy it to `extension/firefox`. Load the folder unpacked (Chrome/Edge: `chrome://extensions` → Developer mode → Load unpacked; Firefox: `about:debugging` → Load Temporary Add-on). `extension/SOURCE_BUILD.md` explains the two generated files.

## Google Drive sync (optional)

The Google sign-in clients of the official builds are not in this repository. Without your own, the app hides Drive sync and can still sync through a folder; the browser extensions need Drive. [GOOGLE_SETUP.md](GOOGLE_SETUP.md) shows step by step how to create your own free Google Cloud project for Android, Windows, Chrome, Edge and Firefox.

---

## Türkçe

### Ne nerede

- `lib/`: Flutter uygulaması (Android ve Windows).
- `android/app/src/main/kotlin/`: Android otomatik doldurma hizmeti.
- `windows/runner/`: Windows penceresi, gizli pano, bildirim alanı simgesi.
- `extension/chrome/`: Chrome ve Edge eklentisi (düz JavaScript). `extension/firefox/` için ortak dosyalar `extension/tools/sync-shared.js` ile kopyalanır.
- `test/`, `integration_test/`: testler.

Kasa dosyası (`vault.kasa`) yalnızca salt, nonce ve AES-256-GCM şifreli veri tutar. Anahtar ana şifreden Argon2id ile türetilir ve diske yazılmaz.

### Uygulama

Flutter SDK (stable); Android için Android SDK ve JDK 17, Windows için Visual Studio "Desktop development with C++" gerekir. Komutlar yukarıdaki İngilizce bölümle aynıdır. Android release build'i, git'e girmeyen `android/key.properties` dosyası olmadan durur. Kendi build'inizi yayınlayacaksanız uygulama kimliğini (`app.passlune`), adı ve simgeyi değiştirin.

### Google Drive senkronu (isteğe bağlı)

Resmi sürümlerin Google giriş istemcileri bu depoda yoktur. Kendi istemcileriniz olmadan uygulama Drive senkronunu gizler, klasör üzerinden senkron yine çalışır; tarayıcı eklentileri ise Drive gerektirir. Android, Windows, Chrome, Edge ve Firefox için ücretsiz Google Cloud projenizi nasıl kuracağınız [GOOGLE_SETUP.md](GOOGLE_SETUP.md#türkçe) dosyasında adım adım anlatılıyor.
