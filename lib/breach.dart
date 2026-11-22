import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'l10n.dart';

/// Upper-case hex SHA-1 of a password, the form the breach database uses.
String pwHash(String password) => sha1.convert(utf8.encode(password)).toString().toUpperCase();

/// Checks passwords against Have I Been Pwned's "Pwned Passwords" list
/// (passwords seen in real data breaches) with its k-anonymity API: only the
/// first 5 characters of each SHA-1 hash leave the device; the server answers
/// with every hash suffix sharing that prefix and the match is made here.
/// Nothing runs unless the user asks for a check.
///
/// Returns hash → times seen (0 = not found) for every given hash.
Future<Map<String, int>> checkPwned(
  Iterable<String> hashes, {
  void Function(int done, int total)? progress,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  final byPrefix = <String, Set<String>>{};
  for (final h in hashes) {
    byPrefix.putIfAbsent(h.substring(0, 5), () => {}).add(h);
  }
  final out = <String, int>{};
  var done = 0;
  try {
    for (final entry in byPrefix.entries) {
      final r = await c
          .get(
            Uri.https('api.pwnedpasswords.com', '/range/${entry.key}'),
            // Padding hides how many real matches the prefix has.
            headers: {'Add-Padding': 'true', 'User-Agent': 'Passlune-password-manager'},
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        throw Exception(t('Sızıntı servisi yanıt vermedi (${r.statusCode}).',
            'The breach service did not answer (${r.statusCode}).'));
      }
      final seen = <String, int>{};
      for (final line in const LineSplitter().convert(r.body)) {
        final i = line.indexOf(':');
        if (i > 0) seen['${entry.key}${line.substring(0, i).trim()}'] = int.tryParse(line.substring(i + 1).trim()) ?? 0;
      }
      for (final h in entry.value) {
        out[h] = seen[h] ?? 0;
      }
      progress?.call(++done, byPrefix.length);
    }
  } finally {
    if (client == null) c.close();
  }
  return out;
}
