import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:path_provider/path_provider.dart';

import 'sync_backend.dart';
import 'l10n.dart';

class Entry {
  String id;
  String site;
  String username;
  String password;
  String notes;

  /// Category id (see insights.dart); empty = guessed from the site.
  String category;

  /// Milliseconds since epoch of the last change. Drives conflict resolution
  /// when two devices edit the same entry.
  int updatedAt;

  /// Tombstone: a deleted entry is kept (emptied) so the deletion syncs to
  /// other devices instead of the entry reappearing.
  bool deleted;

  Entry({
    required this.id,
    required this.site,
    required this.username,
    required this.password,
    this.notes = '',
    this.category = '',
    this.updatedAt = 0,
    this.deleted = false,
  });

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'] as String,
        site: j['site'] as String,
        username: j['username'] as String,
        password: j['password'] as String,
        notes: (j['notes'] ?? '') as String,
        category: (j['category'] ?? '') as String,
        updatedAt: (j['updatedAt'] ?? 0) as int,
        deleted: (j['deleted'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'site': site,
        'username': username,
        'password': password,
        'notes': notes,
        if (category.isNotEmpty) 'category': category,
        'updatedAt': updatedAt,
        'deleted': deleted,
      };
}

class WrongPasswordException implements Exception {}

class CorruptVaultException implements Exception {}

/// The Drive copy is encrypted with a different master password.
class SyncPasswordMismatch implements Exception {}

/// Encrypted vault. The key is derived from the master password with
/// Argon2id and never written to disk; the file holds only salt, nonce and
/// AES-256-GCM ciphertext. A wrong password simply fails GCM authentication.
class Vault {
  static const _fileName = 'vault.kasa';
  static const _memoryKiB = 19456;
  static const _iterations = 2;
  static const _parallelism = 1;

  final _aes = AesGcm.with256bits();

  List<Entry> _all = [];
  List<int>? _salt;
  SecretKey? _key;

  /// Kept only while unlocked, to derive the key of a Drive copy that uses a
  /// different salt.
  String? _password;

  /// Called after a local change so the UI can trigger a sync.
  void Function()? onChanged;

  bool get isUnlocked => _key != null;

  List<Entry> get entries => _all.where((e) => !e.deleted).toList();

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  static Future<bool> exists() async => (await _file()).exists();

  /// The copy every save keeps of the file it replaces.
  static Future<File> _backupFile() async => File('${(await _file()).path}.bak');

  static Future<bool> hasBackup() async => (await _backupFile()).exists();

  /// Installs a vault file downloaded from Drive on a fresh device.
  static Future<void> installRemote(List<int> bytes) async {
    final file = await _file();
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<SecretKey> _derive(String password, List<int> salt) {
    // Run in a separate isolate so the UI does not freeze.
    return Isolate.run(() async {
      final kdf = Argon2id(
        memory: _memoryKiB,
        iterations: _iterations,
        parallelism: _parallelism,
        hashLength: 32,
      );
      final key = await kdf.deriveKeyFromPassword(
        password: password,
        nonce: salt,
      );
      return SecretKey(await key.extractBytes());
    });
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> create(String password) async {
    _salt = _randomBytes(16);
    _key = await _derive(password, _salt!);
    _password = password;
    _all = [];
    await save();
  }

  Future<void> unlock(String password) async {
    final file = await _file();
    final data = await _readBlob(await file.readAsBytes());
    final key = await _derive(password, data.salt);
    _all = await _decrypt(data, key);
    _salt = data.salt;
    _key = key;
    _password = password;
  }

  /// For a vault file that can't be read (damaged, cut short): opens the
  /// copy kept by the save before it, with the same master password, and
  /// puts that copy back in place. At most the last change is lost, and a
  /// sync brings back whatever reached the synced copy. The unreadable file
  /// is kept beside it as vault.kasa.damaged.
  Future<void> unlockFromBackup(String password) async {
    final file = await _file();
    final backup = await _backupFile();
    final data = await _readBlob(await backup.readAsBytes());
    final key = await _derive(password, data.salt);
    final entries = await _decrypt(data, key);
    if (await file.exists()) await file.rename('${file.path}.damaged');
    await backup.copy(file.path);
    _all = entries;
    _salt = data.salt;
    _key = key;
    _password = password;
  }

  Future<void> changePassword(String current, String next) async {
    final file = await _file();
    final data = await _readBlob(await file.readAsBytes());
    await _decrypt(data, await _derive(current, data.salt)); // verify
    _salt = _randomBytes(16);
    _key = await _derive(next, _salt!);
    // The synced copy is still under the old password until the next sync
    // re-encrypts it; keep the old one (in memory only) to open it.
    _previousPassword = current;
    _password = next;
    await save();
    // The save kept the file it replaced, still under the old password, as
    // the backup: replace that too, so the old password opens nothing here
    // and the backup opens with the password the user now knows.
    await file.copy((await _backupFile()).path);
    onChanged?.call();
  }

  String? _previousPassword;

  void lock() {
    _key = null;
    _salt = null;
    _password = null;
    _previousPassword = null;
    _all = [];
  }

  /// Adds or updates an entry (same id replaces).
  Future<void> upsert(Entry e) async {
    e.updatedAt = _now();
    e.deleted = false;
    final i = _all.indexWhere((x) => x.id == e.id);
    i >= 0 ? _all[i] = e : _all.add(e);
    await save();
    onChanged?.call();
  }

  /// Adds new entries with a single save and a single sync (an import).
  Future<void> addAll(Iterable<Entry> list) async {
    final now = _now();
    for (final e in list) {
      e
        ..updatedAt = now
        ..deleted = false;
      _all.add(e);
    }
    await save();
    onChanged?.call();
  }

  Future<void> remove(String id) async {
    final i = _all.indexWhere((x) => x.id == id);
    if (i < 0) return;
    _all[i]
      ..site = ''
      ..username = ''
      ..password = ''
      ..notes = ''
      ..category = ''
      ..deleted = true
      ..updatedAt = _now();
    await save();
    onChanged?.call();
  }

  /// Saves run one after another: an autofill import and a sync finishing at
  /// the same moment must not interleave their writes into one file.
  /// null when idle: a ready-made Future.value() would belong to the zone the
  /// Vault was created in, and chaining onto it from another zone can stall.
  Future<void>? _saving;

  Future<void> save() async {
    while (_saving != null) {
      try {
        await _saving;
      } catch (_) {
        // that save's caller handles its error
      }
    }
    final run = _saveNow();
    _saving = run;
    try {
      await run;
    } finally {
      if (identical(_saving, run)) _saving = null;
    }
  }

  Future<void> _saveNow() async {
    final blob = await _encrypt(_all, _key!, _salt!);
    final file = await _file();
    if (await file.exists()) {
      await file.copy((await _backupFile()).path);
    }
    // Unique name: the autofill screen runs its own Vault in another engine.
    final tmp = File('${file.path}.${_now()}${Random().nextInt(1 << 30)}.tmp');
    await tmp.writeAsBytes(blob, flush: true);
    await tmp.rename(file.path);
  }

  /// Takes in changes another part of the app (the autofill fill screen)
  /// saved to the vault file while this one stayed unlocked: newer entries
  /// win, as in a sync. Only when the file is still under this key.
  Future<void> reloadFromDisk() async {
    if (_key == null) return;
    try {
      final data = await _readBlob(await (await _file()).readAsBytes());
      if (!listEquals(data.salt, _salt)) return;
      _mergeIn(await _decrypt(data, _key!));
    } catch (_) {
      // Unreadable or another key: keep what is in memory.
    }
  }

  /// Encrypted backup: same format as the vault file.
  Future<List<int>> exportBackup() => _encrypt(_all, _key!, _salt!);

  /// Merges a backup into the vault. Needs the backup's own password.
  Future<int> importBackup(List<int> bytes, String backupPassword) async {
    final data = await _readBlob(bytes);
    final imported =
        await _decrypt(data, await _derive(backupPassword, data.salt));
    _mergeIn(imported);
    await save();
    onChanged?.call();
    return imported.where((e) => !e.deleted).length;
  }

  /// Newer `updatedAt` wins per entry. Returns true if local data changed.
  bool _mergeIn(List<Entry> incoming) {
    var changed = false;
    for (final r in incoming) {
      final i = _all.indexWhere((x) => x.id == r.id);
      if (i < 0) {
        _all.add(r);
        changed = true;
      } else if (r.updatedAt > _all[i].updatedAt) {
        _all[i] = r;
        changed = true;
      }
    }
    return changed;
  }

  /// True if local has anything the remote copy lacks or has older.
  bool _localIsAhead(List<Entry> remote) {
    final byId = {for (final r in remote) r.id: r};
    return _all.any((l) {
      final r = byId[l.id];
      return r == null || l.updatedAt > r.updatedAt;
    });
  }

  /// Two-way sync with the encrypted copy held by [backend] — Google Drive
  /// via its API, or a plain folder some other app (Dropbox, OneDrive,
  /// Google Drive for Desktop, Syncthing, ...) keeps in sync. Only
  /// ciphertext ever leaves the device. Returns a short status message.
  /// [remotePassword]: the password the synced copy was encrypted with, when
  /// it differs from this device's (e.g. the master password was changed
  /// here while offline and the app restarted before syncing).
  Future<String> sync(SyncBackend backend, {String? remotePassword}) async {
    final remoteBytes = await backend.download();
    if (remoteBytes == null) {
      await backend.upload(await _encrypt(_all, _key!, _salt!));
      return t('${backend.label} adresine yüklendi', 'Uploaded to ${backend.label}');
    }
    final blob = await _readBlob(remoteBytes);
    final sameSalt = listEquals(blob.salt, _salt);
    List<Entry>? remote;
    // Which password opened the synced copy decides which key wins:
    // - the password this device had before changing it: this device's new
    //   password wins, the copy is re-encrypted with it;
    // - this device's own password (same password, other salt) or the one
    //   the user typed for the synced copy (changed on another device): this
    //   device takes over the copy's salt and key, so a new password spreads
    //   instead of being overwritten by the old one, and two devices don't
    //   keep re-encrypting each other's copy.
    var adopted = false;
    var passwordChanged = false;
    if (sameSalt) {
      try {
        remote = await _decrypt(blob, _key!);
      } on WrongPasswordException {
        throw SyncPasswordMismatch();
      }
    } else {
      for (final pw in {_password, _previousPassword, remotePassword}.whereType<String>()) {
        try {
          final key = await _derive(pw, blob.salt);
          remote = await _decrypt(blob, key);
          if (pw != _previousPassword) {
            passwordChanged = pw != _password;
            _salt = blob.salt;
            _key = key;
            _password = pw;
            adopted = true;
          }
          break;
        } on WrongPasswordException {
          // try the next one
        }
      }
      if (remote == null) throw SyncPasswordMismatch();
    }
    final changedLocal = _mergeIn(remote);
    if (changedLocal || adopted) await save();
    if ((!sameSalt && !adopted) || _localIsAhead(remote)) {
      await backend.upload(await _encrypt(_all, _key!, _salt!));
      if (!adopted) _previousPassword = null;
    }
    if (passwordChanged) {
      _previousPassword = null;
      return t('Ana şifre, diğer cihazında belirlediğin yeni şifreyle güncellendi',
          'Master password updated to the new one set on your other device');
    }
    return changedLocal ? t('${backend.label} adresinden güncellendi', 'Updated from ${backend.label}') : t('Senkron: güncel', 'Sync: up to date');
  }

  Future<List<int>> _encrypt(
      List<Entry> list, SecretKey key, List<int> salt) async {
    final plain = utf8.encode(jsonEncode(list.map((e) => e.toJson()).toList()));
    final box = await _aes.encrypt(plain, secretKey: key, aad: salt);
    return utf8.encode(jsonEncode({
      'v': 1,
      'kdf': 'argon2id',
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'ct': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    }));
  }

  Future<_Blob> _readBlob(List<int> bytes) async {
    try {
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (j['v'] != 1) throw CorruptVaultException();
      return _Blob(
        base64Decode(j['salt'] as String),
        base64Decode(j['nonce'] as String),
        base64Decode(j['ct'] as String),
        base64Decode(j['mac'] as String),
      );
    } on CorruptVaultException {
      rethrow;
    } catch (_) {
      throw CorruptVaultException();
    }
  }

  Future<List<Entry>> _decrypt(_Blob b, SecretKey key) async {
    try {
      final plain = await _aes.decrypt(
        SecretBox(b.ct, nonce: b.nonce, mac: Mac(b.mac)),
        secretKey: key,
        aad: b.salt,
      );
      final list = jsonDecode(utf8.decode(plain)) as List;
      return list
          .map((e) => Entry.fromJson(e as Map<String, dynamic>))
          .toList();
    } on SecretBoxAuthenticationError {
      throw WrongPasswordException();
    } catch (_) {
      throw CorruptVaultException();
    }
  }
}

class _Blob {
  final List<int> salt, nonce, ct, mac;
  _Blob(this.salt, this.nonce, this.ct, this.mac);
}

String generatePassword(int length,
    {bool symbols = true, bool digits = true, bool upper = true}) {
  const lower = 'abcdefghijkmnopqrstuvwxyz';
  final pools = <String>[
    lower,
    if (upper) 'ABCDEFGHJKLMNPQRSTUVWXYZ',
    if (digits) '23456789',
    if (symbols) '!@#\$%^&*()-_=+[]{};:,.?',
  ];
  final r = Random.secure();
  final all = pools.join();
  // Guarantee one char from every selected pool, then fill and shuffle.
  final chars = <String>[
    for (final p in pools) p[r.nextInt(p.length)],
    for (var i = pools.length; i < length; i++) all[r.nextInt(all.length)],
  ]..shuffle(r);
  return chars.take(length).join();
}

String newId() => _randomHex(16);

String _randomHex(int n) {
  final r = Random.secure();
  return List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
}
