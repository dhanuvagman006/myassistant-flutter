import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  bool _checkedThisLaunch = false;

  /// Once per launch: compare the running build number with the newest
  /// published one and offer the update. Silent on any failure — an
  /// update check must never get in the way of using the app.
  Future<void> check(BuildContext context) async {
    if (_checkedThisLaunch) return;
    _checkedThisLaunch = true;
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
      if (cfg.latestVersionCode <= current) return;
      if (!context.mounted) return;

      final forced = cfg.forceUpdateBelow > current;
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
    } catch (e) {
      AppLog.add('update', 'check failed: $e');
    }
  }

  /// Streams the APK to the cache dir, verifies the hash, opens the
  /// installer. Progress 0..1 via [onProgress]. Throws on any failure.
  Future<void> downloadAndInstall(
    RemoteConfig cfg, {
    required void Function(double) onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/update-${cfg.latestVersionCode}.apk');
    final client = http.Client();
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
        await file.delete();
        throw Exception('checksum mismatch — download corrupted');
      }
      onProgress(1);
      AppLog.add('update', 'downloaded build ${cfg.latestVersionCode}, opening installer');
      // Android gates "install unknown apps" PER APP, once. Ask up front:
      // this opens the exact settings page, waits for the user to come
      // back, and then continues into the installer — instead of the
      // installer bouncing them to Settings and losing the flow.
      if (!await Permission.requestInstallPackages.isGranted) {
        AppLog.add('update', 'asking for install permission');
        final granted = await Permission.requestInstallPackages.request();
        if (!granted.isGranted) {
          throw Exception(
              'allow "Install unknown apps" for this app on the settings '
              'page, then come back and tap Try again');
        }
      }
      final result = await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw Exception('installer: ${result.message}');
      }
    } finally {
      client.close();
    }
  }
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
      );
      // The installer is now in front; the sheet has done its job.
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = "Couldn't update: ${e.toString().replaceFirst('Exception: ', '')}";
          _progress = null;
        });
      }
    }
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
            const SizedBox(height: 16),
            if (busy) ...[
              LinearProgressIndicator(
                value: _progress == 0 ? null : _progress,
                color: Neon.cyan,
                backgroundColor: Neon.bg,
              ),
              const SizedBox(height: 8),
              Text(
                _progress! >= 1
                    ? 'Verified — opening the installer…'
                    : 'Downloading ${(_progress! * 100).toStringAsFixed(0)}%',
                style: TextStyle(color: Neon.textDim, fontSize: 12.5),
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
