import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ONBOARDING SURVEY — the first-run "getting to know you" screen.
///
///  Collects: name, location, gender, interests. One POST to
///  /profile/survey stores name+gender on the account and turns location
///  + interests into agent MEMORIES — so from the very first
///  conversation, every agent (voice loop, chat, the face) already
///  knows the user. Gender also drives the opposite-gender avatar.
///
///  Gating: SurveyGate.needed() is true until the survey has been
///  completed once (per signed-in account, tracked locally).
/// ─────────────────────────────────────────────────────────────────────────
class SurveyGate {
  static const _key = 'survey_done_v1';

  static Future<bool> needed() async {
    final p = await SharedPreferences.getInstance();
    final uid = AuthService.instance.user?.id ?? 'anon';
    return !(p.getBool('$_key:$uid') ?? false);
  }

  static Future<void> markDone() async {
    final p = await SharedPreferences.getInstance();
    final uid = AuthService.instance.user?.id ?? 'anon';
    await p.setBool('$_key:$uid', true);
  }
}

class SurveyScreen extends StatefulWidget {
  const SurveyScreen({super.key});

  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen> {
  final _name = TextEditingController(
      text: AuthService.instance.user?.name ?? '');
  final _location = TextEditingController();
  String? _gender = AuthService.instance.user?.gender;
  final Set<String> _picked = {};
  bool _saving = false;

  static const _interests = [
    'Music', 'Movies', 'Cricket', 'Food & cooking', 'Travel',
    'Fitness', 'Technology', 'Studies', 'Business', 'Devotional',
    'Fashion', 'Gaming',
  ];

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please tell me your name.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final r = await http
          .post(
            Uri.parse('${ApiService.baseUrl}/profile/survey'),
            headers: {
              'Content-Type': 'application/json',
              if (ApiService.sessionToken != null)
                'Authorization': 'Bearer ${ApiService.sessionToken}',
            },
            body: jsonEncode({
              'name': name,
              'location': _location.text.trim(),
              'gender': _gender,
              'preferences': _picked.toList(),
            }),
          )
          .timeout(const Duration(seconds: 12));
      AppLog.add('survey', 'submit HTTP ${r.statusCode}');
      if (r.statusCode == 200) {
        await AuthService.instance.refreshUser();
      }
      // Even on failure, don't trap the user at onboarding — the
      // assistant learns everything in conversation anyway.
      await SurveyGate.markDone();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      AppLog.add('survey', 'submit failed: $e');
      await SurveyGate.markDone();
      if (mounted) Navigator.of(context).pop(false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          children: [
            const Text('Let me get to know you',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text(
                'A few quick things — so your assistant feels like she already knows you.',
                style: TextStyle(color: AppColors.mist, fontSize: 14.5)),
            const SizedBox(height: 26),
            _label('Your name'),
            _field(_name, hint: 'e.g. Dhanu'),
            const SizedBox(height: 18),
            _label('Where do you live?'),
            _field(_location, hint: 'e.g. Mysuru'),
            const SizedBox(height: 18),
            _label('You are'),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final g in const ['male', 'female', 'other']) ...[
                  ChoiceChip(
                    label: Text(g[0].toUpperCase() + g.substring(1)),
                    selected: _gender == g,
                    selectedColor: AppColors.marigold,
                    labelStyle: TextStyle(
                        color: _gender == g ? Colors.black : AppColors.mist),
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    onSelected: (_) => setState(() => _gender = g),
                  ),
                  const SizedBox(width: 10),
                ],
              ],
            ),
            const SizedBox(height: 18),
            _label('What do you enjoy? (pick any)'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final i in _interests)
                  FilterChip(
                    label: Text(i),
                    selected: _picked.contains(i),
                    selectedColor: AppColors.marigold,
                    labelStyle: TextStyle(
                        color: _picked.contains(i)
                            ? Colors.black
                            : AppColors.mist),
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    onSelected: (v) => setState(
                        () => v ? _picked.add(i) : _picked.remove(i)),
                  ),
              ],
            ),
            const SizedBox(height: 30),
            SizedBox(
              height: 52,
              child: FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.marigold),
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? 'Saving…' : "Let's begin",
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.black)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String t) => Text(t,
      style: const TextStyle(
          color: AppColors.mist, fontWeight: FontWeight.w600, fontSize: 14));

  Widget _field(TextEditingController c, {String? hint}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextField(
          controller: c,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none),
          ),
        ),
      );
}
