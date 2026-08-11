# Real human face (video mode)

Drop TWO short videos of a real person here and the assistant's face
becomes that person — no D-ID, no API keys, works offline:

    assets/face/idle.mp4      5–15 s of her just listening: blinking,
                              tiny natural movements. Must loop cleanly
                              (first and last frames similar).
    assets/face/talking.mp4   5–15 s of her talking naturally (what she
                              says doesn't matter — audio is muted; her
                              VOICE is the app's TTS).

The app crossfades to talking.mp4 whenever the assistant speaks and
back to idle.mp4 when she finishes. If these files are absent the
painted animated avatar shows instead — nothing breaks.

## Where to get the clips (pick one)

1. FILM SOMEONE (best, free): 15 s phone video of a friend looking at
   the camera doing nothing, then 15 s of them talking. Portrait, good
   light, head centered.
2. GENERATE ONCE: any avatar tool's free tier (D-ID Studio, HeyGen)
   can render one idle clip and one talking clip of a stock presenter —
   download the two MP4s and you never call their API again.
3. STOCK: royalty-free "woman talking to camera" clips from Pexels or
   Pixabay (check the license allows app use).

Keep files small (720p, H.264, a few MB each) — they ship inside the APK.

Tip for clean loops: trim so the first and last frames match, e.g.
`ffmpeg -i in.mp4 -ss 0.5 -t 8 -an -vf scale=720:-2 idle.mp4`
