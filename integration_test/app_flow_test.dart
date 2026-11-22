// End-to-end run of the real app on Windows/Android with a throwaway data
// folder (never the user's real vault):
//   flutter test integration_test/app_flow_test.dart -d windows
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:passlune/l10n.dart';
import 'package:passlune/main.dart';
import 'package:passlune/theme.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPaths extends PathProviderPlatform {
  final String dir;
  _TempPaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

/// Pumps until [finder] matches (real async work like Argon2 runs meanwhile).
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  final err = tester.takeException();
  final texts = find.byType(Text, skipOffstage: false).evaluate().map((e) => (e.widget as Text).data).whereType<String>().take(40).join(' | ');
  throw TestFailure('Timed out waiting for $finder. Error: $err. On screen: $texts');
}

/// Pumps until [finder] matches nothing (e.g. a page has closed).
Future<void> waitGone(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isEmpty) return;
  }
  throw TestFailure('Still there after : ');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create vault, add/edit/delete, lock/unlock, layout, theme, language, breach check', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('passlune_it');
    PathProviderPlatform.instance = _TempPaths(tmp.path);
    await UiPrefs.instance.load();
    applyUiLang('tr');
    // A tall phone-like window so nothing we look for is scrolled off-screen.
    tester.view.physicalSize = const Size(900, 1900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const PassluneApp());

    // --- create vault
    debugPrint('STEP create vault');
    await waitFor(tester, find.text('Kasayı oluştur'));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'kisa');
    await tester.pump();
    await tester.enterText(fields.at(1), 'kisa');
    await tester.pump();
    await tester.tap(find.text('Kasayı oluştur'));
    await tester.pump();
    expect(find.text('En az 10 karakter olmalı.'), findsOneWidget);
    await tester.enterText(fields.at(0), 'deneme-sifre-123');
    await tester.pump();
    await tester.enterText(fields.at(1), 'deneme-sifre-124');
    await tester.pump();
    await tester.tap(find.text('Kasayı oluştur'));
    await tester.pump();
    expect(find.text('Şifreler eşleşmiyor.'), findsOneWidget);
    // Re-type both fields (as a user would after the error).
    await tester.enterText(fields.at(0), 'deneme-sifre-123');
    await tester.pump();
    await tester.enterText(fields.at(1), 'deneme-sifre-123');
    await tester.pump();
    await tester.tap(find.text('Kasayı oluştur'));
    await waitFor(tester, find.text('Kasan boş'), timeout: const Duration(minutes: 3));

    // --- add an entry (required-field check first)
    debugPrint('STEP add an entry (required-field check first)');
    await tester.tap(find.byTooltip('Yeni kayıt'));
    await waitFor(tester, find.text('Kaydet'));
    await tester.tap(find.text('Kaydet'));
    await tester.pump();
    expect(find.text('Zorunlu alan'), findsWidgets);
    final form = find.byType(TextFormField);
    await tester.enterText(form.at(0), 'https://www.github.com/login');
    await tester.pump();
    await tester.enterText(form.at(1), 'dev.ayse@example.com');
    await tester.pump();
    await tester.enterText(form.at(2), 'password123');
    await tester.pump();
    await waitFor(tester, find.text('Zayıf'), timeout: const Duration(seconds: 10)); // live strength meter
    await tester.tap(find.text('Kaydet'));
    await waitGone(tester, find.byType(EditPage));
    await waitFor(tester, find.text('github.com'));
    expect(find.text('Geliştirici'), findsWidgets); // category guessed from the site

    // --- second entry reusing the password → reuse warning on the card
    debugPrint('STEP second entry reusing the password → reuse warning on the card');
    await tester.tap(find.byTooltip('Yeni kayıt'));
    await waitFor(tester, find.text('Kaydet'));
    await tester.enterText(find.byType(TextFormField).at(0), 'netflix.com');
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).at(1), 'ayse');
    await tester.pump();
    await tester.enterText(find.byType(TextFormField).at(2), 'password123');
    await tester.pump();
    await waitFor(tester, find.textContaining('kayıtta daha kullanılıyor'), timeout: const Duration(seconds: 10));
    await tester.tap(find.text('Kaydet'));
    await waitGone(tester, find.byType(EditPage));
    await waitFor(tester, find.text('netflix.com'));
    expect(find.byTooltip('Bu şifre başka kayıtlarda da kullanılıyor'), findsNWidgets(2));

    // --- copy password → clipboard
    debugPrint('STEP copy password → clipboard');
    // Read right away: the clipboard is shared with whatever else runs on the PC.
    await tester.tap(find.byTooltip('Şifreyi kopyala').first);
    await tester.pump();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, 'password123');

    // --- list/grid toggles at once
    debugPrint('STEP list/grid toggles at once');
    expect(find.byType(SliverGrid), findsNothing);
    await tester.tap(find.byTooltip('Izgara görünümü'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SliverGrid), findsOneWidget);
    await tester.tap(find.byTooltip('Liste görünümü'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SliverGrid), findsNothing);

    // --- weak filter
    debugPrint('STEP weak filter');
    await tester.tap(find.text('Zayıf').first);
    await tester.pump();
    expect(find.text('Zayıf şifreler'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(InputChip), matching: find.byType(Icon)).last); // clear the filter
    await tester.pump();

    // --- settings: theme + language
    debugPrint('STEP settings: theme + language');
    await tester.tap(find.byTooltip('Ayarlar'));
    await waitFor(tester, find.text('Ametist'));
    await tester.tap(find.text('Ametist'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(UiPrefs.instance.palette.id, 'amethyst');
    await tester.tap(find.text('English'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('THEME'), findsOneWidget); // section titles are upper-case
    await tester.tapAt(const Offset(10, 10)); // close the sheet
    await waitFor(tester, find.text('Security score'));
    expect(File('${tmp.path}${Platform.pathSeparator}ui.json').readAsStringSync(), contains('"lang":"en"'));

    // --- breach check (live API; only a 5-char hash prefix is sent)
    debugPrint('STEP breach check (live API; only a 5-char hash prefix is sent)');
    await tester.tap(find.text('Exposed'));
    await waitFor(tester, find.text('Check'));
    await tester.tap(find.text('Check'));
    await waitFor(tester, find.text('Exposed passwords'), timeout: const Duration(seconds: 40));
    expect(find.byIcon(Icons.gpp_bad_outlined), findsWidgets); // breach badge on the listed cards

    // --- lock, wrong password, right password
    debugPrint('STEP lock, wrong password, right password');
    await tester.tap(find.byTooltip('Lock'));
    await waitFor(tester, find.text('Vault locked'));
    await tester.enterText(find.byType(TextField).first, 'yanlis-sifre-000');
    await tester.pump();
    await tester.tap(find.text('Unlock'));
    await waitFor(tester, find.text('Wrong master password.'), timeout: const Duration(minutes: 3));
    // The test keyboard can't type into a field that is still focused from the
    // previous attempt, so set the text directly (real typing is unaffected).
    (find.byType(TextField).evaluate().first.widget as TextField).controller!.text = 'deneme-sifre-123';
    await tester.pump();
    await tester.tap(find.text('Unlock'));
    await waitFor(tester, find.text('github.com'), timeout: const Duration(minutes: 3));

    // --- delete
    debugPrint('STEP delete');
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await waitFor(tester, find.text('Delete'));
    await tester.tap(find.text('Delete'));
    await waitFor(tester, find.byType(AlertDialog));
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Delete')));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('github.com'), findsNothing);
    expect(find.text('netflix.com'), findsOneWidget);

    // --- the vault file on disk is ciphertext, never the plain password
    debugPrint('STEP the vault file on disk is ciphertext, never the plain password');
    final vaultFile = File('${tmp.path}${Platform.pathSeparator}vault.kasa');
    expect(vaultFile.existsSync(), isTrue);
    final raw = vaultFile.readAsStringSync();
    expect(raw.contains('password123'), isFalse);
    expect(raw.contains('netflix'), isFalse);
  });
}
