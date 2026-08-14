import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../design/neon_tokens.dart';
import '../../../screens/assistant_settings_screen.dart';
import '../../../screens/clients_screen.dart';
import '../../../screens/diagnostics_screen.dart';
import '../../../screens/mcp_servers_screen.dart';
import '../../../screens/survey_screen.dart';
import '../../../services/auth_service.dart';
import '../assistant_screen.dart';
import 'live_session_controller.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  LIVE SCREEN — the main screen of the app (Rebuild §5).
///
///  The user opens the app and is in a live video call with their
///  assistant: a real human avatar, full screen, talking and listening in
///  real time. No transcript bubbles, no microphone orb, no chat feed —
///  those belong to the secondary voice mode, reachable from ⋯ More.
///
///      ┌───────────────────────────────┐
///      │        LIVE HUMAN VIDEO       │
///      │                               │
///      │       "Maya"    ● LIVE        │
///      │      🔊      ⋯     END CALL   │
///      └───────────────────────────────┘
///
///  Every overlay is driven by the controller's explicit state machine:
///  a LIVE badge and the assistant's name appear only in `ready`, and
///  connection trouble is stated plainly with a retry — never papered
///  over with a fake greeting (§10).
/// ─────────────────────────────────────────────────────────────────────────
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final _session = LiveSessionController();

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    // First run: the onboarding interview comes before the call, so the
    // assistant already knows the user's name when she greets them.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (await SurveyGate.needed()) {
        if (!mounted) return;
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const SurveyScreen()));
      }
      AuthService.instance.lastSignInWasNew = false;
      _session.start();
    });
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _session.state;
    return Scaffold(
      backgroundColor: const Color(0xFF06080E),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The live human, full-bleed. Present from `connecting` on so
          // the room can negotiate; overlays cover it until READY.
          if (_session.web != null &&
              s != LiveSessionState.ended &&
              s != LiveSessionState.error &&
              s != LiveSessionState.offline)
            WebViewWidget(controller: _session.web!),

          // State overlays — exactly one at a time.
          switch (s) {
            LiveSessionState.initializing ||
            LiveSessionState.connecting =>
              _connectingOverlay('Connecting to your assistant\u2026'),
            LiveSessionState.connected =>
              _connectingOverlay('Almost there\u2026', dim: true),
            LiveSessionState.ready => _liveChrome(),
            LiveSessionState.error ||
            LiveSessionState.offline =>
              _troubleOverlay(offline: s == LiveSessionState.offline),
            LiveSessionState.ended => _endedOverlay(),
          },
        ],
      ),
    );
  }

  /* ------------------------------------------------------------------ */
  /* READY — the call chrome                                             */
  /* ------------------------------------------------------------------ */

  Widget _liveChrome() {
    return SafeArea(
      child: Column(
        children: [
          // Top: assistant name + LIVE. Shown ONLY in ready state.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                if (_session.assistantName.isNotEmpty)
                  Text(
                    _session.assistantName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                const Spacer(),
                _livePill(),
              ],
            ),
          ),
          const Spacer(),
          // Bottom: controls on a soft gradient so they read over video.
          Container(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.55),
                ],
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _roundButton(
                  icon: _session.speakerOn
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  label: 'Speaker',
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _session.toggleSpeaker();
                  },
                ),
                _endCallButton(),
                _roundButton(
                  icon: Icons.more_horiz_rounded,
                  label: 'More',
                  onTap: _openMore,
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
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulsingDot(),
            SizedBox(width: 7),
            Text('LIVE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                )),
          ],
        ),
      );

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
              border:
                  Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: Icon(icon, color: Colors.white, size: 26),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75), fontSize: 11.5)),
      ],
    );
  }

  Widget _endCallButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () {
            HapticFeedback.mediumImpact();
            _session.end();
          },
          child: Container(
            width: 68,
            height: 68,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFE5484D),
            ),
            child: const Icon(Icons.call_end_rounded,
                color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 6),
        Text('End',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75), fontSize: 11.5)),
      ],
    );
  }

  /* ------------------------------------------------------------------ */
  /* Connecting / trouble / ended                                        */
  /* ------------------------------------------------------------------ */

  /// While connecting: name of the app + spinner. Deliberately contains
  /// NO greeting and NO LIVE badge (§10) — nothing here may imply a
  /// working session before one exists.
  Widget _connectingOverlay(String message, {bool dim = false}) {
    return Container(
      color: dim
          ? Colors.black.withValues(alpha: 0.55)
          : const Color(0xFF06080E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: Neon.violet),
            ),
            const SizedBox(height: 20),
            Text(message,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 15)),
          ],
        ),
      ),
    );
  }

  /// Honest failure (§9, §10, §30): what went wrong, retry, and a clearly
  /// labelled voice-only fallback. Never a silhouette pretending to be a
  /// live call, never a greeting.
  Widget _troubleOverlay({required bool offline}) {
    return Container(
      color: const Color(0xFF06080E),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  offline
                      ? Icons.cloud_off_rounded
                      : Icons.videocam_off_rounded,
                  size: 44,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
                const SizedBox(height: 16),
                Text(
                  _session.errorMessage.isEmpty
                      ? 'The live session is unavailable right now.'
                      : _session.errorMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 15,
                      height: 1.45),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Neon.violet,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 36, vertical: 14),
                  ),
                  onPressed: _session.start,
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _openVoiceMode,
                  child: Text('Continue in voice mode',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8))),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const DiagnosticsScreen())),
                  child: Text('Diagnostics',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12.5)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _endedOverlay() {
    return Container(
      color: const Color(0xFF06080E),
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline_rounded,
                  size: 44, color: Colors.white.withValues(alpha: 0.6)),
              const SizedBox(height: 16),
              Text('Call ended',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 16)),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Neon.violet,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 36, vertical: 14),
                ),
                onPressed: _session.start,
                child: const Text('Call again'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _openMore,
                child: Text('More',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7))),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ */
  /* More sheet — everything that is NOT the live call (§13)             */
  /* ------------------------------------------------------------------ */

  Future<void> _openVoiceMode() async {
    // Voice mode runs its own mic loop — the live room must not hold the
    // microphone underneath it.
    if (_session.state == LiveSessionState.ready ||
        _session.state == LiveSessionState.connected) {
      await _session.end();
    }
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AssistantScreen()));
  }

  void _openMore() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 6),
            _moreTile(sheet, Icons.mic_rounded,
                'Voice mode (with history)', _openVoiceMode),
            _moreTile(sheet, Icons.folder_shared_rounded, 'Clients & cases',
                () => _push(const ClientsScreen())),
            _moreTile(sheet, Icons.face_retouching_natural_rounded,
                'Assistant settings',
                () => _push(const AssistantSettingsScreen())),
            _moreTile(sheet, Icons.extension_rounded, 'MCP servers',
                () => _push(const McpServersScreen())),
            _moreTile(sheet, Icons.monitor_heart_outlined, 'Diagnostics',
                () => _push(const DiagnosticsScreen())),
            _moreTile(sheet, Icons.logout_rounded, 'Sign out', () async {
              await _session.end();
              await AuthService.instance.signOut();
            }),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _push(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
  }

  Widget _moreTile(BuildContext sheet, IconData icon, String label,
      VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Neon.textLo),
      title: Text(label, style: const TextStyle(color: Neon.textHi)),
      onTap: () {
        Navigator.of(sheet).pop();
        onTap();
      },
    );
  }
}

/// The pulsing red dot inside the LIVE pill.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
            shape: BoxShape.circle, color: Color(0xFFE5484D)),
      ),
    );
  }
}
