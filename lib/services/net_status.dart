import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/log.dart';
import 'api_service.dart';

/// What the phone can reach right now.
enum NetState {
  /// Fine (or not looked at yet).
  ok,

  /// No internet at all: Wi-Fi and mobile data are off, or not working.
  offline,

  /// The internet works but our server does not answer.
  serverDown,
}

/// ─────────────────────────────────────────────────────────────────────────
///  "IS IT ME OR IS IT YOU?" (2026-10-09). Owner: "if internet is off show
///  it to users" — a client's "the app is not responding" was his own
///  internet, and nothing on screen said so.
///
///  Looked at when the app starts and comes back to the front, and
///  whenever a request to the server fails to connect; while something is
///  wrong, again every 10 seconds until it is fine. Two lookups tell the
///  cases apart: a well-known site (the internet itself) and our server.
///  The banner (widgets/net_banner.dart) shows [state].
/// ─────────────────────────────────────────────────────────────────────────
class NetStatus {
  NetStatus._();
  static final NetStatus instance = NetStatus._();

  final ValueNotifier<NetState> state = ValueNotifier(NetState.ok);

  Future<void>? _checking;
  Timer? _again;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// A request could not connect: look again now (at most every 3 s).
  void requestFailed() {
    if (DateTime.now().difference(_last) < const Duration(seconds: 3)) return;
    unawaited(check());
  }

  Future<void> check() {
    final running = _checking;
    if (running != null) return running;
    final f = _check().whenComplete(() => _checking = null);
    _checking = f;
    return f;
  }

  Future<void> _check() async {
    _last = DateTime.now();
    final next = await _probe();
    if (next != state.value) {
      AppLog.add('net', 'now ${next.name}');
      state.value = next;
    }
    _again?.cancel();
    if (next != NetState.ok) {
      _again = Timer(const Duration(seconds: 10), () => unawaited(check()));
    }
  }

  Future<NetState> _probe() async {
    if (await _serverAnswers()) return NetState.ok;
    return await _internetWorks() ? NetState.serverDown : NetState.offline;
  }

  Future<bool> _serverAnswers() async {
    try {
      final r = await http
          .get(Uri.parse('${ApiService.baseUrl}/health'))
          .timeout(const Duration(seconds: 6));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Any of a few well-known names resolving means there is internet.
  Future<bool> _internetWorks() async {
    for (final host in const ['google.com', 'cloudflare.com']) {
      try {
        final a = await InternetAddress.lookup(host).timeout(const Duration(seconds: 4));
        if (a.isNotEmpty) return true;
      } catch (_) {}
    }
    return false;
  }

  @visibleForTesting
  void debugSet(NetState s) => state.value = s;
}

/// True for the errors that mean "could not connect", not "the server said no".
bool isConnectError(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    e is HandshakeException ||
    e is http.ClientException;
