import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../design/neon_tokens.dart';
import '../../design/gyro_tilt.dart';
import '../../design/neon_widgets.dart';
import '../../services/auth_service.dart';

/// First screen of the app when signed out — Neon V2 redesign.
/// One screen, two modes (Log in / Sign up) — plus Google and Apple.
/// On success AuthService notifies, and the gate in main.dart swaps to home.
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
          )
        : auth.logIn(email: _email.text.trim(), password: _password.text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = AuthService.instance;

    return Scaffold(
      body: NeonBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: Neon.s6, vertical: Neon.s7),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Brand mark — orb ring with signature sweep gradient
                      Center(
                        child: GyroTilt(
                          maxTilt: 0.12, // the small orb can tilt further
                          radius: 36,
                          sheen: false, // the orb gradient is its own light
                          shadowColor: Neon.cyan,
                          child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: Neon.gOrb,
                            boxShadow:
                                Neon.glow(Neon.violet, blur: 36, alpha: 0.4),
                          ),
                          padding: const EdgeInsets.all(3),
                          child: Container(
                            decoration: const BoxDecoration(
                                shape: BoxShape.circle, color: Neon.bg),
                            child: const Icon(Icons.auto_awesome_rounded,
                                color: Neon.cyan, size: 30),
                          ),
                        ),
                        ),
                      ),
                      const SizedBox(height: Neon.s5),
                      Center(
                        child: GradientText(
                          _isSignUp ? 'Create your account' : 'Welcome back',
                          style: theme.textTheme.headlineSmall!,
                          gradient: Neon.gVioletCyan,
                        ),
                      ),
                      const SizedBox(height: Neon.s2),
                      Text(
                        _isSignUp
                            ? 'Your assistant, everywhere you go.'
                            : 'Sign in to continue.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Neon.textLo),
                      ),
                      const SizedBox(height: Neon.s7),

                      GlassCard(
                        tilt: true, // gyro 3D — sheen + sliding shadow
                        padding: const EdgeInsets.all(Neon.s5),
                        radius: Neon.rXl,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AnimatedSize(
                              duration: Neon.med,
                              curve: Curves.easeOutCubic,
                              child: _isSignUp
                                  ? Padding(
                                      padding: const EdgeInsets.only(
                                          bottom: Neon.s4),
                                      child: TextFormField(
                                        controller: _name,
                                        textInputAction: TextInputAction.next,
                                        textCapitalization:
                                            TextCapitalization.words,
                                        decoration: const InputDecoration(
                                          labelText: 'Name',
                                          prefixIcon: Icon(
                                              Icons.person_outline_rounded),
                                        ),
                                      ),
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
                                prefixIcon:
                                    Icon(Icons.alternate_email_rounded),
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
                            const SizedBox(height: Neon.s4),
                            TextFormField(
                              controller: _password,
                              obscureText: _obscure,
                              autofillHints: const [AutofillHints.password],
                              onFieldSubmitted: (_) =>
                                  _busy ? null : _submitEmail(),
                              decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon:
                                    const Icon(Icons.lock_outline_rounded),
                                suffixIcon: IconButton(
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                  icon: Icon(_obscure
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined),
                                ),
                              ),
                              validator: (v) {
                                if ((v ?? '').isEmpty) {
                                  return 'Enter your password';
                                }
                                if (_isSignUp && v!.length < 8) {
                                  return 'At least 8 characters';
                                }
                                return null;
                              },
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: Neon.s4),
                              Container(
                                padding: const EdgeInsets.all(Neon.s3),
                                decoration: BoxDecoration(
                                  color:
                                      Neon.error.withValues(alpha: 0.10),
                                  borderRadius:
                                      BorderRadius.circular(Neon.rSm),
                                  border: Border.all(
                                      color: Neon.error
                                          .withValues(alpha: 0.45)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.error_outline_rounded,
                                        color: Neon.error, size: 20),
                                    const SizedBox(width: Neon.s2),
                                    Expanded(
                                      child: Text(
                                        _error!,
                                        style: const TextStyle(
                                            color: Neon.error),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: Neon.s5),
                            GradientButton(
                              label:
                                  _isSignUp ? 'Create account' : 'Log in',
                              gradient: Neon.gVioletCyan,
                              busy: _busy,
                              onPressed: _busy ? null : _submitEmail,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: Neon.s6),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: Neon.s3),
                            child: Text(
                              'or continue with',
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: Neon.textDim),
                            ),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: Neon.s5),

                      GhostButton(
                        label: 'Continue with Google',
                        leading: const _GoogleG(),
                        onPressed: _busy
                            ? null
                            : () =>
                                _run(AuthService.instance.signInWithGoogle),
                      ),
                      if (auth.appleAvailable) ...[
                        const SizedBox(height: Neon.s3),
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

                      const SizedBox(height: Neon.s6),
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
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
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
