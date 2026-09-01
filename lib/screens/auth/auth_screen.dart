import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/neon_tokens.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';

/// First screen of the app when signed out.
///
/// Deliberately STANDARD: a plain ground, a left-aligned headline, theme
/// text fields, one solid primary button. No parallax, no glass, no
/// gradients — trust is built by looking like every serious product the
/// user already signs into, not by decoration.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _isSignUp = false;
  String? _gender; // male | female | other — picked on sign-up
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      HapticFeedback.lightImpact();
      // Success: AuthGate rebuilds via AuthService listener — nothing to do.
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submitEmail() {
    if (!_formKey.currentState!.validate()) return;
    final auth = AuthService.instance;
    _run(() => _isSignUp
        ? auth.signUp(
            email: _email.text.trim(),
            password: _password.text,
            name: _name.text.trim().isEmpty ? null : _name.text.trim(),
            gender: _gender,
          )
        : auth.logIn(email: _email.text.trim(), password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;

    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        child: Stack(children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Simple solid mark. No motion, no glow. Align keeps
                      // it 54px — the stretched column would inflate it.
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
                        _isSignUp ? 'Create your account' : 'Welcome back',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: Neon.textHi,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isSignUp
                            ? 'Your personal assistant, everywhere you go.'
                            : 'Sign in to continue.',
                        style: const TextStyle(
                            color: Neon.textLo, fontSize: 14.5, height: 1.4),
                      ),
                      const SizedBox(height: 28),

                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        child: _isSignUp
                            ? Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  TextFormField(
                                    controller: _name,
                                    textInputAction: TextInputAction.next,
                                    textCapitalization:
                                        TextCapitalization.words,
                                    decoration: const InputDecoration(
                                      labelText: 'Your name',
                                      prefixIcon:
                                          Icon(Icons.person_outline_rounded),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  // Gender — personalizes the assistant.
                                  Row(
                                    children: [
                                      for (final g in const [
                                        ('male', 'Male', Icons.male_rounded),
                                        ('female', 'Female',
                                            Icons.female_rounded),
                                        ('other', 'Other',
                                            Icons.transgender_rounded),
                                      ]) ...[
                                        Expanded(
                                          child: _GenderChip(
                                            label: g.$2,
                                            icon: g.$3,
                                            selected: _gender == g.$1,
                                            onTap: () => setState(() =>
                                                _gender = _gender == g.$1
                                                    ? null
                                                    : g.$1),
                                          ),
                                        ),
                                        if (g.$1 != 'other')
                                          const SizedBox(width: 8),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (t.isEmpty ||
                              !t.contains('@') ||
                              !t.contains('.')) {
                            return 'Enter a valid email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _busy ? null : _submitEmail(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(_obscure
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                          ),
                        ),
                        validator: (v) {
                          if ((v ?? '').isEmpty) return 'Enter your password';
                          if (_isSignUp && v!.length < 8) {
                            return 'At least 8 characters';
                          }
                          return null;
                        },
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Neon.error.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Neon.error.withValues(alpha: 0.35)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  color: Neon.error, size: 19),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(_error!,
                                    style: const TextStyle(
                                        color: Neon.error,
                                        fontSize: 13.5,
                                        height: 1.3)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submitEmail,
                        style: FilledButton.styleFrom(
                            backgroundColor: Neon.textHi),
                        child: _busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.2, color: Colors.white),
                              )
                            : Text(_isSignUp ? 'Create account' : 'Log in'),
                      ),

                      const SizedBox(height: 24),
                      const Row(
                        children: [
                          Expanded(child: Divider()),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: Text('or continue with',
                                style: TextStyle(
                                    color: Neon.textDim, fontSize: 12.5)),
                          ),
                          Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 18),

                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () =>
                                _run(AuthService.instance.signInWithGoogle),
                        icon: const _GoogleG(),
                        label: const Text('Continue with Google'),
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Neon.surface,
                          side: BorderSide(color: Neon.line),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                      if (auth.appleAvailable) ...[
                        const SizedBox(height: 10),
                        SignInWithAppleButton(
                          onPressed: () {
                            if (!_busy) {
                              _run(AuthService.instance.signInWithApple);
                            }
                          },
                          height: 48,
                          style: SignInWithAppleButtonStyle.white,
                        ),
                      ],

                      const SizedBox(height: 20),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                  _isSignUp = !_isSignUp;
                                  _error = null;
                                }),
                        child: Text(
                          _isSignUp
                              ? 'Already have an account? Log in'
                              : 'New here? Create an account',
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Consent by continuing — the standard store pattern:
                      // shown BEFORE any account exists, both documents one
                      // tap away.
                      Text.rich(
                        TextSpan(
                          text: 'By continuing you agree to our ',
                          style: const TextStyle(
                            color: Neon.textDim,
                            fontSize: 11.5,
                            height: 1.5,
                          ),
                          children: [
                            TextSpan(
                              text: 'Terms',
                              style: const TextStyle(
                                  color: Neon.textHi,
                                  decoration: TextDecoration.underline),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => launchUrl(
                                    Uri.parse(
                                        '${ApiService.baseUrl}/legal/terms'),
                                    mode: LaunchMode.externalApplication),
                            ),
                            const TextSpan(text: ' and '),
                            TextSpan(
                              text: 'Privacy Policy',
                              style: const TextStyle(
                                  color: Neon.textHi,
                                  decoration: TextDecoration.underline),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => launchUrl(
                                    Uri.parse(
                                        '${ApiService.baseUrl}/legal/privacy'),
                                    mode: LaunchMode.externalApplication),
                            ),
                            const TextSpan(text: '.'),
                          ],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Simple multicolour "G" so we don't ship a copyrighted asset.
class _GoogleG extends StatelessWidget {
  const _GoogleG();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'G',
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w800,
        color: Color(0xFF4285F4),
      ),
    );
  }
}

/// Small selectable pill for the sign-up gender row.
class _GenderChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _GenderChip(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color:
              selected ? Neon.textHi.withValues(alpha: 0.06) : Neon.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? Neon.textHi : Neon.line,
              width: selected ? 1.4 : 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 16, color: selected ? Neon.textHi : Neon.textLo),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? Neon.textHi : Neon.textLo)),
          ],
        ),
      ),
    );
  }
}
