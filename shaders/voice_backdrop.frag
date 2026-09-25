// THE SPEAKER ROUND THE VOICE ORB, drawn by the GPU in one pass
// (2026-09-25). See _BackdropPainter in lib/widgets/voice_orb.dart,
// which this replaces when it loads.
//
// The client, about the old flares round the orb: "Change outer
// rendering to other style", then a picture and "Make it something like
// this, when it's on, only the speaker should move forward and
// backwards". So this draws the picture's rings — five thin full rings,
// four bright lenses at the sides (the speaker cones), a haze between
// them, and the light-wave ribbons running out to both sides — and the
// Dart side moves the rings in and out with the voice. The disc, the mic
// and the name in the middle are a separate, still picture (VoiceOrb).
//
// THE NUMBERS ARE THE SAME. Every number in the ring(), lens(),
// strand() and sparkle() calls below is copied from OrbRings in
// lib/design/orb_rings.dart, in the same order of painting (haze, lenses,
// full rings, then each ribbon's sheet, strands and sparkles).
// test/orb_rings_test.dart reads this
// file and fails if a number here and there ever differ; the Canvas
// painter draws the same table as triangle meshes, and
// test/gpu_pass_test.dart compares the two pictures pixel by pixel.
//
// WHY A SHADER. Every pixel works out its own colour once: no offscreen
// layer, no paths, no blur, one rectangle. The soft light round each ring
// is part of its profile (a bright core, a bright edge, a fading glow),
// never a blur pass.
//
// PRECISION. Mali runs mediump as 16-bit floats, which cannot hold a
// screen coordinate to the pixel, so everything here is highp. Nothing
// that grows without limit comes in: the Dart side sends the rings'
// scales and the ribbons' sway, never a clock.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Every uniform is a vec4, so no backend can pad them differently.
uniform vec4 uGeom;   // xy: box size (logical px); z: disc radius R; w: one device pixel
uniform vec4 uState;  // x: bloom-in 0..1; y: ribbons' sway (px); z: ribbons' stretch
uniform vec4 uPush0;  // tiers 0..3: how far each is pushed out (its horizontal scale)
uniform vec4 uPush1;  // x: tier 4; y: the push's share at the top and bottom
// One colour per element, in OrbRings.elements order (a full ring's top
// colour), then the full rings' side colours, then the ribbons'.
uniform vec4 uC0;
uniform vec4 uC1;
uniform vec4 uC2;
uniform vec4 uC3;
uniform vec4 uC4;
uniform vec4 uC5;
uniform vec4 uC6;
uniform vec4 uC7;
uniform vec4 uC8;
uniform vec4 uC9;
uniform vec4 uC10;
uniform vec4 uC11;
uniform vec4 uC12;
uniform vec4 uC13;
uniform vec4 uS9;
uniform vec4 uS10;
uniform vec4 uS11;
uniform vec4 uS12;
uniform vec4 uS13;
uniform vec4 uRibNear;
uniform vec4 uRibFar;
uniform vec4 uRibAccent;
uniform vec4 uSparkle;

out vec4 fragColor;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Premultiplied source-over, exactly what drawing one thing on another does.
vec4 over(vec4 dst, vec4 src) {
  return src + dst * (1.0 - src.a);
}

// Across an element: a0 over the core (half-width h), down to a1 over the
// bright edge e, then to nothing over the glow g — straight lines between,
// exactly what the Canvas painter's mesh interpolates.
float prof(float d, float h, float e, float g, float a0, float a1) {
  if (d <= h) return a0;
  if (d <= h + e) return mix(a0, a1, (d - h) / e);
  if (d <= h + e + g) return a1 * (1.0 - (d - h - e) / g);
  return 0.0;
}

// A lens at the sides. rho: distance from the middle in R; al: degrees
// from the horizontal. It is w = 1 - (al/tip)^2 as thick as at the
// horizontal, its middle drifts out by dr as it thins, and it fades by
// smoothstep(f0, f1, w).
vec4 lens(vec4 acc, float rho, float al, float r0, float dr, float h0,
          float e, float g, float a0, float a1, float tip, float f0,
          float f1, vec3 col) {
  if (al >= tip) return acc;
  float w = 1.0 - (al / tip) * (al / tip);
  float d = abs(rho - (r0 + dr * (1.0 - w)));
  float h = h0 * w;
  if (d >= h + e + g) return acc;
  float a = prof(d, h, e, g, a0, a1) * smoothstep(f0, f1, w) * uState.x;
  return over(acc, vec4(col * a, a));
}

// A full ring, its colour turning from top to side within `side` degrees
// of the horizontal.
vec4 ring(vec4 acc, float rho, float al, float r0, float h, float e,
          float g, float a0, float a1, float side, vec3 top, vec3 sideCol) {
  float d = abs(rho - r0);
  if (d >= h + e + g) return acc;
  float ts = clamp(1.0 - (al / side) * (al / side), 0.0, 1.0);
  float a = prof(d, h, e, g, a0, a1) * uState.x;
  return over(acc, vec4(mix(top, sideCol, ts) * a, a));
}

// The ribbons' shape (OrbRings.ribbonMid / ribbonHalf / ribbonEnvelope /
// sheetAlpha).
float ribbonMid(float u, float side) {
  return side > 0.0 ? -0.045 + 0.13 * u + 0.40 * u * u
                    : -0.084 - 0.58 * u + 1.05 * u * u;
}
float ribbonHalf(float u, float side) {
  return side > 0.0 ? 0.095 + 0.29 * u * u : 0.16 - 0.12 * u + 0.33 * u * u;
}
float ribbonEnvelope(float u) {
  return smoothstep(-0.05, 0.04, u) * (1.0 - smoothstep(0.55, 1.0, u));
}
float sheetAlpha(float u) {
  return ribbonEnvelope(u) * (0.12 + 0.55 * (1.0 - smoothstep(0.05, 0.55, u)));
}

// One strand: a line of half-width hw at height y, fading to nothing at
// its edges (a tent, like the mesh's three rows).
vec4 strand(vec4 acc, float py, float y, float hw, float a, vec3 col) {
  float cov = 1.0 - abs(py - y) / hw;
  if (cov <= 0.0) return acc;
  float k = a * cov * uState.x;
  return over(acc, vec4(col * k, k));
}

// A sparkle at x (R) and dy above or below the ribbon's middle: flat to
// 0.45 of its radius, then fading to its edge.
vec4 sparkle(vec4 acc, vec2 p, float side, float x, float dy, float r,
             float a) {
  float sx = side * x;
  vec2 at = vec2(sx, ribbonMid((x - 1.0) / 1.25, side) + dy);
  float d = length(p - at);
  if (d >= r) return acc;
  float k = (d <= 0.45 * r ? a : a * (r - d) / (0.55 * r)) * uState.x;
  return over(acc, vec4(uSparkle.rgb * k, k));
}

// A tiny hash for the dither (no sin: it stays exact on every GPU).
float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 size = uGeom.xy;
  float R = uGeom.z;
  float px = uGeom.w;
  vec2 q = p - size * 0.5;
  float rho0 = length(q) / R;
  vec4 acc = vec4(0.0);

  // Under the disc nothing shows (VoiceOrb paints it opaque on top).
  if (rho0 < 0.96) {
    fragColor = acc;
    return;
  }

  // THE RINGS. Each tier is scaled out by its push — more at the sides
  // than at the top — so each is looked up in its own, unpushed space.
  if (rho0 < 1.95) {
    // A scale is never below half (the pushes are a few per cent): the
    // program's warm-up draw sets only the first few numbers, and nothing
    // here may divide by the zeros it leaves.
    vec4 s0 = max(uPush0, vec4(0.5));
    float s4 = max(uPush1.x, 0.5);
    float top = uPush1.y;
    vec2 k0 = q / (R * vec2(s0.x, 1.0 + top * (s0.x - 1.0)));
    vec2 k1 = q / (R * vec2(s0.y, 1.0 + top * (s0.y - 1.0)));
    vec2 k2 = q / (R * vec2(s0.z, 1.0 + top * (s0.z - 1.0)));
    vec2 k3 = q / (R * vec2(s0.w, 1.0 + top * (s0.w - 1.0)));
    vec2 k4 = q / (R * vec2(s4, 1.0 + top * (s4 - 1.0)));
    vec2 k5 = q / R;
    float r0 = length(k0), r1 = length(k1), r2 = length(k2);
    float r3 = length(k3), r4 = length(k4), r5 = length(k5);
    float a0 = degrees(atan(abs(k0.y), abs(k0.x)));
    float a1 = degrees(atan(abs(k1.y), abs(k1.x)));
    float a2 = degrees(atan(abs(k2.y), abs(k2.x)));
    float a3 = degrees(atan(abs(k3.y), abs(k3.x)));
    float a4 = degrees(atan(abs(k4.y), abs(k4.x)));
    float a5 = degrees(atan(abs(k5.y), abs(k5.x)));

    // The haze at the sides.
    acc = lens(acc, r0, a0, 1.140, 0.0, 0.040, 0.012, 0.020, 0.95, 0.95, 60.0, 0.0, 1.0, uC0.rgb);
    acc = lens(acc, r2, a2, 1.278, 0.0, 0.024, 0.010, 0.015, 0.95, 0.95, 48.0, 0.0, 1.0, uC1.rgb);
    acc = lens(acc, r2, a2, 1.405, 0.0, 0.030, 0.012, 0.020, 1.00, 1.00, 40.0, 0.0, 1.0, uC2.rgb);
    acc = lens(acc, r3, a3, 1.537, 0.0, 0.022, 0.012, 0.020, 0.95, 0.95, 38.0, 0.0, 1.0, uC3.rgb);
    acc = lens(acc, r4, a4, 1.655, 0.0, 0.012, 0.010, 0.080, 0.60, 0.50, 36.0, 0.0, 1.0, uC4.rgb);
    // The lenses: the speaker cones.
    acc = lens(acc, r1, a1, 1.207, 0.006, 0.043, 0.008, 0.020, 1.0, 0.45, 49.0, 0.0, 0.15, uC5.rgb);
    acc = lens(acc, r2, a2, 1.340, 0.0, 0.036, 0.008, 0.018, 1.0, 0.45, 38.0, 0.0, 0.4, uC6.rgb);
    acc = lens(acc, r3, a3, 1.478, 0.004, 0.035, 0.008, 0.018, 1.0, 0.45, 37.0, 0.05, 0.4, uC7.rgb);
    acc = lens(acc, r4, a4, 1.608, 0.008, 0.040, 0.006, 0.016, 1.0, 0.40, 38.0, 0.0, 0.2, uC8.rgb);
    // The full rings.
    acc = ring(acc, r0, a0, 1.099, 0.009, 0.008, 0.022, 1.0, 0.45, 50.0, uC9.rgb, uS9.rgb);
    acc = ring(acc, r2, a2, 1.279, 0.007, 0.007, 0.028, 1.0, 0.35, 50.0, uC10.rgb, uS10.rgb);
    acc = ring(acc, r3, a3, 1.460, 0.005, 0.007, 0.025, 1.0, 0.30, 36.0, uC11.rgb, uS11.rgb);
    acc = ring(acc, r4, a4, 1.637, 0.005, 0.007, 0.020, 1.0, 0.30, 38.0, uC12.rgb, uS12.rgb);
    acc = ring(acc, r5, a5, 1.815, 0.003, 0.007, 0.015, 1.0, 0.25, 40.0, uC13.rgb, uS13.rgb);
  }

  // THE RIBBONS — light-wave strands twisting out to both sides, swaying
  // and swelling a little with the voice (sway and stretch undone here).
  vec2 rp = vec2(q.x / R, (q.y - uState.y) / (R * max(uState.z, 0.5)));
  float X = abs(rp.x);
  if (X > 0.97 && X < 2.30) {
    float side = rp.x > 0.0 ? 1.0 : -1.0;
    float u = (X - 1.0) / 1.25;
    float mid = ribbonMid(u, side);
    float hh = ribbonHalf(u, side);
    if (abs(rp.y - mid) < hh + 0.25) {
      vec3 col = mix(uRibNear.rgb, uRibFar.rgb, smoothstep(0.0, 0.9, u));
      // The sheet: full at the middle, 0.85 at 0.6 of the way out,
      // nothing at the edge.
      float t = abs(rp.y - mid) / hh;
      if (t < 1.0) {
        float k = (t <= 0.6 ? mix(1.0, 0.85, t / 0.6) : 0.85 * (1.0 - (t - 0.6) / 0.4)) *
                  sheetAlpha(u) * uState.x;
        acc = over(acc, vec4(col * k, k));
      }
      float env = ribbonEnvelope(u);
      float ph = TAU * 1.4 * u + (side > 0.0 ? 0.4 : 2.1);
      for (int j = 0; j < 20; j++) {
        float th = ph + TAU * float(j) / 20.0;
        float a = 0.60 * env * (0.35 + 0.65 * (0.5 + 0.5 * cos(th)));
        acc = strand(acc, rp.y, mid + hh * sin(th), 0.009, a, col);
      }
      float aa = 0.70 * env;
      float pa = TAU * 0.8 * u;
      acc = strand(acc, rp.y, mid + 0.35 * hh * sin(pa + (side > 0.0 ? 0.9 : 3.3)), 0.022, aa, uRibAccent.rgb);
      acc = strand(acc, rp.y, mid + 0.35 * hh * sin(pa + (side > 0.0 ? 2.6 : 5.0)), 0.022, aa, uRibAccent.rgb);
      if (side > 0.0) {
        acc = sparkle(acc, rp, side, 1.08, -0.06, 0.012, 0.85);
        acc = sparkle(acc, rp, side, 1.22, 0.05, 0.014, 0.75);
        acc = sparkle(acc, rp, side, 1.34, -0.08, 0.010, 0.80);
        acc = sparkle(acc, rp, side, 1.47, 0.03, 0.015, 0.90);
        acc = sparkle(acc, rp, side, 1.58, 0.12, 0.011, 0.65);
        acc = sparkle(acc, rp, side, 1.68, -0.04, 0.013, 0.80);
        acc = sparkle(acc, rp, side, 1.80, 0.14, 0.016, 0.70);
        acc = sparkle(acc, rp, side, 1.40, 0.16, 0.010, 0.55);
      } else {
        acc = sparkle(acc, rp, side, 1.06, 0.03, 0.013, 0.85);
        acc = sparkle(acc, rp, side, 1.18, -0.08, 0.011, 0.75);
        acc = sparkle(acc, rp, side, 1.30, 0.07, 0.015, 0.85);
        acc = sparkle(acc, rp, side, 1.43, -0.05, 0.010, 0.70);
        acc = sparkle(acc, rp, side, 1.55, 0.10, 0.013, 0.65);
        acc = sparkle(acc, rp, side, 1.66, -0.09, 0.011, 0.80);
        acc = sparkle(acc, rp, side, 1.78, 0.04, 0.015, 0.70);
        acc = sparkle(acc, rp, side, 1.50, 0.19, 0.010, 0.55);
      }
    }
  }

  // Half a step of dither, so the soft glows do not band into rings.
  float n = (hash12(p / px) - 0.5) / 255.0;
  acc.rgb = clamp(acc.rgb + n, vec3(0.0), vec3(acc.a));
  fragColor = acc;
}
