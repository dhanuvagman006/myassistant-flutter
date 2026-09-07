import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

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
            backgroundColor: Neon.surfaceHigh,
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
                    color: Neon.cyan, backgroundColor: Neon.bg),
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
      appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Assistant')),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Neon.textLo))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
              children: [
                // Identity lives in the conversation, and the page says so.
                _card(children: [
                  Row(children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Neon.textHi,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.auto_awesome_rounded,
                          color: Neon.onInk, size: 19),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Live: renaming by voice updates this card too.
                          ValueListenableBuilder<String>(
                            valueListenable: AssistantIdentity.notifier,
                            builder: (_, n, __) => Text(n,
                                style: TextStyle(
                                    color: Neon.textHi,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'To rename, just say it — "your name is Maya '
                            'from now on".',
                            style: TextStyle(
                                color: Neon.textDim,
                                fontSize: 12,
                                height: 1.35),
                          ),
                        ],
                      ),
                    ),
                  ]),
                ]),

                _sectionLabel('Appearance'),
                _card(children: [
                  Row(children: [
                    Icon(
                        Neon.isDark
                            ? Icons.nightlight_round
                            : Icons.wb_sunny_rounded,
                        color: Neon.textHi,
                        size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(Neon.isDark ? 'Dark' : 'Light',
                              style: TextStyle(
                                  color: Neon.textHi,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 1),
                          Text('Tap the sky to switch.',
                              style: TextStyle(
                                  color: Neon.textDim, fontSize: 12)),
                        ],
                      ),
                    ),
                    const _DayNightSwitch(),
                  ]),
                ]),

                _sectionLabel('Voice'),
                Text(
                  'Tap a voice — it applies to your next conversation.',
                  style: TextStyle(color: Neon.textDim, fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 2.55,
                  children: [
                    for (final (id, title, tagline) in _voices)
                      _voiceCard(id, title, tagline),
                  ],
                ),

                _sectionLabel('Conversation'),
                _card(children: [
                  Row(children: [
                    Icon(Icons.closed_caption_rounded,
                        color: Neon.textHi, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Live captions',
                              style: TextStyle(
                                  color: Neon.textHi,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 1),
                          Text(
                            'Read what both of you say at the bottom of '
                            'the conversation screen.',
                            style: TextStyle(
                                color: Neon.textDim,
                                fontSize: 12,
                                height: 1.35),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: _captionsOn,
                      activeThumbColor: Neon.cyan,
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        setState(() => _captionsOn = v);
                        AssistantEngine.setCaptionsEnabled(v);
                      },
                    ),
                  ]),
                ]),

                _sectionLabel('My voice'),
                _card(children: [
                  Row(children: [
                    Icon(Icons.record_voice_over_rounded,
                        color: Neon.textHi, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Voice ID',
                              style: TextStyle(
                                  color: Neon.textHi,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 1),
                          Text(
                            _voiceEnrolled
                                ? 'Enrolled. Stays on this phone — nothing '
                                    'is uploaded.'
                                : 'Record once so the assistant answers '
                                    'only you.',
                            style: TextStyle(
                                color: Neon.textDim,
                                fontSize: 12,
                                height: 1.35),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _enrolling ? null : _enrollVoice,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Neon.cyan,
                        side: BorderSide(
                            color: Neon.cyan.withValues(alpha: 0.5)),
                      ),
                      child: Text(_enrolling
                          ? 'Listening…'
                          : (_voiceEnrolled ? 'Re-record' : 'Enroll')),
                    ),
                  ]),
                  if (_voiceEnrolled) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(
                        child: Text(
                          'Respond only to my voice',
                          style:
                              TextStyle(color: Neon.textHi, fontSize: 13.5),
                        ),
                      ),
                      Switch(
                        value: _voiceGateOn,
                        activeThumbColor: Neon.cyan,
                        onChanged: (v) async {
                          HapticFeedback.selectionClick();
                          setState(() => _voiceGateOn = v);
                          await VoiceIdService.instance.setEnabled(v);
                        },
                      ),
                    ]),
                    Text(
                      'Asking for live translation lets everyone be heard '
                      'until you stop it.',
                      style: TextStyle(color: Neon.textDim, fontSize: 11.5),
                    ),
                  ],
                ]),

                if (_faces.isNotEmpty) ...[
                  _sectionLabel('Video avatar'),
                  _card(children: [
                    InkWell(
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
                      child: Row(children: [
                        Icon(Icons.face_retouching_natural_rounded,
                            color: Neon.textHi, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Avatar face',
                              style: TextStyle(
                                  color: Neon.textHi, fontSize: 14.5)),
                        ),
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
                      ]),
                    ),
                  ]),
                ],

                _sectionLabel('Your avatar identity'),
                _card(children: [
                  InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AvatarIdentityScreen()),
                    ),
                    child: Row(children: [
                      Icon(Icons.record_voice_over_rounded,
                          color: Neon.textHi, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Send messages as you',
                                style: TextStyle(
                                    color: Neon.textHi, fontSize: 14.5)),
                            const SizedBox(height: 1),
                            Text(
                                'Your face and voice on messages you send '
                                '— with your consent.',
                                style: TextStyle(
                                    color: Neon.textDim, fontSize: 12)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          color: Neon.textDim, size: 20),
                    ]),
                  ),
                ]),

                _sectionLabel('Standing rules'),
                Text(
                  'Permanent instructions the assistant follows before every '
                  'decision — e.g. "Always ask before sending messages", '
                  '"Call me Dhanu". You can also just say these in '
                  'conversation.',
                  style: TextStyle(color: Neon.textDim, fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                ..._rules.map((r) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Neon.surface,
                        border: Border.all(color: Neon.line),
                      ),
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
                    )),
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
                      icon: Icon(Icons.add_circle_rounded,
                          color: Neon.textHi)),
                ]),

                _sectionLabel('About & legal'),
                _card(children: [
                  _legalLink('Privacy Policy', '/legal/privacy'),
                  const Divider(height: 18),
                  _legalLink('Terms & Conditions', '/legal/terms'),
                ]),
              ],
            ),
    );
  }

  Widget _voiceCard(String id, String title, String tagline) {
    final selected = _voice == id;
    return GestureDetector(
      onTap: () => _pickVoice(id),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? Neon.textHi.withValues(alpha: 0.05)
              : Neon.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Neon.textHi : Neon.line,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title,
                      style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 13.5,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                      )),
                  const SizedBox(height: 2),
                  Text(tagline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Neon.textDim, fontSize: 10.5)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_circle_rounded,
                  color: Neon.textHi, size: 17),
          ],
        ),
      ),
    );
  }

  String _faceName(String id) {
    if (id.isEmpty) return 'Default';
    final f = _faces.firstWhere((m) => m['id'] == id, orElse: () => const {});
    return (f['name'] as String?) ?? 'Custom';
  }

  Widget _legalLink(String label, String path) => InkWell(
        onTap: () => launchUrl(Uri.parse('${ApiService.baseUrl}$path'),
            mode: LaunchMode.externalApplication),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(color: Neon.textHi, fontSize: 14))),
          Icon(Icons.open_in_new_rounded,
              size: 16, color: Neon.textDim),
        ]),
      );

  Widget _sectionLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: Neon.textDim, fontSize: 11, letterSpacing: 1.2)),
      );

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Neon.surface,
          border: Border.all(color: Neon.line),
        ),
        child: Column(children: children),
      );

  InputDecoration _dec(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Neon.textLo),
        hintStyle: TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Neon.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
      );
}

/// ─────────────────────────────────────────────────────────────────────────
///  DAY/NIGHT SWITCH — a little sky you tap. Light: pale morning with a
///  sun. Dark: ink night with a moon and stars. The knob drifts across
///  like the hours passing. Pure ornament wrapped around one boolean.
/// ─────────────────────────────────────────────────────────────────────────
class _DayNightSwitch extends StatelessWidget {
  const _DayNightSwitch();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeController.dark,
      builder: (_, dark, __) => GestureDetector(
        onTap: () {
          HapticFeedback.mediumImpact();
          ThemeController.toggle();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          width: 64,
          height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(100),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xFF141A33), Color(0xFF0B0D18)]
                  : const [Color(0xFFBFDFFF), Color(0xFFE8F3FF)],
            ),
            border: Border.all(color: Neon.line),
          ),
          child: Stack(
            children: [
              // Stars come out at night.
              for (final (dx, dy, s) in const [
                (0.22, 0.30, 2.0),
                (0.38, 0.62, 1.5),
                (0.30, 0.18, 1.2),
              ])
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: dark ? 0.9 : 0.0,
                  child: Align(
                    alignment: Alignment(dx * 2 - 1, dy * 2 - 1),
                    child: Container(
                      width: s,
                      height: s,
                      decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                    ),
                  ),
                ),
              AnimatedAlign(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                alignment:
                    dark ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dark
                          ? const Color(0xFFE8EAF6)
                          : const Color(0xFFFFC531),
                      boxShadow: [
                        BoxShadow(
                          color: (dark
                                  ? const Color(0xFFE8EAF6)
                                  : const Color(0xFFFFB020))
                              .withValues(alpha: 0.45),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    child: dark
                        ? const Icon(Icons.nightlight_round,
                            size: 15, color: Color(0xFF141A33))
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
