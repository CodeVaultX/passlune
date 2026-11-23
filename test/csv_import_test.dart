import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/csv_import.dart';
import 'package:passlune/vault.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPaths extends PathProviderPlatform {
  final String dir;
  _TempPaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  String sites(CsvImport r) => r.entries.map((e) => '${e.site}|${e.username}|${e.password}').join(', ');

  test('Chrome and Edge exports', () {
    final r = readPasswordCsv(
        'name,url,username,password,note\n'
        'github.com,https://github.com/login,ada,gh-pass,\n'
        'Instagram,android://Xk3_hash==@com.instagram.android/,ada,ig-pass,\n'
        'www.example.com,https://www.example.com/,bob,"p,with ""quotes""",multi\nline note\n',
        []);
    expect(sites(r), 'github.com|ada|gh-pass, Instagram|ada|ig-pass, example.com|bob|p,with "quotes"');
    expect(r.entries[1].notes, 'Android: com.instagram.android');
    expect(r.entries[2].notes, 'multi');
  });

  test('a quoted field can hold a line break', () {
    final r = readPasswordCsv('name,url,username,password,note\nx,https://x.com,u,p,"line one\nline two"\n', []);
    expect(r.entries.single.notes, 'line one\nline two');
  });

  test('Firefox export, with a byte order mark and CRLF line ends', () {
    final r = readPasswordCsv(
        '﻿"url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"\r\n'
        '"https://accounts.google.com","ada@gmail.com","g-pass",,"https://accounts.google.com","{1}","1","2","3"\r\n',
        []);
    expect(sites(r), 'accounts.google.com|ada@gmail.com|g-pass');
  });

  test('Bitwarden export: logins and secure notes', () {
    final r = readPasswordCsv(
        'folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n'
        'Work,1,login,GitLab,,,0,https://gitlab.com/users/sign_in,ada,gl-pass,\n'
        ',,note,Wi-Fi at home,"SSID: Ev\nKey: 1234",,0,,,,\n'
        ',,card,Empty card,,,0,,,,\n',
        []);
    expect(sites(r), 'gitlab.com|ada|gl-pass, Wi-Fi at home||');
    expect(r.entries[1].category, 'note');
    expect(r.entries[1].notes, 'SSID: Ev\nKey: 1234');
    expect(r.skipped, 1);
  });

  test('KeePassXC export: an entry without a URL keeps its title', () {
    final r = readPasswordCsv(
        '"Group","Title","Username","Password","URL","Notes","TOTP","Icon","Last Modified","Created"\n'
        '"Root","Bank","12345678","bank-pass","","PIN is elsewhere","","0","2026-01-01","2026-01-01"\n'
        '"Root","Mail","ada","mail-pass","https://mail.example.org","","","0","2026-01-01","2026-01-01"\n',
        []);
    expect(sites(r), 'Bank|12345678|bank-pass, mail.example.org|ada|mail-pass');
    expect(r.entries.first.notes, 'PIN is elsewhere');
  });

  test('a spreadsheet saved with semicolons', () {
    final r = readPasswordCsv('name;url;username;password\nX;https://x.com;u;p\n', []);
    expect(sites(r), 'x.com|u|p');
  });

  test('logins already in the vault or repeated in the file are skipped', () {
    final existing = [Entry(id: 'a', site: 'github.com', username: 'ada', password: 'gh-pass')];
    final r = readPasswordCsv(
        'name,url,username,password\n'
        'gh,https://www.github.com/,ada,gh-pass\n' // already in the vault
        'gh,https://github.com/,ada,new-pass\n' // same site, other password: kept
        'gh,https://github.com/,ada,new-pass\n', // repeated in the file
        existing);
    expect(sites(r), 'github.com|ada|new-pass');
    expect(r.duplicates, 2);
  });

  test('a CSV without a password column is refused', () {
    expect(() => readPasswordCsv('date,amount\n2026-01-01,5\n', []), throwsA(isA<NotPasswordCsv>()));
    expect(() => readPasswordCsv('', []), throwsA(isA<NotPasswordCsv>()));
  });

  test('addAll saves the imported entries in one go', () async {
    PathProviderPlatform.instance = _TempPaths(Directory.systemTemp.createTempSync('csv_import').path);
    final v = Vault();
    await v.create('ana-sifre-12345');
    var changes = 0;
    v.onChanged = () => changes++;
    final r = readPasswordCsv('name,url,username,password\na,https://a.com,u,1\nb,https://b.com,u,2\n', v.entries);
    await v.addAll(r.entries);
    expect(changes, 1);

    final w = Vault();
    await w.unlock('ana-sifre-12345');
    expect(w.entries.map((e) => e.site), ['a.com', 'b.com']);
  });
}
