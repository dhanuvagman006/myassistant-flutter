// THE ROOM THE APP SITS IN, drawn by the GPU in one pass (2026-09-24,
// GPU pass). See AmbientBackground in lib/widgets/ambient_background.dart,
// which this replaces when it loads.
//
// WHY A SHADER. The ambient light was a full-screen wash plus three large
// pools of light laid over it — about two screens' worth of blended
// gradient. It never changes, but the phone's renderer draws the whole
// picture again on every frame that anything on the page moves (a scroll,
// a spinner, a page sliding in), so all of it was paid on every one of
// those frames. Here every pixel works out the wash and the three pools
// itself and is written ONCE, opaque: one fill instead of four, and
// nothing to blend.
//
// THE PICTURE IS THE SAME — the same stops, alphas and positions.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec4 uGeom;   // xy: box size; zw: screen size (the pools are sized to the screen)
uniform vec4 uPx;     // x: one device pixel
uniform vec4 uWash0;  // rgb: top of the wash
uniform vec4 uWash1;  // rgb: 42% down
uniform vec4 uWash2;  // rgb: the page ground, at the bottom
uniform vec4 uTint;   // rgb: the accent; a: top-left pool strength
uniform vec4 uPartner; // rgb: its partner; a: bottom-right pool strength
uniform vec4 uMiddle; // x: middle pool strength; y: ribbon strength (0: none)

out vec4 fragColor;

vec3 over(vec3 dst, vec3 rgb, float a) {
  return rgb * a + dst * (1.0 - a);
}

// One soft circle of light: stops 0 / 0.34 / 0.62 / 1 at full, 55%, 18%
// and no strength.
float pool(vec2 p, vec2 centre, float radius, float a) {
  float t = length(p - centre) / radius;
  if (t >= 1.0) return 0.0;
  if (t < 0.34) return a * mix(1.0, 0.55, t / 0.34);
  if (t < 0.62) return a * mix(0.55, 0.18, (t - 0.34) / 0.28);
  return a * mix(0.18, 0.0, (t - 0.62) / 0.38);
}

// A soft ribbon of light along y = c + a*sin(k*x + ph): brightest on the
// curve, gone a few widths away.
float ribbon(vec2 p, float c, float a, float k, float ph, float width) {
  float d = (p.y - (c + a * sin(k * p.x + ph))) / width;
  return exp(-d * d);
}

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 box = uGeom.xy;
  float w = uGeom.z, h = uGeom.w;

  // 1 — the wash, top to bottom.
  float v = clamp(p.y / box.y, 0.0, 1.0);
  vec3 col = v < 0.42 ? mix(uWash0.rgb, uWash1.rgb, v / 0.42)
                      : mix(uWash1.rgb, uWash2.rgb, (v - 0.42) / 0.58);

  // 2 — the two pools: top-left (left -0.35 w, top -0.12 h, 1.25 w
  // across) and bottom-right (right -0.42 w, bottom -0.10 h, 1.30 w).
  col = over(col, uTint.rgb,
      pool(p, vec2(0.275 * w, -0.12 * h + 0.625 * w), 0.625 * w, uTint.a));
  col = over(col, uPartner.rgb,
      pool(p, vec2(box.x + 0.42 * w - 0.65 * w, box.y + 0.10 * h - 0.65 * w),
           0.65 * w, uPartner.a));
  // 3 — the middle (left 0.10 w, top 0.34 h, 1.05 w across).
  col = over(col, uPartner.rgb,
      pool(p, vec2(0.625 * w, 0.34 * h + 0.525 * w), 0.525 * w, uMiddle.x));

  // Half a step of dither: a near-flat dark gradient bands without it.
  // RIBBONS (2026-09-30, the client's reference): flowing bands of neon
  // light — blue into purple into magenta across the lower screen, a
  // bright crest along the top of the wave, and magenta into orange
  // sweeping through the top-right corner. Same single pass: no extra cost
  // per frame. Off (0) on the light theme and in the parity test.
  float wave = uMiddle.y;
  if (wave > 0.0) {
    vec3 blue = vec3(0.16, 0.40, 1.0);
    vec3 purple = vec3(0.52, 0.16, 1.0);
    vec3 magenta = vec3(1.0, 0.16, 0.84);
    vec3 orange = vec3(1.0, 0.50, 0.26);
    float t = clamp(p.x / box.x, 0.0, 1.0);
    vec3 band = mix(mix(blue, purple, smoothstep(0.0, 0.55, t)), magenta, smoothstep(0.45, 1.0, t));
    float k = 6.2831853 / (1.2 * w);
    // the wave's body, a wide soft glow under it, and its bright crest
    float body = ribbon(p, 0.745 * h - 0.05 * h * t, 0.045 * h, k, 0.9, 0.040 * h);
    float under = ribbon(p, 0.80 * h - 0.03 * h * t, 0.060 * h, k * 0.8, 2.4, 0.075 * h);
    float crest = ribbon(p, 0.745 * h - 0.05 * h * t - 0.030 * h, 0.045 * h, k, 0.9, 0.006 * h);
    col = over(col, band * 0.85, clamp(under * 0.55 * wave, 0.0, 0.8));
    col = over(col, band, clamp(body * 0.80 * wave, 0.0, 0.9));
    col = over(col, mix(band, vec3(1.0), 0.45), clamp(crest * 0.85 * wave, 0.0, 0.9));
    // the top-right sweep: a band curving down the right edge
    float s1 = ribbon(vec2(p.y, p.x), 0.97 * w, 0.10 * w, 6.2831853 / (1.1 * h), 1.6, 0.070 * w)
             * (1.0 - smoothstep(0.02 * h, 0.34 * h, p.y));
    vec3 sweep = mix(magenta, orange, smoothstep(0.80 * w, 1.0 * w, p.x));
    col = over(col, sweep, clamp(s1 * 0.85 * wave, 0.0, 0.85));
  }

  col += (hash12(p / uPx.x) - 0.5) / 255.0;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
