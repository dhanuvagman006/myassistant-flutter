import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/app_feedback.dart';
import '../services/avatar_message_service.dart';
import 'identity_record_screen.dart';

/// SEND MESSAGES AS YOU — the sender's side of video notes (owner,
/// 2026-09-26: "send a video note for Danush saying he should meet me at
/// twelve PM").
///
/// Order is deliberate: consent FIRST, the video second. The server
/// refuses the video without recorded consent, and withdrawing it stops
/// video notes at once. The one thing captured is a ~30 s video recorded
/// live in the app with the front camera (IdentityRecordScreen) — it
/// carries both the face and the voice, so the old photo and voice-sample
/// cards are gone. There is nothing here to point at another person.
class AvatarIdentityScreen extends StatefulWidget {
  const AvatarIdentityScreen({super.key, this.loader, this.localCopyOf});

  /// Reads the profile. Tests pass their own.
  final Future<AvatarProfile?> Function()? loader;

  /// Finds this phone's copy of a saved video. Tests pass their own.
  final Future<File?> Function(String id)? localCopyOf;

  @override
  State<AvatarIdentityScreen> createState() => _AvatarIdentityScreenState();
}

/// What the switch says when the server refuses to turn video notes on
/// (409). Consent is asked about FIRST: the server's consent refusal,
/// "Agree to video notes first.", also contains "video", and every missing
/// consent was reported as "Record your video first." (review, 2026-09-26).
@visibleForTesting
String enableRefusal(String? serverError) {
  final why = (serverError ?? '').toLowerCase();
  if (why.contains('agree') || why.contains('consent')) {
    return 'Give your consent first.';
  }
  if (why.contains('video')) return 'Record your video first.';
  return "Couldn't change that — try again.";
}

class _AvatarIdentityScreenState extends State<AvatarIdentityScreen> {
  AvatarProfile? _profile;
  File? _localVideo;
  bool _loading = true;
  bool _busy = false;

  /// The small preview, so it can be stopped before the recorder opens.
  final _thumb = GlobalKey<_VideoThumbState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// A failed read used to leave a spinner up for good (the route did not
  /// exist yet). Now: the error and Try again the first time; a toast, with
  /// what is on screen kept, when a refresh fails.
  Future<void> _load() async {
    final p = await (widget.loader ?? AvatarMessageService.profile)();
    if (!mounted) return;
    if (p == null && _profile != null) {
      AppFeedback.show("Couldn't refresh — check your connection.",
          context: context);
    }
    setState(() {
      _loading = false;
      if (p != null) {
        if (p.video?.id != _profile?.video?.id) _localVideo = null;
        _profile = p;
      }
    });
    // The preview copy is looked for after the page is up, not before.
    final id = p?.video?.id;
    if (id == null) return;
    final local =
        await (widget.localCopyOf ?? AvatarMessageService.localCopy)(id);
    if (!mounted || _profile?.video?.id != id) return;
    if (local?.path != _localVideo?.path) setState(() => _localVideo = local);
  }

  Future<void> _retry() async {
    setState(() => _loading = true);
    await _load();
  }

  void _toast(String msg, {FeedbackTone? tone}) {
    if (!mounted) return;
    AppFeedback.show(msg, context: context, tone: tone);
  }

  Future<void> _run(Future<bool> Function() op,
      {required String ok, required String fail}) async {
    setState(() => _busy = true);
    final done = await op();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(done ? ok : fail,
        tone: done ? FeedbackTone.success : FeedbackTone.error);
    await _load();
  }

  Future<void> _consent() => _run(AvatarMessageService.grantConsent,
      ok: 'Thank you. Now record your video.',
      fail: "Couldn't save your consent — try again.");

  Future<void> _withdraw() async {
    final sure = await _confirm(
      title: 'Withdraw consent?',
      body: 'Video notes stop at once, and nothing new is made from your '
          'video. The video itself stays until you delete it.',
      action: 'Withdraw',
    );
    if (sure != true) return;
    await _run(AvatarMessageService.revokeConsent,
        ok: 'Consent withdrawn. Video notes are off.',
        fail: "Couldn't withdraw — check your connection and try again.");
  }

  Future<void> _delete() async {
    final sure = await _confirm(
      title: 'Delete everything?',
      body: 'Your video and your consent are removed from our servers, and '
          'no new video notes can be made from them. Notes already delivered '
          'stay with the people who got them.',
      action: 'Delete',
    );
    if (sure != true) return;
    await _run(AvatarMessageService.deleteIdentity,
        ok: 'Deleted. Nothing new can be made from your video.',
        fail: "Couldn't delete — check your connection and try again.");
  }

  Future<void> _setEnabled(bool on) async {
    HapticFeedback.selectionClick();
    setState(() => _busy = true);
    final r = await AvatarMessageService.setEnabled(on);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      // Nothing goes "as text" instead: with this off, no note is made.
      _toast(on ? 'Video notes on.' : 'Video notes off.');
    } else {
      _toast(enableRefusal(r.error), tone: FeedbackTone.error);
    }
    await _load();
  }

  Future<void> _record() async {
    // The old take, playing with sound, went on under the recorder and
    // into the new take's voice (review, 2026-09-26).
    await _thumb.currentState?.pause();
    if (!mounted) return;
    final saved = await Navigator.of(context).push<IdentityVideo>(
        MaterialPageRoute(builder: (_) => const IdentityRecordScreen()));
    if (saved != null && mounted) await _load();
  }

  Future<bool?> _confirm(
          {required String title,
          required String body,
          required String action}) =>
      showAppDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(action, style: TextStyle(color: Neon.errorInk))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Send messages as you'),
      body: LoadSwitch(
        loading: _loading,
        child: p == null
            ? NeonErrorState(
                message: "Couldn't load your video settings. Check your "
                    'connection and try again.',
                onRetry: _retry,
              )
            : _content(p),
      ),
    );
  }

  Widget _content(AvatarProfile p) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
          child: Text(
            'Say “send a video note to …” and your assistant writes the '
            'words. The person gets a short clip of you saying them, in '
            'your face and voice. Every clip is marked as made by AI.',
            style: TextStyle(
                color: Neon.textLo, fontSize: NeonType.body, height: 1.45),
          ),
        ),
        if (!p.consented) ...[
          const GroupLabel('Before you start'),
          _consentCard(),
        ] else ...[
          const GroupLabel('Your video'),
          // Actions sit on rows of their own: as buttons on the right they
          // squeezed "Recorded" and "Consent given" to "Rec…" and "Con…" at
          // the largest text (review, 2026-09-26).
          GroupedCard(dividerInset: 60, children: [
            _videoRow(p),
            if (p.hasVideo)
              AppleRow(
                leading: IconTile(Icons.videocam_rounded, AppleColors.blue),
                title: 'Record again',
                titleMaxLines: 2,
                onTap: _busy ? null : _record,
              ),
          ]),
          if (!p.hasVideo) ...[
            const SizedBox(height: 12),
            ApplePrimaryButton(
              label: 'Record your video',
              icon: Icons.videocam_rounded,
              onPressed: _busy ? null : _record,
            ),
          ],
          const SizedBox(height: 24),
          const GroupLabel('Video notes'),
          GroupedCard(children: [
            AppleRow(
              // The name the assistant says when it is off ("Turn on Send
              // as you…"), so the user finds the switch it means.
              title: 'Send as you',
              titleMaxLines: 2,
              subtitle: p.hasVideo
                  ? 'Video notes in your face and voice. When off, none '
                      'are made.'
                  : 'Record your video first.',
              trailing: Switch(
                value: p.enabled,
                activeThumbColor: Colors.white,
                activeTrackColor: AppleColors.green,
                onChanged:
                    _busy || (!p.hasVideo && !p.enabled) ? null : _setEnabled,
              ),
            ),
          ]),
          const SizedBox(height: 24),
          const GroupLabel('Consent'),
          GroupedCard(dividerInset: 60, children: [
            AppleRow(
              leading:
                  IconTile(Icons.verified_user_rounded, AppleColors.green),
              title: 'Consent given',
              subtitle: p.consentedAt == null
                  ? 'Only for video notes you ask for.'
                  : 'On ${_date(p.consentedAt!)}. Only for video notes you '
                      'ask for.',
            ),
            AppleRow(
              leading: IconTile(Icons.block_rounded, AppleColors.orange),
              title: 'Withdraw consent',
              titleMaxLines: 2,
              onTap: _busy ? null : _withdraw,
            ),
          ]),
        ],
        const SizedBox(height: 24),
        // Always here, consent or not: whatever is stored can be removed.
        GroupedCard(children: [
          AppleRow(
            title: 'Delete everything',
            titleColor: Neon.errorInk,
            subtitle: 'Your video and your consent, from our servers.',
            onTap: _busy ? null : _delete,
          ),
        ]),
      ],
    );
  }

  Widget _consentCard() => Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Neon.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _point(Icons.videocam_rounded,
                'We record a short video of you reading a script on screen — '
                'about 30 seconds, live with the front camera.'),
            // Said plainly (review, 2026-09-26): for now a person on the
            // team makes each note from the video, by hand.
            _point(Icons.cloud_done_rounded,
                "It's saved on our servers. Each note is made from it by our "
                'team, only when you ask, so it can take a little while.'),
            _point(Icons.lock_rounded,
                'It is used only to make the video notes you ask for. '
                'Nothing else.'),
            _point(Icons.auto_awesome_rounded,
                'Every clip made from it is marked as made by AI, so the '
                'person watching knows.'),
            _point(Icons.delete_outline_rounded,
                'Delete it any time, right here.'),
            const SizedBox(height: 6),
            ApplePrimaryButton(
                label: 'I agree', onPressed: _busy ? null : _consent),
          ],
        ),
      );

  Widget _point(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: Neon.violet),
            const SizedBox(width: 12),
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: NeonType.body,
                      height: 1.4)),
            ),
          ],
        ),
      );

  Widget _videoRow(AvatarProfile p) {
    final v = p.video;
    if (!p.hasVideo) {
      return AppleRow(
        leading: IconTile(Icons.videocam_rounded, AppleColors.blue),
        title: 'No video yet',
        subtitle: 'About 30 seconds of you reading a short script. The '
            'words scroll on screen as you go.',
      );
    }
    final when = v?.createdAt == null ? null : _date(v!.createdAt!);
    final length = v == null || v.durationMs <= 0 ? null : _clock(v.length);
    return AppleRow(
      leading: _VideoThumb(key: _thumb, file: _localVideo),
      title: 'Recorded',
      subtitle: [
        if (when != null) when,
        if (length != null) length,
      ].join(' · '),
    );
  }

  static String _date(int ms) {
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day} ${mo[d.month - 1]} ${d.year}';
  }

  static String _clock(Duration d) =>
      '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

/// The saved video, small: its first frame, and a tap plays it in place.
/// Recorded on another phone (or before a reinstall) there is no copy
/// here, and a plain tile stands in.
class _VideoThumb extends StatefulWidget {
  const _VideoThumb({super.key, required this.file});
  final File? file;

  @override
  State<_VideoThumb> createState() => _VideoThumbState();
}

class _VideoThumbState extends State<_VideoThumb> {
  VideoPlayerController? _c;

  /// Stops it. The screen stays mounted under a pushed route, and the
  /// player would play on there.
  Future<void> pause() async {
    final c = _c;
    if (c == null || !c.value.isPlaying) return;
    try {
      await c.pause();
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void didUpdateWidget(_VideoThumb old) {
    super.didUpdateWidget(old);
    if (old.file?.path != widget.file?.path) {
      _c?.dispose();
      _c = null;
      _open();
    }
  }

  Future<void> _open() async {
    final f = widget.file;
    if (f == null) return;
    final c = VideoPlayerController.file(f);
    _c = c;
    try {
      await c.initialize();
      c.addListener(_changed);
    } catch (_) {
      if (_c == c) _c = null;
      // Not awaited: a player that failed to start never finishes disposing.
      unawaited(c.dispose().catchError((_) {}));
    }
    if (mounted) setState(() {});
  }

  void _changed() {
    final c = _c;
    if (c == null || !mounted) return;
    // At the end: back to the first frame, ready to play again.
    if (!c.value.isPlaying && c.value.position >= c.value.duration) {
      c.seekTo(Duration.zero);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return IconTile(Icons.videocam_rounded, AppleColors.green);
    }
    final a = c.value.aspectRatio <= 0 ? 1.0 : c.value.aspectRatio;
    return Semantics(
      button: true,
      label: c.value.isPlaying ? 'Pause your video' : 'Play your video',
      child: GestureDetector(
        onTap: () => c.value.isPlaying ? c.pause() : c.play(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 44,
            height: 58,
            child: Stack(fit: StackFit.expand, children: [
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                    width: 100 * a, height: 100, child: VideoPlayer(c)),
              ),
              if (!c.value.isPlaying)
                ColoredBox(
                  color: Colors.black.withValues(alpha: 0.25),
                  child: const Icon(Icons.play_arrow_rounded,
                      color: Colors.white, size: 24),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
