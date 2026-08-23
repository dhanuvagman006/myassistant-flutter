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

  // Conversational onboarding (§3): one free-text box that the backend
  // turns into structured fields, so nobody is forced through a form.
  final _aboutMe = TextEditingController();
  final _profession = TextEditingController();
  final _phoneNumber = TextEditingController();
  final _organisation = TextEditingController();
  bool _extracting = false;
  String? _extractNote;
  String? _gender = AuthService.instance.user?.gender;
  DateTime? _birthday;
  final Set<String> _picked = {};
  bool _saving = false;

  static const _interests = [
    'Music', 'Movies', 'Cricket', 'Food & cooking', 'Travel',
    'Fitness', 'Technology', 'Studies', 'Business', 'Devotional',
    'Fashion', 'Gaming', 'Astrology & Horoscope',
  ];

  String? get _birthdayString {
    if (_birthday == null) return null;
    final y = _birthday!.year.toString().padLeft(4, '0');
    final m = _birthday!.month.toString().padLeft(2, '0');
    final d = _birthday!.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1920),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: AppColors.marigold,
              onPrimary: Colors.black,
              surface: Color(0xFF1E2230),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _birthday = picked);
    }
  }

  Future<void> _saveDetails() async {
    // Optional fields — sent only when present; skipping is first-class.
    final body = {
      if (_profession.text.trim().isNotEmpty)
        'profession': _profession.text.trim(),
      if (_phoneNumber.text.trim().isNotEmpty)
        'phone_number': _phoneNumber.text.trim(),
      if (_organisation.text.trim().isNotEmpty)
        'organisation': _organisation.text.trim(),
      if (_location.text.trim().isNotEmpty)
        'location': _location.text.trim(),
      if (_birthdayString != null)
        'birthday': _birthdayString,
    };
    if (body.isEmpty) return;
    await ApiService.sendJson('/profile/details', method: 'PUT', body: body);
  }

  /// "Just tell me about yourself" — sends the free text to the backend,
  /// which extracts structured fields and reports exactly what it applied.
  Future<void> _extractFromText() async {
    final text = _aboutMe.text.trim();
    if (text.isEmpty) return;
    setState(() { _extracting = true; _extractNote = null; });
    final r = await ApiService.sendJson('/profile/conversational',
        method: 'POST', body: {'text': text});
    if (!mounted) return;
    setState(() {
      _extracting = false;
      if (r == null) {
        _extractNote = "Couldn't reach the server — you can fill the fields instead.";
        return;
      }
      final applied = (r['applied'] as Map?) ?? {};
      if (applied.isEmpty) {
        _extractNote = (r['error'] as String?) ??
            'Nothing recognised — try the fields below.';
        return;
      }
      // Reflect what the server understood back into the form, honestly.
      if (applied['name'] is String) _name.text = applied['name'];
      if (applied['location'] is String) _location.text = applied['location'];
      if (applied['profession'] is String) {
        _profession.text = applied['profession'];
      }
      if (applied['organisation'] is String) {
        _organisation.text = applied['organisation'];
      }
      _extractNote = 'Got it: ${applied.keys.join(', ')}.';
    });
  }

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
              'birthday': _birthdayString,
              'preferences': _picked.toList(),
            }),
          )
          .timeout(const Duration(seconds: 12));
      AppLog.add('survey', 'submit HTTP ${r.statusCode}');
      await _saveDetails();
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
    _aboutMe.dispose();
    _profession.dispose();
    _phoneNumber.dispose();
    _organisation.dispose();
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
            // CONVERSATIONAL PATH — speak/type naturally instead of forms.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.white.withValues(alpha: 0.05),
                border:
                    Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Or just tell me about yourself',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _aboutMe,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText:
                          "e.g. I'm Dhanush, a software engineer in Mangalore working on AI systems.",
                      hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 13),
                      border: InputBorder.none,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _extracting
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : TextButton(
                            onPressed: _extractFromText,
                            child: const Text('Understand me')),
                  ),
                  if (_extractNote != null)
                    Text(_extractNote!,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _field(_location, hint: 'e.g. Mysuru'),
            const SizedBox(height: 14),
            _label('Date of birth (for daily astrology & lucky insights)'),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _pickBirthday,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withValues(alpha: 0.06),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome_rounded,
                        color: AppColors.marigold, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _birthday == null
                            ? 'Select your birthday (e.g. 15 Aug 1998)'
                            : '${_birthday!.day} / ${_birthday!.month} / ${_birthday!.year}',
                        style: TextStyle(
                          color: _birthday == null
                              ? Colors.white.withValues(alpha: 0.35)
                              : Colors.white,
                          fontSize: 14.5,
                          fontWeight: _birthday == null
                              ? FontWeight.normal
                              : FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.calendar_month_rounded,
                        color: Colors.white.withValues(alpha: 0.6), size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            _field(_phoneNumber, hint: 'Phone Number (for messages)'),
            const SizedBox(height: 12),
            _field(_profession, hint: 'Profession (optional)'),
            const SizedBox(height: 10),
            _field(_organisation, hint: 'Company / organisation (optional)'),
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
