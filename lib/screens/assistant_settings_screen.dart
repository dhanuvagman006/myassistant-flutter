import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/neon_tokens.dart';
import '../design/theme_controller.dart';
import '../services/api_service.dart';
import '../services/assistant_identity.dart';
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
    final p = await ApiService.getJson('/profile/full');
    final r = await ApiService.getJson('/profile/instructions');
    final f = await ApiService.getJson('/live/avatar/faces');
    if (!mounted) return;
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
