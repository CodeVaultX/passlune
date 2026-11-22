import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/autofill_fill.dart';
import 'package:passlune/vault.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPaths extends PathProviderPlatform {
  final String dir;
  _TempPaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

const _master = 'dogru-sifre-12345';
const _channel = MethodChannel('passlune/autofill_fill');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> calls;

  setUp(() async {
    PathProviderPlatform.instance = _TempPaths(Directory.systemTemp.createTempSync('fill_lock').path);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (c) async {
      calls.add(c.method);
      if (c.method == 'request') {
        return {'site': 'github.com', 'package': 'com.android.chrome', 'appLabel': 'Chrome', 'noTag': true};
      }
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  /// Pumps, letting real file and isolate work run, until [done].
  Future<void> waitUntil(WidgetTester tester, bool Function() done, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail(what);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
  }

  /// Opens the fill screen and unlocks it (Argon2 runs for real).
  Future<void> openUnlocked(WidgetTester tester) async {
    await tester.runAsync(() async {
      final v = Vault();
      await v.create(_master);
      await v.upsert(Entry(id: newId(), site: 'github.com', username: 'ada', password: 'gizli'));
      await runAutofillFill();
    });
    await waitUntil(
        tester,
        () => find.byType(FilledButton).evaluate().isNotEmpty &&
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null,
        'the unlock button never became ready');
    await tester.enterText(find.byType(TextField), _master);
    await tester.tap(find.byType(FilledButton));
    await waitUntil(tester, () => find.byIcon(Icons.input).evaluate().isNotEmpty, 'the vault did not unlock');
  }

  void goToBackground(WidgetTester tester) {
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  testWidgets('leaving the unlocked fill screen locks it and cancels the fill once', (tester) async {
    await openUnlocked(tester);
    expect(find.text('ada'), findsOneWidget);

    goToBackground(tester);
    await tester.pump();

    expect(find.byIcon(Icons.input), findsNothing, reason: 'the logins must be gone');
    expect(find.byType(TextField), findsOneWidget, reason: 'back on the unlock form');
    expect(calls.where((m) => m == 'cancel'), hasLength(1));

    for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    goToBackground(tester);
    await tester.pump();
    expect(calls.where((m) => m == 'cancel'), hasLength(1), reason: 'the system is answered only once');
  });

  testWidgets('a picked login is not followed by a cancel', (tester) async {
    await openUnlocked(tester);
    await tester.tap(find.byIcon(Icons.input));
    await tester.pump();
    expect(calls, contains('pick'));

    goToBackground(tester); // the activity finishing after the pick
    await tester.pump();
    expect(calls, isNot(contains('cancel')));
  });
}
