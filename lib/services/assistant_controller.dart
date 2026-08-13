import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/chat_message.dart';
import '../models/user_document.dart';
import '../models/vision_result.dart';
import 'api_service.dart';
import 'auth_service.dart';
import 'call_service.dart';
import 'notification_service.dart';
import 'phone_state_guard.dart';
import 'region_language.dart';
import 'voice_service.dart';

enum OrbState { idle, listening, thinking, speaking }

/// The assistant's brain, independent of any screen.
///
/// The whole wake → listen → answer → speak loop lives here, so it keeps
/// running when the screen is off or the user is in another tab — the UI
/// merely observes it.
///
/// Wake word engines, best first:
///  1. Porcupine (on-device, ~100 ms, screen-off capable) — used when a
///     PICOVOICE_ACCESS_KEY is provided and assets/wake/hey_hari_android.ppn
///     exists.
///  2. Fallback: Android speech recognizer transcript watching
///     (foreground only, higher latency).
///
/// NOTE: the microphone foreground service (screen-off listening) was
/// removed for now — flutter_foreground_task broke AGP 9 builds. Wake
/// word works while the app is open; screen-off returns later.
class AssistantController extends ChangeNotifier {
  AssistantController._();
  static final AssistantController instance = AssistantController._();

  final _voice = VoiceService.instance;
  final _history = <ChatMessage>[];

  OrbState state = OrbState.idle;
  bool micReady = false;
  bool wakeEnabled = true;
  bool onDeviceWake = false; // true when Porcupine is active
  String partial = '';
  String? lastHeard;
  String? lastReply;

  /// Documents Hari recalled for the LAST spoken answer — the voice screen
  /// shows them as tappable cards while the reply is being spoken, so
  /// "show me the report from my last hospital visit" really pops it up.
  List<UserDocument> lastDocuments = const [];

  /// Live input loudness 0..1 while recording — drives the orb pulse so
  /// the user can SEE the mic is hearing them.
  double micLevel = 0;

  /// Recognizer language chosen by the user in the picker (persisted).
  /// null = Auto: use the regional language detected from location,
  /// falling back to the device recognizer default.
  String? sttLocaleId;
  String? sttLocaleName;

  /// Regional language resolved from the user's location (Auto mode).
  String? autoLocaleId;
  String? autoLocaleName;

  /// What the recognizer actually uses.
  String? get effectiveLocaleId => sttLocaleId ?? autoLocaleId;

  PorcupineManager? _porcupine;
  bool _initialized = false;

  static const _accessKey = String.fromEnvironment('PICOVOICE_ACCESS_KEY');
  static const _modelAsset = 'assets/wake/hey_hari_android.ppn';

  static const _wakePrefKey = 'wake_word_enabled';
  static const _sttLocalePrefKey = 'stt_locale_id';
  static const _sttLocaleNamePrefKey = 'stt_locale_name';

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Respect the user's saved choice — the mic and the foreground
    // service never start if they switched the wake word off.
    try {
      final prefs = await SharedPreferences.getInstance();
      wakeEnabled = prefs.getBool(_wakePrefKey) ?? true;
      sttLocaleId = prefs.getString(_sttLocalePrefKey);
      sttLocaleName = prefs.getString(_sttLocaleNamePrefKey);
    } catch (_) {}

    micReady = await _voice.init();
    ReminderNotifications.instance.sync(); // permissions + schedules
    await _initPorcupine();
    if (micReady && wakeEnabled) await _startWake();
    notifyListeners();

    // INCOMING-CALL GUARD: the instant the phone rings (or any call
    // connects), Hari shuts up and lets go of the mic — talking over a
    // ringing phone is the single most annoying thing an assistant can
    // do. Resumes wake listening after the call ends.
    PhoneStateGuard.instance.start(
      onCallActive: _onPhoneCallActive,
      onCallEnded: _onPhoneCallEnded,
    );

    // Regional language from location (non-blocking; Auto mode only).
    _detectRegionalLanguage();
  }

  /// Karnataka -> Kannada, Kerala -> Malayalam, etc. Only applies while
  /// the user hasn't picked a language themselves, and only if the
  /// device recognizer actually supports the regional locale.
  ///
  /// ORDER MATTERS: GPS runs FIRST so the location permission dialog
  /// actually appears (previously the IP path usually succeeded and the
  /// app never touched location at all). IP stays as the no-permission
  /// fallback. As a side effect the resolved city is saved to the user's
  /// memory so Hari can personalize ("weather in Mysuru" etc.).
  Future<void> _detectRegionalLanguage() async {
    if (sttLocaleId != null) return; // user's explicit choice wins
    if (autoLocaleId != null) return; // conversation already set a language
    try {
      // 1) Device location (asks permission on first run).
      final wanted = <String>[...await RegionLanguage.candidates()];
      // 2) IP-based via the backend — zero permissions, works everywhere.
      if (wanted.isEmpty) {
        final byIp = await ApiService.fetchRegionLocale();
        if (byIp != null) wanted.add(byIp);
      }
      // Share the fix with the API layer → weather headers on every chat.
      ApiService.geoLat = RegionLanguage.lastLat;
      ApiService.geoLng = RegionLanguage.lastLng;
      _saveCityToMemory(); // fire-and-forget; reuses the same fix/permission
      if (wanted.isEmpty) return;
      final supported = await _voice.sttLocales();
      if (supported.isEmpty) return;

      String norm(String id) => id.toLowerCase().replaceAll('-', '_');
      for (final want in wanted) {
        final w = norm(want);
        // Exact locale, else same language any region.
        for (final exact in [true, false]) {
          for (final l in supported) {
            final id = norm(l.localeId);
            final match = exact
                ? id == w
                : id.split('_').first == w.split('_').first;
            if (match) {
              autoLocaleId = l.localeId;
              autoLocaleName = l.name;
              notifyListeners();
              return;
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Saves the user's current city into their backend memory (at most
  /// once per app session) so replies can be location-aware.
  bool _citySaved = false;
  Future<void> _saveCityToMemory() async {
    if (_citySaved) return;
    _citySaved = true;
    try {
      final city = await RegionLanguage.currentCity();
      ApiService.geoLat = RegionLanguage.lastLat;
      ApiService.geoLng = RegionLanguage.lastLng;
      if (city != null) {
        await ApiService.addMemory('current_city', 'Is currently in $city',
            category: 'context');
      }
    } catch (_) {
      _citySaved = false; // retry next session
    }
  }

  // ---------------- GREETING ON SIGN-IN / APP OPEN ----------------

  bool _greeted = false;
  int? _greetedUserId;

  /// Speaks a personalized hello once per app session. The text comes
  /// from the backend (built from the user's memory); when Hari barely
  /// knows the user it ends with ONE get-to-know-you question — in that
  /// case the mic opens automatically so the answer flows through the
  /// normal /chat loop and the memory extractor learns from it.
  Future<void> greetOnLaunch() async {
    final uid = AuthService.instance.user?.id;
    if (uid != null && uid != _greetedUserId) _greeted = false; // new account
    if (_greeted || !micReady || state != OrbState.idle) return;
    _greeted = true;
    _greetedUserId = uid;

    final greeting = await ApiService.fetchGreeting();
    if (greeting == null || state != OrbState.idle) return;

    await _pauseWake();
    state = OrbState.speaking;
    lastReply = greeting;
    // The greeting is part of the conversation — the AI must remember
    // what it asked when the user's answer arrives.
    _history.add(ChatMessage(role: 'assistant', content: greeting));
    notifyListeners();

    await _voice.speak(greeting);

    state = OrbState.idle;
    notifyListeners();

    if (greeting.contains('?')) {
      // Hari asked something — listen for the answer right away.
      await ask();
    } else {
      await _startWake();
    }
  }

  Future<void> _initPorcupine() async {
    if (_accessKey.isEmpty) return;
    try {
      // Verify the trained model is bundled before handing it to Porcupine.
      await rootBundle.load(_modelAsset);
      _porcupine = await PorcupineManager.fromKeywordPaths(
        _accessKey,
        [_modelAsset],
        (_) => _onWake(),
      );
      onDeviceWake = true;
    } catch (_) {
      _porcupine = null;
      onDeviceWake = false; // fall back to transcript watching
    }
  }

  // ---------------- WAKE MANAGEMENT ----------------

  Future<void> _startWake() async {
    if (!micReady || !wakeEnabled || state != OrbState.idle) return;
    if (_porcupine != null) {
      try {
        await _porcupine!.start();
        return;
      } catch (_) {
        onDeviceWake = false;
      }
    }
    await _voice.startWatching(onWake: _onWake);
  }

  Future<void> _pauseWake() async {
    if (_porcupine != null) {
      try {
        await _porcupine!.stop();
      } catch (_) {}
    }
    await _voice.stopWatching();
  }

  Future<void> setWakeEnabled(bool v) async {
    wakeEnabled = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_wakePrefKey, v);
    } catch (_) {}
    if (v) {
      await _startWake();
    } else {
      await _pauseWake();
    }
  }

  /// Languages the device recognizer supports, for the picker UI.
  Future<List<stt.LocaleName>> availableLanguages() =>
      _voice.sttLocales();

  Future<void> setSttLocale(String? localeId, String? localeName) async {
    sttLocaleId = localeId;
    sttLocaleName = localeName;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (localeId == null) {
        await prefs.remove(_sttLocalePrefKey);
        await prefs.remove(_sttLocaleNamePrefKey);
      } else {
        await prefs.setString(_sttLocalePrefKey, localeId);
        await prefs.setString(_sttLocaleNamePrefKey, localeName ?? localeId);
      }
    } catch (_) {}
    if (localeId == null) _detectRegionalLanguage();
  }

  void _onWake() {
    HapticFeedback.heavyImpact();
    ApiService.warm(); // wake the network path immediately
    ask();
  }

  // ---------------- VOICE-DRIVEN CAMERA (Group B x voice) ----------------

  /// While set, the current conversation is ABOUT this photo: every
  /// follow-up question routes to /vision with the photo re-attached,
  /// so "what's the dosage?" after "help me understand this" just works.
  /// Cleared when the conversation ends, on "close camera", or replaced
  /// by "take another photo".
  List<int>? _visionBytes;
  final List<ChatMessage> _visionThread = [];

  /// Camera words across the languages Hari hears most, script + Latin
  /// (covers "camera open madu", "photo tegi", "कैमरा खोलो"…).
  static final _cameraWord = RegExp(
      r'camera|kamera|ಕ್ಯಾಮ|कैमर|ക്യാമ|கேமர|కెమె|ਕੈਮਰ|ক্যামে',
      caseSensitive: false);
  static final _photoTake = RegExp(
      r'\btake (a |another |one more )?(photo|picture|pic)\b|\bclick (a )?(photo|pic)\b|'
      r'\b(photo|pic|picture|snap)\b\s*\b(tegi|le lo|lo|khinch|eduk|edu)\b|'
      r'ಫೋಟೋ|फोटो (लो|खींच)|ഫോട്ടോ എടു|புகைப்படம்|ఫోటో తీ',
      caseSensitive: false);
  static final _cameraClose = RegExp(
      r'close (the )?camera|stop (the )?camera|forget (the )?(photo|picture)|'
      r'ಕ್ಯಾಮೆರಾ (ಕ್ಲೋಸ್|ಮುಚ್ಚು)|कैमरा बंद|ക്യാമറ അടയ',
      caseSensitive: false);

  static bool wantsCamera(String q) =>
      _cameraWord.hasMatch(q) || _photoTake.hasMatch(q);

  // ------------- VOICE "SAVE THIS RECEIPT" (Group B x voice x memory) ----

  /// Save/remember verbs, script + Latin transliteration
  /// ("save madu", "yaad rakho", "ಸೇವ್ ಮಾಡು", "सेव करो"…).
  static final _saveVerb = RegExp(
      r'\b(save|remember|keep|store|file)\b|save (ma+du|karo)|yaad rakh|'
      r'ಸೇವ್|ನೆನಪ|ಇಟ್ಟುಕೊ|सेव|सहेज|याद रख|സേവ്|ഓർത്ത|சேமி|ஞாபக|సేవ్|గుర్తు',
      caseSensitive: false);

  /// Things people photograph to keep: receipts, bills, prescriptions…
  /// "recipe" included deliberately — speech-to-text very often hears
  /// "receipt" as "recipe" ("save the recipe given by Dr. Srikanth").
  static final _docNoun = RegExp(
      r'receipt|reciept|recipe|bill\b|invoice|prescription|document|report|'
      r'warranty|slip|voucher|statement|ticket|certificate|letter|form\b|card\b|'
      r'ರಸೀದಿ|ಬಿಲ್|ದಾಖಲೆ|रसीद|बिल|पर्च|दस्तावेज|രസീത|ബില്‍|ரசீது|பில்|రసీదు|బిల',
      caseSensitive: false);

  static final _thisPhoto = RegExp(
      r'\b(this|it|that)\b|photo|picture|pic\b|ಇದ|इस|ये|यह|ഇത|இத|ఇద',
      caseSensitive: false);

  /// "Save this receipt" → camera opens, the shot is filed into Hari's
  /// document memory (/docs analyzes it in the background), and the
  /// conversation carries on. If a photo is already on the table
  /// ("what's this?" … "save it") that photo is saved without reopening
  /// the camera. Returns null when [question] wasn't a save request.
  Future<bool?> _maybeHandleSaveDocument(String question) async {
    if (!_saveVerb.hasMatch(question)) return null;
    final photoOnTable =
        _visionBytes != null && _thisPhoto.hasMatch(question);
    // Plain "remember that mom's birthday is in May" is a memory fact for
    // the backend, NOT a document — require a document word (or an active
    // photo being referred to).
    if (!_docNoun.hasMatch(question) && !photoOnTable) return null;

    List<int>? bytes = photoOnTable ? _visionBytes : null;
    if (bytes == null) {
      await _sayLocal('Sure — show it to the camera.');
      final XFile? shot;
      try {
        shot = await ImagePicker().pickImage(
          source: ImageSource.camera,
          maxWidth: 1920,
          maxHeight: 1920,
          imageQuality: 82,
        );
      } catch (_) {
        await _sayLocal("I couldn't open the camera.");
        return true;
      }
      if (shot == null) {
        await _sayLocal('Okay, nothing saved.');
        return true; // user backed out; keep talking
      }
      bytes = await shot.readAsBytes();
    }

    state = OrbState.thinking;
    lastHeard = question;
    notifyListeners();
    try {
      // note = the user's own words — recited back on recall, which makes
      // "the receipt I saved after the Apollo visit" findable.
      await ApiService.uploadDocument(
        bytes: bytes,
        filename:
            'voice_save_${DateTime.now().millisecondsSinceEpoch}.jpg',
        mimeType: 'image/jpeg',
        note: question,
      );
      await _sayLocal(
          "Saved. Ask me for it anytime — I'll remember what's on it.");
    } catch (_) {
      await _sayLocal(
          "I couldn't save that — please check your connection and try once more.");
    }
    return true; // conversation continues either way
  }

  /// Opens the camera, captures, and speaks an answer grounded in the
  /// photo. Returns null when [question] wasn't a camera request.
  Future<bool?> _maybeHandleCamera(String question) async {
    if (_cameraClose.hasMatch(question)) {
      if (_visionBytes == null) return null;
      _clearVision();
      await _sayLocal('Okay, done with the photo.');
      return true; // conversation continues, back to normal chat
    }
    if (!wantsCamera(question)) return null;

    _clearVision();
    await _sayLocal('Opening the camera.');
    final XFile? shot;
    try {
      shot = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 82, // ~1 MB uploads — fast on mobile data
      );
    } catch (_) {
      await _sayLocal("I couldn't open the camera.");
      return true;
    }
    if (shot == null) {
      await _sayLocal('Okay.');
      return true; // user backed out; keep the conversation alive
    }
    _visionBytes = await shot.readAsBytes();
    return _askVision(question);
  }

  /// One /vision turn about the captured photo (first ask or follow-up).
  Future<bool> _askVision(String question) async {
    state = OrbState.thinking;
    lastHeard = question;
    lastReply = null;
    lastDocuments = const [];
    notifyListeners();

    String answer;
    try {
      final r = await ApiService.visionAsk(
        bytes: _visionBytes!,
        filename: 'voice_capture.jpg',
        mimeType: 'image/jpeg',
        mode: 'ask',
        question:
            '$question (Answer for VOICE: short, conversational, and in the '
            'same language the question was asked in.)',
        history: _visionThread,
      );
      answer = r.answer;
      _visionThread
        ..add(ChatMessage(role: 'user', content: question))
        ..add(ChatMessage(role: 'assistant', content: answer));
      // The photo exchange also lands in normal history, so if the user
      // drifts to other topics the AI still knows what was discussed.
      _history
        ..add(ChatMessage(role: 'user', content: question))
        ..add(ChatMessage(role: 'assistant', content: answer));
    } catch (_) {
      answer = "I couldn't analyze that. Please check your connection.";
    }

    _followReplyLanguage(answer);
    state = OrbState.speaking;
    lastReply = answer;
    partial = '';
    notifyListeners();
    await _voice.speak(answer);
    return !_speechAborted; // orb tap while speaking ends the conversation
  }

  void _clearVision() {
    _visionBytes = null;
    _visionThread.clear();
  }

  // ---------------- THE ANSWER LOOP ----------------

  /// Text-initiated spoken turn (e.g. the Daily tab's briefing button):
  /// Hari answers aloud, then listens for follow-ups like any conversation.
  Future<void> runText(String question) => ask(text: question);

  Future<void> ask({String? text}) async {
    // A denied-then-granted mic permission used to leave the app stuck on
    // "Microphone unavailable" until restart — retry initialization here.
    if (!micReady) {
      micReady = await _voice.reinit();
      notifyListeners();
      if (!micReady) return;
    }
    if (state != OrbState.idle) return;
    await _pauseWake();
    // Let the wake recognizer fully release the microphone before the
    // recorder grabs it — starting both back-to-back made the mic flap
    // on/off and miss the first words on many devices.
    await Future.delayed(const Duration(milliseconds: 250));

    // CONTINUOUS CONVERSATION: after Hari finishes speaking, the mic
    // reopens automatically for a follow-up — no wake word, no tap.
    // The conversation ends when the user simply stays quiet (~6 s),
    // taps the orb, or the turn was a device action (e.g. a phone call).
    var followUp = false;
    var pendingText = text;
    while (true) {
      String question;
      if (pendingText != null) {
        question = pendingText; // first turn came typed, not spoken
        pendingText = null;
      } else {
        state = OrbState.listening;
        partial = '';
        notifyListeners();
        question = await _captureAnyLanguage(followUp: followUp);
      }
      if (question.trim().isEmpty) break; // silence or cancel → done

      final keepGoing = await _answerOnce(question);
      if (!keepGoing) break;
      followUp = true;
      // Tiny beat so the mic isn't grabbed while TTS audio is tailing off.
      await Future.delayed(const Duration(milliseconds: 150));
    }

    _clearVision(); // photo context lives only within one conversation
    state = OrbState.idle;
    notifyListeners();
    await _startWake();
  }

  /// Capture path, best first:
  ///  1. CLOUD (Whisper via backend /stt) — record m4a, auto language
  ///     detection: Kannada, Hindi, English, mixed — no locale needed.
  ///  2. Device recognizer with the effective locale, if recording or
  ///     transcription fails (offline, permission, server down).
  Future<String> _captureAnyLanguage({bool followUp = false}) async {
    // 1) Cloud path (preferred).
    if (await _voice.canRecord()) {
      final path = await _voice.recordUntilSilence(
        // Follow-up turn: wait ~6 s for the user to keep talking, then
        // end the conversation gracefully instead of listening forever.
        noSpeechTimeoutMs: followUp ? 6000 : 8000,
        onLevel: (l) {
          micLevel = l;
          notifyListeners();
        },
      );
      micLevel = 0;
      if (path == null) {
        // User cancelled (orb tap) → genuinely stop.
        if (_voice.lastRecordingCancelled) return '';
        // Follow-up + silence = the user is done talking. Ending here is
        // the feature, not a failure — don't fall to the device recognizer.
        if (followUp) return '';
        // VAD heard nothing — DON'T give up silently anymore. The old
        // behaviour ("mic turns on and off but nothing happens") ended
        // here; now we hand over to the device recognizer, which has its
        // own tuned endpointing and often hears what the VAD missed.
      } else {
        partial = '…';
        notifyListeners();
        try {
          return await ApiService.transcribe(
            path,
            // Manual pick in "I speak…" = lock transcription to it.
            forceLanguage: _iso(sttLocaleId),
            // Auto + known region = bias detection (Kannada wins over the
            // Hindi misdetection, but English/Hindi speech still works).
            hintLanguage: sttLocaleId == null ? _iso(autoLocaleId) : null,
          );
        } catch (_) {
          // Server unreachable AFTER the user already spoke — ask them to
          // repeat once via the device recognizer instead of going mute.
          partial = '';
          notifyListeners();
        }
      }
    }

    // 2) Device recognizer (recorder unavailable, VAD missed the speech,
    //    or cloud STT failed).
    final q = await _voice.captureQuestion(
      localeId: effectiveLocaleId,
      onPartial: (p) {
        partial = p;
        notifyListeners();
      },
      onLevel: (l) {
        micLevel = l;
        notifyListeners();
      },
    );
    micLevel = 0;
    return q;
  }

  /// 'kn_IN' / 'kn-IN' -> 'kn' (ISO-639-1 for Whisper). null-safe.
  static String? _iso(String? localeId) {
    if (localeId == null || localeId.isEmpty) return null;
    final code = localeId.split(RegExp('[-_]')).first.toLowerCase();
    return code.length == 2 ? code : null;
  }

  /// Sentence boundaries across scripts (., !, ?, …, Devanagari danda).
  /// Whitespace-terminated so "3.5" or a sentence still being typed is
  /// never cut early — the final flush handles the reply's last sentence.
  static final _sentenceEnd = RegExp('[.!?…।॥]+["\')\\]]?\\s');

  /// True while the user has tapped the orb to cut Hari off mid-answer —
  /// stops the queued sentences, not just the one currently playing.
  bool _speechAborted = false;

  /// True when the abort came from the user TALKING OVER Hari (barge-in)
  /// rather than an orb tap. A barge-in continues the conversation (capture
  /// the new question immediately); an orb tap ends it.
  bool _bargedIn = false;

  /// Guards start/stop of the barge-in monitor within one answer.
  bool _bargeMonitorOn = false;

  /// The user started speaking over Hari — stop the reply at once and let
  /// the loop capture what they're saying.
  void _onBargeIn() {
    _speechAborted = true;
    _bargedIn = true;
  }

  /// question -> STREAMED reply -> speak sentence-by-sentence.
  /// Hari starts SPEAKING the first sentence while the rest of the answer
  /// is still being generated (Gemini-Live-style time-to-first-audio).
  /// Returns false when the conversation should end (device action /
  /// user interrupt), true to keep listening for a follow-up.
  Future<bool> _answerOnce(String question) async {
    question = question.trim();
    if (question.isEmpty) return false;

    // DEVICE ACTIONS FIRST: "call amma" is handled entirely on-device
    // (contacts + dialer) — private, instant, works offline.
    if (await _handleCallIntent(question)) return false;

    // SAVE A DOCUMENT: "save this receipt" — must run BEFORE the camera
    // handler ("take a photo of the bill and save it" contains photo
    // words) and before photo follow-ups ("save it" about the current
    // photo files it instead of asking vision about it).
    final saved = await _maybeHandleSaveDocument(question);
    if (saved != null) return saved;

    // CAMERA: "open camera and help me understand this" — opens the
    // camera, then answers grounded in the photo. "Take another photo"
    // recaptures; "close camera" returns to normal chat.
    final cam = await _maybeHandleCamera(question);
    if (cam != null) return cam;
    // Active photo context → this follow-up is about the photo.
    if (_visionBytes != null) return _askVision(question);

    state = OrbState.thinking;
    lastHeard = question;
    lastReply = null;
    lastDocuments = const [];
    _speechAborted = false;
    _bargedIn = false;
    _bargeMonitorOn = false;
    notifyListeners();

    _history.add(ChatMessage(role: 'user', content: question));
    // Keep the payload small for latency; backend trims further.
    final window = _history.length > 12
        ? _history.sublist(_history.length - 12)
        : _history;

    // Sentences are spoken strictly in order on this chain while the
    // stream keeps filling the buffer behind them.
    var speakChain = Future<void>.value();
    var pending = '';
    void enqueue(String sentence) {
      final say = sentence.trim();
      if (say.isEmpty) return;
      speakChain = speakChain.then((_) async {
        if (_speechAborted) return;
        if (state != OrbState.speaking) {
          state = OrbState.speaking;
          notifyListeners();
        }
        // BARGE-IN: the moment Hari starts talking, listen for the user
        // talking over her. Started once, spans the whole spoken reply.
        if (!_bargeMonitorOn) {
          _bargeMonitorOn = true;
          _voice.startBargeInMonitor(_onBargeIn);
        }
        await _voice.speak(say);
      });
    }

    void onDelta(String d) {
      if (_speechAborted) return;
      pending += d;
      lastReply = (lastReply ?? '') + d; // live transcript in the UI
      notifyListeners();
      // Flush every completed sentence to TTS immediately.
      int idx;
      while ((idx = pending.indexOf(_sentenceEnd)) >= 0) {
        final m = _sentenceEnd.firstMatch(pending.substring(idx))!;
        final cut = idx + m.end;
        enqueue(pending.substring(0, cut));
        pending = pending.substring(cut);
      }
    }

    ChatMessage answer;
    try {
      answer = await ApiService.sendChatStream(window, onDelta: onDelta);
    } on QuotaExceeded catch (q) {
      // Plan allowance used up — the server sends a ready-to-speak line.
      answer = ChatMessage(role: 'assistant', content: q.message);
      lastReply = answer.content;
      pending = answer.content;
    } catch (_) {
      // Streaming unavailable → classic one-shot request.
      try {
        answer = await ApiService.sendChat(window);
        lastReply = answer.content;
      } on QuotaExceeded catch (q) {
        answer = ChatMessage(role: 'assistant', content: q.message);
        lastReply = answer.content;
      } catch (_) {
        answer = const ChatMessage(
            role: 'assistant',
            content:
                "I couldn't reach the assistant. Please check your connection.");
        lastReply = answer.content;
      }
      pending = answer.content;
    }
    _history.add(answer);
    lastDocuments = answer.documents;
    final reply = answer.content;

    // FOLLOW THE CONVERSATION'S LANGUAGE: if Hari answered in Kannada,
    // listen in Kannada next time — this is what makes "speak in
    // Kannada" (said in any language) actually switch the whole loop,
    // independent of location. A manual pick still overrides.
    _followReplyLanguage(reply);

    lastReply = reply;
    partial = '';
    notifyListeners();

    // "Remind me to…" may have just created a reminder server-side —
    // resync so the phone schedules its notification immediately.
    ReminderNotifications.instance.sync();

    enqueue(pending); // whatever remained after the last sentence mark
    await speakChain; // wait until every queued sentence has been spoken

    // Release the barge-in mic so the next capture can grab it.
    if (_bargeMonitorOn) {
      await _voice.stopBargeInMonitor();
      _bargeMonitorOn = false;
    }

    // Barge-in: the user talked over Hari → KEEP the conversation going and
    // capture what they're now saying (no wake word, no tap needed).
    if (_bargedIn) {
      _bargedIn = false;
      state = OrbState.thinking;
      notifyListeners();
      return true;
    }

    if (_speechAborted) return false; // orb tap → end conversation
    state = OrbState.thinking; // brief neutral state while mic reopens
    notifyListeners();
    return true;
  }

  List<stt.LocaleName>? _supportedLocales;

  Future<void> _followReplyLanguage(String reply) async {
    if (sttLocaleId != null) return; // user's explicit choice wins
    try {
      final lang = VoiceService.detectLanguage(reply); // e.g. kn-IN
      _supportedLocales ??= await _voice.sttLocales();
      final supported = _supportedLocales ?? const [];

      String norm(String id) => id.toLowerCase().replaceAll('-', '_');
      final want = norm(lang);
      stt.LocaleName? pick;
      for (final l in supported) {
        final id = norm(l.localeId);
        if (id == want) {
          pick = l;
          break;
        }
        pick ??=
            id.split('_').first == want.split('_').first ? l : pick;
      }
      if (pick != null && pick.localeId != autoLocaleId) {
        autoLocaleId = pick.localeId;
        autoLocaleName = pick.name;
        notifyListeners();
      }
    } catch (_) {}
  }

  // ---------------- VOICE CALLING ----------------

  /// Set while Hari has asked "which one?" — the next heard phrase picks
  /// from these contacts instead of going to the AI.
  List<Contact>? _pendingCallOptions;

  /// G2 — a previewed agent call waiting for a spoken yes/no. Hari has
  /// already read out exactly what it will say; only a "yes" dials.
  (Contact, String)? _pendingAgentConfirm;

  /// When the pending call is an AGENT call ("…and ask him when he'll be
  /// home"), the task rides along so the chosen contact gets it.
  String? _pendingCallTask;

  Future<void> _sayLocal(String text) async {
    state = OrbState.speaking;
    lastReply = text;
    notifyListeners();
    await _voice.speak(text);
  }

  static final _yesRe = RegExp(
      r"^\s*(yes|yeah|yep|ya|sure|ok(ay)?|go ahead|do it|call|haan|ho|houdu|sari)\b",
      caseSensitive: false);

  /// Returns true when [question] was a call request (handled here).
  Future<bool> _handleCallIntent(String question) async {
    final svc = CallService.instance;

    // G2 — an agent-call preview is awaiting approval: this utterance IS
    // the verdict. Anything that isn't a clear yes cancels (safe default —
    // Hari never phones a contact on an ambiguous mumble).
    if (_pendingAgentConfirm != null) {
      final (contact, task) = _pendingAgentConfirm!;
      _pendingAgentConfirm = null;
      lastHeard = question;
      if (_yesRe.hasMatch(question)) {
        await _placeAgentCall(contact, task);
      } else {
        await _sayLocal("Okay, I won't call.");
      }
      return true;
    }

    // A "which one?" follow-up is pending: interpret this as the choice.
    if (_pendingCallOptions != null) {
      final options = _pendingCallOptions!;
      final task = _pendingCallTask;
      _pendingCallOptions = null;
      _pendingCallTask = null;
      if (svc.isCancel(question)) {
        lastHeard = question;
        await _sayLocal('Okay, cancelled.');
        return true;
      }
      final chosen = svc.chooseFrom(options, question);
      if (chosen != null) {
        lastHeard = question;
        if (task != null) {
          await _previewAgentCall(chosen, task);
        } else {
          await _placeCall(chosen);
        }
        return true;
      }
      return false; // not a choice — treat as a normal question
    }

    // AGENT CALL FIRST: "call allen lobo and ask him at what time he will
    // come home" also matches the plain call pattern, so the richer intent
    // must win. Hari calls Allen, ASKS HIM ITSELF, and speaks his answer.
    final agent = svc.parseAgentCallIntent(question);
    final name = agent?.$1 ?? svc.parseCallIntent(question);
    if (name == null) return false;
    // The bare-"ask X …" phrasing is only a call when X is a real contact;
    // otherwise it's a normal question for the AI ("ask google…" etc.).
    final askOnly = agent != null && !RegExp(r'\b(call|dial|phone|ring)\b',
            caseSensitive: false)
        .hasMatch(question);
    lastHeard = question;
    lastReply = null;
    lastDocuments = const [];
    notifyListeners();

    final matches = await svc.findContacts(name);
    if (matches.isEmpty) {
      if (askOnly) return false; // no such contact → let the AI answer it
      final hasPerm = await svc.ensurePermission();
      await _sayLocal(hasPerm
          ? "I couldn't find $name in your contacts."
          : 'I need contact access to make calls — you can allow it in settings.');
      return true;
    }
    if (matches.length == 1) {
      if (agent != null) {
        await _previewAgentCall(matches.first, agent.$2);
      } else {
        await _placeCall(matches.first);
      }
      return true;
    }

    // Several close matches: ask, then listen for the answer.
    final names = matches.map((c) => c.displayName).toList();
    final listed = names.length == 2
        ? '${names[0]} or ${names[1]}'
        : '${names.sublist(0, names.length - 1).join(', ')}, or ${names.last}';
    _pendingCallOptions = matches;
    _pendingCallTask = agent?.$2;
    await _sayLocal('I found ${matches.length}: $listed. Which one?');
    state = OrbState.idle;
    notifyListeners();
    await ask(); // opens the mic; the reply routes back through here
    return true;
  }

  /// G2 — CALL PREVIEW & APPROVAL: fetch the exact opening line from the
  /// backend, speak it, and wait for a yes/no. The user's own call rules
  /// (daily limit, allowed hours, master switch) are checked server-side
  /// in the same request; a block is spoken instead of dialing. If the
  /// preview endpoint is unreachable we fall back to the old direct flow
  /// rather than leaving the request hanging.
  Future<void> _previewAgentCall(Contact c, String task) async {
    state = OrbState.thinking;
    notifyListeners();
    try {
      final p = await ApiService.agentCallPreview(
        contactName: c.displayName,
        task: task,
        lang: sttLocaleId ?? autoLocaleId,
      );
      if (!p.allowed) {
        await _sayLocal(p.reason ?? "Your call rules don't allow this right now.");
        return;
      }
      _pendingAgentConfirm = (c, task);
      await _sayLocal(
          'Here\'s what I\'ll say to ${c.displayName}: "${p.opening}" '
          'Shall I make the call?');
      state = OrbState.idle;
      notifyListeners();
      await ask(); // opens the mic; the yes/no routes back through here
    } catch (_) {
      // Preview unavailable (old backend / network) — proceed the old way.
      await _placeAgentCall(c, task);
    }
  }

  /// Hari itself calls [c], speaks with them about [task], then reports
  /// their answer back to the user. Backend-driven (Plivo — India-capable telephony): the phone's
  /// own dialer is never involved, so the loop keeps running while the
  /// call happens and the answer is spoken the moment it lands.
  Future<void> _placeAgentCall(Contact c, String task) async {
    final svc = CallService.instance;
    final number = svc.bestNumber(c);
    await _sayLocal(
        "Alright — I'll call ${c.displayName} and ask. Give me a moment, "
        "I'll tell you what they say.");
    state = OrbState.thinking;
    notifyListeners();

    String id;
    try {
      id = await ApiService.startAgentCall(
        toNumber: number,
        contactName: c.displayName,
        task: task,
        lang: sttLocaleId ?? autoLocaleId,
      );
    } on AgentCallUnavailable {
      // No telephony on this deployment — degrade to a normal call so the
      // user's request still gets acted on.
      await _sayLocal(
          "I can't speak on calls yet on this setup, so I'll connect you "
          "to ${c.displayName} directly.");
      await svc.call(number);
      return;
    } on QuotaExceeded catch (q) {
      // Plan limit — explain, then still connect them directly so the
      // user's actual need (reaching Allen) is never blocked.
      await _sayLocal("${q.message} I'll connect you directly instead.");
      await svc.call(number);
      return;
    } catch (_) {
      await _sayLocal(
          "Sorry, I couldn't start the call to ${c.displayName} just now.");
      return;
    }

    // Poll until the call reaches a terminal state (≈3 min ceiling —
    // dial 30 s + a capped conversation always fits well inside it).
    const poll = Duration(seconds: 3);
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    String? result;
    var stateName = 'dialing';
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(poll);
      try {
        final s = await ApiService.agentCallStatus(id);
        stateName = s.state;
        if (s.state == 'completed' ||
            s.state == 'no_answer' ||
            s.state == 'failed') {
          result = s.result;
          break;
        }
      } catch (_) {/* transient poll error — keep waiting */}
    }

    result ??= stateName == 'in_progress' || stateName == 'summarizing'
        ? "The call with ${c.displayName} is taking longer than expected — "
            "I'll keep the result in our chat."
        : "I couldn't complete the call to ${c.displayName}.";
    await _sayLocal(result);
    // The outcome belongs in the chat history so follow-ups ("call him
    // back", "what did he say again?") have context.
    _history.add(ChatMessage(role: 'assistant', content: result));
  }

  Future<void> _placeCall(Contact c) async {
    final svc = CallService.instance;
    final number = svc.bestNumber(c);
    await _sayLocal('Calling ${c.displayName}…');
    final ok = await svc.call(number);
    if (!ok) {
      await _sayLocal("Sorry, I couldn't start the call.");
    }
  }

  /// A phone call is ringing or connected — stop speaking IMMEDIATELY,
  /// drop every queued sentence, release the mic, and pause wake
  /// listening so speech recognition can't grab audio focus from the
  /// call. Any reply still streaming keeps filling the transcript card
  /// silently; nothing more is spoken aloud.
  Future<void> _onPhoneCallActive() async {
    _speechAborted = true; // kills the whole queued sentence chain
    _bargedIn = false; // a call is not a barge-in — don't resume after
    if (_bargeMonitorOn) {
      _bargeMonitorOn = false;
      try {
        await _voice.stopBargeInMonitor(); // free the mic for the call
      } catch (_) {}
    }
    try {
      await _voice.stopSpeaking(); // cut the CURRENT sentence mid-word
    } catch (_) {}
    switch (state) {
      case OrbState.listening:
        try {
          await _voice.cancelCapture();
        } catch (_) {}
      case OrbState.speaking:
      case OrbState.thinking:
      case OrbState.idle:
        break;
    }
    await _pauseWake();
    if (state != OrbState.idle) {
      state = OrbState.idle;
    }
    notifyListeners();
  }

  /// Call finished — go back to normal wake-word listening.
  Future<void> _onPhoneCallEnded() async {
    if (state == OrbState.idle) await _startWake();
  }

  /// Orb tap behaviour, mirroring the design doc.
  Future<void> tapOrb() async {
    HapticFeedback.mediumImpact();
    switch (state) {
      case OrbState.idle:
        await _pauseWake();
        ask();
      case OrbState.listening:
        await _voice.cancelCapture();
      case OrbState.speaking:
        _speechAborted = true; // stop queued sentences too, not just this one
        _bargedIn = false; // an explicit tap ENDS the conversation
        if (_bargeMonitorOn) {
          _bargeMonitorOn = false;
          await _voice.stopBargeInMonitor();
        }
        await _voice.stopSpeaking();
      case OrbState.thinking:
        break;
    }
  }

  /// App lifecycle: without the foreground service, listening pauses in
  /// the background and resumes when the app returns to the foreground.
  Future<void> onBackground() async {
    if (!onDeviceWake) await _voice.stopWatching();
  }

  Future<void> onForeground() async {
    if (state == OrbState.idle) await _startWake();
  }

}
