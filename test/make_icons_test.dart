// Renders the Passlune mark into PNG icons (extension toolbar icons and
// large masters for app icons). Opt-in:
//   MAKE_ICONS=1 flutter test test/make_icons_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/theme.dart';

Future<void> _render(int px, String out, {bool background = true}) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  final s = px.toDouble();
  if (background) {
    final r = RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, s, s), Radius.circular(s * 0.22));
    canvas.drawRRect(
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.1,
          colors: [Color(0xFF2A2210), Color(0xFF0C0B09)],
        ).createShader(Rect.fromLTWH(0, 0, s, s)),
    );
  }
  final markSize = s * (px <= 16 ? 0.98 : 0.86);
  canvas.translate((s - markSize) / 2, (s - markSize) / 2);
  const gold = Color(0xFFE8B04B);
  // Same painter the app uses.
  final painter = (VaultMark(size: markSize, color: gold).build(_FakeContext()) as CustomPaint).painter!;
  painter.paint(canvas, Size.square(markSize));
  final img = await rec.endRecording().toImage(px, px);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(out)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

class _FakeContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  if (Platform.environment['MAKE_ICONS'] == null) return;
  test('icons', () async {
    for (final px in [16, 32, 48, 128]) {
      await _render(px, 'extension/chrome/icons/icon$px.png');
    }
    await _render(512, 'build/icons/passlune_512.png');
    await _render(1024, 'build/icons/passlune_1024.png');
    await _render(1024, 'build/icons/passlune_foreground_1024.png', background: false);
  });
}
