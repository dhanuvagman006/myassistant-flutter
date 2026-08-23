import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../../../services/api_service.dart';
import '../../../../services/auth_service.dart';
import '../../../screens/diagnostics_screen.dart';
import '../../../screens/clients_screen.dart';
import '../../../design/neon_tokens.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final url = '${ApiService.baseUrl}/avatar/room/?token=${ApiService.sessionToken}';
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setOnConsoleMessage((message) {
         debugPrint('WebView: ${message.message}');
      })
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (error) {
             debugPrint('WebView Error: ${error.description}');
          }
        ),
      );
      
    // Android specific settings for WebRTC
    if (_controller.platform is AndroidWebViewController) {
      final androidController = _controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      androidController.setOnPlatformPermissionRequest((request) {
        request.grant();
      });
    }

    _controller.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // D-ID Avatar Stream
          WebViewWidget(controller: _controller),
          
          if (_loading)
            const Center(child: CircularProgressIndicator(color: Neon.violet)),

          // Overlay UI
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Row(
                    children: [
                      const Text(
                        'Live Session',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      _livePill(),
                    ],
                  ),
                ),
                
                const Spacer(),
                
                // Bottom controls
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 30),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.85),
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _roundButton(
                        icon: Icons.folder_shared_rounded,
                        label: 'Clients',
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ClientsScreen())),
                      ),
                      _micButton(),
                      _roundButton(
                        icon: Icons.monitor_heart_outlined,
                        label: 'Diagnostics',
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DiagnosticsScreen())),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _livePill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8, height: 8,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFE5484D)),
            ),
            const SizedBox(width: 7),
            const Text('LIVE',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
          ],
        ),
      );

  Widget _micButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {}, // Handled by WebView audio channel
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Neon.violet,
            ),
            child: const Icon(Icons.mic_rounded, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 8),
        Text('Talk naturally', style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 12.5)),
      ],
    );
  }

  Widget _roundButton({required IconData icon, required String label, required VoidCallback onTap}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 11.5)),
      ],
    );
  }
}
