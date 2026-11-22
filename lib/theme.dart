import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n.dart';

/// A colour theme: dark ones are a deep background with one accent colour;
/// "Açık" is the light variant.
class Palette {
  final String id;
  final String nameTr, nameEn;
  String get name => t(nameTr, nameEn);
  final Brightness brightness;
  final Color bg; // page background
  final Color surface; // cards
  final Color surface2; // inputs, chips, tiles inside cards
  final Color border;
  final Color accent;
  final Color onAccent;
  final Color text;
  final Color muted;

  const Palette({
    required this.id,
    required this.nameTr,
    required this.nameEn,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.text,
    required this.muted,
  });
}

Palette _dark(String id, String nameTr, String nameEn, Color accent, {Color bg = const Color(0xFF0B0D12)}) {
  final surface = Color.alphaBlend(accent.withValues(alpha: 0.05), const Color(0xFF14171F));
  return Palette(
    id: id,
    nameTr: nameTr,
    nameEn: nameEn,
    brightness: Brightness.dark,
    bg: bg,
    surface: surface,
    surface2: Color.alphaBlend(accent.withValues(alpha: 0.07), const Color(0xFF1B1F29)),
    border: Color.alphaBlend(accent.withValues(alpha: 0.18), const Color(0xFF262B37)),
    accent: accent,
    onAccent: accent.computeLuminance() > 0.4 ? const Color(0xFF111111) : Colors.white,
    text: const Color(0xFFECEEF3),
    muted: const Color(0xFF9AA1B2),
  );
}

final palettes = <Palette>[
  _dark('gold', 'Altın', 'Gold', const Color(0xFFE8B04B), bg: const Color(0xFF0C0B09)),
  _dark('amethyst', 'Ametist', 'Amethyst', const Color(0xFFB28DFF), bg: const Color(0xFF0D0B14)),
  _dark('emerald', 'Zümrüt', 'Emerald', const Color(0xFF34D399), bg: const Color(0xFF08100D)),
  _dark('ocean', 'Okyanus', 'Ocean', const Color(0xFF5AA9FF), bg: const Color(0xFF080D16)),
  _dark('coral', 'Mercan', 'Coral', const Color(0xFFFF7A6B), bg: const Color(0xFF120B0B)),
  _dark('graphite', 'Grafit', 'Graphite', const Color(0xFFCBD2DC)),
  const Palette(
    id: 'light',
    nameTr: 'Açık',
    nameEn: 'Light',
    brightness: Brightness.light,
    bg: Color(0xFFF4F5F8),
    surface: Colors.white,
    surface2: Color(0xFFF0F1F5),
    border: Color(0xFFDDE0E7),
    accent: Color(0xFF4F46E5),
    onAccent: Colors.white,
    text: Color(0xFF14161C),
    muted: Color(0xFF6A7080),
  ),
];

/// Look-and-feel preferences (not secret, so a plain file next to the
/// vault): the theme and list/grid layout.
class UiPrefs extends ChangeNotifier {
  static final instance = UiPrefs._();
  UiPrefs._();

  Palette palette = palettes.first;
  bool grid = false;
  String lang = 'auto'; // 'auto' (device language), 'en' or 'tr'
  /// Windows: closing the window keeps Passlune in the notification area.
  bool tray = true;

  Future<File> _file() async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}ui.json');

  Future<void> load() async {
    try {
      final j = jsonDecode(await (await _file()).readAsString()) as Map<String, dynamic>;
      palette = palettes.firstWhere((p) => p.id == j['palette'], orElse: () => palettes.first);
      grid = j['grid'] as bool? ?? false;
      lang = j['lang'] as String? ?? 'auto';
      tray = j['tray'] as bool? ?? true;
    } catch (_) {
      // First run or unreadable: defaults.
    }
  }

  Future<void> _save() async {
    notifyListeners();
    rebuildAll();
    try {
      await (await _file()).writeAsString(jsonEncode({'palette': palette.id, 'grid': grid, 'lang': lang, 'tray': tray}));
    } catch (_) {}
  }

  Future<void> setPalette(Palette p) {
    palette = p;
    return _save();
  }

  Future<void> setGrid(bool g) {
    grid = g;
    return _save();
  }

  Future<void> setTray(bool on) {
    tray = on;
    return _save();
  }

  Future<void> setLang(String l) {
    lang = l;
    applyUiLang(l);
    return _save();
  }
}

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme.fromSeed(seedColor: p.accent, brightness: p.brightness).copyWith(
    primary: p.accent,
    onPrimary: p.onAccent,
    surface: p.surface,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    outline: p.border,
    outlineVariant: p.border,
    surfaceContainerHighest: p.surface2,
    surfaceContainerHigh: p.surface2,
    surfaceContainer: p.surface,
    surfaceContainerLow: p.surface,
  );
  final radius = BorderRadius.circular(14);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.border,
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: p.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface2,
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.border)),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.border)),
      focusedBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: p.accent, width: 1.6)),
      labelStyle: TextStyle(color: p.muted),
      hintStyle: TextStyle(color: p.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size(0, 50),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accent,
        side: BorderSide(color: p.accent.withValues(alpha: 0.6)),
        minimumSize: const Size(0, 46),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.surface2,
      contentTextStyle: TextStyle(color: p.text),
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: p.border)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: p.border)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface2,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: p.border)),
    ),
  );
}

/// The Passlune mark: a crescent moon (the family look shared with
/// Voicelune) with a keyhole cut into it, inside a thin ring.
class VaultMark extends StatelessWidget {
  final double size;
  final Color color;
  const VaultMark({super.key, this.size = 72, required this.color});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter(color));
}

class _MarkPainter extends CustomPainter {
  final Color color;
  _MarkPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    // Soft glow.
    canvas.drawCircle(
        c,
        r * 0.92,
        Paint()
          ..color = color.withValues(alpha: 0.16)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.18));
    // Thin ring.
    canvas.drawCircle(
        c,
        r * 0.88,
        Paint()
          ..color = color.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.06);
    // Crescent: a disc minus an offset disc.
    final moonC = c + Offset(-r * 0.06, 0);
    var shape = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: moonC, radius: r * 0.62)),
      Path()..addOval(Rect.fromCircle(center: moonC + Offset(r * 0.34, -r * 0.18), radius: r * 0.5)),
    );
    // Keyhole cut into the thick part of the crescent.
    final k = moonC + Offset(-r * 0.3, r * 0.02);
    final keyhole = Path()
      ..addOval(Rect.fromCircle(center: k + Offset(0, -r * 0.08), radius: r * 0.1))
      ..addPolygon([
        k + Offset(-r * 0.05, -r * 0.04),
        k + Offset(r * 0.05, -r * 0.04),
        k + Offset(r * 0.08, r * 0.2),
        k + Offset(-r * 0.08, r * 0.2),
      ], true);
    shape = Path.combine(PathOperation.difference, shape, keyhole);
    canvas.drawPath(shape, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}
