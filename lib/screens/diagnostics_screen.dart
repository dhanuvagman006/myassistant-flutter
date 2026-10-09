import 'package:flutter/material.dart';

import 'package:http/http.dart' as http;

import '../core/log.dart';
import 'assistant_settings_screen.dart';
import 'mcp_servers_screen.dart';
import '../design/apple_kit.dart';
import '../design/gyro_motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/self_check.dart';

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
      final r =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
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
    AppFeedback.show(
        'Server set to ${ApiService.baseUrl}. '
        'Restart the app to reconnect everything.',
        context: context);
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
    return NeonScaffold(
      appBar: appleAppBar(context, 'Connection & diagnostics'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          const GroupLabel('Server URL'),
          TextField(
            controller: _url,
            style: TextStyle(color: Neon.textHi, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'https://your-server  or  http://192.168.1.5:3000',
              hintStyle: TextStyle(color: Neon.textDim),
              filled: true,
              fillColor: Neon.surface,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 8),
          // Wraps to a second line on narrow screens / large text.
          Wrap(spacing: 10, runSpacing: 8, children: [
            // The theme's buttons (2026-09-30): Save the lit primary, the
            // check a rim-only secondary.
            FilledButton(
              onPressed: _saveUrl,
              child: const Text('Save'),
            ),
            OutlinedButton(
              onPressed: _checking ? null : _checkHealth,
              child: Text(_checking ? 'Checking…' : 'Test /health'),
            ),
            // SELF-CHECK (2026-10-09): every check, with the log, to support.
            OutlinedButton(
              onPressed: () async {
                final ok = await SelfCheck.instance.run('button');
                if (!context.mounted) return;
                AppFeedback.show(
                  ok ? 'Self-check sent to support.' : "Couldn't send it now. It will go with the next check.",
                  context: context,
                  tone: ok ? FeedbackTone.success : FeedbackTone.error,
                );
              },
              child: const Text('Send self-check'),
            ),
          ]),
          if (_healthResult != null) ...[
            const SizedBox(height: 10),
            _panel(
              _healthResult!,
              color: _healthResult!.startsWith('HTTP 200')
                  ? Neon.successInk
                  : Neon.errorInk,
            ),
          ],
          const SizedBox(height: 24),
          const GroupLabel('Status'),
          AnimatedBuilder(
            animation: engine,
            builder: (_, __) => _panel(
              'Assistant stream: '
              '${engine.connected ? 'CONNECTED' : 'NOT CONNECTED'}'
              '\nPhase: ${engine.phase.name}'
              '${engine.errorMessage != null ? '\nLast error: ${engine.errorMessage}' : ''}',
              color: engine.connected ? Neon.successInk : Neon.warningInk,
            ),
          ),
          const SizedBox(height: 10),
          // Motion sensor actually in use. Many budget phones have no
          // gyroscope; we fall back to the accelerometer so the tilt
          // effects still work. 'none' means neither is available.
          _panel(
            'Motion sensor: ${GyroMotion.instance.sensorSource}',
            color: GyroMotion.instance.sensorSource == 'none'
                ? Neon.warningInk
                : Neon.successInk,
          ),
          const SizedBox(height: 24),
          // MCP lives in settings, never on the live agent screen — the
          // normal experience is "open the app and talk".
          const GroupLabel('Settings'),
          GroupedCard(
            dividerInset: 60,
            children: [
              AppleRow(
                leading:
                    IconTile(Icons.face_retouching_natural, AppleColors.purple),
                title: 'Assistant',
                subtitle: 'Voice, standing rules, app lock',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AssistantSettingsScreen())),
              ),
              AppleRow(
                leading: IconTile(Icons.extension_rounded, AppleColors.teal),
                title: 'Connected tools',
                subtitle: 'Extra tools your assistant can use (advanced)',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const McpServersScreen())),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const GroupLabel('App log'),
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
          color: Neon.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Neon.line),
        ),
        child: SelectableText(
          text,
          style: TextStyle(
            color: color ?? Neon.textLo,
            fontSize: mono ? 11.5 : 13,
            fontFamily: mono ? 'monospace' : null,
            height: 1.4,
          ),
        ),
      );
}
