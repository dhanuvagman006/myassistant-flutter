// THE SPACE BEHIND THE LISTENING ORB, drawn by the GPU in one pass
// (2026-09-24, GPU pass). See _BackdropPainter in
// lib/widgets/voice_orb.dart, which this replaces when it loads.
//
// WHY A SHADER. The Canvas version opened a full-width offscreen layer on
// every frame of every voice session, filled it with three big gradient
// clouds, five ring strokes and three pulses, built and stroked two
// 121-point paths twice each, then ran a second full-size pass to fade the
// top and bottom and composited the layer back. On his phone's Mali-G57
// that was the most expensive thing the app drew. Here every pixel works
// out its own colour once: no layer, no paths, no second pass, one
// rectangle.
//
// THE PICTURE IS THE SAME. Every number below is the Canvas version's
// number, in the same order of painting (aurora, tunnel, pulses, liquid
// ring, comets, then the top/bottom fade and the bloom-in). Only the 42
// dust motes stay on the Canvas, drawn after this with the same fade.
//
// PRECISION. Mali runs mediump as 16-bit floats, which cannot hold a
// screen coordinate to the pixel, so everything here is highp. Nothing
// that grows without limit comes in: time arrives as angles already
// wrapped to one turn by the Dart side.

#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// Every uniform is a vec4, so no backend can pad them differently.
uniform vec4 uGeom;    // xy: box size (logical px); z: orb radius; w: one device pixel
uniform vec4 uState;   // x: bloom-in 0..1; y: voice level; z: pulses 0..1; w: thinking 0..1
uniform vec4 uClouds;  // xy: left cloud centre; zw: right cloud centre
uniform vec4 uCloudA;  // xyz: the three clouds' strength; w: the tunnel's breath
uniform vec4 uPhase;   // x: the round-the-orb sweep's turn; y: pulse clock 0..1; z: comet angle
uniform vec4 uLiquid0; // xyz: first strand's three ripple phases; w: its amplitude
uniform vec4 uLiquid1; // the second strand, the same way
uniform vec4 uViolet;  // rgb: the accent
uniform vec4 uPink;    // rgb: its partner
uniform vec4 uSweep0;  // rgb: the tunnel's left colour
uniform vec4 uSweep1;  // rgb: its dark middle
uniform vec4 uSweep2;  // rgb: its right colour

out vec4 fragColor;

const float PI = 3.14159265359;
const float TAU = 6.28318530718;

// Premultiplied source-over, exactly what drawing one thing on another does.
vec4 over(vec4 dst, vec4 src) {
  return src + dst * (1.0 - src.a);
}

// How much of a pixel a band of half-width h round a line covers, when the
// pixel's centre is d from the line — anti-aliased over one device pixel,
// and right for bands thinner than a pixel too.
float band(float d, float h, float px) {
  d = abs(d);
  return clamp((h - d) / px + 0.5, 0.0, 1.0) -
         clamp((-h - d) / px + 0.5, 0.0, 1.0);
}

// A radial gradient clouded into an oval (squashed to 0.62 high), stops
// 0 / 0.45 / 1 at full, 35% and no strength.
float cloud(vec2 p, vec2 at, float radius, float a) {
  vec2 q = p - at;
  q.y /= 0.62;
  float t = length(q) / radius;
  if (t >= 1.0) return 0.0;
  return t < 0.45 ? mix(a, a * 0.35, t / 0.45)
                  : mix(a * 0.35, 0.0, (t - 0.45) / 0.55);
}

// The tunnel's left-to-right colour: accent, ink, partner.
vec3 sweep(float u) {
  u = clamp(u, 0.0, 1.0);
  return u < 0.5 ? mix(uSweep0.rgb, uSweep1.rgb, u * 2.0)
                 : mix(uSweep1.rgb, uSweep2.rgb, (u - 0.5) * 2.0);
}

// The colour that runs round the orb, turning slowly: accent, partner, a
// blend of the two, and back.
vec3 around(float theta) {
  float t = fract((theta - uPhase.x) / TAU);
  vec3 v = uViolet.rgb, k = uPink.rgb, m = mix(v, k, 0.4);
  if (t < 0.4) return mix(v, k, t / 0.4);
  if (t < 0.75) return mix(k, m, (t - 0.4) / 0.35);
  return mix(m, v, (t - 0.75) / 0.25);
}

// Distance to an ellipse with half-axes ab, near its outline (the first
// order estimate: the implicit value over the length of its gradient).
float ellipse(vec2 q, vec2 ab) {
  vec2 k = q / ab;
  float k0 = length(k);
  float g = length(q / (ab * ab));
  return (k0 - 1.0) * k0 / max(g, 1e-6);
}

// The liquid ring: its radius wanders with three harmonics. Returns the
// distance to it, measured square to the ring (not just along the radius,
// which would thicken it where it ripples steeply).
float liquid(float rho, float theta, float base, vec4 ph) {
  float a = ph.w;
  float s3 = 3.0 * theta + ph.x, s5 = 5.0 * theta - ph.y, s8 = 8.0 * theta + ph.z;
  float R = base + a * (0.55 * sin(s3) + 0.30 * sin(s5) + 0.15 * sin(s8));
  float dR = a * (1.65 * cos(s3) + 1.50 * cos(s5) + 1.20 * cos(s8));
  return (rho - R) / sqrt(1.0 + (dR * dR) / (R * R));
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
  float r = uGeom.z;
  float px = uGeom.w;
  float appear = uState.x, level = uState.y, pulseAmt = uState.z, think = uState.w;
  vec2 c = size * 0.5;
  vec2 q = p - c;
  float rho = length(q);

  vec4 acc = vec4(0.0);

  // 1. AURORA — two soft clouds of the accent and its partner, drifting,
  // and a fainter blend of both round the orb.
  float a1 = cloud(p, uClouds.xy, r * 2.7, uCloudA.x);
  acc = over(acc, vec4(uViolet.rgb * a1, a1));
  float a2 = cloud(p, uClouds.zw, r * 2.5, uCloudA.y);
  acc = over(acc, vec4(uPink.rgb * a2, a2));
  float a3 = cloud(p, c, r * 1.8, uCloudA.z);
  acc = over(acc, vec4(mix(uViolet.rgb, uPink.rgb, 0.45) * a3, a3));

  // 3. THE TUNNEL — five thin ovals, breathing very slightly.
  vec3 tunnel = sweep(p.x / size.x);
  float breathe = uCloudA.w;
  for (int i = 0; i < 5; i++) {
    float fi = float(i);
    float mult = i == 0 ? 1.39 : i == 1 ? 1.91 : i == 2 ? 2.42 : i == 3 ? 2.9 : 3.4;
    vec2 ab = vec2(r * mult, r * (1.3 + fi * 0.16)) * breathe;
    float a = 0.30 * (1.0 - fi / 5.0) * band(ellipse(q, ab), 0.6, px);
    acc = over(acc, vec4(tunnel * a, a));
  }

  // Everything left hugs the orb (the liquid ring's deepest trough at
  // 0.98 r less its 4 px glow, out to the pulses' 2.03 r): skip the angle
  // maths beyond its reach.
  if (rho > r * 0.95 - 6.0 && rho < r * 2.05 + 3.0) {
    float theta = atan(q.y, q.x);
    vec3 ring = around(theta);

    // 4. PULSES rolling outward.
    if (pulseAmt > 0.01) {
      for (int i = 0; i < 3; i++) {
        float ph = fract(uPhase.y + float(i) / 3.0);
        float fade = (1.0 - ph) * (1.0 - ph);
        float w = 0.6 + 2.2 * (1.0 - ph);
        float a = fade * pulseAmt * (0.35 + level * 0.55) *
                  band(rho - r * (1.08 + ph * 0.95), w * 0.5, px);
        acc = over(acc, vec4(ring * a, a));
      }
    }

    // 5. THE LIQUID RING — two strands out of step, each a soft wide
    // stroke under a crisp one.
    float d0 = liquid(rho, theta, r * 1.12, uLiquid0);
    float wide0 = (0.10 + level * 0.10) * band(d0, 4.0, px);
    acc = over(acc, vec4(ring * wide0, wide0));
    float thin0 = 0.9 * band(d0, 1.0, px);
    acc = over(acc, vec4(ring * thin0, thin0));
    float d1 = liquid(rho, theta, r * 1.155, uLiquid1);
    float wide1 = (0.10 + level * 0.10) * band(d1, 4.0, px);
    acc = over(acc, vec4(ring * wide1, wide1));
    float thin1 = 0.5 * band(d1, 0.6, px);
    acc = over(acc, vec4(ring * thin1, thin1));

    // 6. THINKING — two comets chasing round the orb: an arc of 0.84 of a
    // half turn, round-capped, fading in from its tail.
    if (think > 0.01) {
      float R = r * 1.26;
      vec3 head = mix(uPink.rgb, vec3(1.0), 0.3);
      for (int k = 0; k < 2; k++) {
        float start = uPhase.z + float(k) * PI;
        float t = fract((theta - start) / TAU);
        float d;
        if (t <= 0.42) {
          d = abs(rho - R);
        } else {
          float end = start + PI * 0.84;
          d = min(length(q - R * vec2(cos(start), sin(start))),
                  length(q - R * vec2(cos(end), sin(end))));
        }
        vec4 col = t < 0.3 ? vec4(uViolet.rgb, t / 0.3)
                 : t < 0.42 ? vec4(mix(uViolet.rgb, head, (t - 0.3) / 0.12), 1.0)
                 : vec4(head, 1.0);
        float a = col.a * think * (1.0 - float(k) * 0.45) * band(d, 1.3, px);
        acc = over(acc, vec4(col.rgb * a, a));
      }
    }
  }

  // Melt away toward the top and bottom (0 -> 1 over the first and last
  // 22% of the height), and the bloom-in.
  float v = p.y / size.y;
  float fade = v < 0.22 ? v / 0.22 : v > 0.78 ? (1.0 - v) / 0.22 : 1.0;
  acc *= clamp(fade, 0.0, 1.0) * appear;

  // Half a step of dither, so the dark ground under the clouds does not
  // band into rings.
  float n = (hash12(p / px) - 0.5) / 255.0;
  acc.rgb = clamp(acc.rgb + n, vec3(0.0), vec3(acc.a));
  fragColor = acc;
}
