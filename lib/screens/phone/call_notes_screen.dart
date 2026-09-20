import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../services/call_notes_service.dart';
import '../../services/call_recording_watcher.dart';
import 'call_detail_screen.dart';

/// CALL NOTES — the phone keeps its own dialer and its own recorder; this
/// screen owns the consent toggle, walks the user to the system setting
/// that turns recording on, and shows what the assistant understood from
/// each analysed call.
class CallNotesScreen extends StatefulWidget {
  const CallNotesScreen({super.key});

  @override
  State<CallNotesScreen> createState() => _CallNotesScreenState();
}

class _CallNotesScreenState extends State<CallNotesScreen> {
  final svc = CallNotesService.instance;

  @override
  void initState() {
    super.initState();
    svc.start();
    svc.addListener(_sync);
    svc.refreshRecent();
    CallRecordingWatcher.instance.scan();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    svc.removeListener(_sync);
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    if (!on) {
      await svc.setAnalysis(false);
      return;
    }
    final agreed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Neon.surface,
        title: Text('Analyse your calls?',
            style: TextStyle(color: Neon.textHi, fontSize: 17)),
        content: Text(
          'Your phone\'s own dialer records your calls (both sides). With '
          'this on, each new recording is read, transcribed and understood '
          '— meetings, promises, tasks and deadlines land on your agenda '
          'automatically, and you can ask things like "what did I discuss '
          'with Ramesh four days back".\n\n'
          '• Only calls recorded AFTER you turn this on are read.\n'
          '• Uploaded audio is deleted right after transcription; your '
          'recording files on the phone are never touched.\n'
          '• Depending on where you live, you may need to tell the other '
          'person the call is recorded. That part is on you.',
          style: TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.45),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('I agree — turn on')),
        ],
      ),
    );
    if (agreed != true) return;
    await CallRecordingWatcher.instance.ensurePermission();
    final ok = await svc.setAnalysis(true);
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("Couldn't save the setting — try again.")));
      }
      return;
    }
    CallRecordingWatcher.instance.scan();
    // Straight to where the system recorder is switched on — that is the
    // half of the setup only the user can do.
    if (mounted) _showRecorderGuide();
  }

  void _showRecorderGuide() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Neon.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('One more step — on your phone',
                style: GoogleFonts.spaceGrotesk(
                    color: Neon.textHi,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text(
              'Turn on your phone\'s own call recording:\n\n'
              '1. The call settings screen opens next.\n'
              '2. Tap "Record calls" (Samsung) or "Recording".\n'
              '3. Switch on "Auto record calls".\n\n'
              'From then on, every recorded call is analysed here '
              'automatically.',
              style:
                  TextStyle(color: Neon.textLo, fontSize: 13.5, height: 1.5),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final ok = await svc.openSystemCallSettings();
                  if (!ok && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Open your Phone app → Settings → Record calls.')));
                  }
                },
                child: const Text('Open call settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final calls = svc.recent;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        elevation: 0,
        iconTheme: IconThemeData(color: Neon.textHi),
        title: Text('Call notes',
            style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi,
                fontWeight: FontWeight.w700,
                fontSize: 20)),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: Neon.violet,
          onRefresh: () async {
            await CallRecordingWatcher.instance.scan();
            await svc.refreshRecent();
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
            children: [
              // The toggle card — the single switch the user asked for.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Neon.surface,
                  borderRadius: BorderRadius.circular(Neon.rLg),
                  border: Border.all(color: Neon.line),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Neon.violet.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.graphic_eq_rounded,
                              color: Neon.violet, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('AI call analysis',
                                  style: TextStyle(
                                      color: Neon.textHi,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                              Text(
                                'Reads your phone\'s call recordings and '
                                'files what was agreed.',
                                style: TextStyle(
                                    color: Neon.textLo, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: svc.analysisEnabled,
                          activeThumbColor: Neon.violet,
                          onChanged: _toggle,
                        ),
                      ],
                    ),
                    if (svc.analysisEnabled) ...[
                      const SizedBox(height: 10),
                      InkWell(
                        onTap: _showRecorderGuide,
                        child: Row(
                          children: [
                            Icon(Icons.settings_phone_rounded,
                                size: 15, color: Neon.cyan),
                            const SizedBox(width: 7),
                            Text('Recorder setup / open call settings',
                                style: TextStyle(
                                    color: Neon.cyan,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text('Analysed calls',
                  style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi,
                      fontSize: 16,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (calls.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Text(
                    svc.analysisEnabled
                        ? 'No analysed calls yet. After your next recorded '
                            'call, open the app and it will appear here.'
                        : 'Turn on AI call analysis above to get notes, '
                            'reminders and answers from your calls.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Neon.textDim, fontSize: 13, height: 1.5),
                  ),
                )
              else
                for (final c in calls) _callTile(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _callTile(Map<String, dynamic> c) {
    final name = (c['peer_name'] ?? '').toString();
    final num_ = (c['peer_number'] ?? '').toString();
    final sum = (c['summary'] ?? '').toString();
    final status = (c['status'] ?? '').toString();
    final label = name.isNotEmpty ? name : (num_.isNotEmpty ? num_ : 'Call');
    final at = DateTime.fromMillisecondsSinceEpoch(
        (c['started_at'] as num?)?.toInt() ?? 0);
    final when = '${at.day}/${at.month} '
        '${at.hour % 12 == 0 ? 12 : at.hour % 12}:'
        '${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'am' : 'pm'}';
    return PressScale(
        child: GestureDetector(
      onTap: status == 'done'
          ? () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => CallDetailScreen(
                  callId: (c['id'] as num).toInt(), peerLabel: label)))
          : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(Neon.rMd),
          border: Border.all(color: Neon.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.call_rounded, size: 15, color: Neon.success),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                Text(when,
                    style: TextStyle(color: Neon.textDim, fontSize: 11.5)),
                if (status == 'done')
                  Icon(Icons.chevron_right_rounded,
                      color: Neon.textDim, size: 18),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              status == 'processing'
                  ? 'Understanding this call…'
                  : status == 'failed'
                      ? "Couldn't analyse this recording."
                      : (sum.isEmpty ? 'Analysed — tap for details.' : sum),
              style: TextStyle(
                  color: status == 'done' ? Neon.textLo : Neon.textDim,
                  fontSize: 12.5,
                  height: 1.4,
                  fontStyle:
                      status == 'done' ? FontStyle.normal : FontStyle.italic),
            ),
          ],
        ),
      ),
    ));
  }
}
