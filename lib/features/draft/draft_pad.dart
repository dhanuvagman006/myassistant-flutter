// THE DRAFT PAD (owner, 2026-10-04).
//
// "Draft an email / a cover letter / anything" opens this pad and the
// words appear as they are written; the user can type in it at any time,
// and "change the second paragraph", "make it formal", "keep going" edit
// exactly that. The text is streamed from POST /ai/draft with what is on
// the pad RIGHT NOW, so an edit always works on the real text. Save puts
// it in My documents (shareable from there); Share sends it straight on.
//
// Copied text (WhatsApp, anywhere) offers "Paste & edit" when the app
// comes back ([ClipboardOffer]), which opens the same pad.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/log.dart';
import '../../design/neon_tokens.dart';
import '../../services/api_service.dart';
import '../../services/app_feedback.dart';
import '../../services/avatar_message_service.dart';
import '../assistant/state/assistant_engine.dart';

/// The one draft being worked on, and the pad that shows it.
class DraftPad extends ChangeNotifier {
  DraftPad._();
  static final DraftPad instance = DraftPad._();

  final TextEditingController text = TextEditingController();
  String title = 'Draft';

  /// Writing or editing is streaming in.
  bool busy = false;

  /// The text before the last AI change (one step of Undo).
  String? previous;

  bool _onScreen = false;
  bool get onScreen => _onScreen;

  http.Client? _stream;
  int _run = 0;

  /// Opens the pad with [content] (a pasted text, or the current draft).
  void open({String? title, String? content}) {
    if (title != null && title.trim().isNotEmpty) this.title = title.trim();
    if (content != null) {
      _cancel();
      previous = null;
      text.text = content;
    }
    notifyListeners();
    _show();
  }

  /// A new draft, written live from [instruction].
  Future<void> write(
      {required String title, required String instruction}) async {
    this.title = title.trim().isEmpty ? 'Draft' : title.trim();
    _show();
    await _generate(instruction, current: '');
  }

  /// Changes the pad's text as [instruction] says; a closed pad reopens.
  Future<void> edit(String instruction) async {
    _show();
    if (text.text.trim().isEmpty) {
      await _generate(instruction, current: '');
    } else {
      await _generate(instruction, current: text.text);
    }
  }

  void undo() {
    final p = previous;
    if (p == null || busy) return;
    previous = text.text;
    text.text = p;
    notifyListeners();
  }

  Future<void> _generate(String instruction, {required String current}) async {
    final ask = instruction.trim();
    if (ask.isEmpty) return;
    _cancel();
    final run = ++_run;
    final before = text.text;
    busy = true;
    text.text = '';
    notifyListeners();
    final client = http.Client();
    _stream = client;
    var got = '';
    try {
      final req =
          http.Request('POST', Uri.parse('${ApiService.baseUrl}/ai/draft'))
            ..headers.addAll({
              ...ApiService.authHeaders,
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            })
            ..body = jsonEncode(
                {'instruction': ask, 'current': current, 'title': title});
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw Exception('server said ${resp.statusCode}');
      }
      var buffer = '';
      await for (final piece in resp.stream.transform(utf8.decoder)) {
        if (run != _run) return;
        buffer += piece;
        int nl;
        while ((nl = buffer.indexOf('\n')) >= 0) {
          final line = buffer.substring(0, nl).trim();
          buffer = buffer.substring(nl + 1);
          if (!line.startsWith('data:')) continue;
          final payload = line.substring(5).trim();
          if (payload.isEmpty || payload == '[DONE]') continue;
          final j = jsonDecode(payload);
          if (j is! Map) continue;
          if (j['error'] != null) {
            throw Exception('${(j['error'] as Map)['message'] ?? j['error']}');
          }
          final t = j['t'];
          if (t is String && t.isNotEmpty) {
            got += t;
            text.value = TextEditingValue(
              text: got,
              selection: TextSelection.collapsed(offset: got.length),
            );
          }
        }
      }
      if (run != _run) return;
      if (got.trim().isEmpty) throw Exception('nothing came back');
      text.text = got.trim();
      previous = before.isEmpty ? null : before;
    } catch (e) {
      if (run != _run) return;
      AppLog.add('draft', 'failed: $e');
      text.text = before; // nothing half-written replaces the user's text
      AppFeedback.show("Couldn't write that just now — please try again.",
          tone: FeedbackTone.error);
    } finally {
      if (run == _run) {
        busy = false;
        _stream = null;
        client.close();
        notifyListeners();
      }
    }
  }

  void _cancel() {
    _run++;
    _stream?.close();
    _stream = null;
    if (busy) {
      busy = false;
      notifyListeners();
    }
  }

  /// Stops a write in progress, keeping what has arrived.
  void stop() => _cancel();

  /// Saves the text into My documents.
  Future<bool> save() async {
    final body = text.text.trim();
    if (body.isEmpty || busy) return false;
    final safe = title.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
    final name = '${safe.isEmpty ? 'Draft' : safe}.txt';
    try {
      await ApiService.uploadDocument(
        bytes: utf8.encode(body),
        filename: name,
        mimeType: 'text/plain',
        note: title,
      );
      AppFeedback.show('Saved in your Documents', tone: FeedbackTone.success);
      return true;
    } catch (e) {
      AppLog.add('draft', 'save failed: $e');
      AppFeedback.show("Couldn't save it — check the internet and try again.",
          tone: FeedbackTone.error);
      return false;
    }
  }

  Future<void> share() async {
    final body = text.text.trim();
    if (body.isEmpty) return;
    await Share.share(body, subject: title);
  }

  void _show() {
    if (_onScreen) return;
    final nav = AvatarMessageService.navigatorKey.currentState;
    if (nav == null) return;
    _onScreen = true;
    nav
        .push(MaterialPageRoute<void>(builder: (_) => const DraftPadScreen()))
        .whenComplete(() => _onScreen = false);
  }
}

class DraftPadScreen extends StatefulWidget {
  const DraftPadScreen({super.key});

  @override
  State<DraftPadScreen> createState() => _DraftPadScreenState();
}

class _DraftPadScreenState extends State<DraftPadScreen> {
  final _ask = TextEditingController();
  final _scroll = ScrollController();
  final _paperFocus = FocusNode();
  DraftPad get pad => DraftPad.instance;

  /// One-tap changes; each is the same as saying it.
  static const _quick = [
    ('Make it formal', 'Make it more formal and professional'),
    ('Shorter', 'Make it shorter and tighter, keep every key point'),
    ('Fix grammar', 'Fix grammar, spelling and punctuation only'),
    ('Friendlier', 'Make the tone warmer and friendlier'),
    ('Continue', 'Continue writing from where it ends'),
  ];

  @override
  void initState() {
    super.initState();
    pad.addListener(_changed);
    pad.text.addListener(_onText);
  }

  @override
  void dispose() {
    pad.removeListener(_changed);
    pad.text.removeListener(_onText);
    _ask.dispose();
    _scroll.dispose();
    _paperFocus.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Word count follows typing; while words stream in, the newest line
  /// stays in view.
  void _onText() {
    if (mounted) setState(() {});
    if (!pad.busy || !_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _run(String instruction) {
    if (instruction.trim().isEmpty || pad.busy) return;
    FocusScope.of(context).unfocus();
    unawaited(pad.edit(instruction));
  }

  void _sendAsk() {
    final a = _ask.text.trim();
    if (a.isEmpty) return;
    _ask.clear();
    _run(a);
  }

  Future<void> _talk() async {
    final e = AssistantEngine.instance;
    if (e.liveActive || e.inlineVoice || e.starting) {
      AppFeedback.show('Listening — say what to change',
          tone: FeedbackTone.info);
      return;
    }
    await e.beginInlineConversation();
  }

  String get _status {
    if (pad.busy) return 'Writing…';
    final words = RegExp(r'\S+').allMatches(pad.text.text).length;
    if (words == 0) return 'Empty draft';
    return words == 1 ? '1 word' : '$words words';
  }

  @override
  Widget build(BuildContext context) {
    final busy = pad.busy;
    final empty = pad.text.text.trim().isEmpty;
    return Scaffold(
      backgroundColor: Neon.bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(busy, empty),
            SizedBox(
              height: 2,
              child: busy
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          backgroundColor: Neon.surfaceHigh,
                          color: Neon.violet,
                        ),
                      ),
                    )
                  : null,
            ),
            Expanded(child: _paper(busy)),
            if (!empty && !busy) _chips(),
            _actions(busy, empty),
            _composer(busy, empty),
          ],
        ),
      ),
    );
  }

  Widget _header(bool busy, bool empty) {
    Widget icon(IconData i, String tip, VoidCallback? on) => IconButton(
          tooltip: tip,
          onPressed: on,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          icon:
              Icon(i, size: 22, color: on == null ? Neon.textDim : Neon.textHi),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
      child: Row(
        children: [
          icon(Icons.arrow_back_rounded, 'Back',
              () => Navigator.of(context).maybePop()),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pad.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 18,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(_status,
                    style: TextStyle(
                        color: busy ? Neon.violet : Neon.textLo, fontSize: 13)),
              ],
            ),
          ),
          if (pad.previous != null && !busy)
            icon(Icons.undo_rounded, 'Undo the last change', pad.undo),
          icon(
            Icons.copy_rounded,
            'Copy',
            empty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: pad.text.text));
                    ClipboardOffer.instance.ignoreCurrent();
                    AppFeedback.copied(context);
                  },
          ),
        ],
      ),
    );
  }

  Widget _paper(bool busy) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Neon.surfaceHigh),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Scrollbar(
            controller: _scroll,
            // Tapping anywhere on the page puts the cursor in the text.
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: busy ? null : _paperFocus.requestFocus,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                child: TextField(
                  controller: pad.text,
                  readOnly: busy,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  style: TextStyle(
                      color: Neon.textHi, fontSize: 16.5, height: 1.65),
                  cursorColor: Neon.violet,
                  focusNode: _paperFocus,
                  decoration: _bare(
                    busy
                        ? 'Writing…'
                        : 'Start typing, or tell me what to write below',
                    TextStyle(color: Neon.textDim, fontSize: 16.5),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// A text field with no box of its own (the app theme gives every field
  /// a filled, bordered box; here the card is the box).
  static InputDecoration _bare(String hint, TextStyle style,
          {EdgeInsets padding = EdgeInsets.zero}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: style,
        filled: false,
        isDense: true,
        isCollapsed: padding == EdgeInsets.zero,
        contentPadding: padding,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
      );

  Widget _chips() => SizedBox(
        height: 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _quick.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final (label, ask) = _quick[i];
            return ActionChip(
              label: Text(label),
              onPressed: () => _run(ask),
              labelStyle: TextStyle(
                  color: Neon.textHi,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600),
              backgroundColor: Neon.surfaceHigh,
              side: BorderSide(color: Neon.violet.withValues(alpha: 0.35)),
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 6),
            );
          },
        ),
      );

  Widget _actions(bool busy, bool empty) {
    final off = empty || busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: off ? null : pad.share,
              icon: const Icon(Icons.share_rounded, size: 18),
              label: const Text('Share'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Neon.textHi,
                minimumSize: const Size.fromHeight(48),
                side: BorderSide(color: off ? Neon.surfaceHigh : Neon.textLo),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: off ? null : pad.save,
              icon: const Icon(Icons.save_alt_rounded, size: 18),
              label: const Text('Save'),
              style: FilledButton.styleFrom(
                backgroundColor: Neon.accentFill,
                foregroundColor: Neon.onAccent,
                disabledBackgroundColor: Neon.surfaceHigh,
                disabledForegroundColor: Neon.textDim,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(bool busy, bool empty) {
    Widget round(IconData i, String tip, VoidCallback on,
            {bool filled = false}) =>
        Semantics(
          button: true,
          label: tip,
          child: Material(
            color: filled ? Neon.accentFill : Neon.surfaceHigh,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: on,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(i,
                    size: 22, color: filled ? Neon.onAccent : Neon.violet),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 4, 4, 4),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Neon.surfaceHigh),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ask,
                enabled: !busy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendAsk(),
                style: TextStyle(color: Neon.textHi, fontSize: 15),
                cursorColor: Neon.violet,
                decoration: _bare(
                  busy
                      ? 'Writing…'
                      : empty
                          ? 'What should I write?'
                          : 'Ask for a change…',
                  TextStyle(color: Neon.textDim, fontSize: 15),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (busy)
              round(Icons.stop_rounded, 'Stop writing', pad.stop, filled: true)
            else ...[
              round(Icons.mic_rounded, 'Say what to change', _talk),
              const SizedBox(width: 6),
              round(Icons.arrow_upward_rounded, 'Send', _sendAsk, filled: true),
            ],
          ],
        ),
      ),
    );
  }
}

/// "PASTE & EDIT": text copied in another app is offered once when the
/// app comes back. Android stamps every new clip, so the clipboard is
/// read only after a tap (no "pasted from your clipboard" notice on every
/// return) and a clip is never offered twice.
class ClipboardOffer {
  ClipboardOffer._();
  static final ClipboardOffer instance = ClipboardOffer._();

  static const _channel = MethodChannel('hari/clipboard');
  static const _key = 'clip_offered_stamp';

  /// Offers only clips copied in the last few minutes.
  static const _fresh = Duration(minutes: 10);

  bool _checking = false;

  Future<int> _stamp() async {
    try {
      return (await _channel.invokeMethod<int>('stamp')) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// The current clip is ours (copied from the pad): never offer it.
  Future<void> ignoreCurrent() async {
    final s = await _stamp();
    if (s <= 0) return;
    try {
      (await SharedPreferences.getInstance()).setInt(_key, s);
    } catch (_) {}
  }

  /// Called when the app returns to the foreground.
  Future<void> check() async {
    if (_checking || DraftPad.instance.onScreen) return;
    _checking = true;
    try {
      final stamp = await _stamp();
      if (stamp <= 0) return;
      final age = DateTime.now().millisecondsSinceEpoch - stamp;
      if (age < 0 || age > _fresh.inMilliseconds) return;
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getInt(_key) ?? 0) >= stamp) return;
      if (!await Clipboard.hasStrings()) return;
      await prefs.setInt(_key, stamp);
      final messenger = AppFeedback.messengerKey.currentState;
      if (messenger == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          content: const Text('You copied some text'),
          action: SnackBarAction(label: 'Paste & edit', onPressed: _paste),
        ));
    } catch (e) {
      AppLog.add('draft', 'clipboard check failed: $e');
    } finally {
      _checking = false;
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim() ?? '';
    if (t.isEmpty) return;
    DraftPad.instance.open(title: 'Pasted text', content: t);
  }
}
