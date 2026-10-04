import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:simple_icons/simple_icons.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/auth_service.dart';
import '../services/connections_service.dart';
import 'email_setup_screen.dart';

/// CONNECTED APPS (build 120) — link the apps the user already uses, in one
/// place. Notion links through its own consent page; mail keeps its own
/// screen. The Notion card only appears when the server offers it.
class ConnectedAppsScreen extends StatefulWidget {
  /// Shows the card mid-connect (the layout sweep draws every state).
  final bool startConnecting;
  const ConnectedAppsScreen(
      {super.key, @visibleForTesting this.startConnecting = false});

  @override
  State<ConnectedAppsScreen> createState() => _ConnectedAppsScreenState();
}

class _ConnectedAppsScreenState extends State<ConnectedAppsScreen>
    with WidgetsBindingObserver {
  final _svc = ConnectionsService.instance;
  bool _connecting = false;
  bool _failed = false;
  bool? _mailLinked;
  bool? _googleLinked;

  /// The app being linked or unlinked right now (one at a time).
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _connecting = widget.startConnecting;
    WidgetsBinding.instance.addObserver(this);
    _svc.addListener(_sync);
    _svc.load();
    _loadMail();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _svc.removeListener(_sync);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the browser (or from Notion itself): the link may be made.
    if (state == AppLifecycleState.resumed && !_connecting && _busyId == null) _svc.load();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  Future<void> _loadMail() async {
    final r = await Future.wait([_svc.mailLinked(), _svc.googleLinked()]);
    if (!mounted) return;
    setState(() {
      _mailLinked = r[0];
      _googleLinked = r[1];
    });
  }

  // ── Google and the other apps (owner, 2026-10-04) ─────────────────────


  Future<void> _toggleGoogle() async {
    if (_busyId != null) return;
    HapticFeedback.selectionClick();
    final linked = _googleLinked == true;
    if (linked && !await _confirmUnlink('Google')) return;
    setState(() => _busyId = 'google');
    var ok = false;
    String? msg;
    try {
      if (linked) {
        ok = await ApiService.disconnectGoogle();
      } else {
        await AuthService.instance.linkGoogleData();
        ok = true;
      }
    } on AuthException catch (e) {
      msg = e.message;
    } catch (_) {}
    await _loadMail();
    if (!mounted) return;
    setState(() => _busyId = null);
    _toast(msg ??
        (ok
            ? (linked ? 'Google is disconnected.' : 'Google is connected.')
            : "Couldn't do that. Please try again."));
  }

  Future<bool> _confirmUnlink(String name) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('Disconnect $name?'),
          content: const Text("I'll stop using it for you. Nothing in it is deleted."),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Keep it')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Disconnect')),
          ],
        ),
      ) ==
      true;

  Future<void> _toggleApp(ConnectionInfo a) async {
    if (_busyId != null || !a.available) return;
    HapticFeedback.selectionClick();
    if (a.connected) {
      if (!await _confirmUnlink(a.name)) return;
      setState(() => _busyId = a.id);
      final ok = await _svc.disconnect(a.id);
      if (!mounted) return;
      setState(() => _busyId = null);
      _toast(ok ? '${a.name} is disconnected.' : "Couldn't disconnect. Please try again.");
      return;
    }
    setState(() => _busyId = a.id);
    final r = await _svc.connect(a.id);
    if (!mounted) return;
    setState(() => _busyId = null);
    if (r == ConnectResult.connected) _toast('${a.name} is connected.');
    if (r == ConnectResult.failed) _toast("Couldn't connect ${a.name}. Please try again.");
  }

  Widget _appRow({
    required String id,
    required String name,
    required String subtitle,
    required bool connected,
    required bool available,
    required VoidCallback onTap,
  }) {
    final busy = _busyId == id;
    return AppleRow(
      leading: BrandLogo(id),
      title: name,
      subtitle: subtitle,
      onTap: available && !busy ? onTap : null,
      trailing: busy
          ? const NeonLoader.inline()
          : !available
              ? Text('Soon', style: TextStyle(color: Neon.textDim, fontSize: NeonType.caption))
              : Text(connected ? 'Connected' : 'Connect',
                  style: TextStyle(
                      color: connected ? Neon.successInk : Neon.violet,
                      fontWeight: FontWeight.w700,
                      fontSize: NeonType.footnote)),
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    AppFeedback.show(text, context: context);
  }

  Future<void> _connect() async {
    if (_connecting) return;
    HapticFeedback.selectionClick();
    setState(() {
      _connecting = true;
      _failed = false;
    });
    final r = await _svc.connectNotion();
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _failed = r == ConnectResult.failed;
    });
    if (r == ConnectResult.connected) _toast('Notion is connected.');
    if (r == ConnectResult.failed) {
      _toast("Couldn't connect Notion. Please try again.");
    }
  }

  Future<void> _disconnect() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Disconnect Notion?'),
        content: const Text(
            "I'll stop reading or adding to your pages. Nothing in Notion is deleted."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep it')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _svc.disconnectNotion();
    _toast(done
        ? 'Notion is disconnected.'
        : "Couldn't disconnect. Please try again.");
  }

  Widget _notionCard(ConnectionInfo n) {
    final String subtitle;
    final String button;
    VoidCallback? action;
    if (_connecting) {
      subtitle = 'Opening Notion…';
      button = 'Connect';
    } else if (n.status == 'connected') {
      subtitle = 'Connected to ${n.workspace ?? 'your workspace'}';
      button = 'Disconnect';
      action = _disconnect;
    } else if (n.status == 'needs_reconnect') {
      subtitle = 'Needs a quick reconnect';
      button = 'Reconnect';
      action = _connect;
    } else {
      subtitle = _failed
          ? "Couldn't connect. Please try again."
          : 'Read your pages and add notes and to-dos — only the pages you choose.';
      button = 'Connect';
      action = _connect;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The one lit card here (2026-09-30): its rim says the link's
        // state — green linked, amber to reconnect, blue to link.
        GlowCard(
          tone: n.status == 'connected'
              ? NeonTone.success
              : n.status == 'needs_reconnect'
                  ? NeonTone.warning
                  : NeonTone.info,
          halo: 0.5,
          rimWidth: 1.6,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                AppleRow(
                  leading: const BrandLogo('notion'),
                  title: 'Notion',
                  subtitle: subtitle,
                  trailing: _connecting ? const NeonLoader.inline() : null,
                ),
                // The action on its own row: at large text sizes a button beside
                // the workspace name has no room.
                if (!_connecting) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 60),
                    child: Divider(height: 1, thickness: 0.5, color: Neon.line),
                  ),
                  AppleRow(
                    title: button,
                    titleColor:
                        button == 'Disconnect' ? Neon.errorInk : Neon.violet,
                    onTap: action,
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, top: 6, right: 16),
          child: Text(
            n.status == 'connected'
                ? 'Try saying: "Add milk to my Groceries page in Notion."\n'
                    'To let me see more pages later: in Notion, open the page, '
                    'tap ••• → Connections, and add Hari Assistant.'
                : 'To let me see more pages later: in Notion, open the page, '
                    'tap ••• → Connections, and add Hari Assistant.',
            // textLo (2026-09-30): textDim fell under 4.5:1 on the sky.
            style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = _svc.notion;
    return NeonScaffold(
      appBar: appleAppBar(context, 'Connected apps'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
            child: Text(
              'Link the apps you already use, so I can help inside them. '
              'You can unlink any time.',
              style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.4),
            ),
          ),
          if (n != null && n.available) ...[
            const GroupLabel('Notes'),
            _notionCard(n),
          ],
          const GroupLabel('Google'),
          GroupedCard(dividerInset: 60, children: [
            _appRow(
              id: 'google',
              name: 'Google',
              subtitle: _googleLinked == true
                  ? 'Gmail and Calendar are linked. Tap to disconnect.'
                  : 'Gmail and Google Calendar — one sign-in',
              connected: _googleLinked == true,
              available: _googleLinked != null,
              onTap: _toggleGoogle,
            ),
          ]),
          const SizedBox(height: 24),
          if (_svc.items.any((c) => c.id != 'notion')) ...[
            const GroupLabel('More apps'),
            GroupedCard(dividerInset: 60, children: [
              for (final a in _svc.items.where((c) => c.id != 'notion'))
                _appRow(
                  id: a.id,
                  name: a.name,
                  subtitle: a.connected
                      ? 'Connected${a.workspace != null ? ' to ${a.workspace}' : ''}. Tap to disconnect.'
                      : a.status == 'needs_reconnect'
                          ? 'Needs a quick reconnect'
                          : a.description,
                  connected: a.connected,
                  available: a.available,
                  onTap: () => _toggleApp(a),
                ),
            ]),
            const SizedBox(height: 24),
          ],
          const GroupLabel('Mail & calendar'),
          GroupedCard(
            dividerInset: 60,
            children: [
              AppleRow(
                leading:
                    IconTile(Icons.alternate_email_rounded, AppleColors.green),
                title: 'Email',
                subtitle: _mailLinked == null
                    ? ' '
                    : (_mailLinked! ? 'Linked' : 'Not linked'),
                trailing: Icon(Icons.chevron_right_rounded,
                    color: Neon.textDim, size: 20),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const EmailSetupScreen()));
                  _loadMail();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// THE APP'S OWN LOGO (owner, 2026-10-04): the real brand mark in its brand
/// colour on a plain white tile — no tinted icon. Microsoft's four squares
/// are drawn (Simple Icons does not carry them).
class BrandLogo extends StatelessWidget {
  const BrandLogo(this.id, {super.key, this.size = 34});
  final String id;
  final double size;

  static const _marks = <String, (IconData, Color)>{
    'google': (SimpleIcons.google, SimpleIconColors.google),
    'notion': (SimpleIcons.notion, SimpleIconColors.notion),
    'todoist': (SimpleIcons.todoist, SimpleIconColors.todoist),
    'asana': (SimpleIcons.asana, SimpleIconColors.asana),
    'spotify': (SimpleIcons.spotify, SimpleIconColors.spotify),
    'zoom': (SimpleIcons.zoom, SimpleIconColors.zoom),
    'dropbox': (SimpleIcons.dropbox, SimpleIconColors.dropbox),
  };

  @override
  Widget build(BuildContext context) {
    final mark = _marks[id];
    final Widget inner;
    if (id == 'microsoft') {
      final q = size * 0.24;
      Widget sq(int c) => Container(width: q, height: q, color: Color(c));
      inner = Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min,
            children: [sq(0xfff25022), SizedBox(width: q * 0.12), sq(0xff7fba00)]),
        SizedBox(height: q * 0.12),
        Row(mainAxisSize: MainAxisSize.min,
            children: [sq(0xff00a4ef), SizedBox(width: q * 0.12), sq(0xffffb900)]),
      ]);
    } else {
      inner = Icon(mark?.$1 ?? Icons.apps_rounded,
          color: mark?.$2 ?? Colors.black54, size: size * 0.6);
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: inner,
    );
  }
}
