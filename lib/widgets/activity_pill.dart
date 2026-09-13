import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';

/// WHAT THE USER SEES WHILE A TOOL IS RUNNING.
///
/// The engine has always known which tool was running — `activityLabel` is
/// set on every tool_started and cleared on tool_completed — but nothing
/// ever rendered it, so a four-second web search was indistinguishable
/// from a frozen app. Searching is now the DEFAULT for anything that could
/// have changed rather than a last resort, so those seconds happen far
/// more often and had to become visible.
///
/// Deliberately a small pill rather than a blocking spinner: the work is
/// happening on the user's behalf, not in their way, and a modal overlay
/// would make a two-second lookup feel heavier than it is.
class AssistantActivityPill extends StatefulWidget {
  const AssistantActivityPill({super.key});

  @override
  State<AssistantActivityPill> createState() => _AssistantActivityPillState();
}

class _AssistantActivityPillState extends State<AssistantActivityPill>
    with SingleTickerProviderStateMixin {
  final engine = AssistantEngine.instance;
  // NOT started here. A controller left repeating drives a 60 fps repaint
  // for the whole life of the shell, and this pill is hidden for nearly
  // all of it — the animation runs only while there is something to say.
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  String? _label;
  DateTime? _since;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    engine.activityLabel.addListener(_onLabel);
    // The shell can be rebuilt mid-turn — a theme flip remounts the whole
    // tree — with a tool already running, and the listener alone would
    // never fire for a label that is ALREADY set.
    _adopt(engine.activityLabel.value);
  }


  @override
  void dispose() {
    engine.activityLabel.removeListener(_onLabel);
    _tick?.cancel();
    _spin.dispose();
    super.dispose();
  }

  void _onLabel() {
    if (!mounted) return;
    setState(() => _adopt(engine.activityLabel.value));
  }

  /// Take on whatever the engine reports, from BOTH entry points, so the
  /// two can never drift apart — they did, and the initState path was the
  /// one missing the stale cut-off.
  void _adopt(String? next) {
    // Reset the clock on any change of label, AND when it has already
    // expired. The engine sets activityLabel on every tool_started but
    // clears it only once every activity has completed, so two overlapping
    // tools hand over A -> B with no null between; keying off "was null"
    // left the clock running from A, and a tool that had just started
    // announced itself as "Still ..." from its first frame.
    //
    // The expiry half matters more. If a tool_completed is ever dropped
    // the label sticks, the pill hides itself at _staleAfter — and the
    // next search sets the very same string, so without this there is no
    // change to detect, no reset, and the pill never appears again for
    // the rest of the session.
    if (next != _label || (next != null && _elapsed >= _staleAfter)) {
      _since = next == null ? null : DateTime.now();
    }
    _label = next;
    _tick?.cancel();
    if (next == null) {
      _spin.stop();
      return;
    }
    if (!_spin.isAnimating) _spin.repeat();
    // A LONG LOOKUP HAS TO KEEP SAYING SOMETHING. A label frozen at
    // "Searching…" for eight seconds reads as a hang just like no label
    // at all, so the wording changes as the seconds pass.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      // Past the cut-off the pill is hidden anyway; a 1 Hz rebuild and a
      // 60 fps repaint behind it cost battery for nothing.
      if (_elapsed >= _staleAfter) {
        _tick?.cancel();
        _spin.stop();
      }
    });
  }

  /// The label, with its trailing ellipsis removed — the animated dots
  /// take its place so the wait is visibly moving, not typographic.
  String get _text {
    final raw = (_label ?? '').replaceAll(RegExp(r'[.\u2026]+$'), '').trim();
    if (raw.isEmpty) return '';
    // "Almost there" would be a promise this cannot keep — it has no idea
    // how far along the tool is. Saying it is STILL working is true, and
    // is the thing the user actually needs to know.
    if (_elapsed >= 12) {
      return 'Still ${raw[0].toLowerCase()}${raw.substring(1)}';
    }
    if (_elapsed >= 6) return '$raw \u2014 one moment';
    return raw;
  }

  int get _elapsed =>
      _since == null ? 0 : DateTime.now().difference(_since!).inSeconds;

  /// A pill that never goes away is worse than no pill: it says the app is
  /// stuck even once the turn has moved on. Nothing server-side runs
  /// longer than the 120 s task budget, so past that the label is stale by
  /// definition — a dropped tool_completed, not work still in flight.
  static const _staleAfter = 150;

  bool get _isSearch {
    final l = (_label ?? '').toLowerCase();
    return l.contains('search') || l.contains('looking');
  }

  @override
  Widget build(BuildContext context) {
    final show =
        _label != null && _label!.isNotEmpty && _elapsed < _staleAfter;
    return IgnorePointer(
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        offset: show ? Offset.zero : const Offset(0, 0.6),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: show ? 1 : 0,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: Neon.line),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: Neon.isDark ? 0.5 : 0.1),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: AnimatedBuilder(
                    animation: _spin,
                    builder: (_, __) => CustomPaint(
                      painter: _SweepPainter(
                        t: _spin.value,
                        color: Neon.violet,
                        track: Neon.line,
                      ),
                      child: Center(
                        child: Icon(
                          _isSearch
                              ? Icons.search_rounded
                              : Icons.auto_awesome_rounded,
                          size: 10,
                          color: Neon.violet,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 11),
                Flexible(
                  child: Text(
                    _text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                AnimatedBuilder(
                  animation: _spin,
                  builder: (_, __) => _Dots(t: _spin.value, color: Neon.textLo),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The ring: a short arc travelling round a faint track. Read at a glance
/// as "running", and cheap enough to repeat indefinitely.
class _SweepPainter extends CustomPainter {
  final double t;
  final Color color;
  final Color track;
  const _SweepPainter({required this.t, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(1.4);
    canvas.drawArc(
      r, 0, math.pi * 2, false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );
    canvas.drawArc(
      r, t * math.pi * 2, math.pi * 0.62, false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SweepPainter o) => o.t != t || o.color != color;
}

/// Three dots rising in sequence — the moving ellipsis the label gave up.
class _Dots extends StatelessWidget {
  final double t;
  final Color color;
  const _Dots({required this.t, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        // Each dot runs the same cycle a third of a beat behind the last.
        final phase = (t + i * 0.18) % 1.0;
        final lift = math.sin(phase * math.pi * 2).clamp(-1.0, 1.0);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.4),
          child: Transform.translate(
            offset: Offset(0, -lift * 1.8),
            child: Container(
              width: 3.4,
              height: 3.4,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.45 + 0.55 * ((lift + 1) / 2)),
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      }),
    );
  }
}
