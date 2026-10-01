import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../design/motion.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MCP SERVERS — advanced settings.
///
///  This lives in Settings, NOT on the live agent screen: MCP is an
///  extensibility mechanism, and the normal experience stays "open the app,
///  talk". A user never has to understand MCP to use the assistant.
///
///  Secrets are write-only from here. The backend never returns a stored
///  credential, so a configured server shows "••••••••" and the only
///  options are to replace it or disconnect.
/// ─────────────────────────────────────────────────────────────────────────
class McpServersScreen extends StatefulWidget {
  const McpServersScreen({super.key});

  @override
  State<McpServersScreen> createState() => _McpServersScreenState();
}

class _McpServersScreenState extends State<McpServersScreen> {
  List<dynamic> _servers = [];
  bool _loading = true;
  String? _error;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final r = await ApiService.getJson('/mcp/servers');
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r == null) {
        _error = "Couldn't load your connected tools";
      } else {
        _servers = (r['servers'] as List?) ?? [];
      }
    });
  }

  Future<void> _act(int id, String path,
      {String method = 'POST', Object? body}) async {
    setState(() => _busy.add(id));
    final r = await ApiService.sendJson('/mcp/servers/$id$path',
        method: method, body: body);
    if (!mounted) return;
    setState(() => _busy.remove(id));
    if (r == null) {
      _toast("That didn't work. Check the connection.");
    }
    await _load();
  }

  void _toast(String m) {
    if (!mounted) return;
    AppFeedback.show(m, context: context);
  }

  @override
  Widget build(BuildContext context) {
    // The sky, and the theme's lit FAB (2026-09-30): the local fill
    // colours matched the theme's and kept its glow off.
    return NeonScaffold(
      appBar: appleAppBar(context, 'Connected tools'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addServer,
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const NeonLoader.page(semanticLabel: 'Loading your tools')
            : ListView(
                padding: EdgeInsets.fromLTRB(
                    16, 8, 16, 96 + MediaQuery.paddingOf(context).bottom),
                children: [
                  Text(
                    'Connect external tools — files, issue trackers, calendars — '
                    'and your assistant can use them in conversation. Optional: '
                    'everything works without them.',
                    // textLo (2026-09-30): textDim fell under 4.5:1.
                    style: TextStyle(
                        color: Neon.textLo, fontSize: NeonType.footnote),
                  ),
                  const SizedBox(height: 16),
                  // A failed load hides the cards: their statuses would be
                  // from before it, and could be wrong.
                  if (_error != null)
                    NeonErrorState(message: _error!, onRetry: _load)
                  else ...[
                    if (_servers.isEmpty)
                      NeonEmptyState(
                        icon: Icons.extension_rounded,
                        title: 'No servers yet',
                        body: 'Add one to extend what your assistant can do.',
                        actionLabel: 'Add server',
                        actionIcon: Icons.add_rounded,
                        onAction: _addServer,
                      ),
                    ..._servers.map(_serverCard),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _serverCard(dynamic s) {
    final id = s['id'] as int;
    final status = (s['status'] ?? 'disconnected') as String;
    final enabled = s['enabled'] == true;
    final busy = _busy.contains(id);
    final tools = (s['tools'] as List?) ?? [];

    // THE STATE IS THE LIGHT (2026-09-30): a live server's card is lit
    // green, one connecting amber, a failed one red; an idle one stays a
    // dark card with a hairline, so what needs a look stands out.
    final (Color dot, String label, NeonTone? tone) = switch (status) {
      'connected' => (Neon.success, 'Connected', NeonTone.success),
      'connecting' || 'reconnecting' => (
          Neon.warning,
          'Connecting…',
          NeonTone.warning
        ),
      'error' => (Neon.error, 'Error', NeonTone.danger),
      'disabled' => (Neon.textDim, 'Disabled', null),
      _ => (Neon.textDim, 'Disconnected', null),
    };

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dot,
                    boxShadow:
                        tone == null ? null : Neon.halo(dot, strength: 0.5))),
            const SizedBox(width: 8),
            Expanded(
              child: Text(s['name'] ?? '',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            Switch(
              value: enabled,
              onChanged: busy
                  ? null
                  : (v) =>
                      _act(id, '/enabled', method: 'PUT', body: {'enabled': v}),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '$label · ${s['transport']} · ${tools.length} tool${tools.length == 1 ? '' : 's'}',
          style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote),
        ),
        if ((s['lastError'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(s['lastError'],
              style: TextStyle(color: Neon.errorInk, fontSize: 12)),
        ],
        if (s['hasSecrets'] == true) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text('Authentication: ',
                style: TextStyle(color: Neon.textDim, fontSize: 13)),
            // The credential itself is never sent to the app.
            Text('••••••••',
                style: TextStyle(color: Neon.textLo, letterSpacing: 2)),
          ]),
        ],
        if (tools.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: tools.take(12).map<Widget>((t) {
              final risk = t['risk'] ?? 'low';
              final c = risk == 'high'
                  ? Neon.errorInk
                  : risk == 'medium'
                      ? Neon.warningInk
                      : Neon.textLo;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Neon.line),
                ),
                child: Text(t['name'] ?? '',
                    style: TextStyle(color: c, fontSize: 12)),
              );
            }).toList(),
          ),
        ],
        const SizedBox(height: 12),
        if (busy)
          const LinearProgressIndicator(minHeight: 2)
        else
          Wrap(
            spacing: 8,
            children: [
              if (status == 'connected')
                TextButton(
                    onPressed: () => _act(id, '/disconnect'),
                    child: const Text('Disconnect'))
              else if (enabled)
                TextButton(
                    onPressed: () => _act(id, '/connect'),
                    child: Text(status == 'error' ? 'Retry' : 'Connect')),
              TextButton(
                  onPressed: () => _confirmDelete(id, s['name'] ?? ''),
                  child:
                      Text('Remove', style: TextStyle(color: Neon.errorInk))),
            ],
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: tone == null
          ? Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Neon.rLg),
                color: Neon.surface,
                border: Border.all(color: Neon.line),
              ),
              child: body,
            )
          : GlowCard(
              tone: tone,
              halo: status == 'error' ? 0.6 : 0.35,
              rimWidth: 1.6,
              padding: const EdgeInsets.all(14.4),
              child: body,
            ),
    );
  }

  Future<void> _confirmDelete(int id, String name) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove $name?', style: TextStyle(color: Neon.textHi)),
        content: Text(
            'Its tools will no longer be available to your assistant. Stored credentials are deleted.',
            style: TextStyle(color: Neon.textLo)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text('Remove', style: TextStyle(color: Neon.errorInk))),
        ],
      ),
    );
    if (ok == true) await _act(id, '', method: 'DELETE');
  }

  Future<void> _addServer() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final token = TextEditingController();
    var transport = 'http';

    final saved = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(c).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Add MCP server',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              _field(name, 'Name', 'e.g. My tools'),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'http', label: Text('HTTP')),
                  ButtonSegment(value: 'sse', label: Text('SSE')),
                ],
                selected: {transport},
                onSelectionChanged: (v) => setSheet(() => transport = v.first),
              ),
              const SizedBox(height: 10),
              _field(url, 'Server URL', 'https://example.com/mcp'),
              const SizedBox(height: 10),
              _field(token, 'Access token (optional)', '', obscure: true),
              const SizedBox(height: 6),
              Text(
                'The token is encrypted on the server and never sent back to this app.',
                style:
                    TextStyle(color: Neon.textLo, fontSize: NeonType.caption),
              ),
              const SizedBox(height: 16),
              ApplePrimaryButton(
                label: 'Add',
                onPressed: () => Navigator.pop(c, true),
              ),
            ],
          ),
        ),
      ),
    );

    if (saved != true) return;
    if (name.text.trim().isEmpty || url.text.trim().isEmpty) {
      _toast('Name and URL are required.');
      return;
    }
    final r = await ApiService.sendJson('/mcp/servers', method: 'POST', body: {
      'name': name.text.trim(),
      'transport': transport,
      'config': {'url': url.text.trim()},
      if (token.text.trim().isNotEmpty) 'secrets': {'token': token.text.trim()},
    });
    if (r == null) {
      _toast("Couldn't add that server.");
      return;
    }
    await _load();
    final id = r['server']?['id'];
    if (id is int) await _act(id, '/connect'); // connect + discover tools
  }

  Widget _field(TextEditingController c, String label, String hint,
          {bool obscure = false}) =>
      TextField(
        controller: c,
        obscureText: obscure,
        style: TextStyle(color: Neon.textHi),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: TextStyle(color: Neon.textLo),
          hintStyle: TextStyle(color: Neon.textDim),
          filled: true,
          fillColor: Neon.surfaceHigh,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
        ),
      );
}
