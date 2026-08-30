import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../design/neon_tokens.dart';
import '../../services/auth_service.dart';
import '../../services/brief_service.dart';
import 'state/assistant_engine.dart';
import 'state/assistant_state.dart';
import 'widgets/assistant_persona.dart';
import 'widgets/aura_core.dart';
import 'widgets/action_cards.dart';
import 'widgets/today_panel.dart';
import '../../screens/assistant_settings_screen.dart';
import '../../screens/clients_screen.dart';
import '../../screens/stocks_screen.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE ASSISTANT SCREEN.
///
///  WHAT CHANGED AND WHY
///
///  1. NO STATIC PORTRAIT. The screen used to show a motionless photograph
///     until the avatar's video arrived, which read as a frozen video call —
///     the user could not tell connecting from crashed. It now shows a
///     PresenceOrb that visibly reflects state, and cross-fades to video the
///     moment a frame exists.
///
///  2. THE CONVERSATION IS ALREADY RUNNING. Live mode starts with the screen
///     (AssistantEngine.start), so there is nothing to tap to begin. The big
///     button is therefore END, not START — it matches what is actually
///     happening instead of inviting the user to start something that has
///     already started.
///
///  3. ONE HONEST STATUS. A single line, driven by the real phase, with a
///     colour that matches the orb. Guessing at state was the main thing
///     that made this screen feel broken.
///
///  4. CONTROLS GET OUT OF THE WAY. A frosted bar with one primary action
///     and two secondaries, rather than three equal circles competing with
///     the subject of the screen.
/// ─────────────────────────────────────────────────────────────────────────
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final engine = AssistantEngine.instance;
  AssistantPersona _persona = AssistantPersona.neutral;
  bool _stocksEnabled = false;

  @override
  void initState() {
    super.initState();
    engine.start();
    engine.addListener(_onStateChanged);
    // The Today pill's data — one aggregate fetch, refreshed quietly.
    BriefService.instance.start();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final persona = await AssistantPersonaResolver.resolve();
      if (!mounted) return;
      setState(() => _persona = persona);
      engine.greetingName = AuthService.instance.user?.name;
      engine.greetOnce(name: AuthService.instance.user?.name);
    });
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    engine.removeListener(_onStateChanged);
    super.dispose();
  }

  /* ---------------------------------------------------------------- */
  /* State → words and colour. One source, so nothing contradicts.     */
  /* ---------------------------------------------------------------- */

  bool get _hasVideo => engine.avatarTrack != null;

  String get _statusText {
    if (!engine.connected) return 'Connecting';
    return switch (engine.phase) {
      AssistantPhase.listening => 'Listening',
      AssistantPhase.speaking => 'Speaking',
      AssistantPhase.thinking ||
      AssistantPhase.searching ||
      AssistantPhase.transcribing ||
      AssistantPhase.generatingVoice ||
      AssistantPhase.preparingMessage =>
        'Thinking',
      AssistantPhase.waitingForConfirmation => 'Waiting for you',
      AssistantPhase.findingContact => 'Finding contact',
      AssistantPhase.dialing => 'Dialling',
      AssistantPhase.ringing => 'Ringing',
      AssistantPhase.inCall => 'On a call',
      AssistantPhase.error => 'Something went wrong',
      _ => 'Ready',
    };
  }

  Color get _statusColor {
    if (!engine.connected) return Neon.textLo;
    return switch (engine.phase) {
      AssistantPhase.listening => Neon.cyan,
      AssistantPhase.speaking => Neon.pink,
      AssistantPhase.error => Neon.error,
      AssistantPhase.inCall ||
      AssistantPhase.dialing ||
      AssistantPhase.ringing =>
        Neon.success,
      _ when engine.phase.busy => Neon.violet,
      _ => Neon.textLo,
    };
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final h = media.size.height;

    return Scaffold(
      backgroundColor: Neon.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _stage(h),
          _scrims(),
          SafeArea(
            child: Column(
              children: [
                _topBar(),
                if (engine.errorMessage != null) _errorBanner(),
                const Spacer(),
                _overlayCards(h),
                // The day at a glance — agenda, promises, messages, circle.
                const TodayPill(),
                _controls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /* ---------------------------------------------------------------- */
  /* THE SUBJECT: video when we have it, presence when we don't.       */
  /* ---------------------------------------------------------------- */

  Widget _stage(double h) {
    // Cross-fade rather than swap. The avatar's first frame arriving is the
    // nicest moment in the whole session; a hard cut throws it away.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 520),
      switchInCurve: Curves.easeOut,
      child: _hasVideo
          ? SizedBox.expand(
              key: const ValueKey('video'),
              child: lk.VideoTrackRenderer(
                engine.avatarTrack!,
                fit: lk.VideoViewFit.cover,
              ),
            )
          : _presenceStage(h),
    );
  }

  Widget _presenceStage(double h) {
    return Container(
      key: const ValueKey('presence'),
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.25),
          radius: 1.1,
          colors: [Color(0xFF161C2E), Neon.bg],
        ),
      ),
      child: Center(
        child: Padding(
          // Sits above centre so it is not hidden behind the control bar.
          padding: EdgeInsets.only(bottom: h * 0.12),
          // The assistant's living presence — an organic aura instead of a
          // spinner: it breathes at rest, ripples with the user's voice,
          // pulses when Hari speaks, swirls while thinking.
          child: AuraCore(
            size: h * 0.40,
            phase: engine.connected ? engine.phase : AssistantPhase.idle,
            level: engine.micLevel,
          ),
        ),
      ),
    );
  }

  /// Legibility for the text and controls laid over video.
  Widget _scrims() => IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.55),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.25),
                Colors.black.withValues(alpha: 0.82),
              ],
              stops: const [0.0, 0.22, 0.62, 1.0],
            ),
          ),
        ),
      );

  /* ---------------------------------------------------------------- */
  /* TOP                                                              */
  /* ---------------------------------------------------------------- */

  Widget _topBar() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
        child: Row(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _persona.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                _statusRow(),
              ],
            ),
            const Spacer(),
            _iconButton(
              icon: _stocksEnabled
                  ? Icons.candlestick_chart_rounded
                  : Icons.candlestick_chart_outlined,
              tint: _stocksEnabled ? Neon.cyan : null,
              onTap: () => setState(() => _stocksEnabled = !_stocksEnabled),
            ),
          ],
        ),
      );

  /// Status as a live dot plus a word. Replaces the old LIVE/OFFLINE pill,
  /// which only ever said whether the socket was up — not what the
  /// assistant was actually doing, which is what the user wants to know.
  Widget _statusRow() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _pulseDot(_statusColor),
          const SizedBox(width: 7),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              _statusText,
              key: ValueKey(_statusText),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      );

  Widget _pulseDot(Color c) => TweenAnimationBuilder<double>(
        key: ValueKey(c.toARGB32()),
        tween: Tween(begin: 0.6, end: 1.0),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeInOut,
        builder: (_, v, __) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.withValues(alpha: v),
            boxShadow: [
              BoxShadow(color: c.withValues(alpha: 0.5 * v), blurRadius: 8),
            ],
          ),
        ),
      );

  Widget _errorBanner() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: GestureDetector(
          onTap: engine.dismissError,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Neon.error.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Neon.rMd),
              border: Border.all(color: Neon.error.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Neon.error, size: 17),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    engine.errorMessage ?? '',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13, height: 1.3),
                  ),
                ),
                Icon(Icons.close_rounded,
                    color: Colors.white.withValues(alpha: 0.5), size: 16),
              ],
            ),
          ),
        ),
      );

  /* ---------------------------------------------------------------- */
  /* CARDS — approvals, call progress, citations                       */
  /* ---------------------------------------------------------------- */

  Widget _overlayCards(double h) {
    if (engine.pendingConfirmation != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: ConfirmationCard(
          pending: engine.pendingConfirmation!,
          onDecision: engine.confirm,
        ),
      );
    }
    if (engine.callStatus != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: CallStatusCard(status: engine.callStatus!),
      );
    }
    if (engine.searchResults.isNotEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: h * 0.32),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          itemCount: engine.searchResults.length.clamp(0, 4),
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) =>
              SearchResultCard(result: engine.searchResults[i]),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  /* ---------------------------------------------------------------- */
  /* CONTROLS                                                         */
  /* ---------------------------------------------------------------- */

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Neon.rXl),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(Neon.rXl),
              border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _softButton(
                  icon: Icons.folder_shared_rounded,
                  label: 'Clients',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const ClientsScreen())),
                ),
                if (_stocksEnabled)
                  _softButton(
                    icon: Icons.trending_up_rounded,
                    label: 'Markets',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const StocksScreen())),
                  ),
                _primaryButton(),
                _softButton(
                  icon: Icons.tune_rounded,
                  label: 'Settings',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const AssistantSettingsScreen())),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The primary control.
  ///
  /// While a conversation is live this ENDS it — the session is already
  /// running, so offering "tap to speak" would be describing something the
  /// user does not need to do. When nothing is live it starts one.
  Widget _primaryButton() {
    final live = engine.liveActive;
    final level = engine.micLevel.clamp(0.0, 1.0);
    final listening = engine.phase == AssistantPhase.listening;

    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        engine.pressMic();
      },
      child: SizedBox(
        width: 92,
        height: 78,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            // Grows with the user's voice while listening, so the control
            // itself confirms the microphone is working.
            width: 66 + (listening ? level * 8 : 0),
            height: 66 + (listening ? level * 8 : 0),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: live
                  ? const LinearGradient(
                      colors: [Color(0xFFFF5A6E), Color(0xFFE5484D)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : Neon.gVioletCyan,
              boxShadow: [
                BoxShadow(
                  color: (live ? Neon.error : Neon.violet)
                      .withValues(alpha: 0.35 + (listening ? level * 0.4 : 0)),
                  blurRadius: 22 + (listening ? level * 24 : 0),
                  spreadRadius: listening ? level * 5 : 0,
                ),
              ],
            ),
            child: Icon(
              live ? Icons.call_end_rounded : Icons.mic_rounded,
              color: Colors.white,
              size: 29,
            ),
          ),
        ),
      ),
    );
  }

  Widget _softButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 62,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: 0.10),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: Icon(icon, color: Colors.white, size: 21),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.68),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _iconButton({
    required IconData icon,
    required VoidCallback onTap,
    Color? tint,
  }) =>
      IconButton(
        onPressed: onTap,
        icon: Icon(icon,
            color: tint ?? Colors.white.withValues(alpha: 0.65), size: 22),
      );
}
