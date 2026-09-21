import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/log.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/voice_service.dart';
import '../widgets/voice_orb.dart';

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
  // The app's one recogniser — a second instance would fight the
  // conversation screen for the microphone.
  final _voice = VoiceService.instance;
  _Stage _stage = _Stage.idle;
  double _level = 0;
  bool _voiceReady = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    unawaited(_warmVoice());
  }

  Future<void> _warmVoice() async {
    try {
      final ok = await _voice.init();
      if (mounted) setState(() => _voiceReady = ok);
    } catch (e) {
      // No recogniser on this phone, or permission refused: typing still
      // works, so the screen is useful either way.
      AppLog.add('quicktask', 'voice unavailable: $e');
    }
  }

  @override
  void dispose() {
    _text.dispose();
    unawaited(_voice.stopWatching().catchError((_) {}));
    super.dispose();
  }

  Future<void> _listen() async {
    if (_stage == _Stage.listening || !_voiceReady) return;
    setState(() => _stage = _Stage.listening);
    HapticFeedback.mediumImpact();
    try {
      final said = await _voice.captureQuestion(
        onPartial: (p) {
          if (!mounted) return;
          _text.text = p;
          _text.selection = TextSelection.collapsed(offset: p.length);
        },
        onLevel: (l) {
          if (mounted) setState(() => _level = l);
        },
      );
      if (!mounted) return;
      if (said.trim().isNotEmpty) _text.text = said.trim();
      setState(() {
        _stage = _Stage.idle;
        _level = 0;
      });
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
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              24, 8, 24, 18 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    'Assign a task',
                    style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ],
              ),
              const Spacer(flex: 3),
              GestureDetector(
                onTap: busy ? null : _listen,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  height: 260,
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
                          orbSize: 150,
                          mood: _stage == _Stage.listening
                              ? OrbMood.listening
                              : OrbMood.idle,
                          level: _level,
                        ),
                      ),
                      VoiceOrb(
                        size: 150,
                        mood: _stage == _Stage.listening
                            ? OrbMood.listening
                            : OrbMood.idle,
                        level: _level,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(
                  _caption,
                  key: ValueKey(_caption),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    color: _stage == _Stage.failed
                        ? Neon.error
                        : Colors.white.withValues(alpha: 0.66),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(flex: 4),
              // TYPED IS EQUAL, NOT A FALLBACK. Half the tasks worth
              // handing over are addresses, names and numbers that
              // dictation mangles.
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(26),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                padding: const EdgeInsets.fromLTRB(18, 2, 6, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _text,
                        enabled: !busy,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        keyboardAppearance: Brightness.dark,
                        cursorColor: Neon.violet,
                        style: GoogleFonts.spaceGrotesk(
                          color: Colors.white,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Book a cab at 6, or anything else…',
                          hintStyle: GoogleFonts.spaceGrotesk(
                            color: Colors.white.withValues(alpha: 0.30),
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 13),
                        ),
                      ),
                    ),
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      opacity: _text.text.trim().isEmpty || busy ? 0.35 : 1,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _text.text.trim().isEmpty || busy ? null : _send,
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: Neon.gBrand,
                          ),
                          child: _stage == _Stage.sending
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : Icon(
                                  _stage == _Stage.sent
                                      ? Icons.check_rounded
                                      : Icons.arrow_upward_rounded,
                                  color: Colors.white,
                                  size: 21,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
