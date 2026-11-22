import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows DPAPI (CryptProtectData / CryptUnprotectData): encrypts bytes
/// with a key tied to the signed-in Windows user, so a copied file is
/// useless on another account or machine. Called directly through FFI —
/// no plugin, no extra Visual Studio components needed to build.
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);

const _uiForbidden = 0x1; // CRYPTPROTECT_UI_FORBIDDEN

final _crypt32 = DynamicLibrary.open('crypt32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
final _unprotect =
    _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
final _localFree = _kernel32
    .lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>(
        'LocalFree');

Uint8List _run(_CryptDart fn, Uint8List input) {
  return using((arena) {
    final inBlob = arena<_DataBlob>();
    final outBlob = arena<_DataBlob>();
    final buf = arena<Uint8>(input.isEmpty ? 1 : input.length);
    buf.asTypedList(input.length).setAll(0, input);
    inBlob.ref
      ..cbData = input.length
      ..pbData = buf;
    final ok = fn(inBlob, nullptr, nullptr, nullptr, nullptr, _uiForbidden, outBlob);
    if (ok == 0) throw StateError('DPAPI çağrısı başarısız oldu.');
    try {
      return Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
    } finally {
      _localFree(outBlob.ref.pbData.cast());
    }
  });
}

Uint8List dpapiProtect(Uint8List plain) => _run(_protect, plain);
Uint8List dpapiUnprotect(Uint8List sealed) => _run(_unprotect, sealed);
