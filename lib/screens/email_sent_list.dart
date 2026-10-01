import 'package:flutter/material.dart';

import '../design/apple_kit.dart' show GroupedCard, IconTile;
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonLoader;
import '../services/api_service.dart';

/// SENT MAIL — the Email screen's whole content.
///
/// The assistant sends by voice; this is the record of it. Tapping a row
/// opens that exact message in Gmail (the app handles mail.google.com
/// links), so the real client is always one tap away.
class EmailSentList extends StatefulWidget {
  const EmailSentList({super.key});

  @override
  State<EmailSentList> createState() => EmailSentListState();
}

class EmailSentListState extends State<EmailSentList> {
  List<Map<String, dynamic>>? _sent;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await ApiService.getJson('/email/sent?limit=30',
        timeout: const Duration(seconds: 15));
    if (!mounted) return;
    setState(() => _sent = ((r?['sent'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList());
  }

  static String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final hh = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ap = d.hour < 12 ? 'am' : 'pm';
    if (sameDay) return '$hh:$mm $ap';
    const mo = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${mo[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    if (_sent == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: NeonLoader.page(label: 'Loading your sent mail…'),
      );
    }
    final sent = _sent!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text('SENT',
                  style: NeonType.sectionLabel.copyWith(color: Neon.textLo)),
            ),
            const Spacer(),
            // 48 dp to the finger (2026-09-30): it was an 18 dp glyph.
            IconButton(
              tooltip: 'Refresh',
              onPressed: () {
                setState(() => _sent = null);
                load();
              },
              icon: Icon(Icons.refresh_rounded, size: 20, color: Neon.textLo),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (sent.isEmpty)
          // In the lit group, the mic on its tile (2026-09-30). Not the
          // page's NeonEmptyState: that one scrolls, and this sits inside
          // the Email page's own list.
          GroupedCard(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
              child: Column(
                children: [
                  IconTile(Icons.mic_rounded, Neon.violet, size: 44),
                  const SizedBox(height: 12),
                  Text('Nothing sent yet',
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    'Go back, tap the mic and say "send a mail to ravi@example.com '
                    'saying I\'ll be there by six". Ask again later and just '
                    'say "the same address" — I remember who you write to.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Neon.textLo, fontSize: 13, height: 1.45),
                  ),
                ],
              ),
            ),
          ])
        else
          // One lit group, like every list in the app (2026-09-30).
          GroupedCard(
            dividerInset: 62,
            children: [
              for (var i = 0; i < sent.length; i++)
                Reveal(delayMs: 30 * i, child: _row(sent[i])),
            ],
          ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final label = (m['label'] ?? '').toString();
    final to = (m['to'] ?? '').toString();
    final subject = (m['subject'] ?? '(no subject)').toString();
    final preview = (m['preview'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: IconTile(Icons.north_east_rounded, Neon.violet),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label.isNotEmpty ? '$label · $to' : to,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Neon.textHi,
                            fontSize: 14,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_when((m['at'] as num?)?.toInt() ?? 0),
                        style: TextStyle(color: Neon.textDim, fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Neon.textLo,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Neon.textLo, fontSize: 12, height: 1.3)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
