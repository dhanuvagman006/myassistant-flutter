import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/config.dart';
import '../ai/live_voice.dart';
import '../design/accent_controller.dart';
import '../features/home/home_memory.dart';
import '../design/apple_kit.dart';
import '../design/dock_metrics.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../design/theme_controller.dart';
import '../services/voice_choice.dart';
import '../services/api_service.dart';
import '../services/assistant_identity.dart';
import 'account_section.dart';
import 'app_lock_section.dart';
import 'theme_colour_screen.dart';
import 'voice_picker_screen.dart';
import 'avatar_identity_screen.dart';
import 'bills_email_screen.dart';
import '../models/mail_inbox.dart';
import '../services/mail_inbox_service.dart';
import '../services/app_feedback.dart';
import '../services/location_service.dart';
import '../services/tester_feedback.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ASSISTANT SETTINGS — how the assistant sounds and looks, plus the
///  user's standing rules.
///
///  Deliberately NO name field and NO style dropdown: identity is set by
///  TALKING ("your name is Maya from now on") — the conversation is the
///  interface. Everything left on this page saves the moment it's tapped;
///  there is no Save button to forget.
/// ─────────────────────────────────────────────────────────────────────────
class AssistantSettingsScreen extends StatefulWidget {
  const AssistantSettingsScreen({super.key});

  @override
  State<AssistantSettingsScreen> createState() =>
      _AssistantSettingsScreenState();
}

class _AssistantSettingsScreenState extends State<AssistantSettingsScreen> {
  String _voice = 'gleam';
  List<dynamic> _rules = [];
  // Nearby (2026-10-01): what I share with people around me.
  String _profession = '';
  bool _shared = false;
  final _newRule = TextEditingController();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Bills by email: is it switched on for this server? (hidden if not)
    unawaited(MailInboxService.instance.refresh());
    _load();
  }

  @override
  void dispose() {
    _newRule.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await LiveVoicePrefs.load();
    // Side by side, not one after another: the tab opened on sequential
    // round-trips.
    final results = await Future.wait([
      ApiService.getJson('/profile/full'),
      ApiService.getJson('/profile/instructions'),
      ApiService.nearbyMe(),
    ]);
    final p = results[0];
    final r = results[1];
    final n = results[2];
    if (!mounted) return;
    setState(() {
      _loading = false;
      _profession = (n?['profession'] ?? '').toString();
      _shared = n?['shared'] == true;
      final a = (p?['assistant'] as Map?) ?? {};
      final offered = AiConfigStore.instance.current.live.voices
          .map((v) => v.toLowerCase())
          .toSet();
      final chosen = LiveVoicePrefs.chosenVoice?.trim().toLowerCase();
      final profileVoice = (a['voice'] as String?)?.trim().toLowerCase();
      final configured =
          AiConfigStore.instance.current.live.voice.toLowerCase();
      _voice = [
        chosen,
        profileVoice,
        configured,
      ].whereType<String>().firstWhere(
            (v) => offered.contains(v),
            orElse: () => 'shimmer',
          );
      _rules = (r?['instructions'] as List?) ?? [];
    });
  }

  Future<void> _editProfession() async {
    final c = TextEditingController(text: _profession);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What do you do?'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration:
              const InputDecoration(hintText: 'Lawyer, electrician, teacher…'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(c.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == null) return;
    final me = await ApiService.setNearbyMe(profession: saved.trim());
    if (!mounted) return;
    setState(
        () => _profession = (me?['profession'] ?? saved.trim()).toString());
  }

  Future<void> _setShared(bool v) async {
    HapticFeedback.selectionClick();
    if (v && (ApiService.geoLat == null || ApiService.geoLng == null)) {
      await LocationService.instance.refresh();
      if (ApiService.geoLat == null) {
        if (!mounted) return;
        AppFeedback.show(
            'Turn on location first so people nearby can find you.',
            context: context,
            tone: FeedbackTone.error);
        return;
      }
    }
    final me = await ApiService.setNearbyMe(shared: v);
    if (!mounted) return;
    setState(() => _shared = me?['shared'] == true);
  }

  String _voiceName(String id) {
    if (id.isEmpty) return 'Gleam';
    return '${id[0].toUpperCase()}${id.substring(1)}';
  }

  Future<void> _pickVoice(String v) async {
    HapticFeedback.selectionClick();
    final prev = _voice;
    setState(() => _voice = v);
    // Saved on the phone and the server; the next conversation is in it.
    final why = await VoiceChoice.save(v);
    if (!mounted) return;
    if (why != null) {
      setState(() => _voice = prev);
      // The server explains a mismatch in a sentence the user can act on
      // — show THAT, not a generic failure.
      AppFeedback.show(why, context: context, tone: FeedbackTone.error);
      return;
    }
  }

  Future<void> _addRule() async {
    final t = _newRule.text.trim();
    if (t.isEmpty) return;
    await ApiService.sendJson('/profile/instructions',
        method: 'POST', body: {'instruction': t});
    _newRule.clear();
    await _load();
  }

  Future<void> _removeRule(int id) async {
    await ApiService.sendJson('/profile/instructions/$id', method: 'DELETE');
    await _load();
  }

  /// Opens the tester feedback form (TesterFeedback). When it opened,
  /// the form speaks for itself; when it could not, one toast says so.
  ///
  /// Two messages, each only when it is true (review, 2026-09-25). The one
  /// toast used to say "Check your internet" for every failure, but the
  /// failures that reach here were never the internet (Firebase not
  /// started, no Android half); the connection is now checked before the
  /// form starts, and only that check's answer asks about the connection.
  Future<void> _sendFeedback() async {
    final started = await TesterFeedback.start();
    if (!mounted) return;
    final msg = switch (started) {
      FeedbackStart.opened => null,
      FeedbackStart.offline =>
        'Feedback needs the internet. Check your connection and try again.',
      FeedbackStart.unavailable =>
        "Feedback isn't available right now. Please try again later.",
    };
    if (msg == null) return;
    AppFeedback.show(msg, context: context, tone: FeedbackTone.error);
  }

  @override
  Widget build(BuildContext context) {
    // As the You TAB it wears the same large title as Hub and Chat — a
    // small centred "Assistant" bar under a tab labelled "You" read as a
    // different screen from the one tapped. Pushed on its own (from
    // Diagnostics) it keeps a normal app bar with a back arrow.
    final pushed = ModalRoute.of(context)?.canPop ?? false;
    // UNDER THE SAME SKY (2026-09-30): as the You tab it is clear, so the
    // shell's sky shows through as it does on Hub (a flat Neon.bg hid it
    // on this one tab); pushed, it brings its own (NeonScaffold).
    final body = SafeArea(
      top: !pushed,
      bottom: false,
      child: _loading
          ? const NeonLoader.page(semanticLabel: 'Loading your settings')
          : ListView(
              // Clears the dock and the mic on every phone.
              padding: EdgeInsets.fromLTRB(
                  16, pushed ? 8 : 18, 16, Dock.clearance(context)),
              children: [
                if (!pushed) const LargeTitle('You'),
                // Identity lives in the conversation, and the page says so.
                // Live: renaming by voice updates this card too.
                // The one lit card on the page (2026-09-30): who the
                // assistant is, in the brand's own light; every group
                // below is a calm rim.
                ValueListenableBuilder<String>(
                  valueListenable: AssistantIdentity.notifier,
                  builder: (_, n, __) => GlowCard(
                    halo: 0.5,
                    child: AppleRow(
                      leading: IconTile(
                          Icons.auto_awesome_rounded, AppleColors.purple),
                      title: n,
                      subtitle: 'To rename, just say it — "your name is '
                          'Maya from now on".',
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // NEARBY (2026-10-01): the same two choices the Nearby tab
                // shows, here where every other preference lives.
                const GroupLabel('Nearby'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading: IconTile(Icons.badge_rounded, AppleColors.teal),
                      title:
                          _profession.isEmpty ? 'Your profession' : _profession,
                      subtitle: _profession.isEmpty
                          ? 'Tell people nearby what you do — tap to add'
                          : 'Tap to change',
                      onTap: _editProfession,
                    ),
                    AppleRow(
                      leading:
                          IconTile(Icons.near_me_rounded, AppleColors.green),
                      title: 'Be found by people nearby',
                      subtitle: _shared
                          ? 'Your profession and area are shown — never your exact location or number'
                          : 'Off — only you can see your profession',
                      trailing: Switch.adaptive(
                        value: _shared,
                        onChanged: _profession.isEmpty ? null : _setShared,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const GroupLabel('Appearance'),
                ValueListenableBuilder<ThemeMode3>(
                  valueListenable: ThemeController.mode,
                  builder: (_, mode, __) => GroupedCard(
                    dividerInset: 60,
                    children: [
                      // Adaptive, Light and Dark came out (2026-09-30): the
                      // app has one design, the night-sky neon, in every
                      // theme (owner's word).
                      // In the Appearance card (2026-09-24): it floated
                      // 10 dp under it as a card with no label of its own.
                      AppleRow(
                        leading:
                            IconTile(Icons.palette_rounded, AppleColors.purple),
                        title: 'Theme colour',
                        subtitle: 'Paints the orb, the mic and every highlight',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ValueListenableBuilder<Color>(
                              valueListenable: AccentController.seed,
                              builder: (_, seed, __) => Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: Neon.tile(seed),
                                  border: Border.all(color: Neon.line),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(Icons.chevron_right_rounded,
                                color: Neon.textDim, size: 20),
                          ],
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ThemeColourScreen()),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Home's headlines (2026-09-30): a card of two when there is
                // room under what is personal; the card's ✕ turns it off.
                const GroupLabel('Home'),
                ValueListenableBuilder<bool>(
                  valueListenable: HomeMemory.instance.newsOn,
                  builder: (_, on, __) => GroupedCard(
                    dividerInset: 60,
                    children: [
                      AppleRow(
                        leading:
                            IconTile(Icons.newspaper_rounded, AppleColors.blue),
                        title: 'News on Home',
                        subtitle:
                            'Two headlines from the topic you read, when there is room',
                        trailing: Switch(
                          value: on,
                          onChanged: (v) {
                            HapticFeedback.selectionClick();
                            HomeMemory.instance.setNewsOn(v);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // ONE VOICE CARD (2026-09-24). "ASSISTANT VOICE" sat over a
                // row called "Assistant voice", and "RECOGNISE MY VOICE"
                // over "Voice ID": a label per row, each repeating it.
                const GroupLabel('Voice'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading:
                          IconTile(Icons.graphic_eq_rounded, AppleColors.teal),
                      title: 'Assistant voice',
                      subtitle: 'Preview and choose an OpenAI voice',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _voiceName(_voice),
                            style: TextStyle(
                                color: Neon.textLo,
                                fontSize: 14,
                                fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.chevron_right_rounded,
                              color: Neon.textDim, size: 20),
                        ],
                      ),
                      onTap: () async {
                        final picked = await Navigator.of(context).push<String>(
                          MaterialPageRoute(
                            builder: (_) => VoicePickerScreen(
                              selectedId: _voice,
                            ),
                          ),
                        );
                        if (picked != null && mounted) await _pickVoice(picked);
                      },
                    ),
                    // "Live captions" was here: a switch nothing read
                    // (captions always show in the voice overlay),
                    // describing a conversation screen that no longer
                    // exists.
                    // "Voice ID" and "Respond only to my voice" were here
                    // (2026-09-29). Since the phone's own speech recogniser
                    // hears the owner, no audio reaches a voiceprint check,
                    // so the promise "answers only you" was no longer true.
                    // The voiceprint service and its 28 MB model were
                    // removed on 2026-10-01 (nothing streamed audio to it).
                  ],
                ),
                const SizedBox(height: 24),

                // "Video avatar → Avatar face" was here. It appeared whenever
                // the server listed faces, but the app has no video renderer
                // (face mode is off), so a pick changed nothing visible.
                const GroupLabel('Your avatar identity'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading: IconTile(
                          Icons.video_camera_front_rounded, AppleColors.green),
                      title: 'Send messages as you',
                      subtitle: 'Your face and voice on messages you send '
                          '— with your consent.',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const AvatarIdentityScreen()),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Bills by email (build 120): only when the server says it
                // is switched on — until then there is nothing to show.
                ValueListenableBuilder<MailInboxState?>(
                  valueListenable: MailInboxService.instance.state,
                  builder: (context, s, _) => s?.available != true
                      ? const SizedBox.shrink()
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const GroupLabel('Documents'),
                            GroupedCard(
                              dividerInset: 60,
                              children: [
                                AppleRow(
                                  leading: IconTile(
                                      Icons.forward_to_inbox_rounded,
                                      AppleColors.blue),
                                  title: 'Bills by email',
                                  subtitle:
                                      "Forward bills and tickets — I'll file "
                                      'them and remind you',
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const BillsEmailScreen()),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                          ],
                        ),
                ),

                const GroupLabel('Standing rules'),
                Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Text(
                    'Permanent instructions the assistant follows before every '
                    'decision — e.g. "Always ask before sending messages", '
                    '"Call me by my first name". You can also just say these in '
                    'conversation.',
                    // textLo: textDim fell under 4.5:1 on the ambient wash.
                    style: TextStyle(
                        color: Neon.textLo, fontSize: NeonType.footnote),
                  ),
                ),
                if (_rules.isNotEmpty) ...[
                  GroupedCard(
                    children: [
                      for (final r in _rules)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                          child: Row(children: [
                            Expanded(
                                child: Text(r['instruction'] ?? '',
                                    style: TextStyle(color: Neon.textLo))),
                            IconButton(
                              tooltip: 'Remove rule',
                              icon: Icon(Icons.close_rounded,
                                  size: 18, color: Neon.textDim),
                              onPressed: () => _removeRule(r['id'] as int),
                            ),
                          ]),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _newRule,
                      style: TextStyle(color: Neon.textHi),
                      decoration: _dec('Add a rule', 'Always…'),
                      onSubmitted: (_) => _addRule(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                      tooltip: 'Add rule',
                      onPressed: _addRule,
                      icon: Icon(Icons.add_circle_rounded, color: Neon.violet)),
                ]),
                const SizedBox(height: 24),

                const AppLockSection(),
                const SizedBox(height: 24),

                const AccountSection(),
                const SizedBox(height: 24),

                // SEND FEEDBACK (owner, 2026-09-25: "yes add the send
                // feedback button"). Opens the feedback form of the service
                // the client installs the app from; what they write reaches
                // the owner with the build it is about. Next to About,
                // where a person looks for "tell someone".
                const GroupLabel('Help'),
                GroupedCard(
                  dividerInset: 60,
                  children: [
                    AppleRow(
                      leading:
                          IconTile(Icons.feedback_outlined, AppleColors.blue),
                      title: 'Send feedback',
                      subtitle: 'Tell the developer what to improve',
                      onTap: _sendFeedback,
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                const GroupLabel('About & legal'),
                GroupedCard(
                  children: [
                    _legalRow('Privacy Policy', '/legal/privacy'),
                    _legalRow('Terms & Conditions', '/legal/terms'),
                  ],
                ),
              ],
            ),
    );
    if (pushed) {
      return NeonScaffold(appBar: appleAppBar(context, 'Settings'), body: body);
    }
    return Scaffold(backgroundColor: Colors.transparent, body: body);
  }

  Widget _legalRow(String label, String path) => AppleRow(
        title: label,
        trailing:
            Icon(Icons.open_in_new_rounded, size: 16, color: Neon.textDim),
        onTap: () => launchUrl(Uri.parse('${ApiService.baseUrl}$path'),
            mode: LaunchMode.externalApplication),
      );

  InputDecoration _dec(String label, String hint) => InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: Neon.textLo),
        hintStyle: TextStyle(color: Neon.textDim),
        filled: true,
        fillColor: Neon.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
      );
}
