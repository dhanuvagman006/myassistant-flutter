import 'package:flutter/material.dart';
import '../core/config.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../features/assistant/widgets/avatar_view.dart';
import '../services/live_service.dart';

class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  final _engine = AssistantEngine.instance;
  bool _isLive = false;

  @override
  void initState() {
    super.initState();
    _startConversation();
  }

  Future<void> _startConversation() async {
    try {
      // 1. Establish the bidirectional WebSocket session
      await _engine.start();
    } catch (e) {
      debugPrint('AvatarScreen: engine.start() failed: $e');
      return; // Do not proceed if the engine failed to start
    }

    if (!mounted) return;
    setState(() => _isLive = true);

    // 2. Wait for the WebSocket handshake to fully complete before sending text
    await Future.delayed(const Duration(milliseconds: 800));

    // 3. Guard: if we navigated away during the delay, do not send
    if (!mounted) return;

    // 4. Trigger initial greeting via the live service
    LiveService.instance.sendText(
      "The user just opened the app. Briefly greet them warmly and ask how you can help.",
    );
  }

  @override
  void dispose() {
    // Stop the engine on the way out — the engine handles its own null-guards
    _engine.stopLive();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Full-screen avatar
          AvatarView(
            apiKey: kSimliApiKey,
            faceId: kSimliFaceId,
            isLive: _isLive,
          ),

          // Close / back button
          Positioned(
            top: 50,
            left: 20,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white54, size: 30),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),

          // Connection status overlay
          if (!_isLive)
            const Positioned(
              bottom: 50,
              left: 0,
              right: 0,
              child: Center(
                child: Text(
                  "Connecting to AI Engine...",
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
