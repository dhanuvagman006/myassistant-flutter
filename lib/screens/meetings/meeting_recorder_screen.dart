import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../design/apple_kit.dart';
import '../../core/log.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart' show NeonLoader, NeonScaffold;
import '../../features/assistant/state/assistant_engine.dart';
import '../../services/meetings_service.dart';
import '../../services/phone_state_guard.dart';
import '../../services/recording_guard.dart';
import 'meeting_detail_screen.dart';
import '../../services/app_feedback.dart';
import '../../design/motion.dart';
import '../../widgets/neon_cards.dart';

/// MEETING RECORDER. Owner's pick, 2026-09-23 ("Meeting recorder →
/// minutes"). Records the room — compact AAC, about 15 MB an hour — and
/// hands the whole recording to the server, which writes the minutes.
///
/// The screen stays on while recording: a locked screen puts the app in
/// the background, where Android stops its microphone.
class MeetingRecorderScreen extends StatefulWidget {
  const MeetingRecorderScreen({
    super.key,
    this.autoStart = false,
    this.title = '',
    this.participants = '',
    this.recorder,
    this.callConnected,
  });

  /// Started by voice ("record this meeting") — begin straight away.
  final bool autoStart;
  final String title;
  final String participants;

  /// Tests hand in a fake recorder and their own call signal.
  @visibleForTesting
  final AudioRecorder Function()? recorder;
  @visibleForTesting
  final ValueListenable<bool>? callConnected;

  @override
  State<MeetingRecorderScreen> createState() => _MeetingRecorderScreenState();
}

enum _Stage { ready, recording, paused, uploading }

class _MeetingRecorderScreenState extends State<MeetingRecorderScreen> {
  static const _maxLength = Duration(hours: 3);
  static const _device = MethodChannel('hari/device');

  late final AudioRecorder _rec;
  late final ValueListenable<bool> _call;
  late final _title = TextEditingController(text: widget.title);
  late final _people = TextEditingController(text: widget.participants);
  _Stage _stage = _Stage.ready;
  Duration _elapsed = Duration.zero;
  double _level = 0;
  Timer? _tick;
  StreamSubscription<Amplitude>? _amp;
  StreamSubscription<RecordState>? _state;
  String? _path;

  /// Why it is paused when the owner did not pause it; said on the screen.
  String? _pausedBecause;

  static const _duringCall =
      'Finish the call first — the phone keeps the microphone for it.';

  @override
  void initState() {
    super.initState();
    _rec = (widget.recorder ?? AudioRecorder.new)();
    _call = widget.callConnected ?? PhoneStateGuard.instance.callConnected;
    _call.addListener(_onCall);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _call.removeListener(_onCall);
    _tick?.cancel();
    _amp?.cancel();
    _state?.cancel();
    _rec.dispose();
    _title.dispose();
    _people.dispose();
    _device.invokeMethod('keepScreenOn', {'on': false}).catchError((_) => null);
    RecordingGuard.release(this);
    super.dispose();
  }

  Future<void> _start() async {
    if (_call.value) {
      _snack(_duringCall);
      return;
    }
    // A live voice session holds the microphone — it has to let go first.
    final engine = AssistantEngine.instance;
    if (engine.liveActive || engine.inlineVoice) {
      await engine.endInlineConversation();
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (!await _rec.hasPermission()) {
      _snack('Microphone permission is needed to record.');
      return;
    }
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/meeting_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 32000,
        // A room, not a phone held to the mouth: let the platform level it.
        autoGain: true,
        noiseSuppress: true,
        // record's default PAUSES on any audio-focus loss — a WhatsApp
        // ping, a notification — and never resumes, while this screen went
        // on saying "Recording" (2026-09-30). Nothing but the owner pauses
        // a meeting; a call is handled below, from PhoneStateGuard.
        audioInterruption: AudioInterruptionMode.none,
      ),
      path: _path!,
    );
    _state = _rec.onStateChanged().listen(_onRecorderState);
    HapticFeedback.mediumImpact();
    _device.invokeMethod('keepScreenOn', {'on': true}).catchError((_) => null);
    // A video note arriving now waits: its popup would cover this screen
    // and its sound would be in the recording (2026-09-26).
    RecordingGuard.hold(this);
    _amp = _rec
        .onAmplitudeChanged(const Duration(milliseconds: 160))
        .listen((a) {
      // dBFS −60..0 → 0..1 for the meter.
      final v = ((a.current + 60) / 60).clamp(0.0, 1.0);
      if (mounted) setState(() => _level = v);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_stage != _Stage.recording) return;
      setState(() => _elapsed += const Duration(seconds: 1));
      if (_elapsed >= _maxLength) _stop();
    });
    setState(() => _stage = _Stage.recording);
  }

  Future<void> _pauseResume() async {
    HapticFeedback.selectionClick();
    if (_stage == _Stage.recording) {
      await _pause();
    } else {
      if (_call.value) {
        _snack(_duringCall);
        return;
      }
      setState(() {
        _stage = _Stage.recording;
        _pausedBecause = null;
      });
      await _rec.resume();
    }
  }

  /// Paused by the owner ([because] null) or for a reason said on the
  /// screen. The stage changes first, so the recorder's own "paused" event
  /// that follows finds it paused already.
  Future<void> _pause([String? because]) async {
    setState(() {
      _stage = _Stage.paused;
      _level = 0;
      _pausedBecause = because;
    });
    await _rec.pause();
  }

  /// A pause nobody asked for (the platform took the microphone) shows as
  /// Paused with Resume — never "Recording" over a microphone that stopped.
  void _onRecorderState(RecordState s) {
    if (s != RecordState.pause || _stage != _Stage.recording || !mounted) return;
    AppLog.add('meeting', 'recorder paused by the platform');
    setState(() {
      _stage = _Stage.paused;
      _level = 0;
      _pausedBecause = 'The microphone was interrupted — tap Resume to carry on.';
    });
  }

  /// A CONNECTED call pauses the meeting (a ringing one does not: a declined
  /// call should cost nothing). It never resumes by itself: when the call
  /// ends the app may still be behind the call screen, where Android gives a
  /// background app silence — and the owner may not be back in the room.
  void _onCall() {
    if (!_call.value || _stage != _Stage.recording || !mounted) return;
    AppLog.add('meeting', 'paused for a phone call');
    _pause('Paused for your call — tap Resume when you’re back.');
  }

  Future<void> _stop() async {
    HapticFeedback.mediumImpact();
    _tick?.cancel();
    _amp?.cancel();
    await _state?.cancel();
    _state = null;
    _pausedBecause = null;
    final path = await _rec.stop() ?? _path;
    _device.invokeMethod('keepScreenOn', {'on': false}).catchError((_) => null);
    RecordingGuard.release(this);
    if (path == null) return;
    if (_elapsed.inSeconds < 10) {
      _snack('That was too short to make minutes from.');
      setState(() {
        _stage = _Stage.ready;
        _elapsed = Duration.zero;
      });
      return;
    }
    setState(() => _stage = _Stage.uploading);
    try {
      final id = await MeetingsService.upload(
        path,
        title: _title.text,
        participants: _people.text,
        durationS: _elapsed.inSeconds,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => MeetingDetailScreen(id: id)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _stage = _Stage.ready);
      // The raw error goes to the log; the user gets a sentence.
      AppLog.add('meeting', 'upload failed: $e');
      _snack("Couldn't upload the recording — check your connection. "
          'The recording is kept; try Stop again.');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    AppFeedback.show(text, context: context);
  }

  String get _clock {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<bool> _confirmLeave() async {
    if (_stage != _Stage.recording && _stage != _Stage.paused) return true;
    final leave = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text('Tap Stop instead to get the minutes.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep recording')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    if (leave == true) await _rec.cancel();
    return leave == true;
  }

  @override
  Widget build(BuildContext context) {
    final live = _stage == _Stage.recording;
    final busy = _stage == _Stage.uploading;
    return PopScope(
      canPop: _stage == _Stage.ready,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) Navigator.of(context).pop();
      },
      // Under the night sky (2026-09-30).
      child: NeonScaffold(
        appBar: appleAppBar(context, 'Record a meeting'),
        body: SafeArea(
          // Full height when there is room (the Spacer puts the button at
          // the bottom); scrolls while the keyboard is up instead of
          // pushing the record button off the screen.
          child: LayoutBuilder(builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: IntrinsicHeight(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              children: [
                _field(_title, 'What is the meeting? (optional)', Icons.title_rounded,
                    enabled: !busy),
                const SizedBox(height: 10),
                _field(_people, 'Who is in it? (optional)', Icons.groups_rounded,
                    enabled: !busy),
                const Spacer(),
                Text(_clock,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 48,
                        fontWeight: FontWeight.w300,
                        fontFeatures: const [FontFeature.tabularFigures()])),
                const SizedBox(height: 8),
                Text(
                  switch (_stage) {
                    _Stage.ready => 'Put the phone in the middle of the table.',
                    _Stage.recording => 'Recording — keep this screen open.',
                    _Stage.paused => _pausedBecause ?? 'Paused',
                    _Stage.uploading => 'Uploading — the minutes follow in a few minutes.',
                  },
                  textAlign: TextAlign.center,
                  // On air says so in the danger tone's words.
                  // A pause the owner did not make is a warning, not a whisper.
                  style: TextStyle(
                      color: live
                          ? Neon.errorInk
                          : _pausedBecause != null
                              ? Neon.warningInk
                              : Neon.textDim,
                      fontSize: NeonType.footnote),
                ),
                const SizedBox(height: 26),
                _Meter(level: live ? _level : 0),
                const SizedBox(height: 30),
                if (busy)
                  const NeonLoader(semanticLabel: 'Uploading')
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_stage != _Stage.ready)
                        _round(
                          icon: _stage == _Stage.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          label: _stage == _Stage.paused
                              ? 'Resume recording'
                              : 'Pause recording',
                          color: Neon.surfaceHigh,
                          onTap: _pauseResume,
                          size: 60,
                        ),
                      if (_stage != _Stage.ready) const SizedBox(width: 28),
                      _RecordButton(
                        icon: _stage == _Stage.ready
                            ? Icons.fiber_manual_record_rounded
                            : Icons.stop_rounded,
                        label: _stage == _Stage.ready
                            ? 'Start recording'
                            : 'Stop recording',
                        onTap: _stage == _Stage.ready ? _start : _stop,
                        pulsing: live,
                      ),
                    ],
                  ),
                const SizedBox(height: 14),
                Text(
                  _stage == _Stage.ready ? 'Start' : busy ? '' : 'Stop for minutes',
                  style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote),
                ),
              ],
            ),
          ),
          ),
          ),
          )),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon,
      {bool enabled = true}) {
    return RimCard(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Icon(icon, size: 18, color: Neon.textDim),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: c,
            enabled: enabled,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(color: Neon.textHi, fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: Neon.textDim, fontSize: 14),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
            ),
          ),
        ),
      ]),
    );
  }

  Widget _round({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    required double size,
  }) {
    // Said by a screen reader (it was a bare circle), and the glyph in
    // whichever ink reads on the fill: white on the light theme's pale
    // pause button was about 1.1:1.
    // The secondary control: a lit rim, no glow (2026-09-30).
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PressScale(
        scale: 0.94,
        child: Material(
          color: color,
          shape: CircleBorder(side: BorderSide(color: Neon.lineBright, width: 1.2)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, color: Neon.glyphOn(color), size: size * 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

/// THE RECORD BUTTON, LIT RED (2026-09-30, the client's neon direction):
/// the danger tone's gradient disc with its halo. While the room is being
/// recorded the halo breathes, slowly — the one moving light on the page
/// says "this is on". Ready, paused, or with Remove animations on, it
/// holds still. The halo is drawn once on its own layer; only its opacity
/// moves, so the breathing costs the compositor, not a repaint.
class _RecordButton extends StatefulWidget {
  const _RecordButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.pulsing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool pulsing;

  static const double size = 84;

  @override
  State<_RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<_RecordButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1600));
  late final Animation<double> _glow = _breath.drive(
      Tween<double>(begin: 0.35, end: 1).chain(CurveTween(curve: Curves.easeInOut)));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_RecordButton old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.pulsing && !Motion.reduced(context);
    if (run && !_breath.isAnimating) {
      _breath.repeat(reverse: true);
    } else if (!run && _breath.isAnimating) {
      _breath.stop();
      _breath.value = 1;
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const s = _RecordButton.size;
    final rim = NeonTone.danger.rim;
    final halo = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: Neon.halo(rim.first, strength: 1.3),
        ),
        child: const SizedBox.square(dimension: s),
      ),
    );
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      child: PressScale(
        scale: 0.94,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Stack(
            alignment: Alignment.center,
            children: [
              widget.pulsing && !Motion.reduced(context)
                  ? FadeTransition(opacity: _glow, child: halo)
                  : Opacity(opacity: 0.6, child: halo),
              Container(
                width: s,
                height: s,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: rim,
                  ),
                ),
                child: Icon(widget.icon,
                    color: Neon.glyphOn(rim.first), size: s * 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Twelve bars that follow the room's loudness.
class _Meter extends StatelessWidget {
  const _Meter({required this.level});
  final double level;

  @override
  Widget build(BuildContext context) {
    const n = 12;
    return SizedBox(
      height: 48,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < n; i++)
            AnimatedContainer(curve: Motion.easeMove, 
              duration: Motion.micro,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 6,
              height: 6 + 42 * level * (0.55 + 0.45 * ((i * 7) % 5) / 4),
              decoration: BoxDecoration(
                color: Color.lerp(Neon.violet, Neon.pink, i / n)!
                    .withValues(alpha: level > 0 ? 0.95 : 0.3),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}
