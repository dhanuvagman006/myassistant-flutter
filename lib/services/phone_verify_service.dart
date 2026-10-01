import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'auth_service.dart';
import '../core/log.dart';

/// PROVING THE USER'S OWN NUMBER — Firebase Phone Number Verification.
///
/// The number is what other people's agents address messages to, so it
/// has to be PROVEN rather than typed. Owner, 2026-09-29: the SMS code is
/// gone "completely". Google now reads the number of the SIM in this phone
/// from its carrier, after Android's own consent sheet, and signs it into a
/// token for our Firebase project ("hari/phone_number",
/// PhoneNumberVerificationBridge.kt). That token, not any digits, goes to
/// POST /phone/verify, which checks it against Google's keys before
/// writing anything. A caller therefore cannot register a number they do
/// not control.
///
/// Google does this only where the carrier takes part: 12 countries in
/// September 2026, India not among them. On such a SIM the only other way
/// in is the server's TESTING switch (a typed number), and only while the
/// server offers it.
class PhoneVerifyService {
  PhoneVerifyService({
    SimNumberPort? sim,
    Future<Map<String, dynamic>?> Function(String path)? getJson,
    Future<http.Response> Function(String path, Map<String, dynamic> body)? post,
    Future<void> Function()? refreshUser,
  })  : _sim = sim ?? const SimNumberChannel(),
        _getJson = getJson ?? ApiService.getJson,
        _post = post ?? _httpPost,
        _refreshUser = refreshUser ?? AuthService.instance.refreshUser;

  static final PhoneVerifyService instance = PhoneVerifyService();

  final SimNumberPort _sim;
  final Future<Map<String, dynamic>?> Function(String path) _getJson;
  final Future<http.Response> Function(String path, Map<String, dynamic> body) _post;
  final Future<void> Function() _refreshUser;

  static Future<http.Response> _httpPost(String path, Map<String, dynamic> body) =>
      http.post(
        Uri.parse('${ApiService.baseUrl}$path'),
        headers: {'Content-Type': 'application/json', ...ApiService.authHeaders},
        body: jsonEncode(body),
      );

  /// Which ways in this phone AND this server allow. Asked rather than
  /// assumed, so no button appears that the other side would refuse.
  Future<PhoneVerifyMethods> methods() async {
    Map<String, dynamic>? server;
    try {
      server = await _getJson('/phone/methods');
    } catch (_) {
      server = null;
    }
    if (server == null) return const PhoneVerifyMethods(sim: false, typed: false, reached: false);
    final sim = server['sim'] == true && await _sim.supported();
    return PhoneVerifyMethods(sim: sim, typed: server['typed'] == true);
  }

  /// Android's consent sheet, then the server. Null on success, or words
  /// safe to show the user.
  Future<String?> verifyWithSim() async {
    final got = await _sim.verify();
    if (!got.ok) {
      AppLog.add('phone', 'SIM check failed: ${got.code} ${got.message}');
      return wordsFor(got.code);
    }
    return _register('/phone/verify', {'pnvToken': got.token});
  }

  /// TESTING ONLY — claim a typed number. The server enforces the same
  /// normalisation and one-number-one-account rule as the real path, and
  /// refuses it unless its switch is on.
  Future<String?> devVerify(String e164) => _register('/phone/dev-verify', {'phone': e164});

  Future<String?> _register(String path, Map<String, dynamic> body) async {
    try {
      final r = await _post(path, body);
      if (r.statusCode == 409) {
        // One number, one account — deliberately not silently reassigned.
        return 'This number is already registered to another account.';
      }
      if (r.statusCode >= 300) {
        Object? decoded;
        try {
          decoded = jsonDecode(r.body);
        } catch (_) {}
        return (decoded is Map ? decoded['error'] as String? : null) ??
            'Could not register this number.';
      }
      // Refresh so the gate sees phoneVerified and lets the user through.
      await _refreshUser();
      AppLog.add('phone', 'verified via $path');
      return null;
    } catch (_) {
      return 'Could not reach the server. Check your connection.';
    }
  }

  /// What the user reads when the phone's side did not finish.
  static String wordsFor(String code) => switch (code) {
        'cancelled' => 'You closed the confirmation. Tap Confirm to try again.',
        'unsupported' => "Your network can't confirm numbers automatically yet.",
        'not_enabled' => 'Number confirmation is not switched on for this app yet.',
        'network' => 'No connection. Check your internet and try again.',
        _ => 'Could not confirm your number. Try again.',
      };
}

/// What the verify screen may offer.
class PhoneVerifyMethods {
  const PhoneVerifyMethods({required this.sim, required this.typed, this.reached = true});

  /// Google can confirm this SIM's number, and the server takes its token.
  final bool sim;

  /// The server's testing switch: a typed number is accepted.
  final bool typed;

  /// False when the server did not answer at all.
  final bool reached;
}

class SimNumberResult {
  const SimNumberResult.ok(this.token)
      : ok = true,
        code = '',
        message = '';
  const SimNumberResult.failed(this.code, [this.message = ''])
      : ok = false,
        token = '';

  final bool ok;
  final String token;
  final String code;
  final String message;
}

/// The phone's side, replaceable in tests.
abstract class SimNumberPort {
  Future<bool> supported();
  Future<SimNumberResult> verify();
}

class SimNumberChannel implements SimNumberPort {
  const SimNumberChannel();

  static const _ch = MethodChannel('hari/phone_number');

  @override
  Future<bool> supported() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('support');
      return r?['supported'] == true;
    } catch (_) {
      // No channel (iOS, tests) or no answer: not available here.
      return false;
    }
  }

  @override
  Future<SimNumberResult> verify() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('verify');
      if (r == null) return const SimNumberResult.failed('failed');
      if (r['ok'] == true && (r['token'] as String? ?? '').isNotEmpty) {
        return SimNumberResult.ok(r['token'] as String);
      }
      return SimNumberResult.failed(r['code'] as String? ?? 'failed', r['message'] as String? ?? '');
    } catch (e) {
      return SimNumberResult.failed('failed', '$e');
    }
  }
}
