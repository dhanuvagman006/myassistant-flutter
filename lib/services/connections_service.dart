import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'privacy_prefs_service.dart' show JsonTransport, apiTransport;

/// One linked app, as `GET /connections` describes it. Never a token.
class ConnectionInfo {
  final String id;
  final String name;
  final bool available;
  final String status; // not_connected | connected | needs_reconnect
  final String? workspace;
  final int minBuild;

  /// What linking it lets the assistant do (the other apps, 2026-10-04).
  final String description;

  const ConnectionInfo({
    this.description = '',
    required this.id,
    required this.name,
    required this.available,
    required this.status,
    this.workspace,
    this.minBuild = 120,
  });

  bool get connected => status == 'connected';

  factory ConnectionInfo.fromJson(Map<String, dynamic> j) => ConnectionInfo(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        available: j['available'] == true,
        status: const {'connected', 'needs_reconnect'}.contains(j['status'])
            ? j['status'] as String
            : 'not_connected',
        workspace: j['workspace'] is String ? j['workspace'] as String : null,
        minBuild: (j['minBuild'] as num?)?.toInt() ?? 120,
        description: (j['description'] ?? '').toString(),
      );
}

enum ConnectResult { connected, cancelled, failed }

/// Opens [url] in a Custom Tab and waits for the [scheme] redirect.
typedef WebAuth = Future<String> Function(String url, String scheme);

Future<String> _webAuth(String url, String scheme) =>
    FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: scheme);

/// ─────────────────────────────────────────────────────────────────────────
///  CONNECTED APPS (build 120). Notion links through its own consent page:
///  the server gives the URL, the browser comes back to the app with a
///  result word only (the code is exchanged on the server). Whatever the
///  tab says — even when the user closes it — the list is reloaded, because
///  the link may already have been made.
/// ─────────────────────────────────────────────────────────────────────────
class ConnectionsService extends ChangeNotifier {
  ConnectionsService._();
  static final ConnectionsService instance = ConnectionsService._();

  @visibleForTesting
  static JsonTransport transport = apiTransport;
  @visibleForTesting
  static WebAuth webAuth = _webAuth;

  List<ConnectionInfo> items = const [];
  bool loaded = false;

  ConnectionInfo? get notion {
    for (final c in items) {
      if (c.id == 'notion') return c;
    }
    return null;
  }

  Future<void> load() async {
    final r = await transport('GET', '/connections');
    final list = r?['connections'];
    if (list is List) {
      items = [
        for (final c in list)
          if (c is Map<String, dynamic>) ConnectionInfo.fromJson(c),
      ];
    }
    loaded = true;
    notifyListeners();
  }

  Future<ConnectResult> connectNotion() => connect('notion');

  /// Any app in the list: the server's consent page, then back here.
  Future<ConnectResult> connect(String id) async {
    final start = await transport('POST', '/connections/$id/start');
    final url = start?['authUrl'];
    if (url is! String || url.isEmpty) return ConnectResult.failed;
    final scheme = (start?['callbackScheme'] ?? 'com.myassistant.myassistant').toString();
    var result = 'error';
    try {
      final back = await webAuth(url, scheme);
      result = Uri.parse(back).queryParameters['result'] ?? 'error';
    } on PlatformException catch (e) {
      result = e.code == 'CANCELED' ? 'cancelled' : 'error';
    } catch (_) {
      result = 'error';
    }
    await load();
    // The server is the truth: a closed tab after a finished exchange is
    // still a connection.
    if (items.any((c) => c.id == id && c.connected)) return ConnectResult.connected;
    return result == 'cancelled' ? ConnectResult.cancelled : ConnectResult.failed;
  }

  /// Mail keeps its own screen; this is only whether it is linked.
  Future<bool> mailLinked() async {
    final r = await Future.wait(
        [transport('GET', '/email/account'), transport('GET', '/google/status')]);
    return r[0]?['connected'] == true || r[1]?['connected'] == true;
  }

  /// Google (Gmail + Calendar) links through the phone's own Google sign-in.
  Future<bool> googleLinked() async =>
      (await transport('GET', '/google/status'))?['connected'] == true;

  Future<bool> disconnectNotion() => disconnect('notion');

  Future<bool> disconnect(String id) async {
    final r = await transport('DELETE', '/connections/$id');
    await load();
    return r != null;
  }

  @visibleForTesting
  void resetForTest() {
    items = const [];
    loaded = false;
  }
}
