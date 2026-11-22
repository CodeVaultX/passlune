import 'package:flutter_test/flutter_test.dart';
import 'package:passlune/drive.dart';

void main() {
  test('only the files old Voicelune wrote are picked for cleanup', () {
    for (final name in [
      'library.json',
      'rules.json',
      'premium.json',
      'book_1a4ac899c615974ab60b3822c2f67667.epub',
      'book_00a2b575bb8fc0c0f7e346c3f2f1d281.pdf',
      'tr_1a4ac899c615974ab60b3822c2f67667_tr_google.json',
    ]) {
      expect(DriveClient.isOldVoiceluneFile(name), isTrue, reason: name);
    }
    for (final name in [
      'vault.kasa',
      'vault.kasa.bak',
      'backup.zip',
      'settings.json',
      'book_notes.txt',
      'library.json.bak',
      'tr_short_tr_google.json',
    ]) {
      expect(DriveClient.isOldVoiceluneFile(name), isFalse, reason: name);
    }
  });
}
