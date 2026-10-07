import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../design/gyro_tilt.dart';
import '../../../design/motion.dart';
import '../../../design/neon_tokens.dart';
import '../../../design/neon_widgets.dart';
import '../../../models/user_document.dart';
import '../../../models/vision_result.dart';
// openDocument/documentGlyph live with the document tiles. The import
// is circular (document_tile imports this file for the gallery and the
// share helper) — Dart resolves that fine, and one shared open path is
// worth it: the two used to diverge, and this card still carried the
// launchUrl bug that made every saved PDF answer "sign in required".
import '../../../widgets/document_tile.dart'
    show openDocument, openDocumentFile, documentGlyph, documentTypeLabel;
import '../../../services/api_service.dart';
import '../../../ai/search_suggestions.dart';
import '../state/assistant_state.dart';
import 'package:video_player/video_player.dart';
import '../../../services/app_feedback.dart';

/// THE ASSISTANT'S CARDS ARE LIT (2026-09-30, the client's neon
/// reference). Each is a [GlowCard] whose rim says what it is — green done,
/// blue information, amber a decision waiting for you, magenta-to-orange
/// something to act on, purple something made for you, cyan the assistant
/// suggesting — the same meaning as everywhere else in the app. The old
/// glass card's edge (#141627 at 18%) was invisible on the navy.
class _LitCard extends StatelessWidget {
  final Widget child;
  final NeonTone tone;

  /// 0.35: the soft light every lit card has; 0.8: one that wants you.
  final double halo;
  final VoidCallback? onTap;
  final String? semanticLabel;
  const _LitCard({
    required this.child,
    this.tone = NeonTone.info,
    this.halo = 0.35,
    this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Margin stays OUTSIDE the tilt so the layout box never moves —
      // only the painted card floats with the device.
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: GyroTilt(
        radius: Neon.rLg,
        // The card's own halo is its light; a second, moving one doubled it.
        shadow: false,
        child: GlowCard(
          tone: tone,
          halo: halo,
          rimWidth: 1.6,
          padding: const EdgeInsets.all(14),
          onTap: onTap,
          semanticLabel: semanticLabel,
          child: child,
        ),
      ),
    );
  }
}

/// A card's button (2026-09-30, hierarchy by light): the way forward
/// ([primary]) is filled with its tone's gradient and glows; the other is
/// a rim and nothing more. 48 dp tall; it dips and ticks under the finger.
class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    this.icon,
    this.onTap,
    this.primary = false,
    this.tone = NeonTone.action,
    this.busy = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool primary;
  final NeonTone tone;

  /// Working: a small loader in place of the icon, and no taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    final enabled = tap != null && !busy;
    final rim = tone.rim;
    // Words on the gradient: whichever of white and ink reads there.
    final ink =
        primary ? Neon.textOn(Color.lerp(rim[0], rim[1], 0.5)!) : Neon.textLo;
    Widget body = Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: primary ? LinearGradient(colors: rim) : null,
        color: primary ? null : Neon.textHi.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(Neon.rPill),
        border: primary ? null : Border.all(color: Neon.lineBright, width: 1.2),
        boxShadow: primary && enabled ? Neon.halo(rim.first, strength: 1.2) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const NeonLoader.inline(size: 16, semanticLabel: 'Working')
          else if (icon != null)
            Icon(icon, size: 18, color: ink),
          if (busy || icon != null) const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NeonType.manrope(NeonType.callout, FontWeight.w700)
                  .copyWith(color: ink),
            ),
          ),
        ],
      ),
    );
    if (!enabled && !busy) body = Opacity(opacity: 0.5, child: body);
    if (enabled) {
      body = PressScale(
        scale: 0.96,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            tap();
          },
          child: body,
        ),
      );
    }
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? tap : null,
      excludeSemantics: true,
      child: body,
    );
  }
}

/// THE MOMENT IT WORKED (2026-09-30): the lit tick and a word, in a row
/// on the card that did it.
class _DoneLine extends StatelessWidget {
  const _DoneLine(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          const NeonSuccess(size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: NeonType.manrope(NeonType.callout, FontWeight.w700)
                  .copyWith(color: NeonTone.success.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "what I'm doing" chip — one per tool run.
class ToolCard extends StatelessWidget {
  final ToolActivity activity;
  const ToolCard({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    return _LitCard(
      // Running: information; done: green, with the lit tick.
      tone: activity.completed ? NeonTone.success : NeonTone.info,
      child: Row(
        children: [
          activity.completed
              ? const NeonSuccess(size: 20)
              : const NeonLoader.inline(size: 16, semanticLabel: 'Working'),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              activity.label,
              style: TextStyle(
                color: Neon.textHi,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One web search hit — tappable to open the source.
/// GOOGLE'S SEARCH SUGGESTIONS for a Google-Search-grounded answer — the
/// Gemini API's grounding terms require them beside the answer. Each chip
/// opens that Google search.
class SearchSuggestionChips extends StatelessWidget {
  final List<SearchSuggestion> suggestions;
  const SearchSuggestionChips({super.key, required this.suggestions});

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 15, color: Neon.textLo),
            const SizedBox(width: 4),
            Text('Google',
                style: TextStyle(color: Neon.textLo, fontSize: 12, fontWeight: FontWeight.w700)),
          ],
        ),
        for (final s in suggestions)
          Semantics(
            button: true,
            label: 'Search Google for ${s.label}',
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () {
                final u = Uri.tryParse(s.url);
                if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 36),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Neon.surfaceHigh,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(s.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Neon.textHi, fontSize: 13)),
              ),
            ),
          ),
      ],
    );
  }
}

class SearchResultCard extends StatelessWidget {
  final SearchResult result;
  const SearchResultCard({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return _LitCard(
        onTap: () {
          final u = Uri.tryParse(result.url);
          if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.public_rounded,
                    size: 14, color: NeonTone.tip.ink),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    result.source,
                    style: TextStyle(
                      color: Neon.textDim,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.open_in_new_rounded,
                    size: 14, color: Neon.textDim),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              result.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Neon.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (result.snippet.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                result.snippet,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Neon.textLo,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
    );
  }
}

/// A resolved (or candidate) contact.
class ContactCard extends StatelessWidget {
  final ContactMatch contact;
  final VoidCallback? onTap; // set when the user must choose among several
  final bool selected;
  const ContactCard({
    super.key,
    required this.contact,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial =
        contact.name.isNotEmpty ? contact.name[0].toUpperCase() : '?';
    final cyan = NeonTone.tip.rim.first;
    return _LitCard(
        // The chosen one glows; the others are information.
        tone: selected ? NeonTone.tip : NeonTone.info,
        halo: selected ? 0.8 : 0.35,
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: Neon.tile(cyan),
              ),
              child: Text(initial,
                  style: TextStyle(
                      color: Neon.onTile(cyan), fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(contact.name,
                      style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  Text(contact.phone,
                      style: TextStyle(
                          color: Neon.textDim,
                          fontSize: 13)),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  color: Neon.textDim),
          ],
        ),
    );
  }
}

/// Live call status — timeline dots for dialing → ringing → in call → done.
class CallStatusCard extends StatelessWidget {
  final CallStatusInfo status;
  const CallStatusCard({super.key, required this.status});

  // Mirrors the backend's agent-call state machine (dialing → in_progress →
  // summarizing → completed), so the progress dots actually advance while
  // Hari is on the phone instead of sitting on step one the whole time.
  static const _steps = ['dialing', 'in_progress', 'summarizing', 'completed'];

  @override
  Widget build(BuildContext context) {
    final failed = status.status == 'failed' || status.status == 'no_answer';
    final idx = _steps.indexOf(status.status);
    // Green while it goes well, the danger tone when it did not
    // (2026-09-30: an off-palette green #35C48D before).
    final ok = NeonTone.success.ink, bad = NeonTone.danger.ink;
    return _LitCard(
      tone: failed ? NeonTone.danger : NeonTone.success,
      child: Column(
        // 2026-09-30 visual QA: shrink-wrap — in the voice screen the card was
        // given all the room above the text box and stretched into an empty panel.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.phone_missed_rounded : Icons.phone_in_talk_rounded,
                size: 18,
                color: failed ? bad : ok,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${status.label} — ${status.contactName}',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (!failed) ...[
            const SizedBox(height: 12),
            Row(
              children: List.generate(_steps.length * 2 - 1, (i) {
                if (i.isOdd) {
                  final done = i ~/ 2 < idx;
                  return Expanded(
                    child: Container(
                      height: 2,
                      color: done ? ok : Neon.line,
                    ),
                  );
                }
                final step = i ~/ 2;
                final done = step <= idx;
                final current = step == idx && status.status != 'completed';
                return Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? ok : Neon.lineBright,
                    boxShadow: current ? Neon.halo(ok, strength: 1.2) : null,
                  ),
                );
              }),
            ),
            const SizedBox(height: 6),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StepLabel('Dialing'),
                _StepLabel('Ringing'),
                _StepLabel('In call'),
                _StepLabel('Done'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  final String text;
  const _StepLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style:
            TextStyle(color: Neon.textDim, fontSize: 12),
      );
}

/// "Should I place this call?" — always shown before dialing.
///
/// A DECISION WAITING FOR YOU (2026-09-30): an amber rim with its glow;
/// the way forward filled and glowing, Cancel a rim only; and a yes lands
/// with the lit tick while the card goes.
class ConfirmationCard extends StatefulWidget {
  final PendingConfirmation pending;
  final void Function(bool approved) onDecision;
  const ConfirmationCard({
    super.key,
    required this.pending,
    required this.onDecision,
  });

  @override
  State<ConfirmationCard> createState() => _ConfirmationCardState();
}

class _ConfirmationCardState extends State<ConfirmationCard> {
  bool _approved = false;
  bool _decided = false; // either button: a double tap answers once

  void _decide(bool approved) {
    if (_decided) return;
    _decided = true;
    if (approved) setState(() => _approved = true);
    widget.onDecision(approved);
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    final isCall = pending.action == 'place_call';
    return _LitCard(
      tone: NeonTone.warning,
      halo: 0.8,
      child: Column(
        // 2026-09-30 visual QA: shrink-wrap — in the voice screen the card was
        // given all the room above the text box and stretched into an empty panel.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.verified_user_outlined,
                  size: 18, color: NeonTone.warning.ink),
              const SizedBox(width: 8),
              Text(
                isCall ? 'Confirm this call' : 'Confirm',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (isCall && pending.contact != null) ...[
            Text(
              'Call ${pending.contact!.name} (${pending.contact!.phone}) and say:',
              style: TextStyle(
                  color: Neon.textLo, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Neon.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '“${pending.spokenPreview ?? pending.message ?? ''}”',
                style: TextStyle(
                    color: Neon.textHi,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    height: 1.4),
              ),
            ),
          ] else
            Text(
              pending.question ?? 'Shall I go ahead?',
              style: TextStyle(color: Neon.textHi, fontSize: 15),
            ),
          if (_approved)
            _DoneLine(isCall ? 'Placing the call' : 'Confirmed')
          else ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _CardButton(
                    label: 'Cancel',
                    onTap: () => _decide(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _CardButton(
                    label: isCall ? 'Place call' : 'Confirm',
                    icon: isCall ? Icons.call_rounded : Icons.check_rounded,
                    primary: true,
                    tone: isCall ? NeonTone.success : NeonTone.action,
                    onTap: () => _decide(true),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// An event read off a picture the user picked — "Priya's wedding, Sun 4
/// Oct, 11:00 AM" — with the two things people do with one: a reminder,
/// or the phone's calendar. One tap each; ✕ leaves it.
class EventOfferCard extends StatefulWidget {
  final VisionAction event;
  final Future<bool> Function() onRemind;
  final Future<bool> Function() onCalendar;
  final VoidCallback onClose;
  const EventOfferCard({
    super.key,
    required this.event,
    required this.onRemind,
    required this.onCalendar,
    required this.onClose,
  });

  @override
  State<EventOfferCard> createState() => _EventOfferCardState();
}

class _EventOfferCardState extends State<EventOfferCard> {
  bool _busy = false;

  /// What worked, for the lit tick (2026-09-30); null until something did.
  String? _done;

  Future<void> _run(Future<bool> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (ok && mounted) setState(() => _done = done);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final where = (e.location ?? '').trim();
    return _LitCard(
      // The assistant suggesting: cyan.
      tone: NeonTone.tip,
      halo: 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.event_rounded, size: 18, color: NeonTone.tip.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  e.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                padding: EdgeInsets.zero,
                onPressed: widget.onClose,
                icon: Icon(Icons.close_rounded, color: Neon.textLo, size: 20),
              ),
            ],
          ),
          Text(
            where.isEmpty ? e.whenLabel() : '${e.whenLabel()} · $where',
            style: TextStyle(color: Neon.textLo, fontSize: 14),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CardButton(
                  label: 'Remind me',
                  icon: Icons.alarm_add_rounded,
                  primary: true,
                  busy: _busy,
                  onTap: () => _run(widget.onRemind, 'Reminder set'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CardButton(
                  label: 'Add to calendar',
                  icon: Icons.calendar_month_rounded,
                  onTap: _busy
                      ? null
                      : () => _run(widget.onCalendar, 'Added to your calendar'),
                ),
              ),
            ],
          ),
          if (_done != null) _DoneLine(_done!),
        ],
      ),
    );
  }
}

/// A saved document Hari just recalled ("show me my Aadhaar card") — image
/// thumbnail or PDF badge + title/date/summary, with a Send button that
/// shares the real file out (WhatsApp, email, Drive…). Tap the card to
/// view: images open in a pinch-zoom viewer, PDFs in the system viewer.
class DocumentCard extends StatefulWidget {
  final UserDocument document;
  const DocumentCard({super.key, required this.document});

  @override
  State<DocumentCard> createState() => _DocumentCardState();
}

class _DocumentCardState extends State<DocumentCard> {
  bool _sending = false;

  UserDocument get document => widget.document;

  String get _date {
    if (document.docDate.isNotEmpty) return document.docDate;
    if (document.createdAt <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(document.createdAt);
    return '${d.day}/${d.month}/${d.year}';
  }

  void _open(BuildContext context) => openDocument(context, document);

  Future<void> _send() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await shareDocumentFile(document);
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't prepare that to send.", context: context);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _LitCard(
      child: Column(
        // 2026-09-30 visual QA: shrink-wrap — in the voice screen the card was
        // given all the room above the text box and stretched into an empty panel.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _open(context),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: !document.isImage
                        ? Builder(builder: (_) {
                            final g = documentGlyph(document);
                            return Container(
                              color: Neon.surfaceHigh,
                              child: Icon(g.icon, color: g.color, size: 26),
                            );
                          })
                        : Image.network(
                            ApiService.documentFileUrl(document.id),
                            headers: ApiService.imageHeaders,
                            fit: BoxFit.cover,
                            // Decode at ~2x the 56px display size, not full
                            // resolution — a big memory saving in a list.
                            cacheWidth: 130,
                            errorBuilder: (_, __, ___) => Container(
                              color: Neon.surfaceHigh,
                              child: Icon(Icons.description_rounded,
                                  color: Neon.cyan, size: 24),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        document.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Neon.textHi,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_date.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(_date,
                            style: TextStyle(
                                color: Neon.textLo, fontSize: 12)),
                      ],
                      if (document.summary.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          document.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Neon.textLo,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.open_in_full_rounded,
                    size: 16, color: Neon.textDim),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _CardButton(
                  label: _sending ? 'Preparing…' : 'Send',
                  icon: Icons.send_rounded,
                  primary: true,
                  tone: NeonTone.info,
                  busy: _sending,
                  onTap: _send,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Downloads the real bytes to a temp file with a clean, human name and
/// opens the system share sheet. The temp file is safe to leave — the OS
/// clears the cache dir; naming it well means the recipient sees
/// "Aadhaar Card.jpg", never "voice_save_1785…jpg". Throws on failure so
/// callers can show their own error UI.
Future<void> shareDocumentFile(UserDocument document) async {
  final file = await ApiService.downloadDocument(document.id);
  final dir = await getTemporaryDirectory();
  final safeName = shareFileName(document, file.mime);
  final path = '${dir.path}/$safeName';
  await File(path).writeAsBytes(file.bytes, flush: true);
  await Share.shareXFiles(
    [XFile(path, mimeType: file.mime, name: safeName)],
    subject: document.title,
  );
}

/// A clean filename for sharing — the document's own title (so the
/// recipient sees "Aadhaar Card.jpg", not the internal save name), with a
/// correct extension derived from the mime type.
///
/// Every type the server serves, then the document's own extension: only
/// PDF and three image types were known here, so a deck, a Word file, a
/// sheet or a video note went out as "<title>.jpg" and opened nowhere
/// (2026-09-27).
String shareFileName(UserDocument d, String mime) {
  var base = d.title.trim();
  if (base.isEmpty) base = 'document';
  // Strip anything filesystem-hostile; collapse whitespace.
  base = base.replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final ext = extensionForMime(mime) ?? d.fileExtension;
  return base.toLowerCase().endsWith(ext) ? base : '$base$ext';
}

/// A written piece Hari just COMPOSED ("generate a script for my speech")
/// — title + preview with one tap into a full-screen reader built for
/// actually delivering the speech: big type, scroll, copy, share.
class ScriptCard extends StatelessWidget {
  final String title;
  final String content;
  final VoidCallback? onClose;
  const ScriptCard(
      {super.key, required this.title, required this.content, this.onClose});

  void _openReader(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _TextReaderPage(title: title, content: content),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Something made for you: purple.
    return _LitCard(
        tone: NeonTone.discovery,
        onTap: () => _openReader(context),
        semanticLabel: 'Open $title full screen',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.description_rounded,
                    color: NeonTone.discovery.ink, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // 44 dp targets (were ~27 dp), with names for screen readers.
                IconButton(
                  tooltip: 'Share',
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                  padding: EdgeInsets.zero,
                  onPressed: () => Share.share(content, subject: title),
                  icon: Icon(Icons.share_rounded,
                      color: NeonTone.tip.ink, size: 19),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: 'Close',
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: EdgeInsets.zero,
                    onPressed: onClose,
                    icon: Icon(Icons.close_rounded,
                        color: Neon.textLo, size: 19),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                content,
                maxLines: 7,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  color: Neon.textHi,
                  fontSize: 14,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap to open full screen',
              style: TextStyle(
                color: NeonTone.discovery.ink,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
    );
  }
}

/// Full-screen reader — the "deliver the speech from your phone" view.
class _TextReaderPage extends StatelessWidget {
  final String title;
  final String content;
  const _TextReaderPage({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.textHi,
        title:
            Text(title, style: const TextStyle(fontSize: 16), maxLines: 1),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 20),
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              AppFeedback.copied(context);
            },
          ),
          IconButton(
            icon: const Icon(Icons.share_rounded, size: 20),
            tooltip: 'Share',
            onPressed: () => Share.share(content, subject: title),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 48),
        child: SelectableText(
          content,
          style: TextStyle(
            color: Neon.textHi,
            fontSize: 17,
            height: 1.6,
          ),
        ),
      ),
    );
  }
}

/// An image Hari just CREATED ("draw me a poster for the café") — shown
/// big, because this is the showpiece moment: the full square render with
/// a share button so it can go straight to WhatsApp. Tap for pinch-zoom.
/// The file is already saved server-side as a document.
class GeneratedImageCard extends StatefulWidget {
  final UserDocument document;
  final String prompt;
  final VoidCallback? onClose;
  const GeneratedImageCard(
      {super.key, required this.document, this.prompt = '', this.onClose});

  @override
  State<GeneratedImageCard> createState() => _GeneratedImageCardState();
}

class _GeneratedImageCardState extends State<GeneratedImageCard> {
  bool _sending = false;

  bool get _isVideo => widget.document.mime.startsWith('video/');

  // A generated video used to render as a static film icon — there was no
  // way to watch the thing the assistant had just said was on screen.
  VideoPlayerController? _video;
  bool _videoFailed = false;

  @override
  void initState() {
    super.initState();
    if (_isVideo) _startVideo();
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Future<void> _startVideo() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(ApiService.documentFileUrl(widget.document.id)),
        httpHeaders: ApiService.imageHeaders,
      );
      _video = c;
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _videoFailed = true);
    }
  }

  Future<void> _share() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final file = await ApiService.downloadDocument(widget.document.id);
      final dir = await getTemporaryDirectory();
      final safeName = shareFileName(widget.document, file.mime);
      final path = '${dir.path}/$safeName';
      await File(path).writeAsBytes(file.bytes, flush: true);
      await Share.shareXFiles(
        [XFile(path, mimeType: file.mime, name: safeName)],
        subject: widget.document.title,
      );
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't prepare that to share.", context: context);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Something made for you: purple, and lit a little more — it is the
    // showpiece.
    return _LitCard(
      tone: NeonTone.discovery,
      halo: 0.6,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _isVideo
                  ? (_video != null && _video!.value.isInitialized
                      ? GestureDetector(
                          onTap: () => setState(() {
                            _video!.value.isPlaying
                                ? _video!.pause()
                                : _video!.play();
                          }),
                          child: AspectRatio(
                            aspectRatio: _video!.value.aspectRatio,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(_video!),
                                if (!_video!.value.isPlaying)
                                  Container(
                                    alignment: Alignment.center,
                                    color: Neon.scrim,
                                    child: Icon(Icons.play_arrow_rounded,
                                        color: Neon.textHi, size: 54,
                                        semanticLabel: 'Play'),
                                  ),
                              ],
                            ),
                          ),
                        )
                      : Container(
                          height: 160,
                          alignment: Alignment.center,
                          color: Neon.surfaceHigh,
                          child: _videoFailed
                              ? Icon(Icons.movie_rounded,
                                  color: Neon.cyan, size: 42)
                              : const NeonLoader(
                                  size: 36, semanticLabel: 'Loading the video'),
                        ))
                  : GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DocumentGalleryScreen(
                              documents: [widget.document]),
                        ),
                      ),
                      child: Image.network(
                        ApiService.documentFileUrl(widget.document.id),
                        headers: ApiService.imageHeaders,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        // Card preview, not the viewer — 900 px is past
                        // any phone's card width. The FULL-SCREEN gallery
                        // further down is deliberately left uncapped
                        // because it pinch-zooms to 6x, where a cap shows
                        // up immediately as mush.
                        cacheWidth: 900,
                        loadingBuilder: (context, child, p) => p == null
                            ? child
                            : Container(
                                height: 200,
                                alignment: Alignment.center,
                                color: Neon.surfaceHigh,
                                child: const NeonLoader(
                                    size: 36,
                                    semanticLabel: 'Loading the image'),
                              ),
                        errorBuilder: (_, __, ___) => Container(
                          height: 120,
                          alignment: Alignment.center,
                          color: Neon.surfaceHigh,
                          child: Text("Couldn't load the image.",
                              style: TextStyle(color: Neon.textLo)),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded,
                  color: NeonTone.discovery.ink, size: 16),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  widget.prompt.isNotEmpty
                      ? widget.prompt
                      : widget.document.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Neon.textLo,
                    fontSize: 13,
                    height: 1.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _sending
                  ? const SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                          child: NeonLoader.inline(
                              size: 20, semanticLabel: 'Preparing to share')),
                    )
                  : IconButton(
                      tooltip: 'Share',
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                      padding: EdgeInsets.zero,
                      onPressed: _share,
                      icon: Icon(Icons.share_rounded,
                          color: NeonTone.tip.ink, size: 20),
                    ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: 'Close',
                  constraints:
                      const BoxConstraints(minWidth: 44, minHeight: 44),
                  padding: EdgeInsets.zero,
                  onPressed: widget.onClose,
                  icon: Icon(Icons.close_rounded,
                      color: Neon.textLo, size: 20),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Full-screen gallery for recalled documents — "show me Chetan's
/// evidence" pops this over whatever screen the user is on. Swipe
/// sideways through the set, pinch to zoom, share the real file, close
/// with the X, back, or a downward swipe on the black margins.
class DocumentGalleryScreen extends StatefulWidget {
  final List<UserDocument> documents;
  final int initialIndex;

  /// When given, a Delete action appears. It must perform the deletion
  /// (with its own confirmation) and return true ONLY when the server
  /// confirmed — the gallery then drops the page, or closes if empty.
  final Future<bool> Function(UserDocument)? onDelete;

  const DocumentGalleryScreen(
      {super.key,
      required this.documents,
      this.initialIndex = 0,
      this.onDelete});

  @override
  State<DocumentGalleryScreen> createState() => _DocumentGalleryScreenState();
}

class _DocumentGalleryScreenState extends State<DocumentGalleryScreen> {
  late final PageController _page =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _sharing = false;
  bool _deleting = false;
  late final List<UserDocument> _docs = List.of(widget.documents);

  UserDocument get _current => _docs[_index];

  Future<void> _delete() async {
    final cb = widget.onDelete;
    if (cb == null || _deleting) return;
    setState(() => _deleting = true);
    bool ok = false;
    try {
      ok = await cb(_current);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!ok || !mounted) return;
    setState(() {
      _docs.removeAt(_index);
      if (_index >= _docs.length) _index = _docs.length - 1;
    });
    if (_docs.isEmpty) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _share() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      await shareDocumentFile(_current);
    } catch (_) {
      if (mounted) {
        AppFeedback.show("Couldn't prepare that to send.", context: context);
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = _docs;
    // THE NAVY NIGHT, NOT BLACK (2026-09-30): the app's own ground under
    // the pictures, so the gallery belongs to the app.
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.textHi,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_current.title,
                style: const TextStyle(fontSize: 16),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            if (docs.length > 1)
              Text('${_index + 1} of ${docs.length}',
                  style: TextStyle(fontSize: 12, color: Neon.textLo)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: _sharing
                ? const NeonLoader.inline(semanticLabel: 'Preparing to share')
                : const Icon(Icons.share_rounded),
            onPressed: _sharing ? null : _share,
          ),
          if (widget.onDelete != null)
            IconButton(
              tooltip: 'Delete',
              icon: _deleting
                  ? const NeonLoader.inline(semanticLabel: 'Deleting')
                  : const Icon(Icons.delete_outline_rounded),
              onPressed: _deleting ? null : _delete,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Dismissible(
        key: const ValueKey('document-gallery'),
        direction: DismissDirection.down,
        onDismissed: (_) => Navigator.of(context).pop(),
        child: PageView.builder(
          controller: _page,
          itemCount: docs.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) {
            final d = docs[i];
            if (d.mime.startsWith('video/')) {
              // Without this an MP4 fell through to Image.network and drew
              // the broken-image placeholder full screen.
              return _GalleryVideo(key: ValueKey('gv-${d.id}'), document: d);
            }
            if (!d.isImage) {
              // No in-app PDF or office-file renderer (kept the app light):
              // the type's glyph and one Open. Open is the signed-in
              // download the Documents list uses — the file URL handed to
              // a browser has no session and answered "sign in required",
              // and a deck or sheet fell through to Image.network and drew
              // "Couldn't load this document." (2026-09-27).
              final g = documentGlyph(d);
              final type = documentTypeLabel(d);
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(g.icon, color: g.color, size: 64),
                    const SizedBox(height: 14),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(d.title,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Neon.textHi)),
                    ),
                    if (type.isNotEmpty && !d.isPdf) ...[
                      const SizedBox(height: 4),
                      Text(type, style: TextStyle(color: Neon.textLo)),
                    ],
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Neon.textHi,
                        minimumSize: const Size(120, 48),
                        side: BorderSide(color: Neon.lineBright),
                      ),
                      onPressed: () => openDocumentFile(d),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: Text(d.isPdf ? 'Open PDF' : 'Open'),
                    ),
                  ],
                ),
              );
            }
            return Center(
              child: InteractiveViewer(
                maxScale: 6,
                child: Image.network(
                  ApiService.documentFileUrl(d.id),
                  headers: ApiService.imageHeaders,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, p) => p == null
                      ? child
                      : const NeonLoader.page(),
                  errorBuilder: (_, __, ___) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text("Couldn't load this document.",
                        style: TextStyle(color: Neon.textLo)),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}


/// One video page inside the full-screen gallery. Owns its controller so
/// swiping between pages cannot leave a player running off screen.
class _GalleryVideo extends StatefulWidget {
  final UserDocument document;
  const _GalleryVideo({super.key, required this.document});

  @override
  State<_GalleryVideo> createState() => _GalleryVideoState();
}

class _GalleryVideoState extends State<_GalleryVideo> {
  VideoPlayerController? _c;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final c = VideoPlayerController.networkUrl(
        Uri.parse(ApiService.documentFileUrl(widget.document.id)),
        httpHeaders: ApiService.imageHeaders,
      );
      _c = c;
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Center(
        child: Icon(Icons.movie_rounded, color: Neon.textDim, size: 64,
            semanticLabel: "Couldn't play this video"),
      );
    }
    final c = _c;
    if (c == null || !c.value.isInitialized) {
      return const NeonLoader.page(semanticLabel: 'Loading the video');
    }
    return Center(
      child: GestureDetector(
        onTap: () => setState(
            () => c.value.isPlaying ? c.pause() : c.play()),
        child: AspectRatio(
          aspectRatio: c.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(c),
              if (!c.value.isPlaying)
                Container(
                  alignment: Alignment.center,
                  color: Neon.scrim,
                  child: Icon(Icons.play_arrow_rounded,
                      color: Neon.textHi, size: 64, semanticLabel: 'Play'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
