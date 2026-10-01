# Decisions

Short records of why things are the way they are. Newest first. Each entry:
what we chose, the evidence, and what was kept as a fallback.

## 2026-09-30

### Voice: Gemini 3.8 Live is the default voice path
- **Chosen:** Gemini 3.8 Live through Firebase AI Logic (`lib/ai/live_voice.dart`),
  from build 135. The server sends the model, voice and turn settings in the
  `live` block of `GET /ai/config`.
- **Measured (PC → Firebase proxy, end of speech → first audio):**
  3.8-live 0.62 s · 3.1-flash-live-preview 0.79 s · 2.5 native audio 21 s ·
  the old cascade (STT → model → TTS) ~5–8 s.
- **With the real load** (30k-char prompt + 32 tools): a tool turn's first audio
  1.54 s; session setup 1.76 s, hidden by pre-warming when the orb is tapped.
- **Tools must be BLOCKING on 3.8.** Without `behavior: BLOCKING` the model goes
  silent after a tool response (`BlockingFunctionDeclaration`).
- **Kept:** the cascade as the fallback (connect failure, stall) and for typed
  requests. Fola stays the classic (cascade/TTS) voice.

### Live voice: Callirrhoe, chosen by test
- 12 voices recorded on the same line, rated by a Gemini audio evaluator
  (naturalness, warmth, clarity, pronunciation, pacing).
- Pitch variation measured: Vindemiatrix 5.7 st, Callirrhoe 5.1, Fola 3.9
  (the flattest).
- First audio: Callirrhoe 0.56 s.
- **Callirrhoe** is the default; runner-up **Vindemiatrix**. The owner can switch
  it server-side with `AI_LIVE_VOICE`; users can pick from the voice picker.

### Noise and echo
- Synthesized noise matrix at 10 and 5 dB SNR: fan, AC, traffic and keyboard
  were heard exactly (0.7–1.9 s); background babble was fine.
- TV and other speech-like noise blocked Live's end-of-turn (no answer at
  10 dB). Fix: a local **TV gate** — once this phone's VAD hears the owner stop,
  the app sends silence so Live closes the turn.
- Speaker echo: `VOICE_COMMUNICATION` AEC plus an echo-aware barge-in gate.

### Images: provider chain by quality
- Order: Gemini (only when billed) → fal z-image / qwen-image-2512 →
  Cloudflare FLUX.2 klein 4B (free) → FLUX.1 schnell → Pollinations (keyless).
  Text-heavy images prefer qwen-image-2512.
- Research: there is no free Gemini image tier; Cloudflare klein gives about
  95 free images a day; fal costs $0.005–0.03 an image.
- Posters are **hybrid**: the AI makes a text-free background, and the phone
  draws every word in real fonts, so spelling, dates and names are exact.

### Design: one neon system everywhere
- Every pushed page uses `NeonScaffold` (the Home sky); the theme now styles
  menus, pickers, dialogs and sheets, so screens set no local colours.
- Everything tappable dips under the finger (`Tappable` / `PressScale`).
- Sheets rise on a spring damped to 0.9 (0.15% overshoot, under a pixel).
  **Owner to confirm** — it bends the "nothing bounces" rule.
- The voice orb has six states, each with its own colour and movement.
  **Client to confirm** — it changes his reference ring colours.

### Wow features
- **Play my morning:** a spoken daily brief, not a list to read.
- **Prepare me for my next meeting:** a one-sheet prep from what we already know.
- Both are guarded: any number or person not in the facts sends the reply back
  to a code-written version.

## 2026-09-30 — A meeting recording never pauses behind your back

The meeting recorder had the same hole as "Never stuck on Listening" below:
`record`'s default pauses on ANY audio-focus loss (a WhatsApp ping, a
notification) and never resumes, while the screen went on saying
"Recording" and ticking the clock over a microphone capturing nothing.

- **Chosen:** `AudioInterruptionMode.none` in
  `meeting_recorder_screen.dart`. Only the owner pauses a meeting.
- **A pause nobody asked for is shown.** The screen listens to the
  recorder's state; a `pause` it did not make turns the screen to Paused
  with Resume and a warning line ("The microphone was interrupted — tap
  Resume to carry on"). The clock stops with it.
- **A phone call pauses it, explicitly.** `PhoneStateGuard.callConnected`
  (new; true only while a call is connected) pauses the recording with
  "Paused for your call". Ringing does not pause it: a declined call costs
  the meeting nothing. Start and Resume are refused during a call.
- **No resume by itself after the call.** When the call ends the app may
  still be behind the call screen, where Android gives a background app
  silence, and the owner may not be back in the room. The screen stays on
  Paused with Resume until they tap it.
- **Fallback:** without the phone-state permission the guard is off; the
  recording carries on through a call, and Android records silence for it.
- Tests: `test/meeting_recorder_test.dart` (fake recorder and call signal).

## 2026-09-30 — Home buttons answer on the touch; a real weather card

- **Buttons (owner: "some buttons are laggy… like umbrella reminder"):** Done,
  Later and promise-kept now change the card on the tap and sync behind it; a
  failed request puts the card back where it was and offers Try again (was
  "confirmed, not optimistic"). The rain card's Remind me no longer hands a
  sentence to the assistant (a whole AI turn): it sets the reminder directly
  (POST /reminders, half an hour before the rain), shown as set at once.
- **Weather card (owner's forecast-card example):** GET /tools/weather/forecast
  (Open-Meteo, free) → now, 24 h, 7 days, rain window, area name. Home draws a
  sky per condition, a painted weather picture, four facts and the rain line
  with Remind me. A 7-day / 24-hour chart was built and taken out the same
  day (owner: "only this much is enough"). Painted once, no animation; cached
  on the phone so it shows instantly. It replaces
  the one-line rain row and takes one context slot.

## 2026-09-30 — The reminder pop-up

Owner: "need reminder pop up like this style" (a "Today's focus" task card).
`lib/features/reminders/reminder_popup.dart`: a sheet with today's progress
ring ("1 of 3 done today"), the reminder as the one big card (its time, how
soon, a glowing Mark done that answers on the touch and rolls back on a
failure, Snooze 10 min), Next up (a tap makes it the focus), and the week
strip with a dot per open reminder. It opens from the reminder notification
(payload `reminder:<id>`) and by itself when a reminder comes due while the
app is open (the notification still rings).

## 2026-09-30 — Never stuck on "Listening"

Client (S24 Ultra, build 138): after a few turns the screen sat on
"Listening" and nothing he said did anything. Nothing checked that
"Listening" had a working microphone and a session that could hear. Found
and fixed:

- **The microphone paused for good.** By default the `record` package
  pauses the capture on ANY audio-focus loss (a WhatsApp ping, a
  notification, Bixby) and never resumes it. The stream stayed open with no
  frames, so nothing noticed. Now `AudioInterruptionMode.none` (MicStream
  and the cloud recorder); a phone call is PhoneStateGuard's job. The Live
  voice also watches the frames: after 2 s without one the microphone is
  reopened, and after 3 reopenings in a minute the classic voice takes over.
- **Messages lost in firebase_ai.** A Live message the SDK does not know
  (gemini-3.8-live sends voiceActivity and keep-alives) ended its receive()
  stream, and the tool call or turn complete right behind it was dropped.
  The BLOCKING model then waited for good. Fixed in our copy,
  `third_party/firebase_ai` (dependency_overrides; the four changes are in
  third_party/README.md). That copy also pings the socket every 30 s, so a
  dead connection closes within a minute and the app reconnects.
- **A session that stopped hearing looked like a cough.** Measured on
  gemini-3.8-live: real speech brings a server frame about 1 s after it
  starts; silence, a cough and noise bring nothing. So when 600 ms or more
  of real speech gets no frame back within 2 s of his stopping, a fresh
  session is opened and hears his words again from the phone's copy, so he
  never repeats himself. If the fresh session is silent too, the turn is
  dropped quietly (it may have been a clatter). If that happens twice, or
  the session cannot open, the classic voice says "Sorry, I didn't catch
  that" and takes over.
- **Smaller holes:**
  - The second stall handed over with the Live microphone still open.
    Android then gives the phone's recogniser silence, since only one
    capture runs at a time.
  - A tool that threw or never returned left the model unanswered. Every
    call is now answered, within 40 s.
  - A session that closed while it was being reopened was never noticed.
  - A quiet microphone that never trips the phone's VAD had no reply watch.
    The server's words now start one.
  - The engine now reopens listening when the Live microphone is closed,
    and lets go of a recogniser that has not finished after 40 s (80 s
    while it is still reporting).
- **Audio focus moved to the conversation.** The recorder used to take the
  focus itself, and that request was what paused it. Now the conversation
  holds the focus (MainActivity "audioFocus", GAIN_TRANSIENT): music pauses
  while we talk and plays again afterwards, and losing the focus changes
  nothing.
- **Found in review, fixed before build 139:**
  - With the speaker muted, a hand-over line left the screen on "Thinking".
  - A fallback no longer clears a running cascade turn.
  - end_conversation is kept on a fallback.
  - A stuck recorder stop can no longer freeze the mic watchdog.
  - The permission dialog no longer times out.
  - A known message kind that fails to parse is still an error, not
    skipped.
