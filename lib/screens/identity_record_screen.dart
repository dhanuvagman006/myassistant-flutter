import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import '../core/log.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../widgets/glow_cta.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../services/app_feedback.dart';
import '../services/avatar_message_service.dart';
import '../services/recording_guard.dart';
import '../widgets/teleprompter.dart';

/// Which script a video was read from. Sent with the upload, so a later
/// script (from the server, in another language) can tell them apart.
const int identityScriptVersion = 1;

/// THE IDENTITY SCRIPT, one teleprompter line per row. One const on
/// purpose: it can come from the server later without the screen changing.
///
/// It opens with the consent sentence, said on camera in the user's own
/// voice. The rest is for the lip-sync and voice models: plain everyday
/// speech with numbers, a question, and every vowel in it. 72 words —
/// about 30 seconds at 2.4 words a second, with a breath at each stop.
const String identityScript = '''I'm recording this
so my assistant can make
video messages in my voice,
only when I ask.
Hello there!
It's a bright, breezy morning
and I'm feeling really good.
Could we meet on Thursday
at half past four,
or maybe at five fifteen,
near the old blue bridge?
I'll bring the three books,
some fresh juice
and my umbrella, just in case.
Thank you so much.
See you soon, and take care!''';

/// How long an identity video may be, and how it is encoded.
abstract final class IdentityRecordRules {
  /// Under this there is too little face and voice to learn from; the
  /// script alone takes about 30 s.
  static const Duration minLength = Duration(seconds: 20);

  /// It stops by itself here. 40 s cut off a slower reader mid-script
  /// (review, 2026-09-26); a minute leaves room for the slower pace and a
  /// stumble, and stays well inside the 90 s the server takes.
  static const Duration maxLength = Duration(seconds: 60);

  static bool canSave(Duration length) => length >= minLength;
  static bool mustStop(Duration elapsed) => elapsed >= maxLength;

  /// Without a bitrate the phone uses its camcorder default, often 10–14
  /// Mbps at 720p: 40–60 MB a take, which a slow uplink could not send.
  /// 2.5 Mbps is plenty for a face filling the frame — a minute stays
  /// under 20 MB.
  static const int videoBitrate = 2500000;
  static const int audioBitrate = 128000;

  static const String tooShort =
      'That was under 20 seconds — too short to make video notes from. '
      'Read the whole script; it takes about 30.';
}

/// How fast the words move: a slower reader picks Slower instead of
/// falling behind a fixed clock (review, 2026-09-26).
enum ReadingPace {
  slower('Slower', 0.8),
  normal('Normal', 1.0),
  faster('Faster', 1.2);

  const ReadingPace(this.label, this.factor);
  final String label;
  final double factor;
}

enum RecordStage { preparing, blocked, ready, countdown, recording, review, uploading }

/// Why the camera cannot be used.
enum _Block { permission, permissionInSettings, noFrontCamera, camera }

/// RECORD YOUR VIDEO (owner, 2026-09-26: "one record icon he should click
/// and read that text, that text should go like a lyric… once he completes
/// that he should click on save button, that should be saved on my
/// backend").
///
/// Front camera, full screen. The words scroll in a band just under the
/// camera, as on a real teleprompter: read halfway down the screen, the
/// eyes looked down in the whole video — and in every note made from it.
/// The middle of the picture, the face, stays clear. Only a live recording
/// from this screen: there is no gallery and no back camera, so nobody can
/// make a likeness of someone else from a clip they happen to have.
/// Leaving the app mid-take throws the take away.
class IdentityRecordScreen extends StatefulWidget {
  const IdentityRecordScreen({
    super.key,
    this.script = identityScript,
    this.scriptVersion = identityScriptVersion,
  });

  final String script;
  final int scriptVersion;

  /// Back to the normal pace (tests: the pace picked is kept for the run).
  @visibleForTesting
  static void resetPace() =>
      _IdentityRecordScreenState._pace = ReadingPace.normal;

  @override
  State<IdentityRecordScreen> createState() => _IdentityRecordScreenState();
}

class _IdentityRecordScreenState extends State<IdentityRecordScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _device = MethodChannel('hari/device');

  /// Kept for the rest of the app run: a Retake, or coming back later,
  /// reads at the pace the user picked.
  static ReadingPace _pace = ReadingPace.normal;

  late TeleprompterTimeline _timeline = _timelineAt(_pace);

  /// Time into the take. The teleprompter, the timer and the progress bar
  /// all read it; only the ticker below writes it, and only while recording.
  final _elapsed = ValueNotifier<Duration>(Duration.zero);
  final _seconds = ValueNotifier<int>(0);
  final _done = ValueNotifier<bool>(false);
  final _sent = ValueNotifier<double>(0);
  late final Ticker _clock;

  CameraController? _camera;
  VideoPlayerController? _player;
  RecordStage _stage = RecordStage.preparing;
  _Block _block = _Block.camera;
  int _count = 3;
  Timer? _countdown;
  XFile? _take;
  Duration _takeLength = Duration.zero;
  String? _notice;
  String? _uploadError;
  bool _preparing = false;
  bool _stopping = false;

  /// A permission prompt is up. On some phones it stops the app, which
  /// must not be taken for the user leaving.
  bool _asking = false;

  /// The app really went to the background (hidden / paused) and has not
  /// come back yet. Only then does `resumed` open the camera again: a
  /// permission prompt only makes the app INACTIVE, and its answer lands
  /// BEFORE the `resumed` that follows — acting on every `resumed` asked
  /// again the moment "Don't allow" was tapped, round and round, until
  /// Android made the refusal permanent (review, 2026-09-26).
  bool _wentAway = false;

  /// The last camera being given up. A new one waits for it: the Android
  /// plugin's release acts on whatever camera is current, so an old one
  /// finishing late tore down the new preview (a quick Home and back).
  Future<void> _releasing = Future.value();

  TeleprompterTimeline _timelineAt(ReadingPace p) => TeleprompterTimeline(
      widget.script.split('\n'),
      wordsPerSecond: TeleprompterTimeline.defaultWordsPerSecond * p.factor);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = createTicker(_onTick);
    // A video note waits while this screen is open: its popup would cover
    // the camera, and its sound would be in the take the voice is made
    // from (2026-09-26).
    RecordingGuard.hold(this);
    // A take left behind when the app was closed mid-review.
    unawaited(AvatarMessageService.sweepTemporary(
        takesOnly: true, before: DateTime.now()));
    _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RecordingGuard.release(this);
    _countdown?.cancel();
    _clock.dispose();
    _screenOn(false);
    _letGoOfCamera();
    _closePlayer();
    _deleteTake();
    _elapsed.dispose();
    _seconds.dispose();
    _done.dispose();
    _sent.dispose();
    super.dispose();
  }

  /* ------------------------------ camera ------------------------------ */

  Future<void> _prepare() async {
    if (_preparing) return;
    _preparing = true;
    if (mounted) setState(() => _stage = RecordStage.preparing);
    try {
      // The live session holds the microphone, and it would hear the
      // script and answer it. Closed first, as the meeting recorder does.
      final engine = AssistantEngine.instance;
      if (engine.liveActive || engine.inlineVoice) {
        await engine.endInlineConversation();
        await Future.delayed(const Duration(milliseconds: 600));
      }
      await _releasing;
      if (!await _permissionsGranted()) return;
      final List<CameraDescription> cams;
      try {
        cams = await availableCameras();
      } catch (e) {
        _blocked(_Block.camera, e);
        return;
      }
      final front = cams
          .where((c) => c.lensDirection == CameraLensDirection.front)
          .firstOrNull;
      if (front == null) {
        _blocked(_Block.noFrontCamera);
        return;
      }
      // 720p with sound: plenty for lip-sync and voice.
      final c = CameraController(
        front,
        ResolutionPreset.high,
        enableAudio: true,
        videoBitrate: IdentityRecordRules.videoBitrate,
        audioBitrate: IdentityRecordRules.audioBitrate,
      );
      try {
        await c.initialize();
        try {
          await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
        } catch (_) {}
        await c.prepareForVideoRecording();
      } catch (e) {
        await c.dispose().catchError((_) {});
        final denied = e is CameraException && e.code.contains('AccessDenied');
        _blocked(denied ? _Block.permissionInSettings : _Block.camera, e);
        return;
      }
      // Gone, or sent to the background while the camera was starting:
      // it is given up again, and opened on the way back.
      if (!mounted || _wentAway) {
        await c.dispose().catchError((_) {});
        return;
      }
      setState(() {
        _camera = c;
        _stage = RecordStage.ready;
      });
    } finally {
      _preparing = false;
    }
  }

  Future<bool> _permissionsGranted() async {
    try {
      _asking = true;
      final r = await [Permission.camera, Permission.microphone].request();
      if (r.values.every((s) => s.isGranted || s.isLimited)) return true;
      final forever =
          r.values.any((s) => s.isPermanentlyDenied || s.isRestricted);
      _blocked(forever ? _Block.permissionInSettings : _Block.permission);
      return false;
    } catch (_) {
      // No permission plugin here: the camera asks for itself.
      return true;
    } finally {
      _asking = false;
    }
  }

  void _blocked(_Block why, [Object? error]) {
    if (error != null) AppLog.add('identity', 'camera: $why ($error)');
    if (!mounted) return;
    setState(() {
      _block = why;
      _stage = RecordStage.blocked;
    });
  }

  /// Gives the camera up now; the next [_prepare] waits for it.
  void _letGoOfCamera() {
    final before = _releasing;
    final now = _releaseCamera();
    _releasing = Future.wait([before, now]).then((_) {});
  }

  Future<void> _releaseCamera() async {
    final c = _camera;
    _camera = null;
    if (c == null) return;
    try {
      if (c.value.isRecordingVideo) {
        final f = await c.stopVideoRecording();
        _deleteQuietly(f.path);
      }
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      if (_asking) return;
      _wentAway = true;
      _leftTheApp();
    } else if (state == AppLifecycleState.resumed) {
      if (!_wentAway) return;
      _wentAway = false;
      // The preview was paused on the way out; nothing on the review
      // screen could start it again.
      if (_stage == RecordStage.review) {
        _playReview();
        return;
      }
      // Back from the background or from Settings: the camera was given
      // up on the way out, so it is opened again (and permission asked
      // again, which is how a "turned on in Settings" is noticed).
      final waiting = _stage == RecordStage.preparing ||
          _stage == RecordStage.ready ||
          (_stage == RecordStage.blocked && _block != _Block.noFrontCamera);
      if (_camera == null && waiting) _prepare();
    }
  }

  /// Android takes the camera and the microphone from an app in the
  /// background, so a take cannot go on. It is thrown away — never saved
  /// half-read — and the screen says why when the user is back.
  void _leftTheApp() {
    switch (_stage) {
      case RecordStage.countdown:
      case RecordStage.recording:
        _countdown?.cancel();
        _clock.stop();
        _screenOn(false);
        _letGoOfCamera();
        _resetClock();
        setState(() {
          _stage = RecordStage.preparing;
          _notice = 'Recording stopped when the app went to the background, '
              'and nothing was kept. Start again when you are ready.';
        });
      case RecordStage.ready:
        _letGoOfCamera();
        setState(() => _stage = RecordStage.preparing);
      case RecordStage.review:
        _pauseReview();
        _letGoOfCamera();
      case RecordStage.uploading:
        _letGoOfCamera();
      case RecordStage.preparing:
      case RecordStage.blocked:
        break;
    }
  }

  /* ----------------------------- recording ---------------------------- */

  void _setPace(ReadingPace p) {
    if (p == _pace || _stage != RecordStage.ready) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pace = p;
      _timeline = _timelineAt(p);
    });
  }

  void _startCountdown() {
    if (_stage != RecordStage.ready || _camera == null) return;
    HapticFeedback.selectionClick();
    _screenOn(true);
    _resetClock();
    setState(() {
      _stage = RecordStage.countdown;
      _count = 3;
      _notice = null;
    });
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _stage != RecordStage.countdown) {
        t.cancel();
        return;
      }
      if (_count > 1) {
        HapticFeedback.selectionClick();
        setState(() => _count--);
        return;
      }
      t.cancel();
      _startRecording();
    });
  }

  void _cancelCountdown() {
    _countdown?.cancel();
    _screenOn(false);
    setState(() => _stage = RecordStage.ready);
  }

  Future<void> _startRecording() async {
    final c = _camera;
    if (c == null || _stage != RecordStage.countdown) return;
    try {
      // Not persistent: the take ends with the camera, never outlives it.
      await c.startVideoRecording(enablePersistentRecording: false);
    } catch (e) {
      AppLog.add('identity', 'record start failed: $e');
      _screenOn(false);
      if (!mounted) return;
      setState(() {
        _stage = RecordStage.ready;
        _notice = "Couldn't start recording — try again.";
      });
      return;
    }
    // The user may have left while the camera was starting.
    if (!mounted || _stage != RecordStage.countdown || _camera != c) {
      try {
        _deleteQuietly((await c.stopVideoRecording()).path);
      } catch (_) {}
      return;
    }
    HapticFeedback.mediumImpact();
    _resetClock();
    _clock.start();
    setState(() => _stage = RecordStage.recording);
  }

  void _onTick(Duration t) {
    _elapsed.value = t;
    final s = t.inSeconds;
    if (_seconds.value != s) _seconds.value = s;
    if (!_done.value && _timeline.isDone(t)) _done.value = true;
    if (IdentityRecordRules.mustStop(t)) _stop();
  }

  void _resetClock() {
    _elapsed.value = Duration.zero;
    _seconds.value = 0;
    _done.value = false;
  }

  Future<void> _stop() async {
    if (_stage != RecordStage.recording || _stopping) return;
    _stopping = true;
    final length = _elapsed.value;
    _clock.stop();
    _screenOn(false);
    HapticFeedback.mediumImpact();
    XFile? file;
    try {
      file = await _camera?.stopVideoRecording();
    } catch (e) {
      AppLog.add('identity', 'record stop failed: $e');
    } finally {
      _stopping = false;
    }
    if (!mounted) {
      if (file != null) _deleteQuietly(file.path);
      return;
    }
    if (file == null) {
      setState(() {
        _stage = RecordStage.ready;
        _notice = "That recording couldn't be kept — please record again.";
      });
      return;
    }
    if (!IdentityRecordRules.canSave(length)) {
      _deleteQuietly(file.path);
      _resetClock();
      setState(() {
        _stage = RecordStage.ready;
        _notice = IdentityRecordRules.tooShort;
      });
      return;
    }
    _take = file;
    _takeLength = length;
    try {
      await _camera?.pausePreview();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _stage = RecordStage.review;
      _uploadError = null;
    });
    unawaited(_openPlayer(file.path));
  }

  /* ------------------------------ review ------------------------------ */

  Future<void> _openPlayer(String path) async {
    final p = VideoPlayerController.file(File(path));
    _player = p;
    try {
      await p.initialize();
      await p.setLooping(true);
      if (_player == p && _stage == RecordStage.review) _playReview();
    } catch (e) {
      AppLog.add('identity', 'review player: $e');
    }
    if (mounted && _player == p) setState(() {});
  }

  /// The take plays in a loop while it is watched, and the screen stays
  /// on while it plays: it went dark, and came back to a frozen frame.
  void _playReview() {
    final p = _player;
    if (p == null || !p.value.isInitialized) return;
    p.play();
    _screenOn(true);
  }

  void _pauseReview() {
    _player?.pause();
    _screenOn(false);
  }

  void _toggleReview() {
    final p = _player;
    if (p == null || !p.value.isInitialized || _stage != RecordStage.review) {
      return;
    }
    HapticFeedback.selectionClick();
    p.value.isPlaying ? _pauseReview() : _playReview();
  }

  /// Not awaited: a player whose start failed never finishes disposing,
  /// and Retake must not wait on it.
  void _closePlayer() {
    final p = _player;
    _player = null;
    if (p != null) unawaited(p.dispose().catchError((_) {}));
  }

  Future<void> _retake() async {
    HapticFeedback.selectionClick();
    _closePlayer();
    _screenOn(false);
    _deleteTake();
    _resetClock();
    if (!mounted) return;
    setState(() {
      _stage = RecordStage.ready;
      _uploadError = null;
      _notice = null;
    });
    final c = _camera;
    if (c == null) {
      _prepare();
      return;
    }
    try {
      await c.resumePreview();
    } catch (_) {}
  }

  Future<void> _save() async {
    final take = _take;
    if (take == null || _stage != RecordStage.review) return;
    HapticFeedback.selectionClick();
    await _player?.pause();
    _sent.value = 0;
    setState(() {
      _stage = RecordStage.uploading;
      _uploadError = null;
    });
    // A screen that goes dark mid-upload sends the app to the background,
    // where the connection may be cut: it stays on until the answer.
    _screenOn(true);
    final r = await AvatarMessageService.uploadVideo(
      File(take.path),
      durationMs: _takeLength.inMilliseconds,
      scriptVersion: widget.scriptVersion,
      onProgress: (sent, total) {
        if (total > 0) _sent.value = sent / total;
      },
    );
    _screenOn(false);
    if (!mounted) return;
    if (!r.ok) {
      // The take is kept: Save becomes Try again.
      AppLog.add('identity', 'upload refused: ${r.status} ${r.error ?? ''}');
      setState(() {
        _stage = RecordStage.review;
        _uploadError = r.message;
      });
      return;
    }
    await AvatarMessageService.keepLocalCopy(File(take.path), r.video?.id);
    _closePlayer();
    _deleteTake();
    if (!mounted) return;
    AppFeedback.show('Your video is saved.',
        context: context, tone: FeedbackTone.success);
    Navigator.of(context).pop(r.video);
  }

  /* ------------------------------ leaving ----------------------------- */

  bool get _canLeave =>
      _stage == RecordStage.preparing ||
      _stage == RecordStage.blocked ||
      _stage == RecordStage.ready;

  Future<void> _onBack() async {
    if (_stage == RecordStage.uploading) {
      AppFeedback.show('Saving your video — one moment.', context: context);
      return;
    }
    final recording = _stage == RecordStage.recording;
    final leave = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard this video?'),
        content: Text(recording
            ? 'The recording stops and nothing is saved.'
            : 'Nothing is saved.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text('Discard', style: TextStyle(color: Neon.errorInk))),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    _countdown?.cancel();
    _clock.stop();
    _screenOn(false);
    _closePlayer();
    _letGoOfCamera();
    await _releasing;
    _deleteTake();
    if (mounted) Navigator.of(context).pop();
  }

  /* ------------------------------ helpers ----------------------------- */

  void _screenOn(bool on) {
    _device.invokeMethod('keepScreenOn', {'on': on}).catchError((_) => null);
  }

  void _deleteTake() {
    final t = _take;
    _take = null;
    if (t != null) _deleteQuietly(t.path);
  }

  static void _deleteQuietly(String path) {
    File(path).delete().then((_) {}, onError: (_) {});
  }

  static String _clockOf(Duration d) =>
      '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  /* ------------------------------- build ------------------------------ */

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          // A camera screen is dark in either theme, like the phone's own.
          backgroundColor: Colors.black,
          resizeToAvoidBottomInset: false,
          body: switch (_stage) {
            RecordStage.blocked => _blockedView(),
            RecordStage.review || RecordStage.uploading => _reviewView(),
            _ => _cameraView(),
          },
        ),
      ),
    );
  }

  /// The words and the controls over the picture: [top] pinned under the
  /// status bar, [actions] at the foot, the face clear between them, and
  /// [note] just above the actions. The face gives up its room first; with
  /// the largest text on a small phone the note then scrolls in what is
  /// left, whole — a four-line cap with "…" hid the end of the very notice
  /// saying why a take was lost (review, 2026-09-26) — while the buttons
  /// never leave the screen.
  Widget _overlay(
      {required Widget top, Widget? note, required Widget actions}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
            decoration: _shade(fromTop: true),
            child: SafeArea(bottom: false, child: top)),
        Flexible(
          child: DecoratedBox(
            decoration: _shade(fromTop: false),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (note != null)
                    Flexible(child: SingleChildScrollView(child: note)),
                  actions,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Dark behind the words and behind the controls, fading to clear over
  /// the face: the words stay legible over a bright window as well as a
  /// dim room, and the user sees their own face to frame it.
  // The words' and controls' ink over the picture (2026-09-30): the
  // night theme's white, from the tokens. The picture itself, and the
  // shade that keeps words legible over it, stay true black: this is the
  // camera, like the phone's own.
  static Color get _ink => Neon.textHi;

  static BoxDecoration _shade({required bool fromTop}) => BoxDecoration(
        gradient: LinearGradient(
          begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
          end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.66),
            Colors.black.withValues(alpha: 0.5),
            Colors.black.withValues(alpha: 0),
          ],
          stops: const [0, 0.72, 1],
        ),
      );

  /// How many lines of the script show: the one just read, the one being
  /// read (the second row, as close to the lens as the top bar allows)
  /// and two ahead.
  static const int _promptLines = 4;
  static const double _readingRow = 1.5 / _promptLines;

  Widget _cameraView() {
    final c = _camera;
    final live = _stage == RecordStage.recording;
    final quick = Motion.reduced(context) ? Duration.zero : Motion.short;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (c != null && c.value.isInitialized)
          _cover(c.value.aspectRatio, true, CameraPreview(c))
        else
          const ColoredBox(color: Colors.black),
        // Over the face, in the middle: only the 3-2-1 (which used to sit
        // on the script's opening lines) and the camera starting.
        IgnorePointer(
          child: Center(
            child: switch (_stage) {
              RecordStage.countdown => _countdownNumber(),
              RecordStage.preparing =>
                const NeonLoader(semanticLabel: 'Starting the camera'),
              _ => const SizedBox.shrink(),
            },
          ),
        ),
        _overlay(
          top: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _topBar(
                title: 'Your video',
                trailing: live ? _recPill() : null,
              ),
              AnimatedOpacity(curve: Motion.easeMove, 
                opacity: live ? 1 : 0,
                duration: quick,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(40, 2, 40, 6),
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: _elapsed,
                    builder: (_, t, __) => ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _timeline.progress(t),
                        minHeight: 3,
                        color: Neon.cyan,
                        backgroundColor: _ink.withValues(alpha: 0.22),
                      ),
                    ),
                  ),
                ),
              ),
              // THE WORDS, just under the camera: the eyes stay on the lens.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Teleprompter(
                  timeline: _timeline,
                  elapsed: _elapsed,
                  visibleLines: _promptLines,
                  anchor: _readingRow,
                ),
              ),
              const SizedBox(height: 22),
            ],
          ),
          note: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: _hint(),
          ),
          actions: _controls(),
        ),
      ],
    );
  }

  /// Fills the screen with an upright picture of [aspect] (the landscape
  /// width:height a camera or video reports), cropping the sides as the
  /// phone's own camera does.
  Widget _cover(double aspect, bool landscapeRatio, Widget child) {
    final a = aspect <= 0 ? 1.0 : aspect;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: landscapeRatio ? 100 : 100 * a,
          height: landscapeRatio ? 100 * a : 100,
          child: child,
        ),
      ),
    );
  }

  Widget _topBar({required String title, String? subtitle, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            color: _ink,
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: trailing != null
                ? Center(child: trailing)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.row.copyWith(color: _ink)),
                      if (subtitle != null)
                        Text(subtitle,
                            style: TextStyle(
                                color: _ink.withValues(alpha: 0.75),
                                fontSize: NeonType.footnote,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                    ],
                  ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  /// The time into the take. No "/ 1:00": the minute is only a safety
  /// stop, and a target next to it read as "talk for a minute".
  Widget _recPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Neon.scrim,
          borderRadius: BorderRadius.circular(Neon.rPill),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: Neon.error,
                shape: BoxShape.circle,
                boxShadow: Neon.halo(Neon.error, strength: 0.6)),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<int>(
            valueListenable: _seconds,
            builder: (_, s, __) => Text(
              _clockOf(Duration(seconds: s)),
              style: NeonType.manrope(NeonType.body, FontWeight.w600).copyWith(
                  color: _ink,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ]),
      );

  Widget _countdownNumber() {
    final number = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        '$_count',
        // A 96 px digit is large enough at any text size.
        textScaler: TextScaler.noScaling,
        style: NeonType.manrope(96, FontWeight.w800).copyWith(
          color: _ink,
          // Its own light as well as the dark under it: the count glows.
          shadows: [
            Shadow(color: Neon.scrim, blurRadius: 24),
            Shadow(color: Neon.violet.withValues(alpha: 0.7), blurRadius: 30),
          ],
        ),
      ),
    );
    if (Motion.reduced(context)) return number;
    return AnimatedSwitcher(
      duration: Motion.short,
      switchInCurve: Motion.easeEnter,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 1.35, end: 1.0).animate(a),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(_count), child: number),
    );
  }

  Widget _hint() {
    final hint = switch (_stage) {
      RecordStage.preparing => _notice ?? 'Starting the camera…',
      RecordStage.ready => _notice ??
          'Hold the phone at eye level, somewhere quiet and bright. Tap the '
              'button, then read the words as they light up.',
      RecordStage.countdown => 'Get ready — tap again to cancel.',
      _ => null,
    };
    if (hint != null) return _hintText(hint);
    return ValueListenableBuilder<bool>(
      valueListenable: _done,
      builder: (_, done, __) => _hintText(done
          // Not "all done": a slower reader may still be reading.
          ? 'Finished? Tap to stop.'
          : 'Read along at an easy pace.'),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_stage == RecordStage.ready) ...[
            _paceChoice(),
            const SizedBox(height: 14),
          ],
          _recordButton(),
        ],
      ),
    );
  }

  /// Every line, however large the text: an instruction cut off with "…"
  /// is not an instruction.
  Widget _hintText(String text) => Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
            color: _ink.withValues(alpha: 0.88),
            fontSize: NeonType.footnote,
            height: 1.35),
      );

  Widget _paceChoice() {
    return Semantics(
      container: true,
      label: 'Reading pace',
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Row(
            children: [
              for (final p in ReadingPace.values) ...[
                if (p != ReadingPace.values.first) const SizedBox(width: 8),
                Expanded(child: _paceChip(p)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _paceChip(ReadingPace p) {
    final on = p == _pace;
    return Semantics(
      button: true,
      selected: on,
      label: '${p.label} pace',
      excludeSemantics: true,
      // The chosen pace lit in the brand's gradient and glow; the
      // others clear glass (2026-09-30). It dips under the finger.
      child: PressScale(
        scale: 0.95,
        child: GestureDetector(
        key: ValueKey('pace-${p.name}'),
        onTap: () {
          HapticFeedback.selectionClick();
          _setPace(p);
        },
        child: AnimatedContainer(curve: Motion.easeMove,
          duration: Motion.reduced(context) ? Duration.zero : Motion.micro,
          height: 34,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: on ? null : _ink.withValues(alpha: 0.16),
            gradient: on ? Neon.gBrand : null,
            borderRadius: BorderRadius.circular(Neon.rPill),
            boxShadow: on ? Neon.halo(Neon.violet, strength: 0.7) : null,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              p.label,
              style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                  .copyWith(color: on ? Neon.onBrand : _ink),
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _recordButton() {
    final recording = _stage == RecordStage.recording;
    final counting = _stage == RecordStage.countdown;
    final VoidCallback? onTap = switch (_stage) {
      RecordStage.ready => _startCountdown,
      RecordStage.countdown => _cancelCountdown,
      RecordStage.recording => _stop,
      _ => null,
    };
    final quick = Motion.reduced(context) ? Duration.zero : Motion.short;
    return Semantics(
      key: const ValueKey('record-button'),
      button: true,
      enabled: onTap != null,
      label: recording
          ? 'Stop recording'
          : counting
              ? 'Cancel'
              : 'Start recording',
      // It dips under the finger, and the red core glows (2026-09-30).
      child: PressScale(
        scale: 0.94,
        child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                onTap();
              },
        child: AnimatedOpacity(curve: Motion.easeMove,
          opacity: onTap == null ? 0.45 : 1,
          duration: quick,
          child: Container(
            width: 78,
            height: 78,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: _ink, width: 4),
            ),
            child: AnimatedContainer(
              duration: quick,
              curve: Motion.easeMove,
              width: recording ? 30 : 60,
              height: recording ? 30 : 60,
              decoration: BoxDecoration(
                color: Neon.error,
                borderRadius: BorderRadius.circular(recording ? 8 : 30),
                boxShadow: onTap == null
                    ? null
                    : Neon.halo(Neon.error, strength: 0.8),
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  Widget _reviewView() {
    final p = _player;
    final uploading = _stage == RecordStage.uploading;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (p != null && p.value.isInitialized)
          _cover(p.value.aspectRatio, false, VideoPlayer(p))
        else
          const ColoredBox(color: Colors.black),
        Center(child: _playState()),
        // A tap anywhere on the picture pauses or plays it; the buttons
        // take their own taps first.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _toggleReview,
          child: _overlay(
            top: _topBar(
                title: 'Watch it back', subtitle: _clockOf(_takeLength)),
            note: uploading || _uploadError != null
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    child: uploading
                        ? _uploadProgress()
                        : _errorBanner(_uploadError!),
                  )
                : null,
            actions: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: uploading ? null : _retake,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _ink,
                            minimumSize: const Size.fromHeight(50),
                            side: BorderSide(
                                color: _ink.withValues(alpha: 0.7)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            textStyle: NeonType.manrope(
                                NeonType.rowTitle, FontWeight.w600),
                          ),
                          child: const Text('Retake'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        // The one lit action: keep this take.
                        child: GlowCta(
                          label: _uploadError != null ? 'Try again' : 'Save',
                          onPressed: uploading ? null : _save,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// A play button while the take is paused — the only way back to it
  /// after the screen went dark used to be Retake.
  Widget _playState() {
    final p = _player;
    if (p == null || _stage != RecordStage.review) return const SizedBox.shrink();
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: p,
      builder: (_, v, __) {
        final playing = v.isPlaying;
        return Semantics(
          button: true,
          label: playing ? 'Pause the video' : 'Play the video',
          onTap: _toggleReview,
          child: AnimatedOpacity(curve: Motion.easeMove, 
            opacity: v.isInitialized && !playing ? 1 : 0,
            duration: Motion.reduced(context) ? Duration.zero : Motion.micro,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Neon.scrim,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.play_arrow_rounded, color: _ink, size: 44),
            ),
          ),
        );
      },
    );
  }

  // Could-not, in the danger tone's rim (2026-09-30).
  Widget _errorBanner(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: GlowCard(
          tone: NeonTone.danger,
          halo: 0.5,
          rimWidth: 1.4,
          radius: Neon.rSm,
          padding: const EdgeInsets.all(10.6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.cloud_off_rounded, color: Neon.errorInk, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                    style: TextStyle(
                        color: _ink, fontSize: NeonType.body, height: 1.4)),
              ),
            ],
          ),
        ),
      );

  Widget _uploadProgress() => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ValueListenableBuilder<double>(
          valueListenable: _sent,
          builder: (_, v, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  // Every byte handed over; the server still has to take it.
                  value: v >= 1 ? null : v,
                  minHeight: 5,
                  color: Neon.cyan,
                  backgroundColor: _ink.withValues(alpha: 0.22),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                v >= 1
                    ? 'Almost there…'
                    : 'Saving your video… ${(v * 100).round()}%',
                style: TextStyle(
                    color: _ink,
                    fontSize: NeonType.footnote,
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ],
          ),
        ),
      );

  Widget _blockedView() {
    final (IconData icon, String title, String body, String action,
        VoidCallback onAction) = switch (_block) {
      _Block.permission => (
          Icons.videocam_off_rounded,
          'Camera and microphone needed',
          'Your video is recorded right here in the app, so it needs both. '
              'Nothing is recorded until you tap the button.',
          'Allow',
          _prepare,
        ),
      _Block.permissionInSettings => (
          Icons.videocam_off_rounded,
          'Camera and microphone are off',
          'Turn on Camera and Microphone for this app in Settings, then '
              'come back — this screen picks up where it left off.',
          'Open settings',
          openAppSettings,
        ),
      _Block.noFrontCamera => (
          Icons.no_photography_rounded,
          'No front camera',
          'The video has to be you, facing the screen, so it can only be '
              'recorded with a front camera.',
          'Go back',
          () => Navigator.maybePop(context),
        ),
      _Block.camera => (
          Icons.videocam_off_rounded,
          "Couldn't start the camera",
          'Another app may be using it. Close that app, then try again.',
          'Try again',
          _prepare,
        ),
    };
    return SafeArea(
      child: Column(
        children: [
          _topBar(title: 'Your video'),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 44, color: _ink.withValues(alpha: 0.8)),
                      const SizedBox(height: 16),
                      Text(title,
                          textAlign: TextAlign.center,
                          style: NeonType.cardTitle.copyWith(color: _ink)),
                      const SizedBox(height: 8),
                      Text(body,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: _ink.withValues(alpha: 0.78),
                              fontSize: NeonType.body,
                              height: 1.45)),
                      const SizedBox(height: 22),
                      GlowCta(label: action, onPressed: onAction),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
