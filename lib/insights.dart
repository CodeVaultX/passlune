import 'dart:math';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'vault.dart';

// ------------------------------------------------------------ categories

class Category {
  final String id;
  final String labelTr, labelEn;
  final IconData icon;
  const Category(this.id, this.labelTr, this.labelEn, this.icon);
  String get label => t(labelTr, labelEn);
}

const categories = <Category>[
  Category('web', 'Web', 'Web', Icons.language),
  Category('email', 'E-posta', 'Email', Icons.mail_outline),
  Category('bank', 'Banka', 'Bank', Icons.account_balance_outlined),
  Category('card', 'Kart', 'Card', Icons.credit_card),
  Category('social', 'Sosyal', 'Social', Icons.forum_outlined),
  Category('shopping', 'Alışveriş', 'Shopping', Icons.shopping_bag_outlined),
  Category('fun', 'Eğlence', 'Entertainment', Icons.movie_outlined),
  Category('dev', 'Geliştirici', 'Developer', Icons.code),
  Category('work', 'İş', 'Work', Icons.work_outline),
  Category('wifi', 'Wi-Fi', 'Wi-Fi', Icons.wifi),
  Category('note', 'Not', 'Note', Icons.sticky_note_2_outlined),
  Category('other', 'Diğer', 'Other', Icons.folder_outlined),
];

Category categoryById(String id) => categories.firstWhere((c) => c.id == id, orElse: () => categories.first);

const _hints = <String, List<String>>{
  'email': ['mail', 'outlook', 'hotmail', 'yandex', 'proton', 'icloud'],
  'bank': ['bank', 'banka', 'garanti', 'akbank', 'ziraat', 'isbank', 'yapikredi', 'qnb', 'denizbank',
      'vakif', 'halkbank', 'enpara', 'paypal', 'papara', 'wise', 'revolut', 'binance', 'btcturk'],
  'social': ['facebook', 'instagram', 'twitter', 'x.com', 'tiktok', 'linkedin', 'reddit', 'discord',
      'telegram', 'whatsapp', 'snapchat', 'pinterest', 'eksisozluk'],
  'shopping': ['amazon', 'trendyol', 'hepsiburada', 'ebay', 'aliexpress', 'n11', 'temu', 'getir', 'yemeksepeti'],
  'fun': ['netflix', 'spotify', 'youtube', 'disney', 'steam', 'epicgames', 'twitch', 'exxen', 'blutv', 'primevideo'],
  'dev': ['github', 'gitlab', 'bitbucket', 'aws', 'azure', 'cloudflare', 'vercel', 'heroku', 'digitalocean', 'npmjs'],
  'work': ['slack', 'atlassian', 'jira', 'notion', 'zoom', 'office', 'teams'],
  'wifi': ['wifi', 'wi-fi', 'modem', 'router'],
};

/// The entry's category: the one the user picked, else a guess from the
/// site name.
Category categoryOf(Entry e) {
  if (e.category.isNotEmpty) return categoryById(e.category);
  final s = e.site.toLowerCase();
  if (s.isEmpty) return categoryById('other');
  for (final h in _hints.entries) {
    if (h.value.any(s.contains)) return categoryById(h.key);
  }
  return categoryById('web');
}

/// "https://www.github.com/login" → "github.com"; other titles unchanged.
String displayTitle(String site) {
  final s = site.trim();
  final m = RegExp(r'^(?:[a-z]+://)?(?:www\.)?([^/\s?#]+\.[a-z]{2,})(?:[/?#].*)?$', caseSensitive: false).firstMatch(s);
  return m != null ? m.group(1)! : s;
}

/// "kasabroker@gmail.com" → "kas***er@gmail.com".
String maskUser(String u) {
  if (u.isEmpty) return '';
  final at = u.indexOf('@');
  final name = at > 0 ? u.substring(0, at) : u;
  final rest = at > 0 ? u.substring(at) : '';
  if (name.length <= 4) return '${name[0]}***$rest';
  return '${name.substring(0, 3)}***${name.substring(name.length - 2)}$rest';
}

// -------------------------------------------------------------- strength

enum Strength { weak, medium, strong }

const _common = ['123456', 'password', 'qwerty', '111111', 'abc123', 'sifre', 'şifre', 'parola', 'iloveyou', 'admin', '000000'];

/// A rough entropy estimate: character pool × length, discounted for
/// repetition and well-known passwords.
Strength strengthOf(String p) {
  if (p.isEmpty) return Strength.weak;
  final lower = p.toLowerCase();
  if (_common.any((c) => lower.contains(c)) && p.length < 14) return Strength.weak;
  var pool = 0;
  if (RegExp('[a-z]').hasMatch(p)) pool += 26;
  if (RegExp('[A-Z]').hasMatch(p)) pool += 26;
  if (RegExp('[0-9]').hasMatch(p)) pool += 10;
  if (RegExp(r'[!-/:-@\[-`{-~ ]').hasMatch(p)) pool += 33;
  if (RegExp(r'[^\x00-\x7F]').hasMatch(p)) pool += 40;
  var bits = p.length * log(max(pool, 2)) / ln2;
  if (p.split('').toSet().length < p.length / 2) bits *= 0.6;
  // "Word + digits (+ a symbol)", e.g. Pazartesi2024! or netflix123: the
  // most common human pattern, and the first thing crackers try.
  if (RegExp(r'^[A-Za-zÇĞİÖŞÜçğıöşü]+[0-9]+[^A-Za-z0-9]{0,2}$').hasMatch(p) ||
      RegExp(r'^[0-9]+[A-Za-zÇĞİÖŞÜçğıöşü]+[^A-Za-z0-9]{0,2}$').hasMatch(p)) {
    bits *= 0.55;
  }
  if (bits < 45) return Strength.weak;
  if (bits < 72) return Strength.medium;
  return Strength.strong;
}

Map<Strength, String> get strengthLabel =>
    {Strength.weak: t('Zayıf', 'Weak'), Strength.medium: t('Orta', 'Medium'), Strength.strong: t('Güçlü', 'Strong')};
const strengthColor = {
  Strength.weak: Color(0xFFFF5A5F),
  Strength.medium: Color(0xFFF5B83D),
  Strength.strong: Color(0xFF3DDC84),
};

/// Security summary of the whole vault.
class VaultReport {
  final int total, weak, medium, strong;
  final Set<String> reusedIds; // entries whose password appears elsewhere too
  final Map<String, Strength> strengthById;
  final Map<String, int> reuseCount; // password → how many entries use it

  VaultReport._(this.total, this.weak, this.medium, this.strong, this.reusedIds, this.strengthById, this.reuseCount);

  factory VaultReport.of(List<Entry> entries) {
    final withPw = entries.where((e) => e.password.isNotEmpty).toList();
    final byId = {for (final e in withPw) e.id: strengthOf(e.password)};
    final count = <String, int>{};
    for (final e in withPw) {
      count[e.password] = (count[e.password] ?? 0) + 1;
    }
    final reused = {for (final e in withPw) if (count[e.password]! > 1) e.id};
    int n(Strength s) => byId.values.where((x) => x == s).length;
    return VaultReport._(withPw.length, n(Strength.weak), n(Strength.medium), n(Strength.strong), reused, byId, count);
  }

  /// 0–100, the average of a per-entry score so one bad password isn't
  /// punished three times over: strong 100, medium 60, weak 20; a reused
  /// password keeps 70% of that, one found in breaches scores 0.
  int get score => scoreWith(const {});

  int scoreWith(Set<String> leakedIds) {
    if (total == 0) return 100;
    var sum = 0.0;
    strengthById.forEach((id, s) {
      if (leakedIds.contains(id)) return;
      final base = switch (s) { Strength.strong => 100.0, Strength.medium => 60.0, Strength.weak => 20.0 };
      sum += reusedIds.contains(id) ? base * 0.7 : base;
    });
    return (sum / total).clamp(0, 100).round();
  }
}
