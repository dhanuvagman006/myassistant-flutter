import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../design/neon_tokens.dart';
import '../../services/auth_service.dart';
import 'state/assistant_engine.dart';
import 'state/assistant_state.dart';
import 'widgets/assistant_persona.dart';
import 'widgets/aura_core.dart';
import 'widgets/siri_orb.dart';
import 'widgets/action_cards.dart';

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

  @override
  void initState() {
    super.initState();
    engine.addListener(_onStateChanged);

    // App boot (brief, messages, usage, location) happens in HomeShell.
    // Opening THIS screen is the user's "I want to talk" gesture — only now
    // does Hari greet and the live conversation begin. The app itself never
    // starts listening or speaking on launch.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final persona = await AssistantPersonaResolver.resolve();
      if (!mounted) return;
      setState(() => _persona = persona);
      engine.beginConversation(name: AuthService.instance.user?.name);
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 22),
                  child: Center(child: _primaryButton()),
                ),
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
          colors: [Color(0xFFECEAF8), Neon.bg],
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
                Neon.bg.withValues(alpha: 0.85),
                Colors.transparent,
                Neon.bg.withValues(alpha: 0.35),
                Neon.bg.withValues(alpha: 0.95),
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
                    color: Neon.textHi,
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
              icon: Icons.keyboard_arrow_down_rounded,
              onTap: () => Navigator.of(context).maybePop(),
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
              style: const TextStyle(
                color: Neon.textLo,
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
                        color: Neon.textHi, fontSize: 13, height: 1.3),
                  ),
                ),
                const Icon(Icons.close_rounded,
                    color: Neon.textDim, size: 16),
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
    if (engine.presentedText != null) {
      // A speech/script/draft Hari wrote — reader card, tap to go big.
      // X or a sideways swipe puts it away; talking continues either way.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Dismissible(
          key: const ValueKey('presented-text-card'),
          onDismissed: (_) => engine.dismissPresentedText(),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: h * 0.4),
            child: ScriptCard(
              title: engine.presentedTitle ?? 'From Hari',
              content: engine.presentedText!,
              onClose: engine.dismissPresentedText,
            ),
          ),
        ),
      );
    }
    if (engine.generatedImage != null) {
      // The showpiece: an image Hari just created. Give it real estate —
      // and let X or a sideways swipe put it away when they're done.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Dismissible(
          key: ValueKey('generated-image-${engine.generatedImage!.id}'),
          onDismissed: (_) => engine.dismissGeneratedImage(),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: h * 0.46),
            child: GeneratedImageCard(
              document: engine.generatedImage!,
              prompt: engine.generatedImagePrompt,
              onClose: engine.dismissGeneratedImage,
            ),
          ),
        ),
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

  /// The primary control — the Siri-style orb.
  ///
  /// No mic glyph: the waveform IS the state. Still and dim means stopped,
  /// bright moving waves mean hearing you, pink rolling waves mean Hari is
  /// talking. One tap toggles the conversation; the label underneath only
  /// ever says the one action a tap would perform right now.
  Widget _primaryButton() {
    final live = engine.liveActive;
    final sessionUp = engine.connected || live;
    final active = live ||
        (engine.phase.busy && engine.phase != AssistantPhase.completed);

    final hint = !sessionUp
        ? 'Connecting…'
        : active
            ? 'Tap to stop'
            : 'Tap to talk';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.mediumImpact();
        engine.pressMic();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SiriOrb(
            size: 92,
            phase: sessionUp ? engine.phase : AssistantPhase.idle,
            level: engine.micLevel,
            connected: sessionUp,
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: Text(
              hint,
              key: ValueKey(hint),
              style: const TextStyle(
                color: Neon.textLo,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required VoidCallback onTap,
    Color? tint,
  }) =>
      IconButton(
        onPressed: onTap,
        icon: Icon(icon, color: tint ?? Neon.textLo, size: 22),
      );
}
