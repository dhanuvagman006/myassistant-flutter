import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/theme_controller.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../services/api_service.dart';
import '../services/assistant_identity.dart';
import '../services/voice_id_service.dart';
import 'avatar_face_screen.dart';
import 'avatar_identity_screen.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ASSISTANT SETTINGS — how the assistant sounds and looks, plus the
///  user's standing rules.
///
///  Deliberately NO name field and NO style dropdown: identity is set by
///  TALKING ("your name is Maya from now on") — the conversation is the
///  interface. Everything left on this page saves the moment it's tapped;
///  there is no Save button to forget.
/// ─────────────────────────────────────────────────────────────────────────
class AssistantSettingsScreen extends StatefulWidget {
  const AssistantSettingsScreen({super.key});

  @override
  State<AssistantSettingsScreen> createState() =>
      _AssistantSettingsScreenState();
}

class _AssistantSettingsScreenState extends State<AssistantSettingsScreen> {
  String _voice = '';
  String _avatarId = ''; // '' = deployment default face
  List<Map<String, dynamic>> _faces = const [];
  List<dynamic> _rules = [];
  final _newRule = TextEditingController();
  bool _loading = true;

  // Voice ID ("only my voice") state — mirrors VoiceIdService.
  bool _voiceEnrolled = false;
  bool _voiceGateOn = false;
  bool _enrolling = false;

  // Live captions toggle — mirrors AssistantEngine.captionsEnabled.
  bool _captionsOn = false;

  /// Voices the TTS + live stack actually supports, with what they sound
  /// like — a picker the user can read, not a bare dropdown.
  static const _voices = [
    ('', 'Default', 'Matches the chosen face'),
    ('Kore', 'Kore', 'Warm · Female'),
    ('Aoede', 'Aoede', 'Bright · Female'),
    ('Puck', 'Puck', 'Upbeat · Male'),
    ('Charon', 'Charon', 'Deep · Male'),
    ('Fenrir', 'Fenrir', 'Bold · Male'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _newRule.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final vid = VoiceIdService.instance;
    await vid.load();
    await AssistantEngine.loadCaptionPref();
    _captionsOn = AssistantEngine.captionsEnabled;
    final p = await ApiService.getJson('/profile/full');
    final r = await ApiService.getJson('/profile/instructions');
    final f = await ApiService.getJson('/live/avatar/faces');
    if (!mounted) return;
    _voiceEnrolled = vid.enrolled;
    _voiceGateOn = vid.gateEnabled;
    setState(() {
      _loading = false;
      final a = (p?['assistant'] as Map?) ?? {};
      _voice = (a['voice'] as String?) ?? '';
      _avatarId = (a['avatar_id'] as String?) ?? '';
      _rules = (r?['instructions'] as List?) ?? [];
      _faces = ((f?['faces'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    });
  }

  /// Voice saves the moment it's tapped — 'default' clears the override.
  Future<void> _pickVoice(String v) async {
    HapticFeedback.selectionClick();
    final prev = _voice;
    setState(() => _voice = v);
    final r = await ApiService.sendJson('/profile/assistant',
        method: 'PUT', body: {'voice': v.isEmpty ? 'default' : v});
    if (!mounted) return;
    if (r == null) {
      setState(() => _voice = prev);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't save the voice.")));
    }
  }

  Future<void> _addRule() async {
    final t = _newRule.text.trim();
    if (t.isEmpty) return;
    await ApiService.sendJson('/profile/instructions',
        method: 'POST', body: {'instruction': t});
    _newRule.clear();
    await _load();
  }

  Future<void> _removeRule(int id) async {
    await ApiService.sendJson('/profile/instructions/$id', method: 'DELETE');
    await _load();
  }

  /// Records ~9 s of the user reading a sentence and turns it into the
  /// voiceprint. The audio is processed on the phone and thrown away —
  /// only the numeric print is kept.
  Future<void> _enrollVoice() async {
    if (_enrolling) return;
    if (AssistantEngine.instance.liveActive) {
      _snack('Close the conversation first, then enroll.');
      return;
    }
    final rec = AudioRecorder();
    if (!await rec.hasPermission()) {
      _snack('Microphone permission is needed to enroll.');
      return;
    }
    setState(() => _enrolling = true);
    const seconds = 9;
    final buf = BytesBuilder(copy: true);
    StreamSubscription<List<int>>? sub;
    var cancelled = false;
    try {
      final stream = await rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      sub = stream.listen((c) => buf.add(c));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) {
          Timer.periodic(const Duration(seconds: seconds), (t) {
            t.cancel();
            if (dctx.mounted) Navigator.of(dctx).pop();
          });
          return AlertDialog(
            backgroundColor: Neon.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            title: Text('Read this aloud',
                style: TextStyle(color: Neon.textHi, fontSize: 17)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '"Hey ${AssistantIdentity.name}, this is my voice. From '
                  'now on, listen only to me. One, two, three, four, five — '
                  'today is a really good day."',
                  style: TextStyle(
                      color: Neon.textHi, fontSize: 15.5, height: 1.5),
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(
                    color: Neon.violet, backgroundColor: Neon.bg),
                const SizedBox(height: 10),
                Text('Recording ${seconds}s — speak naturally.',
                    style: TextStyle(color: Neon.textDim, fontSize: 12.5)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(dctx).pop();
                },
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );
    } catch (_) {
      _snack("Couldn't open the microphone.");
      cancelled = true;
    } finally {
      try {
        await sub?.cancel();
        if (await rec.isRecording()) await rec.stop();
      } catch (_) {}
      rec.dispose();
    }
    if (cancelled) {
      if (mounted) setState(() => _enrolling = false);
      return;
    }
    final err = await VoiceIdService.instance.enroll(buf.toBytes());
    if (!mounted) return;
    if (err == null) {
      await VoiceIdService.instance.setEnabled(true);
      setState(() {
        _enrolling = false;
        _voiceEnrolled = true;
        _voiceGateOn = true;
      });
      _snack('Voice saved — the assistant now responds only to you.');
    } else {
      setState(() => _enrolling = false);
      _snack(err);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Assistant'),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Neon.textLo))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                // Identity lives in the conversation, and the page says so.
                // Live: renaming by voice updates this card too.
                ValueListenableBuilder<String>(
                  valueListenable: AssistantIdentity.notifier,
                  builder: (_, n, __) => GroupedCard(
                    dividerInset: 60,
                    children: [
                      AppleRow(
                        leading: const IconTile(
                            Icons.auto_awesome_rounded, AppleColors.purple),
                        title: n,
                        subtitle: 'To rename, just say it — "your name is '
                            'Maya from now on".',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                const GroupLabel('Appearance'),
                ValueListenableBuilder<ThemeMode3>(
                  valueListenable: ThemeController.mode,
                  builder: (_, mode, __) => GroupedCard(
                    dividerInset: 60,
                    children: [
                      AppleRow(
                        leading: IconTile(Icons.brightness_auto_rounded,
                            AppleColors.indigo),
                        title: 'Adaptive',
                        subtitle:
                            'Light through the day, dark after 7 pm — automatically.',
                        trailing: _themeTick(mode == ThemeMode3.adaptive),
                        onTap: () => ThemeController.setMode(ThemeMode3.adaptive),
                      ),
                      AppleRow(
                        leading:
                            IconTile(Icons.wb_sunny_rounded, AppleColors.orange),
                        title: 'Light',
                        trailing: _themeTick(mode == ThemeMode3.light),
                        onTap: () => ThemeController.setMode(ThemeMode3.light),
                      ),
                      AppleRow(
                        leading:
                            IconTile(Icons.nightlight_round, AppleColors.gray),
                        title: 'Dark',
                        trailing: _themeTick(mode == ThemeMode3.dark),
                        onTap: () => ThemeController.setMode(ThemeMode3.dark),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                const GroupLabel('Voice'),
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Text(
                    'Tap a voice — it applies to your next conversation.',
                    style: TextStyle(color: Neon.textDim, fontSize: 12.5),
                  ),
                ),
                GroupedCard(
                  children: [
                    for (final (id, title, tagline) in _voices)
                      AppleRow(
                        title: title,
                        subtitle: tagline,
                        trailing: _voice == id
                            ? const Icon(Icons.check_rounded,
                                color: AppleColors.blue, size: 20)
                            : const SizedBox.shrink(),
                        onTap: () => _pickVoice(id),
                      ),
                  ],
                ),
                const SizedBox(height: 24),

                const GroupLabel('Conversation'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading: const IconTile(
                          Icons.closed_caption_rounded, AppleColors.blue),
                      title: 'Live captions',
                      subtitle: 'Read what both of you say at the bottom of '
                          'the conversation screen.',
                      trailing: Switch(
                        value: _captionsOn,
                        activeThumbColor: Colors.white,
                        activeTrackColor: AppleColors.green,
                        onChanged: (v) {
                          HapticFeedback.selectionClick();
                          setState(() => _captionsOn = v);
                          AssistantEngine.setCaptionsEnabled(v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const GroupLabel('My voice'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading: const IconTile(
                          Icons.record_voice_over_rounded, AppleColors.teal),
                      title: 'Voice ID',
                      subtitle: _voiceEnrolled
                          ? 'Enrolled. Stays on this phone — nothing '
                              'is uploaded.'
                          : 'Record once so the assistant answers '
                              'only you.',
                      trailing: OutlinedButton(
                        onPressed: _enrolling ? null : _enrollVoice,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppleColors.blue,
                          side: BorderSide(color: Neon.line),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: Text(_enrolling
                            ? 'Listening…'
                            : (_voiceEnrolled ? 'Re-record' : 'Enroll')),
                      ),
                    ),
                    if (_voiceEnrolled)
                      AppleRow(
                        title: 'Respond only to my voice',
                        trailing: Switch(
                          value: _voiceGateOn,
                          activeThumbColor: Colors.white,
                          activeTrackColor: AppleColors.green,
                          onChanged: (v) async {
                            HapticFeedback.selectionClick();
                            setState(() => _voiceGateOn = v);
                            await VoiceIdService.instance.setEnabled(v);
                          },
                        ),
                      ),
                  ],
                ),
                if (_voiceEnrolled)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, top: 6),
                    child: Text(
                      'Asking for live translation lets everyone be heard '
                      'until you stop it.',
                      style: TextStyle(color: Neon.textDim, fontSize: 11.5),
                    ),
                  ),
                const SizedBox(height: 24),

                if (_faces.isNotEmpty) ...[
                  const GroupLabel('Video avatar'),
                  GroupedCard(
                    dividerInset: 60,
                    children: [
                      AppleRow(
                        leading: const IconTile(
                            Icons.face_retouching_natural_rounded,
                            AppleColors.orange),
                        title: 'Avatar face',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _faceName(_avatarId),
                              style: TextStyle(
                                  color: Neon.textLo,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 6),
                            Icon(Icons.chevron_right_rounded,
                                color: Neon.textDim, size: 20),
                          ],
                        ),
                        onTap: () async {
                          final picked =
                              await Navigator.of(context).push<String>(
                            MaterialPageRoute(
                              builder: (_) => AvatarFaceScreen(
                                faces: _faces,
                                selectedId: _avatarId,
                              ),
                            ),
                          );
                          if (picked != null && mounted) {
                            setState(() => _avatarId = picked);
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],

                const GroupLabel('Your avatar identity'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading: const IconTile(
                          Icons.record_voice_over_rounded, AppleColors.green),
                      title: 'Send messages as you',
                      subtitle: 'Your face and voice on messages you send '
                          '— with your consent.',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const AvatarIdentityScreen()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const GroupLabel('Standing rules'),
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Text(
                    'Permanent instructions the assistant follows before every '
                    'decision — e.g. "Always ask before sending messages", '
                    '"Call me Dhanu". You can also just say these in '
                    'conversation.',
                    style: TextStyle(color: Neon.textDim, fontSize: 12.5),
                  ),
                ),
                if (_rules.isNotEmpty) ...[
                  GroupedCard(
                    children: [
                      for (final r in _rules)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                          child: Row(children: [
                            Expanded(
                                child: Text(r['instruction'] ?? '',
                                    style:
                                        TextStyle(color: Neon.textLo))),
                            IconButton(
                              icon: Icon(Icons.close_rounded,
                                  size: 18, color: Neon.textDim),
                              onPressed: () => _removeRule(r['id'] as int),
                            ),
                          ]),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _newRule,
                      style: TextStyle(color: Neon.textHi),
                      decoration: _dec('Add a rule', 'Always…'),
                      onSubmitted: (_) => _addRule(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                      onPressed: _addRule,
                      icon: const Icon(Icons.add_circle_rounded,
                          color: AppleColors.blue)),
                ]),
                const SizedBox(height: 24),

                const GroupLabel('About & legal'),
                GroupedCard(
                  children: [
                    _legalRow('Privacy Policy', '/legal/privacy'),
                    _legalRow('Terms & Conditions', '/legal/terms'),
                  ],
                ),
              ],
            ),
    );
  }

  String _faceName(String id) {
    if (id.isEmpty) return 'Default';
    final f = _faces.firstWhere((m) => m['id'] == id, orElse: () => const {});
    return (f['name'] as String?) ?? 'Custom';
  }

  Widget _legalRow(String label, String path) => AppleRow(
        title: label,
        trailing: Icon(Icons.open_in_new_rounded,
            size: 16, color: Neon.textDim),
        onTap: () => launchUrl(Uri.parse('${ApiService.baseUrl}$path'),
            mode: LaunchMode.externalApplication),
      );

  InputDecoration _dec(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Neon.textLo),
        hintStyle: TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Neon.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      );
}

/// Check mark on the selected appearance row.
Widget _themeTick(bool on) => on
    ? Icon(Icons.check_rounded, color: Neon.violet, size: 20)
    : const SizedBox(width: 20);

