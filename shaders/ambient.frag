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
uniform vec4 uMiddle; // x: middle pool strength

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
  col += (hash12(p / uPx.x) - 0.5) / 255.0;
  fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
