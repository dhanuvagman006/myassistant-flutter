import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:video_player/video_player.dart';

import '../../../services/voice_service.dart';
import '../state/assistant_state.dart';
import 'assistant_avatar.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  RealHumanFace — a REAL human face from plain video files. No D-ID,
///  no API keys, no network, no per-minute cost.
///
///  How: drop two short clips of a real person into assets/face/ —
///     idle.mp4     her listening face (subtle blinks, tiny movements)
///     talking.mp4  her talking naturally (any speech, audio ignored)
///  Both loop seamlessly; this widget crossfades to talking.mp4 the
///  moment the TTS starts a reply (VoiceService.isSpeaking) and back to
///  idle.mp4 when it ends — a living person who visibly speaks when the
///  assistant speaks. See assets/face/README.md for where to get clips.
///
///  Missing/broken assets → falls back to the painted AssistantAvatar
///  automatically, so the app NEVER shows a dead face.
/// ─────────────────────────────────────────────────────────────────────────
class RealHumanFace extends StatefulWidget {
  final AssistantPhase phase;
  final double micLevel;
  final String? userGender;
  final VoidCallback? onTap;

  const RealHumanFace({
    super.key,
    required this.phase,
    this.micLevel = 0,
    this.userGender,
    this.onTap,
  });

  @override
  State<RealHumanFace> createState() => _RealHumanFaceState();
}

class _RealHumanFaceState extends State<RealHumanFace> {
  VideoPlayerController? _idle;
  VideoPlayerController? _talking;
  bool _ready = false;
  bool _failed = false;
  bool _speaking = false;

  static const _idleAsset = 'assets/face/idle.mp4';
  static const _talkingAsset = 'assets/face/talking.mp4';

  @override
  void initState() {
    super.initState();
    _init();
    VoiceService.instance.isSpeaking.addListener(_onSpeakingChanged);
  }

  Future<void> _init() async {
    try {
      // Probe first: a clean "assets not added yet" is not an error —
      // the painted avatar simply keeps the stage.
      await rootBundle.load(_idleAsset);
      await rootBundle.load(_talkingAsset);

      _idle = VideoPlayerController.asset(_idleAsset);
      _talking = VideoPlayerController.asset(_talkingAsset);
      await Future.wait([_idle!.initialize(), _talking!.initialize()]);
      await Future.wait([
        _idle!.setLooping(true),
        _talking!.setLooping(true),
        _idle!.setVolume(0), // her VOICE is the TTS; clips stay silent
        _talking!.setVolume(0),
      ]);
      await _idle!.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onSpeakingChanged() {
    final s = VoiceService.instance.isSpeaking.value;
    if (s == _speaking || !_ready) return;
    _speaking = s;
    if (s) {
      _talking?.seekTo(Duration.zero);
      _talking?.play();
      _idle?.pause();
    } else {
      _idle?.play();
      _talking?.pause();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    VoiceService.instance.isSpeaking.removeListener(_onSpeakingChanged);
    _idle?.dispose();
    _talking?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No videos (or they failed) → the painted face carries on.
    if (_failed || !_ready) {
      return AssistantAvatar(
        phase: widget.phase,
        micLevel: widget.micLevel,
        userGender: widget.userGender,
        onTap: widget.onTap,
      );
    }

    final accent = switch (widget.phase) {
      AssistantPhase.listening => Colors.cyanAccent,
      AssistantPhase.error => Colors.redAccent,
      _ => const Color(0xFF9C6BFF),
    };

    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 210,
        height: 210,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 178,
              height: 178,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.35),
                    blurRadius: 44,
                    spreadRadius: 4,
                  ),
                ],
                border: Border.all(
                    color: accent.withValues(
                        alpha:
                            widget.phase == AssistantPhase.idle ? 0.3 : 0.75),
                    width: 2.5),
              ),
            ),
            ClipOval(
              child: SizedBox(
                width: 172,
                height: 172,
                // Crossfade between the two living loops.
                child: AnimatedCrossFade(
                  duration: const Duration(milliseconds: 220),
                  crossFadeState: _speaking
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: _cover(_idle!),
                  secondChild: _cover(_talking!),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Fills the circle regardless of the clip's aspect ratio.
  Widget _cover(VideoPlayerController c) => FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.size.width == 0 ? 172 : c.value.size.width,
          height: c.value.size.height == 0 ? 172 : c.value.size.height,
          child: VideoPlayer(c),
        ),
      );
}
