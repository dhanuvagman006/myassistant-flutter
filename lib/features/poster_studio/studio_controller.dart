import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/log.dart';
import '../poster/poster_controller.dart' show PickedPhoto;
import '../poster/poster_painter.dart' show decodePosterPhoto;
import '../poster/poster_share.dart';
import 'studio_api.dart';
import 'studio_fonts.dart';
import 'studio_models.dart';
import 'studio_painter.dart';
import 'studio_palettes.dart';
import 'studio_templates.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE POSTER STUDIO'S STATE (2026-09-30). One poster at a time: the
///  words (his, or the server's design of his request), the look (a
///  template, a palette, an arrangement), and the picture behind it — the
///  server's AI background, his own photo, or the template's drawn art
///  when neither is there. Every change re-lays the poster and re-measures
///  its contrast; the preview shows the last finished layout, so typing
///  never flickers.
/// ─────────────────────────────────────────────────────────────────────────
class PosterStudioController extends ChangeNotifier {
  PosterStudioController({
    PosterStudioApi? api,
    PosterShare? sharer,
    Future<ui.Image> Function(Uint8List bytes)? decode,
    this.pollEvery = const Duration(seconds: 2),
    this.pollFor = const Duration(seconds: 100),
  })  : api = api ?? HttpPosterStudioApi(),
        _sharer = sharer,
        _decode = decode ?? ((b) => decodePosterPhoto(b));

  static PosterStudioController instance = PosterStudioController();

  final PosterStudioApi api;
  final PosterShare? _sharer;
  PosterShare get sharer => _sharer ?? PosterShare.instance;
  final Future<ui.Image> Function(Uint8List bytes) _decode;
  final Duration pollEvery;
  final Duration pollFor;

  /// What he asked for, in his words.
  String request = '';
  EventDesign design = const EventDesign();
  EventTemplate template = studioTemplates.first;
  StudioPalette palette = studioPalette('neon');

  /// He chose the colours: another template keeps them.
  bool paletteChosen = false;
  int variant = 0;
  int seed = 1;

  /// The picture behind the words, and where it came from:
  /// 'ai' | 'photo' | 'none' (the template's drawn art).
  ui.Image? image;
  String imageSource = 'none';
  StudioBackground? aiBackground;
  ui.Image? logo;

  /// The server is writing the words.
  bool designing = false;

  /// A picture is being painted.
  bool generating = false;

  /// Sharing or saving.
  bool busy = false;

  /// AI pictures are off on this server: the drawn art stays.
  bool aiOff = false;

  /// One plain sentence for the screen.
  String? notice;

  /// Missing lines he answered or waved away.
  final Set<String> answered = {};

  /// Brand colours he added, newest first.
  List<Color> brandColours = const [];

  PreparedStudio? prepared;

  int _open = 0, _bg = 0, _prep = 0;
  String? _savedSignature;

  bool get hasPoster => !design.isEmpty;
  List<StudioPrompt> get prompts => studioPrompts(design, answered);
  List<StudioField> get needs => prepared?.needs ?? const [];

  StudioScene get scene => StudioScene(
        design: design,
        template: template,
        palette: palette,
        image: image,
        logo: logo,
        variant: variant,
        seed: seed,
      );

  // ── opening ────────────────────────────────────────────────────────────

  /// `open_poster_studio` from voice or chat: the design's words go
  /// straight onto the poster; the background follows when it is ready.
  /// Returns once the words are laid out.
  Future<void> openDirective(StudioDirective d) async {
    final gen = _reset();
    request = d.request;
    final given = d.design;
    if (given != null) {
      _applyDesign(given);
    } else if (d.request.isNotEmpty) {
      await _designFrom(d.request, gen);
    }
    if (gen != _open) return;
    await refresh();
    if (d.background != null) {
      final g = ++_bg;
      generating = true;
      notifyListeners();
      unawaited(_loadBackground(d.background!, gen, g).whenComplete(() => _doneGenerating(g)));
    } else if (d.backgroundJob != null) {
      unawaited(_pollJob(d.backgroundJob!, gen));
    } else if (hasPoster) {
      unawaited(regenerateImage());
    }
  }

  /// From the studio screen: "Diwali party at our flat on Saturday 7 pm".
  Future<void> startFromRequest(String text, {StudioFormat? format}) async {
    final t = text.trim();
    if (t.isEmpty) return;
    final f = format ?? design.format;
    final gen = _reset();
    request = t;
    design = design.copyWith(format: f);
    await _designFrom(t, gen, format: f);
    if (gen != _open) return;
    await refresh();
    if (hasPoster) unawaited(regenerateImage());
  }

  /// A fresh, empty studio.
  void clear() {
    _reset();
    design = const EventDesign();
    request = '';
    prepared = null;
    notifyListeners();
  }

  int _reset() {
    _bg++;
    answered.clear();
    notice = null;
    variant = 0;
    image = null;
    imageSource = 'none';
    aiBackground = null;
    logo = null;
    generating = false;
    designing = false;
    paletteChosen = false;
    _savedSignature = null;
    return ++_open;
  }

  Future<void> _designFrom(String text, int gen, {StudioFormat? format}) async {
    designing = true;
    notifyListeners();
    try {
      final d = await api.design(text,
          format: format ?? design.format, brandColours: brandColours.take(1).toList());
      if (gen != _open) return;
      _applyDesign(d);
      if (d.source == 'fallback') {
        notice = 'Made from the facts in your words — check each line.';
      }
    } on StudioApiException catch (e) {
      if (gen != _open) return;
      notice = e.friendly("Couldn't design it just now — add the words yourself with Edit text.");
    } catch (e) {
      AppLog.add('poster', 'studio design failed: $e');
      if (gen == _open) notice = "Couldn't design it just now — add the words yourself with Edit text.";
    } finally {
      if (gen == _open) {
        designing = false;
        notifyListeners();
      }
    }
  }

  void _applyDesign(EventDesign d) {
    design = d;
    template = templateForStyle(d.style);
    final p = d.palette;
    palette = p != null && _suits(template, p) ? p : studioPalette(template.palette);
    seed = 1 + (d.title.hashCode & 0xFFFF);
  }

  /// A palette whose lead colour glows on this template's ground.
  static bool _suits(EventTemplate t, StudioPalette p) => t is CorporateCleanTemplate
      ? contrastRatio(p.primary, StudioInk.paper) >= 3
      : contrastRatio(p.primary, StudioInk.night) >= 4.5;

  // ── the picture ────────────────────────────────────────────────────────

  String get _prompt {
    final p = design.backgroundPrompt.trim();
    if (p.isNotEmpty) return p;
    return [design.style, design.title, design.subtitle].where((s) => s.trim().isNotEmpty).join(', ');
  }

  /// Asks the server for a new picture (a new [seed] for a new one). The
  /// current picture stays until the new one has arrived; a failure keeps
  /// it (or the drawn art) and says so.
  Future<void> regenerateImage({int? seed}) async {
    if (!hasPoster) return;
    final gen = _open;
    final g = ++_bg;
    generating = true;
    notice = null;
    notifyListeners();
    try {
      final b = await api.background(
          prompt: _prompt,
          // The picture follows the chosen look, not the first guess.
          style: template.style,
          format: design.format,
          seed: seed ?? this.seed);
      if (g != _bg || gen != _open) return;
      await _loadBackground(b, gen, g);
    } on StudioApiException catch (e) {
      if (g != _bg || gen != _open) return;
      if (e.off) {
        aiOff = true;
        notice = 'AI pictures are off just now — using a drawn background.';
      } else if (e.busy) {
        notice = 'Still painting the last picture — try again in a moment.';
      } else if (e.dailyLimit) {
        notice = e.friendly("That's all the new pictures for today — the drawn background is on.");
      } else {
        notice = e.friendly("Couldn't paint a picture just now — using a drawn background.");
      }
    } catch (e) {
      AppLog.add('poster', 'studio background failed: $e');
      if (g == _bg && gen == _open) notice = "Couldn't paint a picture just now — using a drawn background.";
    } finally {
      _doneGenerating(g);
    }
  }

  /// "Regenerate image": a new seed, so never the same picture again.
  Future<void> newPicture() {
    seed += 1;
    return regenerateImage();
  }

  void _doneGenerating(int g) {
    if (g != _bg) return;
    generating = false;
    notifyListeners();
  }

  Future<void> _loadBackground(StudioBackground b, int gen, int g) async {
    try {
      final bytes = await api.bytes(b);
      final img = await _decode(bytes);
      if (gen != _open || g != _bg) return;
      image = img;
      imageSource = 'ai';
      aiBackground = b;
      aiOff = false;
      await refresh();
    } catch (e) {
      AppLog.add('poster', 'studio background not loaded: $e');
      if (gen == _open && g == _bg) {
        notice = "The picture didn't come through — using a drawn background.";
        notifyListeners();
      }
    }
  }

  /// create_event_poster answered before its picture was done: wait for it.
  Future<void> _pollJob(String jobId, int gen) async {
    final g = ++_bg;
    generating = true;
    notifyListeners();
    final end = DateTime.now().add(pollFor);
    try {
      while (true) {
        if (gen != _open || g != _bg) return;
        StudioJob? j;
        try {
          j = await api.job(jobId);
        } on StudioApiException catch (e) {
          if (e.status == 404) {
            notice = "The picture wasn't kept — tap Regenerate for a new one.";
            return;
          }
        }
        if (gen != _open || g != _bg) return;
        if (j != null && j.status == 'done' && j.background != null) {
          await _loadBackground(j.background!, gen, g);
          return;
        }
        if (j != null && j.status == 'failed') {
          notice = "Couldn't paint a picture this time — using a drawn background.";
          return;
        }
        if (!DateTime.now().isBefore(end)) {
          notice = 'The picture is taking a while — using a drawn background for now.';
          return;
        }
        await Future<void>.delayed(pollEvery);
      }
    } finally {
      _doneGenerating(g);
    }
  }

  /// His own photo behind the words.
  Future<bool> usePhoto(PickedPhoto p) async {
    final g = ++_bg;
    generating = false;
    try {
      final img = await _decode(p.bytes);
      if (g != _bg) return false;
      image = img;
      imageSource = 'photo';
      notice = null;
      await refresh();
      return true;
    } catch (e) {
      AppLog.add('poster', 'studio photo failed: $e');
      notice = "That photo couldn't be used — please pick another.";
      notifyListeners();
      return false;
    }
  }

  /// The template's own drawn art, no picture.
  void useDrawnArt() {
    _bg++;
    generating = false;
    image = null;
    imageSource = 'none';
    unawaited(refresh());
  }

  /// A logo (or a small photo) in the template's logo corner; null
  /// takes it off.
  Future<void> setLogo(PickedPhoto? p) async {
    if (p == null) {
      logo = null;
    } else {
      try {
        logo = await _decode(p.bytes);
      } catch (e) {
        notice = "That picture couldn't be used as a logo.";
      }
    }
    await refresh();
  }

  // ── the look ───────────────────────────────────────────────────────────

  void setTemplate(String id) {
    template = studioTemplate(id);
    if (!paletteChosen) {
      final p = design.palette;
      palette = p != null && _suits(template, p) ? p : studioPalette(template.palette);
    }
    variant = 0;
    unawaited(refresh());
  }

  void setPalette(StudioPalette p) {
    palette = p;
    paletteChosen = true;
    unawaited(refresh());
  }

  void setFormat(StudioFormat f) {
    design = design.copyWith(format: f);
    unawaited(refresh());
  }

  /// Another arrangement and a new seed — and a new picture when the
  /// current one is the AI's.
  void variation() {
    variant = (variant + 1) % template.variants;
    seed += 1;
    unawaited(refresh());
    if (imageSource == 'ai' && !aiOff) unawaited(regenerateImage(seed: seed));
  }

  /// Saves a brand colour (on this phone) and uses it.
  Future<void> addBrandColour(Color c) async {
    brandColours = [c, ...brandColours.where((b) => b != c)].take(4).toList();
    setPalette(StudioPalette.fromBrand(c));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_brandKey, [for (final b in brandColours) toHex(b)]);
    } catch (_) {}
  }

  Future<void> loadBrandColours() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      brandColours = [
        for (final h in prefs.getStringList(_brandKey) ?? const <String>[])
          if (parseHex(h) != null) parseHex(h)!,
      ];
      notifyListeners();
    } catch (_) {}
  }

  static const _brandKey = 'poster_studio_brand_colours';

  // ── the words ──────────────────────────────────────────────────────────

  void setField(StudioField f, String v) {
    design = design.withText(f, v);
    unawaited(refresh());
  }

  /// Every line at once (the Edit text sheet).
  void setAll(Map<StudioField, String> values) {
    var d = design;
    values.forEach((f, v) => d = d.withText(f, v));
    design = d;
    unawaited(refresh());
  }

  /// "Add location?" answered.
  void answer(StudioPrompt p, String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    answered.add(p.key);
    if (p.field == StudioField.details) {
      design = design.copyWith(details: [...design.details, '${p.detailPrefix}$v']);
      unawaited(refresh());
    } else {
      setField(p.field, v);
    }
  }

  /// "Add location?" waved away.
  void skip(StudioPrompt p) {
    answered.add(p.key);
    notifyListeners();
  }

  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  // ── laying out ─────────────────────────────────────────────────────────

  /// Re-lays the poster and measures its contrast. The last one to
  /// finish wins; the preview keeps the previous layout meanwhile.
  Future<void> refresh() async {
    final g = ++_prep;
    notifyListeners();
    if (!hasPoster) {
      prepared = null;
      return;
    }
    final s = scene;
    try {
      await StudioFonts.ensureLoaded();
      final p = await prepareStudio(s);
      if (g != _prep) return;
      prepared = p;
      notifyListeners();
    } catch (e) {
      AppLog.add('poster', 'studio layout failed: $e');
      if (g == _prep) {
        prepared = prepareStudioSync(s);
        notifyListeners();
      }
    }
  }

  // ── the finished poster ────────────────────────────────────────────────

  String get fileName => PosterShare.fileName(design.title, design.dateText);

  Future<Uint8List?> exportPng() async {
    if (!hasPoster) return null;
    await refresh();
    final p = prepared;
    return p == null ? null : renderStudioPng(p);
  }

  /// Sends the poster: WhatsApp by default, else the share menu. A copy
  /// goes to his documents in the background.
  Future<ShareOutcome> share({String app = 'whatsapp', bool saveToPhotos = false}) async {
    // Never a poster with a line that did not fit.
    if (!hasPoster || busy || needs.isNotEmpty) return ShareOutcome.failed;
    busy = true;
    notifyListeners();
    try {
      final png = await exportPng();
      if (png == null) return ShareOutcome.failed;
      final out = await sharer.share(png, name: fileName, app: app, saveToPhotos: saveToPhotos);
      unawaited(_saveFinal(png));
      return out;
    } catch (e) {
      AppLog.add('poster', 'studio share failed: $e');
      return ShareOutcome.failed;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Into his Photos (Android 10+); older phones get the share menu.
  Future<ShareOutcome> saveToPhotos() async {
    if (!hasPoster || busy || needs.isNotEmpty) return ShareOutcome.failed;
    busy = true;
    notifyListeners();
    try {
      final png = await exportPng();
      if (png == null) return ShareOutcome.failed;
      unawaited(_saveFinal(png));
      if (await sharer.saveToPhotos(png, fileName)) {
        notice = 'Saved to your Photos.';
        return ShareOutcome.saved;
      }
      return await sharer.share(png, name: fileName, app: 'any');
    } catch (e) {
      AppLog.add('poster', 'studio save failed: $e');
      return ShareOutcome.failed;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  String get _signature => [
        design.toJson().toString(),
        template.id,
        palette.id,
        palette.primary.toARGB32(),
        variant,
        seed,
        imageSource,
        aiBackground?.id,
        logo?.hashCode,
      ].join('|');

  /// One copy per finished poster in his documents, not one per tap.
  Future<void> _saveFinal(Uint8List png) async {
    final sig = _signature;
    if (sig == _savedSignature) return;
    _savedSignature = sig;
    final ok = await api.saveFinal(png,
        name: fileName, note: 'Event poster: ${design.title.isEmpty ? 'untitled' : design.title}');
    if (!ok) {
      AppLog.add('poster', 'studio poster not saved to documents');
      if (_savedSignature == sig) _savedSignature = null;
    }
  }
}
