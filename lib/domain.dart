import 'psl_data.dart';

/// Site matching for autofill — the same rules as the browser extension's
/// lib/domain.js, so the app and the extension agree on which saved login
/// belongs to which site:
///  * IP addresses, `localhost` and other single-label hosts match only the
///    exact same host.
///  * Everything else is compared by its registrable domain from the Public
///    Suffix List: accounts.google.com ~ mail.google.com, but
///    garanti.com.tr ≁ other-site.com.tr and alice.github.io ≁ bob.github.io.
///  * A few provider families sign in across several registrable domains.
final Set<String> _rules = pslRules.split('\n').where((l) => l.isNotEmpty).toSet();

const _families = [
  ['microsoft.com', 'microsoftonline.com', 'live.com', 'outlook.com', 'office.com', 'office365.com', 'msn.com', 'hotmail.com', 'xbox.com'],
  ['google.com', 'gmail.com', 'youtube.com'],
  ['apple.com', 'icloud.com'],
  ['amazon.com', 'amazon.co.uk', 'amazon.de', 'amazon.com.tr', 'amazon.fr'],
  ['yahoo.com', 'yahoo.com.tr'],
];

bool _sameFamily(String a, String b) {
  if (a == b) return true;
  for (final f in _families) {
    if (f.contains(a) && f.contains(b)) return true;
  }
  return false;
}

/// "https://www.x.com/path" or "x.com" → "www.x.com" (lower case), or null.
String? hostOf(String value) {
  var s = value.trim();
  if (s.isEmpty) return null;
  if (!RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(s)) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return null;
  return u.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
}

bool _exactOnly(String host) =>
    RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) ||
    host.contains(':') ||
    !host.contains('.') ||
    host.endsWith('.localhost');

/// Registrable domain ("eTLD+1"), or null when the host is a public suffix.
String? registrableDomain(String host) {
  final labels = host.split('.');
  if (labels.any((l) => l.isEmpty)) return null;
  var suffixLen = 1; // the implicit "*" rule
  for (var i = 0; i < labels.length; i++) {
    final candidate = labels.sublist(i).join('.');
    if (_rules.contains('!$candidate')) {
      suffixLen = labels.length - i - 1;
      break;
    }
    if (_rules.contains(candidate)) {
      suffixLen = labels.length - i;
      break;
    }
    if (i + 1 < labels.length && _rules.contains('*.${labels.sublist(i + 1).join('.')}')) {
      suffixLen = labels.length - i;
      break;
    }
  }
  if (suffixLen >= labels.length) return null;
  return labels.sublist(labels.length - suffixLen - 1).join('.');
}

/// Does a saved entry's [site] belong to [page] (a URL or host)?
bool siteMatches(String site, String page) {
  final a = hostOf(site), b = hostOf(page);
  if (a == null || b == null) return false;
  if (_exactOnly(a) || _exactOnly(b)) return a == b;
  final ra = registrableDomain(a), rb = registrableDomain(b);
  if (ra == null || rb == null) return a == b;
  return _sameFamily(ra, rb);
}
