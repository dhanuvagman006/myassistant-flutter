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
Future<void> showAvatarMessagePopup(
  BuildContext context, {
  required String senderName,
  required String text,
  required String kind,
  File? mediaFile,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => _AvatarMessageDialog(
      senderName: senderName,
      text: text,
      kind: kind,
      mediaFile: mediaFile,
    ),
  );
}

class _AvatarMessageDialog extends StatefulWidget {
  const _AvatarMessageDialog({
    required this.senderName,
    required this.text,
    required this.kind,
    required this.mediaFile,
  });

  final String senderName;
  final String text;
  final String kind;
  final File? mediaFile;

  @override
  State<_AvatarMessageDialog> createState() => _AvatarMessageDialogState();
}

class _AvatarMessageDialogState extends State<_AvatarMessageDialog> {
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  bool _loading = true;
  bool _muted = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      if (widget.kind == 'video' && widget.mediaFile != null) {
        final c = VideoPlayerController.file(widget.mediaFile!);
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
      } else if (widget.kind == 'audio' && widget.mediaFile != null) {
        final a = AudioPlayer();
        _audio = a;
        await a.play(DeviceFileSource(widget.mediaFile!.path));
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
      } else if (_audio != null && widget.mediaFile != null) {
        await _audio!.play(DeviceFileSource(widget.mediaFile!.path));
      }
      setState(() {});
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
                      Text(widget.senderName,
                          style: TextStyle(
                              color: Neon.textHi,
                              fontSize: 16,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text('AI-generated message',
                          style:
                              TextStyle(color: Neon.textDim, fontSize: 11.5)),
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
                  icon: const Icon(Icons.close_rounded),
                  color: Neon.textLo,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ]),
            ),
            const SizedBox(height: 10),

            // Body.
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (showVideo)
              ClipRRect(
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
              )
            else ...[
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
                            : Icons.chat_bubble_outline_rounded,
                        color: Neon.textHi,
                        size: 32),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Neon.textHi, fontSize: 15, height: 1.4),
                  ),
                  if (widget.kind == 'audio') ...[
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
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
