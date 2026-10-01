import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/app_feedback.dart';
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
    if (state == AppLifecycleState.resumed && !_connecting) _svc.load();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  Future<void> _loadMail() async {
    final linked = await _svc.mailLinked();
    if (!mounted) return;
    setState(() => _mailLinked = linked);
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
                  leading:
                      IconTile(Icons.sticky_note_2_rounded, AppleColors.blue),
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
