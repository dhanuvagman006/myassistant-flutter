import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../services/mic_probe.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  MIC TEST — a small debug screen, reached from Diagnostics.
///
///  Owner, 2026-09-25: "start talk while it works". Before the assistant
///  keeps listening while it works in another app, this checks on the
///  phone itself that the microphone still hears anything once the app is
///  off screen (the plan's P1 probe). Nothing starts until "Start mic test"
///  is tapped, and nothing is recorded or sent: see MicProbe.
/// ─────────────────────────────────────────────────────────────────────────
class MicProbeScreen extends StatelessWidget {
  const MicProbeScreen({super.key, this.probe});

  /// Tests pass their own; the app uses [MicProbe.instance].
  final MicProbe? probe;

  static const steps = '1. Tap Start mic test. A "Mic test running" '
      'notification appears.\n'
      '2. Press Home and open another app (Instagram is fine).\n'
      '3. Read one sentence aloud, then stay in that app for about '
      '20 seconds.\n'
      '4. Come back here. The test ends when you come back, after '
      '60 seconds, when the screen turns off, or on Stop in the '
      'notification.\n\n'
      'Nothing is recorded, kept or sent. The app only counts how loud '
      'each moment was.';

  @override
  Widget build(BuildContext context) {
    final p = probe ?? MicProbe.instance;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Mic test'),
      body: AnimatedBuilder(
        animation: p,
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
          children: [
            const GroupLabel('How to run it'),
            _panel(steps),
            const SizedBox(height: 12),
            Wrap(spacing: 10, runSpacing: 8, children: [
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Neon.violet,
                    foregroundColor: Neon.onAccent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                onPressed: p.busy ? null : p.start,
                child: Text(p.phase == MicProbePhase.starting
                    ? 'Starting…'
                    : 'Start mic test'),
              ),
              if (p.busy)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppleColors.red,
                      side: BorderSide(color: Neon.line),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                  onPressed: p.stop,
                  child: const Text('Stop'),
                ),
            ]),
            const SizedBox(height: 24),
            const GroupLabel('Result'),
            _panel(_status(p), color: _statusColor(p)),
            if (p.phase != MicProbePhase.idle &&
                p.phase != MicProbePhase.failed) ...[
              const SizedBox(height: 10),
              _panel(p.counts.reportLines().join('\n'), mono: true),
            ],
          ],
        ),
      ),
    );
  }

  static String _status(MicProbe p) => switch (p.phase) {
        MicProbePhase.idle => 'Not run yet.',
        MicProbePhase.starting => 'Starting…',
        MicProbePhase.running => 'Running. Leave the app now.',
        MicProbePhase.done =>
          'Finished: ${MicProbe.wordsFor(p.counts.stopCode)}.',
        MicProbePhase.failed => 'Did not start. ${p.problem ?? ''}',
      };

  static Color _statusColor(MicProbe p) => switch (p.phase) {
        MicProbePhase.failed => AppleColors.red,
        MicProbePhase.done => p.counts.a1Pass == false
            ? AppleColors.orange
            : AppleColors.green,
        _ => Neon.textLo,
      };

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
