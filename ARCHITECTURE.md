# MYASSISTANT — Architecture & Debugging Guide

One page to understand the whole system, find any bug, and know where
new features go.

## The big picture

```
┌─ PHONE (this repo, Flutter) ─────────────────────────────────────┐
│                                                                  │
│  assistant_screen.dart ── the home screen                        │
│        │ observes                                                │
│  AssistantEngine (features/assistant/state/assistant_engine.dart)│
│    the ONE state machine: phases, transcript, cards, errors      │
│        │ uses                    │ uses                          │
│  AssistantApi                VoiceService                        │
│  (core/network/)             (services/voice_service.dart)       │
│  session + SSE stream +      mic VAD recording, device-STT       │
│  POST audio/message/confirm  fallback, TTS + lip-sync pulses     │
│        │ HTTP                                                    │
└────────┼─────────────────────────────────────────────────────────┘
         ▼
┌─ SERVER (myassistant-backend repo, Node) ────────────────────────┐
│  /assistant  src/assistant/routes.js — sessions, SSE events,     │
│              STT, turn loop, call-confirmation flow              │
│        │ every turn                                              │
│  src/agents/orchestrator.js — routes to ONE agent:               │
│     bookingAgent → bookings ledger + reminders                   │
│     searchAgent  → live news / places / weather, then answer     │
│     conversationAgent → personalized persona + memory            │
│  src/agents/memory.js — per-user long-term facts (Postgres)      │
│  src/did/* — D-ID photoreal Face Mode (optional, needs API key); │
│              compat.js feeds it the SAME persona + memories      │
└──────────────────────────────────────────────────────────────────┘
```

## The hero visual

The animated ORB (`assistant_hero_widget.dart`): breathes when idle,
pulses with the live mic level while listening, orbits sparks while
thinking, ripples while speaking. Tap it to talk. (The D-ID face and
avatar experiments were removed — one visual, zero dependencies.)

## Debugging runbook

**Open Diagnostics first**: when the app can't connect, an orange
banner appears under the face — tap it. You get the server URL
(editable at runtime, no rebuild), a `/health` test with the raw error,
the stream state, and the live app log.

| Symptom | Look at |
|---|---|
| "Can't reach the server" banner | Diagnostics → Test /health. `FAILED: Connection refused` = server not running / wrong URL. Phone + laptop must be on the same network; use the laptop's LAN IP (`http://192.168.x.x:3000`), never `localhost`. |
| Mic records but nothing comes back | Diagnostics log: look for `POST /assistant/... HTTP 4xx/5xx`. 404 = server running OLD code (redeploy). 401 = auth/APP key mismatch. |
| Replies but no voice | Phone media volume; log shows `speak` activity; TTS engine installed? |
| Wrong/robotic answers | Server logs; `GEMINI_API_KEY` set? |

**Server quick-check** (on the laptop):
```bash
curl http://localhost:3000/health          # → {"ok":true,...}
node src/server.js                          # watch boot errors
```
Needs `DATABASE_URL` (Postgres) and `GEMINI_API_KEY`. New tables
auto-create on boot.

**Run the app against a local server:**
```bash
flutter run --dart-define=BASE_URL=http://<laptop-LAN-IP>:3000 \
            --dart-define=APP_API_KEY=<your APP_API_KEY>
```
…or just run it and change the URL in Diagnostics.

## Adding features

- **New agent** (backend): one file in `src/agents/` exporting
  `{ matches(text), handle(turn) }` + one line in `orchestrator.js`
  AGENTS list. Turn cards in the app appear automatically.
- **New event type**: emit in `src/assistant/routes.js`, handle in
  `AssistantEngine._onEvent`, render in `assistant_screen.dart`.
- **New screen**: `lib/screens/`, navigate from wherever fits.
- **Log as you go**: `AppLog.add('mytag', '...')` — it shows up in
  Diagnostics instantly.

## Known legacy

`lib/services/assistant_controller.dart` is the OLD wake-word voice
loop ("Hey Hari" while the app is open). It coexists with
AssistantEngine; the engine owns the mic-button conversation. Planned:
fold wake-word into the engine and retire the controller.
