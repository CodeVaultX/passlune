import 'autofill_fill.dart' show appTag;
import 'domain.dart';
import 'vault.dart';

/// Logins exported as CSV by browsers and other password managers: Chrome,
/// Edge, Firefox, Bitwarden, KeePassXC, and any other export whose columns
/// are named alike. Columns are found by name, so their order doesn't matter.
class CsvImport {
  /// New entries, ready for [Vault.addAll].
  final List<Entry> entries;

  /// Rows already in the vault (same site, username and password) or
  /// repeated in the file.
  final int duplicates;

  /// Rows with neither a password nor notes.
  final int skipped;

  const CsvImport(this.entries, this.duplicates, this.skipped);
}

/// The file has no password column: not a passwords export.
class NotPasswordCsv implements Exception {}

const _urlColumns = ['url', 'login_uri', 'website', 'web site', 'uri', 'login url'];
const _userColumns = ['username', 'login_username', 'user name', 'login', 'email', 'user'];
const _passwordColumns = ['password', 'login_password'];
const _notesColumns = ['note', 'notes', 'extra', 'comments'];
const _titleColumns = ['name', 'title'];

/// Reads a passwords CSV and leaves out what [existing] already has.
CsvImport readPasswordCsv(String text, List<Entry> existing) {
  final rows = parseCsv(text);
  if (rows.isEmpty) throw NotPasswordCsv();
  final header = rows.first.map((h) => h.trim().toLowerCase()).toList();
  int column(List<String> names) => header.indexWhere(names.contains);
  final url = column(_urlColumns), user = column(_userColumns), password = column(_passwordColumns);
  final notes = column(_notesColumns), title = column(_titleColumns);
  if (password < 0) throw NotPasswordCsv();

  final added = <Entry>[];
  var duplicates = 0, skipped = 0;
  bool known(Entry n) => [...existing, ...added]
      .any((e) => e.username == n.username && e.password == n.password && _sameSite(e.site, n.site));

  for (final row in rows.skip(1)) {
    String cell(int i) => i >= 0 && i < row.length ? row[i] : '';
    final e = _entryFrom(
      url: cell(url).trim(),
      name: cell(title).trim(),
      user: cell(user).trim(),
      password: cell(password),
      notes: cell(notes).trim(),
    );
    if (e == null) {
      skipped++;
    } else if (known(e)) {
      duplicates++;
    } else {
      added.add(e);
    }
  }
  return CsvImport(added, duplicates, skipped);
}

Entry? _entryFrom({required String url, required String name, required String user, required String password, required String notes}) {
  if (password.isEmpty && notes.isEmpty) return null;
  final lines = [if (notes.isNotEmpty) notes];
  String site;
  // Chrome lists Android app logins as android://<hash>@<package>/.
  final app = RegExp(r'^android://(?:[^@/]*@)?([A-Za-z0-9_.]+)').firstMatch(url);
  if (app != null) {
    site = name.isNotEmpty ? name : app.group(1)!;
    lines.add(appTag(app.group(1)!));
  } else {
    final host = url.isEmpty ? null : hostOf(url);
    site = host != null ? host.replaceFirst(RegExp(r'^www\.'), '') : (name.isNotEmpty ? name : url);
  }
  if (site.isEmpty) site = user.isNotEmpty ? user : 'CSV';
  return Entry(
    id: newId(),
    site: site,
    username: user,
    password: password,
    notes: lines.join('\n'),
    // A row with notes but no password is a secure note (Bitwarden, KeePassXC).
    category: password.isEmpty ? 'note' : '',
  );
}

bool _sameSite(String a, String b) => a.toLowerCase() == b.toLowerCase() || siteMatches(a, b);

/// RFC 4180 CSV: quoted fields may hold the separator, line breaks and
/// doubled quotes. Takes a leading byte order mark, CRLF or LF line ends, and
/// ';' as the separator when the header has more of those than commas
/// (spreadsheets in many locales).
List<List<String>> parseCsv(String text) {
  if (text.startsWith('﻿')) text = text.substring(1);
  final firstLine = text.split('\n').first;
  final sep = ';'.allMatches(firstLine).length > ','.allMatches(firstLine).length ? ';' : ',';
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;

  void endRow() {
    row.add(field.toString());
    field.clear();
    if (row.length > 1 || row.first.isNotEmpty) rows.add(row); // blank lines
    row = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c != '"') {
        field.write(c);
      } else if (i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == sep) {
      row.add(field.toString());
      field.clear();
    } else if (c == '\r' || c == '\n') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
