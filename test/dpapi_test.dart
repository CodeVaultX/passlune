import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/dpapi.dart';

void main() {
  test('DPAPI round-trips and does not store plain text', () {
    final plain = Uint8List.fromList(utf8.encode('1//refresh-token-örnek'));
    final sealed = dpapiProtect(plain);
    expect(utf8.decode(sealed, allowMalformed: true).contains('refresh-token'), isFalse);
    expect(dpapiUnprotect(sealed), plain);
  }, skip: !Platform.isWindows);
}
