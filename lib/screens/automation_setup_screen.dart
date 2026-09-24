import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../services/automation_runner.dart';
import '../services/app_feedback.dart';

/// "DO IT FOR ME" — the one-time permission, asked for honestly.
///
/// Android only lets an app tap and type in other apps through an
/// accessibility service, switched on by the owner in Settings. This
/// screen says in plain words what it does, what it never does, and walks
/// through the two switches (the second only on phones that call an app
/// installed from a file "restricted"). When [pendingGoal] is set, the task
/// that asked for it continues by itself the moment the switch is on.
class AutomationSetupScreen extends StatefulWidget {
  final String? pendingGoal;
  final VoidCallback? onEnabled;

  const AutomationSetupScreen({super.key, this.pendingGoal, this.onEnabled});

  @override
  State<AutomationSetupScreen> createState() => _AutomationSetupScreenState();
}

class _AutomationSetupScreenState extends State<AutomationSetupScreen>
    with WidgetsBindingObserver {
  final _device = ChannelAutomationDevice();
  bool _on = false;
  bool _switchedInSettings = false;
  bool _triedOnce = false;
  bool _continued = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    // The service binds a moment after the switch flips.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final st = await _device.status();
    if (!mounted) return;
    setState(() {
      _on = st.connected;
      _switchedInSettings = st.enabled;
    });
    if (_on && widget.onEnabled != null && !_continued) {
      _continued = true;
      HapticFeedback.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onEnabled!();
    }
  }

  Future<void> _openSettings() async {
    setState(() => _triedOnce = true);
    final ok = await _device.openSettings();
    if (!ok && mounted) {
      AppFeedback.show('Open Settings → Accessibility → Installed apps.', context: context);
    }
  }

  // ONE QUIET GLYPH (2026-09-24). Six red icons of mixed meaning — a
  // crossed-out card beside a plain "send" arrow, a bin, a gavel — read as
  // errors or as things to tap, when the list is a reassurance.
  Widget _never(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.block_rounded, size: 18, color: Neon.textLo),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: TextStyle(color: Neon.textHi, fontSize: 14, height: 1.35))),
        ]),
      );

  Widget _step(int n, String title, String body, {Widget? action}) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: Neon.violet.withValues(alpha: 0.18),
            child: Text('$n',
                style: NeonType.manrope(NeonType.footnote, FontWeight.w700)
                    .copyWith(color: Neon.violet)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: NeonType.manrope(NeonType.callout, FontWeight.w600)
                      .copyWith(color: Neon.textHi)),
              const SizedBox(height: 3),
              Text(body,
                  style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.4)),
              if (action != null) ...[const SizedBox(height: 8), action],
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final goal = widget.pendingGoal;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Do it for me'),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(Neon.rLg),
              border: Border.all(color: Neon.line),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                IconTile(Icons.touch_app_rounded, AppleColors.purple),
                const SizedBox(width: 12),
                // The card's title, bold for real (it drew as regular, so
                // the page read as one wall of text).
                Expanded(
                  child: Text(
                      _on ? 'Switched on — ready' : 'One-time permission',
                      style: NeonType.cardTitle.copyWith(
                          color: _on ? Neon.successInk : Neon.textHi)),
                ),
              ]),
              const SizedBox(height: 12),
              // textLo under a textHi title: explanation, not headline.
              Text(
                'Ask me to "order veg biryani from a 4-star place", "turn on '
                'Bluetooth" or "fill this form with my details" and I use your '
                'phone for you — open any app, search, choose, add to cart, fill '
                'in, change a setting. A small bar with a Stop button shows the '
                'whole time I am working.',
                style: TextStyle(color: Neon.textLo, fontSize: 14, height: 1.45),
              ),
              if (goal != null && goal.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _on
                      ? 'Continuing: "$goal"…'
                      : 'Waiting to do: "$goal" — it continues by itself once this is on.',
                  style: TextStyle(color: Neon.violet, fontSize: 13, height: 1.4),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 20),
          const GroupLabel('I never'),
          GroupedCard(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Column(children: [
                _never('Pay, place a paid order or book a paid ride'),
                _never('Send or move money'),
                _never('Type passwords, PINs, OTPs or card numbers'),
                _never('Send a message or post for you'),
                _never('Delete anything, or change security settings'),
                _never(
                    'Tick a declaration or "I agree" for you, or solve a CAPTCHA'),
                const SizedBox(height: 6),
                Text(
                  'At any of those steps I stop, hand the phone back to you and '
                  'tell you exactly what I did and what is left.',
                  style: TextStyle(
                      color: Neon.textLo,
                      fontSize: NeonType.footnote,
                      height: 1.4),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 20),
          const GroupLabel('What I read'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Only the screens I am working on, only during a task you asked '
              'for. They are read to decide the next tap and are not kept. When '
              'no task is running, I read nothing.',
              style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.45),
            ),
          ),
          const SizedBox(height: 20),
          // Owner, 2026-09-24: be told plainly when an app can't be done —
          // said here once, before it happens. No app names.
          const GroupLabel("Some apps don't allow it"),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Some apps don't allow assistants on some screens — banking and "
              'payment apps often hide them, and a few stop working while one '
              'is on. When that happens I tell you plainly and leave the app '
              'open for you.',
              style: TextStyle(color: Neon.textLo, fontSize: 13, height: 1.45),
            ),
          ),
          const SizedBox(height: 24),
          if (!_on) ...[
            const GroupLabel('Switch it on'),
            _step(
              1,
              'Turn on "MyAssistant — do it for me"',
              // The button is the bar pinned under the page (see below).
              'Tap below, open "Installed apps" (or "Downloaded apps"), tap '
                  '"MyAssistant — do it for me", switch it on and tap Allow.',
            ),
            if (_triedOnce || _switchedInSettings)
              _step(
                2,
                'Says "Restricted setting"?',
                'Android asks this for apps installed from a file. Tap below, '
                    'then ⋮ (top right) → "Allow restricted settings", confirm, '
                    'and do step 1 again.',
                action: OutlinedButton.icon(
                  onPressed: _device.openAppInfo,
                  icon: const Icon(Icons.info_outline_rounded),
                  label: const Text('Open app info'),
                ),
              ),
          ] else
            GroupedCard(children: [
              AppleRow(
                leading: IconTile(Icons.check_circle_rounded, AppleColors.green),
                title: 'Ready',
                subtitle: 'Just ask — "add milk and bread to my cart"',
              ),
              AppleRow(
                leading: IconTile(Icons.toggle_off_rounded, AppleColors.orange),
                title: 'Turn it off',
                subtitle: 'Any time, in Accessibility settings',
                onTap: _device.openSettings,
              ),
            ]),
        ],
      ),
      // THE ONE ACTION, ALWAYS IN REACH (2026-09-24). "Open settings" sat
      // under three sections of explanation, below the fold, and the eye
      // went to the "I never" list first. While the switch is off it is
      // pinned under the page; the steps still say what to do in
      // Settings. Same button, same _openSettings.
      bottomNavigationBar: _on
          ? null
          : DecoratedBox(
              decoration: BoxDecoration(
                color: Neon.bg,
                border: Border(top: BorderSide(color: Neon.line)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _openSettings,
                      icon: const Icon(Icons.settings_accessibility_rounded),
                      label: const Text('Open settings'),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Settings row: "Do it for me" with its On/Off state.
class AutomationSection extends StatefulWidget {
  const AutomationSection({super.key});

  @override
  State<AutomationSection> createState() => _AutomationSectionState();
}

class _AutomationSectionState extends State<AutomationSection> {
  bool _on = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final st = await ChannelAutomationDevice().status();
    if (mounted) setState(() => _on = st.connected);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const GroupLabel('Do it for me'),
        GroupedCard(
          dividerInset: 60,
          children: [
            AppleRow(
              leading: IconTile(Icons.touch_app_rounded, AppleColors.purple),
              title: 'Use other apps for me',
              subtitle: _on
                  ? 'On — any app, forms and settings, up to payment'
                  : 'Off — tap to set up (one time)',
              trailing: Icon(Icons.chevron_right_rounded, color: Neon.textDim),
              onTap: () async {
                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AutomationSetupScreen()));
                _check();
              },
            ),
          ],
        ),
      ],
    );
  }
}
