# MYASSISTANT

**Hari** — a voice-first personal AI assistant. **Flutter (Dart)**, one codebase
for **Android and iOS**. The app is a thin, secure client: it captures voice,
speaks replies, and renders live cards — all AI keys and logic live in the
backend (`MYASSISTANT_BACKEND`).

> Scope note: the original Project Scope doc (Section 5) named Kotlin and
> excluded iOS. Flutter + iOS is a deviation recorded via Change Request.

## The experience
A single-screen agent, not a tab bar. An animated "bloom orb" you tap to talk;
your words and Hari's replies stream in as a transcript, with dynamic cards
appearing inline — search results, contacts to call, saved documents, and a
confirmation card before any real-world action. Two chips sit by the orb:
**Face** (Tavus human-avatar video call) and **Clients** (professional mode).

## Structure
```
lib/
├── main.dart                     # app shell + AuthGate
├── theme/ · design/              # Neon design system (tokens, glass cards, orb, gyro tilt)
├── models/                       # ChatMessage, UserDocument, Client, Reminder, Place, …
├── core/network/assistant_api.dart   # SSE client for the realtime voice loop
├── services/
│   ├── api_service.dart          # all backend REST (chat, docs, /tts, clients, reminders, …)
│   ├── voice_service.dart        # mic capture, adaptive VAD, cloud TTS + barge-in, wake word
│   ├── call_service.dart         # on-device contact lookup + dialing
│   ├── phone_state_guard.dart    # silence Hari the instant the phone rings
│   └── auth_service.dart, notification_service.dart, app_lock.dart, …
├── features/assistant/
│   ├── assistant_screen.dart     # the single-screen agent UI
│   └── state/assistant_engine.dart   # the LIVE brain: phase machine, events, barge-in, camera
└── screens/                      # auth, survey, avatar, clients, lock, splash, diagnostics
```
> The heavy orchestration (intent routing, agent calls, document capture) runs
> **server-side** in the backend's `/assistant` loop; `AssistantEngine` is a thin
> client that records, renders the streamed events, and speaks.

## Key features
- **Voice loop** — wake word (Porcupine) → cloud STT → streamed, sentence-by-
  sentence spoken replies over SSE. Adaptive voice-activity detection with
  hardware **noise suppression** rejects background sound, and snappy
  end-of-speech detection makes turn-taking feel natural.
- **Natural cloud voice** — replies are spoken with a warm neural voice
  (Gemini TTS via the backend `/tts` endpoint), not the robotic on-device
  engine; it falls back to the device voice automatically when offline.
- **Barge-in / interrupt** — talk over Hari mid-sentence and she stops at once
  and listens to your new question. No tap, no wake word. Hardware echo
  cancellation keeps her own voice from triggering it.
- **Voice-driven capture** — say "save this receipt", "scan this" or "remember
  this" and the camera opens, files the shot into document memory with your
  own words as the note — no typing, no naming step.
- **Agent phone calls** — "call mom and tell her I'll be late" and Hari places
  the call itself (Plivo), speaks the message in a natural voice, and **hangs
  up on its own**; for "ask …" tasks it captures their reply and reports it
  back. Auto-dials (announces first, interruptible); offers one retry on no
  answer. Falls back to a direct dial where telephony isn't configured.
- **Incoming-call mute** — the instant your phone rings or a call connects,
  Hari goes silent and releases the mic — never talks over a call.
- **Saved documents** — snap or pick a report/receipt/ID; Hari analyses and
  remembers it. Ask by voice ("show me my last hospital report", "show my
  Aadhaar card") and the document appears on screen with a **Send** button that
  shares the real file (WhatsApp, email, Drive…). ID cards are shown for you to
  read; their numbers are never spoken aloud.
- **Clients / patients (professional mode)** — a doctor, lawyer or CA keeps one
  case file per person: profile, dated notes and linked documents. Reachable
  from the Clients screen or by voice — "give me the details about patient
  Ramesh" speaks the file and shows the documents; "note for patient Ramesh:
  …" adds a dated note.
- **Reminders, Gmail drafts + Calendar, biometric app lock, self-hosted OTA
  updates**, and Pro/Family gating.

## First-time setup
`android/` and `ios/` are already in the repo (release signing, biometric and
permission config live there). Just:
```bash
flutter pub get
```

## Run
`BASE_URL` selects the backend (compile-time `--dart-define` wins; otherwise a
persisted runtime value; debug builds default to a local/dev server).
```bash
# Android emulator against a local backend
flutter run --dart-define=BASE_URL=http://10.0.2.2:3000

# iOS simulator against a local backend (Mac + Xcode)
flutter run --dart-define=BASE_URL=http://localhost:3000
```
Diagnostics (server URL, `/health` test, live logs) is reachable from the
connection banner if the app can't reach the server.

## Build (release)
```bash
flutter build apk --release      # signed with android/hari-release.jks via key.properties
```
See `PROJECT_STATUS.md` for the full release ritual (version bump → build →
publish to the OTA channel) and the ⚠️ notes on keystore and OAuth SHA-1.

## How updates work (no rebuild)
1. **Server-driven** — `GET /config` carries feature flags, announcements and
   changelog. The AI runs server-side, so new capabilities go live instantly on
   both platforms with no store release.
2. **Binary updates** — new screens need a release: Play In-App Updates on
   Android, or the self-hosted OTA channel for direct/client-testing builds.

## Note on secrets
The app ships no AI keys. Never commit tokens, keystores, or `key.properties`.
If a credential leaks anywhere (including chats or screenshots), rotate it.
