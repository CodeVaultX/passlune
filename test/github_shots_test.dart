// Screenshots for the GitHub page, English UI, sample data only. Opt-in:
//   SHOTS=1 flutter test --update-goldens test/github_shots_test.dart
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

// SHOTS_LANG=tr for the Turkish UI; SHOTS_PLAY=1 for Play Store size
// (1080x2160: Play allows at most 2:1).
final _lang = Platform.environment['SHOTS_LANG'] ?? 'en';
final _play = Platform.environment['SHOTS_PLAY'] != null;
final _size = _play ? const Size(1080, 2160) : const Size(1170, 2532);
final _dir = _play ? 'shots/play_$_lang' : 'shots';

void main() {
  if (Platform.environment['SHOTS'] == null) return;

  late Vault vault;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tmp = Directory.systemTemp.createTempSync('passlune_shots');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tmp.path,
    );
    const fonts = 'C:/dev/flutter/bin/cache/artifacts/material_fonts';
    const roboto = ['$fonts/roboto-regular.ttf', '$fonts/roboto-medium.ttf', '$fonts/roboto-bold.ttf', '$fonts/roboto-black.ttf'];
    await _font('Roboto', roboto);
    await _font('FlutterTest', roboto); // styles without a family (button labels) fall back to this in tests
    await _font('MaterialIcons', ['$fonts/materialicons-regular.otf']);
    applyUiLang(_lang);
    vault = Vault();
    await vault.create('preview-password-123');
    final samples = [
      ('github.com', 'dev.alex', 'gH#8v!q2LmZ@x9Rt', ''),
      ('accounts.google.com', 'alex.morgan@gmail.com', 'Summer2024!', ''),
      ('mybank.com', '12345678', 'Summer2024!', 'bank'),
      ('netflix.com', 'alex.morgan@gmail.com', 'netflix123', ''),
      ('instagram.com', 'alex.mrgn', 'Cat-Fish-Moon-77', ''),
      ('amazon.com', 'alex.morgan@gmail.com', 'T8&kq2!Vz#Lp4Wn6', ''),
      ('Home Wi-Fi', 'HomeNet_5G', 'a-very-long-home-wifi-passphrase', 'wifi'),
      ('Passport details', '', '', 'note'),
    ];
    for (final (site, user, pw, cat) in samples) {
      await vault.upsert(Entry(id: newId(), site: site, username: user, password: pw, category: cat));
    }
  });

  Future<void> phone(WidgetTester tester, Palette p) async {
    tester.view.physicalSize = _size;
    tester.view.devicePixelRatio = 3;
    UiPrefs.instance.palette = p;
  }

  Palette pal(String id) => palettes.firstWhere((p) => p.id == id);

  // The app's button labels set no font family; on a device that falls back
  // to the system font, but in tests to boxes, so name Roboto here.
  ThemeData th(String id) {
    final base = buildTheme(pal(id));
    const label = WidgetStatePropertyAll(TextStyle(fontFamily: 'Roboto', fontSize: 16, fontWeight: FontWeight.w600));
    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: base.filledButtonTheme.style!.copyWith(textStyle: label)),
    );
  }

  testWidgets('1 home', (tester) async {
    await phone(tester, pal('gold'));
    UiPrefs.instance.grid = false;
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: th('gold'), home: HomePage(vault: vault, onLock: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/1_home.png'));
  });

  testWidgets('2 grid', (tester) async {
    await phone(tester, pal('amethyst'));
    UiPrefs.instance.grid = true;
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: th('amethyst'), home: HomePage(vault: vault, onLock: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/2_grid.png'));
    UiPrefs.instance.grid = false;
  });

  testWidgets('3 edit', (tester) async {
    await phone(tester, pal('emerald'));
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: th('emerald'), home: EditPage(vault: vault, entry: null)));
    await tester.enterText(find.byType(TextFormField).at(0), 'accounts.google.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'alex.morgan@gmail.com');
    await tester.enterText(find.byType(TextFormField).at(2), 'Summer2024!');
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/3_edit.png'));
  });

  testWidgets('4 unlock', (tester) async {
    await phone(tester, pal('ocean'));
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: th('ocean'), home: UnlockPage(vault: Vault(), onUnlocked: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/4_unlock.png'));
  });

  testWidgets('5 settings', (tester) async {
    await phone(tester, pal('coral'));
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: th('coral'), home: HomePage(vault: vault, onLock: () {})));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(_lang == 'tr' ? 'Ayarlar' : 'Settings'));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/5_settings.png'));
  });

  testWidgets('6 about', (tester) async {
    await phone(tester, pal('graphite'));
    await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner: false, theme: th('graphite'), home: const AboutPage(appName: appName)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('$_dir/6_about.png'));
  });
}
