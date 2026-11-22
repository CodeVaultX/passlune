import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'domain.dart';
import 'insights.dart';
import 'l10n.dart';
import 'theme.dart';
import 'vault.dart';

/// The screen behind "Fill with Passlune" (AutofillFillActivity.kt): unlock the
/// vault, pick a login for the app or site that asked, and hand it back.
Future<void> runAutofillFill() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UiPrefs.instance.load();
  applyUiLang(UiPrefs.instance.lang);
  runApp(ListenableBuilder(
    listenable: UiPrefs.instance,
    builder: (_, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(UiPrefs.instance.palette),
      home: const _FillPage(),
    ),
  ));
}

const _ch = MethodChannel('passlune/autofill_fill');

/// The `Android: <package>` line that links an entry to an app.
String appTag(String pkg) => 'Android: $pkg';

bool hasAppTag(Entry e, String pkg) => e.notes.split('\n').any((l) => l.trim() == appTag(pkg));

/// Does [e] belong to the requesting site or app? [site] is only set when the
/// request came from a known browser (PassluneAutofillService checks that): any
/// other app could claim to be any web site. [noTag]: a browser or other web
/// content whose site is unknown — nothing matches without asking.
/// [trustedInstall]: the app came from Google Play or the system.
bool matchesRequest(Entry e,
    {required String site, required String pkg, bool noTag = false, bool trustedInstall = false}) {
  if (site.isNotEmpty) return siteMatches(e.site, site);
  if (pkg.isEmpty || noTag) return false;
  if (hasAppTag(e, pkg)) return true;
  // Reverse-DNS convention: com.instagram.android ↔ instagram.com. Only for
  // apps from Play or the system: anyone can name a sideloaded app so.
  if (!trustedInstall) return false;
  final host = hostOf(e.site);
  final reg = host == null ? null : registrableDomain(host);
  if (reg == null) return false;
  final reversed = reg.split('.').reversed.join('.');
  return pkg == reversed || pkg.startsWith('$reversed.');
}

class _FillPage extends StatefulWidget {
  const _FillPage();

  @override
  State<_FillPage> createState() => _FillPageState();
}

class _FillPageState extends State<_FillPage> with WidgetsBindingObserver {
  final _vault = Vault();
  final _pw = TextEditingController();
  String _site = '', _pkg = '', _label = '';
  bool _noTag = true, _trustedInstall = false;
  bool _unlocked = false, _busy = false, _hide = true;
  bool? _exists;
  String? _error;
  String _query = '';

  /// A login was handed back or the fill was cancelled: the activity is
  /// finishing and must not be answered twice.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ch.invokeMethod<Map>('request').then((r) {
      if (!mounted || r == null) return;
      setState(() {
        _site = r['site'] as String? ?? '';
        _pkg = r['package'] as String? ?? '';
        _label = r['appLabel'] as String? ?? '';
        _noTag = r['noTag'] as bool? ?? true;
        _trustedInstall = r['trustedInstall'] as bool? ?? false;
      });
    });
    Vault.exists().then((v) {
      if (mounted) setState(() => _exists = v);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vault.lock();
    _pw.dispose();
    super.dispose();
  }

  // Left for another app, or the screen went off, before a login was picked:
  // the opened vault must not wait in the background. Lock it and give up
  // this fill; tapping "Fill with Passlune" again starts over.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused && state != AppLifecycleState.hidden) return;
    _vault.lock();
    _pw.clear();
    if (mounted && _unlocked) setState(() => _unlocked = false);
    _finish('cancel');
  }

  /// Answers the system once: 'pick' with a login, or 'cancel'.
  Future<void> _finish(String method, [Map<String, String>? login]) async {
    if (_done) return;
    _done = true;
    await _ch.invokeMethod(method, login);
  }

  String get _target => _site.isNotEmpty ? _site : (_label.isNotEmpty ? _label : _pkg);

  Future<void> _unlock() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _vault.unlock(_pw.text);
      _pw.clear();
      setState(() => _unlocked = true);
    } on WrongPasswordException {
      setState(() => _error = t('Yanlış ana şifre.', 'Wrong master password.'));
    } on CorruptVaultException {
      // Restoring the backup is offered by the app itself (UnlockPage).
      setState(() => _error = t('Kasa dosyası okunamadı. Passlune uygulamasını açıp kilidi oradan aç.',
          'Couldn\'t read the vault file. Open the Passlune app and unlock it there.'));
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(Entry e) async {
    if (!matchesRequest(e, site: _site, pkg: _pkg, noTag: _noTag, trustedInstall: _trustedInstall)) {
      // Not this site/app's login: a look-alike app is exactly how phishing
      // gets a password typed in, so make the user confirm.
      final who = _site.isNotEmpty ? _site : '$_label ($_pkg)';
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('Bu kayıt bu ${_site.isNotEmpty ? 'site' : 'uygulama'} için değil', 'This login is not for this ${_site.isNotEmpty ? 'site' : 'app'}')),
          content: Text(t(
            '"${displayTitle(e.site)}" kaydı, "$who" içine doldurulacak. Bu uygulamaya güvendiğinden eminsen devam et.',
            'The "${displayTitle(e.site)}" login will be filled into "$who". Continue only if you trust this app.',
          )),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Vazgeç', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Doldur', 'Fill'))),
          ],
        ),
      );
      if (ok != true) return;
      // Remember the app on the entry, so it matches directly next time —
      // never a browser or other web content: the next page could be any site.
      if (_site.isEmpty && _pkg.isNotEmpty && !_noTag) {
        e.notes = e.notes.isEmpty ? appTag(_pkg) : '${e.notes}\n${appTag(_pkg)}';
        await _vault.upsert(e);
      }
    }
    await _finish('pick', {
      'username': e.username,
      'password': e.password,
      'title': displayTitle(e.site),
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = UiPrefs.instance.palette;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _finish('cancel');
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.close), onPressed: () => _finish('cancel')),
          title: Row(children: [
            VaultMark(size: 28, color: pal.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_target.isEmpty ? 'Passlune' : t('Doldur: $_target', 'Fill: $_target'),
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
        ),
        body: _unlocked ? _list(pal) : _lock(pal),
      ),
    );
  }

  Widget _lock(Palette pal) {
    if (_exists == false) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t('Önce Passlune uygulamasını açıp kasanı oluştur.', 'Open the Passlune app and create your vault first.'),
              textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(padding: const EdgeInsets.all(24), children: [
      const SizedBox(height: 12),
      Center(child: VaultMark(size: 72, color: pal.accent)),
      const SizedBox(height: 16),
      Text(t('Doldurmak için kasanın kilidini aç', 'Unlock your vault to fill'),
          textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 20),
      TextField(
        controller: _pw,
        obscureText: _hide,
        autofocus: true,
        enableSuggestions: false,
        autocorrect: false,
        onSubmitted: (_) => _unlock(),
        decoration: InputDecoration(
          hintText: t('Ana şifre', 'Master password'),
          prefixIcon: const Icon(Icons.lock_outline),
          suffixIcon: IconButton(
            icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _hide = !_hide),
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy || _exists == null ? null : _unlock,
        child: _busy
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(t('Kilidi aç', 'Unlock')),
      ),
    ]);
  }

  Widget _list(Palette pal) {
    final all = _vault.entries.where((e) => e.password.isNotEmpty || e.username.isNotEmpty).toList()
      ..sort((a, b) => displayTitle(a.site).toLowerCase().compareTo(displayTitle(b.site).toLowerCase()));
    final matches = all.where((e) => matchesRequest(e, site: _site, pkg: _pkg, noTag: _noTag, trustedInstall: _trustedInstall)).toList();
    final q = _query.toLowerCase();
    final others = q.isEmpty
        ? <Entry>[]
        : all.where((e) => !matches.contains(e) && (e.site.toLowerCase().contains(q) || e.username.toLowerCase().contains(q))).toList();

    Widget tile(Entry e) {
      final cat = categoryOf(e);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: pal.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: pal.border)),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            leading: Icon(cat.icon, color: pal.accent),
            title: Text(displayTitle(e.site), maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(e.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pal.muted)),
            trailing: Icon(Icons.input, color: pal.accent),
            onTap: () => _pick(e),
          ),
        ),
      );
    }

    Widget header(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Text(s.toUpperCase(),
              style: TextStyle(color: pal.accent, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.3)),
        );

    return ListView(padding: const EdgeInsets.all(16), children: [
      // Who is asking: always the real app, plus the site for browsers.
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: pal.border),
        ),
        child: Row(children: [
          Icon(_site.isNotEmpty ? Icons.language : Icons.android, color: pal.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_site.isNotEmpty) Text(_site, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(_site.isNotEmpty ? t('Tarayıcı: $_label', 'Browser: $_label') : _label,
                  style: TextStyle(fontWeight: _site.isEmpty ? FontWeight.w700 : FontWeight.normal)),
              Text(_pkg, style: TextStyle(color: pal.muted, fontSize: 12)),
            ]),
          ),
        ]),
      ),
      header(t('Bu ${_site.isNotEmpty ? 'site' : 'uygulama'} için', 'For this ${_site.isNotEmpty ? 'site' : 'app'}')),
      if (matches.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(t('Eşleşen kayıt yok. Aşağıdan arayıp seçebilirsin.', 'No matching entries. Search below and pick one.'),
              style: TextStyle(color: pal.muted)),
        ),
      for (final e in matches) tile(e),
      header(t('Tüm kayıtlarda ara', 'Search all entries')),
      TextField(
        onChanged: (s) => setState(() => _query = s),
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t('Site ya da kullanıcı adı', 'Site or username')),
      ),
      const SizedBox(height: 10),
      for (final e in others.take(50)) tile(e),
    ]);
  }
}
