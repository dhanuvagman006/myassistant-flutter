# Design system

One neon system for the whole app: the client's night-sky reference. Tokens
live in `lib/design/neon_tokens.dart` (`Neon.*`), widgets in
`lib/design/neon_widgets.dart`, motion in `lib/design/motion.dart`, and the
theme in `lib/theme/app_theme.dart`.

## Rules
- Use tokens, never raw `Colors.*` (the camera view's blacks are the exception).
- One lit (glowing) card per page, in the colour of what it means. Other cards
  get the rim only, which keeps scrolling light on the F15.
- Primary actions glow; secondary actions are outline only.
- Everything tappable dips under the finger.
- Leave colours to the theme: it covers menus, dropdowns, date/time pickers,
  dialogs, sheets, chips, switches, tooltips, snackbars and FABs.
- With Remove animations on, every widget shows its final state and nothing ticks.

## Primitives (added 2026-09-30)

| Widget / API | Use |
|---|---|
| `NeonScaffold({..., bool sky = true})` | Every pushed page. The sky sits outside a transparent `Scaffold`, so the keyboard doesn't re-layout it. `sky: false` = plain `Neon.bg`. |
| `Tappable({onTap, onLongPress, scale = 0.97, semanticLabel, tapHint, haptic})` | Press dip + light tick, announced as a button. No callbacks = returns the child unchanged. |
| `PressScale({child, scale = 0.97})` | The dip alone. Instant outside lists; keeps the 80 ms wait inside a `Scrollable`. Full-width rows use 0.985. |
| `GlowCard(..., onTap, onLongPress, heroTag, semanticLabel)` | With a callback it wraps itself in `Tappable`; with `heroTag` it flies to its page. |
| `cardHeroTag(id)` / `cardFlight` / `cardFlightFor({cardRadius, pageRadius})` | Card → page flight. The target page needs `Hero(tag: cardHeroTag(id), flightShuttleBuilder: cardFlight)`; tags must be unique on the screen. |
| `NeonSuccess({size = 72, label})` | Animated tick, `NeonSuccess.duration` = 700 ms. Announces itself; stops asking for frames once settled. |
| `NeonLoader.inline()` / `NeonLoader.page({label})` | Replace every raw `CircularProgressIndicator`. |
| `NeonEmptyState(..., actionLabel, actionIcon, onAction, tone)` | Empty pages, with an action as a `NeonPill` where one exists. `NeonErrorState` uses the danger tone. |
| `Motion.sheetSpring` / `Motion.sheetIn` (360 ms) / `Motion.sheetRise` / `SpringCurve(spring, settle:)` | Sheets rise on a spring damped to 0.9 (0.15% overshoot) — owner to confirm. `showAppSheet` uses it. |
| `FeedbackTone.warning` | Amber toast, lasts 5 s like an error. Toasts get a rim in their tone. |
| `Neon.scrim` | The dark overlay behind dialogs and sheets. |
| `ToneTile(icon, tone)` · `RimCard({tone, onTap, heroTag, ...})` · `NeonSection({icon, title, tone, lit})` · `cardHero(...)` | `lib/widgets/neon_cards.dart`: icon tiles, rim-lit cards, titled sections. |
| `GlowCta({label, onPressed, icon, busy})` · `BrandMark()` | `lib/widgets/glow_cta.dart`: full-width lit button and brand tile (first-run pages, consent, recorder). |
| `ChatBubble({mine, child})` · `ChatComposer({controller, onSend, sending})` · `ChatUnreadBadge` · `ChatAvatar` | `lib/widgets/chat_bubble.dart`. Sent bubbles use the brand gradient darkened to reach 4.5:1. |

`NeonPill` (0.95) and `AppleRow` (0.985) now dip too, and `appleAppBar` is
transparent so the sky shows through on a `NeonScaffold`.

## Voice orb moods
`enum OrbMood` in `lib/widgets/voice_orb.dart`; `orbMoodFor(engine)` picks it
and `orbMoodColor(mood)` gives the colour. Still one GPU shader
(`shaders/voice_backdrop.frag`). The colours per state are **awaiting the
client's OK**.

| Mood | Colour | Movement |
|---|---|---|
| Idle | dim cyan | slow breath, under 2% |
| Listening | cyan → blue | rings pushed by his mic |
| Thinking | violet | breath rolling outward, 4.5% |
| Responding | magenta → orange | a light running round the inner ring + the tool's words ("Checking your calendar…") |
| Speaking | pink → magenta | rings pushed by her voice; ribbons sway only here |
| Done | green → cyan | one outward pulse, then rest |
| Paused | idle colour, still | while he types, so nothing redraws under the keyboard |

The status line and the dock button's halo take the mood's colour. With Remove
animations on, each mood is its colour and words only.
