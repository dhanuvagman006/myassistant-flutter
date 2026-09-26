import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../design/neon_tokens.dart';

/// The recipient-side popup: the sender's AI avatar delivers their
/// message. Kind:
///   'video'  the rendered talking-face clip (face + cloned voice)
///   'audio'  voice-only fallback (played over a simple identity card)
///   'text'   media unavailable — the words are shown, nothing plays
///
/// Deliberately plain (no gradients, no glass): a rounded card, the
/// video, the sender's name, an AI-generated tag — honesty is part of the
/// design — and mute/close controls.
///
/// A VIDEO NOTE ([videoNote], 2026-09-26) is a clip made by AI from the
/// sender's own recorded video, of words they asked their assistant to
/// send. It says so in its title — "AI video note from Ravi" — even when
/// the clip could not be fetched and only the words are shown.
///
/// Several unread messages come one after another; [index] of [total] says
/// where the user is, and resolves true when they chose to see the rest
/// later (so the popups stop coming back one by one).
///
/// With [fetch] and no [mediaFile], the popup opens AT ONCE and gets the
/// clip itself (2026-09-26): the download used to run first, with nothing
/// on screen for up to a minute, and a clip that did not come left only a
/// crossed-out camera — no reason, no retry.
Future<bool?> showAvatarMessagePopup(
  BuildContext context, {
  required String senderName,
  required String text,
  required String kind,
  File? mediaFile,
  Future<File?> Function()? fetch,
  bool videoNote = false,
  int index = 1,
  int total = 1,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => _AvatarMessageDialog(
      senderName: senderName,
      text: text,
      kind: kind,
      mediaFile: mediaFile,
      fetch: fetch,
      videoNote: videoNote,
      index: index,
      total: total,
    ),
  );
}

/// The words of a video note without the label the server puts in front
/// ("AI video note from Ravi: meet me at 12" → "meet me at 12"): the
/// title already says it.
String videoNoteWords(String text) {
  final m = RegExp(r'^\s*AI video note from [^:]{1,80}:\s*', caseSensitive: false)
      .firstMatch(text);
  return m == null ? text : text.substring(m.end);
}

class _AvatarMessageDialog extends StatefulWidget {
  const _AvatarMessageDialog({
    required this.senderName,
    required this.text,
    required this.kind,
    required this.mediaFile,
    this.fetch,
    this.videoNote = false,
    this.index = 1,
    this.total = 1,
  });

  final String senderName;
  final String text;
  final String kind;
  final File? mediaFile;
  final Future<File?> Function()? fetch;
  final bool videoNote;
  final int index;
  final int total;

  @override
  State<_AvatarMessageDialog> createState() => _AvatarMessageDialogState();
}

class _AvatarMessageDialogState extends State<_AvatarMessageDialog> {
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  File? _file;
  bool _loading = true;
  bool _muted = false;
  bool _failed = false;

  /// The clip did not come (offline, slow line): the words stay, with
  /// the reason and Try again.
  bool _fetchFailed = false;

  bool get _wantsMedia => widget.kind == 'video' || widget.kind == 'audio';

  @override
  void initState() {
    super.initState();
    _file = widget.mediaFile;
    _start();
  }

  Future<void> _tryAgain() async {
    setState(() {
      _loading = true;
      _failed = false;
      _fetchFailed = false;
    });
    await _start();
  }

  Future<void> _start() async {
    final fetch = widget.fetch;
    if (_file == null && fetch != null && _wantsMedia) {
      final f = await fetch();
      if (!mounted) return;
      if (f == null) {
        setState(() {
          _loading = false;
          _failed = true;
          _fetchFailed = true;
        });
        return;
      }
      _file = f;
    }
    try {
      if (widget.kind == 'video' && _file != null) {
        final c = VideoPlayerController.file(_file!);
        _video = c;
        await c.initialize();
        await c.play();
        c.addListener(() {
          // Auto-advance to "done" state at the end so the user sees the
          // replay affordance instead of a frozen last frame.
          if (mounted && c.value.position >= c.value.duration) {
            setState(() {});
          }
        });
      } else if (widget.kind == 'audio' && _file != null) {
        final a = AudioPlayer();
        _audio = a;
        await a.play(DeviceFileSource(_file!.path));
      } else {
        _failed = true;
      }
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _replay() async {
    try {
      if (_video != null) {
        await _video!.seekTo(Duration.zero);
        await _video!.play();
      } else if (_audio != null && _file != null) {
        await _audio!.play(DeviceFileSource(_file!.path));
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _toggleMute() {
    _muted = !_muted;
    _video?.setVolume(_muted ? 0 : 1);
    _audio?.setVolume(_muted ? 0 : 1);
    setState(() {});
  }

  @override
  void dispose() {
    _video?.dispose();
    _audio?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showVideo =
        widget.kind == 'video' && !_failed && _video?.value.isInitialized == true;
    final note = widget.videoNote || widget.kind == 'video';
    final count = widget.total > 1 ? '${widget.index} of ${widget.total}' : '';
    final words = note ? videoNoteWords(widget.text) : widget.text;
    return Dialog(
      backgroundColor: Neon.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: who is speaking + the honesty tag + close.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 6, 0),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          note
                              ? 'AI video note from ${widget.senderName}'
                              : widget.senderName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Neon.textHi,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                      if (!note || count.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                            note
                                ? count
                                : count.isEmpty
                                    ? 'AI-generated message'
                                    : 'AI-generated message · $count',
                            style:
                                TextStyle(color: Neon.textDim, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(_muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded),
                  color: Neon.textLo,
                  onPressed: _toggleMute,
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  color: Neon.textLo,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),
            const SizedBox(height: 10),

            // Body — scrolls: a long text-only message used to run past
            // the bottom of the dialog.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(children: [
                  const Center(child: CircularProgressIndicator()),
                  if (widget.fetch != null && _wantsMedia) ...[
                    const SizedBox(height: 14),
                    Text(
                        widget.kind == 'video'
                            ? 'Getting the video…'
                            : 'Getting the message…',
                        style: TextStyle(
                            color: Neon.textDim,
                            fontSize: NeonType.footnote)),
                  ],
                ]),
              )
            else if (showVideo) ...[
              // A note recorded upright is taller than the dialog is wide:
              // held to 60% of the screen so the words and Close stay in
              // view, centred rather than stretched.
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.6),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: AspectRatio(
                      aspectRatio: _video!.value.aspectRatio == 0
                          ? 1
                          : _video!.value.aspectRatio,
                      child: Stack(fit: StackFit.expand, children: [
                        VideoPlayer(_video!),
                        if (!_video!.value.isPlaying)
                          Container(
                            color: Colors.black38,
                            child: IconButton(
                              iconSize: 56,
                              color: Colors.white,
                              icon: const Icon(Icons.replay_rounded),
                              onPressed: _replay,
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              ),
              // The words under the clip: readable with the sound off.
              if (words.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(words,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Neon.textLo, fontSize: 14, height: 1.4)),
                ),
            ] else ...[
              // Audio / text fallback: an identity card with the words.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  CircleAvatar(
                    radius: 36,
                    backgroundColor: Neon.surfaceHigh,
                    child: Icon(
                        widget.kind == 'audio'
                            ? Icons.graphic_eq_rounded
                            // A video note whose clip would not play.
                            : note
                                ? Icons.videocam_off_rounded
                                : Icons.chat_bubble_outline_rounded,
                        color: Neon.textHi,
                        size: 32),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    words,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Neon.textHi, fontSize: 15, height: 1.4),
                  ),
                  if (_fetchFailed) ...[
                    const SizedBox(height: 12),
                    Text(
                      note
                          ? "The video didn't load. It's also saved in your "
                              'documents.'
                          : "The recording didn't load.",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Neon.textDim,
                          fontSize: NeonType.footnote,
                          height: 1.35),
                    ),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      onPressed: _tryAgain,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Try again'),
                    ),
                  ] else if (widget.kind == 'audio') ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _replay,
                      icon: const Icon(Icons.replay_rounded, size: 18),
                      label: const Text('Play again'),
                    ),
                  ],
                ]),
              ),
            ],
                  ],
                ),
              ),
            ),
            if (widget.index < widget.total)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(
                        'Show the other ${widget.total - widget.index} later'),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
