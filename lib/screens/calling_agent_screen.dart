import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';

/// YOUR CALLING AGENT — how the assistant sounds when it rings someone
/// for you.
///
/// His ask, 2026-09-20: "give a free hand for the user to select how
/// their calling agent should speak and how it should sound… and show how
/// much it may cost per minute so we can charge accordingly."
///
/// What is here is what a person can meaningfully choose: character,
/// voice, language and how sharp it should be. What is NOT here is the
/// latency and interruption tuning from the provider's dashboard — those
/// are correctness settings, not preferences, and a user who sets them
/// wrong has not customised their agent, they have broken it.
class CallingAgentScreen extends StatefulWidget {
  const CallingAgentScreen({super.key});

  @override
  State<CallingAgentScreen> createState() => _CallingAgentScreenState();
}

class _CallingAgentScreenState extends State<CallingAgentScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _saving = false;

  late String _character, _voice, _brain, _language;
  final _persona = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _persona.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await ApiService.getJson('/calling-agent');
      if (r == null) throw Exception('empty');
      if (!mounted) return;
      final cur = (r['current'] as Map).cast<String, dynamic>();
      setState(() {
        _data = r;
        _error = null;
        _character = (cur['character'] ?? 'polite').toString();
        _voice = (cur['voice'] ?? 'monika').toString();
        _brain = (cur['brain'] ?? 'balanced').toString();
        _language = (cur['language'] ?? 'hi').toString();
        _persona.text = (cur['persona'] ?? '').toString();
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Calling is not set up on this account yet, or it could not be '
            'loaded. Pull down to try again.');
      }
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    HapticFeedback.selectionClick();
    final r = await ApiService.sendJson('/calling-agent', method: 'PUT', body: {
      'character': _character,
      'voice': _voice,
      'brain': _brain,
      'language': _language,
      'persona': _persona.text.trim(),
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (r == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't save — your calling agent is unchanged."),
      ));
      return;
    }
    setState(() => _data = r);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Saved. Your next call uses it.'),
    ));
  }

  /// The cost shown small at the bottom, recomputed from the chosen brain
  /// so it moves as the user changes their mind — not a fixed label.
  double get _costPerMin {
    final d = _data;
    if (d == null) return 0;
    final base = ((d['cost']?['total'] as num?) ?? 0).toDouble();
    final brains = (d['brains'] as List?) ?? const [];
    final chosen = brains.whereType<Map>().firstWhere(
        (b) => b['id'] == _brain, orElse: () => const {});
    final current = (d['current'] as Map?)?['brain'];
    final was = brains.whereType<Map>().firstWhere(
        (b) => b['id'] == current, orElse: () => const {});
    final delta = ((chosen['costPerMin'] as num?)?.toDouble() ?? 0) -
        ((was['costPerMin'] as num?)?.toDouble() ?? 0);
    return base + delta;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
          backgroundColor: Neon.bg, title: const Text('Your calling agent')),
      body: _data == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : _errorView())
          : RefreshIndicator(
              onRefresh: _load,
              color: Neon.violet,
              backgroundColor: Neon.surface,
              child: _form(),
            ),
      bottomNavigationBar: _data == null ? null : _bottomBar(),
    );
  }

  Widget _errorView() => ListView(
        padding: const EdgeInsets.fromLTRB(24, 90, 24, 24),
        children: [
          Icon(Icons.phone_disabled_rounded, size: 38, color: Neon.textDim),
          const SizedBox(height: 14),
          Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5)),
        ],
      );

  Widget _form() {
    final d = _data!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _intro(),
        _section('Character', 'How it behaves on the call'),
        for (final c in (d['characters'] as List).whereType<Map>())
          _choice(
            selected: _character == c['id'],
            title: (c['label'] ?? '').toString(),
            subtitle: (c['hint'] ?? '').toString(),
            onTap: () => setState(() => _character = c['id'].toString()),
          ),
        _section('Voice', 'How it sounds'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in (d['voices'] as List).whereType<Map>())
              _chip(
                selected: _voice == v['id'],
                label: (v['label'] ?? '').toString(),
                sub: [v['gender'], v['accent']]
                    .where((x) => (x ?? '').toString().isNotEmpty)
                    .join(' · '),
                onTap: () => setState(() => _voice = v['id'].toString()),
              ),
          ],
        ),
        _section('Language', 'What it should understand on the call'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final l in (d['languages'] as List).whereType<Map>())
              _chip(
                selected: _language == l['id'],
                label: (l['label'] ?? '').toString(),
                sub: (l['hint'] ?? '').toString(),
                onTap: () => setState(() => _language = l['id'].toString()),
              ),
          ],
        ),
        _section('How sharp', 'Slower thinking handles awkward calls better'),
        for (final b in (d['brains'] as List).whereType<Map>())
          _choice(
            selected: _brain == b['id'],
            title: (b['label'] ?? '').toString(),
            subtitle: (b['hint'] ?? '').toString(),
            trailing:
                '\$${((b['costPerMin'] as num?)?.toDouble() ?? 0).toStringAsFixed(3)}/min',
            onTap: () => setState(() => _brain = b['id'].toString()),
          ),
        _section('Anything else it should know',
            'Optional — spoken in every call it makes for you'),
        Container(
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Neon.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: TextField(
            controller: _persona,
            maxLines: 4,
            maxLength: 600,
            style: TextStyle(color: Neon.textHi, fontSize: 14, height: 1.4),
            decoration: InputDecoration(
              border: InputBorder.none,
              counterStyle: TextStyle(color: Neon.textDim, fontSize: 11),
              hintText:
                  'e.g. "Always mention I am calling from Shetty Clinic" or '
                  '"Never discuss money on the phone"',
              hintStyle: TextStyle(color: Neon.textDim, fontSize: 13.5, height: 1.4),
            ),
          ),
        ),
      ],
    );
  }

  Widget _intro() => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Text(
          'This is the assistant that rings people for you — when you say '
          '"call Ravi and tell him I\'ll be late". It does not change how '
          'the assistant talks to you in the app.',
          style: TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.45),
        ),
      );

  Widget _section(String title, String sub) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(sub, style: TextStyle(color: Neon.textDim, fontSize: 12.5)),
          ],
        ),
      );

  Widget _choice({
    required bool selected,
    required String title,
    required String subtitle,
    String? trailing,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: selected ? Neon.violet.withValues(alpha: 0.12) : Neon.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: selected ? Neon.violet : Neon.line,
                    width: selected ? 1.4 : 1),
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    size: 19,
                    color: selected ? Neon.violet : Neon.textDim,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: TextStyle(
                                color: Neon.textHi,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600)),
                        if (subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(subtitle,
                              style: TextStyle(
                                  color: Neon.textLo, fontSize: 12.5, height: 1.3)),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null)
                    Text(trailing,
                        style: TextStyle(color: Neon.textDim, fontSize: 11.5)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _chip({
    required bool selected,
    required String label,
    required String sub,
    required VoidCallback onTap,
  }) =>
      Material(
        color: selected ? Neon.violet.withValues(alpha: 0.14) : Neon.surface,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color: selected ? Neon.violet : Neon.line,
                  width: selected ? 1.4 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
                if (sub.isNotEmpty)
                  Text(sub,
                      style: TextStyle(color: Neon.textDim, fontSize: 10.5)),
              ],
            ),
          ),
        ),
      );

  Widget _bottomBar() => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // THE NUMBER HE ASKED FOR, small and honest. It is an
                    // estimate: what a call really costs also depends on
                    // how long the other person talks.
                    Text('~\$${_costPerMin.toStringAsFixed(3)} per minute',
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    Text('estimate — a call is billed by the minute it runs',
                        style:
                            TextStyle(color: Neon.textDim, fontSize: 10.5)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: Neon.violet),
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      );
}
