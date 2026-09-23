// The session token goes to whatever server the app is pointed at, so a
// release build may only be pointed at HTTPS.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/services/api_service.dart';

void main() {
  test('release builds accept only https servers', () {
    expect(ApiService.overrideAllowed('https://api.hariassistant.tech', release: true), isTrue);
    expect(ApiService.overrideAllowed('http://evil.example', release: true), isFalse);
    expect(ApiService.overrideAllowed('http://10.0.2.2:3000', release: true), isFalse);
    expect(ApiService.overrideAllowed('javascript:alert(1)', release: true), isFalse);
  });

  test('debug builds may use a local http server', () {
    expect(ApiService.overrideAllowed('http://10.0.2.2:3000', release: false), isTrue);
    expect(ApiService.overrideAllowed('ftp://x', release: false), isFalse);
  });
}
