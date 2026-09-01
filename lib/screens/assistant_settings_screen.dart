import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/widgets/assistant_persona.dart';
import '../services/api_service.dart';
import 'avatar_face_screen.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ASSISTANT SETTINGS (§4, §14, §28) — who the assistant is, how it
///  speaks, and the user's standing rules.
///
///  Everything here writes through the SAME backend the agent reads from
///  (assistant_profiles + user_instructions), so a change made here is in
///  the very next turn's context — there is no second configuration store.
/// ─────────────────────────────────────────────────────────────────────────
class AssistantSettingsScreen extends StatefulWidget {
  const AssistantSettingsScreen({super.key});

  @override
  State<AssistantSettingsScreen> createState() =>
      _AssistantSettingsScreenState();
}

class _AssistantSettingsScreenState extends State<AssistantSettingsScreen> {
  final _name = TextEditingController();
  String _gender = '';
  String _voice = '';
  String _style = '';
  String _avatarId = ''; // '' = deployment default face
  List<Map<String, dynamic>> _faces = const [];
  List<dynamic> _rules = [];
  final _newRule = TextEditingController();
  bool _loading = true;
  bool _saving = false;

  // Voices supported by the existing TTS route.
  static const _voices = ['', 'Kore', 'Puck', 'Charon', 'Aoede', 'Fenrir'];
  static const _styles = ['', 'concise', 'friendly', 'formal'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await ApiService.getJson('/profile/full');
    final r = await ApiService.getJson('/profile/instructions');
    final f = await ApiService.getJson('/live/avatar/faces');
    if (!mounted) return;
    setState(() {
      _loading = false;
      final a = (p?['assistant'] as Map?) ?? {};
      _name.text = (a['name'] as String?) ?? 'Hari';
      _gender = (a['gender'] as String?) ?? '';
      _voice = (a['voice'] as String?) ?? '';
      _style = (a['style'] as String?) ?? '';
      _avatarId = (a['avatar_id'] as String?) ?? '';
      _rules = (r?['instructions'] as List?) ?? [];
      _faces = ((f?['faces'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final r = await ApiService.sendJson('/profile/assistant',
        method: 'PUT',
        body: {
          'name': _name.text.trim(),
          'gender': _gender,
          'voice': _voice,
          'style': _style,
          // '' would mean "keep" server-side; 'default' clears the choice.
          'avatar_id': _avatarId.isEmpty ? 'default' : _avatarId,
        });
    // Keep the local persona (face) in step with the chosen gender.
    if (_gender == 'female') {
      await AssistantPersonaResolver.setPreference(AssistantGender.female);
    } else if (_gender == 'male') {
      await AssistantPersonaResolver.setPreference(AssistantGender.male);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(r == null ? "Couldn't save." : 'Saved.')));
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
      backgroundColor: const Color(0xFF0B0A14),
      appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Assistant')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _sectionLabel('Identity'),
                _card(children: [
                  TextField(
                    controller: _name,
                    style: const TextStyle(color: Colors.white),
                    decoration:
                        _dec('Assistant name', 'e.g. Maya'),
                  ),
                  const SizedBox(height: 12),
                  _dropdown('Presentation', _gender, const {
                    '': 'Automatic (opposite of my profile)',
                    'female': 'Female',
                    'male': 'Male',
                    'neutral': 'Neutral',
                  }, (v) => setState(() => _gender = v)),
                ]),
                _sectionLabel('Voice & style'),
                _card(children: [
                  _dropdown(
                      'Voice',
                      _voice,
                      {for (final v in _voices) v: v.isEmpty ? 'Default' : v},
                      (v) => setState(() => _voice = v)),
                  const SizedBox(height: 12),
                  _dropdown(
                      'Communication style',
                      _style,
                      {
                        for (final v in _styles)
                          v: v.isEmpty ? 'Default' : v[0].toUpperCase() + v.substring(1)
                      },
                      (v) => setState(() => _style = v)),
                ]),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style:
                        FilledButton.styleFrom(backgroundColor: Neon.violet),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? 'Saving…' : 'Save'),
                  ),
                ),
                if (_faces.isNotEmpty) ...[
                  _sectionLabel('Video avatar'),
                  _card(children: [
                    InkWell(
                      onTap: () async {
                        final picked = await Navigator.of(context).push<String>(
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
                        const Icon(Icons.face_retouching_natural_rounded,
                            color: Neon.cyan, size: 20),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text('Avatar face',
                              style: TextStyle(
                                  color: Colors.white, fontSize: 14.5)),
                        ),
                        Text(
                          _faceName(_avatarId),
                          style: const TextStyle(
                              color: Neon.cyan, fontSize: 13.5),
                        ),
                        const SizedBox(width: 6),
                        const Icon(Icons.chevron_right_rounded,
                            color: Colors.white38, size: 20),
                      ]),
                    ),
                  ]),
                ],
                _sectionLabel('Standing rules'),
                Text(
                  'Permanent instructions the assistant follows before every '
                  'decision — e.g. "Always ask before sending messages", '
                  '"Call me Dhanu". You can also just say these in '
                  'conversation.',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 12.5),
                ),
                const SizedBox(height: 10),
                ..._rules.map((r) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.white.withValues(alpha: 0.05),
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.10)),
                      ),
                      child: Row(children: [
                        Expanded(
                            child: Text(r['instruction'] ?? '',
                                style:
                                    const TextStyle(color: Colors.white70))),
                        IconButton(
                          icon: const Icon(Icons.close_rounded,
                              size: 18, color: Colors.white38),
                          onPressed: () => _removeRule(r['id'] as int),
                        ),
                      ]),
                    )),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _newRule,
                      style: const TextStyle(color: Colors.white),
                      decoration: _dec('Add a rule', 'Always…'),
                      onSubmitted: (_) => _addRule(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                      onPressed: _addRule,
                      icon: const Icon(Icons.add_circle_rounded,
                          color: Neon.cyan)),
                ]),
                _sectionLabel('About & legal'),
                _card(children: [
                  _legalLink('Privacy Policy', '/legal/privacy'),
                  const Divider(color: Colors.white12, height: 18),
                  _legalLink('Terms & Conditions', '/legal/terms'),
                ]),
              ],
            ),
    );
  }

  String _faceName(String id) {
    if (id.isEmpty) return 'Default';
    final f = _faces.firstWhere((m) => m['id'] == id, orElse: () => const {});
    return (f['name'] as String?) ?? 'Custom';
  }

  Widget _legalLink(String label, String path) => InkWell(
        onTap: () => launchUrl(
            Uri.parse('${ApiService.baseUrl}$path'),
            mode: LaunchMode.externalApplication),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 14))),
          const Icon(Icons.open_in_new_rounded,
              size: 16, color: Colors.white38),
        ]),
      );

  Widget _sectionLabel(String t) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 11,
                letterSpacing: 1.2)),
      );

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Column(children: children),
      );

  InputDecoration _dec(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white70),
        hintStyle: const TextStyle(color: Colors.white24),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
      );

  Widget _dropdown(String label, String value, Map<String, String> items,
          ValueChanged<String> onChanged) =>
      InputDecorator(
        decoration: _dec(label, ''),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: items.containsKey(value) ? value : '',
            isExpanded: true,
            dropdownColor: const Color(0xFF17162A),
            style: const TextStyle(color: Colors.white),
            items: items.entries
                .map((e) => DropdownMenuItem(
                    value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) => onChanged(v ?? ''),
          ),
        ),
      );
}
