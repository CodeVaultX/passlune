import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/main.dart';

void main() {
  Widget app() => const MaterialApp(home: LuneIntro(child: Text('unlock screen')));

  testWidgets('shows the Lune Apps logo, then the app', (tester) async {
    await tester.pumpWidget(app());
    expect(find.bySemanticsLabel('Lune Apps'), findsOneWidget);
    expect(find.text('unlock screen'), findsNothing); // not built yet: no keyboard over the logo

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('unlock screen'), findsOneWidget);
    expect(find.bySemanticsLabel('Lune Apps'), findsNothing);
  });

  testWidgets('a tap skips the logo', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byType(LuneIntro));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('unlock screen'), findsOneWidget);
  });
}
