import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

import 'poster_decor.dart';
import 'poster_fonts.dart';
import 'poster_layout.dart';
import 'poster_models.dart';
import 'poster_palettes.dart';
import 'poster_templates.dart';
import 'signature/signature_model.dart';

/// Everything one card is drawn from.
class PosterScene {
  final PosterSpec spec;

  /// His photo, already decoded (null: the design's emblem stands in).
  final ui.Image? photo;

  /// 'bw' / 'sepia' when the server's clean-up could not apply it (the
  /// original is shown) — then the phone tints it itself.
  final String tint;

  /// Drawn only when [PosterSpec.signature] is on.
  final SignatureData? signature;

  /// Seeds the confetti and petals, so a card never reshuffles itself.
  final int seed;

  const PosterScene({
    required this.spec,
    this.photo,
    this.tint = 'keep',
    this.signature,
    this.seed = 1,
  });
}

/// A laid-out card, ready to paint.
class PreparedPoster {
  final PosterScene scene;
  final PosterTemplate template;
  final PosterPalette palette;
  final PosterLayout layout;
  const PreparedPoster(this.scene, this.template, this.palette, this.layout);

  Size get size => layout.size;
  List<PosterNeed> get needs => layout.needs;
}

PreparedPoster preparePoster(PosterScene s) {
  final t = posterTemplate(s.spec.design);
  final palette = posterPalette(s.spec.colour, deep: t.deepFor(s.spec.colour));
  final photo = s.spec.photoUse == 'none' ? null : s.photo;
  final sig = s.spec.signature && s.signature != null && !s.signature!.isEmpty
      ? s.signature
      : null;
  final layout = layoutPoster(
    spec: s.spec,
    t: t.layout(s.spec.format),
    shapeFor: t.shapeFor,
    palette: palette,
    photoAspect: photo == null ? null : photo.width / photo.height,
    signatureAspect: sig?.aspect,
  );
  return PreparedPoster(s, t, palette, layout);
}

const _bw = ColorFilter.matrix([
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0.2126, 0.7152, 0.0722, 0, 0, //
  0, 0, 0, 1, 0,
]);

const _sepia = ColorFilter.matrix([
  0.393, 0.769, 0.189, 0, 0, //
  0.349, 0.686, 0.168, 0, 0, //
  0.272, 0.534, 0.131, 0, 0, //
  0, 0, 0, 1, 0,
]);

/// Where the photo goes in [frame]: the part of it that shows ([src]),
/// the rectangle it is drawn into ([dst]), and whether a soft blurred copy
/// fills the frame behind it ([fill]).
///
/// Normally the frame is filled edge to edge with [focus] held at its
/// centre; a tall photo is framed from a little above its middle, where
/// faces are, and the frame follows the photo's shape, so usually nothing
/// is cut at all. A photo WIDER than its design's frame allows — a family
/// standing in a row on a 16:9 phone photo — is shown WHOLE at zoom 1,
/// across the frame, over a blurred copy of itself: the people at the ends
/// are never cut off by default (review, 2026-09-26). "Closer" (zoom up
/// to 3, the contract's range) crops in from there.
({Rect src, Rect dst, bool fill}) photoPlacement(ui.Image img, Rect frame, PhotoFocus focus) {
  final iw = img.width.toDouble(), ih = img.height.toDouble();
  final cover = math.max(frame.width / iw, frame.height / ih);
  final wide = iw / ih > frame.width / frame.height * 1.02;
  final scale = wide ? frame.width / iw * focus.zoom : cover * focus.zoom;
  if (scale < cover - 1e-9) {
    // Every row of the photo shows; its sides only once he zooms in.
    final sw = math.min(iw, frame.width / scale);
    final cx = (focus.x * iw).clamp(sw / 2, math.max(sw / 2, iw - sw / 2)).toDouble();
    return (
      src: Rect.fromCenter(center: Offset(cx, ih / 2), width: sw, height: ih),
      dst: Rect.fromCenter(center: frame.center, width: frame.width, height: ih * scale),
      fill: true,
    );
  }
  final sw = frame.width / scale, sh = frame.height / scale;
  var fy = focus.y;
  if (focus.isDefault && ih / iw > frame.height / frame.width * 1.02) fy = 0.42;
  // (max() guards the float error when the photo exactly fills the frame.)
  final cx = (focus.x * iw).clamp(sw / 2, math.max(sw / 2, iw - sw / 2)).toDouble();
  final cy = (fy * ih).clamp(sh / 2, math.max(sh / 2, ih - sh / 2)).toDouble();
  return (
    src: Rect.fromCenter(center: Offset(cx, cy), width: sw, height: sh),
    dst: frame,
    fill: false,
  );
}

/// The part of the photo that shows in [frame] (see [photoPlacement]).
Rect photoSourceRect(ui.Image img, Rect frame, PhotoFocus focus) =>
    photoPlacement(img, frame, focus).src;

/// Draws the card. [ornaments] and [words] are off only in the test that
/// proves no flower, balloon or garland ever lies on a word.
void paintPoster(Canvas c, PreparedPoster r, {bool ornaments = true, bool words = true}) {
  final s = r.scene;
  final l = r.layout;
  final p = r.palette;
  final x = PosterPaintContext(l.size, p, l, s.seed);
  c.save();
  c.clipRect(Offset.zero & l.size);
  r.template.paintBackground(c, x);

  final frame = l.frame;
  if (frame != null) {
    r.template.paintFrame(c, x, frame, l.shape, (clip) {
      final photo = s.spec.photoUse == 'none' ? null : s.photo;
      if (photo != null) {
        final tint = switch (s.tint) {
          'bw' => _bw,
          'sepia' => _sepia,
          _ => null,
        };
        final place = photoPlacement(photo, frame, s.spec.photoFocus);
        c.save();
        c.clipPath(clip);
        final sharp = Paint()
          ..filterQuality = FilterQuality.high
          ..colorFilter = tint;
        if (place.fill) {
          _paintBlurFill(c, photo, frame, tint, p);
          // The photo's top and bottom edges melt into its blurred copy —
          // no hard letterbox line across the frame.
          final d = place.dst;
          final fade = math.min(0.12, 28 / d.height);
          c.saveLayer(d, Paint());
          c.drawImageRect(photo, place.src, d, sharp);
          c.drawRect(
              d,
              Paint()
                ..blendMode = BlendMode.dstIn
                ..shader = ui.Gradient.linear(d.topCenter, d.bottomCenter, const [
                  Color(0x00000000),
                  Color(0xFF000000),
                  Color(0xFF000000),
                  Color(0x00000000),
                ], [
                  0,
                  fade,
                  1 - fade,
                  1
                ]));
          c.restore();
        } else {
          c.drawImageRect(photo, place.src, place.dst, sharp);
        }
        c.restore();
      } else {
        _paintEmblem(c, r, frame, clip);
      }
    });
  }
  if (ornaments) r.template.paintOrnaments(c, x);
  if (!words) {
    c.restore();
    return;
  }
  if (l.divider != null) r.template.paintDivider(c, x, l.divider!, l.dividerWidth / 2);

  final shadows = r.template.textShadows(p);
  for (final b in l.blocks) {
    if (b.role.colour == 'foil') {
      // The foil runs across the words themselves, not the empty column.
      final ink = b.lines.fold<Rect?>(null, (a, e) => a == null ? e : a.expandToInclude(e)) ??
          b.rect;
      final local = ink.shift(-b.offset);
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: foilTextColours(p),
        ).createShader(local);
      c.save();
      c.translate(b.offset.dx, b.offset.dy);
      buildLinePainter(b.text, b.role, b.fontSize, p,
          prefix: b.prefix, foreground: paint, shadows: shadows)
        ..layout(minWidth: b.width, maxWidth: b.width)
        ..paint(c, Offset.zero);
      c.restore();
    } else {
      buildLinePainter(b.text, b.role, b.fontSize, p, prefix: b.prefix, shadows: shadows)
        ..layout(minWidth: b.width, maxWidth: b.width)
        ..paint(c, b.offset);
    }
  }
  if (l.signature != null && s.signature != null) {
    s.signature!.paint(c, l.signature!, p.signatureInk);
  }
  c.restore();
}

/// Behind a wide photo shown whole: the same photo, filling the frame,
/// softly blurred and veiled in the mat's colour — it reads as the photo's
/// own light, not as an empty band — with a faint shadow where the sharp
/// photo begins.
void _paintBlurFill(Canvas c, ui.Image photo, Rect frame, ColorFilter? tint, PosterPalette p) {
  final iw = photo.width.toDouble(), ih = photo.height.toDouble();
  final k = math.max(frame.width / iw, frame.height / ih);
  final src = Rect.fromCenter(
      center: Offset(iw / 2, ih / 2), width: frame.width / k, height: frame.height / k);
  c.drawImageRect(
    photo,
    src,
    frame.inflate(frame.shortestSide * 0.06),
    Paint()
      ..filterQuality = FilterQuality.medium
      ..colorFilter = tint
      ..imageFilter = ui.ImageFilter.blur(
          sigmaX: frame.shortestSide * 0.045,
          sigmaY: frame.shortestSide * 0.045,
          tileMode: TileMode.clamp),
  );
  c.drawRect(frame, Paint()..color = p.mat.withValues(alpha: 0.2));
}

/// No photo: the age, else the name's first letter, else a heart, in the
/// design's frame.
void _paintEmblem(Canvas c, PreparedPoster r, Rect frame, Path clip) {
  final p = r.palette;
  final spec = r.scene.spec;
  c.save();
  c.clipPath(clip);
  c.drawRect(
      frame,
      Paint()
        ..shader = ui.Gradient.radial(frame.center, frame.width * 0.7,
            p.deep ? [p.glow, p.bgTop] : [p.mat, Color.lerp(p.petalLight, p.bgBottom, 0.4)!]));
  c.restore();
  final name = spec.name.trim();
  String? mark;
  String family = PosterFonts.displayBold;
  if (spec.age != null && spec.age! > 0) {
    mark = '${spec.age}';
  } else if (name.isNotEmpty) {
    mark = name.characters.first;
    family = PosterFonts.displayItalic;
  }
  if (mark == null) {
    final heart = heartPath(frame.center, frame.width * 0.22);
    c.drawPath(
        heart,
        Paint()
          ..shader = ui.Gradient.linear(frame.topCenter, frame.bottomCenter,
              [p.petalLight, p.petal, p.petalDeep], [0, 0.5, 1]));
    return;
  }
  final size = frame.height * (mark.length > 2 ? 0.38 : 0.5);
  final role = RoleStyle(family: family, bold: true, size: size, colour: 'foil', height: 1);
  final probe = buildLinePainter(mark, role, size, p)..layout(maxWidth: frame.width * 0.9);
  final o = frame.center - Offset(probe.width / 2, probe.height / 2);
  final rect = Rect.fromLTWH(0, 0, probe.width, probe.height);
  c.save();
  c.translate(o.dx, o.dy);
  buildLinePainter(mark, role, size, p,
      foreground: Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: foilTextColours(p),
        ).createShader(rect))
    ..layout(maxWidth: frame.width * 0.9)
    ..paint(c, Offset.zero);
  c.restore();
}

/// Records the card once; the preview replays the picture at any size.
ui.Picture recordPoster(PreparedPoster r) {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Offset.zero & r.size);
  paintPoster(c, r);
  return rec.endRecording();
}

/// The card as the PNG he shares: 1080×1350 (or 1080×1920 for a status).
Future<Uint8List> renderPosterPng(PosterScene scene) async {
  await PosterFonts.ensureLoaded();
  final r = preparePoster(scene);
  final pic = recordPoster(r);
  final img = await pic.toImage(r.size.width.round(), r.size.height.round());
  pic.dispose();
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bytes!.buffer.asUint8List();
}

/// Decodes photo bytes into an image for the card.
Future<ui.Image> decodePosterPhoto(Uint8List bytes, {int maxEdge = 2048}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final desc = await ui.ImageDescriptor.encoded(buffer);
  final long = math.max(desc.width, desc.height);
  final k = long > maxEdge ? maxEdge / long : 1.0;
  final codec = await desc.instantiateCodec(
    targetWidth: (desc.width * k).round(),
    targetHeight: (desc.height * k).round(),
  );
  final frame = await codec.getNextFrame();
  codec.dispose();
  desc.dispose();
  buffer.dispose();
  return frame.image;
}
