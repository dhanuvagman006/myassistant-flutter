# PROJECT_STATUS.md — MYASSISTANT (Flutter app)
_Handoff document · updated 16 July 2026 · read together with the same file in `MYASSISTANT_BACKEND`_

## What this project is
"MYASSISTANT / Hari" — a voice-first personal AI assistant app (Flutter, Android-first with iOS reference)
per the client's Project Scope document (45 features, groups A–M) and UI Design V1.0
(Peacock `#0F6B66` / Marigold `#F6A21E` / Ink `#0E1B1D` / Mist `#F2F6F5`, Sora + Inter fonts, "bloom orb").
Backend is a separate repo: `MYASSISTANT_BACKEND` (Node/Express, Gemini provider, Dockerised).

## Repo layout
```
lib/
├── main.dart                  # 5-tab shell (Assistant/Chat/Today/Calls/You), announcement banner, haptics
├── theme/app_theme.dart       # FULL light + dark themes, Sora/Inter via google_fonts
├── models/                    # ChatMessage, RemoteConfig
├── services/
│   ├── api_service.dart       # BASE_URL via --dart-define; /chat, /config, warm() ping
│   ├── voice_service.dart     # speech_to_text capture + fallback wake watching + flutter_tts
│   ├── assistant_controller.dart  # SINGLETON brain: wake→listen→answer→speak loop, UI-independent
│   └── update_service.dart    # Play in-app update / App Store link
├── widgets/                   # update_button, coming_soon (empty-state)
└── screens/                   # 8 screens; Chat + Voice Home are LIVE, rest are honest empty states
assets/icon/                   # generated bloom-orb app icon + adaptive foreground
assets/wake/                   # PLACE hey_hari_android.ppn HERE (Porcupine model, user-trained)
```
Note: `android/`/`ios/` folders are NOT in the repo — generated locally once with
`flutter create . --platforms=android,ios --org com.myassistant`.

## Done so far (chronological)
1. **Build fix** — `CardTheme` → `CardThemeData` (Flutter 3.27+ breaking change).
2. **Full redesign per UI Design V1.0** — brand theme (light **and** dark, fully specified:
   cards, chips, nav bar, inputs, buttons), Sora headlines/Inter body, brand mark in app bar,
   marigold announcement banner.
3. **All mock data removed** — no fake user "Arjun", gold rates, HDFC bill, fake devices/memories.
   Daily/Inbox/Smart-Home/Docs/Calls use a shared `ComingSoon` widget; Privacy shows real
   "Nothing yet / Not connected" states with disabled Export/Erase.
4. **App icon** — bloom-orb PNGs generated in `assets/icon/`, wired via `flutter_launcher_icons`
   (run `dart run flutter_launcher_icons` once locally).
5. **Dark-mode + layout fixes** — theme-aware colors everywhere (was white-on-white chips),
   orb layout via LayoutBuilder, SafeArea, haptic feedback (orb/chips/tabs/send).
6. **Voice loop LIVE** — "Hey Hari" wake word → capture question (live partial transcript)
   → backend `/chat` → answer shown in transcript card **and spoken via TTS**; conversation
   context kept; orb tap = instant listen; tap while speaking = interrupt.
7. **Screen-off architecture** — `AssistantController` singleton runs the loop independent of UI.
   Two wake engines: **Porcupine** (on-device, ~100 ms, screen-off; needs user-trained
   `assets/wake/hey_hari_android.ppn` + `--dart-define=PICOVOICE_ACCESS_KEY=...`) with automatic
   fallback to Android-recognizer transcript watching (foreground-only). Microphone
   **foreground service** via `flutter_foreground_task` keeps the process alive with screen off.
   Backend warm-up ping fires the instant the wake word triggers (latency).
8. **Battery toggle** — wake-word switch persists via shared_preferences; OFF releases mic and
   stops the foreground service entirely.
9. **API fix** — flutter_foreground_task 8.17 signatures (TaskStarter / eventAction).

Last commit at time of writing: `3e04298` on `main`.

10. **Natural multilingual voice** (barge-in was added then REMOVED at user request — too many false triggers on-device; tap-to-interrupt only now) (voice_service.dart, assistant_controller.dart, voice_home_screen.dart):
    - TTS picks the most human voice installed per language (scores neural/wavenet/network
      voices above the robotic "local" defaults) — best free upgrade; a cloud TTS
      (ElevenLabs / Google Cloud) via a backend /tts endpoint is the next step if the
      client wants studio-grade voices.
    - Every reply's language is auto-detected (all Indic scripts + CJK/Cyrillic/Arabic/etc.
      by Unicode ranges; Latin languages by stop-word vote, default en-IN) and the TTS
      voice switches to match.
    - BARGE-IN: while Hari speaks, the recognizer stays open; an echo filter (novel-word
      check vs. the reply text, wake word always passes) detects real user speech, cuts
      TTS mid-sentence, and the same recognition session becomes the next question —
      continuous conversation loop in _answerLoop().
      ⚠️ Caveat to test on device: some Android builds duck/mute TTS while SpeechRecognizer
      is active. If TTS is quiet during barge-in on the test phone, gate barge-in behind a
      flag or move to a raw-audio VAD approach.
    - Multilingual HEARING: "I speak…" language picker (globe pill on Voice Home) —
      Auto (device) + every recognizer locale, searchable, persisted (stt_locale_id).
    - Backend system prompt updated: reply in the user's language & script, 1–3 spoken
      sentences, no markdown/emojis (replies are read aloud).

11. **Regional language from location** (region_language.dart) — on first run (Auto mode),
    coarse location -> platform geocoder -> Indian state -> language (Karnataka=kn, Kerala=ml,
    TN=ta, AP/TG=te, MH=mr, GJ=gu, PB=pa, WB=bn, Hindi belt=hi, plus country map for abroad),
    validated against the device recognizer's supported locales. Pill shows "Auto · Kannada".
    User's manual pick in the "I speak…" sheet always overrides. Needs
    ACCESS_COARSE_LOCATION in the local AndroidManifest (README updated) and
    `flutter pub get` (new deps: geolocator, geocoding).

12. **Cloud STT (Whisper via Groq)** — device recognizer kept mishearing Kannada as English
    on the test phone, so question capture is now CLOUD-FIRST: app records m4a (record +
    path_provider, silence-stop at 1.6s quiet / 15s max) -> backend POST /stt (multer ->
    Groq whisper-large-v3-turbo, verbose_json) -> {text, language}. Whisper auto-detects the
    language, so no locale is needed for capture. Device STT remains for the wake word and
    as fallback (recorder unavailable / server down -> user repeats once). Run
    `flutter pub get`; backend needs `npm install` + restart (new dep: multer).

## ⚠️ CURRENT STATE / OPEN ISSUE — resume here
- User's last `flutter run` after commit `3e04298` produced **"long lengthy errors" that were
  NOT yet shared or diagnosed**. First suspects, in order:
  1. Stale caches after adding native plugins → `flutter clean && flutter pub get`.
  2. Porcupine/foreground-task Gradle requirements in the LOCAL `android/` folder:
     `minSdkVersion` (Porcupine needs ≥ 21, speech plugins may want ≥ 23 — check
     `android/app/build.gradle(.kts)`), Kotlin/AGP version, `Namespace not specified`,
     or **Manifest merger failed**.
  3. Manifest entries possibly missing/mistyped (see README "Screen-off wake word" section):
     RECORD_AUDIO, FOREGROUND_SERVICE, FOREGROUND_SERVICE_MICROPHONE, POST_NOTIFICATIONS,
     WAKE_LOCK, speech `<queries>`, and the flutter_foreground_task `<service>` block with
     `android:foregroundServiceType="microphone"`.
  Ask the user for the FIRST `Error:` lines + the "What went wrong:" section.

## Not done yet / roadmap
- Resolve the build error above; verify full screen-off wake flow on the Samsung F15
  (battery → Unrestricted is REQUIRED on One UI).
- User still needs to: train "Hey Hari" on console.picovoice.ai → drop `.ppn` in `assets/wake/`.
- Deploy backend to Render (guide already given; free tier cold-start hurts voice latency —
  suggest paid instance or uptime pinger; contract wants India region for production).
- GitHub Actions: build APK on push → GitHub Release; wire update button to it (Layer-2 updates).
- Features not started: Daily briefing (Calendar), Inbox digest (Gmail), Documents/OCR,
  AI phone calling, Smart home, real memory/privacy data, Google Sign-In (F1 — backend auth
  middleware already supports Google ID tokens when AUTH_DISABLED=false).
- X-App-Key header not yet sent by `api_service.dart` (backend dev mode has AUTH_DISABLED=true).

## How to run (dev)
```bash
# backend on the laptop first (see backend repo), then:
flutter pub get
flutter run --dart-define=BASE_URL=http://<LAPTOP_LAN_IP>:3000 \
            --dart-define=PICOVOICE_ACCESS_KEY=<optional>
# physical device over http needs android:usesCleartextTraffic="true" (dev only)
```

## Security notes for the next session
- A GitHub PAT was pasted into a previous chat and used for pushes; it must be **revoked/rotated**
  (github.com → Settings → Developer settings). Never commit it; use a fresh token per session.
- AI keys live ONLY in the backend `.env`; the app never holds provider keys.

## Update — 19 July 2026: Memory feature (app side)
- **`models/memory_item.dart`** — MemoryItem (id, category, key, value, source,
  updatedAt) + display title helper.
- **`services/api_service.dart`** — `fetchMemories / addMemory / deleteMemory /
  clearMemories` against the backend's new `/memory` routes (session JWT).
- **`screens/privacy_screen.dart`** — "WHAT I REMEMBER" is now LIVE: lists every
  fact with a category icon and per-row forget button, "Teach Hari something"
  dialog (saves with source=user), and confirmed "Forget all". Signed-out and
  offline states handled. No client changes needed for personalization itself —
  the backend injects memory into every /chat reply automatically.

## Update — 19 July 2026 (2): Greeting + location + mic reliability fixes
- **Greeting on sign-in/app open** — `AssistantController.greetOnLaunch()`
  (triggered from Voice Home after init, once per signed-in user): fetches
  /chat/greeting, speaks it, adds it to conversation history; if it ends with a
  question the mic opens automatically so the answer teaches the memory
  extractor. Re-greets when a different account signs in.
- **Location actually accessed now** — `_detectRegionalLanguage` order flipped:
  GPS (`RegionLanguage.candidates()`, triggers the permission dialog) FIRST,
  IP lookup only as fallback. New `RegionLanguage.currentCity()` reverse-geocodes
  "City, State" and it's saved to memory as `current_city` once per session.
  ⚠ Requires ACCESS_COARSE_LOCATION (+ RECORD_AUDIO) in the locally generated
  android/AndroidManifest.xml — android/ is not in the repo.
- **Mic fixes** (the "turns on/off, doesn't recognise" bug):
  1. VAD thresholds were fixed at −30 dBFS — quiet mics never triggered. Now
     ADAPTIVE: ~600 ms ambient calibration, speech = floor +8 dB (clamped
     −55…−22), no-speech window 6→8 s, live `micLevel` 0..1 for the orb.
  2. When the VAD heard nothing, capture DEAD-ENDED. Now it falls back to the
     device recognizer (unless the user cancelled — `lastRecordingCancelled`).
  3. 250 ms mic hand-off delay between stopping wake recognition and starting
     the recorder (they were fighting over the mic).
  4. `VoiceService.reinit()` — mic permission granted after first denial no
     longer requires an app restart (`ask()` retries init).

## Update — 19 July 2026 (3): Voice-reactive orb
- `_BloomOrb` now takes `level` (AssistantController.micLevel, 0..1, both
  capture paths — cloud recorder amplitude AND device recognizer
  onSoundLevelChange). While listening: marigold voice halo blooms with
  loudness, rings and core scale up, glow deepens/spreads. Samples (~5 Hz)
  smoothed with a 180 ms TweenAnimationBuilder so motion is fluid.

## Update — 19 July 2026 (4): Sign-up interview
- **`screens/interview_screen.dart`** — one-time voice onboarding for NEW
  accounts: Hari speaks 4 friendly questions (name, city, work/study, loves),
  auto-listens after each (cloud STT → device fallback, mic level animates the
  indicator), answers editable as text, per-question Skip + top-right "Skip all",
  then lands on the home shell.
- **Routing** — auth responses now carry `isNew` (backend: signup=true, social
  upsert reports `created`); `AuthService.lastSignInWasNew` drives the gate in
  main.dart: AuthScreen → InterviewScreen (new accounts only) → HomeShell.
- **Answer storage** — each answer POSTs to `/memory/interview`, which runs the
  memory extractor with `force:true` (no throttle); if extraction yields nothing
  (e.g. no AI keys) the raw answer is stored keyed by the question, so nothing
  is lost. After the interview the greeting is naturally personal.

## Update — 19 July 2026 (5): Assistant tools (app side)
- **Voice reminders end-to-end** — /chat now sends X-TZ-Offset + X-Geo-Lat/Lng;
  backend intents create reminders; after every answer the app resyncs and
  (re)schedules LOCAL notifications (`services/notification_service.dart`,
  flutter_local_notifications + timezone + flutter_timezone; exact alarms,
  boot-persistent). ⚠ Manifest additions required — documented in the service
  header (POST_NOTIFICATIONS, SCHEDULE_EXACT_ALARM, two receivers).
- **Today screen LIVE** (`screens/daily_screen.dart` rewrite): weather card
  (now + 3-day, icons), reminders with add(+ date/time picker)/complete/delete
  synced to /reminders, top headlines. Pull-to-refresh.
- `models/reminder.dart`; ApiService: reminders CRUD, fetchWeather, fetchNews;
  RegionLanguage caches lastLat/lastLng → ApiService.geo.

## Update — 19 July 2026 (6): Gmail + Calendar (app)
- AuthService.linkGoogleData() — data-scopes GoogleSignIn (gmail.readonly +
  calendar.readonly, forceCodeForRefreshToken) → serverAuthCode → /google/connect.
- Inbox screen LIVE: connect CTA when unlinked; connected: recent primary
  emails (unread bold + marigold dot), pull-to-refresh, disconnect.
- Today screen: CALENDAR card (next 2 days) when linked.
- ApiService: connectGoogle/googleConnected/disconnectGoogle/fetchGmailInbox/
  fetchCalendarEvents (null = not linked). Voice answers "any new emails?" /
  "what's my schedule?" from real data.

## Update — 19 July 2026 (7): Voice calling (B1)
- **`services/call_service.dart`** — fully ON-DEVICE (contacts never reach the
  backend): call-intent patterns (English "call/dial/phone/ring X", Hinglish
  "X ko call karo", Hindi "X को कॉल", Kannada "Xಗೆ ಕರೆ ಮಾಡು"), fuzzy contact
  matching (exact>word>prefix>contains, nicknames included, keeps close calls
  within 20 pts), mobile-number preference, direct dial via
  flutter_phone_direct_caller with tel: dialer fallback.
- **Controller** — `_handleCallIntent` runs BEFORE the AI in _answerOnce:
  1 match → "Calling X…" + dial; several → Hari lists them, opens the mic, the
  reply picks by name or ordinal ("the first one"), "cancel/rehne do" aborts;
  none → spoken not-found / permission hint.
- **Calls screen LIVE** — searchable contact list (name/number), starred
  Favourites pinned, tap-to-call, multi-number picker sheet, permission
  denied state with retry.
- deps: + flutter_contacts, flutter_phone_direct_caller.
  ⚠ Manifest: READ_CONTACTS + CALL_PHONE (Android); NSContactsUsageDescription
  (iOS; iOS always shows the tel: confirmation — platform rule).

## Fix — 19 July 2026: notification build failure
- timezone ^0.9.4 → ^0.10.0. The 0.9 pin made pub downgrade
  flutter_local_notifications to v17 (whose zonedSchedule requires
  uiLocalNotificationDateInterpretation), breaking the v18-style call in
  notification_service.dart. With timezone 0.10, fln resolves to 18 and the
  existing code compiles. Run: flutter clean && flutter pub upgrade.
- KGP warnings from plugins are non-blocking on current Flutter.

## Change — 19 July 2026: removed flutter_foreground_task
- Its hard-coded Java 1.8 target fights AGP 9's JVM-target validation and kept
  breaking builds. Removed the dependency and the whole foreground-service
  section from assistant_controller (service start/stop, wakeServiceCallback,
  _KeepAliveHandler). TRADE-OFF: no screen-off wake word for now — wake word
  works while the app is open. Revisit when the plugin ships a Built-in-Kotlin
  / JVM-17 release (or re-add with kotlin.jvm.target.validation.mode=warning).

11. **Swiggy food ordering (27 Jul 2026)** — pairs with the backend's Swiggy
    MCP integration (see backend PROJECT_STATUS). App side:
    - `ApiService.swiggyLinked() / swiggyConnectUrl() / disconnectSwiggy()`.
    - Privacy screen → Connected Services now has a LIVE Swiggy row:
      Connect opens the browser (Swiggy phone + OTP OAuth; app never holds
      Swiggy tokens), status auto-refreshes on app resume via
      WidgetsBindingObserver; tap when connected → confirm-disconnect.
    - No new dependencies (url_launcher already present).
    - Voice flow needs NO app changes — "order a pizza" rides the existing
      /chat intent pipeline; Hari speaks the cart and waits for "yes".

## Document memory (client feature) — DONE (this session)
- Documents screen: **"Remember this"** button after loading any photo/PDF →
  optional note dialog ("what did the doctor say…") → uploads to `/docs`;
  a **HARI REMEMBERS** strip lists saved docs (tap = full viewer with the
  original image, AI summary, and your note; "Forget this document" deletes).
- ChatMessage now carries `documents`; parsed from `/chat` and the stream
  `done` line in ApiService.
- Voice loop: AssistantController exposes `lastDocuments`; the voice home
  screen shows tappable document cards under the transcript while the answer
  is spoken — "show me my last hospital report" pops the file up hands-free.
- Chat screen renders the same DocumentCard under assistant bubbles.
- New: lib/models/user_document.dart, lib/widgets/document_card.dart.

## Update — 29 July 2026: Agent calls (Hari talks to your contacts)
"Call Allen Lobo and ask him at what time he will come home" → Hari resolves
the contact ON-DEVICE (privacy: only the chosen number + task go to the
backend), the backend dials via Plivo and the AI converses with Allen, the
app polls `/agent-call/:id` and SPEAKS his answer back ("I spoke with Allen…").
- `call_service.dart` — `parseAgentCallIntent` → (name, task): "call X and
  ask/tell/inform/let…" plus bare "ask X when/if/what…" phrasings; pronouns
  rewritten to the contact's name so the call AI has full context.
- `api_service.dart` — `startAgentCall` / `agentCallStatus`;
  `AgentCallUnavailable` thrown on backend 503.
- `assistant_controller.dart` — agent intent checked BEFORE plain dialing;
  disambiguation ("which one?") carries the task through; bare-"ask" phrasing
  only becomes a call when the name matches a real contact (else the AI
  answers normally); 3-min poll then spoken result, saved into chat history
  for follow-ups; backend 503 → graceful fallback to a normal direct call.
- Plain "call amma" direct dialing is unchanged.

## Update — 29 July 2026 (2): Monetization UI + quota handling
- **`lib/screens/upgrade_screen.dart`** — Plan & usage screen: current tier
  + days left, live allowances (chat/STT/vision/agent minutes), Pro ₹249 &
  Family ₹499 cards → Razorpay hosted checkout via url_launcher, "I've
  paid" refresh (webhook activates server-side), Renew button, Family
  invite-code dialog (copies to clipboard) and join flow. Entry: Privacy
  screen top card.
- **`api_service.dart`** — fetchBilling / startCheckout / familyInvite /
  familyJoin; `QuotaExceeded` thrown on any 402 (chat, stream, agent call)
  carrying the server's ready-to-speak upsell line.
- **`assistant_controller.dart`** — voice loop SPEAKS the upsell on quota
  (instead of a generic error); an over-quota agent call still CONNECTS
  the user directly (their need is never blocked, only the AI talking).

## Update — 30 July 2026: Feature-list audit sweep (F1, F2, D2/D3 scopes, G2)
- **F1 — App lock**: `services/app_lock.dart` (biometric via local_auth +
  4-digit PIN fallback in flutter_secure_storage, on-device only) +
  `screens/lock_screen.dart` (auto biometric prompt, PIN pad). Gate wired in
  main.dart's AuthGate; re-locks when the app is backgrounded. Toggle lives
  in the Privacy screen (verify-before-disable).
  ⚠ Local setup: MainActivity must extend FlutterFragmentActivity and the
  manifest needs USE_BIOMETRIC (android/ is generated locally).
- **F2 — Your data, live**: Privacy screen Export shares a real
  `myassistant-data.json` (GET /privacy/export via share sheet); Erase asks
  the user to type DELETE, calls DELETE /privacy/account, signs out.
- **D2/D3 scopes**: linkGoogleData now also requests gmail.compose (drafts
  only — Hari never sends) and calendar.events. Existing linked users must
  reconnect once to grant them.
- **G2 — Call preview & approval**: before any agent call, the controller
  fetches `/agent-call/preview`, SPEAKS the exact opening line, and waits
  for a spoken yes — anything ambiguous cancels. Server-side rules
  (hours/daily cap/master switch) come back as a spoken block. Old-backend
  fallback keeps the previous direct flow.
- deps: + local_auth, + share_plus.

## Update — 3 Aug 2026: Fingerprint fix, release signing, self-hosted OTA updates
- **F1 fingerprint fixed** (button did nothing): the documented local setup was
  never applied — `MainActivity` now extends **FlutterFragmentActivity** (was
  FlutterActivity; local_auth threw no_fragment_activity, silently swallowed)
  and the manifest gained `USE_BIOMETRIC`. android/ is now IN the repo.
- **Release signing**: `build.gradle.kts` reads `android/key.properties`
  (git-ignored) → signs with the owner's `hari-release.jks`; falls back to
  debug signing when the file is absent. ⚠ Keystore + password are backed up
  by the owner; ALL client builds must use this key or updates break.
  ⚠ The release key's SHA-1 must be registered on the Google OAuth Android
  client or sign-in fails in release builds (pending verification).
- **Self-hosted OTA update channel** (sideload/client-testing phase):
  `ota_update ^7.0.0`; `UpdateService.launch()` tries Play In-App Update
  first (store installs unaffected), else downloads `config.apkUrl`
  (sha256-verified) and fires the system installer. Update sheet shows
  download progress + retry. Manifest: `REQUEST_INSTALL_PACKAGES`
  (⚠ REMOVE for Play Store builds — store policy bans self-update).
  `RemoteConfig` gained `apkUrl`/`apkSha256` from GET /config.
- **Distribution decided**: signed release APK shared directly with the client
  (Drive link); Firebase App Distribution / Play internal testing noted as
  next steps. Release ritual: bump `pubspec.yaml` version (+N = versionCode),
  `flutter build apk --release`, then `curl -F apk=@… /admin/apk` (backend doc).

## NEXT (planned for tomorrow, 4 Aug)
- Verify release-build Google sign-in (SHA-1 registration) on a real device.
- Full OTA loop test: install build 1 → publish build 2 → in-app update.
- Swiggy: submit Builders Club application (mcp.swiggy.com/builders) — demo
  video + use-case text; client whitelisting is the ONLY remaining blocker.
- Confirm owner rotated ALL keys leaked in chat on 3 Aug (GitHub token,
  Gemini, Groq, Google client secret — JWT/admin/app/metrics already rotated).

## D-ID avatar integration (5 Aug 2026)
- **Face Mode** — `screens/face_screen.dart`: WebView over the backend's
  hosted `/did/face` page (D-ID streaming avatar; words come from OUR backend
  via its custom-LLM bridge). Entry: marigold "Face to face" chip on Voice
  Home. Pauses/resumes the wake-word loop around the session (mic exclusivity),
  grants the WebView's runtime mic request. 402 → Upgrade screen.
- **Face-to-face first meeting** — the sign-up interview offers "Meet Hari
  face to face" (flag `face_interview` from /config); classic voice interview
  remains the fallback and the default.
- **Video briefing** — `_VideoBriefingCard` on the Daily screen: create →
  poll → inline `video_player` playback of the daily avatar briefing. Hidden
  when the server has D-ID off; Pro-gated via 402.
- **Upgrade screen** — Pro/Family perk lists now lead with the avatar features.
- **Retired**: Smart Home "coming soon" tab (dead placeholder). Restore from
  git (`screens/smart_home_screen.dart`) when Google Home/Matter actually lands.
- New deps: `webview_flutter`, `video_player` → run `flutter pub get`.
- ⚠️ Not compiled in this environment (no Flutter SDK) — run
  `flutter analyze` locally; expect at most minor lint fixes.

## Update — 12 Aug 2026: Professional mode (clients/patients) + document Send + "show my Aadhaar card" (app side)
App side of the case-file feature and the show-and-send document flow. Not
compiled here (no Flutter SDK in this env) — run `flutter analyze` locally;
expect at most minor lint. All touched files pass a structural (bracket/string)
scan.

- **Models**: `models/client.dart` (Client + ClientNote). `UserDocument` gained
  `clientId`.
- **API** (`services/api_service.dart`): full clients API (list/create/profile/
  update/delete, notes, link/unlink docs); `uploadDocument` takes optional
  `clientId`; new `downloadDocument(id)` returns raw bytes + mime for sharing.
- **Clients screen** (`screens/clients_screen.dart`): searchable list, add/edit
  sheet (kind chips), and a case-file detail view — profile card, dated notes
  timeline (add/delete), and document attach (camera/gallery/PDF) filed straight
  into the case. Reached from a new **Clients** chip beside the orb.
- **Document cards in the voice feed**: the engine handles the backend's new
  `documents` SSE event and renders `DocumentCard`s (`features/assistant/
  widgets/action_cards.dart`). Tap = view (image → pinch-zoom viewer, PDF →
  system viewer). New **Send** button downloads the real bytes, writes a temp
  file named from the document title (recipient sees "Aadhaar Card.jpg", not the
  internal save name) and opens the share sheet via `share_plus`.
- So "show my Aadhaar card" now: recalls it → shows it on screen → Send shares
  it. (ID numbers are shown, never spoken — enforced server-side.)

## NEXT
- `flutter pub get` + `flutter analyze` on a real checkout. `share_plus` is
  pinned `^10.1.2` and this code uses `Share.shareXFiles([XFile(...)])` (the
  10.x API). If pub resolves 11.x, switch that call to
  `SharePlus.instance.share(ShareParams(files: [XFile(...)]))`.
- No manifest change needed: `share_plus` merges its own FileProvider.
