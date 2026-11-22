import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'autofill_fill.dart' show appTag, hasAppTag;
import 'domain.dart';
import 'insights.dart';
import 'l10n.dart';
import 'theme.dart';
import 'vault.dart';

/// Bridge to the Android autofill service (PassluneAutofillService.kt), which
/// captures logins typed in other apps and browsers while Passlune is closed.
class AutofillBridge {
  static const _ch = MethodChannel('passlune/autofill');

  static bool get available => Platform.isAndroid;

  /// {supported, enabled, pending}; null off Android or on error.
  static Future<Map<String, dynamic>?> status() async {
    if (!available) return null;
    try {
      return (await _ch.invokeMethod<Map>('status'))?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  static Future<void> openSettings() async {
    if (available) await _ch.invokeMethod('openSettings');
  }

  /// Locking the vault also drops the login kept in memory for the password
  /// page of a two-step sign-in (RecentPick.kt).
  static Future<void> forgetRecentPick() async {
    if (!available) return;
    try {
      await _ch.invokeMethod('forgetRecentPick');
    } catch (_) {}
  }

  /// Moves logins captured while the vault was locked into the vault.
  /// Returns (added, updated).
  static Future<(int, int)> importPending(Vault v) async {
    if (!available) return (0, 0);
    final List<Object?> raw;
    try {
      raw = await _ch.invokeMethod<List<Object?>>('takePending') ?? const [];
    } catch (_) {
      return (0, 0);
    }
    var added = 0, updated = 0;
    for (final r in raw) {
      if (r is! String) continue; // unreadable record
      try {
        final j = jsonDecode(r) as Map<String, dynamic>;
        final site = (j['site'] as String? ?? '').trim();
        final user = (j['username'] as String? ?? '').trim();
        final pw = j['password'] as String? ?? '';
        if (site.isEmpty || pw.isEmpty) continue;
        final isWeb = j['web'] == true;
        final pkg = j['app'] as String? ?? '';
        // Web logins (only reported by known browsers) match by site; app
        // logins only by the exact package they were saved from.
        bool belongs(Entry e) => isWeb ? siteMatches(e.site, site) : (pkg.isNotEmpty && hasAppTag(e, pkg));
        final same = v.entries.where((e) => belongs(e) && e.username.toLowerCase() == user.toLowerCase());
        if (same.isNotEmpty) {
          final e = same.first;
          if (e.password != pw) {
            // Keep the previous password: a "Save?" tap should never be able
            // to silently destroy a working password.
            final when = DateTime.now().toIso8601String().substring(0, 10);
            final old = t('Önceki şifre ($when): ${e.password}', 'Previous password ($when): ${e.password}');
            e.notes = e.notes.isEmpty ? old : '${e.notes}\n$old';
            e.password = pw;
            await v.upsert(e);
            updated++;
          }
          continue;
        }
        await v.upsert(Entry(
          id: newId(),
          site: site,
          username: user,
          password: pw,
          notes: isWeb || pkg.isEmpty ? '' : appTag(pkg),
        ));
        added++;
      } on FormatException {
        // A malformed record is skipped rather than blocking the rest.
      } on TypeError {
        // Same: a field of the wrong type.
      }
    }
    // Only now, with everything saved in the vault, remove the queued records
    // (an exception above leaves them for the next try).
    await _ch.invokeMethod('dropPending', {'count': raw.length});
    return (added, updated);
  }
}

/// Settings → Autofill: what it does and how to turn it on (Android only).
class AutofillPage extends StatefulWidget {
  const AutofillPage({super.key});

  @override
  State<AutofillPage> createState() => _AutofillPageState();
}

class _AutofillPageState extends State<AutofillPage> with WidgetsBindingObserver {
  bool? _enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android settings: show whether it was turned on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await AutofillBridge.status();
    if (mounted) setState(() => _enabled = s?['enabled'] == true);
  }

  @override
  Widget build(BuildContext context) {
    final pal = UiPrefs.instance.palette;
    final on = _enabled == true;
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: pal.accent.withValues(alpha: 0.18),
              child: Text('$n', style: TextStyle(color: pal.accent, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ]),
        );
    Widget card(Widget child) => Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: pal.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: pal.border),
          ),
          child: child,
        );
    return Scaffold(
      appBar: AppBar(title: Text(t('Otomatik doldurma', 'Autofill'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          card(Row(children: [
            Icon(on ? Icons.check_circle : Icons.radio_button_unchecked,
                color: on ? strengthColor[Strength.strong] : pal.muted, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _enabled == null
                    ? '…'
                    : (on
                        ? t('Passlune otomatik doldurma hizmeti olarak seçili.', 'Passlune is your autofill service.')
                        : t('Passlune henüz otomatik doldurma hizmeti değil.', 'Passlune is not your autofill service yet.')),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ])),
          card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              t(
                'Açınca, başka bir uygulamada ya da tarayıcıda giriş yaptığında Android "Passlune\'a kaydedilsin mi?" diye sorar. '
                    'Tek dokunuşla kaydedilir; şifreleri tek tek girmen gerekmez. Giriş ekranlarında da "Passlune ile doldur" önerisi çıkar: dokun, ana şifrenle kilidi aç, kaydı seç. E-posta ve şifrenin ayrı ekranlarda sorulduğu '
                    'girişlerde (Google gibi) ikisi birlikte kaydedilir.',
                'Once on, Android asks "Save to Passlune?" when you sign in to another app or a website. One tap saves it, '
                    'so you don\'t have to enter passwords one by one. Login screens also offer "Fill with Passlune": tap it, '
                    'unlock with your master password and pick the login. When the e-mail and the password are asked on separate '
                    'screens (like Google), both are saved together.',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              t(
                'Passlune kilitliyken kaydedilen şifreler, telefonun donanım korumalı anahtar deposundaki bir anahtarla şifrelenip bekletilir; '
                    'Passlune\'u açtığında kasana eklenir.',
                'Logins saved while Passlune is locked wait encrypted with a key in the phone\'s hardware-backed keystore, and are '
                    'added to your vault when you next open Passlune.',
              ),
              style: TextStyle(color: pal.muted),
            ),
          ])),
          FilledButton.icon(
            onPressed: AutofillBridge.openSettings,
            icon: const Icon(Icons.settings_outlined),
            label: Text(on ? t('Android ayarlarını aç', 'Open Android settings') : t('Passlune\'u seç', 'Choose Passlune')),
          ),
          const SizedBox(height: 18),
          card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t('Chrome için bir adım daha', 'One more step for Chrome'),
                style: TextStyle(color: pal.accent, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            step(1, t('Chrome\'u aç → sağ üstteki ⋮ → Ayarlar.', 'Open Chrome → ⋮ at the top right → Settings.')),
            step(2, t('"Otomatik doldurma hizmetleri"ne dokun.', 'Tap "Autofill services".')),
            step(3, t('"Başka bir hizmet kullanarak otomatik doldur"u seç ve Chrome\'u yeniden başlat.',
                '"Autofill using another service", then restart Chrome.')),
            Text(
              t('Firefox, Samsung İnternet ve uygulamalar için ek ayar gerekmez.',
                  'Firefox, Samsung Internet and apps need no extra setting.'),
              style: TextStyle(color: pal.muted, fontSize: 13),
            ),
          ])),
        ],
      ),
    );
  }
}
