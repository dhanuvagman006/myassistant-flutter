import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:url_launcher/url_launcher.dart';

/// VOICE CALLING (B1) — "Hey Hari, call amma".
///
/// All on-device: contact lookup + dialing never touch the backend, so
/// the user's contact list stays private. The AssistantEngine runs
/// [parseCallIntent] on every heard question BEFORE sending it to the AI;
/// on a hit, the whole flow is handled locally.
///
/// Android manifest additions (android/ is generated locally):
///   <uses-permission android:name="android.permission.READ_CONTACTS"/>
///   <uses-permission android:name="android.permission.CALL_PHONE"/>
/// iOS: NSContactsUsageDescription in Info.plist; dialing falls back to
/// the tel: confirmation sheet (Apple does not allow silent dialing).
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  // ---------------- INTENT PARSING ----------------
  // English + Hinglish + Hindi + Kannada call phrasings. The captured
  // group / remainder is the person's name.

  static final List<RegExp> _patterns = [
    // "call amma", "please call dr shah now"
    RegExp(r'\b(?:call|dial|phone|ring)\s+(?:to\s+)?([\p{L}\p{M} .\-]{2,40})',
        caseSensitive: false, unicode: true),
    // "amma ko call karo / lagao / milao" (Hinglish word order)
    RegExp(r'([\p{L}\p{M} .\-]{2,40}?)\s+(?:ko|se)\s+(?:call|phone|baat)\b',
        caseSensitive: false, unicode: true),
    // Hindi script: "अम्मा को कॉल करो"
    RegExp(r'([\p{L}\p{M} .\-]{2,40}?)\s+को\s+(?:कॉल|फ़ोन|फोन)', unicode: true),
    // Kannada: "ಅಮ್ಮನಿಗೆ ಕರೆ ಮಾಡು" / "ಅಮ್ಮಗೆ ಫೋನ್ ಮಾಡು"
    RegExp(r'([\p{L}\p{M} .\-]{2,40}?)(?:ನಿಗೆ|ಗೆ|ಿಗೆ)\s+(?:ಕರೆ|ಫೋನ್)',
        unicode: true),
  ];

  static final _trailingNoise = RegExp(
      r'\b(now|please|for me|right now|immediately|karo|kar|lagao|maadu|madi)\b\s*$',
      caseSensitive: false);

  // ---------------- AGENT CALL PARSING ----------------
  // "call allen lobo and ask him at what time he will come home"
  // → the AI itself talks on the call and reports the answer back.

  static final List<RegExp> _agentPatterns = [
    // "call X and ask/tell/find out …", "phone X to inform her that …"
    RegExp(
        r'\b(?:call|dial|phone|ring)\s+(?:to\s+)?([\p{L}\p{M} .\-]{2,40}?)\s+(?:and|to)\s+((?:ask|tell|inform|say|find out|check|confirm|know|let)\b.*)$',
        caseSensitive: false, unicode: true),
    // "ask allen lobo when he will come home" / "ask amma if dinner is ready"
    RegExp(
        r'^\s*(?:please\s+|can you\s+|hari[, ]+)*ask\s+([\p{L}\p{M} .\-]{2,40}?)\s+((?:if|whether|when|what|where|why|how|at|about|to)\b.*)$',
        caseSensitive: false, unicode: true),
  ];

  /// Returns (contactName, task) when [text] asks Hari to call someone
  /// AND speak to them ("…and ask him when he'll be home"). The task is
  /// re-phrased around the person's name so the backend AI has full
  /// context ("ask Allen Lobo at what time he will come home").
  (String, String)? parseAgentCallIntent(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    for (final re in _agentPatterns) {
      final m = re.firstMatch(t);
      if (m == null) continue;
      var name = _cleanName(m.group(1) ?? '');
      var task = (m.group(2) ?? '').trim();
      if (name.length < 2 || task.length < 3) continue;
      // "ask him …" → "ask Allen Lobo …" (unambiguous for the call AI).
      task = task.replaceFirst(
          RegExp(r'^(ask|tell|inform|let|say to|confirm with|remind)\s+(him|her|them)\b',
              caseSensitive: false),
          '${task.split(' ').first} $name');
      if (!RegExp(r'^(ask|tell|inform|say|find out|check|confirm|know|let)',
              caseSensitive: false)
          .hasMatch(task)) {
        task = 'ask $name $task';
      }
      return (name, task);
    }
    return null;
  }

  String _cleanName(String raw) {
    var name = raw.trim();
    String prev = '';
    while (prev != name) {
      prev = name;
      name = name.replaceAll(_trailingNoise, '').trim();
    }
    return name.replaceAll(RegExp(r'^(my|the)\s+', caseSensitive: false), '');
  }

  /// Returns the name to call, or null when [text] isn't a call request.
  String? parseCallIntent(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    for (final re in _patterns) {
      final m = re.firstMatch(t);
      if (m != null) {
        var name = (m.group(1) ?? '').trim();
        String prev = '';
        while (prev != name) {
          prev = name;
          name = name.replaceAll(_trailingNoise, '').trim();
        }
        name = name.replaceAll(RegExp(r'^(my|the)\s+', caseSensitive: false), '');
        if (name.isNotEmpty && name.length >= 2) return name;
      }
    }
    return null;
  }

  /// Words that cancel a pending "which one?" disambiguation.
  bool isCancel(String text) => RegExp(
          r"\b(cancel|never ?mind|stop|leave it|rehne do|beda|nahi)\b",
          caseSensitive: false)
      .hasMatch(text);

  // ---------------- CONTACT MATCHING ----------------

  Future<bool> ensurePermission() async {
    try {
      return await FlutterContacts.requestPermission(readonly: true);
    } catch (_) {
      return false;
    }
  }

  String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Fuzzy score: exact > word-exact > prefix > contains.
  int _score(String contactName, String wanted) {
    final c = _norm(contactName), w = _norm(wanted);
    if (c.isEmpty || w.isEmpty) return 0;
    if (c == w) return 100;
    final words = c.split(' ');
    if (words.contains(w)) return 80;
    if (words.any((x) => x.startsWith(w)) || c.startsWith(w)) return 60;
    if (c.contains(w)) return 40;
    // Multi-word queries: all words present somewhere.
    final wWords = w.split(' ');
    if (wWords.length > 1 && wWords.every(c.contains)) return 55;
    return 0;
  }

  /// Contacts matching [name], best first. Empty = none / no permission.
  Future<List<Contact>> findContacts(String name) async {
    if (!await ensurePermission()) return const [];
    final all = await FlutterContacts.getContacts(withProperties: true);
    final scored = <(int, Contact)>[];
    for (final c in all) {
      if (c.phones.isEmpty) continue;
      var s = _score(c.displayName, name);
      // Nicknames count too ("Amma" saved as nickname on "Lakshmi").
      for (final n in c.name.nickname.split(RegExp(r'[,/]'))) {
        final ns = _score(n, name);
        if (ns > s) s = ns;
      }
      if (s > 0) scored.add((s, c));
    }
    scored.sort((a, b) => b.$1 - a.$1);
    // Keep everything within 20 points of the best (close calls only).
    if (scored.isEmpty) return const [];
    final top = scored.first.$1;
    return scored
        .where((e) => e.$1 >= top - 20)
        .map((e) => e.$2)
        .take(4)
        .toList();
  }

  /// From a pending shortlist, pick whichever the user's reply names.
  Contact? chooseFrom(List<Contact> options, String reply) {
    Contact? best;
    var bestScore = 39;
    for (final c in options) {
      final s = _score(c.displayName, reply);
      if (s > bestScore) {
        bestScore = s;
        best = c;
      }
    }
    // Ordinals: "the first one" / "second".
    final r = reply.toLowerCase();
    if (best == null) {
      if (r.contains('first') || r.contains('pehla')) return options.first;
      if (r.contains('second') && options.length > 1) return options[1];
      if (r.contains('third') && options.length > 2) return options[2];
    }
    return best;
  }

  /// Prefer mobile numbers over landline/work.
  String bestNumber(Contact c) {
    for (final p in c.phones) {
      if (p.label == PhoneLabel.mobile) return p.number;
    }
    return c.phones.first.number;
  }

  // ---------------- DIALING ----------------

  /// Places the call. Android: direct (CALL_PHONE); anywhere that fails,
  /// the dialer opens pre-filled instead — the call is never lost.
  Future<bool> call(String number) async {
    final clean = number.replaceAll(RegExp(r'[^\d+#*]'), '');
    if (clean.isEmpty) return false;
    try {
      final ok = await FlutterPhoneDirectCaller.callNumber(clean);
      if (ok == true) return true;
    } catch (_) {}
    try {
      return await launchUrl(Uri.parse('tel:$clean'));
    } catch (_) {
      return false;
    }
  }
}
