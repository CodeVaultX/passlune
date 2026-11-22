import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/sync_backend.dart';
import 'package:passlune/vault.dart';

class _Memory implements SyncBackend {
  List<int>? bytes;
  @override
  Future<List<int>?> download() async => bytes;
  @override
  Future<void> upload(List<int> b) async => bytes = List.of(b);
  @override
  String get label => 'mem';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    final tmp = Directory.systemTemp.createTempSync('vault_sync');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
  });

  test('changing the master password re-encrypts the synced copy', () async {
    final drive = _Memory();
    final a = Vault();
    await a.create('eski-sifre-12345');
    await a.upsert(Entry(id: newId(), site: 'github.com', username: 'u', password: 'p'));
    await a.sync(drive);

    await a.changePassword('eski-sifre-12345', 'yeni-sifre-67890');
    await a.sync(drive); // used to throw SyncPasswordMismatch forever

    // Another device can now open the synced copy with the new password only.
    await Vault.installRemote(drive.bytes!);
    final b = Vault();
    await expectLater(b.unlock('eski-sifre-12345'), throwsA(isA<WrongPasswordException>()));
    await b.unlock('yeni-sifre-67890');
    expect(b.entries.single.site, 'github.com');
  });

  test('a password changed on another device spreads instead of being undone', () async {
    // Each "device" keeps its vault file in its own folder.
    final dirA = Directory.systemTemp.createTempSync('dev_a'), dirB = Directory.systemTemp.createTempSync('dev_b');
    void on(Directory d) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => d.path);

    final drive = _Memory();
    on(dirA);
    final a = Vault();
    await a.create('eski-sifre-12345');
    await a.upsert(Entry(id: newId(), site: 'github.com', username: 'u', password: 'p'));
    await a.sync(drive);

    on(dirB);
    await Vault.installRemote(drive.bytes!);
    final b = Vault();
    await b.unlock('eski-sifre-12345');

    // A changes the master password and syncs.
    on(dirA);
    await a.changePassword('eski-sifre-12345', 'yeni-sifre-67890');
    await a.sync(drive);

    // B still has the old one: asked for the synced copy's password, it
    // takes over the new password instead of re-encrypting with the old.
    on(dirB);
    await expectLater(b.sync(drive), throwsA(isA<SyncPasswordMismatch>()));
    await b.sync(drive, remotePassword: 'yeni-sifre-67890');
    await b.sync(drive); // in step now, no prompt
    b.lock();
    await expectLater(b.unlock('eski-sifre-12345'), throwsA(isA<WrongPasswordException>()));
    await b.unlock('yeni-sifre-67890');

    // The synced copy is still under the new password, and A syncs without a prompt.
    final dirC = Directory.systemTemp.createTempSync('dev_c');
    on(dirC);
    await Vault.installRemote(drive.bytes!);
    await expectLater(Vault().unlock('eski-sifre-12345'), throwsA(isA<WrongPasswordException>()));
    on(dirA);
    await a.sync(drive);
  });

  test('saves at the same moment all end up in the file', () async {
    final a = Vault();
    await a.create('eski-sifre-12345');
    await Future.wait([
      for (var i = 0; i < 5; i++) a.upsert(Entry(id: newId(), site: 's$i.com', username: 'u', password: 'p')),
    ]);
    a.lock();
    await a.unlock('eski-sifre-12345');
    expect(a.entries.length, 5);
  });

  test('a save by the autofill screen is taken in, not overwritten', () async {
    final app = Vault();
    await app.create('eski-sifre-12345');
    await app.upsert(Entry(id: newId(), site: 'github.com', username: 'u', password: 'p'));
    // The fill screen opens its own Vault on the same file and tags an entry.
    final fill = Vault();
    await fill.unlock('eski-sifre-12345');
    final e = fill.entries.single..notes = 'Android: com.github.android';
    await fill.upsert(e);

    await app.reloadFromDisk();
    expect(app.entries.single.notes, 'Android: com.github.android');
    await app.upsert(Entry(id: newId(), site: 'gitlab.com', username: 'u', password: 'p'));
    final check = Vault();
    await check.unlock('eski-sifre-12345');
    expect(check.entries.map((e) => e.notes), contains('Android: com.github.android'));
  });

  test('after a restart the old password can be supplied to finish the sync', () async {
    final drive = _Memory();
    final a = Vault();
    await a.create('eski-sifre-12345');
    await a.sync(drive);
    await a.changePassword('eski-sifre-12345', 'yeni-sifre-67890');
    a.lock(); // app restarted before it could sync
    await a.unlock('yeni-sifre-67890');
    await expectLater(a.sync(drive), throwsA(isA<SyncPasswordMismatch>()));
    await a.sync(drive, remotePassword: 'eski-sifre-12345');
    await a.sync(drive); // now in step, no prompt needed
  });
}
