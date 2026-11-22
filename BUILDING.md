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

The official builds use OAuth clients of our Google Cloud project; they are not in this repository. Without your own, the app hides Drive sync and can sync through a folder instead (Dropbox, OneDrive, Syncthing, ...). The extensions sync only through Drive, so they need a project of yours.

1. Create a project at https://console.cloud.google.com and enable the **Google Drive API**.
2. **Google Auth Platform**: set the app name, support e-mail, home page and privacy policy link; add the scope `https://www.googleapis.com/auth/drive.appdata` (non-sensitive); publish the app to "In production".
3. Create the clients you need:
   - **Android**: your application ID and the SHA-1 of your signing key (`keytool -list -v -keystore <keystore> -alias <alias>`).
   - **Web application**: Android uses its client ID as `serverClientId`; the Firefox and Edge extensions sign in with its ID and secret. Add each extension's redirect address (the popup shows it when sign-in fails) as an authorized redirect URI.
   - **Desktop app** (Windows): client ID and secret.
   - **Chrome Extension** (Chrome): your extension's item ID.
4. Put them in `lib/config.dart`, `extension/chrome/lib/config.js`, `extension/firefox/lib/config.js` and `oauth2.client_id` in `extension/chrome/manifest.json`.

Every user signs in with their own Google account; the vault goes to that account's hidden app folder (`drive.appdata`), still encrypted.

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

Resmi sürümlerin Google istemci kimlikleri bu depoda yoktur. Kendi kimlikleriniz olmadan uygulama Drive senkronunu gizler ve klasör üzerinden senkron (Dropbox, OneDrive, Syncthing...) kullanılabilir. Eklentiler yalnızca Drive ile senkron yaptığı için kendi Google projenizi gerektirir. Adımlar yukarıdaki İngilizce bölümdedir: Drive API'yi açın, `drive.appdata` kapsamını ekleyin, Android, Web application, Desktop app ve Chrome Extension istemcilerini oluşturup kimlikleri `lib/config.dart`, iki `config.js` dosyası ve Chrome `manifest.json` içine yazın.
