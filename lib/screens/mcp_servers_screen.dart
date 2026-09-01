import 'package:flutter/material.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';

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
        _error = "Couldn't reach the server.";
      } else {
        _servers = (r['servers'] as List?) ?? [];
      }
    });
  }

  Future<void> _act(int id, String path, {String method = 'POST', Object? body}) async {
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('MCP servers'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Neon.violet,
        onPressed: _addServer,
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  const Text(
                    'Connect external tools — files, issue trackers, calendars — '
                    'and Hari can use them in conversation. Optional: everything '
                    'works without them.',
                    style: TextStyle(
                        color: Neon.textDim, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    _banner(_error!, Colors.orangeAccent),
                  if (_servers.isEmpty && _error == null)
                    _banner('No servers yet. Add one to extend what Hari can do.',
                        Neon.textDim),
                  ..._servers.map(_serverCard),
                ],
              ),
      ),
    );
  }

  Widget _banner(String text, Color c) => Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: c.withValues(alpha: 0.10),
          border: Border.all(color: c.withValues(alpha: 0.4)),
        ),
        child: Text(text, style: TextStyle(color: c)),
      );

  Widget _serverCard(dynamic s) {
    final id = s['id'] as int;
    final status = (s['status'] ?? 'disconnected') as String;
    final enabled = s['enabled'] == true;
    final busy = _busy.contains(id);
    final tools = (s['tools'] as List?) ?? [];

    final (Color dot, String label) = switch (status) {
      'connected' => (Colors.greenAccent, 'Connected'),
      'connecting' || 'reconnecting' => (Colors.amberAccent, 'Connecting…'),
      'error' => (Colors.redAccent, 'Error'),
      'disabled' => (Neon.textDim, 'Disabled'),
      _ => (Neon.textDim, 'Disconnected'),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Neon.surfaceHigh,
        border: Border.all(color: Neon.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: dot)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(s['name'] ?? '',
                    style: const TextStyle(
                        color: Neon.textHi,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
              ),
              Switch(
                value: enabled,
                activeThumbColor: Neon.cyan,
                onChanged: busy
                    ? null
                    : (v) => _act(id, '/enabled',
                        method: 'PUT', body: {'enabled': v}),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$label · ${s['transport']} · ${tools.length} tool${tools.length == 1 ? '' : 's'}',
            style: const TextStyle(
                color: Neon.textDim, fontSize: 12.5),
          ),
          if ((s['lastError'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(s['lastError'],
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
          if (s['hasSecrets'] == true) ...[
            const SizedBox(height: 8),
            const Row(children: [
              Text('Authentication: ',
                  style: TextStyle(
                      color: Neon.textDim, fontSize: 12.5)),
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
                    ? Colors.redAccent
                    : risk == 'medium'
                        ? Colors.amberAccent
                        : Neon.textDim;
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: c.withValues(alpha: 0.5)),
                  ),
                  child: Text(t['name'] ?? '',
                      style: TextStyle(color: c, fontSize: 11)),
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
                    child: const Text('Remove',
                        style: TextStyle(color: Colors.redAccent))),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF17162A),
        title: Text('Remove $name?', style: const TextStyle(color: Neon.textHi)),
        content: const Text(
            'Its tools will no longer be available to Hari. Stored credentials are deleted.',
            style: TextStyle(color: Neon.textLo)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Remove',
                  style: TextStyle(color: Colors.redAccent))),
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

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF17162A),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(c).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Add MCP server',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              _field(name, 'Name', 'GitHub'),
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
              _field(token, 'Access token (optional)', '',
                  obscure: true),
              const SizedBox(height: 6),
              const Text(
                'The token is encrypted on the server and never sent back to this app.',
                style: TextStyle(
                    color: Neon.textDim, fontSize: 11.5),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Neon.violet),
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Add'),
                ),
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
      if (token.text.trim().isNotEmpty)
        'secrets': {'token': token.text.trim()},
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
        style: const TextStyle(color: Neon.textHi),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: Neon.textLo),
          hintStyle: const TextStyle(color: Neon.textDim),
          filled: true,
          fillColor: Neon.surfaceHigh,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
        ),
      );
}
