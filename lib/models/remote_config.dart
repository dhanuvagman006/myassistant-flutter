/// Mirrors the backend's GET /config response — the update switchboard.
class RemoteConfig {
  final int latestVersionCode;
  final String latestVersionName;
  final int forceUpdateBelow;
  final List<String> changelog;
  final String? announcement;
  final Map<String, bool> features;

  /// Self-hosted update channel (sideload builds): direct APK download URL
  /// + its sha256, published via the backend's POST /admin/apk. Null when
  /// no build has been uploaded — the app then falls back to store flows.
  final String? apkUrl;
  final String? apkSha256;

  /// Bytes. Shown before a download the user has to agree to — nobody
  /// should tap "Update now" on mobile data without knowing the size.
  final int apkSize;

  const RemoteConfig({
    this.latestVersionCode = 1,
    this.latestVersionName = '0.1.0',
    this.forceUpdateBelow = 0,
    this.changelog = const [],
    this.announcement,
    this.features = const {},
    this.apkUrl,
    this.apkSha256,
    this.apkSize = 0,
  });

  factory RemoteConfig.fromJson(Map<String, dynamic> j) => RemoteConfig(
        latestVersionCode: j['latestVersionCode'] ?? 1,
        latestVersionName: j['latestVersionName'] ?? '0.1.0',
        forceUpdateBelow: j['forceUpdateBelow'] ?? 0,
        changelog: List<String>.from(j['changelog'] ?? const []),
        announcement: j['announcement'],
        features: Map<String, bool>.from(j['features'] ?? const {}),
        apkUrl: j['apkUrl'],
        apkSha256: j['apkSha256'],
        apkSize: (j['apkSize'] as num?)?.toInt() ?? 0,
      );

  bool isEnabled(String feature) => features[feature] == true;
}
