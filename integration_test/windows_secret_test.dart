import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:passlune/secure_clipboard.dart';

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _register =
    _user32.lookupFunction<Uint32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>('RegisterClipboardFormatW');
final _available = _user32.lookupFunction<Int32 Function(Uint32), int Function(int)>('IsClipboardFormatAvailable');
final _findEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _pidOf = _user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
    'GetWindowThreadProcessId');
final _affinity = _user32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
    'GetWindowDisplayAffinity');
final _myPid = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

bool _has(String format) => using((a) => _available(_register(format.toNativeUtf16(allocator: a))) != 0);

int _ownWindowAffinity() => using((a) {
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: a);
      final pid = a<Uint32>(), aff = a<Uint32>();
      for (var h = _findEx(0, 0, cls, nullptr); h != 0; h = _findEx(0, h, cls, nullptr)) {
        _pidOf(h, pid);
        if (pid.value == _myPid() && _affinity(h, aff) != 0) return aff.value;
      }
      return -1;
    });

Future<String?> _text() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

// Runs the real Windows app (flutter test integration_test -d windows). It uses
// the real clipboard and puts back the text that was on it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('secrets stay out of clipboard history and screen capture', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(Platform.isWindows, isTrue);
    expect(_ownWindowAffinity(), 0x11); // WDA_EXCLUDEFROMCAPTURE

    final before = await _text();
    try {
      await SecureClipboard.copy('gizli-Şifre-123');
      expect(await _text(), 'gizli-Şifre-123');
      expect(_has('CanIncludeInClipboardHistory'), isTrue);
      expect(_has('CanUploadToCloudClipboard'), isTrue);
      expect(_has('ExcludeClipboardContentFromMonitorProcessing'), isTrue);
      await SecureClipboard.clear();
      expect(await _text() ?? '', isEmpty);

      // Something the user copied after the secret survives the wipe.
      await SecureClipboard.copy('ikinci');
      await Clipboard.setData(const ClipboardData(text: 'kullanici'));
      await SecureClipboard.clear();
      expect(await _text(), 'kullanici');
    } finally {
      if (before != null) await Clipboard.setData(ClipboardData(text: before));
    }
  });
}
