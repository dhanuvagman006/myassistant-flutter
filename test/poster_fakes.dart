import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/poster/poster_models.dart';
import 'package:myassistant/features/poster/poster_service.dart';
import 'package:myassistant/features/poster/poster_share.dart';
import 'package:myassistant/models/user_document.dart';

/// The contract fixture, shared verbatim with the backend
/// (tests/fixtures/posters/contract.json there).
Map<String, dynamic> loadContract() =>
    jsonDecode(File('test/fixtures/poster_contract.json').readAsStringSync())
        as Map<String, dynamic>;

/// A tiny real image, so decoding and drawing run for real.
Future<ui.Image> tinyImage({int w = 30, int h = 40, ui.Color? colour}) {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      ui.Paint()..color = colour ?? const ui.Color(0xFF8899AA));
  return rec.endRecording().toImage(w, h);
}

/// An in-memory /posters that behaves like the server for the parts the
/// controller uses: versions, history, needs, conflicts.
class FakePosterApi implements PosterApi {
  FakePosterApi({this.reachable = true});

  bool reachable;
  int _nextId = 100;
  int _nextPhoto = 40;
  final Map<int, Poster> posters = {};
  final Map<int, List<PosterSpec>> history = {};
  final List<String> calls = [];

  /// Set to make the next PATCH answer 409 with this copy.
  Poster? conflictWith;

  /// Set to refuse every PATCH it returns an error for, as the server
  /// refuses one it cannot do (503 unavailable: no ffmpeg for a colour).
  PosterApiException? Function(PosterChange change)? refusePatch;

  /// The spec each successful create was sent.
  final List<Map<String, dynamic>?> createSpecs = [];

  /// Delays every upload (to test a second pick while one is running).
  Duration uploadDelay = Duration.zero;

  /// Set to make uploads answer this error (415 unsupported_type, …).
  PosterApiException? uploadError;

  /// While set, every PATCH waits for it (to test answers that come back
  /// after he moved to another card).
  Completer<void>? patchGate;

  /// Photo downloads: per photo id (else [photoPng]); ids in [photoFails]
  /// fail as unreachable; [photoGate] holds them back.
  final Map<int, Uint8List> photoPngs = {};
  final Set<int> photoFails = {};
  Completer<void>? photoGate;

  void _check() {
    if (!reachable) throw const PosterApiException(0, 'unreachable', 'offline');
  }

  @override
  Future<PhotoUpload> uploadPhoto({
    required Uint8List bytes,
    required String filename,
    required String mime,
    String source = 'gallery',
    int? posterId,
    String colour = 'keep',
  }) async {
    calls.add('upload:${posterId ?? '-'}:$colour');
    await Future<void>.delayed(uploadDelay);
    _check();
    if (uploadError != null) throw uploadError!;
    final photo = PosterPhoto(
        id: _nextPhoto++,
        source: source,
        width: 30,
        height: 40,
        colour: colour,
        variants: const ['original', 'enhanced'],
        reason: 'off');
    photos[photo.id] = photo;
    Poster? p;
    if (posterId != null && posters.containsKey(posterId)) {
      final old = posters[posterId]!;
      history[posterId]!.add(old.spec);
      // As the server: the photo brings its colour onto the card.
      p = old.copyWith(
          version: old.version + 1,
          photo: photo,
          canUndo: true,
          spec: old.spec.copyWith(photoUse: 'enhanced', photoColour: colour));
      posters[posterId] = p;
    }
    return (photo: photo, poster: p);
  }

  @override
  Future<PhotoUpload> photoFromDocument(int documentId, {int? posterId}) =>
      throw UnimplementedError();

  Uint8List? photoPng;
  final Map<int, PosterPhoto> photos = {};

  @override
  Future<Uint8List> photoBytes(int photoId, String variant, {String? colour}) async {
    calls.add('bytes:$photoId:$variant${colour != null ? ':$colour' : ''}');
    if (photoGate != null) await photoGate!.future;
    _check();
    if (photoFails.contains(photoId)) {
      throw const PosterApiException(0, 'unreachable', 'timed out');
    }
    return photoPngs[photoId] ?? photoPng!;
  }

  @override
  Future<PosterPhoto> recolourPhoto(int photoId, String colour) async {
    calls.add('colour:$photoId:$colour');
    _check();
    final ph = PosterPhoto(
        id: photoId, colour: colour, variants: const ['original', 'enhanced'], updatedAt: 2);
    photos[photoId] = ph;
    return ph;
  }

  @override
  Future<UserDocument> keepPhoto(int photoId, String variant) async {
    calls.add('keep:$photoId:$variant');
    _check();
    return UserDocument.fromJson({'id': 900 + photoId, 'filename': 'photo-$photoId.jpg', 'mime': 'image/jpeg'});
  }

  @override
  Future<Poster> create({String occasion = 'birthday', Map<String, dynamic>? spec, int? photoId}) async {
    calls.add('create');
    _check();
    createSpecs.add(spec);
    final id = _nextId++;
    final photo = photoId == null ? null : photos[photoId];
    final s = applyChange(PosterSpec.fromJson({'occasion': occasion, ...?spec}), const PosterChange())
        .spec!;
    final p = Poster(
      id: id,
      occasion: occasion,
      version: 1,
      photo: photo,
      spec: photo == null ? s : s.copyWith(photoUse: 'enhanced', photoColour: photo.colour),
    );
    posters[id] = p;
    history[id] = [];
    return p;
  }

  @override
  Future<Poster?> latest() async {
    _check();
    return posters.isEmpty ? null : posters.values.last;
  }

  @override
  Future<Poster> get(int id) async {
    calls.add('get:$id');
    _check();
    final p = posters[id];
    if (p == null) throw const PosterApiException(404, 'not_found', 'That card was not found.');
    return p;
  }

  @override
  Future<({Poster poster, bool limitReached})> patch(int id, int version, PosterChange change) async {
    calls.add('patch:${jsonEncode(change.toJson())}');
    patchedIds.add(id);
    if (patchGate != null) await patchGate!.future;
    _check();
    final cur = posters[id]!;
    if (conflictWith != null) {
      final c = conflictWith!;
      conflictWith = null;
      posters[id] = c;
      throw PosterApiException(409, 'version_conflict', 'changed elsewhere', poster: c);
    }
    if (version != cur.version) {
      throw PosterApiException(409, 'version_conflict', 'stale', poster: cur);
    }
    final refused = refusePatch?.call(change);
    if (refused != null) throw refused;
    if (change.undo) {
      final h = history[id]!;
      if (h.isEmpty) {
        throw PosterApiException(422, 'nothing_to_undo', 'nothing', poster: cur);
      }
      final p = cur.copyWith(version: cur.version + 1, spec: h.removeLast(), canUndo: h.isNotEmpty);
      posters[id] = p;
      return (poster: p, limitReached: false);
    }
    final r = applyChange(cur.spec, change);
    if (r.spec == null) {
      throw PosterApiException(422, 'need', 'too long', need: r.needs);
    }
    history[id]!.add(cur.spec);
    final p = cur.copyWith(version: cur.version + 1, spec: r.spec, canUndo: true);
    posters[id] = p;
    return (
      poster: p,
      limitReached: change.textSize == 'bigger' && r.spec!.textScale == cur.spec.textScale,
    );
  }

  final List<Uint8List> finals = [];
  final List<int> finalIds = [];
  final List<int> patchedIds = [];

  @override
  Future<UserDocument?> uploadFinal(int id, Uint8List png, int version) async {
    calls.add('final');
    _check();
    if (version != posters[id]?.version) {
      throw PosterApiException(409, 'version_conflict', 'stale', poster: posters[id]);
    }
    finals.add(png);
    finalIds.add(id);
    return null;
  }

  @override
  Future<void> delete(int id) async {
    posters.remove(id);
  }
}

/// PNG bytes of [tinyImage], for photo downloads.
Future<Uint8List> tinyPng({int w = 30, int h = 40, ui.Color? colour}) async {
  final img = await tinyImage(w: w, h: h, colour: colour);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  return bd!.buffer.asUint8List();
}

/// A sharer whose native side answers [reply] to shareImageTo, recording
/// every native call and every share-menu open.
class ShareSpy {
  ShareSpy({this.reply = 'ok', this.saveReply = 'ok'});
  String reply;
  String saveReply;
  final List<MethodCall> native = [];
  final List<String> sheets = [];

  static const channel = MethodChannel('hari/intent');

  PosterShare install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      native.add(call);
      return call.method == 'saveImageToGallery' ? saveReply : reply;
    });
    return PosterShare(
      channel: channel,
      tempDir: () async => Directory.systemTemp.createTempSync('poster_test'),
      sheet: (file, subject) async => sheets.add(file.path),
    );
  }
}
