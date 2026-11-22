import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passlune/drive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPaths extends PathProviderPlatform {
  final String dir;
  _TempPaths(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  late Directory dir;
  bool hasToken() => dir.listSync().any((f) => f.path.contains('drive_token'));

  setUp(() {
    dir = Directory.systemTemp.createTempSync('drive_auth');
    PathProviderPlatform.instance = _TempPaths(dir.path);
    // A refresh token as older versions stored it (sealed on Windows when read).
    File('${dir.path}${Platform.pathSeparator}drive_token.json').writeAsStringSync(jsonEncode({'refresh_token': 'dead'}));
  });

  Future<Object?> refreshWith(int status, String body) => http.runWithClient(
        () => DesktopDriveAuth().accessToken().then<Object?>((_) => null, onError: (Object e) => e),
        () => MockClient((_) async => http.Response(body, status)),
      );

  test('invalid_grant forgets the sign-in and says so', () async {
    final e = await refreshWith(400, '{"error":"invalid_grant"}');
    expect(e, isA<DriveSignInLost>());
    expect('$e', contains('invalid_grant'));
    expect(hasToken(), isFalse);
  });

  test('other refusals keep the sign-in and name the code', () async {
    final e = await refreshWith(401, '{"error":"invalid_client"}');
    expect(e, isA<DriveException>());
    expect(e, isNot(isA<DriveSignInLost>()));
    expect('$e', contains('invalid_client'));
    expect(hasToken(), isTrue);
  });

  test('a page that is not JSON reports the status instead of a FormatException', () async {
    final e = await refreshWith(502, '<html>captive portal</html>');
    expect(e, isA<DriveException>());
    expect('$e', contains('502'));
    expect(hasToken(), isTrue);
  });
}
