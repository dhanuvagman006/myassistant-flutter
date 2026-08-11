import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../models/remote_config.dart';
import '../../screens/face_screen.dart';
import '../../screens/interview_screen.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import 'state/assistant_engine.dart';
import 'state/assistant_state.dart';
import 'widgets/action_cards.dart';
import 'widgets/real_human_face.dart';
import '../../screens/diagnostics_screen.dart';
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

  /// Auto-open the REAL face (D-ID stream) once per app session when the
  /// backend has it configured — client spec: opening the app should meet
  /// the human face, not the drawn one. Static so navigating back doesn't
  /// re-open it in a loop.
  static bool _faceAutoOpened = false;

  Future<void> _openRealFace({bool auto = false}) async {
    try {
      // Probe first: fails fast (503) when Face Mode isn't configured,
      // so an unconfigured dev setup silently keeps the drawn avatar.
      await ApiService.startFaceSession();
      if (!mounted) return;
      final result = await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FaceScreen()),
      );
      // D-ID failed inside Face Mode and the user chose the fallback —
      // the animated built-in face on this screen takes over; reassure
      // them she still talks.
      if (result == 'use_builtin_face' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                "Using the built-in face — she'll animate as she speaks.")));
      }
    } on ProRequired {
      if (!auto && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Face Mode is a Pro feature.')));
      }
    } catch (_) {
      if (!auto && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Face Mode is unavailable — using the built-in face.')));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    engine.start();
    engine.addListener(_autoScroll);
    ApiService.refreshConfig().then((c) {
      if (mounted) setState(() => _config = c);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_faceAutoOpened && !AuthService.instance.lastSignInWasNew) {
        _faceAutoOpened = true;
        _openRealFace(auto: true);
      }
    });
    // First sign-in → offer the get-to-know-you interview in a sheet
    // (skippable). The single page stays underneath the whole time.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = AuthService.instance;
      if (auth.lastSignInWasNew && mounted) {
        auth.lastSignInWasNew = false;
        showGlassSheet(
          context,
          heightFactor: 0.92,
          child: InterviewScreen(
            onDone: () => Navigator.of(context).pop(),
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    engine.removeListener(_autoScroll);
    _scroll.dispose();
    super.dispose();
  }

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
                      child: RealHumanFace(
                        phase: engine.phase,
                        micLevel: engine.micLevel,
                        userGender: AuthService.instance.user?.gender,
                        onTap: () => _openRealFace(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  AssistantStatusPill(
                    phase: engine.phase,
                    connected: engine.connected,
                    onCancel: engine.cancelAction,
                  ),
                  const SizedBox(height: 8),
                  // Connection trouble is VISIBLE and tappable — the
                  // banner opens Diagnostics (server URL, /health test,
                  // live logs). Silence was the old "not even
                  // connecting" experience.
                  if (!engine.connected || engine.errorMessage != null)
                    _connectionBanner(engine),
                  Expanded(child: _feed()),
                  _frostedInput(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _connectionBanner(AssistantEngine engine) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: Neon.s4),
        child: GestureDetector(
          onTap: () {
            engine.dismissError();
            Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const DiagnosticsScreen()));
          },
          child: GlassCard(
            tint: Neon.warning,
            child: Row(
              children: [
                const Icon(Icons.wifi_off_rounded,
                    color: Neon.warning, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    engine.errorMessage ??
                        "Can't reach the server — tap to diagnose",
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded,
                    color: Neon.warning, size: 20),
              ],
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

