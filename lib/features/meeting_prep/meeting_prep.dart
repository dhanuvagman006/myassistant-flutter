import 'dart:async';

import '../../services/api_service.dart';
import '../../services/brief_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  "PREPARE ME FOR MY NEXT MEETING" (2026-09-30). Mirrors backend
///  src/meetings/prep.js: the event, who is in it (matched to the user's
///  people), what happened last time, promises either way, recent emails —
///  written into a summary and 3–5 talking points from real data only.
///  Opened by Home's Prepare button (GET /meetings/prep) or by voice (the
///  prepare_meeting tool's open_meeting_prep directive carries it whole).
/// ─────────────────────────────────────────────────────────────────────────

class PrepMeeting {
  const PrepMeeting({
    required this.id,
    required this.title,
    required this.startMs,
    this.source = 'google',
    this.endMs,
    this.timeText = '',
    this.whenText = '',
    this.location = '',
    this.link = '',
    this.attendees = const [],
  });

  /// A Google event id, or "reminder:<id>".
  final String id;

  /// 'google' | 'reminder'.
  final String source;
  final String title;
  final int startMs;
  final int? endMs;

  /// "3:00 pm".
  final String timeText;

  /// "in 45 min" / "today at 3 pm" / "tomorrow at 10:30 am".
  final String whenText;
  final String location;

  /// A video-call link (https only), or ''.
  final String link;
  final List<String> attendees;

  factory PrepMeeting.fromJson(Map<String, dynamic> j) => PrepMeeting(
        id: '${j['id'] ?? ''}',
        source: j['source'] as String? ?? 'google',
        title: j['title'] as String? ?? 'Meeting',
        startMs: (j['startMs'] as num?)?.toInt() ?? 0,
        endMs: (j['endMs'] as num?)?.toInt(),
        timeText: j['timeText'] as String? ?? '',
        whenText: j['whenText'] as String? ?? '',
        location: j['location'] as String? ?? '',
        link: j['link'] as String? ?? '',
        attendees: _strings(j['attendees']),
      );
}

class PrepPerson {
  const PrepPerson({required this.name, this.role = '', this.lastContact = '', this.notes = ''});
  final String name;
  final String role;

  /// "23 Sep", or '' when never.
  final String lastContact;
  final String notes;

  factory PrepPerson.fromJson(Map<String, dynamic> j) => PrepPerson(
        name: j['name'] as String? ?? '',
        role: j['role'] as String? ?? '',
        lastContact: j['lastContact'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
      );
}

class MeetingPrep {
  const MeetingPrep({
    this.meeting,
    this.summary = '',
    this.people = const [],
    this.context = const [],
    this.talkingPoints = const [],
    this.asks = const [],
    this.risks = const [],
    this.known = false,
    this.source = 'template',
    this.remindAtMs,
  });

  /// Null: no meeting in the next 24 hours (or that one is gone).
  final PrepMeeting? meeting;
  final String summary;
  final List<PrepPerson> people;
  final List<String> context;
  final List<String> talkingPoints;
  final List<String> asks;
  final List<String> risks;

  /// Anything real was found beyond the event itself.
  final bool known;

  /// 'ai' | 'template'.
  final String source;

  /// Ten minutes before it starts; null when that has passed.
  final int? remindAtMs;

  factory MeetingPrep.fromJson(Map<String, dynamic> j) => MeetingPrep(
        meeting: j['meeting'] is Map<String, dynamic>
            ? PrepMeeting.fromJson(j['meeting'] as Map<String, dynamic>)
            : null,
        summary: (j['summary'] as String? ?? '').trim(),
        people: ((j['people'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(PrepPerson.fromJson)
            .where((p) => p.name.trim().isNotEmpty)
            .toList(),
        context: _strings(j['context']),
        talkingPoints: _strings(j['talkingPoints']),
        asks: _strings(j['asks']),
        risks: _strings(j['risks']),
        known: j['known'] == true,
        source: j['source'] as String? ?? 'template',
        remindAtMs: (j['remindAt'] as num?)?.toInt(),
      );
}

List<String> _strings(Object? v) => ((v as List?) ?? const [])
    .whereType<String>()
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// The network half. Tests hand in their own.
class MeetingPrepApi {
  const MeetingPrepApi();

  /// The prep for [meetingId] (a Google event id or "reminder:<id>"), or
  /// the next meeting; null when it could not be had.
  Future<MeetingPrep?> fetch({String? meetingId}) async {
    final q = meetingId == null || meetingId.isEmpty
        ? ''
        : '?id=${Uri.encodeQueryComponent(meetingId)}';
    // The server may ask the model for the words: up to ~8 s, plus the
    // calendar and the mail.
    final j = await ApiService.getJson('/meetings/prep$q', timeout: const Duration(seconds: 25));
    return j == null ? null : MeetingPrep.fromJson(j);
  }

  /// "Remind me 10 min before": a real reminder (POST /reminders), so it
  /// rings on this phone like any other. False when it could not be set.
  Future<bool> remindBefore(MeetingPrep p) async {
    final m = p.meeting;
    final at = p.remindAtMs;
    if (m == null || at == null) return false;
    final r = await ApiService.sendJson('/reminders', body: {
      'text': 'Meeting in 10 minutes: ${m.title}',
      'dueAt': at,
    });
    if (r == null) return false;
    // The brief refresh re-arms the phone's alarms and shows it on Home.
    unawaited(BriefService.instance.refresh(force: true));
    return true;
  }
}
