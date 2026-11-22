import 'dart:io';

import 'package:flutter/widgets.dart';

/// UI language: Turkish on Turkish phones/PCs, English everywhere else,
/// unless the user picks one in Settings.
bool isTr = deviceIsTurkish;

bool get deviceIsTurkish {
  try {
    return Platform.localeName.toLowerCase().startsWith('tr');
  } catch (_) {
    return false;
  }
}

/// [lang] is 'auto', 'tr' or 'en'.
void applyUiLang(String lang) {
  final was = isTr;
  isTr = switch (lang) {
    'tr' => true,
    'en' => false,
    _ => deviceIsTurkish,
  };
  if (was != isTr) rebuildAll();
}

/// Language, theme and layout are read straight from globals in build(),
/// so after changing one every open screen is rebuilt to show it at once.
void rebuildAll() {
  void mark(Element e) {
    e.markNeedsBuild();
    e.visitChildren(mark);
  }

  try {
    WidgetsBinding.instance.rootElement?.visitChildren(mark);
  } catch (_) {
    // No binding yet (startup, tests): nothing is on screen.
  }
}

/// The Turkish or English text, whichever the UI is in.
String t(String tr, String en) => isTr ? tr : en;
