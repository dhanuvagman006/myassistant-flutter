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
│   ├── api_service.dart          # all backend REST (chat, docs, clients, reminders, …)
│   ├── assistant_controller.dart # voice save/recall + camera flows
│   ├── voice_service.dart        # wake word, mic capture, TTS
│   └── auth_service.dart, notification_service.dart, app_lock.dart, …
├── features/assistant/           # the main screen + engine (state machine) + cards
└── screens/                      # auth, survey, avatar, clients, lock, splash, diagnostics
```

## Key features
- **Voice loop** — wake word (Porcupine) → cloud STT → streamed, sentence-by-
  sentence spoken replies over SSE.
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
- **Reminders, Gmail drafts + Calendar, agent phone calls, biometric app lock,
  self-hosted OTA updates**, and Pro/Family gating.

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
