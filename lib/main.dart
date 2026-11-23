import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'about.dart';
import 'autofill.dart';
import 'autofill_fill.dart';
import 'breach.dart';
import 'csv_import.dart';
import 'drive.dart';
import 'insights.dart';
import 'secure_clipboard.dart';
import 'l10n.dart';
import 'sync_backend.dart';
import 'theme.dart';
import 'vault.dart';
import 'windows_shell.dart';

final navKey = GlobalKey<NavigatorState>();

const appName = 'Passlune';

/// Entry point of the "Fill with Passlune" screen (AutofillFillActivity.kt).
@pragma('vm:entry-point')
Future<void> autofillMain() => runAutofillFill();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _bringOldWindowsData();
  await UiPrefs.instance.load();
  applyUiLang(UiPrefs.instance.lang);
  runApp(const PassluneApp());
}

/// Before the rename, Windows kept the app's files (vault, Drive sign-in,
/// settings) under %APPDATA%\com.kasa\kasa. Copy them once into the new
/// folder; the old one is left in place as a backup.
Future<void> _bringOldWindowsData() async {
  if (!Platform.isWindows) return;
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return;
  final old = Directory('$appData\\com.kasa\\kasa');
  if (!old.existsSync()) return;
  final dir = await getApplicationSupportDirectory();
  if (File('${dir.path}\\vault.kasa').existsSync()) return; // already moved, or a new vault
  try {
    // Each file is copied under a temporary name and then renamed, and the
    // vault itself goes last: if the app is stopped halfway there is never a
    // half-written vault.kasa, and the next start simply copies again.
    final files = await old.list(recursive: true).where((e) => e is File).cast<File>().toList();
    files.sort((a, b) => (a.path.endsWith('vault.kasa') ? 1 : 0) - (b.path.endsWith('vault.kasa') ? 1 : 0));
    for (final e in files) {
      final target = File('${dir.path}${e.path.substring(old.path.length)}');
      if (target.existsSync() && !target.path.endsWith('vault.kasa')) continue;
      await target.parent.create(recursive: true);
      final tmp = await e.copy('${target.path}.moving');
      await tmp.rename(target.path);
    }
  } catch (_) {
    // Leave whatever was copied; the old folder is still there to retry from.
  }
}

class PassluneApp extends StatelessWidget {
  const PassluneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UiPrefs.instance,
      builder: (_, _) => MaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        navigatorKey: navKey,
        theme: buildTheme(UiPrefs.instance.palette),
        home: const Gate(),
      ),
    );
  }
}

Palette get pal => UiPrefs.instance.palette;

/// Switches between the unlock screen and the vault, and auto-locks after a
/// period of inactivity (time in the background counts too).
class Gate extends StatefulWidget {
  const Gate({super.key});

  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  // The real lock boundary used to be "any time the app leaves the
  // foreground" — but that fires on every trip to copy a password into
  // another app, which is the single most common thing this app is used
  // for. Lock only after being away this long, whether that's sitting idle
  // on screen or backgrounded.
  static const _idleLimit = Duration(hours: 1);
  final vault = Vault();
  Timer? _idle;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WindowsShell.start(onLock: _lock);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idle?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
      return;
    }
    if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt != null && DateTime.now().difference(pausedAt) > _idleLimit) {
        _lock();
      } else {
        _touch();
      }
    }
  }

  void _touch() {
    _idle?.cancel();
    if (vault.isUnlocked) _idle = Timer(_idleLimit, _lock);
  }

  void _lock() {
    if (!vault.isUnlocked) return;
    SecureClipboard.clear();
    AutofillBridge.forgetRecentPick();
    vault.lock();
    navKey.currentState?.popUntil((r) => r.isFirst);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touch(),
      child: vault.isUnlocked
          ? HomePage(vault: vault, onLock: _lock)
          : UnlockPage(
              vault: vault,
              onUnlocked: () {
                _touch();
                setState(() {});
              }),
    );
  }
}

/// Page background: the theme colour with a faint glow of the accent at the
/// top, so dark themes don't look flat.
class _Backdrop extends StatelessWidget {
  final Widget child;
  const _Backdrop({required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -1.1),
            radius: 1.3,
            colors: [
              pal.accent.withValues(alpha: pal.brightness == Brightness.dark ? 0.13 : 0.08),
              pal.bg,
            ],
          ),
        ),
        child: child,
      );
}

// ---------------------------------------------------------------- unlock

class UnlockPage extends StatefulWidget {
  final Vault vault;
  final VoidCallback onUnlocked;
  const UnlockPage({super.key, required this.vault, required this.onUnlocked});

  @override
  State<UnlockPage> createState() => _UnlockPageState();
}

class _UnlockPageState extends State<UnlockPage> {
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  bool? _exists;
  bool _busy = false;
  bool _hide = true;
  String? _error;

  /// The vault file couldn't be read and a backup copy exists.
  bool _damaged = false;

  @override
  void initState() {
    super.initState();
    Vault.exists().then((v) {
      if (mounted) setState(() => _exists = v);
    });
  }

  Future<void> _fromFolder() async {
    final path = await FilePicker.getDirectoryPath(
        dialogTitle: t('Dropbox/OneDrive/Drive senkron klasörünü seçin', 'Choose your Dropbox/OneDrive/Drive sync folder'));
    if (path == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await FolderBackend(path).download();
      if (bytes == null) {
        setState(() => _error = t('Seçilen klasörde kayıtlı kasa bulunamadı.', 'No saved vault found in the chosen folder.'));
      } else {
        await Vault.installRemote(bytes);
        await FolderSyncService.instance.setFolder(path);
        setState(() => _exists = true);
      }
    } catch (e) {
      setState(() => _error = t('Klasör okunamadı: $e', 'Couldn\'t read the folder: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fromDrive() async {
    final svc = SyncService.instance;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await svc.connect();
      final bytes = await svc.client.download();
      if (bytes == null) {
        setState(() => _error = t('Drive\'da kayıtlı kasa bulunamadı.', 'No saved vault found on Drive.'));
      } else {
        await Vault.installRemote(bytes);
        setState(() => _exists = true);
      }
    } catch (e) {
      setState(() => _error = t('Drive\'a bağlanılamadı: $e', 'Couldn\'t connect to Drive: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final creating = _exists == false;
    final pw = _pw.text;
    if (creating) {
      if (pw.length < 10) {
        return setState(() => _error = t('En az 10 karakter olmalı.', 'Must be at least 10 characters.'));
      }
      if (pw != _pw2.text) {
        return setState(() => _error = t('Şifreler eşleşmiyor.', 'Passwords don\'t match.'));
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      creating ? await widget.vault.create(pw) : await widget.vault.unlock(pw);
      _pw.clear();
      _pw2.clear();
      widget.onUnlocked();
    } on WrongPasswordException {
      setState(() => _error = t('Yanlış ana şifre.', 'Wrong master password.'));
    } on CorruptVaultException {
      final backup = await Vault.hasBackup();
      setState(() {
        _damaged = backup;
        _error = backup
            ? t('Kasa dosyası okunamadı, bozulmuş olabilir. Bir önceki kayıttan kalan yedeği aynı ana şifreyle açabilirsin.',
                'Couldn\'t read the vault file; it may be damaged. You can open the copy kept from the save before, with the same master password.')
            : t('Kasa dosyası okunamadı, bozulmuş olabilir; yedek kopyası da yok.',
                'Couldn\'t read the vault file; it may be damaged, and there is no backup copy.');
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.vault.unlockFromBackup(_pw.text);
      _pw.clear();
      widget.onUnlocked();
    } on WrongPasswordException {
      setState(() => _error = t('Yedek bu şifreyle açılmadı.', 'The backup didn\'t open with this password.'));
    } on CorruptVaultException {
      setState(() {
        _damaged = false;
        _error = t('Yedek de okunamadı.', 'The backup couldn\'t be read either.');
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_exists == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final creating = !_exists!;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      body: _Backdrop(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(28),
                children: [
                  Center(child: VaultMark(size: 96, color: pal.accent)),
                  const SizedBox(height: 18),
                  Text(appName,
                      textAlign: TextAlign.center,
                      style: tt.headlineMedium!.copyWith(fontWeight: FontWeight.w800, letterSpacing: 4)),
                  Text(t('ŞİFRE KASASI', 'PASSWORD VAULT'),
                      textAlign: TextAlign.center,
                      style: tt.labelMedium!.copyWith(color: pal.accent, letterSpacing: 3)),
                  const SizedBox(height: 28),
                  Text(creating ? t('Ana şifreni oluştur', 'Create your master password') : t('Kasa kilitli', 'Vault locked'),
                      textAlign: TextAlign.center, style: tt.titleLarge!.copyWith(fontWeight: FontWeight.w600)),
                  if (creating)
                    Container(
                      margin: const EdgeInsets.only(top: 14),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: pal.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: pal.border),
                      ),
                      child: Row(children: [
                        Icon(Icons.info_outline, color: pal.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            t('Ana şifreyi unutursan verilerin kurtarılamaz. '
                            'Şifre hiçbir yerde saklanmaz, yalnızca kasanı açar.', 'If you forget the master password, your data can\'t be recovered. It is never stored anywhere; it only opens your vault.'),
                            style: TextStyle(color: pal.muted),
                          ),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 22),
                  TextField(
                    controller: _pw,
                    obscureText: _hide,
                    autofocus: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    onSubmitted: (_) => creating ? null : _submit(),
                    decoration: InputDecoration(
                      hintText: t('Ana şifre', 'Master password'),
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                  if (creating) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pw2,
                      obscureText: _hide,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                          hintText: t('Ana şifre (tekrar)', 'Master password (again)'), prefixIcon: const Icon(Icons.lock_outline)),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(creating ? t('Kasayı oluştur', 'Create vault') : t('Kilidi aç', 'Unlock')),
                  ),
                  if (_damaged && !creating) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _restore,
                      icon: const Icon(Icons.restore),
                      label: Text(t('Yedekten aç', 'Open the backup')),
                    ),
                  ],
                  if (creating && SyncService.instance.configured) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _fromDrive,
                      icon: const Icon(Icons.cloud_download_outlined),
                      label: Text(t('Google Drive\'daki kasayı al', 'Get my vault from Google Drive')),
                    ),
                  ],
                  if (creating)
                    TextButton.icon(
                      onPressed: _busy ? null : _fromFolder,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(t('Senkron klasöründen kasayı al (manuel)', 'Get my vault from a sync folder (manual)')),
                    ),
                  const SizedBox(height: 18),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.shield_outlined, size: 16, color: pal.muted),
                    const SizedBox(width: 6),
                    // Flexible: on narrow (360 dp) phones the English line wraps
                    // instead of overflowing.
                    Flexible(
                      child: Text(
                          t('AES-256 · Argon2id · verilerin cihazında', 'AES-256 · Argon2id · your data stays on your device'),
                          textAlign: TextAlign.center,
                          style: tt.bodySmall!.copyWith(color: pal.muted)),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ home

/// What the list is narrowed to besides the search box.
enum _Filter { all, weak, medium, strong, reused, leaked }

class HomePage extends StatefulWidget {
  final Vault vault;
  final VoidCallback onLock;
  const HomePage({super.key, required this.vault, required this.onLock});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String _query = '';
  String? _category; // null = all
  _Filter _filter = _Filter.all;
  // Breach check results for this session (password hash → times seen).
  // Kept only in memory: cleared when the vault locks.
  Map<String, int>? _pwned;
  bool _pwnedBusy = false;
  bool _syncing = false;
  bool _syncAgain = false;
  // Which backend is active, if any. The folder is the plain, no-setup
  // option (Dropbox/OneDrive/Drive for Desktop/Syncthing); Drive-via-API is
  // an optional advanced mode that only works in a build with its own
  // Google Cloud credentials (lib/config.dart).
  SyncBackend? _backend;

  Vault get v => widget.vault;

  @override
  void initState() {
    super.initState();
    v.onChanged = () => _sync(silent: true);
    WidgetsBinding.instance.addObserver(this);
    _importAutofill();
    _loadBackend();
  }

  // Back from another app where a login was just saved through autofill.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }

  Future<void> _onResume() async {
    // The autofill fill screen may have saved to the vault file meanwhile
    // (e.g. tagged an app); take that in before this copy saves over it.
    await v.reloadFromDisk();
    if (mounted) setState(() {});
    await _importAutofill();
  }

  /// Logins saved by the Android autofill service while the vault was
  /// locked (or the app was in the background) go into the vault now.
  Future<void> _importAutofill() async {
    final int added, updated;
    try {
      (added, updated) = await AutofillBridge.importPending(v);
    } catch (_) {
      return; // nothing removed from the queue: retried next time
    }
    if (!mounted || added + updated == 0) return;
    setState(() {});
    _snack([
      if (added > 0) t('$added yeni şifre otomatik doldurmadan eklendi', '$added new passwords added from autofill'),
      if (updated > 0) t('$updated şifre güncellendi', '$updated passwords updated'),
    ].join(' · '));
  }

  Future<void> _loadBackend() async {
    final folder = await FolderSyncService.instance.backend();
    if (folder != null) {
      setState(() => _backend = folder);
      return _sync(silent: true);
    }
    if (await SyncService.instance.isEnabled()) {
      setState(() => _backend = SyncService.instance.client);
      _sync(silent: true);
    }
  }

  Future<void> _sync({bool silent = false, String? remotePassword}) async {
    final backend = _backend;
    if (backend == null) return;
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    setState(() => _syncing = true);
    try {
      final msg = await v.sync(backend, remotePassword: remotePassword);
      if (backend is DriveClient) unawaited(SyncService.instance.cleanUpOnce());
      if (mounted) {
        setState(() {});
        if (!silent) _snack(msg);
      }
    } on SyncPasswordMismatch {
      if (!mounted) return;
      if (silent || remotePassword != null) {
        _snack(remotePassword != null
            ? t('Bu şifre de ${backend.label} kopyasını açmadı.', 'That password did not open the ${backend.label} copy either.')
            : t('${backend.label} kopyası farklı bir ana şifreyle şifrelenmiş. Senkron düğmesine basıp o şifreyi gir.',
                'The ${backend.label} copy uses a different master password. Tap sync and enter that password.'));
      } else {
        // Ask for the synced copy's password: an older master password of
        // this vault, or the one set on another device.
        final pw = await _askPassword(t('${backend.label} kopyasının ana şifresi', 'Master password of the ${backend.label} copy'));
        if (pw != null && pw.isNotEmpty && mounted) {
          _syncing = false;
          // Awaited inside the try, so the finally below doesn't mark the
          // sync as finished while this retry is still running.
          await _sync(remotePassword: pw);
          return;
        }
      }
    } on DriveSignInLost catch (e) {
      // Even for a silent sync: otherwise sync would just quietly stop.
      await SyncService.instance.disconnect();
      if (!mounted) return;
      setState(() => _backend = null);
      _snack(e.message);
    } catch (e) {
      if (mounted && !silent) _snack(t('Senkron başarısız: $e', 'Sync failed: $e'));
    } finally {
      if (mounted) setState(() => _syncing = false);
      if (_syncAgain && mounted) {
        _syncAgain = false;
        _sync(silent: true);
      }
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.getDirectoryPath(
        dialogTitle: t('Dropbox/OneDrive/Drive senkron klasörünü seçin', 'Choose your Dropbox/OneDrive/Drive sync folder'));
    if (path == null) return;
    await SyncService.instance.disconnect();
    await FolderSyncService.instance.setFolder(path);
    setState(() => _backend = FolderBackend(path));
    await _sync();
  }

  Future<void> _stopFolderSync() async {
    await FolderSyncService.instance.clear();
    setState(() => _backend = null);
    _snack(t('Senkron kapatıldı. Klasördeki şifreli dosya silinmedi.', 'Sync turned off. The encrypted file in the folder was not deleted.'));
  }

  Future<void> _connectDrive() async {
    final svc = SyncService.instance;
    if (!svc.configured) {
      return _snack(t('Google kimlikleri lib/config.dart içine girilmemiş.', 'Google credentials are not set in lib/config.dart.'));
    }
    try {
      await FolderSyncService.instance.clear();
      await svc.connect();
      setState(() => _backend = svc.client);
      await _sync();
    } catch (e) {
      _snack(t('Bağlanılamadı: $e', 'Couldn\'t connect: $e'));
    }
  }

  Future<void> _disconnectDrive() async {
    await SyncService.instance.disconnect();
    setState(() => _backend = null);
    _snack(t('Drive bağlantısı kesildi. Drive\'daki şifreli kopya silinmedi.', 'Disconnected from Drive. The encrypted copy on Drive was not deleted.'));
  }

  @override
  void dispose() {
    v.onChanged = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _copy(String text, String label) async {
    await SecureClipboard.copy(text);
    _snack(t('$label kopyalandı (20 sn sonra panodan silinir)', '$label copied (cleared from the clipboard in 20 s)'));
  }

  Future<void> _open(String site) async {
    var s = site.trim();
    if (s.isEmpty) return;
    if (!s.contains('://')) s = 'https://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return _snack(t('Yalnızca http/https adresleri açılır.', 'Only http/https addresses can be opened.'));
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _edit([Entry? e]) async {
    final saved = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => EditPage(vault: v, entry: e, pwned: _pwned)));
    if (saved == true) setState(() {});
  }

  Future<void> _delete(Entry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('${displayTitle(e.site)} silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Vazgeç', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Sil', 'Delete'))),
        ],
      ),
    );
    if (ok == true) {
      await v.remove(e.id);
      setState(() {});
    }
  }

  Future<String?> _askPassword(String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c, obscureText: true, autofocus: true, decoration: InputDecoration(hintText: t('Şifre', 'Password'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('Vazgeç', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(t('Tamam', 'OK'))),
        ],
      ),
    );
  }

  Future<void> _changeMaster() async {
    final cur = await _askPassword(t('Mevcut ana şifre', 'Current master password'));
    if (cur == null || !mounted) return;
    final next = await _askPassword(t('Yeni ana şifre (en az 10 karakter)', 'New master password (at least 10 characters)'));
    if (next == null || !mounted) return;
    if (next.length < 10) return _snack(t('Yeni şifre en az 10 karakter olmalı.', 'The new password must be at least 10 characters.'));
    try {
      await v.changePassword(cur, next);
      _snack(t('Ana şifre değiştirildi.', 'Master password changed.'));
    } on WrongPasswordException {
      _snack(t('Mevcut şifre yanlış.', 'The current password is wrong.'));
    }
  }

  Future<void> _export() async {
    final bytes = await v.exportBackup();
    final path = await FilePicker.saveFile(
      dialogTitle: t('Şifreli yedeği kaydet', 'Save encrypted backup'),
      fileName: t('passlune-yedek.kasa', 'passlune-backup.kasa'),
      bytes: Uint8List.fromList(bytes),
    );
    // null = the user cancelled the save dialog (on every platform).
    if (path != null) _snack(t('Şifreli yedek kaydedildi.', 'Encrypted backup saved.'));
  }

  Future<void> _import() async {
    final f = await FilePicker.pickFile();
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    final pw = await _askPassword(t('Yedeğin ana şifresi', 'The backup\'s master password'));
    if (pw == null) return;
    try {
      final n = await v.importBackup(bytes, pw);
      setState(() {});
      _snack(t('$n kayıt içe aktarıldı.', '$n entries imported.'));
    } on WrongPasswordException {
      _snack(t('Yedek şifresi yanlış.', 'Wrong backup password.'));
    } on CorruptVaultException {
      _snack(t('Geçersiz yedek dosyası.', 'Invalid backup file.'));
    }
  }

  /// Logins exported as CSV from a browser or another password manager.
  Future<void> _importCsv() async {
    final f = await FilePicker.pickFile(
        dialogTitle: t('Şifre dışa aktarma dosyasını (CSV) seç', 'Choose the passwords export (CSV)'));
    if (f == null) return;
    final CsvImport found;
    try {
      found = readPasswordCsv(utf8.decode(await f.readAsBytes(), allowMalformed: true), v.entries);
    } on NotPasswordCsv {
      return _snack(t('Bu dosyada şifre sütunu yok. Chrome, Edge, Firefox, Bitwarden ya da KeePassXC\'den dışa aktarılmış bir CSV seç.',
          'This file has no password column. Choose a CSV exported from Chrome, Edge, Firefox, Bitwarden or KeePassXC.'));
    }
    if (!mounted) return;
    if (found.entries.isEmpty) {
      return _snack(found.duplicates > 0
          ? t('Bu dosyadaki kayıtların hepsi zaten kasanda.', 'Every entry in this file is already in your vault.')
          : t('Bu dosyada içe aktarılacak kayıt yok.', 'There is nothing to import in this file.'));
    }
    final n = found.entries.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('$n kayıt içe aktarılsın mı?', 'Import $n entries?')),
        content: Text([
          if (found.duplicates > 0)
            t('${found.duplicates} kayıt zaten kasanda olduğu için atlanacak.',
                '${found.duplicates} entries are already in your vault and will be skipped.'),
          t('CSV dosyası şifrelerini açık metin olarak içerir. İçe aktardıktan sonra dosyayı sil (çöp kutusundan da).',
              'The CSV file holds your passwords as plain text. Delete it after the import (from the bin too).'),
        ].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Vazgeç', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('İçe aktar', 'Import'))),
        ],
      ),
    );
    if (ok != true) return;
    await v.addAll(found.entries);
    if (!mounted) return;
    setState(() {});
    _snack(t('$n kayıt içe aktarıldı. CSV dosyasını silmeyi unutma.', '$n entries imported. Don\'t forget to delete the CSV file.'));
  }

  // ------------------------------------------------------------ settings

  void _settings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        Widget item(IconData icon, String title, String? sub, VoidCallback onTap) => ListTile(
              leading: _IconTile(icon: icon),
              title: Text(title),
              subtitle: sub == null ? null : Text(sub, style: TextStyle(color: pal.muted)),
              trailing: Icon(Icons.chevron_right, color: pal.muted),
              onTap: () {
                Navigator.pop(ctx);
                onTap();
              },
            );
        return SafeArea(
          child: ListenableBuilder(
            listenable: UiPrefs.instance,
            builder: (_, _) => ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              children: [
                _SectionTitle(t('Tema', 'Theme')),
                SizedBox(
                  height: 92,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [for (final p in palettes) _ThemeSwatch(p)],
                  ),
                ),
                _SectionTitle(t('Dil', 'Language')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: 'auto', label: Text(t('Otomatik', 'Auto'))),
                      const ButtonSegment(value: 'en', label: Text('English')),
                      const ButtonSegment(value: 'tr', label: Text('Türkçe')),
                    ],
                    selected: {UiPrefs.instance.lang},
                    onSelectionChanged: (s) => UiPrefs.instance.setLang(s.first),
                  ),
                ),
                _SectionTitle(t('Senkron', 'Sync')),
                if (SyncService.instance.configured)
                  item(
                    Icons.cloud_outlined,
                    _backend is DriveClient ? t('Google Drive bağlantısını kes', 'Disconnect Google Drive') : t('Google Drive ile senkronize et', 'Sync with Google Drive'),
                    t('Şifreli kasa Drive\'ında yalnızca bu uygulamanın gördüğü klasörde durur', 'The encrypted vault sits in a Drive folder only this app can see'),
                    () => _backend is DriveClient ? _disconnectDrive() : _connectDrive(),
                  ),
                item(
                  Icons.folder_outlined,
                  _backend is FolderBackend ? t('Senkron klasörünü kapat', 'Turn off folder sync') : t('Senkron klasörü seç', 'Choose a sync folder'),
                  t('Dropbox, OneDrive, Syncthing klasörü (manuel)', 'Dropbox, OneDrive, Syncthing folder (manual)'),
                  () => _backend is FolderBackend ? _stopFolderSync() : _pickFolder(),
                ),
                _SectionTitle(t('Yedek', 'Backup')),
                item(Icons.upload_outlined, t('Şifreli yedek al', 'Create encrypted backup'), t('Tüm kayıtlar AES-256 ile şifreli .kasa dosyası', 'All entries in an AES-256 encrypted .kasa file'),
                    _export),
                item(Icons.download_outlined, t('Yedekten içe aktar', 'Import from backup'), t('.kasa dosyasındaki kayıtları ekle', 'Add the entries from a .kasa file'), _import),
                item(Icons.table_view_outlined, t('CSV\'den içe aktar', 'Import from CSV'),
                    'Chrome, Edge, Firefox, Bitwarden, KeePassXC', _importCsv),
                if (AutofillBridge.available) ...[
                  _SectionTitle(t('Otomatik doldurma', 'Autofill')),
                  item(
                    Icons.password_outlined,
                    t('Şifreleri kaydet ve doldur', 'Save and fill passwords'),
                    t('Başka uygulamalarda ve Chrome\'da girilen şifreleri Passlune\'a kaydet',
                        'Save logins typed in other apps and Chrome to Passlune'),
                    () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AutofillPage())),
                  ),
                ],
                _SectionTitle(t('Güvenlik', 'Security')),
                item(Icons.password, t('Ana şifreyi değiştir', 'Change master password'), null, _changeMaster),
                item(Icons.lock_outline, t('Şimdi kilitle', 'Lock now'), null, widget.onLock),
                if (WindowsShell.available) ...[
                  const _SectionTitle('Windows'),
                  const _WindowsOptions(),
                ],
                _SectionTitle(t('Uygulama', 'App')),
                item(Icons.info_outline, t('Hakkında', 'About'), t('Destek, gizlilik, sürüm', 'Support, privacy, version'),
                    () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutPage(appName: appName)))),
              ],
            ),
          ),
        );
      },
    );
  }

  // ----------------------------------------------------------------- build

  /// How many times the entry's password was seen in breaches (0 if not,
  /// or not checked yet).
  int _seen(Entry e) => e.password.isEmpty ? 0 : (_pwned?[pwHash(e.password)] ?? 0);

  /// Ids of entries whose password the last check found in breaches.
  Set<String> _leakedIds(List<Entry> all) {
    final p = _pwned;
    if (p == null) return {};
    return {for (final e in all) if (e.password.isNotEmpty && (p[pwHash(e.password)] ?? 0) > 0) e.id};
  }

  Future<void> _askBreachCheck() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: Icon(Icons.gpp_maybe_outlined, color: strengthColor[Strength.weak], size: 36),
        title: Text(t('Şifrelerin sızıntılarda görülmüş mü?', 'Exposed password check')),
        content: Text(t(
          'Şifrelerinin, geçmişteki veri sızıntılarından toplanmış ve saldırganların bildiği şifre listelerinde '
              'olup olmadığı Have I Been Pwned servisinde kontrol edilir.\n\n'
              'Önemli: Bu kontrol hesabının çalındığını göstermez. Yalnızca şifrenin kendisinin bu listelerde '
              'olduğunu gösterir; aynı şifreyi başka biri kullanmış da olabilir. Ama saldırganlar şifre denerken '
              'önce bu listeleri kullandığı için listedeki şifreleri değiştirmen iyi olur.\n\n'
              'Şifrelerin gönderilmez: her şifrenin SHA-1 özetinin yalnızca ilk 5 karakteri gönderilir, '
              'karşılaştırma cihazında yapılır. Sonuçlar yalnızca kasa açıkken bellekte tutulur.\n\nİnternet gerekir.',
          'Checks whether your passwords appear in the password lists collected from past data breaches, '
              'the lists attackers try first, using the Have I Been Pwned service.\n\n'
              'Important: this does not mean your account was stolen. It only shows that the password itself is on '
              'those lists; someone else may have used the same password. Still, attackers try these lists first, '
              'so it is best to change any password found there.\n\n'
              'Your passwords are not sent: only the first 5 characters of each password\'s SHA-1 hash leave the device, '
              'and the comparison happens here. Results are kept in memory only while the vault is open.\n\nNeeds internet.',
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t('Vazgeç', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t('Kontrol et', 'Check'))),
        ],
      ),
    );
    if (ok == true) await _runBreachCheck();
  }

  Future<void> _runBreachCheck() async {
    final hashes = {for (final e in v.entries) if (e.password.isNotEmpty) pwHash(e.password)};
    if (hashes.isEmpty) return _snack(t('Kontrol edilecek şifre yok.', 'No passwords to check.'));
    setState(() => _pwnedBusy = true);
    try {
      final res = await checkPwned(hashes);
      if (!mounted) return;
      setState(() => _pwned = {...?_pwned, ...res});
      final n = _leakedIds(v.entries).length;
      _snack(n == 0
          ? t('Şifrelerinin hiçbiri sızıntı listelerinde yok.', 'None of your passwords are on breach lists.')
          : t('$n kayıttaki şifre sızıntı listelerinde var. Bu hesabın çalındığı anlamına gelmez, ama bu şifreleri değiştirmen iyi olur.',
              'Passwords in $n entries are on breach lists. This does not mean those accounts were stolen, but it is best to change them.'));
      if (n > 0) setState(() => _filter = _Filter.leaked);
    } catch (e) {
      if (mounted) _snack(t('Kontrol edilemedi: $e', 'Couldn\'t check: $e'));
    } finally {
      if (mounted) setState(() => _pwnedBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = v.entries;
    final report = VaultReport.of(all);
    final leaked = _leakedIds(all);
    final q = _query.toLowerCase();
    bool passes(Entry e) => switch (_filter) {
          _Filter.all => true,
          _Filter.weak => report.strengthById[e.id] == Strength.weak,
          _Filter.medium => report.strengthById[e.id] == Strength.medium,
          _Filter.strong => report.strengthById[e.id] == Strength.strong,
          _Filter.reused => report.reusedIds.contains(e.id),
          _Filter.leaked => leaked.contains(e.id),
        };
    final list = all
        .where((e) =>
            (_category == null || categoryOf(e).id == _category) &&
            passes(e) &&
            (q.isEmpty ||
                e.site.toLowerCase().contains(q) ||
                e.username.toLowerCase().contains(q) ||
                e.notes.toLowerCase().contains(q)))
        .toList()
      ..sort((a, b) => displayTitle(a.site).toLowerCase().compareTo(displayTitle(b.site).toLowerCase()));
    // Leaked list: the most common (most dangerous) passwords first.
    if (_filter == _Filter.leaked) list.sort((a, b) => _seen(b).compareTo(_seen(a)));
    final counts = <String, int>{};
    for (final e in all) {
      counts.update(categoryOf(e).id, (n) => n + 1, ifAbsent: () => 1);
    }
    final grid = UiPrefs.instance.grid;
    final width = MediaQuery.sizeOf(context).width;

    return Scaffold(
      floatingActionButton: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: pal.accent.withValues(alpha: 0.45), blurRadius: 22)],
        ),
        child: FloatingActionButton(
          onPressed: () => _edit(),
          tooltip: t('Yeni kayıt', 'New entry'),
          elevation: 0,
          highlightElevation: 0,
          backgroundColor: pal.accent,
          foregroundColor: pal.onAccent,
          shape: const CircleBorder(),
          child: const Icon(Icons.add, size: 30),
        ),
      ),
      body: _Backdrop(
        child: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _header(context)),
              SliverToBoxAdapter(child: _dashboard(report, leaked)),
              SliverToBoxAdapter(child: _searchRow()),
              SliverToBoxAdapter(child: _categoryBar(counts, all.length)),
              if (_filter != _Filter.all)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Row(children: [
                      InputChip(
                        label: Text(switch (_filter) {
                          _Filter.weak => t('Zayıf şifreler', 'Weak passwords'),
                          _Filter.medium => t('Orta şifreler', 'Medium passwords'),
                          _Filter.strong => t('Güçlü şifreler', 'Strong passwords'),
                          _Filter.reused => t('Tekrar kullanılan şifreler', 'Reused passwords'),
                          _Filter.leaked => t('Sızıntılarda görülen şifreler', 'Exposed passwords'),
                          _Filter.all => '',
                        }),
                        onDeleted: () => setState(() => _filter = _Filter.all),
                      ),
                      const Spacer(),
                      // After changing passwords, check again.
                      if (_filter == _Filter.leaked)
                        TextButton.icon(
                          onPressed: _pwnedBusy ? null : _runBreachCheck,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(t('Yeniden kontrol et', 'Check again')),
                        ),
                    ]),
                  ),
                ),
              if (list.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(hasEntries: all.isNotEmpty),
                )
              else if (grid)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: width > 900 ? 4 : (width > 600 ? 3 : 2),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 150,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, i) => _card(list[i], report, compact: true),
                      childCount: list.length,
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                  sliver: SliverList.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _card(list[i], report),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final sync = _backend == null
        ? t('Yalnızca bu cihazda', 'On this device only')
        : (_syncing ? t('Senkronize ediliyor…', 'Syncing…') : t('Senkron: ${_backend!.label}', 'Sync: ${_backend!.label}'));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(children: [
        VaultMark(size: 42, color: pal.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(appName, style: tt.titleLarge!.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.5)),
            Text(sync, style: tt.bodySmall!.copyWith(color: _backend == null ? pal.muted : pal.accent)),
          ]),
        ),
        if (_backend != null)
          _SquareButton(
            icon: Icons.sync,
            tooltip: t('Şimdi senkronize et', 'Sync now'),
            busy: _syncing,
            onTap: () => _sync(),
          ),
        _SquareButton(icon: Icons.lock_outline, tooltip: t('Kilitle', 'Lock'), onTap: widget.onLock),
        _SquareButton(icon: Icons.tune, tooltip: t('Ayarlar', 'Settings'), onTap: _settings),
      ]),
    );
  }

  Widget _dashboard(VaultReport r, Set<String> leakedIds) {
    final leaked = leakedIds.length;
    Widget stat(String label, Object n, Color color, _Filter f, {VoidCallback? onTap, bool busy = false}) {
      final on = _filter == f;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap ?? () => setState(() => _filter = on ? _Filter.all : f),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: on ? color.withValues(alpha: 0.14) : pal.surface2,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: on ? color : pal.border),
            ),
            child: Column(children: [
              SizedBox(
                height: 30,
                child: Center(
                  child: busy
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                      : Text('$n', style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w700)),
                ),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(label, style: TextStyle(color: pal.muted, fontSize: 12)),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    const gap = SizedBox(width: 6);
    final score = r.scoreWith(leakedIds);
    final scoreColor = score >= 80
        ? strengthColor[Strength.strong]!
        : (score >= 50 ? strengthColor[Strength.medium]! : strengthColor[Strength.weak]!);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: pal.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: pal.border),
        ),
        child: Column(children: [
          Row(children: [
            stat(t('Toplam', 'Total'), r.total, pal.accent, _Filter.all),
            gap,
            stat(t('Zayıf', 'Weak'), r.weak, strengthColor[Strength.weak]!, _Filter.weak),
            gap,
            stat(t('Orta', 'Medium'), r.medium, strengthColor[Strength.medium]!, _Filter.medium),
            gap,
            stat(t('Güçlü', 'Strong'), r.strong, strengthColor[Strength.strong]!, _Filter.strong),
            gap,
            stat(t('Tekrar', 'Reused'), r.reusedIds.length, pal.accent, _Filter.reused),
            gap,
            stat(
              t('Sızıntıda', 'Exposed'),
              _pwned == null ? '?' : leaked,
              strengthColor[Strength.weak]!,
              _Filter.leaked,
              busy: _pwnedBusy,
              onTap: _pwnedBusy
                  ? () {}
                  : (_pwned == null
                      ? _askBreachCheck
                      : () => setState(() => _filter = _filter == _Filter.leaked ? _Filter.all : _Filter.leaked)),
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Icon(Icons.health_and_safety_outlined, size: 18, color: scoreColor),
            const SizedBox(width: 8),
            Text(t('Güvenlik puanı', 'Security score'), style: TextStyle(color: pal.muted, fontSize: 13)),
            const Spacer(),
            Text('$score', style: TextStyle(color: scoreColor, fontWeight: FontWeight.w700)),
            Text(' / 100', style: TextStyle(color: pal.muted, fontSize: 13)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(children: [
              Container(height: 8, color: pal.surface2),
              FractionallySizedBox(
                widthFactor: score / 100,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [
                      strengthColor[Strength.weak]!,
                      strengthColor[Strength.medium]!,
                      strengthColor[Strength.strong]!,
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _searchRow() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              onChanged: (t) => setState(() => _query = t),
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: t('Site, kullanıcı adı ya da not ara', 'Search site, username or note'),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _LayoutToggle(
            grid: UiPrefs.instance.grid,
            onChanged: (g) => UiPrefs.instance.setGrid(g),
          ),
        ]),
      );

  Widget _categoryBar(Map<String, int> counts, int total) {
    Widget chip(String? id, IconData icon, String label, int n) {
      final on = _category == id;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () => setState(() => _category = id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: on ? pal.accent : pal.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: on ? pal.accent : pal.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 18, color: on ? pal.onAccent : pal.muted),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: on ? pal.onAccent : pal.text, fontWeight: FontWeight.w500)),
              const SizedBox(width: 6),
              Text('$n', style: TextStyle(color: on ? pal.onAccent.withValues(alpha: 0.75) : pal.muted, fontSize: 12)),
            ]),
          ),
        ),
      );
    }

    return SizedBox(
      height: 54,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        children: [
          chip(null, Icons.apps, t('Tümü', 'All'), total),
          for (final c in categories)
            if ((counts[c.id] ?? 0) > 0) chip(c.id, c.icon, c.label, counts[c.id]!),
        ],
      ),
    );
  }

  Widget _card(Entry e, VaultReport r, {bool compact = false}) {
    final cat = categoryOf(e);
    final s = r.strengthById[e.id];
    final reused = r.reusedIds.contains(e.id);
    final title = displayTitle(e.site);
    final tt = Theme.of(context).textTheme;
    final seen = _seen(e);
    final strength = seen > 0
        ? Tooltip(
            message: t('Bu şifre sızıntı listelerinde $seen kez geçiyor', 'This password appears $seen times on breach lists'),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.gpp_bad_outlined, size: 15, color: strengthColor[Strength.weak]),
              const SizedBox(width: 3),
              Text(_compact(seen),
                  style: TextStyle(color: strengthColor[Strength.weak], fontSize: 12, fontWeight: FontWeight.w700)),
            ]),
          )
        : s == null
            ? const SizedBox.shrink()
            : Text(strengthLabel[s]!,
                style: TextStyle(color: strengthColor[s], fontSize: 12, fontWeight: FontWeight.w600));
    final menu = PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: pal.muted, size: 20),
      onSelected: (x) {
        if (x == 'user') _copy(e.username, t('Kullanıcı adı', 'Username'));
        if (x == 'pw') _copy(e.password, t('Şifre', 'Password'));
        if (x == 'open') _open(e.site);
        if (x == 'del') _delete(e);
      },
      itemBuilder: (_) => [
        if (e.username.isNotEmpty) PopupMenuItem(value: 'user', child: Text(t('Kullanıcı adını kopyala', 'Copy username'))),
        if (e.password.isNotEmpty) PopupMenuItem(value: 'pw', child: Text(t('Şifreyi kopyala', 'Copy password'))),
        if (cat.id != 'note' && cat.id != 'wifi') PopupMenuItem(value: 'open', child: Text(t('Siteyi aç', 'Open site'))),
        PopupMenuItem(value: 'del', child: Text(t('Sil', 'Delete'))),
      ],
    );
    final copyPw = e.password.isEmpty
        ? const SizedBox.shrink()
        : IconButton(
            tooltip: t('Şifreyi kopyala', 'Copy password'),
            icon: Icon(Icons.key_outlined, color: pal.accent, size: 20),
            onPressed: () => _copy(e.password, t('Şifre', 'Password')),
          );

    return Material(
      color: pal.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: pal.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _edit(e),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, compact ? 12 : 10, 4, compact ? 8 : 10),
          child: compact
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    _IconTile(icon: cat.icon, size: 38),
                    const Spacer(),
                    menu,
                  ]),
                  const SizedBox(height: 8),
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: tt.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
                  Text(cat.label, style: TextStyle(color: pal.accent, fontSize: 12)),
                  const Spacer(),
                  Row(children: [
                    Expanded(
                      child: Text(maskUser(e.username), maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: pal.muted, fontSize: 12)),
                    ),
                    const SizedBox(width: 6),
                    strength,
                    const SizedBox(width: 10),
                  ]),
                ])
              : Row(children: [
                  _IconTile(icon: cat.icon, size: 44),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: tt.titleSmall!.copyWith(fontWeight: FontWeight.w700)),
                        ),
                        if (reused) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: t('Bu şifre başka kayıtlarda da kullanılıyor', 'This password is also used in other entries'),
                            child: Icon(Icons.repeat, size: 15, color: strengthColor[Strength.medium]),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 2),
                      Row(children: [
                        Text(cat.label, style: TextStyle(color: pal.accent, fontSize: 12)),
                        if (e.username.isNotEmpty) ...[
                          Text('  ·  ', style: TextStyle(color: pal.muted, fontSize: 12)),
                          Flexible(
                            child: Text(maskUser(e.username), maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: pal.muted, fontSize: 12)),
                          ),
                        ],
                      ]),
                    ]),
                  ),
                  strength,
                  copyPw,
                  menu,
                ]),
        ),
      ),
    );
  }
}

/// 257752 → "257B" / "257K", 52372427 → "52M": breach counts at a glance.
String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
  if (n >= 1000) return isTr ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}B' : '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
  return '$n';
}

// ------------------------------------------------------- small widgets

class _IconTile extends StatelessWidget {
  final IconData icon;
  final double size;
  const _IconTile({required this.icon, this.size = 40});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: pal.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(size * 0.3),
          border: Border.all(color: pal.accent.withValues(alpha: 0.25)),
        ),
        child: Icon(icon, color: pal.accent, size: size * 0.5),
      );
}

class _SquareButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool busy;
  static const double size = 42;
  const _SquareButton({required this.icon, required this.tooltip, required this.onTap, this.busy = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : onTap,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: pal.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: pal.border),
              ),
              child: busy
                  ? Padding(
                      padding: EdgeInsets.all(size * 0.3),
                      child: CircularProgressIndicator(strokeWidth: 2, color: pal.accent),
                    )
                  : Icon(icon, color: pal.text, size: 21),
            ),
          ),
        ),
      );
}

/// List / grid switch: two icons, the active one filled with the accent.
class _LayoutToggle extends StatelessWidget {
  final bool grid;
  final ValueChanged<bool> onChanged;
  const _LayoutToggle({required this.grid, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget half(bool forGrid, IconData icon, String tip) {
      final on = grid == forGrid;
      return Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onChanged(forGrid),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: on ? pal.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: on ? pal.onAccent : pal.muted),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: pal.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: pal.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        half(false, Icons.view_agenda_outlined, t('Liste görünümü', 'List view')),
        half(true, Icons.grid_view, t('Izgara görünümü', 'Grid view')),
      ]),
    );
  }
}

/// Settings on Windows: start with Windows, and keep running next to the
/// clock when the window is closed.
class _WindowsOptions extends StatefulWidget {
  const _WindowsOptions();

  @override
  State<_WindowsOptions> createState() => _WindowsOptionsState();
}

class _WindowsOptionsState extends State<_WindowsOptions> {
  bool? _autostart;

  @override
  void initState() {
    super.initState();
    WindowsShell.autostart().then((on) {
      if (mounted) setState(() => _autostart = on);
    });
  }

  Future<void> _setAutostart(bool on) async {
    setState(() => _autostart = on);
    try {
      await WindowsShell.setAutostart(on);
    } catch (_) {
      if (!mounted) return;
      setState(() => _autostart = !on);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t('Windows başlangıç ayarı değiştirilemedi.', 'Couldn\'t change the Windows startup setting.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData icon, String title, String sub, bool? value, ValueChanged<bool> onChanged) => SwitchListTile(
          secondary: _IconTile(icon: icon),
          title: Text(title),
          subtitle: Text(sub, style: TextStyle(color: pal.muted)),
          value: value ?? false,
          onChanged: value == null ? null : onChanged,
        );
    final tray = UiPrefs.instance.tray;
    return Column(children: [
      tile(
        Icons.power_settings_new,
        t('Windows açılışında başlat', 'Start with Windows'),
        tray
            ? t('Saatin yanındaki simge olarak başlar, pencere açılmaz', 'Starts as an icon next to the clock, no window')
            : t('Windows\'a girişte Passlune açılır', 'Passlune opens when you sign in to Windows'),
        _autostart,
        _setAutostart,
      ),
      tile(
        Icons.move_to_inbox_outlined,
        t('Kapatınca simge durumunda kalsın', 'Keep running when closed'),
        t('Pencereyi kapatınca saatin yanında çalışmaya devam eder. Tamamen kapatmak için simgeye sağ tıkla, Çıkış.',
            'Closing the window keeps it next to the clock. To quit, right-click the icon and choose Quit.'),
        tray,
        (on) => WindowsShell.setTray(on),
      ),
    ]);
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Text(text.toUpperCase(),
            style: TextStyle(color: pal.accent, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.4)),
      );
}

class _ThemeSwatch extends StatelessWidget {
  final Palette p;
  const _ThemeSwatch(this.p);

  @override
  Widget build(BuildContext context) {
    final on = UiPrefs.instance.palette.id == p.id;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => UiPrefs.instance.setPalette(p),
        child: Column(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: p.bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: on ? p.accent : pal.border, width: on ? 2.5 : 1),
            ),
            child: Center(
              child: on
                  ? Icon(Icons.check, color: p.accent)
                  : Container(width: 22, height: 22, decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle)),
            ),
          ),
          const SizedBox(height: 6),
          Text(p.name, style: TextStyle(fontSize: 12, color: on ? pal.accent : pal.muted)),
        ]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasEntries;
  const _EmptyState({required this.hasEntries});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(hasEntries ? Icons.search_off : Icons.inventory_2_outlined, size: 56, color: pal.muted),
          const SizedBox(height: 12),
          Text(hasEntries ? t('Eşleşen kayıt yok', 'No matching entries') : t('Kasan boş', 'Your vault is empty'),
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(hasEntries ? t('Aramayı ya da filtreyi değiştir.', 'Change the search or the filter.') : t('İlk şifreni eklemek için + düğmesine dokun.', 'Tap + to add your first password.'),
              style: TextStyle(color: pal.muted), textAlign: TextAlign.center),
        ]),
      );
}

// ------------------------------------------------------------------ edit

class EditPage extends StatefulWidget {
  final Vault vault;
  final Entry? entry;

  /// Results of a breach check run from the home screen, if any.
  final Map<String, int>? pwned;
  const EditPage({super.key, required this.vault, this.entry, this.pwned});

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  late final _site = TextEditingController(text: widget.entry?.site);
  late final _user = TextEditingController(text: widget.entry?.username);
  late final _pass = TextEditingController(text: widget.entry?.password);
  late final _notes = TextEditingController(text: widget.entry?.notes);
  // Picked by the user, or null to keep guessing it from the site name as
  // it is typed (and saved empty, so the guess also follows later edits).
  late String? _picked = (widget.entry?.category.isEmpty ?? true) ? null : widget.entry!.category;
  String get _category => _picked ?? categoryOf(Entry(id: '', site: _site.text, username: '', password: '')).id;
  double _len = 18;
  bool _hide = true;
  // Opening an existing entry starts in a read-only "view" mode — tapping a
  // row used to drop straight into an editable form, so a stray keystroke
  // (or an accidental swipe-to-select-all-and-type on mobile) could alter
  // or blank out a saved password without meaning to. A new entry has
  // nothing to protect, so it starts editable.
  late bool _readOnly = widget.entry != null;
  final _form = GlobalKey<FormState>();

  bool get _isNote => _category == 'note';

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final e = widget.entry ?? Entry(id: newId(), site: '', username: '', password: '');
    e
      ..site = _site.text.trim()
      ..username = _user.text.trim()
      ..password = _pass.text
      ..notes = _notes.text
      ..category = _picked ?? '';
    await widget.vault.upsert(e);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _copy(String text, String label) async {
    await SecureClipboard.copy(text);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(t('$label kopyalandı (20 sn sonra panodan silinir)', '$label copied (cleared from the clipboard in 20 s)'))));
  }

  String? _required(String? s) => (s == null || s.trim().isEmpty) ? t('Zorunlu alan', 'Required') : null;

  /// How many other entries already use the password being typed.
  int get _reuse => widget.vault.entries
      .where((e) => e.id != widget.entry?.id && e.password.isNotEmpty && e.password == _pass.text)
      .length;

  @override
  Widget build(BuildContext context) {
    final cat = categoryById(_category);
    final s = _pass.text.isEmpty ? null : strengthOf(_pass.text);
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Text(widget.entry == null ? t('Yeni kayıt', 'New entry') : (_readOnly ? t('Kayıt', 'Entry') : t('Kaydı düzenle', 'Edit entry'))),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: pal.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(cat.icon, size: 14, color: pal.accent),
              const SizedBox(width: 4),
              Text(cat.label, style: TextStyle(color: pal.accent, fontSize: 12)),
            ]),
          ),
        ]),
        actions: [
          if (_readOnly)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: t('Düzenle', 'Edit'),
              onPressed: () => setState(() => _readOnly = false),
            ),
        ],
      ),
      bottomNavigationBar: _readOnly
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton(onPressed: () => Navigator.pop(context), child: Text(t('Vazgeç', 'Cancel'))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: FilledButton(onPressed: _save, child: Text(t('Kaydet', 'Save')))),
                ]),
              ),
            ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_readOnly) ...[
              _SectionTitle(t('Kategori', 'Category')),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in categories)
                    ChoiceChip(
                      avatar: Icon(c.icon, size: 18, color: _category == c.id ? pal.onAccent : pal.muted),
                      label: Text(c.label),
                      selected: _category == c.id,
                      showCheckmark: false,
                      selectedColor: pal.accent,
                      labelStyle: TextStyle(color: _category == c.id ? pal.onAccent : pal.text),
                      onSelected: (_) => setState(() => _picked = c.id),
                    ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            TextFormField(
              controller: _site,
              readOnly: _readOnly,
              validator: _required,
              // The guessed category follows the site as it is typed.
              onChanged: (_) => _picked == null ? setState(() {}) : null,
              decoration: InputDecoration(
                labelText: _isNote ? t('Başlık', 'Title') : (_category == 'wifi' ? t('Ağ adı', 'Network name') : t('Site ya da başlık', 'Site or title')),
                prefixIcon: Icon(_isNote ? Icons.title : Icons.language),
              ),
            ),
            if (!_isNote) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _user,
                readOnly: _readOnly,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _category == 'email' ? t('E-posta', 'Email') : t('Kullanıcı adı', 'Username'),
                  prefixIcon: const Icon(Icons.person_outline),
                  suffixIcon: _readOnly
                      ? IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: t('Kopyala', 'Copy'),
                          onPressed: () => _copy(_user.text, t('Kullanıcı adı', 'Username')),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _pass,
                readOnly: _readOnly,
                validator: _required,
                obscureText: _hide,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: t('Şifre', 'Password'),
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                      if (_readOnly)
                        IconButton(
                          icon: const Icon(Icons.copy),
                          tooltip: t('Kopyala', 'Copy'),
                          onPressed: () => _copy(_pass.text, t('Şifre', 'Password')),
                        ),
                    ],
                  ),
                ),
              ),
              if (s != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  for (var i = 0; i < 3; i++)
                    Expanded(
                      child: Container(
                        height: 6,
                        margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                        decoration: BoxDecoration(
                          color: i <= s.index ? strengthColor[s] : pal.surface2,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Text(strengthLabel[s]!, style: TextStyle(color: strengthColor[s], fontWeight: FontWeight.w600)),
                ]),
              ],
              if ((widget.pwned?[pwHash(_pass.text)] ?? 0) > 0)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: strengthColor[Strength.weak]!.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: strengthColor[Strength.weak]!.withValues(alpha: 0.5)),
                  ),
                  child: Row(children: [
                    Icon(Icons.gpp_bad_outlined, color: strengthColor[Strength.weak]),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(t(
                        'Bu şifre sızıntı listelerinde ${widget.pwned![pwHash(_pass.text)]} kez geçiyor. Hesabın çalındığı anlamına gelmez, ama saldırganlar bu listeleri ilk dener: değiştirmen iyi olur.',
                        'This password appears ${widget.pwned![pwHash(_pass.text)]} times on breach lists. That does not mean this account was stolen, but attackers try these lists first: change it.',
                      )),
                    ),
                  ]),
                ),
              if (_reuse > 0)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: strengthColor[Strength.medium]!.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: strengthColor[Strength.medium]!.withValues(alpha: 0.5)),
                  ),
                  child: Row(children: [
                    Icon(Icons.repeat, color: strengthColor[Strength.medium]),
                    const SizedBox(width: 10),
                    Expanded(child: Text(t('Bu şifre $_reuse kayıtta daha kullanılıyor. Her siteye ayrı şifre daha güvenli.', 'This password is used in $_reuse other entries. A separate password for each site is safer.'))),
                  ]),
                ),
              if (!_readOnly) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: Slider(
                      value: _len,
                      min: 8,
                      max: 48,
                      divisions: 40,
                      label: '${_len.round()}',
                      onChanged: (x) => setState(() => _len = x),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.casino_outlined),
                    label: Text(t('Üret (${_len.round()})', 'Generate (${_len.round()})')),
                    onPressed: () => setState(() {
                      _pass.text = generatePassword(_len.round());
                      _hide = false;
                    }),
                  ),
                ]),
              ],
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              readOnly: _readOnly,
              maxLines: _isNote ? 10 : 3,
              decoration: InputDecoration(
                labelText: _isNote ? t('Not', 'Note') : t('Not (isteğe bağlı)', 'Note (optional)'),
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
