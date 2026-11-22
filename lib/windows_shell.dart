import 'dart:io';

import 'package:flutter/services.dart';

import 'l10n.dart';
import 'theme.dart';

/// Windows only: the notification-area icon (closing the window keeps
/// Passlune running there, like RoboForm) and starting with Windows. The
/// native side is in windows/runner/flutter_window.cpp.
class WindowsShell {
  static const _ch = MethodChannel('passlune/windows');
  static bool get available => Platform.isWindows;
  static VoidCallback? _onLock;
  static bool _started = false;

  /// Called once the vault screen exists; [onLock] runs for "Lock" in the
  /// icon's menu.
  static Future<void> start({required VoidCallback onLock}) async {
    if (!available) return;
    _onLock = onLock;
    if (_started) return;
    _started = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'trayLock') _onLock?.call();
    });
    // Menu texts follow the app language.
    UiPrefs.instance.addListener(_applyTray);
    await _applyTray();
    // Re-written on every start: keeps the path right if the folder moved,
    // and the --tray flag in step with the tray setting.
    try {
      if (await autostart()) await setAutostart(true);
    } catch (_) {}
  }

  static Future<void> _applyTray() async {
    try {
      await _ch.invokeMethod('setTray', {
        'enabled': UiPrefs.instance.tray,
        'open': t('Passlune\'u aç', 'Open Passlune'),
        'lock': t('Kilitle', 'Lock'),
        'quit': t('Çıkış', 'Quit'),
        'hintTitle': t('Passlune çalışmaya devam ediyor', 'Passlune is still running'),
        'hintText': t('Saatin yanındaki bu simgeden açabilirsin. Kapatmak için simgeye sağ tıklayıp Çıkış de.',
            'Open it from this icon next to the clock. To close it, right-click the icon and choose Quit.'),
      });
    } catch (_) {
      // An older runner without the tray: nothing to do.
    }
  }

  static Future<void> setTray(bool on) async {
    await UiPrefs.instance.setTray(on); // the listener sends it to the runner
    // Started with Windows: start in the icon only when closing keeps it there.
    if (await autostart()) await setAutostart(true);
  }

  /// Whether Passlune starts when the user signs in to Windows.
  static Future<bool> autostart() async {
    if (!available) return false;
    try {
      return await _ch.invokeMethod<bool>('getAutostart') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setAutostart(bool on) =>
      _ch.invokeMethod('setAutostart', {'enabled': on, 'inTray': UiPrefs.instance.tray});
}
