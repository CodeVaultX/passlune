import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Copies secrets and wipes them again.
///
/// On Android the copy is marked sensitive (no preview in the Android 13+
/// clipboard popup) and the wipe is done natively without reading the
/// clipboard first — a backgrounded app can't read it on Android 10+, which
/// is exactly when the user is pasting elsewhere, so read-then-clear never
/// cleared. On Windows the runner (flutter_window.cpp) keeps the copy out of
/// clipboard history and cloud clipboard, and wipes it only if nothing was
/// copied since. The timer is global, so leaving a screen doesn't cancel it.
class SecureClipboard {
  static const _ch = MethodChannel('passlune/autofill');
  static const _win = MethodChannel('passlune/windows');
  static Timer? _timer;
  static String? _last;

  static const clearAfter = Duration(seconds: 20);

  static Future<void> copy(String text) async {
    if (Platform.isAndroid) {
      await _ch.invokeMethod('copySecret', {'text': text});
    } else if (Platform.isWindows) {
      await _win.invokeMethod('copySecret', text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    _last = text;
    _timer?.cancel();
    _timer = Timer(clearAfter, clear);
  }

  /// Wipes what we copied (on desktop only if it is still on the clipboard,
  /// so something the user copied afterwards survives).
  static Future<void> clear() async {
    _timer?.cancel();
    _timer = null;
    final last = _last;
    _last = null;
    if (last == null) return;
    try {
      if (Platform.isAndroid) {
        await _ch.invokeMethod('clearClipboard');
      } else if (Platform.isWindows) {
        await _win.invokeMethod('clearClipboard');
      } else {
        final cur = await Clipboard.getData(Clipboard.kTextPlain);
        if (cur?.text == last) await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (_) {
      // Nothing to do: the clipboard isn't reachable right now.
    }
  }
}
