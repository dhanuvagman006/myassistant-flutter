import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_service.dart';

/// MEETINGS — the recorder's server side. A whole recording goes up in one
/// piece; the server answers at once and writes the minutes in the
/// background (summary, decisions, action items, follow-up, PDF).
class MeetingsService {
  MeetingsService._();

  /// Uploads a finished recording. Returns the new meeting's id.
  static Future<int> upload(
    String path, {
    String title = '',
    String participants = '',
    int durationS = 0,
  }) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('${ApiService.baseUrl}/meetings/record'));
    req.headers.addAll(ApiService.authHeaders..remove('Content-Type'));
    if (title.trim().isNotEmpty) req.fields['title'] = title.trim();
    if (participants.trim().isNotEmpty) {
      req.fields['participants'] = participants.trim();
    }
    req.fields['duration_s'] = '$durationS';
    req.files.add(await http.MultipartFile.fromPath('audio', path));
    // An hour is ~15 MB; give a slow connection real time.
    final streamed = await req.send().timeout(const Duration(minutes: 10));
    final r = await http.Response.fromStream(streamed);
    if (r.statusCode != 202 && r.statusCode != 200) {
      String msg = 'Upload failed (${r.statusCode}).';
      try {
        msg = (jsonDecode(r.body)['error'] ?? msg).toString();
      } catch (_) {}
      throw Exception(msg);
    }
    return (jsonDecode(r.body)['id'] as num).toInt();
  }

  /// null = the fetch failed; [] = a real empty list.
  static Future<List<Map<String, dynamic>>?> list() async {
    final r = await ApiService.getJson('/meetings?limit=30');
    if (r == null) return null;
    return ((r['meetings'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }

  static Future<Map<String, dynamic>?> get(int id) async {
    final r = await ApiService.getJson('/meetings/$id');
    return r?.cast<String, dynamic>();
  }

  /// The minutes as a PDF, for sharing.
  static Future<List<int>> pdf(int id) async {
    final r = await http
        .get(Uri.parse('${ApiService.baseUrl}/meetings/$id/pdf'),
            headers: ApiService.authHeaders)
        .timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw Exception('pdf ${r.statusCode}');
    return r.bodyBytes;
  }
}
