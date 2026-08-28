import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/neon_tokens.dart';
import '../../services/auth_service.dart';
import '../../services/phone_verify_service.dart';

/// Mandatory step between signing in and reaching the assistant.
///
/// It is blocking on purpose. The whole point of a verified number is that
/// other people's agents can deliver to it; an account without one is
/// unreachable, so letting it through would create users who silently never
/// receive anything.
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
  String _dialCode = '+91';
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
    super.dispose();
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
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.verified_user_rounded, size: 56, color: Neon.cyan),
                const SizedBox(height: 20),
                const Text(
                  'Verify your number',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _codeSent
                      ? 'Enter the code we sent to ${_svc.pendingNumber ?? _e164}.'
                      : 'This is how friends and family reach you through '
                          'their assistant. One number, one account.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Neon.textLo, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 28),

                if (!_codeSent) ...[
                  Row(
                    children: [
                      SizedBox(width: 92, child: _input(
                        controller: TextEditingController(text: _dialCode),
                        hint: '+91',
                        keyboard: TextInputType.phone,
                        onChanged: (v) => _dialCode = v.startsWith('+') ? v : '+$v',
                      )),
                      const SizedBox(width: 10),
                      Expanded(child: _input(
                        controller: _phone,
                        hint: 'Phone number',
                        keyboard: TextInputType.phone,
                        autofocus: true,
                      )),
                    ],
                  ),
                ] else
                  _input(
                    controller: _code,
                    hint: '6-digit code',
                    keyboard: TextInputType.number,
                    autofocus: true,
                    maxLength: 6,
                  ),

                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Neon.error, fontSize: 13),
                  ),
                ],

                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _busy ? null : (_codeSent ? _confirm : _send),
                  style: FilledButton.styleFrom(
                    backgroundColor: Neon.violet,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                        )
                      : Text(_codeSent ? 'Confirm' : 'Send code'),
                ),

                if (_codeSent) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() { _codeSent = false; _error = null; }),
                    child: const Text('Change number',
                        style: TextStyle(color: Neon.textLo)),
                  ),
                ],

                // Dev escape hatch. Shown only when the SERVER says it will
                // accept it, so it cannot linger in a build pointed at a
                // production backend.
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
                  onPressed: _busy ? null : () => AuthService.instance.signOut(),
                  child: const Text('Sign out',
                      style: TextStyle(color: Neon.textDim, fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _input({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboard,
    bool autofocus = false,
    int? maxLength,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      autofocus: autofocus,
      maxLength: maxLength,
      onChanged: onChanged,
      inputFormatters:
          maxLength != null ? [FilteringTextInputFormatter.digitsOnly] : null,
      style: const TextStyle(color: Neon.textHi, fontSize: 16),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: const TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Neon.surfaceHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
