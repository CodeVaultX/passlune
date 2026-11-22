// Renders the main screens to PNGs (flutter test --update-goldens
// test/screens_preview_test.dart) so the design can be reviewed without
// running the app. Sample data only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/about.dart';
import 'package:passlune/l10n.dart';
import 'package:passlune/main.dart';
import 'package:passlune/theme.dart';
import 'package:passlune/vault.dart';

Future<void> _font(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  // Opt-in: KASA_PREVIEW=1 flutter test --update-goldens test/screens_preview_test.dart
  if (Platform.environment['KASA_PREVIEW'] == null) return;

  late Directory tmp;
  late Vault vault;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('kasa_preview');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
    const fonts = 'C:/dev/flutter/bin/cache/artifacts/material_fonts';
    await _font('Roboto', ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf']);
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
    vault = Vault();
    await vault.create('preview-password-123');
    final samples = [
      ('github.com', 'dev.ayse', 'gH#8v!q2LmZ@x9Rt', ''),
      ('accounts.google.com', 'ayse.demir@gmail.com', 'Pazartesi2024!', ''),
      ('garanti.com.tr', '12345678', 'Pazartesi2024!', 'bank'),
      ('netflix.com', 'ayse.demir@gmail.com', 'netflix123', ''),
      ('instagram.com', 'ayse.dmr', 'Kedi-Balik-Ay-77', ''),
      ('trendyol.com', 'ayse.demir@gmail.com', 'T8&kq2!Vz#Lp4Wn6', ''),
      ('Ev Wi-Fi', 'EvAgi_5G', 'super-uzun-ev-sifresi-2026', 'wifi'),
      ('Pasaport bilgileri', '', '', 'note'),
    ];
    for (final (site, user, pw, cat) in samples) {
      await vault.upsert(Entry(id: newId(), site: site, username: user, password: pw, category: cat));
    }
  });

  for (final p in [palettes[0], palettes[1], palettes[3], palettes.last]) {
    testWidgets('home ${p.id}', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      UiPrefs.instance.palette = p;
      UiPrefs.instance.grid = p.id == 'amethyst';
      applyUiLang(p.id == 'ocean' ? 'en' : 'tr');
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(p),
        home: HomePage(vault: vault, onLock: () {}),
      ));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      await expectLater(find.byType(HomePage), matchesGoldenFile('preview/home_${p.id}.png'));
    });
  }

  testWidgets('unlock', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    final p = palettes[0];
    UiPrefs.instance.palette = p;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(p),
      home: UnlockPage(vault: Vault(), onUnlocked: () {}),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(UnlockPage), matchesGoldenFile('preview/unlock_gold.png'));
  });

  testWidgets('edit', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    final p = palettes[2];
    UiPrefs.instance.palette = p;
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(p),
      home: EditPage(vault: vault, entry: null),
    ));
    await tester.enterText(find.byType(TextFormField).at(0), 'accounts.google.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'ayse.demir@gmail.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'Pazartesi2024!');
    await tester.pumpAndSettle();
    await expectLater(find.byType(EditPage), matchesGoldenFile('preview/edit_emerald.png'));
  });

  testWidgets('about', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    final p = palettes[1];
    UiPrefs.instance.palette = p;
    applyUiLang('tr');
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(p),
      home: const AboutPage(appName: appName),
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(AboutPage), matchesGoldenFile('preview/about_amethyst.png'));
  });
}
