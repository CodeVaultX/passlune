import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/vault.dart';

void main() {
  test('generated password has requested length and mixed classes', () {
    final p = generatePassword(24);
    expect(p.length, 24);
    expect(p, matches(RegExp(r'[a-z]')));
    expect(p, matches(RegExp(r'[A-Z]')));
    expect(p, matches(RegExp(r'[0-9]')));
  });
}
