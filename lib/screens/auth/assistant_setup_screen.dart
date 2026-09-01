import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../design/neon_tokens.dart';
import '../../services/api_service.dart';
import '../../services/assistant_identity.dart';
import '../../shell/home_shell.dart';
import '../splash_screen.dart';
import 'guide_screen.dart';
import 'welcome_screen.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  NAME YOUR ASSISTANT — the last step of registration.
///
///  The product has no fixed persona: the user names their assistant, and
///  that name is what every screen shows and what the voice answers to.
///  This step runs ONCE — after sign-up (or the first sign-in of an
///  account that never picked a name) — and can be skipped; the name is
///  editable any time in Settings.
/// ─────────────────────────────────────────────────────────────────────────

/// Decides once whether the naming step is needed, then shows either the
/// setup screen or the home shell. Never blocks the app: any doubt
/// (offline, server hiccup) falls through to home.
class AssistantSetupGate extends StatefulWidget {
  const AssistantSetupGate({super.key});

  @override
  State<AssistantSetupGate> createState() => _AssistantSetupGateState();
}

class _AssistantSetupGateState extends State<AssistantSetupGate> {
  static const _doneKey = 'assistant_named_v1';
  bool? _needed;

  /// True only right after the naming step actually ran — the one moment
  /// that earns the celebration screen. Returning users never see it.
  bool _celebrate = false;

  /// The quick guide that follows the celebration, skippable throughout.
  bool _guide = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    bool needed = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_doneKey) == true) {
        needed = false;
      } else {
        final p = await ApiService.getJson('/profile/full');
        if (p != null) {
          final n =
              (((p['assistant'] as Map?)?['name'] as String?) ?? '').trim();
          // 'Hari' was the old hardcoded default — accounts still carrying
          // it never actually chose a name, so they get the step once too.
          needed = n.isEmpty || n == 'Assistant' || n == 'Hari';
          if (!needed) {
            await prefs.setBool(_doneKey, true);
            await AssistantIdentity.set(n);
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _needed = needed);
  }

  Future<void> _markDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_doneKey, true);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _needed = false;
        _celebrate = true; // fresh onboarding → one welcome moment
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return switch (_needed) {
      null => const SplashScreen(),
      true => AssistantSetupScreen(onDone: _markDone),
      false => _celebrate
          ? WelcomeScreen(
              onDone: () => setState(() {
                    _celebrate = false;
                    _guide = true;
                  }))
          : _guide
              ? GuideScreen(
                  onDone: () => setState(() => _guide = false))
              : const HomeShell(),
    };
  }
}

class AssistantSetupScreen extends StatefulWidget {
  const AssistantSetupScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<AssistantSetupScreen> createState() => _AssistantSetupScreenState();
}

class _AssistantSetupScreenState extends State<AssistantSetupScreen> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  static const _suggestions = ['Maya', 'Aarav', 'Zara', 'Dev', 'Ira', 'Nova'];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final n = _name.text.trim();
    if (n.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await ApiService.sendJson('/profile/assistant',
        method: 'PUT', body: {'name': n});
    if (r == null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't save the name. Check your connection and try again.";
        });
      }
      return;
    }
    await AssistantIdentity.set(n);
    HapticFeedback.lightImpact();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final n = _name.text.trim();

    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: Neon.textHi,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Icon(Icons.auto_awesome_rounded,
                          color: Colors.white, size: 26),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Name your assistant',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Neon.textHi,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Pick any name you like — this is who you\'ll be '
                    'talking to. You can change it anytime in Settings.',
                    style: TextStyle(
                        color: Neon.textLo, fontSize: 14.5, height: 1.45),
                  ),
                  const SizedBox(height: 26),
                  TextField(
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    maxLength: 30,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                    decoration: const InputDecoration(
                      labelText: 'Assistant name',
                      hintText: 'e.g. Maya',
                      counterText: '',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in _suggestions)
                        ActionChip(
                          label: Text(s),
                          backgroundColor: Neon.surface,
                          side: BorderSide(color: Neon.line),
                          onPressed: () {
                            _name.text = s;
                            _name.selection = TextSelection.collapsed(
                                offset: s.length);
                            setState(() {});
                          },
                        ),
                    ],
                  ),
                  // A quiet preview so the choice feels real before saving.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    child: n.isEmpty
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 20),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Neon.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Neon.line),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.graphic_eq_rounded,
                                      color: Neon.textHi, size: 19),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      '“Hi, I\'m $n. How can I help you today?”',
                                      style: const TextStyle(
                                          color: Neon.textLo,
                                          fontSize: 13.5,
                                          fontStyle: FontStyle.italic,
                                          height: 1.35),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(_error!,
                        style:
                            const TextStyle(color: Neon.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: n.isEmpty || _busy ? null : _save,
                    style:
                        FilledButton.styleFrom(backgroundColor: Neon.textHi),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white),
                          )
                        : const Text('Continue'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy ? null : widget.onDone,
                    child: const Text('Skip for now'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
