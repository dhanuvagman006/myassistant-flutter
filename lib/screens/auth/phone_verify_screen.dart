import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/neon_tokens.dart';
import '../../services/auth_service.dart';
import '../../services/phone_verify_service.dart';

/// Mandatory step between signing in and reaching the assistant.
///
/// It is blocking on purpose. The whole point of a verified number is that
/// other people's agents can deliver to it; an account without one is
/// unreachable, so letting it through would create users who silently never
/// receive anything.
///
/// Styled as part of ONE onboarding flow with the auth and naming screens:
/// plain ground, left-aligned headline, theme fields, ink primary button.
class PhoneVerifyScreen extends StatefulWidget {
  const PhoneVerifyScreen({super.key});

  @override
  State<PhoneVerifyScreen> createState() => _PhoneVerifyScreenState();
}

class _PhoneVerifyScreenState extends State<PhoneVerifyScreen> {
  final _svc = PhoneVerifyService.instance;
  final _phone = TextEditingController();
  final _code = TextEditingController();

  /// Default matches the backend's DEFAULT_PHONE_REGION.
  final _dial = TextEditingController(text: '+91');
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  /// Only true while the backend is running with ALLOW_DEV_PHONE_VERIFY.
  bool _devAvailable = false;

  @override
  void initState() {
    super.initState();
    _svc.devVerifyAvailable().then((v) {
      if (mounted) setState(() => _devAvailable = v);
    });
  }

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    _dial.dispose();
    super.dispose();
  }

  String get _dialCode {
    final t = _dial.text.trim();
    return t.startsWith('+') ? t : '+$t';
  }

  String get _e164 => '$_dialCode${_phone.text.replaceAll(RegExp(r'\D'), '')}';

  Future<void> _send() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) {
      setState(() => _error = 'Enter your phone number.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    await _svc.sendCode(
      _e164,
      onError: (m) { if (mounted) setState(() { _busy = false; _error = m; }); },
      onCodeSent: () { if (mounted) setState(() { _busy = false; _codeSent = true; }); },
      // Android often reads the SMS itself on the receiving handset, so the
      // user may never see a code. Finish for them rather than showing an
      // entry box that will never be used.
      onAutoVerified: (cred) async {
        final err = await _svc.submit(cred);
        if (mounted) setState(() { _busy = false; _error = err; });
      },
    );
  }

  Future<void> _devSkip() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) {
      setState(() => _error = 'Enter your phone number first.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await _svc.devVerify(_e164);
    if (mounted) setState(() { _busy = false; _error = err; });
  }

  Future<void> _confirm() async {
    if (_code.text.trim().length < 4) {
      setState(() => _error = 'Enter the code we sent you.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await _svc.confirmCode(_code.text);
    if (mounted) setState(() { _busy = false; _error = err; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 40, 24, 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                      child: const Icon(Icons.verified_user_rounded,
                          color: Colors.white, size: 26),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Verify your number',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: Neon.textHi,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _codeSent
                        ? 'Enter the code we sent to ${_svc.pendingNumber ?? _e164}.'
                        : 'This is how friends and family reach you through '
                            'their assistant. One number, one account.',
                    style: const TextStyle(
                        color: Neon.textLo, fontSize: 14.5, height: 1.45),
                  ),
                  const SizedBox(height: 26),

                  if (!_codeSent)
                    Row(
                      children: [
                        SizedBox(
                          width: 96,
                          child: TextField(
                            controller: _dial,
                            keyboardType: TextInputType.phone,
                            decoration:
                                const InputDecoration(labelText: 'Code'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _phone,
                            keyboardType: TextInputType.phone,
                            autofocus: true,
                            decoration: const InputDecoration(
                              labelText: 'Phone number',
                              prefixIcon: Icon(Icons.phone_outlined),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    TextField(
                      controller: _code,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      maxLength: 6,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly
                      ],
                      decoration: const InputDecoration(
                        labelText: '6-digit code',
                        counterText: '',
                        prefixIcon: Icon(Icons.pin_outlined),
                      ),
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
                    onPressed: _busy ? null : (_codeSent ? _confirm : _send),
                    style:
                        FilledButton.styleFrom(backgroundColor: Neon.textHi),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.2, color: Colors.white),
                          )
                        : Text(_codeSent ? 'Confirm' : 'Send code'),
                  ),

                  if (_codeSent) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _codeSent = false;
                                _error = null;
                              }),
                      child: const Text('Change number',
                          style: TextStyle(color: Neon.textLo)),
                    ),
                  ],

                  // Dev escape hatch. Shown only when the SERVER says it
                  // will accept it, so it cannot linger in a build pointed
                  // at a production backend.
                  if (_devAvailable && !_codeSent) ...[
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _busy ? null : _devSkip,
                      child: const Text(
                        'Skip OTP (dev only)',
                        style: TextStyle(color: Neon.warning, fontSize: 13),
                      ),
                    ),
                  ],

                  const SizedBox(height: 6),
                  TextButton(
                    onPressed:
                        _busy ? null : () => AuthService.instance.signOut(),
                    child: const Text('Sign out',
                        style:
                            TextStyle(color: Neon.textDim, fontSize: 13)),
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
