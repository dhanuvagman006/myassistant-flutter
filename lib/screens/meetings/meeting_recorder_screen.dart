import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../design/apple_kit.dart';
import '../../core/log.dart';
import '../../design/neon_tokens.dart';
import '../../features/assistant/state/assistant_engine.dart';
import '../../services/meetings_service.dart';
import '../../services/recording_guard.dart';
import 'meeting_detail_screen.dart';
import '../../services/app_feedback.dart';

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
  });

  /// Started by voice ("record this meeting") — begin straight away.
  final bool autoStart;
  final String title;
  final String participants;

  @override
  State<MeetingRecorderScreen> createState() => _MeetingRecorderScreenState();
}

enum _Stage { ready, recording, paused, uploading }

class _MeetingRecorderScreenState extends State<MeetingRecorderScreen> {
  static const _maxLength = Duration(hours: 3);
  static const _device = MethodChannel('hari/device');

  final _rec = AudioRecorder();
  late final _title = TextEditingController(text: widget.title);
  late final _people = TextEditingController(text: widget.participants);
  _Stage _stage = _Stage.ready;
  Duration _elapsed = Duration.zero;
  double _level = 0;
  Timer? _tick;
  StreamSubscription<Amplitude>? _amp;
  String? _path;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _amp?.cancel();
    _rec.dispose();
    _title.dispose();
    _people.dispose();
    _device.invokeMethod('keepScreenOn', {'on': false}).catchError((_) => null);
    RecordingGuard.release(this);
    super.dispose();
  }

  Future<void> _start() async {
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
      ),
      path: _path!,
    );
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
      await _rec.pause();
      setState(() {
        _stage = _Stage.paused;
        _level = 0;
      });
    } else {
      await _rec.resume();
      setState(() => _stage = _Stage.recording);
    }
  }

  Future<void> _stop() async {
    HapticFeedback.mediumImpact();
    _tick?.cancel();
    _amp?.cancel();
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
    final leave = await showDialog<bool>(
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
      child: Scaffold(
        backgroundColor: Neon.bg,
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
                    _Stage.paused => 'Paused',
                    _Stage.uploading => 'Uploading — the minutes follow in a few minutes.',
                  },
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Neon.textDim, fontSize: 13),
                ),
                const SizedBox(height: 26),
                _Meter(level: live ? _level : 0),
                const SizedBox(height: 30),
                if (busy)
                  CircularProgressIndicator(color: Neon.violet)
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_stage != _Stage.ready)
                        _round(
                          icon: _stage == _Stage.paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          color: Neon.surfaceHigh,
                          onTap: _pauseResume,
                          size: 60,
                        ),
                      if (_stage != _Stage.ready) const SizedBox(width: 28),
                      _round(
                        icon: _stage == _Stage.ready
                            ? Icons.fiber_manual_record_rounded
                            : Icons.stop_rounded,
                        color: const Color(0xFFE5484D),
                        onTap: _stage == _Stage.ready ? _start : _stop,
                        size: 84,
                      ),
                    ],
                  ),
                const SizedBox(height: 14),
                Text(
                  _stage == _Stage.ready ? 'Start' : busy ? '' : 'Stop for minutes',
                  style: TextStyle(color: Neon.textLo, fontSize: 13),
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
    return Container(
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Neon.line),
      ),
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
    required Color color,
    required VoidCallback onTap,
    required double size,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: size * 0.45),
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
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
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
