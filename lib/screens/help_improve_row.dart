import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../services/api_service.dart';
import '../services/app_feedback.dart';
import '../services/privacy_prefs_service.dart';

/// What the user is told before they say yes — on the one-time card and in
/// the dialog behind the switch. Plain words; the server stores which
/// version they saw ([PrivacyPrefsService.noticeVersion]).
String helpImproveNotice(int days) =>
    'If you say yes, our team may listen to recordings of your voice chats '
    '(kept up to $days days) and read your conversations, only to find and '
    'fix mistakes. We never use them to train AI, and we never sell or share '
    'them. The assistant works the same either way. You can change this '
    'anytime in You → Privacy & security.';

void _openPolicy() {
  launchUrl(Uri.parse('${ApiService.baseUrl}/legal/privacy'),
      mode: LaunchMode.externalApplication);
}

Widget _policyLink() => Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: _openPolicy,
        style: TextButton.styleFrom(padding: EdgeInsets.zero),
        child: const Text('Privacy Policy'),
      ),
    );

/// The notice before turning it on. True only when they press Turn on.
Future<bool> showHelpImproveNotice(BuildContext context, int days) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Help improve the assistant?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(helpImproveNotice(days)), _policyLink()],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Not now')),
        FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Turn on')),
      ],
    ),
  );
  return ok == true;
}

/// The confirmation before turning it off. True only when they press Turn off.
Future<bool> showHelpImproveTurnOff(BuildContext context) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Turn off?'),
      content: const Text(
          'Your voice recordings will be deleted now, and your chats will '
          'stay private. The assistant works the same.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep on')),
        FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Turn off')),
      ],
    ),
  );
  return ok == true;
}

/// The one-time card's body. [onAnswer] gets true for "Yes, help improve".
/// The two buttons are the same style: neither answer is the "right" one.
class HelpImproveAskCard extends StatelessWidget {
  final int days;
  final void Function(bool yes) onAnswer;
  const HelpImproveAskCard({super.key, required this.days, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.volunteer_activism_rounded, color: Neon.violet, size: 20),
            const SizedBox(width: 9),
            Flexible(
              child: Text('Help improve the assistant?',
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(helpImproveNotice(days),
              style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.45)),
          _policyLink(),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => onAnswer(false),
                child: const Text('No thanks'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: () => onAnswer(true),
                child: const Text('Yes, help improve'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// You → Privacy & security: the switch.
class HelpImproveRow extends StatefulWidget {
  const HelpImproveRow({super.key});

  @override
  State<HelpImproveRow> createState() => _HelpImproveRowState();
}

class _HelpImproveRowState extends State<HelpImproveRow> {
  final _prefs = PrivacyPrefsService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_sync);
    if (!_prefs.loaded) _prefs.load();
  }

  @override
  void dispose() {
    _prefs.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (mounted) setState(() {});
  }

  void _toast(String text) {
    if (!mounted) return;
    AppFeedback.show(text, context: context);
  }

  Future<void> _change(bool on) async {
    if (_busy) return;
    final agreed = on
        ? await showHelpImproveNotice(context, _prefs.recordingDays)
        : await showHelpImproveTurnOff(context);
    if (!agreed || !mounted) return;
    setState(() => _busy = true);
    final ok = await _prefs.set(on, source: 'settings');
    if (mounted) setState(() => _busy = false);
    if (!ok) {
      _toast("Couldn't save that. Please try again.");
      return;
    }
    _toast(on ? 'Thank you — this is on.' : 'Turned off. Your recordings are deleted.');
  }

  @override
  Widget build(BuildContext context) {
    return AppleRow(
      leading: IconTile(Icons.volunteer_activism_rounded, AppleColors.blue),
      title: 'Help improve the assistant',
      subtitle: 'Let our team check your chats to fix mistakes.',
      trailing: Switch(
        value: _prefs.isOn,
        onChanged: _busy
            ? null
            : (v) {
                HapticFeedback.selectionClick();
                _change(v);
              },
      ),
    );
  }
}
