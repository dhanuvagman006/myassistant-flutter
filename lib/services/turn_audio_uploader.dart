import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ai/live_voice.dart' show LiveTurnAudio;
import '../core/log.dart';
import 'api_service.dart';

/// HEARING A LIVE TURN (2026-10-01). The fast voice runs phone ↔ Gemini,
/// so the server never hears it; the owner needs to, for the testers who
/// said yes to "Help improve the assistant". Both halves of a finished
/// turn — what the microphone fed to Live and what Live spoke back — are
/// posted once the turn is recorded. The server keeps them only for a
/// consenting user (it checks too) and the admin panel plays them back.
///
/// Never on the hot path, never a failure anyone sees: a missed upload
/// is one AppLog line.
class TurnAudioUploader {
  TurnAudioUploader._();

  static const _timeout = Duration(seconds: 25);

  /// Always upload (2026-10-01, owner: pre-release internal testers, record
  /// every conversation for the admin panel). The server still decides
  /// whether to keep it (helpImprove policy, default on). A test can
  /// override this to false.
  static bool Function() enabled = () => true;

  static Future<void> send(LiveTurnAudio a) async {
    if (!enabled()) return;
    final user = _join(a.user);
    final agent = _join(a.agent);
    if (user.length < 3200 && agent.length < 3200) return;
    try {
      final req = http.MultipartRequest(
          'POST', Uri.parse('${ApiService.baseUrl}/ai/turn-audio'))
        ..headers.addAll(Map.of(ApiService.authHeaders)..remove('Content-Type'))
        ..fields['turn_id'] = a.turnId
        ..fields['started_at'] = a.startedAt.millisecondsSinceEpoch.toString()
        ..fields['user_rate'] = a.userRate.toString()
        ..fields['agent_rate'] = a.agentRate.toString();
      if (user.isNotEmpty) {
        req.files.add(http.MultipartFile.fromBytes('user', user, filename: 'user.pcm'));
      }
      if (agent.isNotEmpty) {
        req.files.add(http.MultipartFile.fromBytes('agent', agent, filename: 'agent.pcm'));
      }
      final res = await req.send().timeout(_timeout);
      if (res.statusCode == 200 || res.statusCode == 204) {
        AppLog.add('live', 'turn audio ${res.statusCode == 204 ? 'declined' : 'uploaded'} '
            '(${(user.length + agent.length) ~/ 1024} KB)');
      } else {
        AppLog.add('live', 'turn audio not uploaded: ${res.statusCode}');
      }
    } catch (e) {
      AppLog.add('live', 'turn audio not uploaded: ${e.runtimeType}');
    }
  }

  static Uint8List _join(List<Uint8List> parts) {
    var n = 0;
    for (final p in parts) {
      n += p.length;
    }
    final out = Uint8List(n);
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }
}
