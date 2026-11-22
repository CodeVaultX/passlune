import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'dpapi.dart';
import 'sync_backend.dart';
import 'l10n.dart';

const _scope = 'https://www.googleapis.com/auth/drive.appdata';

/// Longest one Google request may take. A stalled connection (weak mobile
/// signal, a captive portal) used to never finish, and the sync it belonged
/// to stayed "running" until the app was restarted.
const _requestTimeout = Duration(seconds: 30);

Future<http.Response> _send(Future<http.Response> request) => request.timeout(
      _requestTimeout,
      onTimeout: () => throw DriveException(t('Google yanıt vermedi; internet bağlantını kontrol edip tekrar dene.',
          'Google did not respond; check your connection and try again.')),
    );

class DriveException implements Exception {
  final String message;
  DriveException(this.message);
  @override
  String toString() => message;
}

/// Google refused the stored sign-in for good (revoked, expired): it has been
/// forgotten, and only connecting again brings sync back.
class DriveSignInLost extends DriveException {
  DriveSignInLost(super.message);
}

/// Source of OAuth access tokens for the Drive appDataFolder scope.
abstract class DriveAuth {
  /// Signs in interactively (browser / account picker).
  Future<void> signIn();

  /// A valid access token; requires a previous [signIn].
  Future<String> accessToken();

  Future<void> signOut();
}

class AndroidDriveAuth implements DriveAuth {
  static bool _initialized = false;

  Future<void> _init() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(serverClientId: googleWebClientId);
    _initialized = true;
  }

  @override
  Future<void> signIn() async {
    await _init();
    await GoogleSignIn.instance.authenticate(scopeHint: const [_scope]);
    await accessToken();
  }

  @override
  Future<String> accessToken() async {
    await _init();
    final client = GoogleSignIn.instance.authorizationClient;
    final authz = await client.authorizationForScopes(const [_scope]) ??
        await client.authorizeScopes(const [_scope]);
    return authz.accessToken;
  }

  @override
  Future<void> signOut() async {
    await _init();
    await GoogleSignIn.instance.signOut();
  }
}

/// Desktop OAuth: system browser + loopback redirect + PKCE. The refresh
/// token only grants access to this app's hidden Drive folder (ciphertext),
/// but it's still a credential: on Windows it's sealed with DPAPI (tied to the
/// Windows user account), so a copy of the file is useless elsewhere.
class DesktopDriveAuth implements DriveAuth {
  String? _access;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// Plain-text JSON: what versions before 1.1 used everywhere, and still
  /// the store on non-Windows desktops.
  static Future<File> _plainTokenFile() => _file('drive_token.json');

  /// DPAPI-sealed token (Windows).
  static Future<File> _sealedTokenFile() => _file('drive_token.dpapi');

  static Future<String?> _readRefreshToken() async {
    if (Platform.isWindows) {
      final sealed = await _sealedTokenFile();
      if (await sealed.exists()) {
        return utf8.decode(dpapiUnprotect(await sealed.readAsBytes()));
      }
    }
    final plain = await _plainTokenFile();
    if (!await plain.exists()) return null;
    final token =
        (jsonDecode(await plain.readAsString()) as Map)['refresh_token'] as String?;
    if (token != null && Platform.isWindows) {
      // Left by an older version: seal it and remove the plain copy.
      await _writeRefreshToken(token);
    }
    return token;
  }

  static Future<void> _writeRefreshToken(String token) async {
    final plain = await _plainTokenFile();
    if (Platform.isWindows) {
      await (await _sealedTokenFile())
          .writeAsBytes(dpapiProtect(Uint8List.fromList(utf8.encode(token))), flush: true);
      if (await plain.exists()) await plain.delete();
    } else {
      await plain.writeAsString(jsonEncode({'refresh_token': token}));
    }
  }

  static Future<void> _deleteRefreshToken() async {
    for (final f in [await _plainTokenFile(), await _sealedTokenFile()]) {
      if (await f.exists()) await f.delete();
    }
  }

  static String _b64url(List<int> b) =>
      base64UrlEncode(b).replaceAll('=', '');

  static String _random(int n) {
    final r = Random.secure();
    return _b64url(List<int>.generate(n, (_) => r.nextInt(256)));
  }

  @override
  Future<void> signIn() async {
    final verifier = _random(48);
    final challenge =
        _b64url((await Sha256().hash(utf8.encode(verifier))).bytes);
    final state = _random(16);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    try {
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': googleDesktopClientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': _scope,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
      });
      await launchUrl(url, mode: LaunchMode.externalApplication);

      final req = await server.first.timeout(const Duration(minutes: 3));
      final q = req.uri.queryParameters;
      req.response
        ..headers.contentType = ContentType.html
        ..write(t('<html><body style="font-family:sans-serif">'
            'Giriş tamamlandı. Bu sekmeyi kapatıp uygulamaya dönebilirsiniz.'
            '</body></html>', '<html><body style="font-family:sans-serif">Signed in. You can close this tab and return to the app.</body></html>'));
      await req.response.close();

      if (q['state'] != state || q['code'] == null) {
        throw DriveException(t('Google girişi iptal edildi.', 'Google sign-in was cancelled.'));
      }
      final res = await _send(http.post(
        Uri.https('oauth2.googleapis.com', '/token'),
        body: {
          'code': q['code']!,
          'client_id': googleDesktopClientId,
          'client_secret': googleDesktopClientSecret,
          'redirect_uri': redirect,
          'grant_type': 'authorization_code',
          'code_verifier': verifier,
        },
      ));
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode != 200 || j['refresh_token'] == null) {
        throw DriveException(t('Google token alınamadı: ${j['error'] ?? res.statusCode}', 'Couldn\'t get a Google token: ${j['error'] ?? res.statusCode}'));
      }
      await _writeRefreshToken(j['refresh_token'] as String);
      _store(j);
    } on TimeoutException {
      throw DriveException(t('Google girişi zaman aşımına uğradı.', 'Google sign-in timed out.'));
    } finally {
      await server.close(force: true);
    }
  }

  void _store(Map<String, dynamic> j) {
    _access = j['access_token'] as String;
    _expires = DateTime.now()
        .add(Duration(seconds: (j['expires_in'] as int) - 60));
  }

  @override
  Future<String> accessToken() async {
    if (_access != null && DateTime.now().isBefore(_expires)) return _access!;
    final refresh = await _readRefreshToken();
    if (refresh == null) throw DriveException(t('Google hesabı bağlı değil.', 'No Google account connected.'));
    final res = await _send(http.post(
      Uri.https('oauth2.googleapis.com', '/token'),
      body: {
        'client_id': googleDesktopClientId,
        'client_secret': googleDesktopClientSecret,
        'refresh_token': refresh,
        'grant_type': 'refresh_token',
      },
    ));
    Map<String, dynamic> j;
    try {
      j = jsonDecode(res.body) as Map<String, dynamic>;
    } on FormatException {
      j = const {}; // a captive portal's page, a proxy error, ...
    }
    if (res.statusCode != 200) {
      final code = j['error'] ?? res.statusCode;
      if (code == 'invalid_grant') {
        // Revoked or expired for good: retrying it can never work.
        await _deleteRefreshToken();
        throw DriveSignInLost(t('Google oturumu sona erdi; Drive senkronu durdu. Ayarlar → "Google Drive ile senkronize et" ile yeniden bağlan. ($code)',
            'The Google sign-in expired and Drive sync stopped. Connect again in Settings → "Sync with Google Drive". ($code)'));
      }
      throw DriveException(t('Oturum yenilenemedi, Drive\'a yeniden bağlanın. ($code)', 'Session couldn\'t be renewed; reconnect to Drive. ($code)'));
    }
    _store(j);
    return _access!;
  }

  @override
  Future<void> signOut() async {
    _access = null;
    await _deleteRefreshToken();
  }
}

/// Stores one file, `vault.kasa`, in the app's hidden appDataFolder. Needs a
/// Google Cloud project of your own (see README); a public build without
/// one simply leaves [SyncService.configured] false.
class DriveClient implements SyncBackend {
  static const _name = 'vault.kasa';
  final DriveAuth auth;
  DriveClient(this.auth);

  @override
  String get label => 'Google Drive';

  Future<Map<String, String>> _headers() async =>
      {'Authorization': 'Bearer ${await auth.accessToken()}'};

  void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw DriveException(t('Drive hatası (${r.statusCode}).', 'Drive error (${r.statusCode}).'));
  }

  Future<String?> _findId() async {
    final r = await _send(http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files', {
        'spaces': 'appDataFolder',
        'q': "name = '$_name'",
        'fields': 'files(id)',
      }),
      headers: await _headers(),
    ));
    _check(r);
    final files = (jsonDecode(r.body) as Map)['files'] as List;
    return files.isEmpty ? null : (files.first as Map)['id'] as String;
  }

  @override
  Future<List<int>?> download() async {
    final id = await _findId();
    if (id == null) return null;
    final r = await _send(http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}),
      headers: await _headers(),
    ));
    _check(r);
    return r.bodyBytes;
  }

  @override
  Future<void> upload(List<int> bytes) async {
    final id = await _findId();
    final headers = await _headers();
    if (id != null) {
      final r = await _send(http.patch(
        Uri.https('www.googleapis.com', '/upload/drive/v3/files/$id',
            {'uploadType': 'media'}),
        headers: {...headers, 'Content-Type': 'application/octet-stream'},
        body: bytes,
      ));
      _check(r);
      return;
    }
    const boundary = 'kasa-boundary-7f3a9c';
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode({'name': _name, 'parents': ['appDataFolder']})}\r\n'
          '--$boundary\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    final r = await _send(http.post(
      Uri.https('www.googleapis.com', '/upload/drive/v3/files',
          {'uploadType': 'multipart'}),
      headers: {...headers, 'Content-Type': 'multipart/related; boundary=$boundary'},
      body: body.toBytes(),
    ));
    _check(r);
  }

  /// Voicelune used this Google project before it got its own, so its books
  /// and library files sit in the same hidden folder as the vault. Only the
  /// names Voicelune wrote match; the vault and anything else stay.
  static final _oldVoiceluneFile = RegExp(r'^(library\.json|rules\.json|premium\.json'
      r'|book_[0-9a-f]{32}\.[a-z0-9]{2,5}|tr_[0-9a-f]{32}_[a-z]{2,3}_[A-Za-z0-9._-]+\.json)$');

  static bool isOldVoiceluneFile(String name) => name != _name && _oldVoiceluneFile.hasMatch(name);

  /// Deletes Voicelune's old files from the hidden folder; returns how many.
  Future<int> dropOldVoiceluneFiles() async {
    final ids = <String>[];
    String? page;
    do {
      final r = await _send(http.get(
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'fields': 'nextPageToken,files(id,name)',
          'pageSize': '1000',
          'pageToken': ?page,
        }),
        headers: await _headers(),
      ));
      _check(r);
      final j = jsonDecode(r.body) as Map;
      for (final f in (j['files'] as List).cast<Map>()) {
        if (isOldVoiceluneFile(f['name'] as String)) ids.add(f['id'] as String);
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    for (final id in ids) {
      final r = await _send(http.delete(Uri.https('www.googleapis.com', '/drive/v3/files/$id'), headers: await _headers()));
      if (r.statusCode != 404) _check(r);
    }
    return ids.length;
  }
}

/// Whether the Google Drive API sync is configured (i.e. whoever built this
/// app put their own OAuth client IDs in lib/config.dart) and connected.
/// This is the "advanced" sync option; the "Senkron klasör" option in
/// [FolderSyncService] needs none of this and works in every public build.
class SyncService {
  static final SyncService instance = SyncService._();
  SyncService._();

  final DriveAuth _auth =
      Platform.isAndroid ? AndroidDriveAuth() : DesktopDriveAuth();
  late final DriveClient client = DriveClient(_auth);

  bool get configured => Platform.isAndroid
      ? googleWebClientId.isNotEmpty
      : googleDesktopClientId.isNotEmpty && googleDesktopClientSecret.isNotEmpty;

  static Future<File> _marker() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}sync.on');
  }

  Future<bool> isEnabled() async => configured && await (await _marker()).exists();

  Future<void> connect() async {
    await _auth.signIn();
    await (await _marker()).writeAsString('1');
  }

  Future<void> disconnect() async {
    await _auth.signOut();
    final m = await _marker();
    if (await m.exists()) await m.delete();
  }

  /// Runs [DriveClient.dropOldVoiceluneFiles] once per device, after a sync
  /// that worked; a failure just means it tries again next time.
  Future<void> cleanUpOnce() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final done = File('${dir.path}${Platform.pathSeparator}voicelune_cleanup.done');
      if (await done.exists()) return;
      await client.dropOldVoiceluneFiles();
      await done.writeAsString('1');
    } catch (_) {}
  }
}

/// Remembers which local folder (typically inside Dropbox, OneDrive, Google
/// Drive for Desktop, or a Syncthing share) the vault syncs through. Works
/// with any provider identically because it never talks to a cloud API —
/// the provider's own app watches the folder and uploads/downloads for us.
class FolderSyncService {
  static final FolderSyncService instance = FolderSyncService._();
  FolderSyncService._();

  static Future<File> _pointerFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}sync_folder.txt');
  }

  Future<String?> folder() async {
    final f = await _pointerFile();
    if (!await f.exists()) return null;
    final p = (await f.readAsString()).trim();
    return p.isEmpty ? null : p;
  }

  Future<FolderBackend?> backend() async {
    final p = await folder();
    return p == null ? null : FolderBackend(p);
  }

  Future<void> setFolder(String path) async {
    await (await _pointerFile()).writeAsString(path);
  }

  Future<void> clear() async {
    final f = await _pointerFile();
    if (await f.exists()) await f.delete();
  }
}
