import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import 'api_service.dart';
import 'call_notes_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  SYSTEM CALL-RECORDER WATCHER.
///
///  Samsung's own dialer records BOTH sides of a call cleanly (it is a
///  system app; nothing we ship can do that from the earpiece). When the
///  user keeps Samsung as the phone app and turns its call recording on,
///  the recordings land as audio files under well-known folders. With
///  the audio-files permission we read any NEW recording, hand it to the
///  same /calls/upload pipeline the in-app dialer uses, and NEVER delete
///  or modify the user's own files — we only remember which ones were
///  already processed.
///
///  Runs only while AI call analysis is consented ON, and scans on app
///  resume / dialer-screen open / a slow periodic tick — a filesystem
///  watcher would need a background service for little gain.
/// ─────────────────────────────────────────────────────────────────────────
class CallRecordingWatcher {
  CallRecordingWatcher._();
  static final CallRecordingWatcher instance = CallRecordingWatcher._();

  static const _doneKey = 'call_recordings_processed_v1';

  /// Where Samsung (and most OEM dialers) put call recordings.
  static const _dirs = [
    '/storage/emulated/0/Recordings/Call',
    '/storage/emulated/0/Call',
    '/storage/emulated/0/Sounds/Call',
    '/storage/emulated/0/Recordings/Call Recordings',
    '/storage/emulated/0/MIUI/sound_recorder/call_rec',
  ];

  Timer? _tick;
  bool _scanning = false;

  void start() {
    _tick ??= Timer.periodic(const Duration(minutes: 10), (_) => scan());
    scan();
  }

  /// The audio-files permission, asked only when the toggle goes on.
  /// Android 13+ = READ_MEDIA_AUDIO; older = storage.
  Future<bool> ensurePermission() async {
    var p = await Permission.audio.request();
    if (p.isGranted) return true;
    p = await Permission.storage.request();
    return p.isGranted;
  }

  Future<void> scan() async {
    if (_scanning) return;
    final prefs = await SharedPreferences.getInstance();
    // The prefs flag, not the service singleton: a WorkManager isolate has
    // no hydrated CallNotesService, but the toggle is always mirrored here.
    final enabled = prefs.getBool('call_analysis_enabled_v1') ??
        CallNotesService.instance.analysisEnabled;
    if (!enabled) return;
    _scanning = true;
    try {
      if (!await Permission.audio.isGranted &&
          !await Permission.storage.isGranted) {
        AppLog.add('callrec', 'scan skipped — audio permission not granted');
        return;
      }
      // No consent stamp yet (fresh account that hasn't answered the
      // sign-in notice) → nothing is read, however the toggle looks.
      final consentAt = await _consentAt();
      if (consentAt <= 0) {
        AppLog.add('callrec', 'scan skipped — consent not yet recorded');
        return;
      }
      final done = (prefs.getStringList(_doneKey) ?? const []).toSet();
      var seen = 0, sent = 0;

      for (final dir in _dirs) {
        final d = Directory(dir);
        if (!await d.exists()) continue;
        await for (final ent in d.list()) {
          if (ent is! File) continue;
          final name = ent.uri.pathSegments.last;
          if (!RegExp(r'\.(m4a|mp3|amr|wav|3gp|aac|ogg)$', caseSensitive: false)
              .hasMatch(name)) {
            continue;
          }
          if (done.contains(name)) continue;
          seen++;
          final stat = await ent.stat();
          // Only calls made AFTER analysis was turned on get analysed —
          // the archive from before consent is not ours to read.
          if (stat.modified.millisecondsSinceEpoch < consentAt) {
            done.add(name); // old file: mark seen, never touch
            continue;
          }
          // A file still being written grows; wait for the next scan.
          if (DateTime.now().difference(stat.modified).inSeconds < 20) {
            continue;
          }
          if (await _upload(ent, name, stat)) {
            done.add(name);
            sent++;
          }
        }
      }
      AppLog.add('callrec', 'scan: $seen new file(s), $sent uploaded');
      // Cap the ledger — thousands of entries would bloat prefs.
      final keep = done.toList();
      if (keep.length > 500) keep.removeRange(0, keep.length - 500);
      await prefs.setStringList(_doneKey, keep);
    } catch (e) {
      AppLog.add('callrec', 'scan failed: $e');
    } finally {
      _scanning = false;
    }
  }

  int _consentAtCache = 0;
  Future<int> _consentAt() async {
    if (_consentAtCache > 0) return _consentAtCache;
    try {
      final r = await ApiService.getJson('/calls/analysis');
      _consentAtCache = (r?['consentAt'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    return _consentAtCache;
  }

  /// Samsung names files "Call Gopal Rao Karle_260917_210925.m4a" (saved
  /// contact — NO number) or "Call +919876543210_260917_210925.m4a"
  /// (unsaved number). Strip extension, the "Call "/"Call recording "
  /// prefix and the trailing _ddmmyy_hhmmss stamp FIRST — an eager number
  /// regex read the date stamp as a phone number and filed "260917" as
  /// the person.
  static (String, String) parsePeer(String name) {
    var base = name
        .replaceFirst(
            RegExp(r'\.(m4a|mp3|amr|wav|3gp|aac|ogg)$', caseSensitive: false),
            '')
        .replaceFirst(
            RegExp(r'^call(\s*recording)?[\s_]*', caseSensitive: false), '');
    base = base.replaceFirst(RegExp(r'[_\s]\d{6}[_\s]\d{6}$'), '');
    final numMatch = RegExp(r'\+?\d[\d\s-]{7,}').firstMatch(base);
    final number = numMatch?.group(0)?.replaceAll(RegExp(r'[\s-]'), '') ?? '';
    var peer = base;
    if (numMatch != null) peer = base.substring(0, numMatch.start);
    peer = peer.replaceAll(RegExp(r'[_\-]+$'), '').replaceAll('_', ' ').trim();
    if (RegExp(r'^[\d\s]*$').hasMatch(peer)) peer = '';
    return (peer, number);
  }

  Future<bool> _upload(File f, String name, FileStat stat) async {
    try {
      final len = await f.length();
      if (len < 24 * 1024 || len > 120 * 1024 * 1024) return true; // skip junk
      final (peer, number) = parsePeer(name);
      final req = http.MultipartRequest(
          'POST', Uri.parse('${ApiService.baseUrl}/calls/upload'));
      final token = ApiService.sessionToken;
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      req.fields['peerNumber'] = number;
      req.fields['peerName'] = peer;
      req.fields['direction'] = 'outgoing'; // filenames don't say; neutral
      req.fields['startedAtMs'] = '${stat.modified.millisecondsSinceEpoch}';
      req.fields['durationSec'] = '0';
      req.fields['source'] = 'system_recorder';
      req.files.add(await http.MultipartFile.fromPath('audio', f.path));
      final res = await req.send().timeout(const Duration(minutes: 5));
      AppLog.add('callrec', 'uploaded $name → HTTP ${res.statusCode}');
      CallNotesService.instance.refreshRecent();
      return res.statusCode < 500; // 4xx (toggle off etc.) → don't retry
    } catch (e) {
      AppLog.add('callrec', 'upload of $name failed: $e');
      return false; // retry on a later scan
    }
  }
}
