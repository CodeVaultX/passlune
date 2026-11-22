import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:passlune/breach.dart';

void main() {
  test('only the 5-character hash prefix is sent; matches are found locally', () async {
    final leaked = pwHash('password');
    final safe = pwHash('gH#8v!q2LmZ@x9Rt-not-leaked');
    final asked = <String>[];
    final client = MockClient((req) async {
      asked.add(req.url.path);
      final prefix = req.url.pathSegments.last;
      final body = prefix == leaked.substring(0, 5)
          ? '0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n${leaked.substring(5)}:9659365\r\n'
          : '0018A45C4D1DEF81644B54AB7F969B88D65:2\r\n';
      return http.Response(body, 200);
    });
    final r = await checkPwned([leaked, safe], client: client);
    expect(r[leaked], 9659365);
    expect(r[safe], 0);
    expect(asked, everyElement(matches(RegExp(r'^/range/[0-9A-F]{5}$'))));
    expect(pwHash('password'), '5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8');
  });
}
