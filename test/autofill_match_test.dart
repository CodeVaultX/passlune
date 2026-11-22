import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/autofill_fill.dart';
import 'package:passlune/domain.dart';
import 'package:passlune/vault.dart';

void main() {
  Entry e(String site, {String notes = ''}) => Entry(id: newId(), site: site, username: 'u', password: 'p', notes: notes);

  test('registrable domain follows the Public Suffix List', () {
    expect(registrableDomain('accounts.google.com'), 'google.com');
    expect(registrableDomain('giris.turkiye.gov.tr'), 'turkiye.gov.tr');
    expect(registrableDomain('www.garanti.com.tr'), 'garanti.com.tr');
    expect(registrableDomain('alice.github.io'), 'alice.github.io');
    expect(registrableDomain('com.tr'), isNull);
  });

  test('web matching', () {
    expect(siteMatches('https://accounts.google.com/signin', 'mail.google.com'), isTrue);
    expect(siteMatches('outlook.com', 'login.microsoftonline.com'), isTrue); // provider family
    expect(siteMatches('github.com', 'google.com'), isFalse);
    expect(siteMatches('alice.github.io', 'bob.github.io'), isFalse);
    expect(siteMatches('garanti.com.tr', 'kotu-site.com.tr'), isFalse);
    expect(siteMatches('192.168.1.1', '192.168.2.1'), isFalse);
  });

  test('app matching: exact package tag or reverse-DNS, never the app label', () {
    expect(matchesRequest(e('instagram.com'), site: '', pkg: 'com.instagram.android', trustedInstall: true), isTrue);
    // Reverse-DNS needs an app from Play/the system: a sideloaded "com.paypal.x" gets nothing.
    expect(matchesRequest(e('paypal.com'), site: '', pkg: 'com.paypal.android'), isFalse);
    expect(matchesRequest(e('paypal.com'), site: '', pkg: 'com.evil.paypal', trustedInstall: true), isFalse);
    expect(matchesRequest(e('Banka', notes: 'Android: com.garanti.cepsubesi'), site: '', pkg: 'com.garanti.cepsubesi'), isTrue);
    // A tag for a longer package name must not match a shorter one.
    expect(matchesRequest(e('Banka', notes: 'Android: com.bank.mobile'), site: '', pkg: 'com.bank'), isFalse);
    expect(matchesRequest(e('netflix.com'), site: '', pkg: 'com.instagram.android'), isFalse);
  });

  test('a site is only used for matching when one is given (browsers)', () {
    expect(matchesRequest(e('paypal.com'), site: 'paypal.com', pkg: 'com.android.chrome'), isTrue);
    expect(matchesRequest(e('paypal.com'), site: 'paypa1.com', pkg: 'com.android.chrome'), isFalse);
  });

  test('web content of unknown site never matches by package', () {
    // An unlisted browser or a WebView app: even a tag on its package must
    // not open every page it shows.
    final tagged = e('bank.com', notes: 'Android: org.example.browser');
    expect(matchesRequest(tagged, site: '', pkg: 'org.example.browser', noTag: true), isFalse);
    expect(matchesRequest(e('example.com'), site: '', pkg: 'com.example.app', noTag: true, trustedInstall: true), isFalse);
  });
}
