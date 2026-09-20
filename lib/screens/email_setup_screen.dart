import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'email_sent_list.dart';

/// EMAIL — the ONE-TAP screen. "Continue with Google" links Gmail in a
/// single tap (server keeps the tokens; the app never sees them). Any
/// other mailbox still works through the app-password form, folded away
/// under "Use another mail service". Connected users get tappable
/// starter chips that actually ask the assistant — no decoration here.
class EmailSetupScreen extends StatefulWidget {
  const EmailSetupScreen({super.key});

  @override
  State<EmailSetupScreen> createState() => _EmailSetupScreenState();
}

class _EmailSetupScreenState extends State<EmailSetupScreen> {
  final _address = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _loaded = false;
  bool _connected = false;
  bool _justLinked = false; // drives the success pop animation
  bool _showManual = false;
  String _method = ''; // 'google' | 'password'
  String _connectedAddress = '';
  String _error = '';

  static String get _base => ApiService.baseUrl;
  static Map<String, String> get _headers => ApiService.authHeaders;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      ApiService.getJson('/email/account'),
      ApiService.getJson('/google/status'),
    ]);
    if (!mounted) return;
    final acc = results[0];
    final goog = results[1];
    setState(() {
      _loaded = true;
      if (acc?['connected'] == true) {
        _connected = true;
        _method = 'password';
        _connectedAddress = (acc?['address'] ?? '').toString();
      } else if (goog?['connected'] == true) {
        _connected = true;
        _method = 'google';
        _connectedAddress = 'your Gmail';
      } else {
        _connected = false;
        _method = '';
      }
    });
  }

  Future<void> _linkGoogle() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await AuthService.instance.linkGoogleData();
      if (!mounted) return;
      setState(() {
        _connected = true;
        _justLinked = true;
        _method = 'google';
        _connectedAddress = 'your Gmail';
      });
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'Google linking failed — try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectManual() async {
    final addr = _address.text.trim();
    final pass = _password.text.trim();
    if (addr.isEmpty || pass.isEmpty) {
      setState(() => _error = 'Enter the email address and its app password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final r = await http
          .post(Uri.parse('$_base/email/account'),
              headers: _headers,
              body: jsonEncode({'address': addr, 'password': pass}))
          .timeout(const Duration(seconds: 45));
      final body = jsonDecode(r.body);
      if (r.statusCode == 200 && body is Map && body['connected'] == true) {
        _password.clear();
        if (!mounted) return;
        setState(() {
          _connected = true;
          _justLinked = true;
          _method = 'password';
          _connectedAddress = (body['address'] ?? addr).toString();
        });
      } else {
        setState(() => _error =
            (body is Map ? body['error'] : null)?.toString() ??
                'Could not connect — check the address and app password.');
      }
    } catch (_) {
      setState(() =>
          _error = 'Could not reach the server — check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final isGoogle = _method == 'google';
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: Neon.surfaceHigh,
        title: Text('Disconnect mail?', style: TextStyle(color: Neon.textHi)),
        content: Text(
          isGoogle
              ? 'This unlinks your Google account — mail AND calendar '
                  'features stop until you link it again.'
              : 'Your saved credentials are deleted from the server.',
          style: TextStyle(color: Neon.textLo),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep it')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Disconnect',
                  style: TextStyle(color: Color(0xFFFF8585)))),
        ],
      ),
    );
    if (sure != true) return;
    setState(() => _busy = true);
    try {
      if (isGoogle) {
        await ApiService.disconnectGoogle();
      } else {
        await http
            .delete(Uri.parse('$_base/email/account'), headers: _headers)
            .timeout(const Duration(seconds: 15));
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _connected = false;
      _justLinked = false;
      _method = '';
      _connectedAddress = '';
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(backgroundColor: Neon.bg, title: const Text('Email')),
      body: !_loaded
          ? Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Neon.textLo))
          : _connected
              ? _connectedView()
              : _connectView(),
    );
  }

  // ---------------- NOT CONNECTED ----------------

  Widget _connectView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
      children: [
        Reveal(
          child: Center(
            child: Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Neon.violet.withValues(alpha: 0.12),
                border:
                    Border.all(color: Neon.violet.withValues(alpha: 0.35)),
                boxShadow: Neon.glow(Neon.violet, alpha: 0.25),
              ),
              child: Icon(Icons.mark_email_unread_rounded,
                  size: 42, color: Neon.violet),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Reveal(
          delayMs: 60,
          child: Text('Your mail, by voice',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Neon.textHi,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3)),
        ),
        const SizedBox(height: 6),
        Reveal(
          delayMs: 90,
          child: Text('One tap to link. Then just say\n"Read my mails."',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: Neon.textLo, fontSize: 14, height: 1.45)),
        ),
        const SizedBox(height: 26),
        Reveal(
          delayMs: 130,
          child: PressScale(
            child: GestureDetector(
              onTap: _busy ? null : _linkGoogle,
              child: Container(
                height: 54,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Neon.rPill),
                  boxShadow: Neon.glow(Neon.violet, alpha: 0.18),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_busy)
                      const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(0xFF4285F4)))
                    else
                      const Text('G',
                          style: TextStyle(
                              color: Color(0xFF4285F4),
                              fontSize: 24,
                              fontWeight: FontWeight.w800)),
                    const SizedBox(width: 12),
                    const Text('Continue with Google',
                        style: TextStyle(
                            color: Color(0xFF1B1D28),
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Reveal(
          delayMs: 160,
          child: Text('Works with Gmail — nothing to type.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Neon.textDim, fontSize: 12)),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(_error,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: Color(0xFFFF8585), fontSize: 12.5)),
        ],
        const SizedBox(height: 26),
        Reveal(
          delayMs: 190,
          child: Row(children: [
            Expanded(child: Divider(color: Neon.line)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or',
                  style: TextStyle(color: Neon.textDim, fontSize: 12)),
            ),
            Expanded(child: Divider(color: Neon.line)),
          ]),
        ),
        const SizedBox(height: 14),
        Reveal(
          delayMs: 220,
          child: Center(
            child: TextButton(
              onPressed: () => setState(() => _showManual = !_showManual),
              child: Text(
                  _showManual
                      ? 'Hide the manual setup'
                      : 'Use another mail service',
                  style: TextStyle(color: Neon.cyan, fontSize: 13.5)),
            ),
          ),
        ),
        if (_showManual) ...[
          const SizedBox(height: 8),
          _field(_address, 'Email address',
              hint: 'you@company.com', keyboard: TextInputType.emailAddress),
          const SizedBox(height: 12),
          _field(_password, 'App password',
              hint: 'App password from your mail provider', obscure: true),
          const SizedBox(height: 8),
          Text(
            'Outlook, Yahoo, Zoho and company mailboxes: create an app '
            'password in the provider\'s security settings and paste it '
            'here once.',
            style: TextStyle(color: Neon.textDim, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 14),
          PressScale(
            child: GestureDetector(
              onTap: _busy ? null : _connectManual,
              child: Container(
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Neon.violet,
                  borderRadius: BorderRadius.circular(Neon.rPill),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Text('Connect mailbox',
                        style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
                            fontSize: 14.5)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ---------------- CONNECTED ----------------

  Widget _connectedView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
      children: [
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: _justLinked ? 0.0 : 1.0, end: 1.0),
            duration: const Duration(milliseconds: 650),
            curve: Curves.elasticOut,
            builder: (c, v, child) => Transform.scale(scale: v, child: child),
            child: Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Neon.success.withValues(alpha: 0.12),
                border:
                    Border.all(color: Neon.success.withValues(alpha: 0.45)),
                boxShadow: Neon.glow(Neon.success, alpha: 0.3),
              ),
              child:
                  Icon(Icons.check_rounded, size: 40, color: Neon.success),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(_justLinked ? 'Linked!' : 'Your mail',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Neon.textHi,
                fontSize: 22,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(
            _method == 'google'
                ? 'Gmail is linked. Ask me to write a mail — it lands here.'
                : '$_connectedAddress is linked. Ask me to write a mail — it lands here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Neon.textLo, fontSize: 13.5)),
        const SizedBox(height: 22),
        // THE SCREEN IS THE SENT LOG (his call, 2026-09-19: "I don't want
        // this screen… whatever mail I have sent should be visible here").
        // Composing happens by voice; there is no form to fill in.
        const EmailSentList(),
        const SizedBox(height: 22),
        Center(
          child: Text('Tap the mic and say who to write to',
              style: TextStyle(color: Neon.textDim, fontSize: 12.5)),
        ),
        const SizedBox(height: 30),
        PressScale(
          child: GestureDetector(
            onTap: _busy ? null : _disconnect,
            child: Container(
              height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Neon.surface,
                borderRadius: BorderRadius.circular(Neon.rPill),
                border: Border.all(color: Neon.line),
              ),
              child: const Text('Disconnect',
                  style: TextStyle(
                      color: Color(0xFFFF8585),
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, bool obscure = false, TextInputType? keyboard}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      autocorrect: false,
      style: TextStyle(color: Neon.textHi, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Neon.textLo),
        hintStyle: TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Neon.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: BorderSide(color: Neon.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: BorderSide(color: Neon.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Neon.rMd),
          borderSide: BorderSide(color: Neon.violet.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}
