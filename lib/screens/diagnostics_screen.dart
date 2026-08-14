import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/log.dart';
import 'mcp_servers_screen.dart';
import '../design/gyro_motion.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  DIAGNOSTICS — "why isn't it working?", answered on the phone itself.
///
///  Opened by tapping the connection banner on the home screen. Shows:
///    • the server URL in use, EDITABLE at runtime (no rebuild — point
///      the app at your laptop's LAN IP while developing)
///    • a live /health check with the raw failure text
///    • the assistant stream state
///    • the app log tail (every API/SSE/voice event, timestamped)
/// ─────────────────────────────────────────────────────────────────────────
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  late final TextEditingController _url =
      TextEditingController(text: ApiService.baseUrl);
  String? _healthResult;
  bool _checking = false;

  Future<void> _checkHealth() async {
    setState(() {
      _checking = true;
      _healthResult = null;
    });
    final url = '${ApiService.baseUrl}/health';
    try {
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 8));
      _healthResult = 'HTTP ${r.statusCode} — ${r.body}';
      AppLog.add('diag', 'health: HTTP ${r.statusCode}');
    } catch (e) {
      _healthResult = 'FAILED: $e';
      AppLog.add('diag', 'health FAILED: $e');
    }
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _saveUrl() async {
    final v = _url.text.trim();
    await ApiService.setServerOverride(v.isEmpty ? null : v);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Server set to ${ApiService.baseUrl}. '
            'Restart the app to reconnect everything.')));
    setState(() {});
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = AssistantEngine.instance;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        backgroundColor: AppColors.ink,
        foregroundColor: AppColors.mist,
        title: const Text('Connection & diagnostics'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Server URL',
              style:
                  TextStyle(color: AppColors.mist, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: _url,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'https://your-server  or  http://192.168.1.5:3000',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.06),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.marigold),
              onPressed: _saveUrl,
              child: const Text('Save'),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: _checking ? null : _checkHealth,
              child: Text(_checking ? 'Checking…' : 'Test /health'),
            ),
          ]),
          if (_healthResult != null) ...[
            const SizedBox(height: 10),
            _panel(
              _healthResult!,
              color: _healthResult!.startsWith('HTTP 200')
                  ? Colors.greenAccent
                  : Colors.redAccent,
            ),
          ],
          const SizedBox(height: 20),
          AnimatedBuilder(
            animation: engine,
            builder: (_, __) => _panel(
              'Assistant stream: '
              '${engine.connected ? 'CONNECTED' : 'NOT CONNECTED'}'
              '\nPhase: ${engine.phase.name}'
              '${engine.errorMessage != null ? '\nLast error: ${engine.errorMessage}' : ''}',
              color:
                  engine.connected ? Colors.greenAccent : Colors.orangeAccent,
            ),
          ),
          const SizedBox(height: 20),
          // MCP lives in settings, never on the live agent screen — the
          // normal experience is "open the app and talk".
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.extension_rounded, color: Colors.white70),
            title: const Text('MCP servers',
                style: TextStyle(color: Colors.white)),
            subtitle: const Text('Connect external tools (advanced)',
                style: TextStyle(color: Colors.white54, fontSize: 12.5)),
            trailing:
                const Icon(Icons.chevron_right, color: Colors.white38),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const McpServersScreen())),
          ),
          const SizedBox(height: 20),
          // Motion sensor actually in use. Many budget phones have no
          // gyroscope; we fall back to the accelerometer so the tilt
          // effects still work. 'none' means neither is available.
          _panel(
            'Motion sensor: ${GyroMotion.instance.sensorSource}',
            color: GyroMotion.instance.sensorSource == 'none'
                ? Colors.orangeAccent
                : Colors.greenAccent,
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('App log',
                  style: TextStyle(
                      color: AppColors.mist, fontWeight: FontWeight.w600)),
              TextButton(
                  onPressed: () => setState(AppLog.clear),
                  child: const Text('Clear')),
            ],
          ),
          ValueListenableBuilder(
            valueListenable: AppLog.revision,
            builder: (_, __, ___) {
              final lines = AppLog.tail(120).reversed.toList();
              return _panel(
                lines.isEmpty ? '(nothing yet)' : lines.join('\n'),
                mono: true,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _panel(String text, {Color? color, bool mono = false}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (color ?? Colors.white).withValues(alpha: 0.25)),
        ),
        child: SelectableText(
          text,
          style: TextStyle(
            color: (color ?? AppColors.mist).withValues(alpha: 0.95),
            fontSize: mono ? 11.5 : 13,
            fontFamily: mono ? 'monospace' : null,
            height: 1.4,
          ),
        ),
      );
}
