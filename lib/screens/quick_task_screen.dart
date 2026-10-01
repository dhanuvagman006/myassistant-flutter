import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../ai/listen.dart';
import '../ai/model_port.dart';
import '../core/log.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonLoader, NeonScaffold;
import '../services/api_service.dart';
import '../services/assistant_identity.dart';
import '../widgets/inline_voice.dart' show NightField;
import '../widgets/voice_orb.dart';
import '../design/motion.dart';

/// ─────────────────────────────────────────────────────────────────────
///  ASSIGN A TASK AND WALK AWAY.
///
///  His ask, 2026-09-21: a home-screen widget where "it's not like a
///  realtime communication — I will click on that mic orb and assign
///  tasks that the agent should properly analyse and do completely."
///
///  So this screen is deliberately NOT the conversation. There is no
///  live socket, no back-and-forth, no waiting for an answer. You say
///  or type one thing, it goes to the server, and the screen closes.
///  The work happens with the phone in a pocket and the result arrives
///  as a notification.
///
///  WHY THAT IS THE RIGHT SHAPE. A live session holds a microphone, a
///  WebSocket and the user's attention for as long as it runs — fine
///  when you are talking to it, wrong when you are walking out of the
///  door and want something done. The server already knows how to run a
///  turn nobody is watching (the same path a scheduled task uses), so
///  this hands work to that and gets out of the way.
/// ─────────────────────────────────────────────────────────────────────
class QuickTaskScreen extends StatefulWidget {
  const QuickTaskScreen({super.key});

  @override
  State<QuickTaskScreen> createState() => _QuickTaskScreenState();
}

enum _Stage { idle, listening, sending, sent, failed }

class _QuickTaskScreenState extends State<QuickTaskScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  // The phone's own recogniser (on-device first), with a cloud
  // transcription fallback — the same listener the conversation uses.
  // Made on the first tap of the mic, not with the screen.
  VoiceListener? _listener;
  VoiceListener get _voice => _listener ??= VoiceListener.standard(FirebaseModelPort());
  _Stage _stage = _Stage.idle;

  /// THE MIC LEVEL, READ BY THE ORB ON ITS OWN FRAMES (2026-09-24, GPU
  /// pass). Every reading used to setState the whole screen — the text
  /// box, the fonts, the orb and its backdrop, all rebuilt inside a
  /// LayoutBuilder several times a second while he spoke. The orb and its
  /// backdrop read the live value themselves, as they do on the voice
  /// screen; only a change of stage rebuilds this screen now.
  final ValueNotifier<double> _level = ValueNotifier<double>(0);
  bool _voiceReady = true;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    // The pill lights up while typing, as on the voice screen.
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _level.dispose();
    unawaited(_listener?.cancel().catchError((_) {}));
    super.dispose();
  }

  Future<void> _listen() async {
    if (_stage == _Stage.listening || !_voiceReady) return;
    setState(() => _stage = _Stage.listening);
    HapticFeedback.mediumImpact();
    try {
      var said = '';
      await for (final e in _voice.listen()) {
        if (!mounted) break;
        switch (e) {
          case HearPartial(:final text):
            _text.text = text;
            _text.selection = TextSelection.collapsed(offset: text.length);
          case HearLevel(:final level):
            _level.value = level;
          case HearFinal(:final text):
            said = text;
          case HearError(:final code, :final permanent):
            // No recogniser or no permission: typing still works, so the
            // screen stays useful either way.
            AppLog.add('quicktask', 'voice unavailable: $code');
            if (permanent && mounted) setState(() => _voiceReady = false);
          case HearEndOfSpeech():
            break;
        }
      }
      if (!mounted) return;
      if (said.trim().isNotEmpty) _text.text = said.trim();
      _level.value = 0;
      setState(() => _stage = _Stage.idle);
      // Speaking a task is a complete gesture — they said the thing and
      // expect it to go. Making them hunt for a send button afterwards
      // is the sort of extra tap that stops a widget being used at all.
      if (_text.text.trim().isNotEmpty) await _send();
    } catch (e) {
      AppLog.add('quicktask', 'capture failed: $e');
      if (mounted) setState(() => _stage = _Stage.idle);
    }
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty || _stage == _Stage.sending) return;
    setState(() => _stage = _Stage.sending);
    final ok = await ApiService.queueQuickTask(t);
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    setState(() => _stage = ok ? _Stage.sent : _Stage.failed);
    if (ok) {
      // Long enough to read the confirmation, short enough that it feels
      // like a button rather than a screen.
      await Future.delayed(const Duration(milliseconds: 1400));
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  String get _caption => switch (_stage) {
        _Stage.listening => 'Listening…',
        _Stage.sending => 'Handing it over…',
        _Stage.sent => "On it. I'll let you know when it's done.",
        _Stage.failed => "That didn't go through. Try again?",
        _Stage.idle => _voiceReady
            ? 'Tap the orb and say what you need'
            : 'Type what you need',
      };

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _Stage.sending || _stage == _Stage.sent;
    final canListen = !busy && _voiceReady && _stage != _Stage.listening;
    final canSend = _text.text.trim().isNotEmpty && !busy;
    // THE NIGHT SKY, NOT A BLACK PAGE (2026-09-30, the client's neon
    // direction): the same sky as Home under the orb, words in the tokens.
    return NeonScaffold(
      // The Scaffold already lifts the body above the keyboard. Adding the
      // keyboard's height again as padding squeezed the page to nothing on
      // the owner's phone — title, close button and text box all vanished
      // the moment the keyboard opened.
      body: SafeArea(
        child: LayoutBuilder(builder: (context, box) {
          // The orb gives up height first, so everything fits on a short
          // phone with the keyboard up.
          final orb = (box.maxHeight - 240).clamp(96.0, 260.0);
          // The disc, sized so its whole ring system fits the slot (the
          // rings are whole circles since 2026-09-25, never cut off).
          final disc = math.min(150.0, orb / VoiceOrbBackdrop.reach);
          return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Assign a task',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.spaceGrotesk(
                        color: Neon.textHi,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                    color: Neon.textLo,
                  ),
                ],
              ),
              const Spacer(flex: 3),
              // A button only when a tap starts listening; said as what
              // it does. (Tapping while listening, sending or with no
              // recogniser did nothing.)
              Semantics(
                button: canListen,
                label: canListen
                    ? 'Speak your task'
                    : _stage == _Stage.listening
                        ? 'Listening'
                        : null,
                // The orb gives under the finger when a tap will listen.
                child: PressScale(
                scale: canListen ? 0.97 : 1,
                child: GestureDetector(
                onTap: canListen ? _listen : null,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: orb,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: -24,
                        right: -24,
                        top: 0,
                        bottom: 0,
                        child: VoiceOrbBackdrop(
                          orbSize: disc,
                          mood: _stage == _Stage.listening
                              ? OrbMood.listening
                              : OrbMood.idle,
                          levelListenable: _level,
                        ),
                      ),
                      // The same still disc as the voice screen, name and
                      // all; only the rings round it move with his voice.
                      ValueListenableBuilder<String>(
                        valueListenable: AssistantIdentity.notifier,
                        builder: (_, name, __) =>
                            VoiceOrb(size: disc, label: orbLabelFor(name)),
                      ),
                    ],
                  ),
                ),
              ),
              ),
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                switchInCurve: Motion.easeEnter,
                switchOutCurve: Motion.easeFadeOut,
                duration: Motion.short,
                reverseDuration: Motion.out,
                child: Text(
                  _caption,
                  key: ValueKey(_caption),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    color: _stage == _Stage.failed
                        ? Neon.errorInk
                        : _stage == _Stage.sent
                            ? Neon.successInk
                            : Neon.textLo,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(flex: 4),
              // TYPED IS EQUAL, NOT A FALLBACK. Half the tasks worth
              // handing over are addresses, names and numbers that
              // dictation mangles.
              // The voice screen's own pill (NightField): the theme's
              // light fill drew a pale box with a faint hint here.
              AnimatedContainer(
                curve: Motion.easeMove,
                duration: Motion.micro,
                constraints: const BoxConstraints(minHeight: 54),
                decoration: NightField.pill(focused: _focus.hasFocus),
                padding: const EdgeInsets.fromLTRB(18, 3, 3, 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        enabled: !busy,
                        minLines: 1,
                        maxLines: 4,
                        // Single-line to the keyboard: its Send key sends.
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        keyboardAppearance: Brightness.dark,
                        cursorColor: Neon.violet,
                        style: NightField.input,
                        decoration: NightField.decoration(
                            'Book a cab at 6, or anything else…'),
                      ),
                    ),
                    const SizedBox(width: 5),
                    // 48 dp to the finger, 42 dp to the eye — and named.
                    // THE PAGE'S ONE PRIMARY ACTION GLOWS (2026-09-30): lit
                    // in the brand gradient with its halo once there is
                    // something to send; a quiet ring while it goes.
                    Semantics(
                      button: true,
                      enabled: canSend,
                      label: 'Send',
                      child: AnimatedOpacity(
                        curve: Motion.easeMove,
                        duration: Motion.micro,
                        opacity: canSend || busy ? 1 : 0.35,
                        child: PressScale(
                          // Dips only when a tap will send.
                          scale: canSend ? 0.92 : 1,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: canSend ? _send : null,
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Center(
                                child: AnimatedContainer(
                                  duration: Motion.micro,
                                  curve: Motion.easeMove,
                                  width: 42,
                                  height: 42,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: _stage == _Stage.sending
                                        ? null
                                        : Neon.gBrand,
                                    color: _stage == _Stage.sending
                                        ? Neon.surfaceHigh
                                        : null,
                                    boxShadow: canSend || _stage == _Stage.sent
                                        ? Neon.halo(Neon.violet)
                                        : null,
                                  ),
                                  child: _stage == _Stage.sending
                                      ? const Center(
                                          child: NeonLoader.inline(
                                              size: 22,
                                              semanticLabel: 'Sending'))
                                      : Icon(
                                          _stage == _Stage.sent
                                              ? Icons.check_rounded
                                              : Icons.arrow_upward_rounded,
                                          color: Neon.onBrand,
                                          size: 21,
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          );
        }),
      ),
    );
  }
}
