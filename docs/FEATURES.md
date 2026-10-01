# Features

What the app does, by feature. Newest first. Server-side details are in the
backend README.

## Added 2026-09-30 (build 135)
None of these has run on a phone yet.

- **Fast Live voice** — conversations run on Gemini 3.8 Live (about 0.6 s from
  the end of speech to her first word, measured on the PC), with the same tools,
  approvals and barge-in as before. If Live can't connect or stalls, the classic
  voice answers the same words. The orb shows six states: idle, listening,
  thinking, responding (with the tool's words, e.g. "Checking your calendar…"),
  speaking and done.
- **Voice picker** — choose the Live voice (default Callirrhoe) and hear a
  sample first, from the assistant settings.
- **Poster Studio** — "make a poster for our get-together on Saturday". The
  server writes the words and a picture with no text in it; the phone draws
  every word in real fonts, so nothing is misspelt. Four templates (Neon Night,
  Corporate Clean, Festive, Bold Minimal) with three layouts each, palettes and
  brand colours, edit text, change image, and "Add location?" prompts for
  missing details. Text always stays readable (4.5:1). Share on WhatsApp or save
  to Photos. Opened by voice/chat or from the Poster screen.
- **Play my morning** — a button under the Home greeting (and "play my
  morning" by voice) reads the day's brief aloud in short groups, with captions,
  pause and stop in a strip above the dock. It ends with one offer, such as
  "Prepare me" for the next meeting. It never plays into an open microphone.
- **Meeting prep** — "prepare me for my next meeting", or Prepare on the
  meeting card. A sheet shows the summary, people, 3–5 talking points, what's
  worth knowing, promises and risks, with "Remind me 10 min before" and "Join
  the call" when there's a link. Works from a meeting-like reminder when Google
  isn't linked.
- **Photo edit by voice** (server) — "remove the background from my photo",
  "make the sky blue". Faces and bodies are never changed; face swaps and
  "make me fairer / younger / slimmer" are refused. The original is kept.
- **Better image generation** — pictures come from the best provider available
  (see DECISIONS.md), with a prompt rewrite, upscaling and clean cropping.
  Poster and story sizes added.
- **Neon everywhere** — every screen now uses the Home look: night sky, lit
  cards, press feedback, standard loaders and empty states (see DESIGN_SYSTEM.md).
