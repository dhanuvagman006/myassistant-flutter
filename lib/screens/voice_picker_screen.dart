import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/config.dart';
import '../ai/live_voice.dart';
import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/audio/pcm_player.dart';

/// One voice supported by GPT Live, from GET /ai/voices.
class VoiceCatalogItem {
  const VoiceCatalogItem({
    required this.id,
    required this.name,
    required this.gender,
    required this.accent,
    required this.tagline,
  });

  final String id;
  final String name;
  final String gender;
  final String accent;
  final String tagline;

  factory VoiceCatalogItem.fromJson(Map value) {
    String field(String key) => (value[key] ?? '').toString().trim();
    final id = field('id').toLowerCase();
    final gender = field('gender').toLowerCase();
    if (id.isEmpty || (gender != 'female' && gender != 'male')) {
      throw const FormatException('Invalid GPT Live voice entry');
    }
    return VoiceCatalogItem(
      id: id,
      name: field('name').isEmpty
          ? '${id[0].toUpperCase()}${id.substring(1)}'
          : field('name'),
      gender: gender,
      accent: field('accent'),
      tagline: field('tagline'),
    );
  }
}

/// VOICE — compact GPT Live voice selection, reached from Settings → Voice.
/// Voice samples come from GPT Live itself, not a separate speech provider.
class VoicePickerScreen extends StatefulWidget {
  final String selectedId;

  /// Optional data sources make the real catalogue and audio path testable.
  final List<VoiceCatalogItem>? voices;
  final Future<Uint8List?> Function(String id)? sampleLoader;
  final PcmPlayer? player;

  const VoicePickerScreen({
    super.key,
    required this.selectedId,
    this.voices,
    this.sampleLoader,
    this.player,
  });

  @override
  State<VoicePickerScreen> createState() => _VoicePickerScreenState();
}

class _VoicePickerScreenState extends State<VoicePickerScreen> {
  late String _selected = widget.selectedId.toLowerCase();
  bool _fast = LiveVoicePrefs.enabled;
  String? _serverDefault;
  List<VoiceCatalogItem> _voices = const [];
  bool _loading = true;
  bool _loadFailed = false;
  String? _previewing;

  PcmPlayer get _player => widget.player ?? PcmPlayer.instance;

  @override
  void initState() {
    super.initState();
    final supplied = widget.voices;
    if (supplied != null) {
      _voices = supplied;
      _loading = false;
      _selectDefault();
    } else {
      unawaited(_loadVoices());
    }
    unawaited(LiveVoicePrefs.load().then((_) {
      if (mounted) setState(() => _fast = LiveVoicePrefs.enabled);
    }));
  }

  @override
  void dispose() {
    if (_previewing != null) unawaited(_player.stop());
    super.dispose();
  }

  void _selectDefault() {
    if (_voices.any((v) => v.id == _selected)) return;
    final configured = _serverDefault?.toLowerCase();
    _selected = _voices.any((v) => v.id == configured)
        ? configured!
        : _voices.isEmpty
            ? ''
            : _voices.first.id;
  }

  Future<void> _loadVoices() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    final response = await ApiService.getJson('/ai/voices');
    if (!mounted) return;
    final rawVoices = response?['voices'];
    if (rawVoices is! List) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return;
    }
    try {
      final loaded = rawVoices
          .whereType<Map>()
          .map(VoiceCatalogItem.fromJson)
          .toList(growable: false);
      if (loaded.isEmpty) throw const FormatException('No GPT Live voices');
      setState(() {
        _voices = loaded;
        _serverDefault = response?['default']?.toString();
        _loading = false;
        _selectDefault();
      });
    } on FormatException {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<Uint8List?> _fetchSample(String id) => widget.sampleLoader == null
      ? ApiService.getBytes('/ai/voices/$id/sample')
      : widget.sampleLoader!(id);

  Future<void> _setFast(bool on) async {
    HapticFeedback.selectionClick();
    setState(() => _fast = on);
    await LiveVoicePrefs.setEnabled(on);
  }

  Future<void> _preview(VoiceCatalogItem voice) async {
    if (_previewing != null) return;
    HapticFeedback.selectionClick();
    setState(() => _previewing = voice.id);
    try {
      await _player.stop();
      final wav = await _fetchSample(voice.id);
      if (!mounted) return;
      final audio = wav == null ? null : _decodePcmWav(wav);
      if (audio == null) {
        AppFeedback.show(
          "Couldn't play the sample. Check your connection and try again.",
          context: context,
          tone: FeedbackTone.error,
        );
        return;
      }
      await _player.play(audio.pcm, sampleRate: audio.sampleRate);
      await _player.drained().timeout(const Duration(seconds: 35));
    } on TimeoutException {
      await _player.stop();
      if (mounted) {
        AppFeedback.show(
          'The voice sample took too long to play.',
          context: context,
          tone: FeedbackTone.error,
        );
      }
    } finally {
      if (mounted && _previewing == voice.id) {
        setState(() => _previewing = null);
      }
    }
  }

  void _choose(VoiceCatalogItem voice) {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(voice.id);
  }

  @override
  Widget build(BuildContext context) {
    final live = AiConfigStore.instance.current.live;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Assistant voice'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 12, 16, 40 + MediaQuery.paddingOf(context).bottom),
        children: [
          if (live.on) ...[
            GroupedCard(
              dividerInset: 60,
              children: [
                AppleRow(
                  leading: IconTile(Icons.bolt_rounded, Neon.cyan),
                  title: 'GPT Live voice',
                  subtitle: _fast
                      ? 'Fast, natural conversations'
                      : 'Off: conversations use the classic reply voice',
                  trailing: Semantics(
                    label: 'GPT Live voice',
                    child: Switch(value: _fast, onChanged: _setFast),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Preview a voice, then tap its name to use it.',
              style: TextStyle(color: Neon.textLo, fontSize: 14),
            ),
          ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: Neon.cyan),
              ),
            )
          else if (_loadFailed)
            GroupedCard(
              children: [
                AppleRow(
                  leading: IconTile(Icons.wifi_off_rounded, Neon.textLo),
                  title: "Couldn't load GPT Live voices",
                  subtitle: 'Check your connection and try again.',
                  trailing: TextButton(
                    onPressed: _loadVoices,
                    child: const Text('Retry'),
                  ),
                ),
              ],
            )
          else ...[
            _genderGroup('female', 'Female voices', Icons.female_rounded),
            const SizedBox(height: 12),
            _genderGroup('male', 'Male voices', Icons.male_rounded),
          ],
        ],
      ),
    );
  }

  Widget _genderGroup(String gender, String title, IconData icon) {
    final voices = _voices.where((voice) => voice.gender == gender).toList();
    if (voices.isEmpty) return const SizedBox.shrink();
    return GroupedCard(
      children: [
        ExpansionTile(
          key: PageStorageKey<String>('gpt-live-$gender-voices'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: EdgeInsets.zero,
          leading: Icon(icon, color: Neon.cyan, size: 22),
          title: Text(
            title,
            style: TextStyle(
              color: Neon.textHi,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '${voices.length} voices',
            style: TextStyle(color: Neon.textLo, fontSize: 13),
          ),
          children: [
            for (final voice in voices) _voiceRow(voice),
          ],
        ),
      ],
    );
  }

  Widget _voiceRow(VoiceCatalogItem voice) {
    final selected = voice.id == _selected;
    final playing = _previewing == voice.id;
    return AppleRow(
      leading: SizedBox.square(
        dimension: 48,
        child: IconButton(
          onPressed: _previewing == null ? () => _preview(voice) : null,
          tooltip: playing
              ? 'Playing a sample of ${voice.name}'
              : 'Play a sample of ${voice.name}',
          icon: playing
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Neon.cyan,
                  ),
                )
              : const Icon(Icons.play_circle_outline_rounded),
          color: playing ? Neon.cyan : Neon.textLo,
        ),
      ),
      title: voice.name,
      subtitle: [
        if (voice.accent.isNotEmpty) voice.accent,
        if (voice.tagline.isNotEmpty) voice.tagline,
      ].join(' · '),
      trailing: selected
          ? Icon(
              Icons.check_rounded,
              color: Neon.cyan,
              size: 20,
              semanticLabel: 'Selected',
            )
          : const SizedBox(width: 20),
      onTap: () => _choose(voice),
    );
  }
}

final class _WavPcm {
  const _WavPcm(this.pcm, this.sampleRate);

  final Uint8List pcm;
  final int sampleRate;
}

_WavPcm? _decodePcmWav(Uint8List wav) {
  if (wav.length < 44) return null;
  String fourCc(int offset) =>
      String.fromCharCodes(wav.sublist(offset, offset + 4));
  if (fourCc(0) != 'RIFF' || fourCc(8) != 'WAVE') return null;

  final data = ByteData.sublistView(wav);
  int? format;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataStart;
  int? dataLength;
  var offset = 12;
  while (offset + 8 <= wav.length) {
    final size = data.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    final end = start + size;
    if (end > wav.length) return null;
    switch (fourCc(offset)) {
      case 'fmt ':
        if (size < 16) return null;
        format = data.getUint16(start, Endian.little);
        channels = data.getUint16(start + 2, Endian.little);
        sampleRate = data.getUint32(start + 4, Endian.little);
        bitsPerSample = data.getUint16(start + 14, Endian.little);
      case 'data':
        dataStart = start;
        dataLength = size;
    }
    offset = end + (size.isOdd ? 1 : 0);
  }
  if (format != 1 ||
      channels != 1 ||
      sampleRate == null ||
      sampleRate == 0 ||
      bitsPerSample != 16 ||
      dataStart == null ||
      dataLength == null ||
      dataLength < 2 ||
      dataLength.isOdd) {
    return null;
  }
  return _WavPcm(
    Uint8List.sublistView(wav, dataStart, dataStart + dataLength),
    sampleRate,
  );
}
