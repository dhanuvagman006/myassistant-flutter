import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/log.dart';
import '../services/api_service.dart';
import '../services/voice_service.dart';
import '../theme/app_theme.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  AVATAR SCREEN — talk face-to-face with a real human avatar.
///
///  Powered by Tavus CVI: the backend mints a conversation
///  (POST /avatar/session, personalized with the user's memories) and
///  returns a WebRTC room URL; this screen embeds it. Tavus runs the
///  entire low-latency loop — she hears you, watches you, answers in
///  under a second, and you can interrupt her mid-sentence like a real
///  call. Requires TAVUS_API_KEY + TAVUS_FACE_ID on the server.
///
///  This screen's jobs: mic+camera permission, silence the app's own
///  TTS (two voices must never overlap), embed, and clean up on exit.
/// ─────────────────────────────────────────────────────────────────────────
class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  /// Is the avatar configured server-side? (Cheap probe for the button.)
  static Future<bool> available() async {
    try {
      final r = await http
          .get(Uri.parse('${ApiService.baseUrl}/avatar/status'),
              headers: ApiService.authHeaders)
          .timeout(const Duration(seconds: 6));
      return r.statusCode == 200 &&
          (jsonDecode(r.body) as Map)['enabled'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  WebViewController? _web;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    VoiceService.instance.stopSpeaking(); // one voice at a time
    _start();
  }

  Future<void> _start() async {
    try {
      final mic = await Permission.microphone.request();
      final cam = await Permission.camera.request();
      if (!mic.isGranted) {
        setState(() {
          _error = 'The avatar needs your microphone to hear you.';
          _loading = false;
        });
        return;
      }
      // Camera is optional — she can talk without seeing you.
      AppLog.add('avatar', 'perms mic=${mic.isGranted} cam=${cam.isGranted}');

      final r = await http
          .post(Uri.parse('${ApiService.baseUrl}/avatar/session'),
              headers: ApiService.authHeaders)
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 503) {
        throw Exception('not configured');
      }
      if (r.statusCode != 200) {
        AppLog.add('avatar', 'session HTTP ${r.statusCode}: ${r.body}');
        throw Exception('session failed');
      }
      final url = (jsonDecode(r.body) as Map)['url'] as String;
      AppLog.add('avatar', 'joining $url');

      final c = WebViewController(
        // The room asks the WebView for mic/cam at runtime — grant it
        // (OS-level permission was handled above).
        onPermissionRequest: (request) => request.grant(),
      )
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == true && mounted) {
              setState(() {
                _error = 'Could not join the call. Check your connection.';
                _loading = false;
              });
            }
          },
        ));
      await c.loadRequest(Uri.parse(url));
      if (mounted) setState(() => _web = c);
    } catch (e) {
      AppLog.add('avatar', 'start failed: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString().contains('not configured')
            ? 'The human avatar isn\'t set up on the server yet.'
            : 'The avatar is unavailable right now. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.mist,
        elevation: 0,
        title: const Text('Face to face'),
      ),
      body: Stack(
        children: [
          if (_web != null) WebViewWidget(controller: _web!),
          if (_loading && _error == null)
            const Center(
                child: CircularProgressIndicator(color: AppColors.marigold)),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off_outlined,
                        size: 44, color: AppColors.mist),
                    const SizedBox(height: 14),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppColors.mist, fontSize: 15)),
                    const SizedBox(height: 18),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.marigold,
                          side: const BorderSide(color: AppColors.marigold)),
                      onPressed: () {
                        setState(() {
                          _error = null;
                          _loading = true;
                        });
                        _start();
                      },
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
