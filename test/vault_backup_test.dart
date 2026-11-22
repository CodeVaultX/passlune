import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/main.dart';
import 'package:passlune/vault.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPaths extends PathProviderPlatform {
  final String dir;
  _TempPaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  late Directory dir;
  File vaultFile() => File('${dir.path}${Platform.pathSeparator}vault.kasa');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('vault_backup');
    PathProviderPlatform.instance = _TempPaths(dir.path);
  });

  Entry entry(String site) => Entry(id: newId(), site: site, username: 'u', password: 'p');

  test('a damaged vault file opens from the backup with the same password', () async {
    final v = Vault();
    await v.create('ana-sifre-12345');
    await v.upsert(entry('github.com'));
    await v.upsert(entry('gitlab.com')); // the backup now holds github.com only
    await vaultFile().writeAsString('{"v":1,"salt":"kesik'); // cut short

    final w = Vault();
    await expectLater(w.unlock('ana-sifre-12345'), throwsA(isA<CorruptVaultException>()));
    expect(await Vault.hasBackup(), isTrue);

    await expectLater(w.unlockFromBackup('yanlis-sifre-000'), throwsA(isA<WrongPasswordException>()));
    expect(File('${vaultFile().path}.damaged').existsSync(), isFalse, reason: 'nothing moved on a wrong password');

    await w.unlockFromBackup('ana-sifre-12345');
    expect(w.entries.map((e) => e.site), ['github.com']);
    expect(File('${vaultFile().path}.damaged').existsSync(), isTrue);

    // The restored copy is the vault file again.
    final x = Vault();
    await x.unlock('ana-sifre-12345');
    expect(x.entries.map((e) => e.site), ['github.com']);
  });

  testWidgets('the unlock screen offers the backup when the vault file is damaged', (tester) async {
    await tester.runAsync(() async {
      final v = Vault();
      await v.create('ana-sifre-12345');
      await v.upsert(entry('github.com'));
      await v.upsert(entry('gitlab.com'));
      await vaultFile().writeAsString('bozuk');
    });
    var unlocked = false;
    final vault = Vault();
    await tester.pumpWidget(MaterialApp(home: UnlockPage(vault: vault, onUnlocked: () => unlocked = true)));
    Future<void> settle(bool Function() done) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!done()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    await settle(() => find.byType(TextField).evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField), 'ana-sifre-12345');
    await tester.tap(find.byType(FilledButton));
    await settle(() => find.byIcon(Icons.restore).evaluate().isNotEmpty);

    await tester.tap(find.byIcon(Icons.restore));
    await settle(() => unlocked);
    expect(vault.entries.map((e) => e.site), ['github.com']);
  });

  test('after a password change the backup opens with the new password only', () async {
    final v = Vault();
    await v.create('eski-sifre-12345');
    await v.upsert(entry('github.com'));
    await v.changePassword('eski-sifre-12345', 'yeni-sifre-67890');
    await vaultFile().writeAsString('bozuk');

    final w = Vault();
    await expectLater(w.unlockFromBackup('eski-sifre-12345'), throwsA(isA<WrongPasswordException>()));
    await w.unlockFromBackup('yeni-sifre-67890');
    expect(w.entries.single.site, 'github.com');
  });
}
