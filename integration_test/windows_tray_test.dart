import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:passlune/windows_shell.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _findEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _pidOf = _user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
    'GetWindowThreadProcessId');
final _visible = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
final _post = _user32.lookupFunction<Int32 Function(IntPtr, Uint32, IntPtr, IntPtr), int Function(int, int, int, int)>(
    'PostMessageW');
final _registerMsg =
    _user32.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('RegisterWindowMessageW');
// HRESULT Shell_NotifyIconGetRect(const NOTIFYICONIDENTIFIER*, RECT*): S_OK only while the icon exists.
final _iconRect = _shell32.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Int32>),
    int Function(Pointer<Uint8>, Pointer<Int32>)>('Shell_NotifyIconGetRect');
final _myPid = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

const _wmClose = 0x0010;
const _ch = MethodChannel('passlune/windows');
const _run = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const _approved = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

int _ownWindow() => using((a) {
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: a);
      final pid = a<Uint32>();
      for (var h = _findEx(0, 0, cls, nullptr); h != 0; h = _findEx(0, h, cls, nullptr)) {
        _pidOf(h, pid);
        if (pid.value == _myPid()) return h;
      }
      return 0;
    });

bool _hasTrayIcon(int hwnd) => using((a) {
      // NOTIFYICONIDENTIFIER (x64): cbSize@0, hWnd@8, uID@16, guidItem@20; 40 bytes.
      final id = a<Uint8>(40);
      id.cast<Uint32>().value = 40;
      (id + 8).cast<IntPtr>().value = hwnd;
      (id + 16).cast<Uint32>().value = 1;
      return _iconRect(id, a<Int32>(4)) == 0;
    });

/// `reg query` output line for [value], or null when absent.
Future<String?> _regLine(String key, String value) async {
  final r = await Process.run('reg', ['query', key, '/v', value]);
  if (r.exitCode != 0) return null;
  return (r.stdout as String).split('\n').map((l) => l.trim()).firstWhere((l) => l.startsWith(value), orElse: () => '');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

// Runs the real Windows app (flutter test integration_test/windows_tray_test.dart -d windows).
// It touches the user's startup entry and puts back whatever was there.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('closing hides to the notification area; a second start brings it back', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final hwnd = _ownWindow();
    expect(hwnd, isNot(0));
    expect(_hasTrayIcon(hwnd), isFalse);

    await _ch.invokeMethod('setTray', {'enabled': true, 'open': 'Aç', 'lock': 'Kilitle', 'quit': 'Çıkış'});
    expect(_hasTrayIcon(hwnd), isTrue);
    expect(_visible(hwnd), isNot(0));

    _post(hwnd, _wmClose, 0, 0); // the window's X
    await _settle(tester);
    expect(_visible(hwnd), 0, reason: 'closed into the tray, still running');
    expect(_hasTrayIcon(hwnd), isTrue);

    final show = using((a) => _registerMsg('Passlune.ShowWindow'.toNativeUtf16(allocator: a)));
    _post(hwnd, show, 0, 0); // what a second Passlune.exe sends
    await _settle(tester);
    expect(_visible(hwnd), isNot(0));

    // Turning the tray off removes the icon (and never leaves the window hidden).
    _post(hwnd, _wmClose, 0, 0);
    await _settle(tester);
    expect(_visible(hwnd), 0);
    await _ch.invokeMethod('setTray', {'enabled': false});
    await _settle(tester);
    expect(_hasTrayIcon(hwnd), isFalse);
    expect(_visible(hwnd), isNot(0));
  });

  testWidgets('start with Windows writes, re-enables and removes the startup entry', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final runBefore = await _regLine(_run, 'Passlune');
    final approvedBefore = await _regLine(_approved, 'Passlune');
    try {
      await _ch.invokeMethod('setAutostart', {'enabled': true, 'inTray': true});
      final line = await _regLine(_run, 'Passlune');
      expect(line, contains(Platform.resolvedExecutable));
      expect(line, endsWith('--tray'));
      expect(await WindowsShell.autostart(), isTrue);

      // Switched off in Task Manager: shown as off, and turning it on undoes that.
      await Process.run('reg', ['add', _approved, '/v', 'Passlune', '/t', 'REG_BINARY', '/d', '030000000000000000000000', '/f']);
      expect(await WindowsShell.autostart(), isFalse);
      await _ch.invokeMethod('setAutostart', {'enabled': true, 'inTray': false});
      expect(await WindowsShell.autostart(), isTrue);
      expect(await _regLine(_approved, 'Passlune'), isNull);
      expect(await _regLine(_run, 'Passlune'), isNot(contains('--tray')));

      await _ch.invokeMethod('setAutostart', {'enabled': false});
      expect(await _regLine(_run, 'Passlune'), isNull);
      expect(await WindowsShell.autostart(), isFalse);
    } finally {
      Future<void> restore(String key, String? line) async {
        await Process.run('reg', ['delete', key, '/v', 'Passlune', '/f']);
        if (line == null || line.isEmpty) return;
        final m = RegExp(r'^Passlune\s+(REG_\w+)\s+(.*)$').firstMatch(line)!;
        await Process.run('reg', ['add', key, '/v', 'Passlune', '/t', m[1]!, '/d', m[2]!, '/f']);
      }

      await restore(_run, runBefore);
      await restore(_approved, approvedBefore);
    }
  });
}
