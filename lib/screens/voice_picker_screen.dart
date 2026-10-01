import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/config.dart';
import '../ai/live_voice.dart';
import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../services/app_feedback.dart';
import '../services/audio/pcm_player.dart';

/// VOICE — its own screen, reached from Settings → Voice.
///
/// Six rows of voice names took as much room as everything else on the
/// settings page for a choice made once. The row on Settings names the
/// current voice; this is where it changes.
///
/// 2026-09-30: the FAST LIVE VOICE (Gemini Live) — a switch, on unless the
/// owner turns it off, and its own voices with a short sample each. The
/// classic voice (Fola by default) still answers when the fast voice is
/// off or cannot, and speaks typed replies.
class VoicePickerScreen extends StatefulWidget {
  final List<(String, String, String)> voices;
  final String selectedId;
  const VoicePickerScreen({
    super.key,
    required this.voices,
    required this.selectedId,
  });

  @override
  State<VoicePickerScreen> createState() => _VoicePickerScreenState();
}

class _VoicePickerScreenState extends State<VoicePickerScreen> {
  late String _sel = widget.selectedId;
  bool _fast = LiveVoicePrefs.enabled;
  String _liveVoice = LiveVoicePrefs.voiceFor(AiConfigStore.instance.current.live);

  /// The voice whose sample is playing (or being made).
  String? _previewing;

  /// What each Live voice sounds like, in Google's own words for them.
  static const _liveTaglines = {
    'Callirrhoe': 'Easy-going',
    'Achernar': 'Soft',
    'Aoede': 'Breezy',
    'Vindemiatrix': 'Gentle',
    'Sulafat': 'Warm',
    'Kore': 'Firm',
    'Charon': 'Informative',
    'Achird': 'Friendly',
  };

  @override
  void initState() {
    super.initState();
    unawaited(LiveVoicePrefs.load().then((_) {
      if (!mounted) return;
      setState(() {
        _fast = LiveVoicePrefs.enabled;
        _liveVoice = LiveVoicePrefs.voiceFor(AiConfigStore.instance.current.live);
      });
    }));
  }

  @override
  void dispose() {
    if (_previewing != null) unawaited(PcmPlayer.instance.stop());
    super.dispose();
  }

  Future<void> _setFast(bool on) async {
    HapticFeedback.selectionClick();
    setState(() => _fast = on);
    await LiveVoicePrefs.setEnabled(on);
  }

  Future<void> _pickLive(String voice) async {
    setState(() => _liveVoice = voice);
    await LiveVoicePrefs.setVoice(voice);
  }

  Future<void> _preview(String voice) async {
    HapticFeedback.selectionClick();
    setState(() => _previewing = voice);
    final ok = await LiveVoicePreview.play(voice, sink: PcmPlayer.instance);
    if (!ok && mounted && _previewing == voice) {
      AppFeedback.show("Couldn't play the sample. Check your connection.",
          context: context, tone: FeedbackTone.error);
    }
    try {
      await PcmPlayer.instance.drained().timeout(const Duration(seconds: 8));
    } catch (_) {}
    if (mounted && _previewing == voice) setState(() => _previewing = null);
  }

  @override
  Widget build(BuildContext context) {
    final live = AiConfigStore.instance.current.live;
    final liveOffered = live.on;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Assistant voice'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 40 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (liveOffered) ...[
            GroupedCard(
              dividerInset: 60,
              children: [
                AppleRow(
                  leading: IconTile(Icons.bolt_rounded, Neon.cyan),
                  title: 'Fast live voice',
                  subtitle: _fast
                      ? 'Answers in about a second, and you can talk over her'
                      : 'Off: the classic voice answers, a few seconds slower',
                  trailing: Semantics(
                    label: 'Fast live voice',
                    child: Switch(value: _fast, onChanged: _setFast),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_fast) ...[
              const GroupLabel('Live voice'),
              GroupedCard(
                dividerInset: 16,
                children: [
                  for (final v in live.voices) _liveRow(v),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ],
          const GroupLabel('Classic voice'),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 14),
            child: Text(
              liveOffered
                  ? 'Used when the fast voice is off, and for typed replies.'
                  : 'Tap a voice — the next reply uses it.',
              style: TextStyle(color: Neon.textLo, fontSize: 14),
            ),
          ),
          GroupedCard(
            children: [
              for (final (id, title, tagline) in widget.voices)
                AppleRow(
                  title: title,
                  subtitle: tagline,
                  trailing: _sel == id
                      ? Icon(Icons.check_rounded, color: Neon.violet, size: 20)
                      : const SizedBox(width: 20),
                  onTap: () {
                    setState(() => _sel = id);
                    Navigator.of(context).pop(id);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _liveRow(String voice) {
    final chosen = voice == _liveVoice;
    final playing = _previewing == voice;
    return AppleRow(
      // 48 dp, and named for a screen reader by its tooltip.
      leading: SizedBox.square(
        dimension: 48,
        child: IconButton(
          onPressed: _previewing == null ? () => _preview(voice) : null,
          tooltip: playing ? 'Playing a sample of $voice' : 'Play a sample of $voice',
          icon: Icon(
            playing ? Icons.graphic_eq_rounded : Icons.play_circle_outline_rounded,
            color: playing ? Neon.cyan : Neon.textLo,
          ),
        ),
      ),
      title: voice,
      subtitle: _liveTaglines[voice] ?? '',
      trailing: chosen
          ? Icon(Icons.check_rounded, color: Neon.cyan, size: 20,
              semanticLabel: 'Selected')
          : const SizedBox(width: 20),
      onTap: () => _pickLive(voice),
    );
  }
}
