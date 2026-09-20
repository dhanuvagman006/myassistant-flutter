import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
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
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
            child: CircularProgressIndicator(strokeWidth: 2, color: Neon.violet)),
      );
    }
    final sent = _sent!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('SENT',
                style: TextStyle(
                    color: Neon.violet,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1)),
            const Spacer(),
            PressScale(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _sent = null);
                  load();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child:
                      Icon(Icons.refresh_rounded, size: 18, color: Neon.textDim),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (sent.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(Neon.rXl),
              border: Border.all(color: Neon.line),
            ),
            child: Column(
              children: [
                Icon(Icons.mic_rounded, size: 26, color: Neon.violet),
                const SizedBox(height: 10),
                Text('Nothing sent yet',
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(
                  'Tap the mic and say "send a mail to ravi@example.com '
                  'saying I\'ll be there by six". Ask again later and just '
                  'say "the same address" — I remember who you write to.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Neon.textLo, fontSize: 13, height: 1.45),
                ),
              ],
            ),
          )
        else
          for (var i = 0; i < sent.length; i++)
            Reveal(
              delayMs: 30 * i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _row(sent[i]),
              ),
            ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> m) {
    final label = (m['label'] ?? '').toString();
    final to = (m['to'] ?? '').toString();
    final subject = (m['subject'] ?? '(no subject)').toString();
    final preview = (m['preview'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(Neon.rLg),
            border: Border.all(color: Neon.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  gradient: Neon.gBrand,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(Icons.north_east_rounded,
                    size: 17, color: Colors.white),
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
                            label.isNotEmpty ? '$label · $to' : to,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Neon.textHi,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(_when((m['at'] as num?)?.toInt() ?? 0),
                            style: TextStyle(
                                color: Neon.textDim, fontSize: 11)),
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
                              color: Neon.textDim,
                              fontSize: 12,
                              height: 1.3)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
  }
}
