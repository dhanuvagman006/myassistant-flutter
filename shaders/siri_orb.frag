// THE SIRI ORB, drawn by the GPU in one pass (2026-09-24, GPU pass). See
// _OrbPainter in lib/features/assistant/widgets/siri_orb.dart, which this
// replaces when it loads.
//
// WHY A SHADER. The splash shows this orb on every cold start and the
// Welcome screen until its button is tapped. Each frame drew three waves,
// each a freshly built 57-point path stroked with a blur under it — and a
// blurred path has no fast route on the phone's GPU: every wave went to
// its own offscreen texture, was blurred in two passes and composited
// back, nine to twelve render passes a frame, competing with start-up
// work. Here the glow is worked out directly (a line blurred by a
// Gaussian is two error functions across it), so the whole orb is one
// rectangle and no offscreen pass.
//
// THE PICTURE IS THE SAME: halo, dark glass disc, up to three waves (each
// a soft glow under a crisp line) clipped to the glass, the state's rim
// and the glassy highlight — with the Canvas version's numbers.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec4 uGeom;   // x: orb box side (logical px); y: one device pixel; z: wave count; w: amplitude (px)
uniform vec4 uHalo;   // rgb: state colour; a: halo strength
uniform vec4 uRim;    // x: rim strength
uniform vec4 uWave0;  // rgb: colour; a: strength — back wave
uniform vec4 uWave1;
uniform vec4 uWave2;
uniform vec4 uPhaseA; // xyz: each wave's first harmonic phase
uniform vec4 uPhaseB; // xyz: each wave's second harmonic phase

out vec4 fragColor;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

vec4 over(vec4 dst, vec4 src) {
  return src + dst * (1.0 - src.a);
}

// Coverage of a band of half-width h at distance d, anti-aliased over one
// device pixel.
float band(float d, float h, float px) {
  d = abs(d);
  return clamp((h - d) / px + 0.5, 0.0, 1.0) -
         clamp((-h - d) / px + 0.5, 0.0, 1.0);
}

// erf, to 1.5e-7 (Abramowitz and Stegun 7.1.26).
float erf1(float x) {
  float s = sign(x);
  x = abs(x);
  float t = 1.0 / (1.0 + 0.3275911 * x);
  float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
      - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
  return s * y;
}

// A band of half-width h blurred by a Gaussian of sigma s, at distance d:
// what MaskFilter.blur does to a stroke, without drawing it first.
float blurredBand(float d, float h, float s) {
  float k = 1.0 / (s * 1.41421356);
  return 0.5 * (erf1((h - d) * k) + erf1((h + d) * k));
}

// One wave at x: its height and its slope. Two harmonics under a sine
// envelope that pinches to nothing at the disc's edges.
vec2 wave(float x, vec2 c, float r, float amp, float freq, float pa, float pb) {
  float w2 = 2.0 * r;
  float f = (x - (c.x - r)) / w2;
  float env = sin(PI * f);
  float envD = PI * cos(PI * f) / w2;
  float al = freq * TAU * f + pa;
  float be = freq * 1.7 * TAU * f + pb;
  float s = amp * (sin(al) + 0.45 * sin(be));
  float sD = amp * (cos(al) * freq * TAU + 0.45 * cos(be) * freq * 1.7 * TAU) / w2;
  return vec2(c.y + env * s, envD * s + env * sD);
}

// Just the wave's height at x (the scan below needs nothing more).
float waveY(float x, vec2 c, float r, float amp, float freq, float pa, float pb) {
  float f = (x - (c.x - r)) / (2.0 * r);
  return c.y + sin(PI * f) * amp *
      (sin(freq * TAU * f + pa) + 0.45 * sin(freq * 1.7 * TAU * f + pb));
}

// How far p is from one wave, square to it.
//
// A near-flat wave (the splash's "connecting" breath, a resting line): the
// height straight above or below, corrected for the slope, is exact
// enough. A steep one (listening, speaking) is not — out in the glow it
// is far too near and smears the glow into streaks — so the nearest point
// is FOUND: a scan either side picks the right crest, and two
// Gauss-Newton steps settle on it. Every point tried is a real point on
// the wave, so the answer can only ever be too far, never too near.
float waveDist(vec2 p, vec2 c, float r, float amp, float freq, float pa, float pb,
               float reach) {
  vec2 w0 = wave(p.x, c, r, amp, freq, pa, pb);
  float steep = amp * (1.45 * PI + freq * TAU * 1.765) / (2.0 * r);
  if (steep < 0.35) {
    return abs(p.y - w0.x) / sqrt(1.0 + w0.y * w0.y);
  }
  float step = reach / 5.0;
  float bestX = p.x;
  float best = abs(p.y - w0.x);
  for (int k = -5; k <= 5; k++) {
    if (k == 0) continue;
    float x = clamp(p.x + float(k) * step, c.x - r, c.x + r);
    float d = length(vec2(x - p.x, waveY(x, c, r, amp, freq, pa, pb) - p.y));
    if (d < best) {
      best = d;
      bestX = x;
    }
  }
  float x = bestX;
  for (int it = 0; it < 2; it++) {
    vec2 w = wave(x, c, r, amp, freq, pa, pb);
    float g = (x - p.x) + (w.x - p.y) * w.y;
    x = clamp(x - clamp(g / (1.0 + w.y * w.y), -step, step), c.x - r, c.x + r);
  }
  return min(best, length(vec2(x - p.x, waveY(x, c, r, amp, freq, pa, pb) - p.y)));
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  float S = uGeom.x;
  float px = uGeom.y;
  vec2 c = vec2(S * 0.5);
  float r = S * 0.42;
  vec2 q = p - c;
  float rho = length(q);
  vec4 acc = vec4(0.0);

  // 1. HALO — the room-glow that says "on" from a distance. A radial
  // gradient to transparent BLACK, so the colour darkens as it fades.
  if (uHalo.a > 0.01) {
    float t = clamp(rho / (r * 1.55), 0.0, 1.0);
    float a = uHalo.a * (1.0 - t);
    acc = over(acc, vec4(uHalo.rgb * (1.0 - t) * a, a));
  }

  // 2. THE DARK GLASS DISC, lit from above.
  float disc = clamp((r - rho) / px + 0.5, 0.0, 1.0);
  if (disc > 0.0) {
    // RadialGradient's radius is a fraction of the box's shortest side
    // (2 r here): 1.2 of it is 2.4 r.
    float t = clamp(length(p - (c + vec2(0.0, -0.5 * r))) / (2.4 * r), 0.0, 1.0);
    vec3 glass = mix(vec3(0.14902, 0.16471, 0.29412),  // #262A4B
                     vec3(0.06275, 0.07059, 0.14902),  // #101226
                     t);
    acc = over(acc, vec4(glass, 1.0) * disc);
  }

  // 3. WAVES, clipped to the glass: two harmonics under a sine envelope
  // that pinches to nothing at the edges.
  float clip = clamp((r * 0.94 - rho) / px + 0.5, 0.0, 1.0);
  if (clip > 0.0) {
    int layers = int(uGeom.z + 0.5);
    for (int i = 0; i < 3; i++) {
      if (i >= layers) break;
      float fi = float(i);
      vec4 col = i == 0 ? uWave0 : i == 1 ? uWave1 : uWave2;
      float pa = i == 0 ? uPhaseA.x : i == 1 ? uPhaseA.y : uPhaseA.z;
      float pb = i == 0 ? uPhaseB.x : i == 1 ? uPhaseB.y : uPhaseB.z;
      float amp = uGeom.w * (1.0 - fi * 0.22);
      float freq = 2.0 + fi * 0.9;
      float width = S * (0.030 - fi * 0.006);
      // Beyond three sigmas of the glow nothing of this wave shows: skip
      // it (the whole band it can swing through, plus that).
      float reach = width * 1.3 + 18.0;
      if (abs(p.y - c.y) > amp * 1.45 + reach) continue;
      float d = waveDist(p, c, r, amp, freq, pa, pb, reach);
      // Soft glow underneath (the stroke 2.6 times wider, blurred by 6)...
      float g = col.a * 0.35 * blurredBand(d, width * 1.3, 6.0) * clip;
      acc = over(acc, vec4(col.rgb * g, g));
      // ...and the crisp line on top.
      float l = col.a * band(d, width * 0.5, px) * clip;
      acc = over(acc, vec4(col.rgb * l, l));
    }
  }

  // 4. RIM — the state's colour round the edge, and a glassy highlight
  // arc across the top (round-capped, 0.7 of a half turn).
  float rim = uRim.x * band(rho - r, 0.8, px);
  acc = over(acc, vec4(uHalo.rgb * rim, rim));
  float R = r - 2.5;
  float theta = atan(q.y, q.x);
  float from = -PI * 0.85, to = -PI * 0.15;
  float d = theta >= from && theta <= to
      ? abs(rho - R)
      : min(length(q - R * vec2(cos(from), sin(from))),
            length(q - R * vec2(cos(to), sin(to))));
  float hl = 0.14 * band(d, 1.0, px);
  acc = over(acc, vec4(vec3(hl), hl));

  // Half a step of dither against banding in the halo.
  float n = (hash12(p / px) - 0.5) / 255.0;
  acc.rgb = clamp(acc.rgb + n, vec3(0.0), vec3(acc.a));
  fragColor = acc;
}
