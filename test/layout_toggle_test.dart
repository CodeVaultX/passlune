import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/main.dart';
import 'package:passlune/theme.dart';
import 'package:passlune/vault.dart';

void main() {
  testWidgets('list/grid switch updates the screen at once', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('kasa_toggle');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
    final vault = Vault();
    await tester.runAsync(() async {
      await vault.create('toggle-test-password');
      await vault.upsert(Entry(id: newId(), site: 'github.com', username: 'u', password: 'gH#8v!q2LmZ@x9Rt'));
    });
    UiPrefs.instance.grid = false;
    await tester.pumpWidget(MaterialApp(theme: buildTheme(UiPrefs.instance.palette), home: HomePage(vault: vault, onLock: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byType(SliverGrid), findsNothing);
    await tester.tap(find.byIcon(Icons.grid_view));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byType(SliverGrid), findsOneWidget);
    await tester.tap(find.byIcon(Icons.view_agenda_outlined));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byType(SliverGrid), findsNothing);
  });
}
