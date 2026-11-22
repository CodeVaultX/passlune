import 'dart:io';

/// A place the encrypted vault blob can be read from and written to.
///
/// Both Google Drive (via API) and a plain synced folder (Dropbox, OneDrive,
/// Google Drive for Desktop, Syncthing, ...) implement this the same way, so
/// [Vault.sync] doesn't need to know which one it's talking to.
abstract class SyncBackend {
  Future<List<int>?> download();
  Future<void> upload(List<int> bytes);

  /// Short label for messages, e.g. "Dropbox/Passlune".
  String get label;
}

/// Syncs through an ordinary folder that some other app (Dropbox, OneDrive,
/// Google Drive for Desktop, Syncthing, a network share, ...) already keeps
/// in sync across devices. No account, API key or internet permission is
/// needed here — the syncing app does that part on its own.
class FolderBackend implements SyncBackend {
  static const fileName = 'vault.kasa';
  final String folderPath;
  FolderBackend(this.folderPath);

  File get _file => File('$folderPath${Platform.pathSeparator}$fileName');

  @override
  String get label => folderPath;

  @override
  Future<List<int>?> download() async {
    final f = _file;
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> upload(List<int> bytes) async {
    final dir = Directory(folderPath);
    if (!await dir.exists()) await dir.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(_file.path);
  }
}
