import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../design/apple_kit.dart';
import '../../design/motion.dart';
import '../../design/neon_tokens.dart';
import '../../design/neon_widgets.dart';
import '../../widgets/neon_cards.dart';
import '../../services/call_notes_service.dart';
import '../../services/call_recording_watcher.dart';
import 'call_detail_screen.dart';
import '../../services/app_feedback.dart';

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
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    svc.start();
    svc.addListener(_sync);
    svc.refreshRecent();
    CallRecordingWatcher.instance.scan();
    // "Analysing…" should turn into the summary without a pull-to-refresh.
    // Only while something is actually in flight — the list read is cheap,
    // but a screen left open shouldn't poll for nothing.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (svc.recent.any((c) => c['status'] == 'processing')) {
        svc.refreshRecent();
      }
    });
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _poll?.cancel();
    svc.removeListener(_sync);
    super.dispose();
  }

  Future<void> _toggle(bool on) async {
    if (!on) {
      await svc.setAnalysis(false);
      return;
    }
    final agreed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Analyse your calls?',
            style: TextStyle(color: Neon.textHi, fontSize: 17)),
        content: Text(
          'Your phone\'s own dialer records your calls (both sides). With '
          'this on, each new recording is read, transcribed and understood '
          '— meetings, promises, tasks and deadlines land on your agenda '
          'automatically, and you can ask things like "what did I discuss '
          'with Ramesh four days back".\n\n'
          '• Only calls recorded AFTER you turn this on are read, each '
          'one once — nothing older than a day.\n'
          '• Uploaded audio is deleted right after transcription; your '
          'recording files on the phone are never touched.\n'
          '• Depending on where you live, you may need to tell the other '
          'person the call is recorded. That part is on you.',
          style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.45),
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
        AppFeedback.show("Couldn't save the setting — try again.", context: context);
      }
      return;
    }
    CallRecordingWatcher.instance.scan();
    // Straight to where the system recorder is switched on — that is the
    // half of the setup only the user can do.
    if (mounted) _showRecorderGuide();
  }

  void _showRecorderGuide() {
    // The theme's sheet (2026-09-30): lit rim, night scrim, handle.
    showAppSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
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
              '2. Tap "Record calls" or "Recording".\n'
              '3. Switch on "Auto record calls".\n\n'
              'From then on, every recorded call is analysed here '
              'automatically.',
              style:
                  TextStyle(color: Neon.textLo, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  final ok = await svc.openSystemCallSettings();
                  if (!ok && mounted) {
                    AppFeedback.show('Open your Phone app → Settings → Record calls.', context: context);
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
    final groups = groupCalls(svc.recent, DateTime.now());
    final analysed = groups
        .expand((g) => g.calls)
        .where((c) => c['status'] == 'done')
        .length;
    final on = svc.analysisEnabled;
    // Under the night sky (2026-09-30).
    return NeonScaffold(
      appBar: appleAppBar(context, 'Call notes'),
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
              // The toggle card — the single switch the user asked for, and
              // the page's one lit card (2026-09-30): green while it works
              // for him, the app's own light while it waits to be turned on.
              GlowCard(
                tone: on ? NeonTone.success : NeonTone.brand,
                halo: 0.6,
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Row(
                      children: [
                        ToneTile(Icons.graphic_eq_rounded,
                            on ? NeonTone.success : NeonTone.brand,
                            size: 34),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('AI call analysis',
                                  style: NeonType.manrope(
                                          NeonType.callout, FontWeight.w700)
                                      .copyWith(color: Neon.textHi)),
                              Text(
                                'Reads your phone\'s call recordings and '
                                'files what was agreed.',
                                style: TextStyle(
                                    color: Neon.textLo,
                                    fontSize: NeonType.caption),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: svc.analysisEnabled,
                          onChanged: _toggle,
                        ),
                      ],
                    ),
                    _statusLine(on),
                    if (on) ...[
                      const SizedBox(height: 4),
                      // 48 dp to the finger, and it dips (2026-09-30).
                      Tappable(
                        onTap: _showRecorderGuide,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              Icon(Icons.settings_phone_rounded,
                                  size: 15, color: Neon.cyan),
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text('Set up call recording',
                                    style: NeonType.manrope(
                                            NeonType.footnote, FontWeight.w600)
                                        .copyWith(color: Neon.cyanInk)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text('Recent calls',
                          style: NeonType.sectionTitle
                              .copyWith(color: Neon.textHi)),
                    ),
                  ),
                  if (analysed > 0)
                    Text('$analysed analysed',
                        style: TextStyle(
                            color: Neon.textDim, fontSize: NeonType.caption)),
                ],
              ),
              const SizedBox(height: 4),
              if (groups.isEmpty)
                NeonEmptyState(
                  icon: Icons.phone_callback_rounded,
                  title: on ? 'No analysed calls yet' : 'No call notes yet',
                  body: on
                      ? 'After your next recorded call, open the app and it '
                          'will appear here.'
                      : 'Turn on AI call analysis above to get notes, '
                          'reminders and answers from your calls.',
                  tone: on ? NeonTone.success : NeonTone.brand,
                )
              else
                for (final g in groups) ...[
                  const SizedBox(height: 10),
                  GroupLabel(g.label),
                  for (final c in g.calls) _callTile(c),
                ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusLine(bool on) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: on ? Neon.success : Neon.textDim,
              shape: BoxShape.circle,
              boxShadow: on ? Neon.halo(Neon.success, strength: 0.6) : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              on
                  ? 'On — each new recorded call is analysed once.'
                  : 'Off — no recordings are read or uploaded.',
              style: TextStyle(color: Neon.textLo, fontSize: NeonType.caption),
            ),
          ),
        ],
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
    final done = status == 'done';
    final tint = avatarTint(label);
    final id = (c['id'] as num?)?.toInt();
    // The row grows into the call's page (2026-09-30): the page's header
    // card carries the same tag.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RimCard(
        // A call that could not be read says so in amber; one being read,
        // in the assistant's cyan.
        tone: status == 'processing'
            ? NeonTone.tip
            : status == 'failed'
                ? NeonTone.warning
                : null,
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        heroTag: done && id != null ? callHeroTag(id) : null,
        onTap: done && id != null
            ? () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CallDetailScreen(
                    callId: id, peerLabel: label, preview: c)))
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(color: tint.withValues(alpha: 0.5)),
              ),
              child: name.isNotEmpty
                  ? Text(name.characters.first.toUpperCase(),
                      style: NeonType.manrope(
                              NeonType.rowTitle, FontWeight.w700)
                          .copyWith(color: tint))
                  : Icon(Icons.phone_rounded, color: tint, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: NeonType.manrope(
                                  NeonType.callout, FontWeight.w600)
                              .copyWith(color: Neon.textHi),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(clockLabel(at),
                          style: TextStyle(
                              color: Neon.textDim,
                              fontSize: NeonType.caption)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  _callStatus(status, sum),
                ],
              ),
            ),
            SizedBox(
              width: 22,
              child: done
                  ? Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Icon(Icons.chevron_right_rounded,
                          color: Neon.textDim, size: 20),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  /// One line that says honestly where this call stands.
  Widget _callStatus(String status, String sum) {
    Widget chip(IconData icon, Color color, String text) => Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: color, fontSize: NeonType.footnote, height: 1.35)),
            ),
          ],
        );
    switch (status) {
      case 'done':
        return Text(sum.isEmpty ? 'Analysed — tap for details.' : sum,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Neon.textLo, fontSize: NeonType.footnote, height: 1.4));
      case 'processing':
        return Row(
          children: [
            const NeonLoader.inline(size: 13, semanticLabel: 'Analysing'),
            const SizedBox(width: 7),
            Text('Analysing…',
                style: TextStyle(
                    color: Neon.cyanInk, fontSize: NeonType.footnote)),
          ],
        );
      case 'skipped':
        return chip(Icons.do_not_disturb_on_outlined, Neon.textDim,
            sum.isEmpty ? 'Not analysed.' : sum);
      default: // failed
        return chip(Icons.error_outline_rounded, Neon.warningInk,
            sum.isEmpty ? "Couldn't analyse this call." : sum);
    }
  }
}

/// A day's worth of calls under one header.
class CallGroup {
  const CallGroup(this.label, this.calls);
  final String label;
  final List<Map<String, dynamic>> calls;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today", "Yesterday", or "Mon, 21 Sep".
String dayLabel(DateTime at, DateTime now) {
  final d = DateTime(at.year, at.month, at.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return '${_weekdays[at.weekday - 1]}, ${at.day} ${_months[at.month - 1]}';
}

/// "4:08 pm".
String clockLabel(DateTime at) =>
    '${at.hour % 12 == 0 ? 12 : at.hour % 12}:'
    '${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'am' : 'pm'}';

/// Newest first, one row per recording, grouped by day. The same
/// recording uploaded twice (an older server kept both) shows once —
/// the analysed copy wins.
List<CallGroup> groupCalls(List<Map<String, dynamic>> calls, DateTime now) {
  final best = <String, Map<String, dynamic>>{};
  for (final c in calls) {
    if (c['status'] == 'duplicate') continue;
    final key = '${c['started_at']}|${c['peer_name']}|${c['peer_number']}';
    final have = best[key];
    if (have == null || (have['status'] != 'done' && c['status'] == 'done')) {
      best[key] = c;
    }
  }
  final sorted = best.values.toList()
    ..sort((a, b) => ((b['started_at'] as num?) ?? 0)
        .compareTo((a['started_at'] as num?) ?? 0));
  final groups = <CallGroup>[];
  for (final c in sorted) {
    final at = DateTime.fromMillisecondsSinceEpoch(
        (c['started_at'] as num?)?.toInt() ?? 0);
    final label = dayLabel(at, now);
    if (groups.isEmpty || groups.last.label != label) {
      groups.add(CallGroup(label, []));
    }
    groups.last.calls.add(c);
  }
  return groups;
}

/// A steady colour per person, from the app's own accents.
Color avatarTint(String label) {
  final palette = [Neon.violet, Neon.cyan, Neon.pink, Neon.lime, Neon.success];
  var h = 0;
  for (final u in label.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return palette[h % palette.length];
}
