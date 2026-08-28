import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../../services/live_service.dart';
import '../../../services/avatar_service.dart';
import '../../../screens/diagnostics_screen.dart';
import '../../../screens/clients_screen.dart';
import '../../../design/neon_tokens.dart';

/// Real-time Audio-to-Audio Gemini Bidi Voice Interface.
///
/// Features:
///   • Direct WebSocket voice streaming (PCM16 @ 16 kHz up, PCM16 @ 24 kHz down).
///   • Dynamic glowing voice orb reacting to mic volume & assistant audio output.
///   • Real-time live transcript display for both user and Hari.
///   • Mute toggle & session controls.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> with TickerProviderStateMixin {
  final LiveService _liveSvc = LiveService.instance;

  double _micLevel = 0.0;
  bool _isSpeaking = false;
  bool _isMuted = false;
  bool _connecting = true;
  String _userTranscript = '';
  String _hariTranscript = '';
  String? _errorMessage;

  final AvatarService _avatar = AvatarService.instance;

  /// Null until BeyondPresence is actually rendering. Everything about the
  /// screen falls back to the orb while it is, so a slow or unavailable
  /// avatar costs the user nothing but a plainer picture.
  lk.VideoTrack? _avatarTrack;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _setupAnimation();
    _startSession();
  }

  void _setupAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  Future<void> _startSession() async {
    setState(() {
      _connecting = true;
      _errorMessage = null;
    });

    _liveSvc.onReady = () {
      if (mounted) {
        setState(() {
          _connecting = false;
        });
      }
    };

    _liveSvc.onMicLevel = (level) {
      if (mounted && !_isMuted) {
        setState(() {
          _micLevel = level;
        });
      }
    };

    _liveSvc.onSpeaking = (speaking) {
      if (mounted) {
        setState(() {
          _isSpeaking = speaking;
        });
      }
    };

    _liveSvc.onUserText = (text) {
      if (mounted) {
        setState(() {
          _userTranscript = text;
        });
      }
    };

    _liveSvc.onHariText = (text) {
      if (mounted) {
        setState(() {
          _hariTranscript = text;
        });
      }
    };

    _liveSvc.onInterrupted = () {
      if (mounted) {
        setState(() {
          _hariTranscript = '...';
        });
      }
    };

    _liveSvc.onError = (msg) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _errorMessage = msg;
        });
      }
    };

    // Reserve the avatar FIRST: the backend needs the room name at socket
    // setup time to know where to send Hari's voice. Deliberately not
    // fatal — a null room simply means this call is audio-only.
    _avatar.onChanged = () {
      if (mounted) setState(() => _avatarTrack = _avatar.videoTrack);
    };
    String? room;
    if (await AvatarService.isAvailable()) {
      room = await _avatar.start();
    }
    if (!mounted) return;

    await _liveSvc.start(avatarRoom: room);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _liveSvc.stop();
    _avatar.onChanged = null;
    // Ends the BEY session. Fire-and-forget: dispose cannot await, but the
    // backend also tears the room down when the live socket closes.
    _avatar.stop();
    super.dispose();
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      if (_isMuted) {
        _micLevel = 0.0;
      }
    });
  }

  /// Mic toggle used while the avatar is on screen: small, translucent
  /// and low in the frame so it never covers her face.
  Widget _avatarMicButton() {
    return GestureDetector(
      onTap: _toggleMute,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isMuted
              ? Colors.red.withValues(alpha: 0.85)
              : Colors.white.withValues(alpha: 0.16),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.35), width: 1.5),
        ),
        child: Icon(
          _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          color: Colors.white,
          size: 32,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeLevel =
        _isSpeaking ? 0.6 + (_pulseAnim.value - 1.0) : _micLevel;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0C10),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The avatar owns the full screen while BEY is rendering. The
          // ambient glow below is what audio-only mode falls back to, so
          // a missing avatar looks intentional rather than broken.
          if (_avatarTrack != null)
            Positioned.fill(
              child: lk.VideoTrackRenderer(
                _avatarTrack!,
                fit: lk.VideoViewFit.cover,
              ),
            ),

          // Scrim: a real face is bright and busy, and the header, status
          // line and transcript sit directly on top of it.
          if (_avatarTrack != null)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.55),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.78),
                      ],
                      stops: const [0.0, 0.38, 1.0],
                    ),
                  ),
                ),
              ),
            ),

          // Background ambient gradient glow
          if (_avatarTrack == null)
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.85 + (activeLevel * 0.4),
                    colors: [
                      _isSpeaking
                          ? Neon.violet.withValues(alpha: 0.25)
                          : Neon.cyan.withValues(alpha: 0.20),
                      Colors.black.withValues(alpha: 0.95),
                    ],
                  ),
                ),
              ),
            ),

          SafeArea(
            child: Column(
              children: [
                // Top Header Bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close_rounded,
                            color: Colors.white70, size: 28),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Voice Assistant',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const Spacer(),
                      _statusPill(),
                    ],
                  ),
                ),

                const Spacer(),

                // Central Voice Orb. Once the avatar is up she IS the
                // focal point, so the orb gives way to a compact control.
                if (_avatarTrack == null)
                  GestureDetector(
                    onTap: _toggleMute,
                    child: ScaleTransition(
                      scale: _pulseAnim,
                      child: Container(
                        width: 170,
                        height: 170,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: _isMuted
                                ? [Colors.grey.shade800, Colors.grey.shade900]
                                : _isSpeaking
                                    ? [Neon.violet, Neon.pink]
                                    : [Neon.cyan, Neon.violet],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (_isSpeaking ? Neon.violet : Neon.cyan)
                                  .withValues(
                                      alpha: 0.35 + (activeLevel * 0.4)),
                              blurRadius: 35 + (activeLevel * 45),
                              spreadRadius: 8 + (activeLevel * 20),
                            ),
                          ],
                        ),
                        child: Center(
                          child: Icon(
                            _isMuted
                                ? Icons.mic_off_rounded
                                : _isSpeaking
                                    ? Icons.graphic_eq_rounded
                                    : Icons.mic_rounded,
                            color: Colors.white,
                            size: 56,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  _avatarMicButton(),

                const SizedBox(height: 32),

                // Status text
                Text(
                  _connecting
                      ? 'Connecting to Hari…'
                      : _errorMessage != null
                          ? _errorMessage!
                          : _isMuted
                              ? 'Microphone Muted'
                              // With the avatar live the reply audio never
                              // reaches this app, so there is no local
                              // signal to call "speaking" from — her face
                              // already says it.
                              : _avatarTrack != null
                                  ? 'Tap the mic to mute'
                                  : _isSpeaking
                                      ? 'Hari is speaking…'
                                      : 'Listening…',
                  style: TextStyle(
                    color: _errorMessage != null
                        ? Colors.redAccent
                        : Colors.white70,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),

                const SizedBox(height: 24),

                // Real-time transcript box
                if (_userTranscript.isNotEmpty || _hariTranscript.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 28),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Column(
                      children: [
                        if (_userTranscript.isNotEmpty)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'You: $_userTranscript',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        if (_userTranscript.isNotEmpty &&
                            _hariTranscript.isNotEmpty)
                          const SizedBox(height: 8),
                        if (_hariTranscript.isNotEmpty)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Hari: $_hariTranscript',
                              style: const TextStyle(
                                color: Neon.cyan,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                const Spacer(),

                // Bottom Control Bar
                Container(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _roundButton(
                        icon: Icons.folder_shared_rounded,
                        label: 'Clients',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ClientsScreen()),
                        ),
                      ),
                      _roundButton(
                        icon: _isMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: _isMuted ? 'Unmute' : 'Mute',
                        active: _isMuted,
                        onTap: _toggleMute,
                      ),
                      _roundButton(
                        icon: Icons.call_end_rounded,
                        label: 'End Session',
                        color: Colors.redAccent,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                      _roundButton(
                        icon: Icons.monitor_heart_outlined,
                        label: 'Diagnostics',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const DiagnosticsScreen()),
                        ),
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

  Widget _statusPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _connecting
                ? Colors.amber.withValues(alpha: 0.4)
                : Colors.greenAccent.withValues(alpha: 0.4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _connecting ? Colors.amber : Colors.greenAccent,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              _connecting ? 'CONNECTING' : 'LIVE VOICE',
              style: TextStyle(
                color: _connecting ? Colors.amber : Colors.greenAccent,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      );

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color? color,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active
                  ? (color ?? Neon.cyan).withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.1),
              border: Border.all(
                color: active
                    ? (color ?? Neon.cyan)
                    : Colors.white.withValues(alpha: 0.18),
              ),
            ),
            child: Icon(icon, color: color ?? Colors.white, size: 24),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.75),
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
