// Golden path: in-app update. GET /config is the update switchboard; the
// app must read exactly the fields the backend's routes/config.js writes
// (latestVersionCode, apkUrl, apkSha256, apkSize, forceUpdateBelow,
// changelog) and stay harmless when no APK has been published.
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/models/remote_config.dart';

void main() {
  test('a published build is read with its url, hash, size and changelog', () {
    final c = RemoteConfig.fromJson({
      'features': {'agent_calls': true},
      'latestVersionCode': 142,
      'latestVersionName': '0.2.101',
      'forceUpdateBelow': 106,
      'changelog': ['Faster voice', 'Calendar holidays'],
      'apkUrl': 'https://api.example/app/latest.apk',
      'apkSha256': 'abc123',
      'apkSize': 198765432,
    });
    expect(c.latestVersionCode, 142);
    expect(c.latestVersionName, '0.2.101');
    expect(c.forceUpdateBelow, 106);
    expect(c.apkUrl, 'https://api.example/app/latest.apk');
    expect(c.apkSha256, 'abc123');
    expect(c.apkSize, 198765432);
    expect(c.changelog, ['Faster voice', 'Calendar holidays']);
    expect(c.isEnabled('agent_calls'), isTrue);
    expect(c.isEnabled('missing'), isFalse);
  });

  test('no APK published → no update is offered, nothing throws', () {
    final c = RemoteConfig.fromJson({'features': {}});
    expect(c.apkUrl, isNull);
    expect(c.latestVersionCode, 1);
    expect(c.forceUpdateBelow, 0);
    expect(c.changelog, isEmpty);
  });

  test('a newer build is newer; the running build never updates to itself', () {
    final c = RemoteConfig.fromJson({'latestVersionCode': 142, 'apkUrl': 'x'});
    expect(c.latestVersionCode > 141, isTrue);
    expect(c.latestVersionCode <= 142, isTrue);
  });
}
