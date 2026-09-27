import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../models/mail_inbox.dart';
import '../services/app_feedback.dart';
import '../services/auth_service.dart';
import '../services/avatar_message_service.dart';
import '../services/mail_inbox_service.dart';
import 'documents_screen.dart';

/// Opens Bills by email from a notification tap, once the app has a
/// navigator and a signed-in user (the MomentumNav pattern).
abstract final class BillsEmailNav {
  static Future<void> open() async {
    for (var i = 0; i < 24; i++) {
      final nav = AvatarMessageService.navigatorKey.currentState;
      if (nav != null && AuthService.instance.user != null) {
        if (BillsEmailScreen.showing == 0) {
          unawaited(nav.push(MaterialPageRoute(builder: (_) => const BillsEmailScreen())));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}

/// ─────────────────────────────────────────────────────────────────────────
///  BILLS BY EMAIL (You → Bills by email, build 120).
///
///  The user's own private address: forward a bill, ticket or renewal to it
///  and it is saved in My documents with reminders. Shown only when the
///  server reports the feature available. Copy names no company.
/// ─────────────────────────────────────────────────────────────────────────
class BillsEmailScreen extends StatefulWidget {
  const BillsEmailScreen({super.key, this.service});

  /// For tests; the app uses [MailInboxService.instance].
  final MailInboxService? service;

  /// How many are open (BillsEmailNav does not stack a second).
  static int showing = 0;

  @override
  State<BillsEmailScreen> createState() => _BillsEmailScreenState();
}

class _BillsEmailScreenState extends State<BillsEmailScreen> {
  late final MailInboxService _svc = widget.service ?? MailInboxService.instance;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  List<MailItem> _items = const [];

  @override
  void initState() {
    super.initState();
    BillsEmailScreen.showing++;
    unawaited(_load());
  }

  @override
  void dispose() {
    BillsEmailScreen.showing--;
    super.dispose();
  }

  Future<void> _load() async {
    final s = await _svc.refresh();
    final items = s?.address != null ? await _svc.recent() : const <MailItem>[];
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failed = s == null;
      _items = items ?? _items;
    });
  }

  Future<void> _run(Future<bool> Function() job, {String? ok, String fail = "That didn't work. Try again."}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final done = await job();
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) {
      if (ok != null) AppFeedback.show(ok, context: context, tone: FeedbackTone.success);
      await _load();
    } else {
      AppFeedback.show(fail, context: context, tone: FeedbackTone.error);
    }
  }

  Future<void> _copy(String text, [String message = 'Copied']) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) await AppFeedback.copied(context, message);
  }

  Future<void> _confirmRotate() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Get a new address?'),
        content: const Text('Your current address stops working straight away. Emails sent to it will bounce.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Get new address')),
        ],
      ),
    );
    if (yes != true) return;
    await _run(() async => await _svc.rotate() != null,
        ok: 'New address ready',
        fail: "Couldn't get a new address. You can do this 5 times a day.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Bills by email'),
      body: ValueListenableBuilder<MailInboxState?>(
        valueListenable: _svc.state,
        builder: (context, s, _) {
          if (_loading) return const Center(child: CircularProgressIndicator());
          if (_failed || s == null) return _message("Couldn't load this. Check your connection and try again.", retry: true);
          if (!s.available) return _message('Bills by email is not available yet.');
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: s.address == null ? _off() : _on(s),
            ),
          );
        },
      ),
    );
  }

  Widget _message(String text, {bool retry = false}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center, style: TextStyle(color: Neon.textLo, fontSize: 15)),
              if (retry) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () {
                    setState(() => _loading = true);
                    unawaited(_load());
                  },
                  child: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      );

  List<Widget> _off() => [
        Text(
          "Get your own address for bills, tickets and policy renewals. Forward them to it and "
          "I'll save them in My documents and remind you before they're due.",
          style: TextStyle(color: Neon.textHi, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 20),
        ApplePrimaryButton(
          label: 'Turn on',
          icon: Icons.forward_to_inbox_rounded,
          onPressed: _busy ? null : () => _run(() async => await _svc.turnOn() != null),
        ),
        const SizedBox(height: 20),
        _footer(null),
      ];

  List<Widget> _on(MailInboxState s) {
    final a = s.address!;
    return [
      GroupedCard(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your address', style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
              const SizedBox(height: 4),
              SelectableText(
                a.address,
                key: const ValueKey('bills-address'),
                style: TextStyle(color: Neon.textHi, fontSize: 18, fontFamily: 'monospace', fontWeight: FontWeight.w600),
              ),
              if (!a.on) ...[
                const SizedBox(height: 4),
                Text('Switched off — emails to it bounce back to the sender.',
                    style: TextStyle(color: Neon.warningInk, fontSize: NeonType.footnote)),
              ],
              const SizedBox(height: 4),
              Wrap(spacing: 8, children: [
                TextButton.icon(
                  onPressed: () => _copy(a.address),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy'),
                ),
                TextButton.icon(
                  onPressed: () => Share.share('My bills address: ${a.address}'),
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: const Text('Share'),
                ),
              ]),
            ],
          ),
        ),
        if (s.trustedFrom.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Mail from these addresses is treated as yours:',
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
                for (final t in s.trustedFrom)
                  Row(children: [
                    Expanded(
                      child: Text(t, overflow: TextOverflow.ellipsis, style: TextStyle(color: Neon.textHi, fontSize: 14)),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _run(() => _svc.untrust(t)),
                      child: const Text('Remove'),
                    ),
                  ]),
              ],
            ),
          ),
      ]),
      const SizedBox(height: 16),
      GroupedCard(children: [
        AppleRow(
          title: 'Receive emails',
          subtitle: a.on ? null : 'Emails to this address bounce back to the sender.',
          trailing: Switch(
            key: const ValueKey('bills-switch'),
            value: a.on,
            onChanged: _busy ? null : (v) => _run(() async => await _svc.setOn(v) != null),
          ),
        ),
        AppleRow(
          title: 'Get a new address',
          subtitle: 'Use this if strangers start sending you mail.',
          onTap: _busy ? null : _confirmRotate,
        ),
      ]),
      const SizedBox(height: 24),
      const GroupLabel('Set it up once'),
      GroupedCard(children: [
        for (final (i, t) in const [
          'Copy your address.',
          'In your email app, forward a bill to it — or set up automatic forwarding for emails from your electricity, phone or insurance company.',
          'If your email service sends a confirmation code, it appears below.',
        ].indexed)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${i + 1}.', style: TextStyle(color: Neon.textLo, fontSize: 14)),
              const SizedBox(width: 10),
              Expanded(child: Text(t, style: TextStyle(color: Neon.textHi, fontSize: 14, height: 1.35))),
            ]),
          ),
      ]),
      const SizedBox(height: 24),
      const GroupLabel('Recent'),
      if (_items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
          child: Text('Nothing yet. Forward a bill to try it.', style: TextStyle(color: Neon.textLo, fontSize: 14)),
        )
      else
        GroupedCard(children: [for (final m in _items) _row(m)]),
      const SizedBox(height: 20),
      _footer(s),
    ];
  }

  Widget _footer(MailInboxState? s) => Text(
        'Only people who know this address can send to it. I never pay, reply or click links from these emails.'
        '${s == null ? '' : ' Limit: ${s.perDay} emails a day, ${s.maxMb} MB each.'}',
        style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote, height: 1.4),
      );

  String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${mo[d.month - 1]}, $hh:$mm';
  }

  (String, Color) _chip(MailItem m) => switch (m.status) {
        'saved' when m.isPersonal && !m.verified => ('Did you send this?', Neon.warningInk),
        'saved' when !m.verified && m.reminders.isEmpty => ('Sender not confirmed', Neon.warningInk),
        'saved' => ('Saved', Neon.successInk),
        'already_saved' => ('Already saved', Neon.textLo),
        'couldnt_read' => ("Couldn't read", Neon.warningInk),
        'confirm_code' => ('Confirmation code', Neon.cyanInk),
        'processing' => ('Working on it', Neon.textLo),
        _ => ('Not saved', Neon.textLo),
      };

  Widget _row(MailItem m) {
    final (label, color) = _chip(m);
    final opens = m.status == 'saved' || m.status == 'couldnt_read';
    return InkWell(
      onTap: opens
          ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DocumentsScreen()))
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.subject.isEmpty ? '(no subject)' : m.subject,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Neon.textHi, fontSize: 15)),
            const SizedBox(height: 2),
            Text([m.from, _when(m.receivedAt)].where((x) => x.isNotEmpty).join(' · '),
                style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
            const SizedBox(height: 4),
            Text(
              m.status == 'not_saved' && m.reason.isNotEmpty ? '$label — ${m.reason}' : label,
              key: ValueKey('bills-chip-${m.id}'),
              style: TextStyle(color: color, fontSize: NeonType.footnote, fontWeight: FontWeight.w600),
            ),
            if (m.confirmCode != null)
              Row(children: [
                Expanded(
                  child: SelectableText(m.confirmCode!,
                      style: TextStyle(color: Neon.textHi, fontSize: 17, fontFamily: 'monospace')),
                ),
                TextButton(onPressed: () => _copy(m.confirmCode!, 'Code copied'), child: const Text('Copy')),
              ]),
            for (final r in m.reminders)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('⏰ ${r.text}', style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
              ),
            if (m.status == 'saved' && m.isPersonal && !m.verified && m.fromAddress != null) ...[
              const SizedBox(height: 4),
              Text('From ${m.fromAddress}', style: TextStyle(color: Neon.textLo, fontSize: NeonType.footnote)),
            ],
            if (m.status == 'saved' && !m.verified && !m.remindersDone)
              Wrap(spacing: 8, children: [
                if (m.isPersonal && m.fromAddress != null)
                  TextButton(
                    key: ValueKey('bills-trust-${m.id}'),
                    onPressed: _busy ? null : () => _run(() => _svc.trust(m.id), ok: 'Reminders set'),
                    child: const Text('This was me'),
                  ),
                TextButton(
                  key: ValueKey('bills-remind-${m.id}'),
                  onPressed: _busy
                      ? null
                      : () => _run(() => _svc.remindAnyway(m.id),
                          ok: 'Reminders set', fail: 'Nothing to remind about in this one.'),
                  child: const Text('Set reminders'),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}
