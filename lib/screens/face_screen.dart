import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/api_service.dart';
import '../services/assistant_controller.dart';
import '../theme/app_theme.dart';

/// FACE MODE — talk to Hari face to face.
///
/// The heavy lifting (WebRTC avatar stream, STT, lip-sync) happens inside
/// a server-hosted page (`GET /did/face`) powered by D-ID's Agents Embed;
/// the avatar's *words* come from OUR backend via the custom-LLM bridge,
/// so this face knows everything Hari knows. Hosting the page server-side
/// means the face UI can be improved for every install with a redeploy —
/// the same philosophy as the remote-config switchboard.
///
/// This screen's only jobs: get mic permission, pause the wake-word loop
/// (two listeners can't share one microphone), load the WebView, and
/// grant its runtime permission request.
class FaceScreen extends StatefulWidget {
  /// 'assistant' — the everyday Pro face session.
  /// 'interview' — the first-meeting hello for brand-new accounts.
  final String mode;
  const FaceScreen({super.key, this.mode = 'assistant'});

  @override
  State<FaceScreen> createState() => _FaceScreenState();
}

class _FaceScreenState extends State<FaceScreen> {
  WebViewController? _web;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Release the microphone: the WebView's WebRTC needs exclusive access.
    AssistantController.instance.onBackground();
    _start();
  }

  @override
  void dispose() {
    // Hand the mic back to the wake-word loop.
    AssistantController.instance.onForeground();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        setState(() {
          _error = 'Face Mode needs the microphone so Hari can hear you.';
          _loading = false;
        });
        return;
      }
      final url = await ApiService.startFaceSession(mode: widget.mode);
      final c = WebViewController(
        // The embed asks the WebView for mic access at runtime — grant it
        // (the OS-level permission was already approved above).
        onPermissionRequest: (request) => request.grant(),
      )
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        // TRANSPARENT WebView: the hosted /did/face page also paints a
        // transparent background, so the app's own backdrop below shows
        // through instead of a mismatched solid box around the avatar.
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            // Only surface errors for the main document, not sub-resources.
            if (e.isForMainFrame == true && mounted) {
              setState(() {
                _error = 'Could not load Face Mode. Check your connection.';
                _loading = false;
              });
            }
          },
        ));
      await c.loadRequest(Uri.parse(url));
      if (mounted) setState(() => _web = c);
    } on ProRequired {
      if (!mounted) return;
      Navigator.pop(context, 'pro_required');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Face Mode is unavailable right now. Please try again.';
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
        title: Text(widget.mode == 'interview' ? 'Meet Hari' : 'Face to face'),
        actions: widget.mode == 'interview'
            ? [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'done'),
                  child: const Text('Done',
                      style: TextStyle(
                          color: AppColors.marigold,
                          fontWeight: FontWeight.w600)),
                ),
              ]
            : null,
      ),
      body: Stack(
        children: [
          // Brand backdrop that shows through the transparent WebView —
          // the avatar appears to live inside the app, not in a web box.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.4),
                radius: 1.2,
                colors: [Color(0xFF14242A), AppColors.ink],
              ),
            ),
            child: SizedBox.expand(),
          ),
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
