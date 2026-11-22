import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/insights.dart';
import 'package:passlune/vault.dart';

void main() {
  test('password strength', () {
    expect(strengthOf('netflix123'), Strength.weak);
    expect(strengthOf('123456'), Strength.weak);
    expect(strengthOf('Pazartesi2024!'), Strength.medium);
    expect(strengthOf('gH#8v!q2LmZ@x9Rt'), Strength.strong);
    expect(strengthOf(generatePassword(20)), Strength.strong);
  });

  test('report counts reuse and categories are guessed', () {
    Entry e(String site, String pw) => Entry(id: newId(), site: site, username: 'u', password: pw);
    final r = VaultReport.of([e('a.com', 'same-Pass-1234!x'), e('b.com', 'same-Pass-1234!x'), e('c.com', 'x')]);
    expect(r.reusedIds.length, 2);
    expect(r.total, 3);
    expect(categoryOf(e('https://www.garanti.com.tr', '')).id, 'bank');
    expect(categoryOf(e('mail.google.com', '')).id, 'email');
    expect(displayTitle('https://www.github.com/login'), 'github.com');
    expect(maskUser('ayse.demir@gmail.com'), 'ays***ir@gmail.com');
  });
}
