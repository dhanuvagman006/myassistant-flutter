import 'dart:async';
import 'dart:io';

// material re-exports foundation, and carries MaterialPageRoute /
// WidgetBuilder for opening the app's own screens by voice.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../ai/brain.dart';
import '../../../ai/listen.dart';
import '../../../ai/live_voice.dart';
import '../../../ai/model_port.dart';
import '../../../ai/search_suggestions.dart';
import '../../../ai/speech.dart' show SpeechEngine;
import '../../../ai/types.dart' show AiToolSpec;
import '../../../core/log.dart';
// Screens and settings reachable BY VOICE (open_app_screen / set_theme).
import '../../../services/avatar_message_service.dart';
import '../../../services/notification_service.dart';
import '../../../design/motion.dart' show showAppDialog;
import '../../../design/theme_controller.dart';
import '../../../shell/home_shell.dart';
import '../../../screens/documents_screen.dart';
import '../../../screens/phone/call_notes_screen.dart';
import '../../../screens/reminders_screen.dart';
import '../../../screens/business_card_flow.dart';
import '../../../screens/meetings/meeting_recorder_screen.dart';
import '../../../screens/meetings/meetings_screen.dart';
import '../../../screens/clients_screen.dart';
import '../../../screens/finance_screen.dart';
import '../../../screens/stocks_screen.dart';
import '../../../screens/diagnostics_screen.dart';
import '../../../screens/mcp_servers_screen.dart';
import '../../../screens/news_screen.dart';
import '../../../screens/calendar_screen.dart';
import '../../../screens/focus_screen.dart';
import '../../../screens/avatar_identity_screen.dart';
import '../../../screens/connected_apps_screen.dart';
import '../../../screens/shortcuts_screen.dart';
import '../../../models/shortcut.dart';
import '../../../services/shortcut_runner.dart';
import '../../../services/turn_audio_uploader.dart';
import '../../../screens/bills_email_screen.dart';
import '../../../models/user_document.dart';
import '../../../models/vision_result.dart';
import '../../../models/news_item.dart';
import '../../../models/schedule_item.dart';
import '../../../services/api_service.dart';
import '../../../services/audio/mic_stream.dart' show BargeInWatch;
import '../../../services/audio/pcm_player.dart';
import '../../../services/document_events.dart';
import '../../../services/device_control_service.dart';
import '../../../services/sms_service.dart';
import '../widgets/action_cards.dart' show shareDocumentFile;
import '../../../services/app_feedback.dart';
import '../../../services/auth_service.dart';
import '../../../services/app_update_service.dart';
import '../../../services/assistant_identity.dart';
import '../../../services/call_history.dart';
import '../../../services/call_service.dart';
import '../../../services/location_service.dart';
import '../../../services/missed_calls_service.dart';
import '../../../services/phone_calendar.dart';
import '../../../services/phone_state_guard.dart';
import '../../../services/brief_service.dart';
import '../../../services/contacts_sync_service.dart';
import '../../../services/listening_chime.dart';
import '../../../services/usage_service.dart';
import 'assistant_state.dart';
import '../../../services/greeting_voice.dart';
// 2026-09-30: the spoken morning and Meeting Prep (features/briefing).
import '../../briefing/briefing_directives.dart';
import '../../people/address_sheet.dart';
import '../../shopping/shop_handoff.dart';
import '../../shopping/shopping_list_screen.dart';
import '../../shopping/shopping_service.dart';

/// The assistant experience's single source of truth (ChangeNotifier — the
/// state-management style used across this codebase; the UI observes it
/// with AnimatedBuilder/ListenableBuilder).
///
/// Owns: the voice conversation (listen -> the brain's turn -> her voice
/// -> listen again), every typed and tapped request, the phase state
/// machine, transcript and captions, tool/search/contact/call cards,
/// confirmations, cancellation, and every device action the brain hands
/// the phone.
class AssistantEngine extends ChangeNotifier {
  AssistantEngine._() {
    AuthService.instance.onSignOut(_onSignedOut);
    _player.playingListenable.addListener(_onPlayback);
  }
  static final AssistantEngine instance = AssistantEngine._();

  // ---------------- THE BRAIN ----------------
  // Owner, 2026-09-29: the app talks to the models itself, through Firebase
  // AI Logic — Gemini in the cloud for every turn (Nano was removed the
  // same night), Gemini TTS for the voice — and the server is the tool
  // server (lib/ai/brain.dart). Every spoken, typed and tapped
  // request is ONE brain turn: its words become the captions, its device
  // actions run through [_onEvent] exactly as they always did (and are
  // always answered), and its reply is spoken sentence by sentence through
  // [_player]. There is no socket and no session to keep alive.

  AssistantBrain? _brainMade;

  /// The app's one brain (made on first use).
  AssistantBrain get brain => _brainMade ??= AssistantBrain.standard(
        sink: _player,
        deviceContext: _deviceContext,
      );

  /// The assistant's voice out, and the brain's AudioSink: one gapless
  /// 24 kHz PCM stream player, shared with the greeting.
  PcmPlayer _player = PcmPlayer.instance;

  VoiceListener? _listenerMade;
  VoiceListener get _listener =>
      _listenerMade ??= VoiceListener.standard(ModelPorts.cloud());

  /// Speech with no model behind it: a fixed line (someone's message read
  /// out, a greeting) in the assistant's own voice.
  SpeechEngine? _speechMade;
  SpeechEngine get _speech => _speechMade ??= SpeechEngine(port: ModelPorts.cloud());

  /// Talking over her: the microphone listens while she speaks.
  BargeInWatch? _bargeMade;
  BargeInWatch get _barge => _bargeMade ??= BargeInWatch(player: _player);
  // Off since 2026-10-02 (the owner: "remove interruption completely"):
  // the Interrupt button on the voice screen calls [bargeIn].
  bool _bargeWatchOn = false;

  // ---------------- THE FAST VOICE (Gemini Live) ----------------
  // 2026-09-30: a spoken conversation runs on ONE Gemini Live session
  // (lib/ai/live_voice.dart) — her first sound ~0.6 s after the owner stops
  // instead of 5-8 s. Its tools still go through the brain (the same
  // approvals and device actions); the cascade (recogniser -> brain ->
  // Fola) answers whatever Live cannot, and every typed message.

  LiveVoice? _liveMade;
  StreamSubscription<LiveEvent>? _liveSub;

  /// Tests that hand the engine no Live voice run the cascade only.
  bool _liveOff = false;

  /// This conversation is running on Live now.
  bool _liveMode = false;

  /// Live failed in this conversation: the cascade carries it to the end.
  bool _liveGaveUp = false;

  LiveVoice get _live {
    final made = _liveMade ??= LiveVoice.standard(
      brain: brain,
      player: _player,
      deviceContext: _deviceContext,
      // Testers who said yes to "help improve": the owner can hear the
      // turn in the admin panel (2026-10-01).
      onTurnAudio: (a) => unawaited(TurnAudioUploader.send(a)),
    );
    _liveSub ??= made.events.listen(_onLive);
    made.onLevel ??= (l) => micLevel = l;
    return made;
  }

  /// Live is wanted for the next listen: the owner's switch, the server's,
  /// and no failure in this conversation.
  bool get _liveWanted =>
      !_liveOff &&
      !_liveGaveUp &&
      LiveVoicePrefs.enabled &&
      AiConfigStore.instance.current.live.on;

  /// The conversation is on the fast (Live) voice right now.
  bool get fastVoice => _liveMode;

  /// Test seam: a scripted brain, listener, player and voice. The barge-in
  /// microphone stays off unless [bargeWatch]; the fast voice is off unless
  /// a [live] one is given.
  @visibleForTesting
  void debugUse({
    AssistantBrain? brain,
    VoiceListener? listener,
    PcmPlayer? player,
    SpeechEngine? speech,
    LiveVoice? live,
    bool bargeWatch = false,
  }) {
    if (brain != null) _brainMade = brain;
    if (listener != null) _listenerMade = listener;
    if (speech != null) _speechMade = speech;
    if (player != null && !identical(player, _player)) {
      _player.playingListenable.removeListener(_onPlayback);
      _player = player;
      _player.playingListenable.addListener(_onPlayback);
      _bargeMade = null;
    }
    _bargeWatchOn = bargeWatch;
    if (!identical(live, _liveMade)) {
      unawaited(_liveSub?.cancel());
      _liveSub = null;
      _liveMade = live;
    }
    _liveOff = live == null;
  }

  /// What every turn tells the server about this phone: what it may do
  /// (the permissions, so only tools that can work are offered) and where
  /// the owner is — the position that used to ride the live socket.
  static Future<Map<String, Object?>> _deviceContext() async {
    // The permissions take a dozen platform calls: read at most once a
    // minute (a revoked one still counts within a minute).
    final now = DateTime.now();
    final cached = _caps;
    if (cached == null || now.difference(_capsAt) > const Duration(minutes: 1)) {
      _caps = await AssistantBrain.phoneContext();
      _capsAt = now;
    }
    final out = <String, Object?>{...?_caps};
    final lat = ApiService.geoLat;
    final lng = ApiService.geoLng;
    if (lat != null && lng != null) {
      // Four decimals (~11 m): plenty for "near me".
      double r4(double v) => (v * 10000).roundToDouble() / 10000;
      out['lat'] = r4(lat);
      out['lng'] = r4(lng);
      final acc = LocationService.instance.accuracy;
      if (acc != null && acc.isFinite) out['acc'] = acc.round();
    }
    return out;
  }

  /// What the next turn will tell the server about this phone (tests).
  @visibleForTesting
  static Future<Map<String, Object?>> debugDeviceContext() => _deviceContext();

  static Map<String, Object?>? _caps;
  static DateTime _capsAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------------- observable state ----------------

  AssistantPhase phase = AssistantPhase.idle;

  /// The assistant's services answered the last turn (false after one that
  /// could not reach them).
  bool connected = true;
  String? errorMessage;

  /// Live mic loudness 0..1 while listening — drives the hero animation.
  ///
  /// A ValueNotifier of its own, NOT part of notifyListeners: level updates
  /// arrive several times a second for the whole conversation, and pushing
  /// each one through the engine's main listener rebuilt the entire
  /// conversation screen on every mic frame. Only the orb cares about this
  /// number, so only the orb listens to it.
  final ValueNotifier<double> micLevelListenable = ValueNotifier<double>(0);
  double get micLevel => micLevelListenable.value;
  set micLevel(double v) => micLevelListenable.value = v;

  /// HER VOICE'S LOUDNESS, 0..1, asked by the orb's rings on each frame
  /// while she speaks (2026-09-25: "only the speaker should move forward
  /// and backwards"): the reply audio's own level at the moment it is
  /// heard; with none of hers playing here, the level the engine holds.
  double speakerLevelNow() {
    if (_player.playing) return _player.levelNow();
    return phase == AssistantPhase.speaking ? micLevel : 0;
  }

  /// True once the reply being spoken has all been generated: its words
  /// are all here, though the speaker may still be playing them. The
  /// captions use it to land the last word with the last of the voice.
  bool replyComplete = false;

  /// How much of her reply, as received so far, is still to be heard.
  Duration get speakingRemaining =>
      _player.playing ? _player.remaining : Duration.zero;

  /// Interim transcript while the user is still speaking (device-side).
  String partial = '';

  /// True while the HOME orb is running the conversation inline (no
  /// conversation screen). Captions are always produced in this mode —
  /// they are the only visual feedback the user gets.
  bool inlineVoice = false;

  /// Starts the inline conversation from the Home orb.
  Future<void> beginInlineConversation({String? name}) async {
    // A second tap while a start is still running must not stack another
    // one on top of it.
    if (_starting) {
      AppLog.add('orb', 'start already in progress — ignoring tap');
      return;
    }
    _starting = true;
    unawaited(ListeningChime.warm()); // decoded before it is needed
    // THE FAST VOICE CONNECTS WHILE THE HELLO PLAYS (2026-09-30): the
    // instruction, the tools and the Live session are ready by the time
    // the microphone opens.
    if (_liveWanted) unawaited(_live.warm().catchError((Object _) => false));
    inlineVoice = true;
    notifyListeners();
    // GREET ON THE TAP, NEVER ON APP OPEN (his two calls, 2026-09-20: no
    // greeting when the app opens; "I click on that mic orb, it should
    // greet"). Spoken on the DEVICE from a cached recording of the
    // assistant's own voice — instant, no model, no round trip.
    final now = DateTime.now();
    if (_liveWanted && now.difference(_lastGreetedAt) >= _greetCooldown) {
      // ON THE FAST VOICE SHE SAYS IT HERSELF, in the voice she answers in,
      // once her session is up (_greetOnLive) — with the missed calls in
      // it. The recording below is for the classic voice only.
      _lastGreetedAt = now;
      _openingDue = true;
    } else if (now.difference(_lastGreetedAt) >= _greetCooldown &&
        MissedCallsService.instance.hasUnmentioned) {
      // CALLS WERE MISSED: the greeting is the one that mentions them,
      // said once the conversation is up. The cached hello as well would
      // say hello twice.
      _lastGreetedAt = now;
      _helloInMention = true;
    } else if (now.difference(_lastGreetedAt) >= _greetCooldown) {
      _lastGreetedAt = now;
      final hello = orbGreeting(
        name: name ?? greetingName ?? AuthService.instance.user?.name,
        gender: AuthService.instance.user?.gender,
      );
      // The microphone opens only once this has played: it comes out of
      // the same loudspeaker, and heard, it would be the owner's first
      // words.
      _greeting = _sayGreeting(hello);
    }
    _startCancelled = false;
    try {
      // HARD CEILING: a wedged plugin must never hang the tap.
      await beginConversation(name: name).timeout(
        const Duration(seconds: 20),
        onTimeout: () => AppLog.add('orb', 'start timed out after 20s'),
      );
    } catch (e) {
      AppLog.add('orb', 'start failed: $e');
    } finally {
      _starting = false;
      _greeting = null;
    }
    // STOPPED WHILE CONNECTING (client, 1 Oct: "I have to tap twice, it
    // looks stuck"). The tap that stopped it landed mid-connect; the
    // session that finished connecting afterwards must not come back up.
    if (_startCancelled) {
      _startCancelled = false;
      AppLog.add('orb', 'start cancelled by a tap');
      await leaveConversation(chime: false);
      return;
    }
    // Nothing came up: the tap achieved nothing. Reset so the orb is
    // honestly idle and the next tap is a clean attempt, and say so.
    if (!_voiceOn) {
      inlineVoice = false;
      await _stopVoice();
      _setPhase(AssistantPhase.idle, silent: true);
      notifyListeners();
      AppLog.add('orb', 'start produced no session');
      AppFeedback.toast("Couldn't start the conversation — tap again.");
    }
  }

  /// The orb's hello, in the assistant's own (cached) voice. An uncached
  /// greeting is SILENT rather than spoken in another voice.
  Future<void> _sayGreeting(String hello) async {
    try {
      if (await GreetingVoice.instance.play(hello)) {
        replyComplete = true;
        _captionLine('hari', hello);
      }
    } catch (_) {/* a greeting that fails is simply silent */}
  }

  /// The orb's hello while it is being started (the mic waits for it).
  Future<void>? _greeting;

  /// True while a start is running, so taps cannot pile up.
  bool _starting = false;

  /// The caption overlay reads this to appear the INSTANT the orb is
  /// tapped — a connecting orb on a dimmed page beats a frozen screen.
  bool get starting => _starting;

  /// Holds the session on "Connecting…" for a test (the voice screen's
  /// still, idle orb).
  @visibleForTesting
  set debugStarting(bool v) => _starting = v;

  /// A stop that arrived while [beginInlineConversation] was connecting.
  bool _startCancelled = false;

  /// Tap-again on the orb: full clean shutdown — at ANY point, including
  /// mid-connect (the start sees [_startCancelled] and stands down).
  Future<void> endInlineConversation() async {
    if (_starting) _startCancelled = true;
    inlineVoice = false;
    await leaveConversation();
  }

  final List<TranscriptEntry> transcript = [];
  final List<ToolActivity> activities = [];

  String? searchQuery;
  List<SearchResult> searchResults = const [];

  /// Google's search suggestions for a grounded answer, shown as chips
  /// beside its sources (the grounding terms require them).
  List<SearchSuggestion> searchSuggestions = const [];

  /// Saved documents recalled by this turn ("pull up patient Ramesh's
  /// file") — shown as cards while the reply is spoken.
  List<UserDocument> documentCards = const [];

  /// Shows the duplicate-name contact picker. Set by the app shell; the
  /// callback receives the spoken name, the candidates, and a sink for the
  /// user's tap (null = dismissed).
  void Function(String spokenName, List<ContactMatch> matches,
      void Function(ContactMatch?) onChosen)? onPickContact;

  /// The name the current call lookup is resolving ("Manish").
  String _pendingLookupName = '';

  /// UI hook (registered by HomeShell): present recalled documents as the
  /// full-screen swipe gallery, over whatever screen the user is on.
  bool Function(List<UserDocument> documents)? onShowDocuments;

  /// Interpreter mode ("be my translator") — while true the model
  /// translates what it hears instead of assisting. Never survives the
  /// conversation it was asked in.
  bool translatorActive = false;

  /// Live captions (Settings toggle): the line currently being spoken by
  /// either side, shown at the bottom of the conversation screen. Only
  /// this notifier rebuilds — never the whole screen per fragment.
  final ValueNotifier<CaptionLine?> caption = ValueNotifier(null);

  /// Mirrored from SharedPreferences; when off, nothing is published.
  static bool captionsEnabled = false;
  static const _captionsPrefKey = 'captions_enabled';

  static Future<void> loadCaptionPref() async {
    try {
      final p = await SharedPreferences.getInstance();
      captionsEnabled = p.getBool(_captionsPrefKey) ?? false;
    } catch (_) {}
  }

  static Future<void> setCaptionsEnabled(bool v) async {
    captionsEnabled = v;
    if (!v) instance.caption.value = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_captionsPrefKey, v);
    } catch (_) {}
  }

  /// The whole line [speaker] has said so far this turn (the recogniser and
  /// the brain both hand over everything so far, not just what is new).
  void _captionLine(String speaker, String text) {
    if (!captionsEnabled && !inlineVoice) return;
    // Anything being said, by either side, is activity — the idle-stop
    // clock starts over (a long monologue must never be cut short).
    _armIdleStop(phase);
    var t = text.trim();
    if (t.isEmpty) return;
    // The whole turn, lyrics-style — the bar scrolls, it never elides.
    // A hard cap only guards against a runaway reply.
    if (t.length > 6000) t = t.substring(t.length - 6000);
    caption.value = CaptionLine(speaker, t);
  }

  /// SPEAKER MUTED — the assistant keeps working, it just stops talking.
  ///
  /// His ask, 2026-09-21: "in the top add a btn to mute and unmute when
  /// agent speaks, bcs some will just read the caption". NOT ending the
  /// session and NOT muting the microphone: the conversation continues,
  /// the captions keep arriving, the answer is read rather than heard.
  bool speakerMuted = false;

  void setSpeakerMuted(bool v) {
    if (speakerMuted == v) return;
    speakerMuted = v;
    // Dropped at the player: the clock runs as if she spoke, so the turn
    // opens and closes exactly as it does out loud.
    _player.muted = v || !_foreground;
    if (v) {
      // Whatever is mid-sentence right now stops mid-sentence.
      unawaited(_player.stop());
      unawaited(_bargeMade?.stop());
    }
    AppLog.add('voice', v ? 'speaker muted' : 'speaker unmuted');
    notifyListeners();
  }

  /// SOMETHING TYPED INSTEAD OF SPOKEN, mid-session ("add a beautiful text
  /// bar where user can type and send instead of speaking"): the text box
  /// has focus, so typed means typed — the microphone stops listening
  /// until the keyboard closes.
  bool _typing = false;

  void setTyping(bool on) {
    if (_typing == on) return;
    _typing = on;
    AppLog.add('voice', on ? 'typing: mic paused' : 'typing done: mic back');
    if (on) {
      if (_listening) unawaited(_stopListening());
      _idleStop?.cancel();
      _idleStop = null;
    } else {
      _maybeListen();
      _armIdleStop(phase); // the quiet clock starts only once they stop typing
    }
    // The voice screen says so: "Listening…" while the mic is paused was
    // the screen contradicting what was happening (2026-09-24, s5.png).
    notifyListeners();
  }

  /// The microphone is paused because the user is typing.
  bool get micPausedForTyping => _typing;

  /// A message typed in the conversation: its own turn (a chat turn — the
  /// server never lets the model stay silent on typed words), answered out
  /// loud while the conversation is running.
  Future<void> sendTypedMessage(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    await _runTurn(t, mode: BrainMode.chat, speak: _voiceOn || inlineVoice);
  }

  void _clearCaption() => caption.value = null;

  /// What the assistant is doing RIGHT NOW ("Searching the web…") — a
  /// small chip on the conversation screen, so background work never
  /// reads as the app hanging. Null = nothing running.
  /// THE DAY'S COMMITMENTS, held for the panel. Same reasoning as the
  /// headlines: a list read aloud tells the user nothing they can act on,
  /// so the voice gives the count and the next one or two while the whole
  /// day sits on screen.
  List<ScheduleItem> scheduleItems = const [];
  String scheduleDay = '';

  /// Sources that could not be read. A failed calendar is NOT an empty
  /// calendar, and the panel says so rather than looking complete.
  List<String> scheduleFailed = const [];

  void clearSchedule() {
    if (scheduleItems.isEmpty) return;
    scheduleItems = const [];
    scheduleDay = '';
    scheduleFailed = const [];
    notifyListeners();
  }

  /// TODAY'S HEADLINES, held for the panel. Ten of them read aloud takes
  /// over a minute and nobody remembers the fourth, so the list lives on
  /// screen and the voice covers only the top few.
  List<NewsItem> newsItems = const [];
  String newsTopic = '';

  /// read_news_story's news_focus (build 111): the story being read comes
  /// to the front of the deck. A new request object every time, so asking
  /// for the same story twice still moves the deck.
  final ValueNotifier<NewsFocusRequest?> newsFocus = ValueNotifier(null);

  // The deck closed last, so "read me the second one" can bring it back.
  List<NewsItem> _closedNews = const [];
  String _closedNewsTopic = '';

  void clearNews() {
    if (newsItems.isEmpty) return;
    _closedNews = newsItems;
    _closedNewsTopic = newsTopic;
    newsItems = const [];
    newsTopic = '';
    notifyListeners();
  }

  /// Fresh stories for the deck from its own Refresh — no turn, no voice.
  void showNews(List<NewsItem> items, {String topic = ''}) {
    newsItems = items;
    newsTopic = topic;
    notifyListeners();
  }

  /// One device action through the dispatcher, as the brain hands it over.
  @visibleForTesting
  void debugEvent(Map<String, dynamic> e) => unawaited(_onEvent(e));

  final ValueNotifier<String?> activityLabel = ValueNotifier(null);

  /// The status line's words for the phase: while a tool runs
  /// (RESPONDING) the tool's own ("Checking your calendar…").
  String get phaseLabel => phase == AssistantPhase.responding
      ? (activityLabel.value ?? phase.label)
      : phase.label;

  /// Friendly present-tense labels per tool; anything unknown says
  /// "Working on it…" rather than leaking an internal tool name.
  static String _labelForTool(String tool) {
    if (tool.startsWith('web_search') || tool.startsWith('search_')) {
      return 'Searching…';
    }
    if (tool.contains('calendar') || tool.contains('event')) {
      return 'Checking your calendar…';
    }
    if (tool.startsWith('find_') || tool.startsWith('list_')) {
      return 'Looking that up…';
    }
    if (tool.startsWith('remember_') || tool.startsWith('update_')) {
      return 'Saving…';
    }
    return switch (tool) {
      'create_reminder' => 'Saving the reminder…',
      'schedule_task' => 'Scheduling…',
      'cancel_scheduled_task' => 'Cancelling…',
      'send_agent_message' => 'Sending the message…',
      'lookup_person' || 'recall_memory' => 'Checking what I know…',
      'get_last_document' || 'associate_document' => 'Fetching the document…',
      'daily_brief' => 'Fetching your day…',
      'get_weather' => 'Checking the weather…',
      'place_phone_call' => 'Setting up the call…',
      'capture_document' => 'Opening the camera…',
      'generate_image' || 'generate_video' => 'Creating it…',
      // A multi-step plan runs several tools behind this one label, so it
      // says so — 'Working on it…' for twenty seconds reads as a hang.
      'start_task' => 'Working through the steps…',
      'translator_mode' => 'Switching modes…',
      'set_morning_brief' => 'Updating your brief…',
      'read_news_story' => 'Reading the story…',
      'plan_my_day' => 'Planning your day…',
      'complete_priority' || 'check_habit' => 'Ticking it off…',
      'add_habit' => 'Adding the habit…',
      'start_focus' => 'Starting your focus…',
      'momentum_status' => 'Checking your progress…',
      _ => 'Working on it…',
    };
  }

  /// AI creation just generated for the user ("draw me a poster") — the
  /// backend saved it as a document and sent its JSON along; shown as a
  /// large card until the next turn starts.
  UserDocument? generatedImage;
  String generatedImagePrompt = '';

  /// A written piece Hari just composed (present_text) — a speech, email
  /// draft, decision breakdown — shown in a reader card until next turn.
  String? presentedTitle;
  String? presentedText;

  ContactMatch? foundContact;
  List<ContactMatch> ambiguousContacts = const [];
  PendingConfirmation? pendingConfirmation;

  /// An event read off a picture the user picked (look_at_screenshot):
  /// offered as one tap — a reminder, or the phone's calendar. The server
  /// always resolved it ("this Sunday" → a date); nothing here read it
  /// (2026-09-27). Like a confirmation it waits for the user, so a new
  /// answer does not retire it — a tap, the ✕ or a new turn does.
  VisionAction? seenEvent;

  /// The call card. Stamped on every change, so a call the server stopped
  /// reporting on cannot hold a session open forever ([callStillRunning]).
  CallStatusInfo? get callStatus => _callStatus;
  set callStatus(CallStatusInfo? v) {
    _callStatus = v;
    _callStatusAt = DateTime.now();
  }

  CallStatusInfo? _callStatus;
  DateTime _callStatusAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The server gives a call to a business or a meeting contact 180 s to
  /// finish, and reports only CHANGES of state — a long "Speaking with
  /// them" sends nothing for minutes. Past this with no word, it is over.
  static const _callStatusCap = Duration(minutes: 4);

  /// Is a call the assistant placed still under way? Ringing, speaking
  /// with them, getting the answer — anything short of an end state, and
  /// heard of within [_callStatusCap].
  static bool callStillRunning(
          CallStatusInfo? s, DateTime changedAt, DateTime now) =>
      s != null && !s.done && now.difference(changedAt) < _callStatusCap;

  bool get micBusy => phase == AssistantPhase.listening;

  /// Set by HomeShell: opens the conversation screen (same navigation as
  /// tapping the mic) and returns true, or returns false when it is
  /// already on screen. A tapped message notification uses this so the
  /// assistant POPS UP, delivers the message through the live session,
  /// and is already listening for the reply — instead of narrating over
  /// whatever screen happened to be open.
  bool Function()? onOpenConversation;
  bool requestConversationOpen() {
    try {
      return onOpenConversation?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True while a DEVICE FLOW owns the screen (camera capture, gallery
  /// pick, a signature). The microphone must NOT listen then — it recorded
  /// shutter clicks and camera-app silence, and every empty transcript was
  /// answered with "I couldn't hear that clearly".
  bool _deviceFlowActive = false;

  Timer? _stuckWatchdog;

  // ---------------- HER VOICE ----------------

  /// Bumped to silence a fixed line mid-way (barge-in, leaving, pausing).
  int _sayEpoch = 0;

  /// Says [text] in the assistant's own voice with NO model behind it:
  /// Gemini TTS through the speech engine, into the player. For words that
  /// are fixed — someone's message read out when no conversation is
  /// running, the greeting.
  Future<void> _speakDirect(String text) async {
    final line = text.trim();
    if (line.isEmpty || speakerMuted || !_foreground) {
      // Nothing is said (muted: the caption says it), and the conversation
      // listens on — or a hand-over left it on "Thinking" for good.
      _maybeListen();
      return;
    }
    if (PhoneStateGuard.instance.inCall) return; // never over a phone call
    // Never into an open microphone: it would hear her as the owner.
    if (_listening) await _stopListening();
    final epoch = _sayEpoch;
    try {
      await for (final c in _speech.synthesizeChunks(line)) {
        if (epoch != _sayEpoch) break;
        await _player.play(c.pcm, sampleRate: c.sampleRate);
      }
      if (epoch == _sayEpoch) await _player.drained();
    } catch (e) {
      AppLog.add('voice', 'could not speak a line: $e');
    }
    _maybeListen();
  }

  /// The player started or stopped sounding: the orb follows her voice,
  /// the barge-in microphone listens only while she is audible, and the
  /// conversation listens again once she has finished.
  void _onPlayback() {
    if (_player.playing) {
      if (phase != AssistantPhase.speaking) {
        _setPhase(AssistantPhase.speaking, silent: true);
      }
      // The fast voice watches for barge-in on its own microphone.
      if (_voiceOn && _bargeWatchOn && !speakerMuted && _foreground && !_liveMode) {
        unawaited(_barge.start(_onBargeIn));
      }
    } else {
      micLevel = 0;
      _lastLifeAt = DateTime.now(); // her answer was the last sign of life
      if (_bargeWatchOn) unawaited(_bargeMade?.stop());
      if (phase == AssistantPhase.speaking && !_turnRunning) {
        _setPhase(_voiceOn ? AssistantPhase.listening : AssistantPhase.completed,
            silent: true);
      }
      _maybeListen();
    }
    notifyListeners();
  }

  /// Tools that change what should be ringing on this phone. Anything
  /// here re-arms the local alarms as soon as the tool reports back,
  /// rather than waiting for a throttled brief refresh.
  static bool _remindersTouchedBy(String? tool) => const {
        'create_reminder',
        'update_reminder',
        'set_alarm',
        'schedule_task',
        'cancel_scheduled_task',
        'schedule_patient_recall',
      }.contains(tool ?? '');

  /// A finished turn may have created a reminder or commitment — reflect it
  /// on the Home brief now instead of whenever the 5-minute timer next
  /// fires (users read "restart the app to see it" otherwise). Throttled so
  /// rapid back-and-forth turns don't hammer /brief.
  DateTime _briefRefreshedAt = DateTime.fromMillisecondsSinceEpoch(0);
  void _refreshBriefSoon() {
    final now = DateTime.now();
    // 5s: just enough to collapse a rapid burst of turns into one fetch.
    // The old 20s window meant a freshly created reminder could sit
    // invisible on Home/calendar — "I added it but nothing changed".
    if (now.difference(_briefRefreshedAt) < const Duration(seconds: 5)) {
      return;
    }
    _briefRefreshedAt = now;
    // Small delay so the backend has committed the turn's side effects.
    Future.delayed(const Duration(seconds: 2), () {
      BriefService.instance.refresh(force: true);
    });
  }

  /// A busy phase that lasts 35 s without a new event surfaces a retryable
  /// error instead of a spinner forever. Listening and speaking are not
  /// "stuck": the listener and the player end those themselves.
  void _armWatchdog() {
    _stuckWatchdog?.cancel();
    _stuckWatchdog = null;
    // A Live turn has its own watch (LiveVoice hands a stalled turn to the
    // cascade), and must not be cancelled from here.
    if (_liveTurnRunning) return;
    if (!phase.busy ||
        phase == AssistantPhase.listening ||
        phase == AssistantPhase.speaking) {
      return;
    }
    _stuckWatchdog = Timer(const Duration(seconds: 35), () {
      _stuckWatchdog = null;
      if (phase.busy &&
          phase != AssistantPhase.listening &&
          phase != AssistantPhase.speaking) {
        unawaited(_brainMade?.cancel());
        _setLocalError('That took too long. Please try again.');
      }
    });
  }

  // ---------------- lifecycle ----------------

  bool _started = false;

  /// Stops the engine's standing timer (tests tear the engine down with
  /// this).
  @visibleForTesting
  void cancelReconnect() {
    _locationTicker?.cancel();
    _locationTicker = null;
  }

  /// Skips [start]'s phone-wide side effects (tests).
  @visibleForTesting
  void debugMarkStarted() => _started = true;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    unawaited(loadCaptionPref());
    unawaited(LiveVoicePrefs.load());
    // The saved server override must win the race against the first turn.
    await ApiService.loadServerOverride();
    // INCOMING-CALL GUARD: the instant the phone rings or a call connects,
    // the assistant goes silent and lets go of the microphone.
    PhoneStateGuard.instance.start(
      onCallActive: _onPhoneCallActive,
      onCallEnded: _onPhoneCallEnded,
    );
    // Mirror the address book so "tell mom I'll be late" can be resolved
    // by the server's tools. Never delays the assistant coming up.
    ContactsSyncService.instance.maybeSync();
    // Where the owner is, kept current while the app is on screen, and
    // calls missed while it was closed (the Home card; never a dialog).
    _startLocationTicker();
    unawaited(MissedCallsService.instance.check());
    // The brain's config (models, voice, routing words), ready before the
    // first turn. Deliberately NO listening and NO greeting:
    // the microphone opens only when the owner taps the orb.
    unawaited(brain.prepare().catchError((_) {}));
  }

  /// The owner opened the conversation — THIS is the moment the assistant
  /// may speak and the microphone may open.
  Future<void> beginConversation({String? name}) async {
    if (name != null && name.isNotEmpty) greetingName = name;
    _conversationOpen = true;
    // Any way into the conversation warms the fast voice (the orb's tap
    // already has: one connection either way).
    if (_liveWanted) unawaited(_live.warm().catchError((Object _) => false));
    // Calls missed since the last look, read while the conversation opens
    // so the greeting can mention them.
    final missedCheck = MissedCallsService.instance.check(force: true);
    _missedCheck = missedCheck;
    await start();
    if (!await _startVoice()) return;
    // On the fast voice the greeting carries the calls (_greetOnLive).
    if (!_openingDue) unawaited(_mentionMissedCalls(missedCheck));
  }

  /// Set when the orb tap left its hello to the missed-calls mention.
  bool _helloInMention = false;

  /// The tap's greeting is still to be said by the fast voice, once its
  /// session is up (_greetOnLive), or by the classic one if it is not.
  bool _openingDue = false;
  Future<void>? _missedCheck;

  /// Connects the fast voice before the orb is tapped (the app coming to
  /// the front), so the tap listens at once instead of ~4 s later
  /// (measured on the owner's phone, 2026-09-30). A session nobody uses
  /// closes itself ([AiLive.idleCloseSec]).
  void prewarmVoice() {
    if (_voiceOn || !_liveWanted) return;
    unawaited(_live.warm().catchError((Object _) => false));
  }

  /// HER HELLO ON THE FAST VOICE: said by Live itself, in the voice she
  /// answers in, the moment her session and the microphone are up — the
  /// missed calls in it when there are any.
  Future<void> _greetOnLive(int epoch) async {
    try {
      await (_missedCheck ?? Future<void>.value()).timeout(const Duration(seconds: 1));
    } catch (_) {}
    if (epoch != _voiceEpoch || !_foreground || PhoneStateGuard.instance.inCall) return;
    final svc = MissedCallsService.instance;
    final calls = svc.unmentioned;
    final u = AuthService.instance.user;
    final line = svc.takeMention(
          honorific: honorific(gender: u?.gender),
          hello: true,
        ) ??
        orbGreeting(name: greetingName ?? u?.name, gender: u?.gender);
    final back = [
      for (final g in CallHistory.group(calls).take(CallHistory.maxEntries))
        if (g.latest.dialable.isNotEmpty) '${g.latest.label} (${g.latest.dialable})',
    ];
    final said = _live.greet('[SYSTEM] I just opened the conversation. Greet me '
        'now with exactly this, nothing before or after it: "$line" Then stop '
        'and wait for me. BUT if I have already said something by the time you '
        'answer, skip the greeting completely and answer what I said.'
        '${back.isEmpty ? '' : ' If I ask to call someone back, use '
            'place_phone_call with the name or number: ${back.join('; ')}.'}');
    if (!said) AppLog.add('voice', 'hello skipped: he was already talking');
  }

  /// The classic voice's greeting, when the fast voice could not start.
  Future<void> _greetOnCascade() async {
    if (MissedCallsService.instance.hasUnmentioned) {
      _helloInMention = true;
      await _mentionMissedCalls(_missedCheck ?? Future<void>.value());
      return;
    }
    final u = AuthService.instance.user;
    await _sayGreeting(orbGreeting(name: greetingName ?? u?.name, gender: u?.gender));
  }

  /// THE GREETING MENTIONS MISSED CALLS, ONCE.
  ///
  /// Owner, 2026-09-24: "it should report when we have any missed calls".
  /// Said by the assistant itself, so the calls are in the conversation —
  /// "call him back" then just works — and never repeated for calls
  /// already mentioned (MissedCallsService.takeMention).
  Future<void> _mentionMissedCalls(Future<void> check) async {
    try {
      await check.timeout(const Duration(seconds: 3));
    } catch (_) {}
    final hello = _helloInMention;
    _helloInMention = false;
    if (!_conversationOpen || PhoneStateGuard.instance.inCall) return;
    final svc = MissedCallsService.instance;
    final calls = svc.unmentioned;
    final line = svc.takeMention(
      honorific: honorific(gender: AuthService.instance.user?.gender),
      hello: hello,
    );
    // Nothing new after all (called back meanwhile): the conversation
    // simply opens listening, as it always does.
    if (line == null) return;
    AppLog.add('calls', 'greeting mentions ${calls.length} missed call(s)');
    final back = [
      for (final g in CallHistory.group(calls).take(CallHistory.maxEntries))
        if (g.latest.dialable.isNotEmpty)
          '${g.latest.label} (${g.latest.dialable})',
    ];
    await _tellModel('[SYSTEM] Say exactly this to me now, nothing before or '
        'after it: "$line" If I have already asked for something, answer '
        'that first and then say it. Then wait for me.'
        '${back.isEmpty ? '' : ' If I ask to call someone back, use '
            'place_phone_call with the name or number: ${back.join('; ')}.'}');
  }

  /// The Missed calls card's Call back: the owner's tap is the go-ahead,
  /// so it dials straight away and says what really happened.
  Future<void> callBackMissed(CallEntry c) async {
    final phone = c.dialable;
    if (phone.isEmpty) return;
    MissedCallsService.instance.remove(c);
    _localCallVia = 'phone';
    await _dialAndReport(ContactMatch(id: '', name: c.label, phone: phone));
  }

  /// When the greeting was last actually spoken. Opening the mic and
  /// SAYING HELLO are different things, and only one of them should happen
  /// every time the app comes forward.
  DateTime _lastGreetedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Long enough that flicking to another app and back is silent, short
  /// enough that coming back to the app later is still greeted.
  static const _greetCooldown = Duration(minutes: 15);

  /// A call started/rang — a real phone call always wins the audio: the
  /// conversation ends, nothing speaks and nothing listens.
  Future<void> _onPhoneCallActive() async {
    if (_voiceOn || inlineVoice) {
      await leaveConversation(chime: false);
      return;
    }
    _sayEpoch++;
    await _brainMade?.cancel();
    await _player.stop();
    if (phase != AssistantPhase.idle) _setPhase(AssistantPhase.idle, silent: true);
    notifyListeners();
  }

  void _onPhoneCallEnded() {
    // Nothing to resume — the owner taps the orb when they want to talk.
    if (phase != AssistantPhase.idle && !phase.busy) {
      _setPhase(AssistantPhase.idle, silent: true);
    }
  }

  @override
  void dispose() {
    _stuckWatchdog?.cancel();
    super.dispose();
  }

  // ---------------- THE VOICE CONVERSATION ----------------
  // listen (the phone's own recogniser, on-device first, in the owner's
  // language) -> the brain's turn -> her reply, spoken sentence by
  // sentence -> listen again, until the owner ends it (the orb, "bye",
  // end_conversation) or a minute passes with nobody talking. Talking
  // over her, or tapping, stops her at once (barge-in).

  bool _voiceOn = false;

  /// The voice conversation is running — listening, thinking or speaking.
  /// (It used to mean the live socket was open; every screen asks it.)
  bool get liveActive => _voiceOn;

  /// The fast voice is still connecting: nothing said now is heard
  /// (2026-10-02, the owner: "the client is speaking while it is still
  /// connecting — show something until it is ready, then a ping").
  bool get connecting => _voiceOn && _liveStarting;

  /// Marks a conversation as running without its loop (widget tests that
  /// show the voice screen).
  @visibleForTesting
  set debugVoiceOn(bool on) {
    _voiceOn = on;
    if (on) {
      _listening = true; // the microphone a running conversation has open
      return;
    }
    // Off: any listen still open is over, and its deadline with it.
    _voiceEpoch++;
    _listening = false;
    _listenGuard?.cancel();
    _listenGuard = null;
  }

  /// Bumped whenever the conversation stops, so a listen still finishing
  /// from the one before knows it is stale.
  int _voiceEpoch = 0;
  bool _listening = false;

  /// True while the microphone is actually open for the user's words —
  /// not while the fast voice is still connecting (audit 2026-10-01: the
  /// label said Listening through a 7 s connect with no microphone).
  bool get micOpen =>
      _listening &&
      !_liveStarting &&
      (!_liveMode || (_liveMade?.listening ?? false));
  bool _turnRunning = false;
  int _turnGen = 0;
  int _hearFailures = 0;
  int _turnFailures = 0;

  /// "Bye" or end_conversation: the conversation closes once her last
  /// words have played.
  bool _endAfterTurn = false;

  /// The last sign of life: the owner speaking, or her answering.
  DateTime _lastLifeAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// A minute with nobody talking ends the conversation (owner,
  /// 2026-09-24: "when user don't respond for 1 min (silence) auto close
  /// it").
  static const quietClose = Duration(seconds: 60);

  /// Starts the conversation. False when it cannot (a phone call).
  Future<bool> _startVoice() async {
    if (_voiceOn) return true;
    if (PhoneStateGuard.instance.inCall) return false;
    AppLog.add('voice', 'conversation starts');
    // The model connection gets ready while the owner is still talking.
    unawaited(brain.warmUp());
    _voiceOn = true;
    _audioFocus(true);
    final epoch = ++_voiceEpoch;
    _hearFailures = 0;
    _turnFailures = 0;
    _endAfterTurn = false;
    _lastLifeAt = DateTime.now();
    _clearCaption();
    _resetTurn();
    // Where the owner is, for the turns to come (every turn carries it).
    unawaited(_refreshLocation());
    _setPhase(AssistantPhase.listening, silent: true);
    notifyListeners();
    final hello = _greeting;
    if (hello != null) {
      try {
        await hello.timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    if (epoch != _voiceEpoch) return _voiceOn;
    _chimeOnListen = true;
    _maybeListen();
    return true;
  }

  /// MUSIC PAUSES WHILE WE TALK, and plays again after (2026-09-30). The
  /// microphone used to take the audio focus itself, and paused its capture
  /// for good whenever it lost it (a WhatsApp ping): the client's S24 Ultra
  /// sat on "Listening". The conversation holds it now, and a loss changes
  /// nothing (MainActivity "audioFocus").
  static const _device = MethodChannel('hari/device');
  void _audioFocus(bool on) {
    _device.invokeMethod<bool>('audioFocus', {'on': on}).catchError((Object _) => false);
  }

  /// Lets go of everything the conversation holds: the listener, the turn,
  /// her voice, the barge-in microphone.
  Future<void> _stopVoice() async {
    final was = _voiceOn;
    _voiceOn = false;
    _voiceEpoch++;
    _listening = false;
    _sayEpoch++;
    _notes.clear();
    if (was) {
      AppLog.add('voice', 'conversation ends');
      _audioFocus(false);
    }
    try {
      await _listenerMade?.cancel();
    } catch (_) {}
    try {
      await _brainMade?.cancel();
    } catch (_) {}
    try {
      await _speechMade?.cancel();
    } catch (_) {}
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _bargeMade?.stop();
    } catch (_) {}
    _liveMode = false;
    // A Live turn cut short by the end of the conversation is over too.
    if (_liveTurnRunning) _turnRunning = false;
    _liveTurnRunning = false;
    _liveGaveUp = false; // the next conversation tries the fast voice again
    _openingDue = false;
    _missedCheck = null;
    _liveQuiet?.cancel();
    _liveQuiet = null;
    _listenGuard?.cancel();
    _listenGuard = null;
    _doneTimer?.cancel();
    _doneTimer = null;
    _liveUser = null;
    _liveBubble = null;
    try {
      await _liveMade?.stop();
    } catch (_) {}
    micLevel = 0;
    partial = '';
  }

  /// Listens for the owner's next words — when the conversation is on and
  /// nothing else owns the microphone or the turn.
  void _maybeListen() {
    if (!_voiceOn || _listening || _turnRunning) return;
    if (_typing || _deviceFlowActive || !_foreground) return;
    if (PhoneStateGuard.instance.inCall) return;
    // Never over her voice: _onPlayback comes back here when she is done.
    if (_player.playing) return;
    if (_notes.isNotEmpty) {
      unawaited(_nextNote());
      return;
    }
    if (DateTime.now().difference(_lastLifeAt) >= quietClose && !_sessionWaiting) {
      AppLog.add('voice', 'a minute of quiet — closing the conversation');
      unawaited(_closeAfterQuiet());
      return;
    }
    if (_liveWanted) {
      unawaited(_listenLive(_voiceEpoch));
      return;
    }
    unawaited(_listenOnce(_voiceEpoch));
  }

  /// The first listen of a conversation chimes.
  bool _chimeOnListen = false;

  /// One listen of the phone's recogniser, at most (its own limit is 30 s).
  static const listenDeadline = Duration(seconds: 40);
  Timer? _listenGuard;

  Future<void> _listenOnce(int epoch) async {
    _listening = true;
    partial = '';
    // THE BARGE-IN MICROPHONE LETS GO FIRST (voice audit, 2026-09-30): the
    // recogniser opening while it still held the microphone got nothing.
    try {
      await _bargeMade?.stop();
    } catch (_) {}
    if (epoch != _voiceEpoch || !_listening) return;
    if (_chimeOnListen) {
      _chimeOnListen = false;
      // THE MOMENT IT IS LISTENING (after the hello has played): one chime
      // is the whole signal to start talking (his ask, 2026-09-20) — and
      // never off-screen.
      if (_foreground) unawaited(ListeningChime.play());
    }
    if (phase != AssistantPhase.listening) {
      _setPhase(AssistantPhase.listening, silent: true);
    }
    var heard = '';
    HearError? failed;
    // A recogniser that never reports back must not hold "Listening" for
    // ever: past its own limit (30 s) it is let go, and listening starts
    // again (2026-09-30).
    var lastEvent = DateTime.now();
    var extended = false;
    void onDeadline() {
      if (epoch != _voiceEpoch || !_listening) return;
      // Still reporting (a long dictation, the cloud transcribing it): once
      // more, never for ever.
      if (!extended && DateTime.now().difference(lastEvent) < const Duration(seconds: 15)) {
        extended = true;
        _listenGuard = Timer(listenDeadline, onDeadline);
        return;
      }
      AppLog.add('voice', 'the recogniser never finished: listening again');
      unawaited(_listenerMade?.cancel());
    }

    _listenGuard?.cancel();
    _listenGuard = Timer(listenDeadline, onDeadline);
    try {
      await for (final e in _listener.listen()) {
        if (epoch != _voiceEpoch || !_listening) break;
        lastEvent = DateTime.now();
        switch (e) {
          case HearPartial(:final text):
            partial = text;
            if (text.trim().isNotEmpty) {
              _lastLifeAt = DateTime.now();
              _captionLine('you', text);
            }
            notifyListeners();
          case HearLevel(:final level):
            micLevel = level;
          case HearEndOfSpeech():
            micLevel = 0;
          case HearFinal(:final text, :final audio):
            heard = text.trim();
            if (audio != null) {
              _heardAudio = audio;
              _heardAt = DateTime.now();
            }
          case final HearError err:
            failed = err;
        }
      }
    } catch (_) {
      failed = const HearError('failed');
    } finally {
      _listenGuard?.cancel();
      _listenGuard = null;
    }
    if (epoch != _voiceEpoch) return; // the conversation ended meanwhile
    final wanted = _listening;
    _listening = false;
    micLevel = 0;
    partial = '';
    if (!wanted) return; // stopped on purpose: typing, a note, a camera
    final error = failed;
    if (error != null) return _hearFailed(error);
    _hearFailures = 0;
    if (heard.isEmpty) {
      // Nothing was said: listen again (the quiet minute ends it). A beat
      // first, so a recogniser that answers at once cannot spin.
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (epoch == _voiceEpoch) _maybeListen();
      });
      return;
    }
    _lastLifeAt = DateTime.now();
    await _runTurn(heard, mode: BrainMode.voice);
  }

  /// Stops listening on purpose (what was heard so far is dropped).
  Future<void> _stopListening() async {
    if (!_listening) return;
    _listening = false;
    micLevel = 0;
    partial = '';
    if (_liveMode) {
      // The fast voice lets go of the microphone; its session stays.
      try {
        await _liveMade?.pause();
      } catch (_) {}
      return;
    }
    try {
      await _listenerMade?.cancel();
    } catch (_) {}
  }

  void _hearFailed(HearError e) {
    AppLog.add('voice', 'listening failed: ${e.code}');
    final epoch = _voiceEpoch;
    if (e.code == 'permission') {
      unawaited(_stopVoice());
      _setLocalError('Microphone permission is needed. Enable it in Settings.');
      return;
    }
    _hearFailures++;
    if (e.permanent || _hearFailures >= 3) {
      unawaited(_stopVoice());
      _setLocalError(e.code == 'network'
          ? "I couldn't reach the speech service. Check your connection."
          : "I couldn't hear you just now. Please try again.");
      return;
    }
    // A blip: try again in a moment.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (epoch == _voiceEpoch) _maybeListen();
    });
  }

  /// BARGE-IN: the owner talked over her (the microphone heard it) or
  /// tapped. She stops at once, the turn is dropped, and the conversation
  /// listens — the way a person stops when interrupted.
  Future<void> bargeIn() async {
    if (!_voiceOn && !_turnRunning && !_player.playing) return;
    AppLog.add('voice', 'barge-in');
    _sayEpoch++;
    _lastLifeAt = DateTime.now();
    if (_liveMode) await _liveMade?.interrupt();
    await _bargeMade?.stop();
    await _brainMade?.cancel();
    await _speechMade?.cancel();
    await _player.stop();
    replyComplete = true;
    activityLabel.value = null;
    if (_voiceOn) {
      _setPhase(AssistantPhase.listening, silent: true);
      // The dropped turn clears itself as its stream closes; that, or
      // this, opens the microphone.
      _maybeListen();
    } else if (phase.busy) {
      _setPhase(AssistantPhase.completed, silent: true);
    }
    notifyListeners();
  }

  void _onBargeIn() => unawaited(bargeIn());

  // ---------------- THE FAST VOICE'S TURNS ----------------

  /// The quiet minute, for a Live conversation (its microphone never
  /// stops, so the listening loop's own check never comes round).
  Timer? _liveQuiet;

  /// DONE is shown briefly, then LISTENING.
  Timer? _doneTimer;
  static const liveDoneHold = Duration(milliseconds: 450);

  /// This Live turn's bubbles: the owner's words and her reply, replaced
  /// as they grow.
  TranscriptEntry? _liveUser;
  TranscriptEntry? _liveBubble;

  /// Listens on the fast voice: the session (warmed on the orb tap) and
  /// its microphone. Anything short of ready within LiveTimeouts and the
  /// cascade listens instead, for the rest of this conversation.
  Future<void> _listenLive(int epoch) async {
    _listening = true;
    partial = '';
    final chime = _chimeOnListen;
    _chimeOnListen = false;
    if (phase != AssistantPhase.listening) {
      _setPhase(AssistantPhase.listening, silent: true);
    }
    var ok = false;
    _liveStarting = true;
    notifyListeners(); // "Connecting… wait for the ping" until it is ready
    try {
      ok = await _live.start();
    } catch (e) {
      AppLog.add('voice', 'fast voice failed to start: $e');
    } finally {
      _liveStarting = false;
    }
    if (epoch != _voiceEpoch) return; // the conversation ended meanwhile
    if (!_listening) {
      // Stopped on purpose meanwhile (typing, a note, the camera).
      if (ok) unawaited(_liveMade?.pause());
      return;
    }
    if (!ok) {
      _listening = false;
      _liveMode = false;
      _liveGaveUp = true;
      AppLog.add('voice', 'fast voice unavailable — the classic voice listens');
      if (_openingDue) {
        _openingDue = false;
        await _greetOnCascade();
        if (epoch != _voiceEpoch) return;
      }
      _chimeOnListen = chime;
      _maybeListen();
      return;
    }
    if (!_liveMode) AppLog.add('voice', 'fast voice listening');
    _liveMode = true;
    _armLiveQuiet();
    if (_openingDue) {
      // Her hello is the cue to talk: no chime (it would reach her
      // microphone and could cut the hello short).
      _openingDue = false;
      unawaited(_greetOnLive(epoch));
    } else {
      // Ready: the ping says "speak now" — every time, not only the first.
      _pingListening();
    }
    notifyListeners();
  }

  /// The listening ping, with the fast voice's microphone held silent
  /// while it plays so the ping is never taken for speech.
  void _pingListening() {
    if (!_foreground || !_voiceOn) return;
    _liveMade?.holdMic(const Duration(milliseconds: 700));
    unawaited(ListeningChime.play());
  }

  /// The fast voice's microphone is being opened ([_listenLive]).
  bool _liveStarting = false;

  void _armLiveQuiet() {
    _liveQuiet?.cancel();
    _liveQuiet = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_liveMode || !_voiceOn) {
        _liveQuiet?.cancel();
        _liveQuiet = null;
        return;
      }
      // LISTENING MEANS AN OPEN MICROPHONE (the client's S24 Ultra stuck on
      // "Listening", 2026-09-30): the conversation believes the fast voice
      // listens, but its microphone is closed and nothing is opening it.
      if (_listening &&
          _liveWanted &&
          !_liveStarting &&
          !(_liveMade?.listening ?? false) &&
          !_turnRunning &&
          !_player.playing &&
          _foreground &&
          !_typing &&
          !_deviceFlowActive) {
        AppLog.add('voice', 'listening with no microphone: opening it again');
        _listening = false;
        _maybeListen();
        return;
      }
      if (_turnRunning || _player.playing || (_liveMade?.turnOpen ?? false)) return;
      if (_sessionWaiting || _notes.isNotEmpty) return;
      if (DateTime.now().difference(_lastLifeAt) >= quietClose) {
        AppLog.add('voice', 'a minute of quiet — closing the conversation');
        _liveQuiet?.cancel();
        _liveQuiet = null;
        unawaited(_closeAfterQuiet());
      }
    });
  }

  /// A Live turn is running (from THINKING until DONE).
  bool _liveTurnRunning = false;

  /// A Live turn is under way from here (THINKING or later).
  void _liveTurnBegins() {
    if (_liveTurnRunning) return;
    _liveTurnRunning = true;
    _turnRunning = true;
    replyComplete = false;
    errorMessage = null;
  }

  /// The owner's words on the fast voice, as they are heard.
  void _liveHeard(String text) {
    _lastLifeAt = DateTime.now();
    if (text.isEmpty) return;
    partial = text;
    if (_liveUser == null) {
      // A NEW QUESTION RETIRES THE LAST ANSWER'S CARDS, as a cascade turn
      // does.
      _clearAnswerCards();
      pendingConfirmation = null;
      _maybeAskLocationFor(text);
    }
    final entry = TranscriptEntry(TranscriptRole.user, text);
    final i = _liveUser == null ? -1 : transcript.lastIndexOf(_liveUser!);
    if (i >= 0) {
      transcript[i] = entry;
    } else {
      transcript.add(entry);
    }
    _liveUser = entry;
    _captionLine('you', text);
  }

  /// Everything the fast voice reports.
  void _onLive(LiveEvent e) {
    if (!_voiceOn || !_liveMode) {
      // A device action is always answered, or its tool waits 30 s.
      if (e case LiveBrain(event: BrainDeviceAction(:final respond))) {
        respond(const DeviceOutcome.failed('The conversation had ended.'));
      }
      return;
    }
    switch (e) {
      case LiveHeard(:final text):
        _liveHeard(text);
      case LiveThinking():
        _liveTurnBegins();
        _setPhase(AssistantPhase.thinking, silent: true);
      case LiveBrain(:final event):
        _liveTurnBegins();
        switch (event) {
          case BrainToolCall(:final name):
            _toolStarted(name);
            _setPhase(AssistantPhase.responding, silent: true);
          case BrainDeviceAction(:final tool, :final action, :final respond):
            unawaited(_performForBrain(tool, action, respond));
          case BrainNeedsConfirmation(:final tool, :final summary):
            pendingConfirmation = PendingConfirmation(
              action: tool,
              question: summary.trim().isEmpty ? null : summary.trim(),
            );
            HapticFeedback.mediumImpact();
          default:
            break;
        }
      case LiveSpeaking():
        _liveTurnBegins();
        _finishTools();
        // GPT-Live's voice plays on the call, not our player: her words
        // are what turn the orb to speaking.
        if (phase != AssistantPhase.speaking) _setPhase(AssistantPhase.speaking, silent: true);
      case LiveSaid(:final text):
        _lastLifeAt = DateTime.now();
        _liveTurnBegins();
        _finishTools();
        _captionLine('hari', text);
        _liveBubble = _liveReply(_liveBubble, text);
      case LiveInterrupted():
        _lastLifeAt = DateTime.now();
        replyComplete = true;
        activityLabel.value = null;
        _setPhase(AssistantPhase.listening, silent: true);
      case LiveTurnDone(:final user, :final reply, :final interrupted, :final opening):
        // Her hello goes straight to listening (no DONE flash).
        _onLiveTurnDone(user, reply, interrupted || opening);
      case LiveCorrected(:final text):
        final b = _liveBubble;
        final i = b == null ? -1 : transcript.lastIndexOf(b);
        if (i >= 0) {
          transcript[i] = TranscriptEntry(TranscriptRole.assistant, text);
        } else if (transcript.isNotEmpty &&
            transcript.last.role == TranscriptRole.assistant) {
          transcript[transcript.length - 1] =
              TranscriptEntry(TranscriptRole.assistant, text);
        }
        _captionLine('hari', text);
      case LiveFallback():
        _onLiveFallback(e);
    }
    notifyListeners();
  }

  /// A Live turn is over and its last sound heard: DONE, briefly, then
  /// LISTENING (or the goodbye closes the conversation).
  void _onLiveTurnDone(String user, String reply, bool interrupted) {
    _lastLifeAt = DateTime.now();
    // Only a Live turn's own flag: a cascade turn running meanwhile (typed,
    // a note) keeps its own.
    if (_liveTurnRunning) _turnRunning = false;
    _liveTurnRunning = false;
    _finishTools();
    activityLabel.value = null;
    replyComplete = true;
    partial = '';
    if (user.isNotEmpty) _liveHeard(user);
    if (reply.isNotEmpty) {
      connected = true;
      _turnFailures = 0;
      if (!interrupted) {
        _liveBubble = _liveReply(_liveBubble, reply);
        _captionLine('hari', reply);
      }
      _refreshBriefSoon();
    }
    if (user.isNotEmpty && isFarewell(user)) _endAfterTurn = true;
    _liveUser = null;
    _liveBubble = null;
    if (_endAfterTurn) {
      _endAfterTurn = false;
      unawaited(_endWhenQuiet());
      return;
    }
    _doneTimer?.cancel();
    if (interrupted || (user.isEmpty && reply.isEmpty)) {
      if (phase != AssistantPhase.listening) {
        _setPhase(AssistantPhase.listening, silent: true);
        _pingListening();
      }
    } else {
      _setPhase(AssistantPhase.completed, silent: true);
      _doneTimer = Timer(liveDoneHold, () {
        _doneTimer = null;
        if (_voiceOn && phase == AssistantPhase.completed) {
          _setPhase(AssistantPhase.listening, silent: true);
          // Her reply is over: the ping says it is their turn (no voice
          // interruption since 2026-10-02, so they wait for it).
          _pingListening();
        }
      });
    }
    // Notes that waited for this turn (a camera's reading, a message).
    unawaited(_nextNote());
    _maybeListen();
  }

  /// Words that stop mid-thought: no sentence end, and ending on a word
  /// that needs another ("the", "about", "Dr.", "is", "to", "and").
  /// "What?", "Stop" and "Call Amma" are finished.
  @visibleForTesting
  static bool looksUnfinished(String words) {
    final w = words.trim();
    if (w.isEmpty) return true;
    final toks = w.split(RegExp(r'\s+'));
    final last = toks.last.toLowerCase().replaceAll(RegExp(r'[.,;:\-–]+$'), '');
    // "Dr." / "Mr." end nothing: the name is still to come.
    const titles = {'dr', 'mr', 'mrs', 'ms', 'prof', 'st'};
    if (titles.contains(last)) return true;
    if (RegExp(r'[.!?।]$').hasMatch(w)) return false;
    // Words that need another after them. Short openers ("He is", "What
    // is") hang on an auxiliary; a longer sentence ending on one ("tell
    // me what time it is") is whole.
    const auxiliaries = {'is', 'are', 'was', 'were', 'can', 'could', 'would', 'should', 'will'};
    if (auxiliaries.contains(last)) return toks.length <= 3;
    const hanging = {
      'the', 'a', 'an', 'about', 'to', 'of', 'for', 'and', 'or', 'but',
      'with', 'from', 'into', 'onto', 'than', 'as', 'if', 'my', 'his', 'her',
      'their', 'our', 'your',
    };
    return hanging.contains(last);
  }

  /// Live could not answer: the cascade does — the owner is never left
  /// without an answer, and nothing a tool did is done twice.
  // The classic voice's recorded turn, waiting for the server to name
  // the turn (record mode; see _uploadHeard).
  RecordedAudio? _heardAudio;
  DateTime? _heardAt;

  /// Sends the recorded turn for review under the server's turn id (the
  /// admin page matches audio to turns by it). Nothing on the hot path.
  void _uploadHeard(String? turnId) {
    final a = _heardAudio;
    final at = _heardAt;
    _heardAudio = null;
    _heardAt = null;
    if (a == null || turnId == null || turnId.isEmpty) return;
    unawaited(TurnAudioUploader.sendUser(turnId, at ?? DateTime.now(), a));
  }

  void _onLiveFallback(LiveFallback f) {
    AppLog.add('voice',
        'fast voice: ${f.reason}${f.keepLive ? '' : ' — the classic voice from here'}');
    // The server keeps the reason (2026-10-01: "why did Live drop for the
    // client?" could only be answered from the phone's own log).
    unawaited(ApiService.postJson('/ai/live-fallback',
        {'reason': f.reason, 'keep_live': f.keepLive, 'build': ApiService.appBuild}));
    final liveTurn = _liveTurnRunning;
    _liveTurnRunning = false;
    if (liveTurn) {
      _turnRunning = false;
      _finishTools();
      activityLabel.value = null;
    }
    partial = '';
    final shown = _liveUser;
    _liveUser = null;
    _liveBubble = null;
    Future<void> micFree = Future.value();
    if (!f.keepLive) {
      _liveMode = false;
      _liveGaveUp = true;
      _listening = false;
      _liveQuiet?.cancel();
      _liveQuiet = null;
      // Its microphone lets go before the phone's recogniser opens: one
      // capture at a time, or the recogniser hears silence (2026-09-30).
      // WAITED FOR below (2026-10-01): the stop can take up to 3 s, and
      // a recogniser opened meanwhile heard nothing.
      micFree = (_liveMade?.stop() ?? Future<void>.value())
          .timeout(const Duration(seconds: 4))
          .catchError((Object _) {});
    }
    final words = f.words;
    final line = f.line;
    if (words != null && words.isNotEmpty && f.keepLive && _live.fragmentGuard &&
        looksUnfinished(words)) {
      // HALF A SENTENCE IS NOT A QUESTION (client's phone, 2026-10-01):
      // "Tell me the", "Can you tell me about Dr.", "He is" reached the
      // cascade while he was still talking, and two answers came back.
      // Live stays open and hears the rest; the cascade keeps quiet.
      AppLog.add('voice', 'fast voice: "$words" is unfinished — waiting for the rest');
      if (shown != null) transcript.remove(shown);
      if (!_turnRunning) {
        replyComplete = true;
        if (_voiceOn && phase != AssistantPhase.listening) {
          _setPhase(AssistantPhase.listening, silent: true);
        }
        final epoch = _voiceEpoch;
        unawaited(micFree.whenComplete(() {
          if (epoch == _voiceEpoch) _maybeListen();
        }));
      }
      return;
    }
    if (words != null && words.isNotEmpty) {
      // Its bubble is the cascade turn's own now.
      if (shown != null) transcript.remove(shown);
      unawaited(_runTurn(words, mode: BrainMode.voice));
      return;
    }
    if (line != null && line.isNotEmpty) {
      transcript.add(TranscriptEntry(TranscriptRole.assistant, line));
      _captionLine('hari', line);
      replyComplete = true;
      unawaited(_speakDirect(line));
      return;
    }
    // A cascade turn still running (typed, a note) listens when it ends.
    if (_turnRunning) return;
    replyComplete = true;
    if (_endAfterTurn) {
      // end_conversation, or a goodbye, on a turn that ended this way.
      _endAfterTurn = false;
      unawaited(_endWhenQuiet());
      return;
    }
    if (_voiceOn && phase != AssistantPhase.listening) {
      _setPhase(AssistantPhase.listening, silent: true);
    }
    final epoch = _voiceEpoch;
    unawaited(micFree.whenComplete(() {
      if (epoch == _voiceEpoch) _maybeListen();
    }));
  }

  // ---------------- ONE TURN ----------------

  /// ONE BRAIN TURN, end to end, for every way in: the owner's words
  /// (spoken or typed), a panel's button, the app's own [SYSTEM] note, a
  /// photo. [speak] says the reply aloud (default: in voice mode).
  /// [fromOwner] false: the words are not shown as the owner's.
  Future<void> _runTurn(
    String text, {
    BrainMode mode = BrainMode.voice,
    bool? speak,
    AiAttachment? image,
    bool untrusted = false,
    bool shared = false,
    bool fromOwner = true,
  }) async {
    final words = text.trim();
    if (words.isEmpty && image == null) return;
    // Something typed while she answers on the fast voice: she stops.
    if (_liveMode && fromOwner) await _liveMade?.interrupt();
    if (_listening) await _stopListening();
    _sayEpoch++;
    final gen = ++_turnGen;
    _turnRunning = true;
    _lastLifeAt = DateTime.now();
    errorMessage = null;
    replyComplete = false;
    if (fromOwner) {
      // A NEW QUESTION RETIRES THE LAST ANSWER'S CARDS (and answers, or
      // moves on from, a question still on screen). The news and schedule
      // panels stay: the owner dismisses those.
      _clearAnswerCards();
      pendingConfirmation = null;
      transcript.add(TranscriptEntry(TranscriptRole.user, words));
      _captionLine('you', words);
      _maybeAskLocationFor(words);
      // A goodbye closes the conversation: she still answers this turn (so
      // she can say goodbye back), but the microphone does not reopen.
      if (isFarewell(words)) _endAfterTurn = true;
    }
    _setPhase(AssistantPhase.thinking, silent: true);
    // THE BARGE-IN MICROPHONE OPENS NOW, NOT WHEN SHE STARTS (voice audit,
    // 2026-09-30): while she is silent it learns the room's noise floor,
    // which it never did when it only ran while she spoke.
    if ((speak ?? mode == BrainMode.voice) &&
        _voiceOn &&
        _bargeWatchOn &&
        !speakerMuted &&
        _foreground &&
        !_liveMode) {
      unawaited(_barge.start(_onBargeIn));
    }
    TranscriptEntry? live;
    try {
      final events = brain.turn(
        text: words,
        mode: mode,
        image: image,
        untrusted: untrusted,
        shared: shared,
        speak: speak ?? mode == BrainMode.voice,
      );
      await for (final e in events) {
        if (gen != _turnGen) break;
        switch (e) {
          case BrainRouteChosen(:final route, :final reason):
            AppLog.add('brain', '${route.name} ($reason)');
          case BrainPartialText(:final text):
            _finishTools();
            if (phase == AssistantPhase.responding) {
              _setPhase(AssistantPhase.thinking, silent: true);
            }
            _captionLine('hari', text);
            live = _liveReply(live, text);
          case BrainToolCall(:final name):
            _toolStarted(name);
            if (phase != AssistantPhase.speaking) {
              _setPhase(AssistantPhase.responding, silent: true);
            }
          case BrainDeviceAction(:final tool, :final action, :final respond):
            unawaited(_performForBrain(tool, action, respond));
          case BrainNeedsConfirmation(:final tool, :final summary):
            // The reply asks "…?"; the owner's yes — spoken, typed or this
            // card's button — carries the approval on the next turn.
            pendingConfirmation = PendingConfirmation(
              action: tool,
              question: summary.trim().isEmpty ? null : summary.trim(),
            );
            HapticFeedback.mediumImpact();
          case final BrainFinalText fin:
            _uploadHeard(fin.turnId);
            _finishTools();
            live = _onFinal(fin, words, live);
          case BrainSpokenAudio():
            // Already queued on the player; the orb follows the player.
            break;
          case BrainError(:final code, :final message, :final fatal):
            _onBrainError(code, message, fatal);
        }
        _armWatchdog();
        notifyListeners();
      }
    } catch (e) {
      AppLog.add('brain', 'turn failed: $e');
    } finally {
      if (gen == _turnGen) {
        _turnRunning = false;
        _finishTools();
        activityLabel.value = null;
        replyComplete = true;
        _afterTurn();
      }
    }
  }

  /// The assistant's bubble being written, replaced as the reply grows.
  TranscriptEntry _liveReply(TranscriptEntry? live, String text) {
    final entry = TranscriptEntry(TranscriptRole.assistant, text);
    final i = live == null ? -1 : transcript.lastIndexOf(live);
    if (i >= 0) {
      transcript[i] = entry;
    } else {
      transcript.add(entry);
    }
    return entry;
  }

  TranscriptEntry? _onFinal(BrainFinalText e, String asked, TranscriptEntry? live) {
    connected = true;
    _turnFailures = 0;
    final text = e.text.trim();
    if (text.isEmpty) {
      // The model chose to stay silent (the words were not for it):
      // nothing shown, nothing said.
      if (live != null) transcript.remove(live);
      if (caption.value?.speaker == 'hari') caption.value = null;
      return null;
    }
    _captionLine('hari', text);
    // A Google-Search-grounded answer shows the pages it used and Google's
    // search suggestions beside it (the grounding terms require both).
    if (e.sources.isNotEmpty || (e.searchSuggestionsHtml ?? '').isNotEmpty) {
      searchQuery = asked;
      searchResults = [
        for (final s in e.sources.take(5))
          SearchResult(
            title: (s.title ?? '').trim().isEmpty ? _host(s.uri) : s.title!.trim(),
            url: s.uri,
            snippet: '',
            source: (s.title ?? '').trim().isEmpty ? '' : s.title!.trim(),
          ),
      ];
      searchSuggestions = parseSearchSuggestions(e.searchSuggestionsHtml);
    }
    _refreshBriefSoon();
    return _liveReply(live, text);
  }

  static String _host(String url) {
    try {
      final h = Uri.parse(url).host;
      return h.startsWith('www.') ? h.substring(4) : h;
    } catch (_) {
      return url;
    }
  }

  void _onBrainError(String code, String message, bool fatal) {
    AppLog.add('brain', 'error $code${fatal ? '' : ' (the reply stands)'}');
    if (code == 'offline') connected = false;
    if (!fatal) {
      if (code == 'tts' && !speakerMuted) AppFeedback.toast(message);
      return;
    }
    // The turn ended with no reply. In a conversation it is said on screen
    // and the conversation listens on — twice in a row, or a fault no
    // retry can fix (the app not allowed, the service off), and it stops.
    _turnFailures++;
    const permanent = {'not_enabled', 'denied', 'location'};
    if (_voiceOn && !permanent.contains(code) && _turnFailures < 2) {
      transcript.add(TranscriptEntry(TranscriptRole.assistant, message));
      _captionLine('hari', message);
      return;
    }
    if (_voiceOn) unawaited(_stopVoice());
    _setLocalError(message);
  }

  /// The tool the model is using, as a chip ("Checking the weather…").
  void _toolStarted(String tool) {
    _finishTools();
    if (LocationService.locationTools.contains(tool)) {
      unawaited(_maybeAskLocation());
    }
    final label = _labelForTool(tool);
    activities.add(ToolActivity(tool: tool, label: label));
    activityLabel.value = label;
  }

  /// The tools before this point have reported back (the brain runs them
  /// one at a time): what they changed on this phone is brought up to date.
  void _finishTools() {
    for (final a in activities) {
      if (a.completed) continue;
      a.completed = true;
      // ARM THE ALARM NOW, NOT WHEN THE BRIEF NEXT REFRESHES: a reminder
      // set for a few seconds from now has to be armed in those seconds.
      if (_remindersTouchedBy(a.tool)) {
        unawaited(ReminderNotifications.instance.sync());
      }
    }
    if (activityLabel.value != null) activityLabel.value = null;
  }

  void _afterTurn() {
    _lastLifeAt = DateTime.now();
    if (_endAfterTurn) {
      _endAfterTurn = false;
      unawaited(_endWhenQuiet());
      return;
    }
    if (phase == AssistantPhase.thinking ||
        phase == AssistantPhase.responding ||
        (phase == AssistantPhase.speaking && !_player.playing)) {
      _setPhase(_voiceOn ? AssistantPhase.listening : AssistantPhase.completed,
          silent: true);
    }
    if (_voiceOn) {
      _maybeListen();
    } else {
      unawaited(_nextNote());
    }
  }

  /// "Bye": her farewell plays out, then the whole conversation closes —
  /// orb, overlay, microphone.
  Future<void> _endWhenQuiet() async {
    await _stopListening();
    try {
      await _player.drained().timeout(const Duration(seconds: 12));
    } catch (_) {}
    if (inlineVoice || _voiceOn || _conversationOpen) {
      await endInlineConversation();
    }
  }

  // ---------------- THE APP'S OWN NOTES ----------------

  /// [SYSTEM] notes waiting for a turn of their own.
  final _notes = <({String line, bool untrusted})>[];
  bool _notesRunning = false;

  /// [_tellModel] for feature modules (the photo-card actions).
  Future<void> tellModel(String line) => _tellModel(line);

  /// [_tellModel] with [untrusted] (tests).
  @visibleForTesting
  Future<void> debugNote(String line, {bool untrusted = false}) =>
      _tellModel(line, untrusted: untrusted);

  /// A [SYSTEM] note about something the phone did.
  ///
  /// Said while a device action of a turn runs, it IS that action's outcome
  /// — the model hears it as the function's result, in the same turn.
  /// Outside a turn (a greeting, missed calls, a camera's reading, a call
  /// that ended, someone's message), it starts a turn of its own once the
  /// current one is over; [untrusted] marks someone else's words.
  Future<void> _tellModel(String line, {bool untrusted = false}) async {
    final reply = Zone.current[_deviceReplyKey];
    if (reply is _DeviceReply && !reply.answered) {
      reply.answer(DeviceOutcome(ok: !line.contains('ERROR'), detail: line));
      return;
    }
    _notes.add((line: line, untrusted: untrusted));
    await _nextNote();
  }

  Future<void> _nextNote() async {
    if (_notesRunning || _turnRunning || _notes.isEmpty) return;
    // A real phone call always wins: nothing is said over it.
    if (PhoneStateGuard.instance.inCall) {
      _notes.clear();
      return;
    }
    if (_listening) {
      // The owner is mid-sentence: their turn first.
      if (partial.trim().isNotEmpty) return;
      await _stopListening();
    }
    _notesRunning = true;
    try {
      while (_notes.isNotEmpty && !_turnRunning) {
        final n = _notes.removeAt(0);
        await _runTurn(n.line,
            mode: BrainMode.voice, untrusted: n.untrusted, fromOwner: false);
        // One after another, never over each other.
        try {
          await _player.drained().timeout(const Duration(seconds: 30));
        } catch (_) {}
      }
    } finally {
      _notesRunning = false;
    }
    _maybeListen();
  }

  // ---------------- DEVICE ACTIONS ----------------

  static const _deviceReplyKey = #assistantDeviceReply;

  /// Flows that need the owner (the camera, a picker, a signature, a share
  /// sheet): the model is answered at once and the result follows as a
  /// turn of its own.
  static const _ownerFlows = {
    'analyze_camera',
    'capture_document',
    'open_camera',
    'ask_about_image',
    'scan_business_card',
    'shortcut_run',
  };

  /// The most a device action may keep the model waiting (the brain gives
  /// up at 30 s); a longer one is answered "started" and reports later.
  static const _deviceAnswerWithin = Duration(seconds: 20);

  /// Performs a device action the brain handed over, through the same
  /// switch that always performed them, and ALWAYS answers — unanswered,
  /// the model waits 30 s. A [SYSTEM] note said while it runs is its
  /// outcome; a reported failure makes it a failure; otherwise it is done.
  Future<void> _performForBrain(
    String tool,
    Map<String, dynamic> action,
    void Function(DeviceOutcome outcome) respond,
  ) async {
    final reply = _DeviceReply(respond);
    final type = '${action['type'] ?? ''}';
    AppLog.add('brain', 'device action $type ($tool)');
    await runZoned(() async {
      try {
        final work = _onEvent(action);
        if (_ownerFlows.contains(type)) {
          reply.answer(const DeviceOutcome.ok('It is open on the phone and the '
              'owner is doing it now; its result comes as the next message. Do '
              'not say it is finished.'));
        }
        await work.timeout(_deviceAnswerWithin);
      } on TimeoutException {
        reply.answer(const DeviceOutcome.ok(
            'Started on the phone; its result comes as the next message.'));
      } catch (e) {
        reply.answer(DeviceOutcome.failed('The phone could not do it: $e'));
      }
      reply.answer(const DeviceOutcome.ok());
    }, zoneValues: {_deviceReplyKey: reply});
  }

  /// The account the current conversation belongs to. HomeShell calls
  /// [ensureFreshSession] on every appearance: after a sign-out and
  /// sign-in as someone else, the brain must not carry the previous
  /// account's conversation.
  String? _sessionUid;

  /// Nobody is signed in any more: stop listening and forget the
  /// conversation, so nothing of the previous account runs behind the
  /// login screen.
  Future<void> _onSignedOut() async {
    try {
      await leaveConversation(chime: false);
    } catch (_) {}
    _brainMade?.reset();
    resetGreeting();
    _sessionUid = null;
  }

  Future<void> ensureFreshSession() async {
    final uid = AuthService.instance.user?.id.toString();
    if (uid == null) return;
    if (_sessionUid == null || _sessionUid == uid) {
      _sessionUid = uid;
      return;
    }
    AppLog.add('engine', 'account changed — a new conversation');
    _sessionUid = uid;
    await leaveConversation();
    _brainMade?.reset();
    resetGreeting();
  }

  /// The owner LEFT the conversation — back on Home, among the calendar and
  /// cards, nothing may keep listening or talking. Reopening starts
  /// everything fresh.
  Future<void> leaveConversation({bool chime = true}) async {
    // THE CLOSING HALF OF THE PAIR: only when something was listening, and
    // never off-screen.
    final wasListening = _voiceOn || inlineVoice;
    if (chime && wasListening && _foreground) unawaited(ListeningChime.playStop());
    _idleStop?.cancel();
    _idleStop = null;
    _conversationOpen = false;
    inlineVoice = false;
    _endAfterTurn = false;
    // MUTE BELONGS TO THE CONVERSATION THAT SET IT: the only unmute control
    // lives in the voice overlay.
    if (speakerMuted) setSpeakerMuted(false);
    // Typing pauses the mic; the pause never outlives the conversation.
    _typing = false;
    // Web results belong to the conversation they answered.
    searchQuery = null;
    searchResults = const [];
    searchSuggestions = const [];
    translatorActive = false; // the interpreter never outlives the screen
    _clearCaption();
    activityLabel.value = null;
    _announceEpoch++; // any message readout in flight stops at its next line
    // THE SCREEN GOES FIRST (client, 2026-10-01: "Listening" stayed on
    // after the tap). The phase used to turn idle only after the voice had
    // stopped, and that stop waits on the microphone and the session — on
    // a bad link, for many seconds — while the overlay still said
    // Listening and a second tap read as "stop" again.
    micLevel = 0;
    if (phase != AssistantPhase.idle) _setPhase(AssistantPhase.idle, silent: true);
    notifyListeners();
    await _stopVoice();
    micLevel = 0;
    if (phase != AssistantPhase.idle) _setPhase(AssistantPhase.idle, silent: true);
    notifyListeners();
  }

  // ---------------- OPENING GREETING ----------------

  /// True once the owner has opened the conversation this app run. The
  /// greeting is gated on it, so nothing can make the phone start talking
  /// out of nowhere while they are on the dashboard.
  bool _conversationOpen = false;

  /// The user's display name, supplied by the screen once it is known.
  String? greetingName;

  /// Suppresses the automatic spoken greeting when a conversation opens.
  ///
  /// OFF since 2026-09-20 at the owner's request (the orb tap's cached
  /// hello stays). It stays a switch rather than deleted code: flipping it
  /// back is one word.
  bool greetingEnabled = false;

  /// How the owner is addressed (owner, 2026-09-23: "should say hello
  /// Sir, and give more respect"; 2026-09-24: "don't call them ji, call
  /// them Sir"). Ma'am when the profile says female, Sir otherwise — never
  /// "<name> ji". The server tells the model the same thing, so the voice
  /// and this greeting never disagree.
  static String honorific({String? name, String? gender}) {
    return (gender ?? '').trim().toLowerCase() == 'female' ? "Ma'am" : 'Sir';
  }

  /// What the orb tap says, instantly, in the assistant's own voice.
  static String orbGreeting({String? name, String? gender}) {
    final who = honorific(name: name, gender: gender);
    return who.isEmpty ? 'Hello!' : 'Hello $who!';
  }

  /// Time-appropriate greeting text.
  static String greetingFor(String? name, {String? gender, DateTime? now}) {
    final h0 = honorific(name: name, gender: gender);
    final who = h0.isEmpty ? 'there' : h0;
    // Short and professional — the greeting is also the app's first
    // latency impression, so one crisp sentence beats a flourish.
    final h = (now ?? DateTime.now()).hour;
    final part = h < 12
        ? 'Good morning'
        : h < 17
            ? 'Good afternoon'
            : 'Good evening';
    return '$part, $who! How can I help you today?';
  }

  /// The spoken greeting, when it is switched on: a FIXED line, so it goes
  /// straight through the speech engine — no model is asked to say it.
  /// Refuses while offline to the conversation, mid-turn, in a phone call,
  /// or when it was said recently.
  Future<void> greetOnce({String? name}) async {
    if (name != null && name.isNotEmpty) greetingName = name;
    if (!greetingEnabled || !_conversationOpen) return;
    if (DateTime.now().difference(_lastGreetedAt) < _greetCooldown) return;
    if (_turnRunning || PhoneStateGuard.instance.inCall) return;
    _lastGreetedAt = DateTime.now();
    final text = greetingFor(greetingName, gender: AuthService.instance.user?.gender);
    transcript.add(TranscriptEntry(TranscriptRole.assistant, text));
    replyComplete = true;
    _captionLine('hari', text);
    notifyListeners();
    await _speakDirect(text);
  }

  /// Resets the greeting clock — used when a DIFFERENT user signs in, so
  /// the next person is greeted properly.
  void resetGreeting() => _lastGreetedAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------------- GOODBYE ----------------

  /// Phrases that close the conversation. Deliberately conservative: the
  /// phrase must END the utterance (allowing trailing filler like "then",
  /// "thanks", "for now") and the utterance must be short. That way "see
  /// you at the clinic tomorrow" or "that's all right, continue" keep the
  /// conversation going, while "okay goodbye" ends it.
  static final RegExp _farewellRx = RegExp(
    r"\b(bye|bye bye|goodbye|good bye|good night|goodnight|see you|see ya|"
    r"talk (to you )?later|catch you later|that'?s all|thats all|that'?s it|"
    r"nothing else|no more questions|i'?m done|we'?re done|stop listening|"
    r"stop it|that will be all)"
    r"(?:\s+(hari|harry|then|now|dear|ok|okay|thanks|thank you|please|bye|"
    r"later|for now))*\s*$",
    caseSensitive: false,
  );

  /// Farewells in the other languages the assistant speaks.
  static final RegExp _farewellNativeRx = RegExp(
    r"अलविदा|फिर मिलेंगे|बाय|बस इतना|ಬೈ|ಸಾಕು|ಹೋಗ್ತೀನಿ|ಮುಗಿಯಿತು|"
    r"போதும்|பிறகு பார்க்கலாம்|సరిపోతుంది|వెళ్తాను",
  );

  static bool isFarewell(String text) {
    var t = text.trim().toLowerCase();
    t = t.replaceAll(RegExp(r'[.!?,;।]+$'), '').trim();
    if (t.isEmpty) return false;
    // Sign-offs are short; a long sentence that merely contains "see you"
    // is not the user ending the conversation.
    if (t.split(RegExp(r'\s+')).length > 8) return false;
    return _farewellRx.hasMatch(t) || _farewellNativeRx.hasMatch(t);
  }

  // ---------------- ASKED FROM A SCREEN ----------------

  /// The same canned request sent twice, a second apart (a double-tapped
  /// "Brief me") read the whole agenda out twice. Keyed on the TEXT:
  /// asking two different things in quick succession is legitimate.
  String? _lastAsk;
  DateTime _lastAskAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _askDedupeWindow = Duration(seconds: 4);

  /// Ask the assistant something on the owner's behalf (a panel's button:
  /// "Brief me", "Listen", "Tell me about Ravi"): one turn, answered out
  /// loud — a button tap and a spoken request are the same thing to the
  /// rest of the system.
  Future<void> askAssistant(String text) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final now = DateTime.now();
    if (t == _lastAsk && now.difference(_lastAskAt) < _askDedupeWindow) {
      AppLog.add('ask', 'ignored a repeat of "${t.length > 40 ? '${t.substring(0, 40)}…' : t}"');
      return;
    }
    _lastAsk = t;
    _lastAskAt = now;
    await _runTurn(t, mode: BrainMode.voice);
  }

  /// AGENT-TO-AGENT DELIVERY, spoken half. Fetches this user's unread
  /// agent messages and has the assistant SAY them ("Dhanush said: …").
  /// Called by the push listeners (foreground arrival, notification tap,
  /// cold start from a notification). Marked read immediately, so a
  /// conversation that starts later does not announce them a second time.
  bool _announcing = false;

  /// Bumped by leaveConversation — the readout checks it between messages
  /// so unread items 2 and 3 don't keep speaking over Home.
  int _announceEpoch = 0;

  Future<void> announceIncomingMessages() async {
    if (_announcing) return;
    _announcing = true;
    final epoch = _announceEpoch;
    try {
      // On a cold start from a notification tap the auth session may not
      // be loaded yet — wait for it briefly rather than fetching as nobody.
      for (var i = 0; i < 20 && ApiService.sessionToken == null; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      final j = await ApiService.getJson('/messages/unread');
      final list = (j?['messages'] as List?)
              ?.whereType<Map<String, dynamic>>()
              // Messages with avatar media are delivered VISUALLY by the
              // popup (AvatarMessageService) — speaking them here would
              // both double-deliver and mark them read before the popup
              // ever saw them.
              .where((m) => (m['media'] ?? '') == '')
              .toList() ??
          const [];
      if (list.isEmpty) return;
      await ApiService.sendJson('/messages/read',
          body: {'ids': [for (final m in list) m['id']]});

      // A personal relay, not a readout: "Hey Allen, Dhanush said: …".
      final meFull = (greetingName ?? AuthService.instance.user?.name ?? '').trim();
      final me = meFull.isEmpty ? '' : meFull.split(RegExp(r'\s+')).first;
      final hey = me.isEmpty ? 'Hey,' : 'Hey $me,';
      final lines = [
        for (final m in list)
          '$hey ${(m['from'] as String? ?? 'Someone').split(RegExp(r'\s+')).first}'
              // auto = composed by the other person's assistant — never put
              // words in the person's own mouth.
              '${m['auto'] == true ? "'s assistant" : ''} '
              'said: ${m['message'] ?? ''}'
      ];
      if (_voiceOn || _turnRunning) {
        // A conversation is running: the assistant delivers them in it —
        // someone else's words, so the turn is marked untrusted (nothing is
        // saved, sent or paid because a message asks).
        await _tellModel(
            '[SYSTEM] New message${lines.length > 1 ? 's' : ''} just arrived. '
            'Read to me now, naming each sender: ${lines.join(' | ')}',
            untrusted: true);
        return;
      }
      // No conversation: read out as they are, in her voice, no model.
      for (final line in lines) {
        if (epoch != _announceEpoch) return; // user left — stop talking
        transcript.add(TranscriptEntry(TranscriptRole.assistant, line));
        notifyListeners();
        await _speakDirect(line);
      }
    } catch (_) {
      // A failed announce keeps the message unread-safe: worst case the
      // brief still shows it and the next conversation says it.
    } finally {
      _announcing = false;
    }
  }

  /// Confirmation card buttons.
  Future<void> confirm(bool approved) async {
    final pending = pendingConfirmation;
    pendingConfirmation = null;
    notifyListeners();
    HapticFeedback.selectionClick();

    // An on-device call flow: dial (or drop) here, and say what happened.
    if (_localCallFlow) {
      _localCallFlow = false;
      final who = pending?.contact?.name ?? 'them';
      if (approved && (pending?.contact?.phone.isNotEmpty ?? false)) {
        await _dialAndReport(pending!.contact!);
      } else {
        await _tellModel('[SYSTEM] I declined the call to $who. Acknowledge briefly.');
      }
      return;
    }
    // The server is waiting for the owner's yes: the card's button IS that
    // answer, and the approval rides on this turn only when it says yes.
    await _runTurn(approved ? 'Yes' : 'No',
        mode: _voiceOn ? BrainMode.voice : BrainMode.chat, speak: true);
  }

  /// Ambiguous-contact card selection.
  Future<void> chooseContact(ContactMatch m) async {
    ambiguousContacts = const [];
    notifyListeners();
    // The owner's tap on the pick IS the choice — act on it (relay or
    // direct dial).
    if (_localCallFlow) {
      _localCallFlow = false;
      await _actOnResolvedCall(m);
      return;
    }
    // No call is waiting on it here: the name goes to the assistant as the
    // owner's answer.
    await _runTurn(m.name, mode: _voiceOn ? BrainMode.voice : BrainMode.chat, speak: true);
  }

  /// Cancel whatever is in flight: the turn, her voice, a card waiting on
  /// a tap. A conversation that is running listens again.
  Future<void> cancelAction() async {
    _localCallFlow = false;
    pendingConfirmation = null;
    ambiguousContacts = const [];
    _sayEpoch++;
    await _brainMade?.cancel();
    await _speechMade?.cancel();
    await _player.stop();
    activityLabel.value = null;
    _setPhase(_voiceOn ? AssistantPhase.listening : AssistantPhase.idle);
    _maybeListen();
  }

  void dismissError() {
    errorMessage = null;
    if (phase == AssistantPhase.error) phase = AssistantPhase.idle;
    notifyListeners();
  }

  // ---------------- DEVICE ACTIONS: WHAT THE PHONE DOES ----------------

  /// Hands an action to the engine as if the brain had (tests).
  @visibleForTesting
  void debugHandleEvent(Map<String, dynamic> e) => unawaited(_onEvent(e));

  /// Performs one device action — every shape the server's tools send.
  /// Completes when the action is done, so the brain can tell the model
  /// how it went ([_performForBrain]).
  Future<void> _onEvent(Map<String, dynamic> e) async {
    switch (e['type']) {
      case 'search_results':
        searchQuery = e['query'] as String?;
        searchResults = ((e['results'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SearchResult.fromJson)
            .toList();
        break;

      case 'documents':
        // Saved documents matched by this turn (doc recall or a client's
        // case file) — pop them on screen while Hari speaks the answer.
        documentCards = UserDocument.listFromJson(e['documents']);
        if (documentCards.isNotEmpty) {
          onShowDocuments?.call(documentCards);
        }
        break;

      case 'resolve_and_call':
        // LIVE MODE calling. The place_phone_call tool emits this action;
        // on the SSE path the server converts it into the contact_lookup
        // handshake, but on the LIVE socket it arrives here AS-IS — and
        // nothing handled it, so Hari said "Calling…" and the phone never
        // dialled. The whole flow is on-device anyway (contacts + dialler
        // live here), so resolve, confirm and dial locally.
        await _handleResolveAndCall(
          e['name'] as String? ?? '',
          e['message'] as String?,
          agentAvailable: e['agent_available'] == true,
          via: (e['via'] ?? 'phone').toString(),
          retryTimes: (e['retry_times'] as num?)?.toInt() ?? 0,
          retryGapMinutes: (e['retry_gap_minutes'] as num?)?.toInt() ?? 0,
          tone: e['tone'] as String?,
          language: e['language'] as String?,
          voice: e['voice'] as String?,
        );
        break;

      case 'analyze_camera':
        // Voice-driven vision analysis ("what tablet is this")
        await _analyzeCamera(e['question'] as String? ?? 'What is in this image?');
        break;

      case 'capture_document':
      case 'open_camera':
        // Voice-driven capture: the backend recognised "save/scan/remember
        // this" and asks the device to open the camera/gallery and file the shot.
        await _captureDocument(
          e['note'] as String? ?? '',
          clientId: (e['client_id'] as num?)?.toInt(),
          person: e['person'] as String?,
          source: e['source'] as String? ?? 'camera',
        );
        break;

      case 'ask_about_image':
        // look_at_screenshot: they pick a picture they already have and we
        // answer about it. The server's screenshot mode existed for months
        // with nothing on this side to reach it.
        await _askAboutImage(
          question: e['question'] as String? ?? '',
          source: e['source'] as String? ?? 'gallery',
        );
        break;

      case 'phone_control':
        // Flashlight / volume / media / battery / settings — executed on
        // the device with the REAL result reported back; a control that
        // failed is said to have failed, never assumed.
        await _handlePhoneControl(e);
        break;

      case 'send_sms':
        // Delivery ladder, rung two: the recipient isn't an app user, so
        // the phone itself sends the message as a plain SMS — no taps.
        // The REAL result is recorded and, on failure, spoken: the tool
        // already told the user "sending as a text", so silence on an
        // error would be a lie.
        {
          final to = (e['to'] ?? '').toString();
          final who = (e['name'] ?? 'them').toString();
          final msg = (e['message'] ?? '').toString();
          final err = await SmsService.instance.send(to, msg);
          final ok = err == null;
          AppFeedback.toast(ok ? 'Text sent to $who.' : "Couldn't text $who — $err.");
          try {
            await ApiService.sendJson('/outcomes', method: 'POST', body: {
              'kind': 'message',
              'target': who,
              'status': ok ? 'completed' : 'failed',
              if (!ok) 'reason': err,
              'detail': 'SMS',
            });
          } catch (_) {}
          if (!ok) {
            await _tellModel('[SYSTEM] ERROR: the SMS to $who FAILED — $err. It was NOT '
                'sent; tell me plainly and suggest fixing the permission '
                'or trying again.');
          }
        }
        break;

      case 'share_document':
        // "Send Ramesh his report on WhatsApp" — the server picked the
        // file from the patient's case; the phone downloads the real bytes
        // and opens the share sheet. The user's tap on a chat is what
        // actually sends it, so nothing here claims delivery.
        {
          final doc = e['document'];
          if (doc is Map) {
            final d = UserDocument.fromJson(doc.cast<String, dynamic>());
            documentCards = [d];
            notifyListeners();
            await shareDocumentFile(d).catchError((_) {
              AppFeedback.toast("Couldn't prepare that file to share.");
            });
          }
        }
        break;

      case 'document_filed':
        // The agent moved a saved document into a client's case file
        // (file_document_under_client) and the server CONFIRMED it. Refresh
        // any open document list and show it on screen.
        {
          final client = e['client'];
          final name = client is Map ? (client['name'] ?? '').toString() : '';
          final doc = e['document'];
          if (doc is Map) {
            documentCards = [UserDocument.fromJson(doc.cast<String, dynamic>())];
            notifyListeners();
          }
          DocumentEvents.bump();
          if (name.isNotEmpty) AppFeedback.toast("Filed under $name.");
        }
        break;

      case 'set_theme':
        // "Switch to dark mode" — spoken, and applied without opening a
        // settings screen. ThemeController persists it and repaints the
        // whole tree, exactly as the toggle in the You tab does.
        {
          final mode = e['mode'] as String? ?? '';
          final target = switch (mode) {
            'dark' => ThemeMode3.dark,
            'light' => ThemeMode3.light,
            'adaptive' => ThemeMode3.adaptive,
            _ => null,
          };
          if (target != null) {
            ThemeController.setMode(target);
          } else {
            _reportDeviceFailure('set_app_theme',
                target: mode, reason: 'not a theme this app has');
          }
        }
        break;

      case 'scan_business_card':
        await _scanBusinessCard();
        break;

      case 'call_log':
        // "Any missed calls?", "did Ravi call?" — read on this phone and
        // answered with ONE [SYSTEM] line (phone_calls tool, build 106).
        await _answerCallLog(e);
        break;

      case 'shortcut_run':
        // "Office mode" (build 120): the phone steps of a shortcut, in the
        // order the server fixed. Each one is an ordinary device action
        // this switch already performs and reports on; the runner decides
        // when (in-app at once, the chat message, the app that stays open,
        // a phone task last) and keeps the rest for the owner's return.
        unawaited(ShortcutRunner.instance.run(ShortcutRunDirective.fromJson(e), shortcutPorts));
        break;

      case 'open_app_screen':
        // A screen inside THIS app, opened by voice. The four main tabs go
        // through the shell; everything else is a pushed route.
        {
          final screen = e['screen'] as String? ?? '';
          // Nearby took Chat's place in the dock (2026-10-01); 'chat' now
          // means the Messages thread list, pushed from the Hub.
          const tabs = {'home': 0, 'hub': 1, 'nearby': 2, 'settings': 3};
          if (tabs.containsKey(screen)) {
            HomeShell.requestedTab.value = tabs[screen];
          } else {
            final nav = AvatarMessageService.navigatorKey.currentState;
            final builder = _appScreenBuilder(screen, e);
            if (nav == null || builder == null) {
              _reportDeviceFailure('open_app_screen',
                  target: screen, reason: 'that screen is not available');
            } else if (screen == 'shopping_list' && ShoppingListScreen.showing > 0) {
              // Already open: it redraws with what the assistant just did
              // rather than stacking a second list.
              unawaited(ShoppingService.instance.refresh());
            } else {
              nav.push(MaterialPageRoute(builder: builder));
            }
          }
        }
        break;

      case 'start_focus':
        // "Start a 25-minute focus on the report" (build 111): the Focus
        // page opens and starts; it logs the minutes itself when it ends.
        {
          final nav = AvatarMessageService.navigatorKey.currentState;
          final minutes = (e['minutes'] as num?)?.toInt() ?? 25;
          final label = (e['label'] ?? '').toString();
          if (nav == null) {
            _reportDeviceFailure('start_focus', reason: 'the focus timer could not open');
          } else {
            nav.push(MaterialPageRoute(
                builder: (_) => FocusScreen(minutes: minutes, label: label, autoStart: true)));
          }
        }
        break;

      case 'momentum_updated':
        // Momentum is gone from the app (2026-09-29): nothing to redraw.
        break;

      case 'shopping_list_updated':
        // The assistant added, ticked, removed or cleared something on the
        // shopping list (build 124): an open list and Hub's count redraw
        // now. A notice — asks nothing else of the phone.
        unawaited(ShoppingService.instance.refresh());
        break;

      case 'shop_handoff':
        // "Order these" (shop_from_list, build 124, asked first): each
        // thing opens in the app that sells it — the first now, the rest
        // from the "Shopping · 1 of 7 · Next" notification. Nothing is
        // ordered or paid here; the owner chooses and pays in the app.
        await _shopFromList(e);
        break;

      case 'open_usage_access':
        // Screen-time needs the Usage access switch, which lives in a
        // system settings screen no dialog can replace — take them there.
        //
        // The RESULT is reported now. It used to be discarded, so the
        // server never learned the screen had opened and the claim check
        // treated "I'm opening those settings" as unbacked — the assistant
        // then apologised three times running for something that had
        // worked. Only a real failure is reported, matching every other
        // device action.
        await UsageService.instance.openSettings().then((opened) {
          if (!opened) {
            _reportDeviceFailure('enable_usage_tracking',
                reason: 'this phone has no Usage access settings screen');
          }
        });
        break;

      case 'clock_intent':
        // Alarms and timers no longer travel as an intent URI — see the
        // Kotlin handler. The action and its extras go across as data and
        // the Intent is built natively, so nothing has to survive a URI
        // parser on the way.
        {
          final action = e['action'] as String? ?? '';
          final extras = (e['extras'] as Map?)?.cast<String, dynamic>() ?? {};
          if (action.isNotEmpty) {
            await const MethodChannel('hari/intent')
                .invokeMethod<Map<Object?, Object?>>(
                    'clockIntent', {'action': action, 'extras': extras})
                .then((res) {
              final ok = res?['ok'] == true;
              final reason = (res?['reason'] as String?) ?? 'failed';
              AppLog.add('clock', '$action -> ${ok ? "started" : "FAILED ($reason)"}');
              if (ok) return;
              _reportDeviceFailure('clock_intent', target: action, reason: reason);
              // WHAT THE USER CAN ACTUALLY DO ABOUT IT.
              //
              // SET_ALARM is an install-time permission: Android grants it
              // when the app declares it and there is no runtime dialog to
              // show. So an older build genuinely cannot be fixed from
              // here — the honest remedy is the update, and the assistant
              // offers it rather than leaving the user to guess.
              if (reason == 'needs_alarm_permission') {
                AppFeedback.toast(
                    'This version cannot set alarms — update the app to enable it.',
                    spoken: true);
                _tellModel(
                    '[SYSTEM] ERROR: this build of the app is not permitted to set '
                    'alarms or timers, so NOTHING was set. Tell them in one line '
                    'that it needs a newer version, then call update_app to put '
                    'the installer on screen. Do NOT tell them to hunt through '
                    'settings — there is no permission switch for this one.');
              } else if (reason == 'no_clock_app') {
                AppFeedback.toast('No clock app on this phone.', spoken: true);
                _tellModel(
                    '[SYSTEM] ERROR: this phone has no clock app that can handle '
                    '"$action", so NOTHING was set. Say that plainly.');
              } else {
                _tellModel(
                    '[SYSTEM] ERROR: the phone refused "$action", so NOTHING was '
                    'set. Say plainly that it did not work. Do not claim it did.');
              }
            }).catchError((err) {
              AppLog.add('clock', '$action -> channel error: $err');
            });
          }
        }
        break;

      case 'open_url':
        // Voice-driven deep linking to external apps like Uber, Swiggy, Zomato.
        final url = e['url'] as String?;
        if (url != null && url.isNotEmpty) {
          // We are sending them out of the app on purpose — mark it so
          // the return trip rebuilds the voice session instead of
          // resuming a socket Android has already torn down.
          _leftForExternalApp = true;
          await _openExternalUrl(url);
        }
        break;

      case 'end_conversation':
        // The owner said goodbye: no more listening, her farewell (this
        // turn's reply) plays out, then the whole conversation closes —
        // orb, overlay, microphone.
        AppLog.add('voice', 'the owner ended the conversation by voice');
        _endAfterTurn = true;
        if (_listening) unawaited(_stopListening());
        if (!_turnRunning) unawaited(_endWhenQuiet());
        break;

      case 'open_any_app':
        // ANY app on the phone, resolved BY THE PHONE. The server has no
        // list to be missing from — it passes the spoken name through and
        // Android matches it against what is actually installed. A miss
        // is reported honestly so the assistant says it plainly instead of
        // claiming an app opened.
        {
          final want = (e['name'] as String? ?? '').trim();
          final pkg = (e['pkg'] as String? ?? '').trim();
          // INSTALL ONLY ON THE OWNER'S WORDS. Owner, 2026-09-24: "open X"
          // on a phone without X installed it unasked. The server now says
          // whether they asked to install / download it (or said yes to
          // installing it); without that the store page opens and ONE
          // question is asked.
          final mayInstall = e['install'] == true;
          _leftForExternalApp = true;
          await const MethodChannel('hari/intent')
              .invokeMethod<String>('launchApp', {'name': want, 'pkg': pkg})
              .then((opened) async {
            if (opened == null || opened.isEmpty) {
              _leftForExternalApp = false;
              // NOT INSTALLED MEANS THE STORE. Owner, 2026-09-23: "open
              // swiggy" must never end at the website or at "you don't
              // have it" — the app store page (the exact listing when the
              // package is known), and the phone opens the app once it is
              // installed (InstallWatch).
              if (e['store_if_missing'] == true) {
                await const MethodChannel('hari/intent')
                    .invokeMethod<bool>('openStore', {'query': want, 'pkg': pkg})
                    .then((ok) async {
                  if (ok == true) {
                    _leftForExternalApp = true;
                    if (!mayInstall) {
                      // Not asked to install: the page is open, the
                      // decision is theirs — one question, nothing pressed.
                      AppFeedback.toast("$want isn't installed");
                      _tellModel(
                          '[SYSTEM] "$want" is not installed; its page in the app '
                          'store is now open and NOTHING was installed. Ask exactly '
                          'this one question and nothing else: "It isn\'t installed '
                          '— want me to install it?" If they say yes, call '
                          'open_named_app for "$want" with install true. Never '
                          'name the store.');
                      return;
                    }
                    // Asked to install: the store page is open, they tap
                    // Install, and InstallWatch opens the app when it lands.
                    AppFeedback.toast("$want isn't installed — tap Install",
                        spoken: true);
                    _tellModel(
                        '[SYSTEM] "$want" is not installed, so its page in the app '
                        'store is now open. Say in ONE short sentence that they '
                        'just need to tap Install, and you will open $want for '
                        'them as soon as it is installed. Never name the store.');
                  } else {
                    _reportDeviceFailure('open_named_app',
                        target: want, reason: 'not installed, no app store');
                    _tellModel(
                        '[SYSTEM] ERROR: "$want" is NOT installed and the app '
                        'store could not be opened. Say that plainly.');
                  }
                }).catchError((_) {});
                return;
              }
              AppFeedback.toast('$want isn\'t installed on this phone.',
                  spoken: true);
              _reportDeviceFailure('open_named_app',
                  target: want, reason: 'no app by that name is installed');
              _tellModel(
                  '[SYSTEM] ERROR: "$want" is NOT installed on this phone, so '
                  'nothing opened. Tell the user plainly that they do not have '
                  'it, and do NOT open or claim to open anything else.');
            } else {
              AppLog.add('intent', 'opened $opened');
            }
          }).catchError((e) {
            _leftForExternalApp = false;
            AppLog.add('intent', 'launchApp failed: $e');
            _reportDeviceFailure('open_named_app',
                target: want, reason: 'the phone could not launch it');
          });
        }
        break;

      case 'uninstall_app':
        // "UNINSTALL INSTAGRAM". Android's own confirmation opens and the
        // owner's OK there is the permission — the assistant never taps
        // it. The phone then checks whether the app is really gone, and
        // the assistant says exactly that, one fixed sentence per outcome.
        {
          final want = (e['name'] as String? ?? '').trim();
          final pkg = (e['pkg'] as String? ?? '').trim();
          await const MethodChannel('hari/intent')
              .invokeMethod<Object?>('uninstallApp', {'name': want, 'pkg': pkg})
              .then((r) {
            final m = r is Map ? r : const {};
            final status = '${m['status'] ?? 'failed'}';
            final label = '${m['label'] ?? want}'.trim().isEmpty ? want : '${m['label']}';
            AppLog.add('uninstall', status);
            final String line;
            switch (status) {
              case 'uninstalled':
                line = '$label is uninstalled.';
                AppFeedback.toast(line);
                break;
              case 'cancelled':
                line = "Okay, I've kept $label.";
                break;
              case 'no_answer':
                line = 'The uninstall screen closed without an answer, so $label is still on your phone.';
                break;
              case 'not_found':
                line = "I couldn't find an app called $want on your phone.";
                break;
              case 'system_app':
                line = m['opened_info'] == true
                    ? "$label came with your phone, so Android won't let it be uninstalled — I've opened its App info, where you can tap Disable."
                    : "$label came with your phone, so Android won't let it be uninstalled — you can disable it in Settings, Apps.";
                break;
              case 'self':
                line = "I can't uninstall myself — you can do that from Settings, Apps.";
                break;
              case 'busy':
                line = 'The uninstall screen is already open — tap OK or Cancel there first.';
                break;
              case 'device_admin':
                // Found before the dialog opens: Android would refuse it.
                line = '$label is a device admin app, so Android won\'t remove it until '
                    'that is switched off — in Settings, under Device admin apps. Then ask me again.';
                break;
              case 'blocked_by_policy':
                line = "Your phone's settings don't allow uninstalling $label, so it's still on your phone.";
                break;
              case 'failed_after_confirm':
                line = "Android didn't remove $label — it's still on your phone.";
                break;
              default:
                line = "I couldn't open the uninstall screen for $label.";
            }
            // EVERY outcome but a real removal goes back as a failure, so
            // "did you uninstall it?" is never answered from a stale "ok".
            if (status != 'uninstalled') {
              _reportDeviceFailure('uninstall_app', target: want, reason: status);
            }
            _tellModel('[SYSTEM] Uninstall "$want" finished: $status. Say exactly '
                'this, nothing before or after it: "$line"');
          }).catchError((err) {
            AppLog.add('uninstall', 'channel error: $err');
            _reportDeviceFailure('uninstall_app', target: want, reason: 'channel');
            _tellModel('[SYSTEM] ERROR: the uninstall screen could not be opened, '
                'so NOTHING was removed. Say that plainly in one sentence.');
          });
        }
        break;

      case 'live_voice_changed':
        // The voice is /ai/config's (Gemini TTS): fetched again, the next
        // sentence is said in the new one. The cached greeting was made in
        // the old voice.
        unawaited(AiConfigStore.instance.refresh());
        unawaited(GreetingVoice.instance.clear());
        break;

      case 'assistant_renamed':
        // "Your name is Maya now" — the app renames itself instantly,
        // every screen at once. The spoken confirmation already happened.
        final newName = (e['name'] as String?)?.trim();
        if (newName != null && newName.isNotEmpty) {
          AssistantIdentity.set(newName);
        }
        break;

      case 'show_schedule':
        scheduleItems = ((e['items'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ScheduleItem.fromJson)
            .where((x) => x.title.isNotEmpty)
            .toList(growable: false);
        scheduleDay = e['day'] as String? ?? 'today';
        scheduleFailed = ((e['failed'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false);
        break;

      case 'check_for_update':
        // THE USER ASKED FOR THE UPDATE, so this bypasses the ordinary
        // throttle — a check that silently declines because one ran two
        // minutes ago looks exactly like the feature not working.
        // The sheet needs a BuildContext; the app's global navigator key
        // is the only one an engine method can reach.
        {
          final ctx = AvatarMessageService.navigatorKey.currentContext;
          if (ctx != null) {
            unawaited(AppUpdateService.instance.check(ctx, force: true));
          } else {
            // NEVER LET "opening the installer" STAND WHEN NOTHING OPENED.
            // The tool has already spoken by the time this runs, so the
            // only honest move left is to correct it out loud.
            AppLog.add('update', 'no context to show the update sheet');
            AppFeedback.toast('Open the app first, then ask me to update.',
                spoken: true);
            _reportDeviceFailure('check_for_update', reason: 'no screen to show it on');
            await _tellModel(
                '[SYSTEM] ERROR: the update screen could NOT be opened on '
                'this phone, so nothing is installing. Tell me that '
                'plainly and say to open the app and ask again — do not '
                'claim the update started.');
          }
        }
        break;

      case 'show_news':
        // show_news: the headlines panel. The spoken half of the turn
        // arrives separately as sentences, so the list is up before the
        // assistant has finished the first line about it.
        newsItems = ((e['items'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(NewsItem.fromJson)
            .where((n) => n.title.isNotEmpty)
            .toList(growable: false);
        newsTopic = e['topic'] as String? ?? '';
        break;

      case 'news_focus':
        // read_news_story: bring the story being read to the front. A deck
        // closed moments ago, during this conversation, opens again for it.
        final focusId = e['id'] as String? ?? '';
        if (focusId.isEmpty) break;
        if (newsItems.isEmpty &&
            inlineVoice &&
            _closedNews.any((n) => n.key == focusId)) {
          newsItems = _closedNews;
          newsTopic = _closedNewsTopic;
        }
        newsFocus.value = NewsFocusRequest(focusId);
        break;

      case 'show_text':
        // present_text: a speech/script/draft Hari wrote — the reader
        // card shows it; the spoken line is only a pointer to the screen.
        final content = e['content'] as String? ?? '';
        if (content.isNotEmpty) {
          presentedTitle = e['title'] as String? ?? 'From ${AssistantIdentity.name}';
          presentedText = content;
        }
        break;

      // 2026-09-30 HOOK (features/briefing): play_daily_brief and
      // prepare_meeting. Returns at once; the brief plays on its own.
      case 'play_brief':
      case 'open_meeting_prep':
        await BriefingDirectives.handle(e);
        break;

      // 2026-09-30 HOOK (features/people): remember_address / show_address
      // — the owner asks for someone's address and "it should show us".
      // The sheet pops over the screen; the voice turn does not wait.
      case 'show_address':
        unawaited(AddressSheet.fromDirective(e));
        break;

      case 'show_image':
      case 'show_video':
        // generate_image / generate_video: the result is already saved as
        // a document server-side; its client JSON rides in the action.
        //
        // STRAIGHT TO FULL SCREEN, wherever the user is. It used to land
        // in a half-height card inside the conversation screen with the
        // prompt printed under it — so on Home, where that card does not
        // exist, the assistant announced an image nobody could see. The
        // gallery route pops over whatever is on top, the conversation
        // keeps running underneath and the mic stays hot.
        //
        // Exactly ONE presentation: no card, no prompt caption, nothing to
        // escalate. Two ways to show the same picture is where the glitches
        // were coming from.
        {
          final docJson = e['document'];
          // Several pictures of a person (2026-10-02): the gallery swipes
          // through all of them; `document` alone is the first.
          final many = e['documents'];
          final all = <UserDocument>[
            if (many is List)
              for (final d in many)
                if (d is Map) UserDocument.fromJson(d.cast<String, dynamic>()),
          ];
          if (docJson is Map || all.isNotEmpty) {
            final doc = all.isNotEmpty ? all.first : UserDocument.fromJson((docJson as Map).cast<String, dynamic>());
            final shown = onShowDocuments?.call(all.isNotEmpty ? all : [doc]) ?? false;
            if (!shown) {
              // No host to pop a gallery over (rare) — fall back to the
              // in-conversation card rather than dropping it silently.
              generatedImage = doc;
              generatedImagePrompt = e['prompt'] as String? ?? '';
            }
          }
        }
        break;

      case 'translator':
        // Interpreter: while on, the model translates each utterance
        // between the two languages instead of assisting.
        {
          final on = e['on'] == true;
          translatorActive = on;
          final a = (e['from'] as String?)?.trim() ?? '';
          final b = (e['to'] as String?)?.trim() ?? '';
          await _tellModel(on
              ? '[SYSTEM] INTERPRETER MODE ON between $a and $b. From now '
                  'until told otherwise, several different people will speak. '
                  'For each utterance you hear: if it is in $a, say it in $b; '
                  'if it is in $b, say it in $a. Speak ONLY the translation — '
                  'no commentary, no answering questions yourself, no '
                  'greetings. Keep names and numbers exact. If an utterance '
                  'is in neither language, translate it into $a.'
              : '[SYSTEM] INTERPRETER MODE OFF. Stop translating; go back '
                  'to being my assistant and respond only to me as usual.');
          AppFeedback.toast(on
              ? 'Translator on — everyone near the phone is heard.'
              : 'Translator off.');
        }
        break;

      case 'open_video':
        // Face-to-face video rode the live socket, which is gone: said
        // plainly rather than opening an empty room.
        _reportDeviceFailure('open_video', reason: 'face-to-face video is not in this version');
        await _tellModel('[SYSTEM] ERROR: face-to-face video is not available in '
            'this version of the app, so nothing opened. Say that plainly in '
            'one sentence.');
        break;
    }
    notifyListeners();
  }

  // ---------------- THE CAMERA AND PICTURES ----------------

  /// A photo from the camera or the gallery; null when the owner closed it.
  /// Throws when it would not open.
  static Future<XFile?> _pick(ImageSource source, {int quality = 82}) =>
      ImagePicker().pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: quality,
      );

  /// "WHAT IS THIS?" — the camera, then ONE brain turn with the photo and
  /// the owner's question, answered by the cloud model. The turn that asked for the camera
  /// has already answered; this is the next one. The microphone is held
  /// shut for the whole capture — the shutter, and whatever the owner
  /// mutters while framing the shot, are not a question.
  Future<void> _analyzeCamera(String question) async {
    XFile? shot;
    try {
      shot = await holdMicDuring(() => _pick(ImageSource.camera));
    } catch (e) {
      AppLog.add('vision', 'camera failed: $e');
      _reportDeviceFailure('analyze_camera', reason: 'the camera would not open');
      await _tellModel('[SYSTEM] ERROR: the camera could not be opened, so no '
          'photo was taken. Say so plainly in one sentence.');
      return;
    }
    if (shot == null) {
      await _tellModel('[SYSTEM] The owner closed the camera without taking a '
          'photo; nothing was looked at. Acknowledge in a few words.');
      return;
    }
    await _askWithPicture(shot, question);
  }

  /// Dashboard "Scan" button — same flow as the voice command, but entered
  /// deterministically: the camera opens immediately, no voice turn needed.
  Future<void> startScan() => _captureDocument('');

  /// LOOK AT A PICTURE THEY ALREADY HAVE (look_at_screenshot) and answer
  /// about it, as a turn with the picture. When it shows an upcoming event
  /// (an invite, a ticket, a booking), the model may put it on screen as
  /// one tap — a reminder or the phone's calendar — through an app-local
  /// tool offered only for this picture's turn.
  Future<void> _askAboutImage({
    required String question,
    String source = 'gallery',
  }) async {
    XFile? shot;
    try {
      shot = await holdMicDuring(() => _pick(
            source == 'camera' ? ImageSource.camera : ImageSource.gallery,
            quality: 85,
          ));
    } catch (e) {
      AppLog.add('vision', 'picker failed: $e');
      _reportDeviceFailure('look_at_screenshot', reason: 'the picker would not open');
      await _tellModel('[SYSTEM] ERROR: the gallery would not open, so NO image was '
          'read. Say so plainly.');
      return;
    }
    if (shot == null) {
      await _tellModel('[SYSTEM] The user closed the picker without choosing an image. '
          'Nothing was read. Acknowledge briefly and move on.');
      return;
    }
    await _askWithPicture(shot, question, offerEventCard: true);
  }

  /// THE "+" IN THE TYPE BAR (owner, 2026-09-30: "need one + icon there
  /// itself to upload or click images to ask my assistant"): a photo from
  /// the camera or the gallery, with whatever was typed as the question —
  /// one turn, answered out loud while the conversation is on. The
  /// microphone is held shut while the picker is up. False when the
  /// picker or the photo failed (the bar says so); true otherwise, closed
  /// without choosing included.
  Future<bool> askWithPhoto(ImageSource source, {String question = ''}) async {
    XFile? shot;
    try {
      shot = await holdMicDuring(() => _pick(source));
    } catch (e) {
      AppLog.add('vision', 'picker failed: $e');
      return false;
    }
    if (shot == null) return true;
    Uint8List bytes;
    try {
      bytes = await shot.readAsBytes();
    } catch (e) {
      AppLog.add('vision', 'photo unreadable: $e');
      return false;
    }
    final mime = shot.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    final image = AiAttachment(kind: 'image', mimeType: mime, bytes: bytes, path: shot.path);
    final ask = question.trim().isEmpty ? 'What is in this picture?' : question.trim();
    await _runTurn(ask,
        mode: BrainMode.chat, speak: _voiceOn || inlineVoice, image: image);
    return true;
  }

  /// The picture and the question as a turn of their own, once the turn
  /// that asked for it is over.
  Future<void> _askWithPicture(XFile shot, String question, {bool offerEventCard = false}) async {
    Uint8List bytes;
    try {
      bytes = await shot.readAsBytes();
    } catch (e) {
      AppLog.add('vision', 'photo unreadable: $e');
      await _tellModel('[SYSTEM] ERROR: the photo could not be read on the phone, so '
          'nothing was looked at. Say so and offer to try again.');
      return;
    }
    final mime = shot.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    final image = AiAttachment(kind: 'image', mimeType: mime, bytes: bytes, path: shot.path);
    final ask = question.trim().isEmpty ? 'What is in this picture?' : question.trim();
    // After the turn that opened the camera, never instead of it.
    while (_turnRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final remove = offerEventCard ? brain.localTools.register(_eventCardTool) : null;
    try {
      await _runTurn(ask, mode: BrainMode.voice, image: image, fromOwner: false);
    } finally {
      remove?.call();
    }
  }

  /// THE EVENT IN THE PICTURE, as one tap (build 2026-09-27's card, now
  /// filled by the model that saw the picture): offered to the cloud model
  /// only during a picked picture's turn.
  late final LocalTool _eventCardTool = LocalTool(
    spec: const AiToolSpec(
      name: 'offer_event_card',
      description: 'Call this when the picture shows an upcoming event (an '
          'invitation, a ticket, a booking, an appointment). It puts a card on '
          "the owner's screen that sets a reminder or adds the event to their "
          'phone calendar in one tap. Work out the date from today\'s date. '
          'Mention the card in a few words.',
      parameters: {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'What the event is.'},
          'startIso': {
            'type': 'string',
            'description': 'When it starts: ISO 8601 with the time zone offset.',
          },
          'endIso': {
            'type': 'string',
            'description': 'When it ends, if the picture says (ISO 8601).',
          },
          'location': {'type': 'string', 'description': 'Where, if the picture says.'},
        },
        'required': ['title', 'startIso'],
      },
    ),
    handler: (call) async {
      final event = VisionAction.fromJson({...call.args, 'type': 'calendar'});
      if (event == null || !event.isUpcoming()) {
        return const LocalToolResult.failed('That is not an upcoming event with a date.');
      }
      seenEvent = event;
      notifyListeners();
      return LocalToolResult(result: {
        'shown': true,
        'when': event.whenLabel(withYear: true),
      });
    },
  );

  /// Holds the microphone shut while [body] owns the screen — a picker, a
  /// signature pad — so the next turn is not shutter noise or a pen on
  /// glass. The conversation listens again when it is over.
  Future<T> holdMicDuring<T>(Future<T> Function() body) async {
    final wasHeld = _deviceFlowActive;
    _deviceFlowActive = true;
    if (!wasHeld) await _stopListening();
    try {
      return await body();
    } finally {
      if (!wasHeld) {
        _deviceFlowActive = false;
        _maybeListen();
      }
    }
  }

  /// Voice-driven document capture: open the camera or gallery, then file
  /// the shot into document memory with the owner's own words as the note
  /// (so "the receipt I saved after the doctor" is findable later).
  ///
  /// [person] is who the document BELONGS to ("save this scan for
  /// Prasant") — it lands in that person's records.
  Future<void> _captureDocument(String note,
      {int? clientId, String? person, String source = 'camera'}) async {
    XFile? shot;
    try {
      shot = await holdMicDuring(() => _pick(
            source == 'gallery' ? ImageSource.gallery : ImageSource.camera,
          ));
    } catch (_) {
      await _tellModel('Say this to me now, in my language: "I couldn\'t open the camera."');
      return;
    }
    if (shot == null) {
      await _tellModel('Say this to me now, in my language: "Okay, nothing saved."');
      return;
    }
    try {
      final bytes = await shot.readAsBytes();
      final result = await ApiService.uploadDocumentDetailed(
        bytes: bytes,
        filename: 'Capture.jpg',
        mimeType: 'image/jpeg',
        note: note,
        clientId: clientId,
        person: person,
      );
      documentCards = [result.document];
      notifyListeners();

      // Report WHERE the server actually filed it — never where we hoped.
      final String toast;
      final String spoken;
      if (result.filedUnderClient) {
        toast = "Saved to ${result.clientName}'s file.";
        spoken = "Saved to ${result.clientName}'s file.";
      } else if (result.clientCandidates.length > 1) {
        final names = result.clientCandidates.join(' and ');
        toast = 'Saved to your documents — "$person" matched $names.';
        spoken = 'Saved to your documents for now — $names both match '
            '"$person". Tell me which one and I\'ll file it.';
      } else if (person != null && person.trim().isNotEmpty) {
        toast = 'Saved to your documents — no client named "$person".';
        spoken = "I saved it to your documents, but I couldn't find a "
            "client or patient named $person. Add them from the Clients "
            "screen and I'll file it there.";
      } else {
        toast = 'Saved to your documents.';
        spoken = 'Saved to your documents. Ask me about it anytime.';
      }
      // Visible proof on WHATEVER screen the owner is on.
      AppFeedback.toast(toast, tone: FeedbackTone.success, spoken: true);
      // The assistant confirms the save itself AND knows to use
      // get_last_document for follow-ups ("what does it say?").
      await _tellModel(
          '[SYSTEM] I just scanned a document. Server result: "$spoken" '
          'It is being analyzed right now. If I ask to save/put/file '
          '"this" under a client or patient, call file_document_under_client '
          '(do not open the camera). When I ask about "the image/photo/'
          'document I just scanned" or what it says, call get_last_document '
          'and answer from its text. Now tell me the server result above '
          'in one short sentence, in my language.');
    } on DocumentUploadException catch (e) {
      final why = e.message.isNotEmpty
          ? e.message
          : 'the server refused the upload (${e.statusCode})';
      AppFeedback.toast("Couldn't save the scan — $why.", spoken: true);
      await _tellModel('[SYSTEM] ERROR: the scan was NOT saved — $why. Say that '
          'plainly in one sentence; nothing was saved.');
    } catch (_) {
      AppFeedback.toast("Couldn't save the scan — check your connection.", spoken: true);
      await _tellModel('[SYSTEM] ERROR: the scan could not be uploaded (no '
          'connection), so NOTHING was saved. Say so and suggest trying again.');
    }
  }

  /// True while a call flow is being handled entirely ON-DEVICE (live
  /// mode). confirm()/chooseContact() then act locally instead of posting
  /// to the SSE session, which knows nothing about this flow.
  bool _localCallFlow = false;

  /// The message to deliver / question to ask on the current local call
  /// flow ("call X and tell him …"), and whether the server can place the
  /// call itself (agent relay) so the user never has to talk.
  String? _localCallTask;
  bool _localCallAgentAvailable = false;

  /// How to place the pending call: 'phone' (normal), 'whatsapp' or
  /// 'whatsapp_video'. Set ONLY from what the user actually said — the
  /// two kinds of call are never substituted for each other.
  String _localCallVia = 'phone';
  int _localCallRetryTimes = 0;
  int _localCallRetryGap = 0;
  String? _localCallTone;

  String? _localCallVoice;
  /// The language the relayed message is to be spoken in ('ml' for
  /// Malayalam…), as the server worked it out when the user confirmed the
  /// read-back (2026-09-26). Null: the usual.
  String? _localCallLanguage;

  /// Live-mode "call X [and tell them Y]": resolve the name against the
  /// phone's contacts and act. The spoken yes already happened inside the
  /// live conversation — since 2026-09-26 a relayed message is read back
  /// word for word and confirmed before the server sends this — so a
  /// single match proceeds immediately, no second tap to approve.
  Future<void> _handleResolveAndCall(String name, String? message,
      {bool agentAvailable = false,
      String via = 'phone',
      int retryTimes = 0,
      int retryGapMinutes = 0,
      String? tone,
      String? language,
      String? voice}) async {
    if (name.trim().isEmpty) return;
    // Whatever the user decided about a no-answer. Zero means one
    // attempt — the assistant never invents a retry.
    _localCallRetryTimes = retryTimes;
    _localCallRetryGap = retryGapMinutes;
    _localCallTone = tone;
    _localCallVoice = voice;
    _localCallLanguage = language;
    _localCallTask = message;
    _localCallAgentAvailable = agentAvailable;
    _localCallVia = via;

    // EMERGENCY ("call an ambulance", "call 112"): skip contacts AND the
    // relay — the handset dials the short code itself, immediately.
    final sos = CallService.emergencyNumber(name);
    if (sos != null) {
      _localCallTask = null; // no message ever rides an emergency call
      await _actOnResolvedCall(
          ContactMatch(id: '', name: '${name.trim()} ($sos)', phone: sos));
      return;
    }

    // The user SPOKE a number ("call 6360139965") — the model passes it as
    // the name. Searching contacts for a digit string always fails; dial
    // it directly instead.
    final digits = name.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.replaceAll('+', '').length >= 7 &&
        digits.length >= name.trim().length - 4) {
      await _actOnResolvedCall(
          ContactMatch(id: '', name: name.trim(), phone: digits));
      return;
    }

    // No contacts permission = no lookup = no call. Say EXACTLY that —
    // the worst outcome is the assistant claiming a call it never made.
    if (!await CallService.instance.ensurePermission()) {
      AppFeedback.toast(
          'Contacts permission is off — the call to "$name" was NOT placed. '
          'Enable Contacts in Settings.',
          tone: FeedbackTone.error,
          spoken: true);
      await _tellModel(
          '[SYSTEM] ERROR: Contacts permission is turned off on this '
          'phone, so "$name" could not be looked up and NO call was '
          'placed. Tell me plainly that the call failed because contacts '
          'access is off, and that I should enable the Contacts '
          'permission in the phone settings. Do NOT say the call was '
          'made.');
      return;
    }

    List<ContactMatch> matches = const [];
    try {
      final found = await CallService.instance.findContacts(name);
      matches = [
        for (final c in found)
          if (CallService.instance.bestNumber(c).isNotEmpty)
            ContactMatch(
              id: c.id,
              name: c.displayName,
              phone: CallService.instance.bestNumber(c),
            ),
      ];
    } catch (_) {}

    // Device contacts had nothing — ask the SERVER, which knows the synced
    // address book, the client files, AND registered app users. This is
    // what lets "call Dhanush" work when he's saved under a nickname (or
    // only exists as an app user the caller knows by real name).
    if (matches.isEmpty) {
      try {
        final r = await ApiService.getJson(
            '/contacts/resolve?name=${Uri.encodeComponent(name.trim())}');
        final m = r?['match'];
        if (m is Map && (m['phone'] as String? ?? '').isNotEmpty) {
          matches = [
            ContactMatch(
              id: '',
              name: m['name'] as String? ?? name,
              phone: m['phone'] as String,
            ),
          ];
        } else {
          final cands = (r?['candidates'] as List?) ?? const [];
          matches = [
            for (final c in cands.whereType<Map>())
              if ((c['phone'] as String? ?? '').isNotEmpty)
                ContactMatch(
                  id: '',
                  name: c['name'] as String? ?? name,
                  phone: c['phone'] as String,
                ),
          ];
        }
      } catch (_) {}
    }

    if (matches.isEmpty) {
      // Tell whichever brain is running, so the assistant says it instead
      // of the user waiting on a call that can never come.
      AppFeedback.toast('No contact named "$name" found — no call placed.',
          spoken: true);
      await _tellModel(
          '[SYSTEM] ERROR: No contact named "$name" was found on the '
          'phone, so NO call was placed. Tell me that plainly — do NOT '
          'say the call was made.');
      return;
    }

    if (matches.length == 1) {
      await _actOnResolvedCall(matches.first);
      return;
    }

    // THE SAME PERSON SAVED THREE TIMES ("Ravi 1", "Ravi 2", "Ravi 3").
    //
    // Saying the FULL saved name is an instruction, not a guess: if
    // exactly one contact carries that name outright, dial it. Only a
    // bare "call Ravi" — which matches all three equally — is ambiguous.
    final spoken = CallService.instance.normalizedName(name);
    final exact = [
      for (final m in matches)
        if (CallService.instance.normalizedName(m.name) == spoken) m,
    ];
    if (exact.length == 1) {
      await _actOnResolvedCall(exact.first);
      return;
    }

    // Genuinely ambiguous. The agent ASKS — by voice, naming the options
    // exactly as they are saved so the answer ("Ravi 2") resolves to one
    // contact on the next turn. The picker still appears for a tap.
    _localCallFlow = true; // chooseContact routes back here
    ambiguousContacts = matches.take(6).toList();
    _pendingLookupName = name;
    notifyListeners();
    _offerContactPicker();

    final names = ambiguousContacts.map((c) => c.name).join(', ');
    await _tellModel(
        '[SYSTEM] "$name" matches ${ambiguousContacts.length} saved '
        'contacts: $names. NO call was placed. Ask the user which one '
        'you should call, in ONE short question that says the names as '
        'they are saved. When they answer, call place_phone_call again '
        'with that exact saved name.');
  }

  /// Acts on a resolved contact: agent relay (Hari speaks the message on
  /// the call herself) when a task + the server-side caller are available,
  /// else a plain direct dial for the user to talk.
  Future<void> _actOnResolvedCall(ContactMatch contact) async {
    HapticFeedback.mediumImpact();
    final task = _localCallTask;
    _localCallTask = null;

    // A WhatsApp call is placed BY THE PHONE, so the relay service (which
    // only dials normal numbers) is skipped entirely — _dialAndReport
    // below routes it to WhatsApp.
    final whatsapp = _localCallVia.startsWith('whatsapp');

    if (!whatsapp && task != null && task.isNotEmpty && _localCallAgentAvailable) {
      String? id;
      try {
        id = await ApiService.startAgentCall(
          toNumber: contact.phone,
          contactName: contact.name,
          task: task,
          retryTimes: _localCallRetryTimes,
          retryGapMinutes: _localCallRetryGap,
          tone: _localCallTone,
          voice: _localCallVoice,
          lang: _localCallLanguage,
        );
      } catch (_) {
        id = null; // unavailable / quota / network — fall through
      }
      if (id != null) {
        // The call is the assistant's now: followed to its real end, and
        // its outcome said then, as a turn of its own.
        unawaited(_followAgentCall(id, contact.name));
        await _tellModel('[SYSTEM] The assistant is now calling '
            '${contact.name} to deliver the message; the result comes when '
            'the call ends. Say that in one short sentence.');
        return;
      }
      // A MESSAGE CALL IS THE ASSISTANT'S CALL, NEVER THE PHONE'S
      // (2026-09-26). This used to fall through to a direct dial. The
      // owner asked it to call 6360139965 — his own number — with a
      // message; the server was slow to answer, the phone gave up after
      // 20 s and dialled the number from the handset, and the relayed
      // call then met a busy line. "Use agent call … when such request is
      // made." So nothing is dialled here: the user hears that the call
      // could not be placed and decides.
      await _tellModel(
          '[SYSTEM] ERROR: I could not place the call to ${contact.name} with '
          'the message just now, and NOTHING was dialled. Tell me that in one '
          'short sentence and ask whether you should try again. Do NOT '
          'dial them from my phone unless I ask for that myself.');
      return;
    }

    await _dialAndReport(contact);
  }

  Future<void> _handlePhoneControl(Map<String, dynamic> e) async {
    final dc = DeviceControlService.instance;
    final action = (e['action'] ?? '').toString();
    bool ok = false;
    String? report; // a [SYSTEM] line the model needs to answer with
    switch (action) {
      case 'flashlight_on':
        ok = await dc.torch(true);
      case 'flashlight_off':
        ok = await dc.torch(false);
      case 'volume_set':
        ok = await dc.volume('set', value: (e['value'] as num?)?.toInt() ?? 50);
      case 'volume_up':
        ok = await dc.volume('up');
      case 'volume_down':
        ok = await dc.volume('down');
      case 'mute':
        ok = await dc.volume('mute');
      case 'unmute':
        ok = await dc.volume('unmute');
      case 'media_play':
        ok = await dc.media('play');
      case 'media_pause':
        ok = await dc.media('pause');
      case 'media_next':
        ok = await dc.media('next');
      case 'media_previous':
        ok = await dc.media('previous');
      case 'battery':
        final pct = await dc.battery();
        ok = pct != null;
        report = pct != null
            ? '[SYSTEM] Battery is at $pct percent. Tell me in one short sentence.'
            : '[SYSTEM] ERROR: battery level could not be read.';
      case 'open_settings':
        ok = await dc.openPanel((e['panel'] ?? 'settings').toString());
      // THE RINGER AND DO NOT DISTURB (build 120, shortcuts). Android asks
      // the owner once, on its own page, before an app may silence the
      // phone: that page is opened (never flipped for him), and silent
      // falls back to vibrate meanwhile — said plainly, not claimed.
      case 'ringer_silent':
        final r = await dc.ringer('silent');
        if (r == 'needs_access') {
          // Vibrate first, so the phone is quiet while he decides.
          ok = await dc.ringer('vibrate') == 'ok';
          final opened = await _askDndAccess();
          report = ok
              ? '[SYSTEM] The phone is on VIBRATE, not silent: full silent needs Do Not '
                  'Disturb access${opened ? ' — it is the switch on the screen I opened' : ', which they can allow later'}. '
                  'Say that in one short line.'
              : null;
        } else {
          ok = r == 'ok';
        }
      case 'ringer_vibrate':
        ok = await dc.ringer('vibrate') == 'ok';
      case 'ringer_normal':
        ok = await dc.ringer('normal') == 'ok';
      case 'dnd_on':
      case 'dnd_off':
        final r = await dc.dnd(action == 'dnd_on');
        if (r == 'needs_access') {
          final opened = await _askDndAccess();
          ok = true; // nothing failed: it is waiting on his switch
          report = '[SYSTEM] Do Not Disturb was NOT changed: it needs Do Not Disturb '
              'access${opened ? ' — it is the switch on the screen I opened' : ', which they can allow later'}. '
              'Say that in one short line.';
        } else {
          ok = r == 'ok';
        }
      default:
        ok = false;
    }
    if (report == null && !ok) {
      report =
          '[SYSTEM] ERROR: the phone could not perform "$action" — tell me plainly.';
      AppFeedback.toast("Couldn't do that on this phone.", spoken: true);
      _reportDeviceFailure('phone_control', target: action,
          reason: 'the phone refused or could not do it');
    }
    if (report != null) await _tellModel(report);
  }

  /// Do Not Disturb access is asked for once per app run, IN the app first:
  /// Android's own page is a long list of every app, and dropping the owner
  /// there unannounced (2026-09-27) left him lost in Settings. He chooses;
  /// the switch on that page is always flipped by him, never for him.
  /// Returns true when Android's page was opened.
  bool _dndAccessAsked = false;
  Future<bool> _askDndAccess() async {
    if (_dndAccessAsked) return false;
    _dndAccessAsked = true;
    final ctx = AvatarMessageService.navigatorKey.currentContext;
    if (ctx == null || !_foreground) return false;
    final open = await showAppDialog<bool>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: const Text('Allow full silent?'),
        content: const Text('To put your phone fully on silent, allow "Do Not Disturb" '
            'for My Assistant once, then come back. Until then I use vibrate.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Use vibrate')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open settings')),
        ],
      ),
    );
    if (open != true) return false;
    _leftForExternalApp = true;
    return DeviceControlService.instance.openDndAccess();
  }

  /// True while the user is deliberately in ANOTHER app because we sent
  /// them there (Instagram, a map, a web page).
  bool _leftForExternalApp = false;
  DateTime? _backgroundedAt;

  /// Is the app actually on the user's screen right now?
  ///
  /// NOTHING THAT MAKES A SOUND OR OPENS A MICROPHONE MAY RUN WHEN THIS
  /// IS FALSE. He heard the listening chime twice while using WhatsApp,
  /// having never opened the assistant (2026-09-20).
  bool _foreground = true;

  /// The app went to the background: GO QUIET THE INSTANT IT LEAVES THE
  /// SCREEN — her voice stops mid-word and nothing listens (a phone in a
  /// pocket must not be listening to a conversation). A turn still being
  /// answered finishes silently; the conversation itself is left alone,
  /// so a caller back in two seconds finds it still there.
  void onAppPaused() {
    _foreground = false;
    _backgroundedAt = DateTime.now();
    // Location is only kept current while the app is on screen.
    _locationTicker?.cancel();
    _locationTicker = null;
    _sayEpoch++;
    _player.muted = true;
    unawaited(_player.stop().catchError((_) {}));
    unawaited(_bargeMade?.stop());
    if (_listening) unawaited(_stopListening());
  }

  /// The app came back to the foreground.
  Future<void> onAppResumed() async {
    // FIRST LINE, BEFORE ANY EARLY RETURN: a false left here would silence
    // every later chime for the rest of the app's life.
    _foreground = true;
    _player.muted = speakerMuted;
    // Back from the chat the shortcut opened: carry on with its next step.
    unawaited(ShortcutRunner.instance.resumePending(shortcutPorts));
    // Back on screen: where the owner is now (and every 5 minutes from
    // here), and any calls missed while they were away — for the card.
    _startLocationTicker();
    unawaited(_refreshLocation());
    unawaited(MissedCallsService.instance.check());
    final pausedAt = _backgroundedAt;
    final away = pausedAt == null ? Duration.zero : DateTime.now().difference(pausedAt);
    _backgroundedAt = null;
    final wasExternal = _leftForExternalApp;
    _leftForExternalApp = false;
    if (!_conversationOpen && !inlineVoice) return;
    // A resume with no matching pause is a UI flicker (a dialog, a
    // permission sheet), not a trip to another app.
    if (pausedAt == null) return;
    // WE SENT THEM SOMEWHERE ELSE, SO THE CONVERSATION IS OVER (his
    // report, 2026-09-21: back from the page he was sent to, the orb
    // should be a mic again, not a conversation). No chime: returning to
    // the app is not a gesture.
    if (wasExternal && away.inMilliseconds >= 800) {
      AppLog.add('voice', 'returned from another app — conversation ended');
      await leaveConversation(chime: false);
      notifyListeners();
      return;
    }
    // Otherwise the conversation simply listens again (there is no socket
    // to rebuild) — silently: it talks only when the owner does.
    _maybeListen();
  }

  /// Places the call and reports what ACTUALLY happened.
  ///
  /// The dialer returning true only means the intent was accepted, so the
  /// phone's own call state is the witness: a call that really starts
  /// within a few seconds is `connected`, otherwise `unconfirmed`. The
  /// result goes to the server (admin "Task outcomes") and to the model,
  /// so the assistant never claims a call it cannot prove.
  Future<void> _dialAndReport(ContactMatch contact) async {
    final who = contact.name.isEmpty ? 'them' : contact.name;

    // WHATSAPP WAS ASKED FOR BY NAME. It rings differently and costs the
    // other person data, so a normal call is never a silent substitute:
    // if WhatsApp can't place it, we say so and offer, never assume.
    if (_localCallVia.startsWith('whatsapp')) {
      final video = _localCallVia == 'whatsapp_video';
      _localCallVia = 'phone';
      final fail =
          await CallService.instance.whatsappCall(contact.phone, video: video);
      if (fail == null) {
        AppFeedback.toast('WhatsApp ${video ? 'video ' : ''}call to $who…',
            tone: FeedbackTone.progress);
        await _reportCallResult(who, 'connected');
        await _tellModel('[SYSTEM] WhatsApp is placing the '
            '${video ? 'video ' : ''}call to $who now.');
        return;
      }
      final why = CallService.whatsappFailure(fail, who);
      AppFeedback.toast(why, tone: FeedbackTone.error, spoken: true);
      await _reportCallResult(who, 'failed', reason: fail);
      await _tellModel('[SYSTEM] ERROR: $why Tell me that plainly and ask '
          'whether I want a normal phone call instead — do NOT place one '
          'on your own.');
      return;
    }

    // ANY OTHER APP THEY NAMED — Telegram, Signal, Viber, whatever is on
    // the phone. Same contract as WhatsApp above: an app was asked for by
    // name, so a normal call is never a silent substitute. The apps are
    // DISCOVERED from the contact rather than hardcoded, so this works for
    // anything installed (his ask, 2026-09-20).
    if (_localCallVia != 'phone' && _localCallVia.isNotEmpty) {
      final raw = _localCallVia;
      _localCallVia = 'phone';
      final video = raw.endsWith('_video');
      final app = video ? raw.substring(0, raw.length - 6) : raw;
      final res = await CallService.instance
          .callViaApp(contact.phone, app, video: video);
      if (res.reason == null) {
        final shown = res.app ?? app;
        AppFeedback.toast('$shown ${video ? 'video ' : ''}call to $who…',
            tone: FeedbackTone.progress);
        await _reportCallResult(who, 'connected');
        await _tellModel('[SYSTEM] $shown is placing the '
            '${video ? 'video ' : ''}call to $who now.');
        return;
      }
      final why = CallService.appCallFailure(res.reason!, who, app,
          available: res.available);
      AppFeedback.toast(why, tone: FeedbackTone.error, spoken: true);
      await _reportCallResult(who, 'failed', reason: res.reason ?? 'failed');
      await _tellModel('[SYSTEM] ERROR: $why Tell me that plainly and ask '
          'whether I want a normal phone call instead — do NOT place one '
          'on your own.');
      return;
    }

    bool ok = false;
    try {
      ok = await CallService.instance.call(contact.phone);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      AppFeedback.toast('The phone could not start the call to $who.',
          tone: FeedbackTone.error, spoken: true);
      await _reportCallResult(who, 'failed',
          reason: 'the phone could not start the call');
      await _tellModel(
          '[SYSTEM] ERROR: The phone could NOT start the call to $who — '
          'no call is happening. Tell me plainly.');
      return;
    }

    // Watch the phone's real call state briefly (the guard is already
    // running for TTS muting) before deciding what to report.
    var connected = false;
    for (var i = 0; i < 12; i++) {
      if (PhoneStateGuard.instance.inCall) {
        connected = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await _reportCallResult(who, connected ? 'connected' : 'unconfirmed',
        reason: connected ? '' : 'the phone never reported a call starting');
    await _tellModel(connected
        ? '[SYSTEM] The call to $who started on the phone.'
        : '[SYSTEM] The dialer opened for $who but the phone never '
            'confirmed a call started — do NOT claim the call happened.');
  }

  /// Records the true result of a call attempt on the account, so "did my
  /// call to Allen go through?" and the admin panel both see the same fact.
  Future<void> _reportCallResult(String who, String status,
      {String reason = ''}) async {
    try {
      await ApiService.sendJson('/outcomes', method: 'POST', body: {
        'kind': 'call',
        'target': who,
        'status': status,
        if (reason.isNotEmpty) 'reason': reason,
      });
    } catch (_) {}
  }

  /// Pops the duplicate-name picker and acts on the tap immediately.
  void _offerContactPicker() {
    final list = ambiguousContacts;
    if (list.isEmpty) return;
    final show = onPickContact;
    if (show == null) return;
    show(_pendingLookupName, List.of(list), (chosen) {
      ambiguousContacts = const [];
      notifyListeners();
      if (chosen == null) {
        // Dismissed: nothing is dialled, and the flow is closed out so the
        // assistant doesn't sit waiting on a choice that never comes.
        _localCallFlow = false;
        cancelAction();
        return;
      }
      chooseContact(chosen);
    });
  }

  /// Follows a server-placed relay call to its real end, keeping the
  /// call-status card honest and speaking the true outcome — never "done"
  /// unless the call actually landed.
  Future<void> _followAgentCall(String id, String who) async {
    callStatus = CallStatusInfo(status: 'dialing', contactName: who);
    notifyListeners();
    String state = 'failed';
    String? result;
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        final st = await ApiService.agentCallStatus(id);
        state = st.state;
        result = st.result ?? result;
      } catch (_) {
        continue; // transient poll failure — keep following
      }
      if (state == 'completed' || state == 'no_answer' || state == 'failed') {
        break;
      }
      callStatus = CallStatusInfo(status: state, contactName: who);
      notifyListeners();
    }
    callStatus = null;
    notifyListeners();
    final said = result ??
        (state == 'completed'
            ? 'The call to $who is done.'
            : state == 'no_answer'
                ? '$who did not pick up, so the message was not delivered.'
                : 'The call to $who did not go through.');
    await _tellModel(
        '[SYSTEM] The call to $who has ended. Result: $said Tell me this '
        'now in one short sentence, exactly as it happened.');
  }

  // ---------------- helpers ----------------

  /// Opens a provider deep link (Swiggy, Uber, …) and NEVER fails silently.
  ///
  /// The server wraps Android links as `intent://…;package=…;
  /// S.browser_fallback_url=…;end`, which url_launcher cannot always
  /// resolve — historically this call was fire-and-forget, so "order a
  /// biryani" could end with nothing on screen and no error anywhere.
  /// Now: try the intent as-is, then the https link into the provider's
  /// own app, then the browser — and if ALL of that fails, say so out
  /// loud instead of leaving the user waiting for food that isn't coming.
  /// A SAVED DOCUMENT IS NEVER A WEB PAGE.
  ///
  /// /docs/<id>/file needs the session token, so handing it to a browser
  /// produces "sign in required" — which is exactly what happened when
  /// the assistant was asked to open a metro map it had just saved
  /// (2026-09-20). The model builds that URL itself from context, so the
  /// guard belongs here, where every path converges, rather than in a
  /// prompt it might not follow. Returns the id when the URL is one of
  /// ours, so the caller can open it properly instead.
  static int? _ourDocumentId(String url) {
    if (!url.startsWith(ApiService.baseUrl)) return null;
    final m = RegExp(r'/docs/(\d+)/file').firstMatch(url);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// Shows one of our own documents through the SAME presenter the
  /// gallery and the generated-image card already use — so it opens in
  /// the app, with the session token attached, instead of in a browser
  /// that cannot authenticate.
  Future<void> _openOwnDocument(int id) async {
    try {
      final all = await ApiService.fetchDocuments();
      final doc = all.where((d) => d.id == id).firstOrNull;
      if (doc != null && (onShowDocuments?.call([doc]) ?? false)) return;
    } catch (_) {
      // fall through to the honest message
    }
    AppFeedback.toast('It is saved — open it from Hub, My documents.');
  }

  Future<void> _openExternalUrl(String url) async {
    final docId = _ourDocumentId(url);
    if (docId != null) {
      _leftForExternalApp = false; // staying in the app after all
      await _openOwnDocument(docId);
      return;
    }
    // AN INTENT URI IS NOT A WEB ADDRESS.
    //
    // Tools that reach the phone's own apps — the clock for alarms and
    // timers, the launcher for Home, an app's settings page — send
    // `intent://#Intent;action=…;end`, which has no host. This code used
    // to synthesise an https URL from that empty host and hand "https://"
    // to a browser: asking for an alarm at 5:50 opened Brave, and because
    // the tool had already reported success the assistant said the alarm
    // was set. It had not been.
    //
    // Intent URIs now go to the platform, which is what parses them. Only
    // a REAL fallback URL declared in the URI is ever opened as a page.
    // BOTH FORMS. The server used to emit `intent://#Intent;…` and now
    // emits `intent:#Intent;…` — the slashes made parseUri treat
    // everything before #Intent as a DATA uri, which no clock intent
    // filter matches. Testing that server change never exercised this
    // line, so the new URLs stopped matching here, skipped the native
    // launcher entirely and fell through to the web-link path, which
    // cannot open them. Matching the scheme rather than the slashes means
    // neither side can break the other again.
    if (url.startsWith('intent:')) {
      var launched = false;
      try {
        launched = await const MethodChannel('hari/intent')
                .invokeMethod<bool>('launch', {'uri': url}) ??
            false;
      } catch (e) {
        AppLog.add('intent', 'native launch failed: $e');
      }
      if (launched) return;

      final fb = RegExp(r'S\.browser_fallback_url=([^;]+);').firstMatch(url);
      if (fb != null) {
        // The URI itself named a web page to use instead — that one is
        // legitimate to open.
        await _openExternalUrl(Uri.decodeComponent(fb.group(1)!));
        return;
      }
      // Nothing on this phone can do it. Say so, and retract the record —
      // never open a browser as a consolation prize.
      final action =
          RegExp(r'action=([^;]+);').firstMatch(url)?.group(1) ?? 'that';
      AppFeedback.toast("This phone has no app that can do that.",
          tone: FeedbackTone.error, spoken: true);
      // NOTHING OPENED, SO NOBODY LEFT. The flag is set optimistically
      // before the launch is attempted; left true on a dead end it made
      // the NEXT ordinary interruption — a notification, a permission
      // sheet, a one-second screen lock — end the conversation instead
      // of resuming it. open_any_app already clears it on failure.
      _leftForExternalApp = false;
      _reportDeviceFailure('open_url',
          target: action, reason: 'no app on the phone can handle it');
      await _tellModel(
          '[SYSTEM] ERROR: nothing on this phone could perform "$action", so '
          'it did NOT happen — no alarm, timer or screen was opened. Tell me '
          'plainly that it failed and do not claim it worked.');
      return;
    }

    // An ordinary web or app link.
    var ok = false;
    // The provider's app claims its own https links (app links) — this
    // opens Swiggy itself rather than a browser tab when installed.
    try {
      ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalNonBrowserApplication);
    } catch (_) {}
    if (!ok) {
      try {
        ok = await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (!ok) {
      AppFeedback.toast(
          'Could not open the app for that — nothing was ordered or booked.',
          spoken: true);
      _leftForExternalApp = false; // the app never went anywhere
      // The server recorded this as done the moment it dispatched it. Tell
      // it the truth so the log stops claiming a success, and so the next
      // turn cannot say it opened.
      _reportDeviceFailure('open_url',
          target: url, reason: 'nothing could open that link');
      await _tellModel(
          '[SYSTEM] ERROR: The phone could not open the app for that action, '
          'so NOTHING was ordered, booked or opened. Tell me plainly that it '
          'failed.');
    }
  }

  /// The app's own screens that a voice command may open. Returning null
  /// for anything unknown is deliberate: the tool already validates its
  /// enum, and a screen that cannot be built must be reported as a
  /// failure rather than silently doing nothing.
  WidgetBuilder? _appScreenBuilder(String screen,
          [Map<String, dynamic> e = const {}]) =>
      switch (screen) {
        'meetings' => (_) => const MeetingsScreen(),
        // "Record this meeting" — straight into recording.
        'meeting_recorder' => (_) => MeetingRecorderScreen(
              autoStart: true,
              title: (e['title'] ?? '').toString(),
              participants: (e['participants'] ?? '').toString(),
            ),
        'reminders' => (_) => const RemindersScreen(),
        'call_notes' => (_) => const CallNotesScreen(),
        'documents' => (_) => const DocumentsScreen(),
        'clients' => (_) => const ClientsScreen(),
        'finance' => (_) => const FinanceScreen(),
        'stocks' => (_) => const StocksScreen(),
        'diagnostics' => (_) => const DiagnosticsScreen(),
        'mcp' => (_) => const McpServersScreen(),
        'news' => (_) => const NewsScreen(),
        // "Open my calendar": this app's own calendar, never Google's
        // (owner, 2026-09-30: it said Google Calendar was not connected).
        'calendar' => (_) => const CalendarScreen(),
        'focus' => (_) => const FocusScreen(),
        // "Send a video note to …" with no video recorded yet: the server
        // opens the place to record it (send_video_note, 2026-09-26).
        'avatar_identity' => (_) => const AvatarIdentityScreen(),
        // "Connect my Notion" (build 120).
        'connected_apps' => (_) => const ConnectedAppsScreen(),
        // "Show my shortcuts" (build 120).
        'shortcuts' => (_) => const ShortcutsScreen(),
        // "What's my bills email" (bills_email tool, build 120).
        'bills_email' => (_) => const BillsEmailScreen(),
        // "Show my shopping list" (shopping_list_show, build 124), or one
        // kind of it ("my grocery list").
        'shopping_list' => (_) => ShoppingListScreen(
              category: (e['category'] as String?)?.trim().isEmpty ?? true
                  ? null
                  : (e['category'] as String).trim(),
            ),
        _ => null,
      };

  /// shop_handoff: the first thing opens (in its app when it is installed,
  /// else the browser) and the notification offers the rest. The answer
  /// is what really happened — where it opened, or that nothing did.
  Future<void> _shopFromList(Map<String, dynamic> e) async {
    final h = ShopHandoff.fromJson(e);
    if (h == null) {
      _reportDeviceFailure('shop_from_list', reason: 'there was nothing to open');
      await _tellModel('[SYSTEM] ERROR: nothing from the shopping list could be opened on the '
          'phone, so NOTHING was opened, ordered or paid. Say so plainly in one sentence.');
      return;
    }
    // We are sending them to the shopping app on purpose (see open_url).
    _leftForExternalApp = true;
    final r = await ShopHandoffRunner.instance.start(h);
    final s = r.step;
    if (!r.opened || s == null) {
      _leftForExternalApp = false;
      _reportDeviceFailure('shop_from_list',
          reason: s == null ? 'no safe link to open' : 'nothing could open ${s.item.name}');
      await _tellModel('[SYSTEM] ERROR: the phone could not open '
          '${s == null ? 'any of those links safely' : s.item.name}, so NOTHING was opened, '
          'ordered or paid. Say so plainly in one sentence.');
      return;
    }
    // Inside the action it is its answer; outside one it needs no turn.
    if (Zone.current[_deviceReplyKey] is! _DeviceReply) return;
    final where = r.inApp ? s.label : 'the browser';
    final more = r.total > 1
        ? ' The notification on the phone offers the next of the ${r.total} things.'
        : '';
    await _tellModel('[SYSTEM] Opened ${s.item.name} in $where.$more Nothing is ordered or '
        'paid: they choose and pay in the app themselves.');
  }

  /// SOMETHING SHARED IN FROM ANOTHER APP, with the owner's choice of what
  /// to do with it ("Add to shopping list", build 124): one turn, answered
  /// out loud like a panel's button. What was shared is outside content,
  /// so the turn is untrusted — nothing is sent, paid or changed because
  /// the shared words ask.
  Future<void> askAboutShared(String text, {AiAttachment? image}) async {
    final t = text.trim();
    if (t.isEmpty && image == null) return;
    // After a turn already under way, never instead of it.
    for (var i = 0; i < 100 && _turnRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await _runTurn(t,
        mode: BrainMode.voice, image: image, untrusted: true, shared: true, fromOwner: false);
  }

  /// Performs one device action as if the server had just sent it — the
  /// shortcut runner's hands. Every action keeps its own honest reporting.
  Future<void> performDeviceAction(Map<String, dynamic> action) => _onEvent(action);

  /// The shortcut runner's view of this app.
  late final ShortcutPorts shortcutPorts = _EngineShortcutPorts(this);

  /// Whether a voice command can open [screen] (open_app_screen).
  @visibleForTesting
  bool canOpenAppScreen(String screen) => _appScreenBuilder(screen) != null;

  /// When the conversation was last closed for a task rather than by the
  /// owner: its last line ("On it…") is not an answer to keep on screen.
  DateTime? _quietEndAt;

  /// True once, just after a conversation closed for a task — read by the
  /// answer card (AnswerAfterglow). Stale after a few seconds, so a close
  /// nobody was watching cannot hide a later, real answer.
  @visibleForTesting
  void debugMarkQuietEnd() => _quietEndAt = DateTime.now();

  bool takeQuietEnd() {
    final at = _quietEndAt;
    _quietEndAt = null;
    return at != null && DateTime.now().difference(at) < const Duration(seconds: 5);
  }

  /// "Scan this visiting card" — the camera, the server's reading, and the
  /// result sheet (add to contacts / say hello / call). The microphone is
  /// held shut meanwhile, as for any camera flow.
  Future<void> _scanBusinessCard() async {
    await holdMicDuring(() async {
      final ctx = AvatarMessageService.navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) {
        _reportDeviceFailure('scan_business_card', reason: 'no screen to show the camera on');
        await _tellModel('[SYSTEM] ERROR: the card scanner could not open on '
            'this screen, so nothing was saved. Say so in ONE short sentence.');
        return;
      }
      final person = await BusinessCardFlow.scan(ctx);
      if (person == null) {
        _reportDeviceFailure('scan_business_card', reason: 'cancelled or unreadable');
        await _tellModel('[SYSTEM] The card scan was cancelled or could not be '
            'read, so nothing was saved. Say so in ONE short sentence.');
      } else {
        final company = (person['company'] ?? '').toString();
        await _tellModel('[SYSTEM] Saved ${person['name']}'
            '${company.isEmpty ? '' : ' of $company'} from the business card. '
            'Buttons to add them to phone contacts and say hello on WhatsApp '
            'are on screen. Confirm in ONE short sentence.');
      }
    });
  }

  /// A device action failed. Inside a turn, the action it belongs to is
  /// answered as a failure (the model says so; the server's record of the
  /// turn carries the outcome); outside one, it is logged.
  void _reportDeviceFailure(String tool, {String target = '', String reason = ''}) {
    AppLog.add('device',
        '$tool failed${target.isEmpty ? '' : ' ($target)'}${reason.isEmpty ? '' : ': $reason'}');
    final reply = Zone.current[_deviceReplyKey];
    if (reply is _DeviceReply) {
      reply.failed ??= 'the phone could not do it${reason.isEmpty ? '' : ': $reason'}';
    }
  }

  void dismissGeneratedImage() {
    generatedImage = null;
    generatedImagePrompt = '';
    notifyListeners();
  }

  /// User closed the web results.
  void dismissSearchResults() {
    if (searchResults.isEmpty && searchQuery == null && searchSuggestions.isEmpty) return;
    searchQuery = null;
    searchResults = const [];
    searchSuggestions = const [];
    notifyListeners();
  }

  /// User closed the written-piece reader card.
  void dismissPresentedText() {
    presentedTitle = null;
    presentedText = null;
    notifyListeners();
  }

  /// User closed the event card without acting on it.
  void dismissSeenEvent() {
    if (seenEvent == null) return;
    seenEvent = null;
    notifyListeners();
  }

  /// "Remind me" on the event card: an ordinary reminder at the event's
  /// time, the same one the Reminders screen makes. True when it was set.
  Future<bool> remindSeenEvent() async {
    final e = seenEvent;
    if (e == null || e.start == null) return false;
    try {
      await ApiService.createReminder(e.title, e.start);
      if (identical(seenEvent, e)) seenEvent = null;
      notifyListeners();
      AppFeedback.toast('Reminder set — ${e.title}, ${e.whenLabel()}.',
          tone: FeedbackTone.success);
      return true;
    } catch (err) {
      AppLog.add('vision', 'reminder from the picture failed: $err');
      AppFeedback.toast("Couldn't set that reminder — try again.");
      return false;
    }
  }

  /// "Add to calendar" on the event card: into the phone's own calendar.
  Future<bool> calendarSeenEvent() async {
    final e = seenEvent;
    if (e == null || e.start == null) return false;
    final ok = await PhoneCalendar.addEvent(
        title: e.title, start: e.start!, durationMin: e.durationMin);
    if (ok) {
      if (identical(seenEvent, e)) seenEvent = null;
      notifyListeners();
      AppFeedback.toast('Added to your calendar — ${e.title}, ${e.whenLabel()}.',
          tone: FeedbackTone.success);
    } else {
      AppFeedback.toast("Couldn't add it to your calendar — allow calendar "
          'access, or use Remind me.');
    }
    return ok;
  }

  /// The cards that belong to ONE answer — cleared when the next question
  /// starts. Separate from _resetTurn, which also tears down turn state
  /// that a live session manages itself.
  void _clearAnswerCards() {
    if (searchResults.isEmpty &&
        searchSuggestions.isEmpty &&
        documentCards.isEmpty &&
        presentedText == null &&
        generatedImage == null) {
      return;
    }
    searchQuery = null;
    searchResults = const [];
    searchSuggestions = const [];
    documentCards = const [];
    presentedTitle = null;
    presentedText = null;
    generatedImage = null;
    generatedImagePrompt = '';
    notifyListeners();
  }

  void _resetTurn() {
    errorMessage = null;
    searchQuery = null;
    searchResults = const [];
    searchSuggestions = const [];
    documentCards = const [];
    generatedImage = null;
    generatedImagePrompt = '';
    presentedTitle = null;
    presentedText = null;
    foundContact = null;
    ambiguousContacts = const [];
    pendingConfirmation = null;
    seenEvent = null;
    callStatus = null;
    activities.clear();
    activityLabel.value = null;
    notifyListeners();
  }

  void _setPhase(AssistantPhase p, {bool silent = false}) {
    phase = p;
    _armWatchdog();
    _armIdleStop(p);
    notifyListeners();
    if (!silent) _haptic(p);
  }

  /// A SESSION THAT NOBODY IS TALKING TO ENDS ITSELF: a minute after the
  /// last turn completed with the conversation resting (not listening),
  /// the inline session closes on its own; any real activity re-arms the
  /// clock. The listening loop has its own quiet minute ([quietClose]).
  Timer? _idleStop;
  static const _idleStopAfter = Duration(seconds: 60);

  void _armIdleStop(AssistantPhase p) {
    _idleStop?.cancel();
    _idleStop = null;
    if (!inlineVoice || !liveActive) return;
    if (p != AssistantPhase.idle && p != AssistantPhase.completed) return;
    // Someone with the keyboard open is not "nobody" (tester run,
    // 2026-10-01: the session closed under a typist as "a minute of quiet").
    if (_typing) return;
    _idleStop = Timer(_idleStopAfter, () {
      if (!inlineVoice || !liveActive || _typing) return;
      if (phase != AssistantPhase.idle && phase != AssistantPhase.completed) {
        return;
      }
      if (_sessionWaiting) return;
      AppLog.add('voice', 'idle ${_idleStopAfter.inSeconds}s — ending session');
      unawaited(_closeAfterQuiet());
    });
  }

  /// Something outside the conversation is still going: a card waiting on
  /// the owner's TAP (a confirmation, a contact pick, the camera), a phone
  /// call, or a call the assistant placed to a business or a contact. That
  /// last one can run for minutes, and its outcome comes back to this
  /// conversation — closed, the owner would never hear what they said.
  bool get _sessionWaiting =>
      pendingConfirmation != null ||
      ambiguousContacts.isNotEmpty ||
      _deviceFlowActive ||
      PhoneStateGuard.instance.inCall ||
      callStillRunning(_callStatus, _callStatusAt, DateTime.now());

  /// Closes cleanly with a short caption and no spoken goodbye.
  Future<void> _closeAfterQuiet() async {
    await endInlineConversation();
    if (_foreground) AppFeedback.toast('Closed after a minute of quiet.');
  }

  // ---------------- WHERE THE OWNER IS ----------------

  Timer? _locationTicker;

  /// Every 5 minutes while the app is on screen (owner, 2026-09-24: "my
  /// assistant should be aware of user location when he makes any
  /// requests"). Every turn carries the latest fix (the brain's
  /// deviceContext).
  void _startLocationTicker() {
    _locationTicker?.cancel();
    _locationTicker = Timer.periodic(
        const Duration(minutes: 5), (_) => unawaited(_refreshLocation()));
  }

  Future<void> _refreshLocation() async {
    try {
      await LocationService.instance.refresh();
    } catch (_) {}
  }

  /// A request that needs the owner's position, with location unknown.
  void _maybeAskLocationFor(String text) {
    if (ApiService.geoLat != null) return;
    if (!LocationService.needsHere(text)) return;
    unawaited(_maybeAskLocation());
  }

  bool _askingLocation = false;

  /// ASKED ONCE, EVER: a one-line explainer and Android's dialog, the
  /// first time a request needs the owner's location and cannot have it.
  /// LocationService remembers that it asked. The next turn carries the
  /// new permission and the fix, so the tools that need them are offered.
  Future<void> _maybeAskLocation() async {
    if (_askingLocation || ApiService.geoLat != null) return;
    _askingLocation = true;
    try {
      final wasOn = await LocationService.instance.granted();
      if (wasOn) return; // allowed, just no fix yet — nothing to ask
      final ok = await LocationService.instance
          .askOnce(explain: (line) => AppFeedback.toast(line));
      if (!ok) return;
      await _refreshLocation();
      AppFeedback.toast('Location is on — ask me again.');
    } catch (_) {
    } finally {
      _askingLocation = false;
    }
  }

  // ---------------- CALL HISTORY ----------------

  static const _kCallLogExplained = 'call_log_explained';

  /// The `call_log` device action: read the phone's call history and hand
  /// the assistant ONE line — counts, names, local times, at most five
  /// people. Call history is asked for here, the first time it is needed,
  /// with a one-line explainer; a refusal is told to the model plainly so
  /// it never guesses.
  Future<void> _answerCallLog(Map<String, dynamic> e) async {
    const filters = {'missed', 'all', 'incoming', 'outgoing'};
    final f = (e['filter'] ?? '').toString().toLowerCase().trim();
    final filter = filters.contains(f) ? f : 'all';
    final person = (e['person'] ?? '').toString().trim();
    final hours = ((e['since_hours'] as num?)?.round() ?? 24).clamp(1, 720);
    // How many the owner asked for ("my last 3 calls"); never more than
    // five people in the line.
    final limit = ((e['limit'] as num?)?.round() ?? 10).clamp(1, 50);
    if (!Platform.isAndroid) {
      await _tellModel('[SYSTEM] ERROR: this phone does not let apps read '
          'its call history, so NO calls were read. Say that plainly in one '
          'sentence — do not guess any calls.');
      return;
    }
    if (!await CallHistory.canRead()) {
      var explained = false;
      try {
        final p = await SharedPreferences.getInstance();
        explained = p.getBool(_kCallLogExplained) ?? false;
        if (!explained) await p.setBool(_kCallLogExplained, true);
      } catch (_) {}
      if (!explained) {
        AppFeedback.toast('To tell you who called, allow call history.');
      }
      final r = await CallHistory.requestCallLog();
      AppLog.add('calls', 'call history permission: $r');
      if (r != 'granted') {
        _reportDeviceFailure('phone_calls',
            target: filter, reason: 'call history permission is off');
        final where = r == 'blocked'
            ? ' in the phone settings (App info, then Permissions)'
            : '';
        await _tellModel('[SYSTEM] ERROR: call history permission is off on '
            'this phone, so I could NOT read any calls. Tell me plainly in '
            'one sentence that I need to allow Call logs for the '
            'assistant$where. Do NOT guess or invent any calls.');
        return;
      }
      // Just allowed: the Missed calls card can fill in too.
      unawaited(MissedCallsService.instance.check(force: true));
    }
    final now = DateTime.now();
    List<CallEntry> calls;
    try {
      calls = await CallHistory.recent(
        filter: filter,
        person: person,
        since: now.subtract(Duration(hours: hours)),
        limit: 200,
      );
    } catch (err) {
      AppLog.add('calls', 'call history read failed: $err');
      _reportDeviceFailure('phone_calls',
          target: filter, reason: 'the call history could not be read');
      await _tellModel('[SYSTEM] ERROR: the call history could not be read '
          'just now, so NO calls were read. Say that plainly — do not guess '
          'any calls.');
      return;
    }
    // Missed calls the owner has now heard about are not greeted again.
    MissedCallsService.instance
        .markMentioned(calls.where((c) => c.type == 'missed'));
    await _tellModel(CallHistory.summaryLine(
      calls: calls,
      filter: filter,
      person: person,
      sinceHours: hours,
      now: now,
      maxPeople: limit,
    ));
  }

  void _setLocalError(String message) {
    _stuckWatchdog?.cancel();
    _stuckWatchdog = null;
    errorMessage = message;
    phase = AssistantPhase.error;
    notifyListeners();
  }

  void _haptic(AssistantPhase p) {
    switch (p) {
      case AssistantPhase.waitingForConfirmation:
      case AssistantPhase.inCall:
        HapticFeedback.mediumImpact();
      case AssistantPhase.completed:
        HapticFeedback.lightImpact();
      case AssistantPhase.error:
        HapticFeedback.heavyImpact();
      default:
        break;
    }
  }
}

/// One caption line: who is talking and the text so far this turn.
class CaptionLine {
  final String speaker; // 'you' | 'hari'
  final String text;
  const CaptionLine(this.speaker, this.text);
}

/// The shortcut runner's hands in the app: each step goes through the
/// engine's own device-action switch; a step that has to wait for the
/// owner gets a notification (Android lets an app open another only while
/// it is on screen).
class _EngineShortcutPorts implements ShortcutPorts {
  _EngineShortcutPorts(this.engine);
  final AssistantEngine engine;

  @override
  Future<void> perform(Map<String, dynamic> action) async =>
      unawaited(engine.performDeviceAction(action));

  @override
  // Android only lets an app open another app while it is in front; the
  // runner keeps the rest for the owner's return.
  Future<bool> canLaunchFromBackground() async => false;

  @override
  Future<void> notifyContinue(ShortcutRunDirective d, ShortcutEnvelope next) =>
      ReminderNotifications.instance.showNow(d.name, 'Tap to carry on: ${next.label}');

  @override
  Future<void> notifyUnfinished(String name, String label) =>
      ReminderNotifications.instance.showNow(name, "I didn't finish: $label");

  @override
  Future<void> wait(Duration d) => Future<void>.delayed(d);
}

/// The answer owed to the brain for one device action: given once. A
/// failure reported while it runs turns a plain "done" into that failure.
class _DeviceReply {
  _DeviceReply(this._respond);

  final void Function(DeviceOutcome outcome) _respond;
  bool answered = false;
  String? failed;

  void answer(DeviceOutcome outcome) {
    if (answered) return;
    answered = true;
    final why = failed;
    _respond(outcome.ok && why != null ? DeviceOutcome.failed(why) : outcome);
  }
}
