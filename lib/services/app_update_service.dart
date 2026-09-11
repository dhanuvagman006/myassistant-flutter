import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../design/neon_tokens.dart';
import '../models/remote_config.dart';
import 'api_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  SELF-UPDATE — the app is its own distribution channel while it is
///  sideloaded. On launch it asks the backend for the newest published
///  build; if that is newer than what's running, a sheet offers the
///  update, downloads the APK with progress, verifies its sha256, and
///  hands it to Android's installer. No more forwarding APK files.
///
///  Server side: POST /admin/apk publishes; GET /config advertises
///  latestVersionCode + apkUrl + apkSha256; GET /app/latest.apk serves.
/// ─────────────────────────────────────────────────────────────────────────
class AppUpdateService {
  /// Set per check(): the sheet starts the update on its own. Only ever
  /// true on a connection the user is not paying for by the megabyte —
  /// a ~200 MB download that begins without being asked is not a feature
  /// on mobile data.
  static bool _autoStart = false;
  static bool get autoStart => _autoStart;
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  int _lastCheckMs = 0;
  bool _sheetShowing = false;

  /// The in-flight download, so closing the sheet actually stops it.
  /// Without this, "Later" popped the sheet and left the request running:
  /// bytes kept arriving, the file kept growing, and the install fired
  /// anyway on a build the user had just declined.
  http.Client? _client;
  bool _cancelled = false;

  /// Once the installer has the file, closing the sheet must NOT snooze
  /// or cancel — Android is already replacing the app.
  bool _installStarted = false;

  static const _snoozePrefix = 'update_snooze_';
  static const _snoozeMs = 12 * 60 * 60 * 1000; // 12 hours

  /// "Later" has to mean something. It used to live only in memory, so
  /// the next return to the foreground — two minutes later — reopened the
  /// sheet and restarted the download from zero. A declined build is now
  /// left alone for half a day; a NEWER build is a different key and is
  /// offered immediately.
  Future<void> snooze(int versionCode) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(
          '$_snoozePrefix$versionCode', DateTime.now().millisecondsSinceEpoch);
      AppLog.add('update', 'build $versionCode snoozed for 12h');
    } catch (_) {}
  }

  Future<bool> _snoozed(int versionCode) async {
    try {
      final p = await SharedPreferences.getInstance();
      final at = p.getInt('$_snoozePrefix$versionCode') ?? 0;
      if (at == 0) return false;
      if (DateTime.now().millisecondsSinceEpoch - at < _snoozeMs) return true;
      await p.remove('$_snoozePrefix$versionCode');
      return false;
    } catch (_) {
      return false;
    }
  }

  /// True when the active connection is metered (mobile data, a metered
  /// hotspot) — or when we cannot tell. Guessing "unmetered" spends the
  /// user's data; guessing "metered" costs one tap.
  Future<bool> _metered() async {
    try {
      final m = await const MethodChannel('hari/updater')
          .invokeMethod<bool>('isMetered');
      return m ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Stop an in-flight download and remove the partial file.
  Future<void> cancelDownload() async {
    _cancelled = true;
    try {
      _client?.close();
    } catch (_) {}
    _client = null;
  }

  /// Delete APKs left behind by earlier updates. The install replaces the
  /// process, so nothing ever ran after a successful one — a tester who
  /// took ten builds was carrying ten ~200 MB files in the cache
  /// directory and seeing the app listed as multi-gigabyte.
  Future<void> _sweepOldApks({int? keepVersionCode}) async {
    try {
      final dir = await getTemporaryDirectory();
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final name = f.path.split('/').last;
        if (!name.startsWith('update-') || !name.endsWith('.apk')) continue;
        if (keepVersionCode != null && name == 'update-$keepVersionCode.apk') {
          continue;
        }
        try {
          await f.delete();
          AppLog.add('update', 'removed stale $name');
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Compare the running build number with the newest published one and
  /// offer the update. Called on launch AND whenever the app returns to
  /// the foreground — a phone that keeps the app in memory for days used
  /// to never see new releases. Throttled to once per 30 minutes; silent
  /// on any failure — a check must never get in the way of using the app.
  Future<void> check(BuildContext context, {bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_sheetShowing) return;
    // Short throttle: back-to-back releases used to hide behind a 30-min
    // window, so a resumed app missed the newer one until a full restart.
    if (!force && now - _lastCheckMs < 2 * 60 * 1000) return;
    _lastCheckMs = now;
    try {
      final r = await http
          .get(Uri.parse('${ApiService.baseUrl}/config'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;
      final cfg = RemoteConfig.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
      if (cfg.apkUrl == null || cfg.apkUrl!.isEmpty) return;

      final info = await PackageInfo.fromPlatform();
      final current = int.tryParse(info.buildNumber) ?? 0;
      AppLog.add('update',
          'running build $current, published ${cfg.latestVersionCode}');
      if (cfg.latestVersionCode <= current) {
        // ALREADY UP TO DATE — which is exactly when the APK that got us
        // here is still sitting in the cache. The install replaces the
        // process, so nothing ever ran after it to clean up, and a tester
        // who took ten builds was carrying ten ~200 MB files.
        unawaited(_sweepOldApks());
        return;
      }

      // Anything left over from a build that already installed, or that
      // was abandoned, goes now — before another ~200 MB lands next to it.
      unawaited(_sweepOldApks(keepVersionCode: cfg.latestVersionCode));

      final forced = cfg.forceUpdateBelow > current;
      if (!forced && await _snoozed(cfg.latestVersionCode)) {
        AppLog.add('update', 'build ${cfg.latestVersionCode} is snoozed');
        return;
      }
      // HANDS-FREE, BUT NOT ON SOMEONE'S DATA PLAN. On Wi-Fi the sheet
      // still starts on its own — that is the zero-effort path. On mobile
      // data it waits for a tap and says how big the download is.
      // Asked BEFORE the last mounted check so the sheet is never built
      // against a context that went away while we were asking.
      final unmetered = !await _metered();
      if (!context.mounted) return;

      _sheetShowing = true;
      _cancelled = false;
      _installStarted = false;
      _autoStart = forced || unmetered;
      await showModalBottomSheet<void>(
        context: context,
        isDismissible: !forced,
        enableDrag: !forced,
        backgroundColor: Neon.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _UpdateSheet(config: cfg, forced: forced),
      );
      // Swiping the sheet away used to pop the UI and leave the request
      // running. Whatever closed it, the download stops here.
      if (!_installStarted) {
        await cancelDownload();
        if (!forced) await snooze(cfg.latestVersionCode);
      }
      _sheetShowing = false;
    } catch (e) {
      AppLog.add('update', 'check failed: $e');
    }
  }

  /// Streams the APK to the cache dir, verifies the hash, opens the
  /// installer. Progress 0..1 via [onProgress]. Throws on any failure.
  Future<void> downloadAndInstall(
    RemoteConfig cfg, {
    required void Function(double) onProgress,
    void Function()? onInstalling,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/update-${cfg.latestVersionCode}.apk');
    await _sweepOldApks(keepVersionCode: cfg.latestVersionCode);
    _cancelled = false;
    final client = http.Client();
    _client = client;
    try {
      final req = http.Request('GET', Uri.parse(cfg.apkUrl!));
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('download ${res.statusCode}');
      final total = res.contentLength ?? 0;
      var got = 0;
      final sink = file.openWrite();
      final digest = AccumulatorSink<Digest>();
      final hasher = sha256.startChunkedConversion(digest);
      await for (final chunk in res.stream) {
        if (_cancelled) {
          await sink.close();
          await _safeDelete(file);
          throw const _UpdateCancelled();
        }
        sink.add(chunk);
        hasher.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
      await sink.close();
      hasher.close();
      final hash = digest.events.single.toString();
      if (cfg.apkSha256 != null &&
          cfg.apkSha256!.isNotEmpty &&
          hash.toLowerCase() != cfg.apkSha256!.toLowerCase()) {
        await _safeDelete(file);
        throw Exception('checksum mismatch — download corrupted');
      }
      if (_cancelled) {
        await _safeDelete(file);
        throw const _UpdateCancelled();
      }
      onProgress(1);
      AppLog.add('update', 'downloaded build ${cfg.latestVersionCode}, opening installer');
      // Android gates "install unknown apps" PER APP, once. Ask up front:
      // this opens the exact settings page, waits for the user to come
      // back, and then continues into the installer — instead of the
      // installer bouncing them to Settings and losing the flow.
      // Android 8+ gates installs per-app; BELOW API 26 that permission
      // does not exist (unknown-sources is one global toggle) and the
      // permission plugin reports it permanently denied — the old check
      // looped "allow … then Try again" forever on Android 7 phones.
      final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdk >= 26 && !await Permission.requestInstallPackages.isGranted) {
        AppLog.add('update', 'asking for install permission');
        final granted = await Permission.requestInstallPackages.request();
        if (!granted.isGranted) {
          throw Exception(
              'allow "Install unknown apps" for this app on the settings '
              'page, then come back and tap Try again');
        }
      }
      // HANDS-FREE INSTALL. A PackageInstaller session with
      // USER_ACTION_NOT_REQUIRED updates silently on Android 12+ once this
      // app is its own installer of record — which the first such install
      // establishes (that one shows the system's single confirmation).
      // From then on, updates apply themselves; the app simply restarts
      // as the new version.
      AppLog.add('update', 'committing install session');
      _installStarted = true;
      onInstalling?.call();
      final started = await const MethodChannel('hari/updater')
          .invokeMethod<bool>('install', {'path': file.path});
      if (started != true) {
        // Session refused (odd OEM) — fall back to the tap-through installer.
        final result = await OpenFilex.open(
          file.path,
          type: 'application/vnd.android.package-archive',
        );
        if (result.type != ResultType.done) {
          throw Exception('installer: ${result.message}');
        }
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  static Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// The user closed the sheet or tapped Cancel — not a failure, and not
/// something to show them an error about.
class _UpdateCancelled implements Exception {
  const _UpdateCancelled();
  @override
  String toString() => 'cancelled';
}

class _UpdateSheet extends StatefulWidget {
  final RemoteConfig config;
  final bool forced;
  const _UpdateSheet({required this.config, required this.forced});

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  double? _progress; // null = not started
  String? _error;
  // The install itself is silent and takes a while: Android replaces the
  // app, the screen drops to the launcher and the app reopens by itself.
  // Without a visible "installing" state that looked like a crash.
  bool _installing = false;

  @override
  void initState() {
    super.initState();
    // Zero-effort updates: the download starts the moment the sheet
    // appears — no button hunting. The sheet stays as a progress surface.
    if (AppUpdateService.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _progress == null) _update();
      });
    }
  }

  Future<void> _update() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await AppUpdateService.instance.downloadAndInstall(
        widget.config,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onInstalling: () {
          if (mounted) setState(() => _installing = true);
        },
      );
      // DO NOT close the sheet. Android is now installing in the
      // background and will restart the app when it finishes; leaving the
      // "Installing…" panel up is what tells the user the screen going
      // dark for a moment is the update, not a crash.
      if (mounted) setState(() => _installing = true);
    } on _UpdateCancelled {
      // The user stopped it. Not an error, and nothing to report.
      if (mounted) setState(() { _progress = null; _installing = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = "Couldn't update: ${e.toString().replaceFirst('Exception: ', '')}";
          _progress = null;
          _installing = false;
        });
      }
    }
  }

  Future<void> _cancel() async {
    await AppUpdateService.instance.cancelDownload();
    if (mounted) setState(() { _progress = null; _installing = false; });
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / (1024 * 1024);
    return mb >= 1024
        ? '${(mb / 1024).toStringAsFixed(1)} GB'
        : '${mb.toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.config;
    final busy = _progress != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.system_update_rounded, color: Neon.cyan, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Update available — v${cfg.latestVersionName}',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ]),
            if (cfg.changelog.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final line in cfg.changelog.take(6))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('•  $line',
                      style: TextStyle(
                          color: Neon.textLo, fontSize: 13.5, height: 1.35)),
                ),
            ],
            if (widget.forced) ...[
              const SizedBox(height: 10),
              Text('This update is required to keep using the app.',
                  style: TextStyle(color: Neon.error, fontSize: 12.5)),
            ],
            if (!busy && !AppUpdateService.autoStart && cfg.apkSize > 0) ...[
              const SizedBox(height: 10),
              Text(
                "${_size(cfg.apkSize)} download — you're on mobile data, so "
                "it won't start until you say so.",
                style: TextStyle(
                    color: Neon.textDim, fontSize: 12.5, height: 1.35),
              ),
            ],
            const SizedBox(height: 16),
            if (_installing) ...[
              Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Neon.violet),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Installing the update…',
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'The app will close and reopen by itself in a moment. '
                'Nothing is lost — this is the update finishing.',
                style: TextStyle(
                    color: Neon.textLo, fontSize: 12.5, height: 1.35),
              ),
            ] else if (busy) ...[
              LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                color: Neon.violet,
                backgroundColor: Neon.surfaceHigh,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _progress! >= 1
                          ? 'Verified — starting the install…'
                          : 'Downloading ${(_progress! * 100).toStringAsFixed(0)}%'
                              '${cfg.apkSize > 0 ? ' of ${_size(cfg.apkSize)}' : ''}',
                      style: TextStyle(color: Neon.textDim, fontSize: 12.5),
                    ),
                  ),
                  // A download in progress must be stoppable. Closing the
                  // sheet used to leave it running to completion and
                  // install anyway.
                  if (!widget.forced && _progress! < 1)
                    TextButton(
                      onPressed: () async {
                        await _cancel();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                      child: const Text('Cancel'),
                    ),
                ],
              ),
            ],
            if (_error != null) ...[
              Text(_error!, style: TextStyle(color: Neon.error, fontSize: 12.5)),
              const SizedBox(height: 10),
            ],
            if (!busy)
              Row(
                children: [
                  if (!widget.forced)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Later'),
                    ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _update,
                    style: FilledButton.styleFrom(
                        backgroundColor: Neon.textHi,
                        foregroundColor: Neon.onInk),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(_error == null ? 'Update now' : 'Try again'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
