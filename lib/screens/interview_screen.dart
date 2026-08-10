import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../services/voice_service.dart';
import '../theme/app_theme.dart';

/// SIGN-UP INTERVIEW — shown exactly once, right after a NEW account is
/// created, before the home shell. Hari asks a few friendly questions
/// aloud, listens for each answer (editable as text too), and every
/// answer is fed to the backend where the memory extractor turns it into
/// durable facts — so the assistant is personal from minute one.
///
/// Fully skippable: "Skip" per question, "Skip all" in the corner.
class InterviewScreen extends StatefulWidget {
  final VoidCallback onDone;
  const InterviewScreen({super.key, required this.onDone});

  @override
  State<InterviewScreen> createState() => _InterviewScreenState();
}

class _Q {
  final String spoken; // what Hari says (TTS)
  final String hint; // text-field hint
  const _Q(this.spoken, this.hint);
}

class _InterviewScreenState extends State<InterviewScreen> {
  static const _questions = [
    _Q("Hi, I'm Hari — so nice to meet you! First things first: what should I call you?",
        'Your name or nickname'),
    _Q('Which city do you live in?', 'e.g. Mysuru'),
    _Q('And what do you do — do you work, or study? What field?',
        'e.g. engineering student, teacher, shop owner…'),
    _Q('Last one! Tell me a few things you love — food, music, a sports team, anything I should remember.',
        'e.g. masala dosa, RCB, old Kannada songs'),
  ];

  final _voice = VoiceService.instance;
  final _answer = TextEditingController();

  int _index = 0;
  bool _listening = false;
  bool _saving = false;
  bool _done = false;
  double _level = 0;

  /// Server-flagged: offer the first meeting FACE TO FACE (D-ID avatar).
  /// The classic voice interview stays as the fallback either way.

  @override
  void initState() {
    super.initState();
    _startQuestion();
    // Non-blocking: light up the face-to-face invite once the server
    // confirms Face Mode is configured (feature flag + D-ID key).
  }

  @override
  void dispose() {
    _voice.stopSpeaking();
    _voice.cancelCapture();
    _answer.dispose();
    super.dispose();
  }

  _Q get _q => _questions[_index];

  /// Speak the question, then open the mic for the answer.
  Future<void> _startQuestion() async {
    _answer.clear();
    await _voice.init();
    if (!mounted) return;
    await _voice.speak(_q.spoken);
    if (!mounted || _done) return;
    _listen();
  }

  /// Capture one spoken answer. Cloud Whisper first (any language),
  /// device recognizer as fallback — same strategy as the main loop.
  Future<void> _listen() async {
    if (_listening || !_voice.isReady) return;
    setState(() => _listening = true);

    String heard = '';
    if (await _voice.canRecord()) {
      final path = await _voice.recordUntilSilence(
        onLevel: (l) => mounted ? setState(() => _level = l) : null,
      );
      if (path != null) {
        try {
          heard = await ApiService.transcribe(path);
        } catch (_) {}
      }
      if (heard.isEmpty && !_voice.lastRecordingCancelled) {
        heard = await _voice.captureQuestion(
          onLevel: (l) => mounted ? setState(() => _level = l) : null,
        );
      }
    } else {
      heard = await _voice.captureQuestion(
        onLevel: (l) => mounted ? setState(() => _level = l) : null,
      );
    }

    if (!mounted) return;
    setState(() {
      _listening = false;
      _level = 0;
      // Never overwrite something the user already typed.
      if (heard.isNotEmpty && _answer.text.trim().isEmpty) {
        _answer.text = heard;
      }
    });
  }

  Future<void> _next({required bool skip}) async {
    HapticFeedback.selectionClick();
    await _voice.cancelCapture();
    final text = _answer.text.trim();

    if (!skip && text.isNotEmpty) {
      setState(() => _saving = true);
      try {
        await ApiService.submitInterviewAnswer(_q.spoken, text);
      } catch (_) {
        // Losing one onboarding fact is not worth blocking the user.
      }
      if (!mounted) return;
      setState(() => _saving = false);
    }

    if (_index + 1 < _questions.length) {
      setState(() => _index++);
      _startQuestion();
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    if (_done) return;
    _done = true;
    await _voice.cancelCapture();
    if (mounted) setState(() {});
    await _voice.speak("Lovely — thank you! Let's get started.");
    widget.onDone();
  }

  Future<void> _skipAll() async {
    _done = true;
    await _voice.stopSpeaking();
    await _voice.cancelCapture();
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = cs.onSurface.withValues(alpha: 0.6);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [

              // Top bar: progress dots + Skip all
              Row(
                children: [
                  for (var i = 0; i < _questions.length; i++)
                    Container(
                      width: 22,
                      height: 5,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: i <= _index
                            ? AppColors.peacock
                            : cs.onSurface.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: _skipAll,
                    child: Text('Skip all', style: TextStyle(color: muted)),
                  ),
                ],
              ),
              const Spacer(),

              // Mic indicator — pulses with the user's voice.
              Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  width: 86 + _level * 30,
                  height: 86 + _level * 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      center: Alignment(-0.3, -0.4),
                      colors: [AppColors.peacockLight, AppColors.peacockDeep],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.peacock
                            .withValues(alpha: 0.35 + _level * 0.3),
                        blurRadius: 34 + _level * 26,
                      ),
                    ],
                  ),
                  child: Icon(
                    _listening ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
              const SizedBox(height: 28),

              Text(
                'Getting to know you',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: AppColors.marigold,
                ),
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _q.spoken,
                  key: ValueKey(_index),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        height: 1.35,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _listening
                    ? "I'm listening — or just type below"
                    : 'Tap the mic to answer by voice, or type',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: muted),
              ),
              const SizedBox(height: 20),

              TextField(
                controller: _answer,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _next(skip: false),
                decoration: InputDecoration(
                  hintText: _q.hint,
                  suffixIcon: IconButton(
                    tooltip: 'Answer by voice',
                    icon: Icon(
                      Icons.mic_rounded,
                      color: _listening ? AppColors.marigold : cs.primary,
                    ),
                    onPressed: _listening ? null : _listen,
                  ),
                ),
              ),
              const Spacer(),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => _next(skip: true),
                      child: const Text('Skip'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _saving ? null : () => _next(skip: false),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : Text(_index + 1 < _questions.length
                              ? 'Next'
                              : 'Finish'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }
}
