import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/neon_tokens.dart';
import '../../design/motion.dart';
import '../../design/neon_widgets.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/glow_cta.dart';

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

  /// Explicit consent for account creation — the checkbox must be ticked
  /// before Create account works. Sign-IN keeps the lighter "by
  /// continuing" line; the box guards REGISTRATION.
  bool _agree = false;
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
    if (_isSignUp && !_agree) {
      setState(() => _error =
          'Please accept the Terms and Privacy Policy to create your account.');
      return;
    }
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

    // Under Home's sky from the very first page (2026-09-30).
    return NeonScaffold(
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
                      // The lit brand mark (2026-09-30; it was a flat white
                      // square). Align keeps it 54px — the stretched column
                      // would inflate it.
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: BrandMark(),
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
                        style: TextStyle(
                            color: Neon.textLo, fontSize: 15, height: 1.4),
                      ),
                      const SizedBox(height: 28),

                      // The app's own expand (Collapse, Motion tokens; it
                      // was a raw 200 ms AnimatedSize), and still with
                      // "Remove animations" on.
                      Collapse(
                        open: _isSignUp,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              controller: _name,
                              textInputAction: TextInputAction.next,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                labelText: 'Your name',
                                prefixIcon: Icon(Icons.person_outline_rounded),
                              ),
                              // Mandatory: the assistant addresses the
                              // user by name everywhere; a nameless
                              // account reads broken from minute one.
                              validator: (v) =>
                                  (v == null || v.trim().length < 2)
                                      ? 'Please enter your name'
                                      : null,
                            ),
                            const SizedBox(height: 14),
                            // Gender — personalizes the assistant.
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final g in const [
                                  ('male', 'Male', Icons.male_rounded),
                                  ('female', 'Female', Icons.female_rounded),
                                  ('other', 'Other', Icons.transgender_rounded),
                                ])
                                  ChoiceChip(
                                    avatar: Icon(g.$3,
                                        size: 16,
                                        color: _gender == g.$1
                                            ? Neon.violet
                                            : Neon.textLo),
                                    label: Text(g.$2),
                                    selected: _gender == g.$1,
                                    // The theme's chip: lit rim when
                                    // chosen (2026-09-30).
                                    labelStyle: TextStyle(
                                        fontWeight: _gender == g.$1
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: _gender == g.$1
                                            ? Neon.textHi
                                            : Neon.textLo),
                                    showCheckmark: false,
                                    onSelected: (_) => setState(() => _gender =
                                        _gender == g.$1 ? null : g.$1),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 14),
                          ],
                        ),
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
                            tooltip:
                                _obscure ? 'Show password' : 'Hide password',
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
                            color: Neon.error.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline_rounded,
                                  color: Neon.error, size: 19),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(_error!,
                                    style: TextStyle(
                                        color: Neon.errorInk,
                                        fontSize: 14,
                                        height: 1.3)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // REGISTRATION CONSENT — an explicit box to tick,
                      // with both documents one tap away.
                      if (_isSignUp) ...[
                        const SizedBox(height: 16),
                        InkWell(
                          onTap: () => setState(() {
                            _agree = !_agree;
                            if (_agree) _error = null;
                          }),
                          borderRadius: BorderRadius.circular(10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 24,
                                height: 24,
                                // The theme's checkbox (2026-09-30).
                                child: Checkbox(
                                  value: _agree,
                                  onChanged: (v) => setState(() {
                                    _agree = v ?? false;
                                    if (_agree) _error = null;
                                  }),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    text: 'I have read and accept the ',
                                    style: TextStyle(
                                        color: Neon.textLo,
                                        fontSize: 13,
                                        height: 1.45),
                                    children: [
                                      TextSpan(
                                        text: 'Terms & Conditions',
                                        style: TextStyle(
                                            color: Neon.textHi,
                                            fontWeight: FontWeight.w600,
                                            decoration:
                                                TextDecoration.underline),
                                        recognizer: TapGestureRecognizer()
                                          ..onTap = () => launchUrl(
                                              Uri.parse(
                                                  '${ApiService.baseUrl}/legal/terms'),
                                              mode: LaunchMode
                                                  .externalApplication),
                                      ),
                                      const TextSpan(text: ' and the '),
                                      TextSpan(
                                        text: 'Privacy Policy',
                                        style: TextStyle(
                                            color: Neon.textHi,
                                            fontWeight: FontWeight.w600,
                                            decoration:
                                                TextDecoration.underline),
                                        recognizer: TapGestureRecognizer()
                                          ..onTap = () => launchUrl(
                                              Uri.parse(
                                                  '${ApiService.baseUrl}/legal/privacy'),
                                              mode: LaunchMode
                                                  .externalApplication),
                                      ),
                                      const TextSpan(text: '.'),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      GlowCta(
                        label: _isSignUp ? 'Create account' : 'Log in',
                        busy: _busy,
                        busyLabel: 'Signing in',
                        onPressed: _submitEmail,
                      ),

                      const SizedBox(height: 24),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          // 2026-09-30 visual QA: a loose Flexible(flex: 3)
                          // left its unused share empty at the end, so the
                          // words sat left of centre and the right rule
                          // stopped short. Capped instead of flexed.
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 240),
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              child: Text('or continue with',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: Neon.textLo,
                                      fontSize: NeonType.footnote)),
                            ),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 18),

                      OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(AuthService.instance.signInWithGoogle),
                        icon: const _GoogleG(),
                        label: const Text('Continue with Google'),
                        // Secondary: the theme's rim on the raised surface;
                        // the G keeps Google's own blue.
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Neon.surface,
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
                          style: TextStyle(
                            color: Neon.textLo,
                            fontSize: NeonType.caption,
                            height: 1.5,
                          ),
                          children: [
                            TextSpan(
                              text: 'Terms',
                              style: TextStyle(
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
                              style: TextStyle(
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
