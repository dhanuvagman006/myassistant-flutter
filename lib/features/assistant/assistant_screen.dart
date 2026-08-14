import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/gyro_tilt.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../models/remote_config.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import 'state/assistant_engine.dart';
import 'widgets/action_cards.dart';
import '../../screens/diagnostics_screen.dart';
import '../../screens/avatar_screen.dart';
import 'widgets/assistant_persona.dart';
import '../../screens/clients_screen.dart';
import '../../screens/survey_screen.dart';
import 'widgets/assistant_hero_widget.dart';
import 'widgets/bottom_input_bar.dart';

/// THE app — a single-page AI agent experience.
///
/// Layout (top → bottom):
///   • animated hero orb (state-driven)
///   • live transcript + dynamic action cards
///   • quick-action glass chips (first launch) → tap to run
///   • frosted bottom bar: mic + text fallback
///
/// The top bar (hub / calls / profile / settings) and its pages were removed.
/// The status pill and error banner are commented out for now.
/// The first-run interview still opens as a bottom sheet on first sign-in.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final engine = AssistantEngine.instance;
  final _scroll = ScrollController();
  RemoteConfig _config = const RemoteConfig();
  bool _announcementDismissed = false;
  bool _avatarAvailable = false;

  @override
  void initState() {
    super.initState();
    engine.start();
    engine.addListener(_autoScroll);
    ApiService.refreshConfig().then((c) {
      if (mounted) setState(() => _config = c);
    });
    AvatarScreen.available().then((ok) {
      if (mounted) setState(() => _avatarAvailable = ok);
    });
    // VOICE-DRIVEN VIDEO MODE: saying "open video mode" pushes the avatar
    // video call. The engine can't navigate (no BuildContext), so it calls
    // back here. The chip that used to sit under the orb is gone — voice is
    // the way in.
    engine.onOpenVideoMode = _openVideoMode;

    // ASSISTANT PRESENCE. Resolve the persona and hand the engine the
    // user's name. The GREETING is NOT triggered here: it fires from the
    // engine's connect path when the live session genuinely becomes
    // ready, so opening the screen offline never produces a greeting.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final persona = await AssistantPersonaResolver.resolve();
      if (!mounted) return;
      setState(() => _persona = persona);
      engine.greetingName = AuthService.instance.user?.name;
      // If the session was already ready before the name arrived, this
      // lets the greeting happen now; it is still gated on `connected`.
      engine.greetOnce(name: AuthService.instance.user?.name);
    });
    // STARTUP: first run shows the native onboarding survey; after
    // that the orb home screen IS the experience (Face Mode removed).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (await SurveyGate.needed()) {
        if (!mounted) return;
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SurveyScreen()));
      }
      AuthService.instance.lastSignInWasNew = false;
    });
  }

  @override
  void dispose() {
    engine.removeListener(_autoScroll);
    engine.onOpenVideoMode = null;
    _scroll.dispose();
    super.dispose();
  }

  /// Opens the human-avatar video call (voice command "open video mode").
  /// Guards against a double-push if the screen is already on top, and says
  /// so plainly when the avatar service isn't configured.
  Future<void> _openVideoMode() async {
    if (!mounted) return;
    if (!_avatarAvailable) {
      // Re-check once: availability is fetched async at startup and may not
      // have landed yet on a cold start.
      _avatarAvailable = await AvatarScreen.available();
    }
    if (!mounted) return;
    if (!_avatarAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Video mode isn't set up on this account yet."),
      ));
      return;
    }
    if (_videoModeOpen) return;
    _videoModeOpen = true;
    engine.cancelAction(); // release the mic before the avatar takes over
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AvatarScreen()));
    _videoModeOpen = false;
  }

  bool _videoModeOpen = false;

  /// Who the assistant appears to be. Neutral until resolved so the first
  /// frame never flickers a wrong persona.
  AssistantPersona _persona = AssistantPersona.neutral;

  /// True while a live avatar session is connecting (polished loading
  /// state inside the circle instead of falling back to an icon, §12).
  final bool _avatarConnecting = false;

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: engine,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: AuroraBackdrop(
            child: SafeArea(
              child: Column(
                children: [
                  if (_config.announcement != null && !_announcementDismissed)
                    _announcement(),
                  const SizedBox(height: 16),
                  // Hero shrinks once a conversation is underway so the
                  // transcript/cards get the room.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    height: engine.transcript.isEmpty ? 236 : 148,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: AssistantHeroWidget(
                        phase: engine.phase,
                        micLevel: engine.micLevel,
                        onTap: engine.pressMic, // tap the orb to talk
                        persona: _persona,
                        avatarConnecting: _avatarConnecting,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AssistantStatusPill(
                        phase: engine.phase,
                        connected: engine.connected,
                        onCancel: engine.cancelAction,
                      ),
                      // The video-mode chip used to sit here. It's gone —
                      // say "open video mode" instead. The LIVE chip is
                      // gone too: tapping the ORB now starts a live
                      // conversation directly.
                      const SizedBox(width: 10),
                      // Professional mode: patients/clients case files.
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const ClientsScreen()));
                        },
                        child: Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.07),
                            border: Border.all(
                                color: Neon.violet.withValues(alpha: 0.5)),
                          ),
                          child: const Icon(Icons.folder_shared_rounded,
                              color: Neon.violet, size: 18),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Connection trouble is VISIBLE and tappable — the
                  // banner opens Diagnostics (server URL, /health test,
                  // live logs). Silence was the old "not even
                  // connecting" experience.
                  if (!engine.connected || engine.errorMessage != null)
                    _connectionBanner(engine),
                  // PURE VOICE: during a live conversation there is no
                  // text chat and no input bar — just the orb and a hint.
                  Expanded(
                      child:
                          engine.liveActive ? _liveIndicator() : _feed()),
                  if (!engine.liveActive) _frostedInput(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Connection trouble, stated once and quietly. Previously this was a
  /// full-width warning card in the centre of the assistant experience,
  /// which turned a transient network blip into the main event. It is now
  /// a compact pill: the assistant stays the focus, and the technical
  /// detail lives behind a tap (§5, §20).
  Widget _connectionBanner(AssistantEngine engine) => Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            onTap: () {
              engine.dismissError();
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const DiagnosticsScreen()));
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Neon.warning.withValues(alpha: 0.10),
                border:
                    Border.all(color: Neon.warning.withValues(alpha: 0.35)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off_rounded,
                      color: Neon.warning.withValues(alpha: 0.9), size: 14),
                  const SizedBox(width: 7),
                  Text(
                    engine.connected ? 'Connection issue' : 'Offline',
                    style: TextStyle(
                        fontSize: 12,
                        color: Neon.warning.withValues(alpha: 0.95)),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _announcement() => Padding(
        padding: const EdgeInsets.fromLTRB(Neon.s4, Neon.s2, Neon.s4, 0),
        child: GlassCard(
          tint: Neon.warning,
          child: Row(
            children: [
              const Icon(Icons.campaign_outlined,
                  color: Neon.warning, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(_config.announcement!)),
              GestureDetector(
                onTap: () => setState(() => _announcementDismissed = true),
                child: const Icon(Icons.close_rounded,
                    size: 18, color: Neon.textLo),
              ),
            ],
          ),
        ),
      );

  // Error banner — hidden for now. Re-enable in build() when needed.
  // Widget _errorBanner() {
  //   return Padding(
  //     padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
  //     child: Container(
  //       padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
  //       decoration: BoxDecoration(
  //         color: Neon.error.withValues(alpha: 0.14),
  //         borderRadius: BorderRadius.circular(14),
  //         border: Border.all(color: Neon.error.withValues(alpha: 0.45)),
  //       ),
  //       child: Row(
  //         children: [
  //           const Icon(Icons.error_outline_rounded,
  //               color: Neon.error, size: 18),
  //           const SizedBox(width: 8),
  //           Expanded(
  //             child: Text(engine.errorMessage!,
  //                 style: const TextStyle(color: Neon.textHi, fontSize: 13)),
  //           ),
  //           GestureDetector(
  //             onTap: engine.dismissError,
  //             child: const Icon(Icons.close_rounded,
  //                 size: 18, color: Neon.textLo),
  //           ),
  //         ],
  //       ),
  //     ),
  //   );
  // }

  /// Transcript + all dynamic action cards, in conversational order.
  /// Shown instead of the chat feed during a live conversation: voice is
  /// the whole interface, so the screen stays clean.
  Widget _liveIndicator() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: Neon.cyan.withValues(alpha: 0.10),
              border:
                  Border.all(color: Neon.cyan.withValues(alpha: 0.55)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: Neon.cyan),
                ),
                const SizedBox(width: 8),
                const Text('Live — just talk',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text('Tap the orb to end',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12.5)),
        ],
      ),
    );
  }

  Widget _feed() {
    final empty = engine.transcript.isEmpty &&
        engine.activities.isEmpty &&
        engine.pendingConfirmation == null;
    if (empty) return _emptyState();

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      children: [
        for (final t in engine.transcript) TranscriptBubble(entry: t),
        for (final a in engine.activities) ToolCard(activity: a),
        if (engine.searchResults.isNotEmpty) ...[
          _sectionLabel('Results for "${engine.searchQuery}"'),
          for (final r in engine.searchResults) SearchResultCard(result: r),
        ],
        if (engine.documentCards.isNotEmpty) ...[
          _sectionLabel(engine.documentCards.length == 1
              ? 'From your saved documents'
              : '${engine.documentCards.length} saved documents'),
          for (final d in engine.documentCards) DocumentCard(document: d),
        ],
        if (engine.ambiguousContacts.isNotEmpty) ...[
          _sectionLabel('Which one did you mean?'),
          for (final c in engine.ambiguousContacts)
            ContactCard(contact: c, onTap: () => engine.chooseContact(c)),
        ],
        if (engine.foundContact != null &&
            engine.pendingConfirmation == null &&
            engine.callStatus == null)
          ContactCard(contact: engine.foundContact!),
        if (engine.pendingConfirmation != null)
          ConfirmationCard(
            pending: engine.pendingConfirmation!,
            onDecision: engine.confirm,
          ),
        if (engine.callStatus != null)
          CallStatusCard(status: engine.callStatus!),
        if (engine.usedClonedVoice)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Message prepared in your enrolled voice',
              textAlign: TextAlign.center,
              style: TextStyle(color: Neon.textDim, fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Text(
          text,
          style: const TextStyle(
            color: Neon.textLo,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      );

  /// First-launch empty state — greeting + tappable quick-action chips.
  Widget _emptyState() {
    final name = AuthService.instance.user?.name;
    final actions = <(IconData, String, String)>[
      (Icons.waving_hand_rounded, 'Say hello', 'Hello'),
      (
        Icons.travel_explore_rounded,
        "Today's gold price",
        "Search for today's gold price"
      ),
      (
        Icons.phone_forwarded_rounded,
        'Call & inform someone',
        'Call Alan and inform him I will not be coming today'
      ),
      (Icons.wb_sunny_outlined, 'Plan my day', 'What should I focus on today?'),
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Neon.s7),
        // Device tilt gives the greeting + quick chips the same parallax
        // depth the orb and aurora already have. Sheen/shadow are off:
        // this is text and chips, not a glass card, so plain tilt reads
        // cleaner. Degrades to a static layout with no motion sensor.
        child: GyroTilt(
          maxTilt: 0.05,
          sheen: false,
          shadow: false,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
            GradientText(
              name == null ? 'Hi, I\'m Hari' : 'Hi $name',
              style: Theme.of(context).textTheme.headlineSmall!,
              gradient: Neon.gVioletPink,
            ),
            const SizedBox(height: Neon.s3),
            // Quiet, single-tone helper line — luxury UIs keep secondary
            // text neutral so the orb + greeting stay the only color heroes.
            Text(
              'Tap the face to meet Hari, hold the mic, or try one of these',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Neon.textDim,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: Neon.s6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Neon.s3,
              runSpacing: Neon.s3,
              children: [
                for (final (icon, label, prompt) in actions)
                  _PressScale(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      engine.sendText(prompt);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(Neon.rPill),
                        border: Border.all(color: Neon.line),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Monochrome icons: one accent family on screen at
                          // a time reads premium; four competing hues do not.
                          Icon(icon,
                              size: 15,
                              color: Neon.textLo.withValues(alpha: 0.9)),
                          const SizedBox(width: 8),
                          Text(label,
                              style: const TextStyle(
                                  color: Neon.textHi,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.1)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            ],
          ),
        ),
      ),
    );
  }

  /// Frosted wrapper around the mic + text input bar.
  Widget _frostedInput() {
    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Neon.bg.withValues(alpha: 0.35),
            border: Border(top: BorderSide(color: Neon.line)),
          ),
          child: BottomInputBar(
            phase: engine.phase,
            onMic: engine.pressMic,
            onSendText: engine.sendText,
          ),
        ),
      ),
    );
  }
}

/// Tactile press feedback — the micro-interaction that separates premium
/// from generic: the chip settles 4% smaller under the finger, then springs
/// back. Cheap UIs have no press state; luxury UIs always respond to touch.
class _PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  const _PressScale({required this.child, required this.onTap});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

