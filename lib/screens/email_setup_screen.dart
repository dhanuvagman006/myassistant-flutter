import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
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
        _connectedAddress = 'your mailbox';
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
        _connectedAddress = 'your mailbox';
      });
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = "Couldn't link your account — try again.");
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
    final sure = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        // The theme's floating surface and words (2026-09-30).
        title: const Text('Disconnect mail?'),
        content: Text(
          isGoogle
              ? 'This unlinks your account — mail AND calendar '
                  'features stop until you link it again.'
              : 'Your saved credentials are deleted from the server.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep it')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text('Disconnect',
                  style: TextStyle(color: Neon.errorInk))),
        ],
      ),
    );
    if (sure != true) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    // Unlinked only when the server says so. A failure used to show
    // "disconnected" while the server kept the grant or the password and
    // went on reading mail (audit, 2026-09-27).
    var ok = false;
    try {
      if (isGoogle) {
        ok = await ApiService.disconnectGoogle();
      } else {
        final r = await http
            .delete(Uri.parse('$_base/email/account'), headers: _headers)
            .timeout(const Duration(seconds: 15));
        ok = r.statusCode == 200;
      }
    } catch (_) {}
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _error = "Couldn't disconnect — try again.";
      });
      return;
    }
    setState(() {
      _busy = false;
      _connected = false;
      _justLinked = false;
      _method = '';
      _connectedAddress = '';
    });
    // Then what the server holds: a mail password and a Google link can
    // both be set, and unlinking one leaves the other.
    await _load();
  }


  @override
  Widget build(BuildContext context) {
    // 2026-09-30: under the app's sky; loading, "link it" and "linked"
    // replace one another softly.
    return NeonScaffold(
      appBar: appleAppBar(context, 'Email'),
      body: StateSwitch.of(!_loaded
          ? const NeonLoader.page()
          : _connected
              ? _connectedView()
              : _connectView()),
    );
  }

  // ---------------- NOT CONNECTED ----------------

  Widget _connectView() {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          24, 18, 24, 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        Reveal(
          child: Center(
            // Lit glass (2026-09-30): the brand's rim and its halo.
            child: Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NeonTone.brand.fill,
                border:
                    Border.all(color: Neon.violet.withValues(alpha: 0.6), width: 1.6),
                boxShadow: Neon.halo(Neon.violet, strength: 0.7),
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
          // THE PRIMARY ACTION GLOWS (2026-09-30): the accent's lit fill
          // and halo, with Google's G on its own white round — not a white
          // slab in raw colours on the night page.
          child: Semantics(
            button: true,
            enabled: !_busy,
            child: PressScale(
              child: GestureDetector(
                onTap: _busy ? null : _linkGoogle,
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Neon.accentFill,
                    borderRadius: BorderRadius.circular(Neon.rPill),
                    boxShadow: Neon.halo(Neon.violet),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Neon.textHi,
                          shape: BoxShape.circle,
                        ),
                        child: _busy
                            ? const NeonLoader.inline(
                                semanticLabel: 'Linking your account')
                            : ExcludeSemantics(
                                child: Text('G',
                                    style: NeonType.manrope(
                                            NeonType.title3, FontWeight.w800)
                                        .copyWith(
                                            color: NeonTone.info.rim.first)),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text('Continue with Google',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: NeonType.manrope(
                                    NeonType.rowTitle, FontWeight.w700)
                                .copyWith(color: Neon.onAccent)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Reveal(
          delayMs: 160,
          child: Text('One tap — nothing to type.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Neon.textDim, fontSize: 12)),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(_error,
              textAlign: TextAlign.center,
              style: TextStyle(color: Neon.errorInk, fontSize: 13)),
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
                  style: TextStyle(color: Neon.cyanInk, fontSize: 14)),
            ),
          ),
        ),
        // Opens in place and pushes what is below (Collapse, 2026-09-30).
        Collapse(
          open: _showManual,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              _field(_address, 'Email address',
                  hint: 'you@company.com', keyboard: TextInputType.emailAddress),
              const SizedBox(height: 12),
              _field(_password, 'App password',
                  hint: 'App password from your mail provider', obscure: true),
              const SizedBox(height: 8),
              Text(
                'Other mail services and company mailboxes: create an app '
                'password in the provider\'s security settings and paste it '
                'here once.',
                style: TextStyle(color: Neon.textLo, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 14),
              Semantics(
                button: true,
                enabled: !_busy,
                child: PressScale(
                  child: GestureDetector(
                    onTap: _busy ? null : _connectManual,
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Neon.accentFill,
                        borderRadius: BorderRadius.circular(Neon.rPill),
                        boxShadow: Neon.halo(Neon.violet, strength: 0.8),
                      ),
                      child: _busy
                          ? const NeonLoader.inline(semanticLabel: 'Connecting')
                          : Text('Connect mailbox',
                              style: TextStyle(
                                  color: Neon.onAccent,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 15)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------- CONNECTED ----------------

  Widget _connectedView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
      children: [
        Center(
          // THE APP'S SUCCESS MARK (2026-09-30): just linked, the tick
          // draws itself once (NeonSuccess); coming back later, it is
          // simply there, lit.
          child: _justLinked
              ? const NeonSuccess(size: 74)
              : Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: NeonTone.success.fill,
                    border: Border.all(
                        color: Neon.success.withValues(alpha: 0.6), width: 1.6),
                    boxShadow: Neon.halo(Neon.success, strength: 0.7),
                  ),
                  child: Icon(Icons.check_rounded,
                      size: 40, color: Neon.success),
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
                ? 'Your mailbox is linked. Ask me to write a mail — it lands here.'
                : '$_connectedAddress is linked. Ask me to write a mail — it lands here.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Neon.textLo, fontSize: 14)),
        const SizedBox(height: 22),
        // THE SCREEN IS THE SENT LOG (his call, 2026-09-19: "I don't want
        // this screen… whatever mail I have sent should be visible here").
        // Composing happens by voice; there is no form to fill in.
        const EmailSentList(),
        const SizedBox(height: 22),
        Center(
          child: Text('Go back, tap the mic and say who to write to',
              style: TextStyle(color: Neon.textDim, fontSize: 13)),
        ),
        const SizedBox(height: 30),
        // Secondary and destructive: a danger-tinted rim, no glow.
        PressScale(
          child: GestureDetector(
            onTap: _busy ? null : _disconnect,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Neon.surface,
                borderRadius: BorderRadius.circular(Neon.rPill),
                border: Border.all(color: Neon.error.withValues(alpha: 0.45)),
              ),
              child: Text('Disconnect',
                  style: TextStyle(
                      color: Neon.errorInk,
                      fontWeight: FontWeight.w700,
                      fontSize: 14)),
            ),
          ),
        ),
        if (_error.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_error,
              textAlign: TextAlign.center,
              style: TextStyle(color: Neon.errorInk, fontSize: 13)),
        ],
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
      // The theme's field (2026-09-30): its ground, rim and lit focus.
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }
}
