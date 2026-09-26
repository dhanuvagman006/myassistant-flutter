import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../core/log.dart';
import '../../services/auth_service.dart';
import 'poster_fonts.dart';
import 'poster_models.dart';
import 'poster_painter.dart';
import 'poster_service.dart';
import 'poster_share.dart';
import 'signature/signature_model.dart';
import 'signature/signature_store.dart';

/// A photo he just picked, before any server has seen it.
class PickedPhoto {
  final Uint8List bytes;
  final String mime;

  /// 'gallery' | 'camera' | 'share' | 'document'
  final String source;
  const PickedPhoto(this.bytes, {this.mime = 'image/jpeg', this.source = 'gallery'});
}

/// The camera (or his photos) are switched off for this app in the phone's
/// settings. Not the same as closing the picker: asking "try again?" would
/// only fail the same way, so he is shown the way to Settings instead.
class PhotoAccessDenied implements Exception {
  /// 'camera' | 'gallery'
  final String source;
  const PhotoAccessDenied(this.source);

  @override
  String toString() => 'PhotoAccessDenied($source)';
}

/// One change waiting for the server, and the card it was made on.
class _Queued {
  _Queued(this.posterId, this.change);
  final int posterId;
  final PosterChange change;
}

/// ─────────────────────────────────────────────────────────────────────────
///  THE CARD ON SCREEN — one at a time, shared by the card screen and the
///  assistant's device actions.
///
///  Local first: every change shows at once on the preview, then goes to
///  the server in order (PATCH with the version it last saw). The server's
///  answer replaces the local copy; a version conflict adopts the server's
///  card; a line over its limit is taken back and he is ASKED to shorten
///  it. When the server cannot be reached the change is KEPT, in order, and
///  sent again on the next change or a little later — a correction to her
///  name made on a weak connection must never quietly come undone
///  (review, 2026-09-26). The card keeps working on this phone meanwhile:
///  it still draws and shares.
///
///  Every answer is tied to the card it was asked for: one that comes back
///  after he opened another card never lands on the new one.
/// ─────────────────────────────────────────────────────────────────────────
class PosterController extends ChangeNotifier {
  PosterController({
    PosterApi? api,
    PosterShare? sharer,
    SignatureStore? signatures,
    Future<ui.Image> Function(Uint8List bytes)? decode,
    this.retryAfter = const Duration(seconds: 8),
  })  : api = api ?? HttpPosterApi(),
        sharer = sharer ?? PosterShare.instance,
        signatures = signatures ?? SignatureStore.instance,
        _decode = decode ?? decodePosterPhoto;

  static PosterController instance = PosterController();

  final PosterApi api;
  final PosterShare sharer;
  final SignatureStore signatures;
  final Future<ui.Image> Function(Uint8List bytes) _decode;

  /// How soon changes kept on the phone are tried again (doubling, up to
  /// eight times this, while the server stays out of reach).
  final Duration retryAfter;

  // ── state ──────────────────────────────────────────────────────────────

  /// 'poster' — the card; 'photo' — a photo made clearer, on its own.
  String mode = 'poster';

  Poster? poster;

  /// The last copy the server confirmed (what a failed change returns to).
  Poster? _server;

  /// Bumped whenever another card takes the screen: an answer for an older
  /// generation is not for the card on screen.
  int _gen = 0;

  /// The decoded photo, and which photo it IS ([_photoId]; -1 for one just
  /// picked) in which colours ([_photoTone]). The card draws it only when
  /// it belongs to the card's own photo — never the last card's picture
  /// while this one's is on its way.
  ui.Image? photo;
  int? _photoId;
  String _photoTone = 'keep';
  String? _photoKey;
  Future<void>? _photoLoad;
  bool photoLoading = false;

  /// The card's photo could not be fetched (and the phone has no copy).
  bool photoFailed = false;

  /// Bytes of the photo he picked, keyed by photo id (-1 until uploaded).
  final Map<int, Uint8List> _localBytes = {};

  /// A photo picked while the server was out of reach, for a card the
  /// server knows: it stays on the card here and goes up when it answers.
  PickedPhoto? _pendingPhoto;

  /// The shared picture of a card whose changes had not all reached the
  /// server yet: saved to his documents once they have (and dropped if he
  /// changes the card again — it would no longer match).
  ({int posterId, Uint8List png})? _pendingFinal;

  /// Photo mode: the photo on its own, before and after the clean-up.
  PosterPhoto? loosePhoto;
  ui.Image? looseOriginal;
  ui.Image? looseEnhanced;
  int _looseGen = 0;

  SignatureData? signature;

  /// Lines he must shorten (over a limit, or too long for the card).
  List<PosterNeed> needs = const [];

  /// A short, kind line for the status chip ("Saved to your Photos").
  String? notice;

  /// True while nothing reaches the server: the card lives on the phone.
  bool offline = false;

  /// "Bigger" was asked for at the largest size.
  bool limitReached = false;
  bool busy = false;

  final List<PosterSpec> _history = [];
  final List<_Queued> _queue = [];
  bool _flushing = false;
  bool _adding = false;
  Timer? _retry;
  int _retries = 0;

  PosterSpec get spec => poster?.spec ?? const PosterSpec();
  bool get canUndo => _history.isNotEmpty || (poster?.canUndo ?? false);

  /// A photo is being added (shown at once; the server copy on its way).
  bool get addingPhoto => _adding;

  /// Changes made on this phone that the server has not got yet.
  bool get hasUnsent => _queue.isNotEmpty || _pendingPhoto != null;

  /// The decoded photo, when it is the card's own photo.
  ui.Image? get _cardPhoto {
    final ph = poster?.photo;
    return ph != null && _photoId == ph.id ? photo : null;
  }

  /// True when the card can be drawn as he means it: no photo wanted, or
  /// the card's own photo is here.
  bool get hasCardPhoto =>
      spec.photoUse == 'none' || poster?.photo == null || _cardPhoto != null;

  /// Drawn with this: the card, his photo in the card's colours, and his
  /// signature when it is switched on.
  PosterScene get scene {
    final p = poster;
    final img = _cardPhoto;
    // The server tints its cleaned-up copy (?colour=); the original — or a
    // copy still in the old colours while the new one downloads — is tinted
    // here, so "black and white" shows the moment he asks.
    final want = spec.photoColour;
    final tint = img != null && want != _photoTone ? want : 'keep';
    return PosterScene(
      spec: spec,
      photo: img,
      tint: tint,
      signature: spec.signature ? signature : null,
      seed: (p?.id ?? 1).abs() + 1,
    );
  }

  PreparedPoster? _prepared;
  Object? _preparedFor;

  /// The laid-out card for the current state (cached until it changes).
  PreparedPoster get prepared {
    final s = scene;
    final key = Object.hash(s.spec, s.photo, s.tint, s.signature, s.seed, PosterFonts.loaded);
    if (_prepared == null || _preparedFor != key) {
      _prepared = preparePoster(s);
      _preparedFor = key;
    }
    return _prepared!;
  }

  /// Lines to shorten: his (limits, server) and the card's own (no room).
  List<PosterNeed> get allNeeds => [...needs, ...prepared.needs];

  // ── opening a card ─────────────────────────────────────────────────────

  Future<void> _ready() async {
    await PosterFonts.ensureLoaded();
    signature = await signatures.load();
  }

  /// A different card takes the screen: nothing of the last one's pending
  /// work may land on it.
  void _leaveCard() {
    _gen++;
    if (_queue.isNotEmpty) {
      AppLog.add('poster', '${_queue.length} unsent change(s) left behind on card ${poster?.id}');
    }
    _history.clear();
    _queue.clear();
    needs = const [];
    _pendingPhoto = null;
    _pendingFinal = null;
    limitReached = false;
  }

  /// Shows [p] (from the server or a device action).
  Future<void> open(Poster p) async {
    mode = 'poster';
    if (poster?.id != p.id) _leaveCard();
    await _ready();
    _adopt(p);
  }

  /// Loads card [id] unless it is already the one on screen. True when card
  /// [id] (or, with no id, the card already here) is on screen afterwards —
  /// a card that could not be fetched is never stood in for by another.
  Future<bool> ensure(int? id) async {
    if (id == null || id <= 0 || poster?.id == id) return true;
    try {
      await open(await api.get(id));
    } on PosterApiException catch (e) {
      AppLog.add('poster', 'could not load card $id: $e');
    }
    return poster?.id == id;
  }

  /// The Hub's door: the latest card, or a fresh one.
  Future<void> openLatestOrNew() async {
    await _ready();
    try {
      final latest = await api.latest();
      if (latest != null) return await open(latest);
    } on PosterApiException catch (e) {
      AppLog.add('poster', 'latest card: $e');
    }
    await startNew();
  }

  /// A fresh card: the occasion's design, its heading, nothing else yet.
  Future<void> startNew({String occasion = 'birthday'}) async {
    await _ready();
    mode = 'poster';
    _leaveCard();
    notice = null;
    final gen = _gen;
    final design = designForOccasion[occasion] ?? 'floral_blush';
    final local = Poster(
      id: 0,
      occasion: occasion,
      spec: PosterSpec(
        occasion: occasion,
        design: design,
        colour: designHomeColour[design] ?? 'pink',
      ),
    );
    _adopt(local);
    try {
      final created = await api.create(occasion: occasion);
      if (gen != _gen) return;
      offline = false;
      _adopt(created);
    } on PosterApiException catch (e) {
      if (gen != _gen) return;
      offline = e.notAvailable;
      AppLog.add('poster', 'new card stays on the phone: $e');
    }
  }

  void _adopt(Poster p) {
    // An answer older than the copy already here (a voice edit landed while
    // this phone's request was on its way) never rolls the card back.
    final s = _server;
    if (!p.isLocal && s != null && s.id == p.id && poster?.id == p.id && p.version < s.version) {
      return;
    }
    var next = p;
    final cur = poster;
    // A photo still waiting to go up stays on the card: the server's copy
    // simply has not got it yet.
    if (_pendingPhoto != null &&
        cur != null &&
        cur.id == p.id &&
        cur.photo?.id == -1 &&
        p.photo == null) {
      next = p.copyWith(
          photo: cur.photo,
          spec: p.spec.copyWith(photoUse: cur.spec.photoUse, photoColour: cur.spec.photoColour));
    }
    poster = next;
    if (!p.isLocal) _server = p;
    notifyListeners();
    _syncPhoto();
  }

  // ── the photo ──────────────────────────────────────────────────────────

  static String _keyFor(PosterPhoto ph, PosterSpec s) {
    final variant = ph.variantFor(s.photoUse);
    final colour = variant == 'enhanced' ? s.photoColour : 'keep';
    return '${ph.id}:$variant:$colour:${ph.updatedAt}';
  }

  void _syncPhoto() {
    final p = poster;
    final ph = p?.photo;
    if (p == null || ph == null) {
      if (photo != null && !_adding) {
        photo = null;
        _photoId = null;
        _photoKey = null;
        photoFailed = false;
        notifyListeners();
      }
      return;
    }
    if (ph.id != _photoId && photo != null) {
      // Another photo: the last one's picture must never stand in for it —
      // not on the screen, and never in a card that is sent.
      photo = null;
      _photoId = null;
      _photoKey = null;
    }
    if (p.spec.photoUse == 'none') return;
    final key = _keyFor(ph, p.spec);
    if (key == _photoKey) return;
    _photoKey = key;
    final variant = ph.variantFor(p.spec.photoUse);
    _photoLoad = _loadPhoto(ph, variant, variant == 'enhanced' ? p.spec.photoColour : 'keep', key);
  }

  Future<void> _loadPhoto(PosterPhoto ph, String variant, String colour, String key) async {
    photoLoading = true;
    photoFailed = false;
    notifyListeners();
    ui.Image? img;
    var tone = colour;
    var fromServer = true;
    try {
      final local = variant == 'original' ? _localBytes[ph.id] : null;
      final bytes = local ?? await api.photoBytes(ph.id, variant, colour: colour);
      img = await _decode(bytes);
    } catch (e) {
      AppLog.add('poster', 'photo $key did not load: $e');
      fromServer = false;
      // His own picked copy stands in (the phone tints it) rather than an
      // empty frame.
      final local = _localBytes[ph.id];
      if (local != null) {
        try {
          img = await _decode(local);
          tone = 'keep';
        } catch (_) {}
      }
    }
    if (_photoKey != key) return; // a newer load owns the photo now
    if (img != null) {
      photo = img;
      _photoId = ph.id;
      _photoTone = variant == 'original' ? 'keep' : tone;
    } else if (_photoId != ph.id) {
      photoFailed = true;
    }
    // A failed fetch is tried again on the next change, or by "Try again".
    if (!fromServer) _photoKey = null;
    photoLoading = false;
    notifyListeners();
  }

  /// "Try again" after the card's photo did not arrive.
  void retryPhoto() {
    _photoKey = null;
    photoFailed = false;
    _syncPhoto();
  }

  /// Waits for the card's photo. True when the card can be drawn with it
  /// (or wants none). A voice "send it" can come a moment after the card
  /// opened: it waits for the picture rather than sending without it.
  Future<bool> photoReady() async {
    for (var i = 0; i < 4; i++) {
      final f = _photoLoad;
      if (f == null) break;
      await f;
      if (identical(f, _photoLoad)) break;
    }
    if (!hasCardPhoto && !photoLoading) {
      // One fresh try before giving up.
      retryPhoto();
      final f = _photoLoad;
      if (f != null) await f;
    }
    return hasCardPhoto;
  }

  /// Puts a photo he picked on the card. A second pick while one is still
  /// being added is ignored. [colour] is the colour he asked for with it
  /// ('bw', 'sepia'); otherwise the card's own photo colour carries over.
  /// False when the photo is not on the card (it would not open, or the
  /// server refused it) — then nothing of it stays.
  Future<bool> addPhoto(PickedPhoto picked, {String? colour}) async {
    if (_adding) return false;
    _adding = true;
    busy = true;
    notice = null;
    final gen = _gen;
    final before = poster;
    final beforePhoto = (photo: photo, id: _photoId, tone: _photoTone, key: _photoKey);
    try {
      await _ready();
      // Shown at once, from the phone's own copy.
      final img = await _decode(picked.bytes);
      final want =
          colour != null && posterPhotoColours.contains(colour) ? colour : spec.photoColour;
      final localPhoto =
          PosterPhoto(id: -1, width: img.width, height: img.height, source: picked.source);
      var p = poster ??
          Poster(id: 0, spec: PosterSpec(design: designForOccasion['birthday']!));
      p = p.copyWith(
        photo: localPhoto,
        spec: p.spec.copyWith(photoUse: 'original', photoColour: want),
      );
      poster = p;
      photo = img;
      _photoId = -1;
      _photoTone = 'keep';
      _photoKey = _keyFor(localPhoto, p.spec);
      photoFailed = false;
      _localBytes[-1] = picked.bytes;
      notifyListeners();

      Poster? created;
      try {
        if (p.isLocal) {
          created = await api.create(occasion: p.occasion, spec: _createSpec(p.spec));
          if (gen != _gen) return false;
          // The server knows this card now: every later change and the
          // finished picture go to IT, never to the card shown before.
          _server = created;
          offline = false;
          p = created.copyWith(
              photo: localPhoto,
              spec: created.spec.copyWith(photoUse: 'original', photoColour: want));
          poster = p;
        }
        final up = await api.uploadPhoto(
          bytes: picked.bytes,
          filename: picked.mime == 'image/png' ? 'photo.png' : 'photo.jpg',
          mime: picked.mime,
          source: picked.source,
          posterId: p.id,
          colour: want,
        );
        if (gen != _gen) return false;
        _localBytes[up.photo.id] = picked.bytes;
        // The picture on screen IS this photo (its original), until the
        // cleaned-up copy arrives.
        _photoId = up.photo.id;
        _pendingPhoto = null;
        offline = false;
        _history.clear();
        _adopt(up.poster ??
            p.copyWith(
                photo: up.photo,
                spec: p.spec.copyWith(
                    photoUse: up.photo.variants.contains('enhanced') ? 'enhanced' : 'original')));
        return true;
      } on PosterApiException catch (e) {
        if (gen != _gen) return false;
        if (e.notAvailable) {
          // Kept on this phone: the card still draws and shares with it,
          // and it goes up when the server answers again.
          AppLog.add('poster', 'photo stays on the phone for now: $e');
          offline = true;
          if (!p.isLocal) {
            _pendingPhoto = picked;
            _scheduleRetry();
          }
          return true;
        }
        // Refused (too big, not a photo it can open): nothing of it stays
        // on the card — the chip must not say "pick another" beside it.
        AppLog.add('poster', 'photo refused: $e');
        _localBytes.remove(-1);
        photo = beforePhoto.photo;
        _photoId = beforePhoto.id;
        _photoTone = beforePhoto.tone;
        _photoKey = beforePhoto.key;
        if (created != null) {
          _adopt(created);
        } else {
          poster = before;
          _syncPhoto();
        }
        notice = e.friendly("That photo couldn't be used. Please pick another one.");
        return false;
      }
    } catch (e) {
      AppLog.add('poster', 'photo could not be used: $e');
      notice = "That photo couldn't be opened. Please pick another one.";
      return false;
    } finally {
      _adding = false;
      busy = false;
      notifyListeners();
      // Changes made while it was going up follow it, on its new version.
      if (_queue.isNotEmpty) unawaited(_flush());
    }
  }

  /// A photo kept on the phone while the server was away, sent now.
  Future<void> _uploadPending() async {
    final picked = _pendingPhoto;
    final p = poster;
    if (picked == null || p == null || p.isLocal || _adding) return;
    final gen = _gen;
    _adding = true;
    try {
      final up = await api.uploadPhoto(
        bytes: picked.bytes,
        filename: picked.mime == 'image/png' ? 'photo.png' : 'photo.jpg',
        mime: picked.mime,
        source: picked.source,
        posterId: p.id,
        colour: spec.photoColour,
      );
      if (gen != _gen) return;
      _pendingPhoto = null;
      _localBytes[up.photo.id] = picked.bytes;
      if (_photoId == -1) _photoId = up.photo.id;
      offline = false;
      _history.clear();
      if (up.poster != null) _adopt(up.poster!);
    } on PosterApiException catch (e) {
      if (gen != _gen) return;
      if (e.notAvailable) {
        _scheduleRetry();
        return;
      }
      AppLog.add('poster', 'kept photo refused: $e');
      _pendingPhoto = null;
      notice = e.friendly("That photo couldn't be used. Please pick another one.");
      if (_server != null) _adopt(_server!);
    } finally {
      _adding = false;
      notifyListeners();
      if (_queue.isNotEmpty) unawaited(_flush());
    }
  }

  static Map<String, dynamic> _createSpec(PosterSpec s) => {
        for (final e in s.toJson().entries)
          if (!{'v', 'photoUse', 'photoFocus', 'textScale', 'headlineCustom', 'languageCustom', 'colourCustom'}
                  .contains(e.key) &&
              // The automatic heading is the server's to work out.
              !(e.key == 'headline' && !s.headlineCustom) &&
              // A language or colour sent on create is one HE chose to the
              // server (languageCustom / colourCustom): sent when he never
              // named one, the card stopped following his words' script
              // and its design's colour once it synced (integration check,
              // 2026-09-26). The contract's create_request sends words only.
              !(e.key == 'language' && !s.languageCustom) &&
              !(e.key == 'colour' && !s.colourCustom) &&
              e.value != null &&
              e.value != '')
            e.key: e.value,
      };

  /// The card's photo colour: as it is, black and white, or old-photo
  /// brown. Part of the card (contract v2), so it is one change — undo
  /// takes it back — and the card is drawn from that colour's copy.
  bool setPhotoColour(String colour) {
    if (poster?.photo == null || !posterPhotoColours.contains(colour)) return false;
    if (spec.photoColour == colour) return true;
    return apply(PosterChange(photoColour: colour));
  }

  // ── changes ────────────────────────────────────────────────────────────

  /// Applies [c] now and sends it. Returns false (and sets [needs]) when a
  /// line is too long — nothing is cut, he is asked to shorten it.
  bool apply(PosterChange c, {bool record = true}) {
    final p = poster;
    if (p == null || c.isEmpty) return false;
    final r = applyChange(p.spec, c);
    if (r.spec == null) {
      needs = r.needs;
      notifyListeners();
      return false;
    }
    needs = needs.where((n) => !c.set.containsKey(n.field)).toList();
    if (c.textSize == 'bigger' && r.spec!.textScale == p.spec.textScale) limitReached = true;
    if (c.textSize == 'smaller' || c.textSize == 'reset') limitReached = false;
    if (record) {
      _history.add(p.spec);
      if (_history.length > 20) _history.removeAt(0);
    }
    poster = p.copyWith(spec: r.spec, canUndo: true);
    notifyListeners();
    _syncPhoto();
    _send(c);
    return true;
  }

  /// Moves the photo in its frame while a finger or button is still on it —
  /// shown, not yet sent (commitFocus sends it once).
  void previewFocus(PhotoFocus f) {
    final p = poster;
    if (p == null) return;
    poster = p.copyWith(spec: p.spec.copyWith(photoFocus: f));
    notifyListeners();
  }

  void commitFocus(PhotoFocus before) {
    final p = poster;
    if (p == null || p.spec.photoFocus == before) return;
    _history.add(p.spec.copyWith(photoFocus: before));
    _send(PosterChange(photoFocus: p.spec.photoFocus));
  }

  /// One step back — on the phone at once, then on the server.
  void undo() {
    final p = poster;
    if (p == null) return;
    if (_history.isNotEmpty) {
      poster = p.copyWith(spec: _history.removeLast());
      needs = const [];
      notifyListeners();
      _syncPhoto();
      _send(PosterChange.undoChange);
    } else if (p.canUndo) {
      _send(PosterChange.undoChange);
    }
  }

  void _send(PosterChange c) {
    final p = poster;
    if (p == null || p.isLocal) return;
    // The card changed after a shared picture was drawn: that picture no
    // longer matches it.
    _pendingFinal = null;
    _queue.add(_Queued(p.id, c));
    unawaited(_flush());
  }

  Future<void> _flush() async {
    // A photo going up moves the card's version: changes wait for it.
    if (_flushing || _adding) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.first;
        final p = poster;
        final base = _server;
        if (p == null || base == null || p.isLocal || item.posterId != p.id || base.id != p.id) {
          // Made on a card no longer on screen (or one the server never saw).
          _queue.remove(item);
          continue;
        }
        try {
          final r = await api.patch(base.id, base.version, item.change);
          _queue.remove(item);
          // He opened another card meanwhile: this answer is not for it.
          if (poster?.id != base.id) continue;
          offline = false;
          _retries = 0;
          if (r.limitReached) limitReached = true;
          final s = _server;
          if (s != null && s.id == base.id && r.poster.version < s.version) continue;
          _server = r.poster;
          // The server's copy is the truth once nothing else is waiting.
          if (!_queue.any((q) => q.posterId == base.id)) {
            _adopt(r.poster);
            _afterSynced(base.id);
          } else {
            poster = poster!.copyWith(version: r.poster.version);
          }
        } on PosterApiException catch (e) {
          if (poster?.id != base.id) {
            _queue.remove(item);
            continue;
          }
          if (e.notAvailable) {
            // KEPT, in order: tried again with the next change or in a
            // moment. The screen already shows it; the server will too.
            offline = true;
            _scheduleRetry();
            notifyListeners();
            break;
          }
          _queue.removeWhere((q) => q.posterId == base.id);
          if ((e.isConflict || e.code == 'nothing_to_undo') && e.poster != null) {
            if (e.isConflict) {
              _history.clear();
              notice = 'This card was changed somewhere else — here is the latest.';
            }
            _adopt(e.poster!);
          } else if (e.isNeed) {
            needs = e.need;
            if (_history.isNotEmpty) _history.removeLast();
            if (_server != null) _adopt(_server!);
          } else {
            AppLog.add('poster', 'change refused: $e');
            if (_history.isNotEmpty) _history.removeLast();
            if (e.message.isNotEmpty) notice = e.friendly(e.message);
            if (_server != null) _adopt(_server!);
          }
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// Everything kept on the phone has reached the server: a picture shared
  /// meanwhile can now be saved to his documents.
  void _afterSynced(int posterId) {
    final f = _pendingFinal;
    if (f == null || f.posterId != posterId) return;
    _pendingFinal = null;
    unawaited(_uploadFinal(posterId, f.png));
  }

  void _scheduleRetry() {
    if (_retry?.isActive ?? false) return;
    final k = math.min(8, 1 << math.min(_retries, 3));
    _retries++;
    _retry = Timer(retryAfter * k, () {
      _retry = null;
      unawaited(resync());
    });
  }

  /// Sends what was kept on the phone while the server was out of reach.
  Future<void> resync() async {
    await _flush();
    if (_queue.isNotEmpty) return; // still out of reach: tried again later
    if (_pendingPhoto != null) {
      await _uploadPending();
    } else if (poster != null) {
      // A shared picture that could not be saved while the server was away.
      _afterSynced(poster!.id);
    }
  }

  /// Waits until every change has reached the server, or is kept on the
  /// phone because the server is out of reach.
  Future<void> settle() async {
    while (_flushing || _adding || (_queue.isNotEmpty && !offline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  // ── signature ──────────────────────────────────────────────────────────

  /// A new signature was drawn: shown on the card.
  void useSignature(SignatureData s) {
    signature = s;
    if (!spec.signature) {
      apply(const PosterChange(signature: true));
    } else {
      notifyListeners();
    }
  }

  Future<void> deleteSignature() async {
    await signatures.delete();
    signature = null;
    if (spec.signature) {
      apply(const PosterChange(signature: false));
    } else {
      notifyListeners();
    }
  }

  // ── the finished card ──────────────────────────────────────────────────

  Future<Uint8List> exportPng() async {
    await PosterFonts.ensureLoaded();
    return renderPosterPng(scene);
  }

  String get fileName => PosterShare.fileName(spec.printedHeadline, spec.name);

  static const _photoNotHere =
      "Your photo hasn't arrived on this phone yet. Please try again in a moment.";

  /// Sends the card: WhatsApp by default, the share menu otherwise. A copy
  /// is saved to his documents on the server in the background.
  Future<ShareOutcome> share({String app = 'whatsapp', bool saveToPhotos = false}) async {
    final p = poster;
    if (p == null) return ShareOutcome.failed;
    if (allNeeds.isNotEmpty) return ShareOutcome.failed;
    busy = true;
    notifyListeners();
    try {
      // Never a card with the wrong photo, or none where his should be.
      if (!await photoReady()) {
        notice = _photoNotHere;
        return ShareOutcome.photoMissing;
      }
      if (poster?.id != p.id) return ShareOutcome.failed;
      final png = await exportPng();
      final out = await sharer.share(png, name: fileName, app: app, saveToPhotos: saveToPhotos);
      unawaited(_uploadFinal(p.id, png));
      return out;
    } catch (e) {
      AppLog.add('poster', 'share failed: $e');
      return ShareOutcome.failed;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Into his Photos (Android 10+); older phones get the share menu.
  Future<ShareOutcome> saveToPhotos() async {
    final p = poster;
    if (p == null || allNeeds.isNotEmpty) return ShareOutcome.failed;
    busy = true;
    notifyListeners();
    try {
      if (!await photoReady()) {
        notice = _photoNotHere;
        return ShareOutcome.photoMissing;
      }
      if (poster?.id != p.id) return ShareOutcome.failed;
      final png = await exportPng();
      unawaited(_uploadFinal(p.id, png));
      if (await sharer.saveToPhotos(png, fileName)) {
        notice = 'Saved to your Photos.';
        return ShareOutcome.saved;
      }
      return await sharer.share(png, name: fileName, app: 'any');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Saves the shared picture of card [posterId] to his documents — the
  /// card it was drawn from, never whichever card is on screen by then.
  Future<void> _uploadFinal(int posterId, Uint8List png) async {
    if (posterId <= 0) return;
    await settle();
    final base = _server;
    if (base == null || base.id != posterId || poster?.id != posterId) return;
    if (_queue.isNotEmpty) {
      // Its changes are still on the phone: saved once they are through.
      _pendingFinal = (posterId: posterId, png: png);
      return;
    }
    try {
      await api.uploadFinal(posterId, png, base.version);
    } on PosterApiException catch (e) {
      AppLog.add('poster', 'final card not saved to documents: $e');
      if (e.notAvailable && poster?.id == posterId) {
        _pendingFinal = (posterId: posterId, png: png);
        _scheduleRetry();
      }
    }
  }

  // ── photo mode ─────────────────────────────────────────────────────────

  /// "Make this old photo nice": the photo on its own, before and after.
  Future<void> showLoosePhoto(PosterPhoto ph, {Uint8List? original}) async {
    mode = 'photo';
    final gen = ++_looseGen;
    final same = loosePhoto?.id == ph.id || (loosePhoto == null && original != null);
    loosePhoto = ph;
    if (original != null) _localBytes[ph.id] = original;
    if (!same) {
      looseOriginal = null;
      looseEnhanced = null;
    }
    notifyListeners();
    try {
      if (looseOriginal == null) {
        final o = _localBytes[ph.id] ?? await api.photoBytes(ph.id, 'original');
        final img = await _decode(o);
        if (gen != _looseGen) return;
        looseOriginal = img;
        notifyListeners();
      }
      if (ph.variants.contains('enhanced')) {
        // The clean-up in the colour last asked for (each colour its own copy).
        final img = await _decode(await api.photoBytes(ph.id, 'enhanced', colour: ph.colour));
        if (gen != _looseGen) return;
        looseEnhanced = img;
      }
    } catch (e) {
      AppLog.add('poster', 'photo mode: $e');
    }
    if (gen == _looseGen) notifyListeners();
  }

  /// Adds a picked photo in photo mode (no card yet), cleaned up in
  /// [colour]. The photo the server made of it, or null when it could not.
  Future<PosterPhoto?> addLoosePhoto(PickedPhoto picked, {String colour = 'keep'}) async {
    if (_adding) return null;
    _adding = true;
    // Photo mode at once, his own copy on the left while it is cleaned up.
    mode = 'photo';
    _looseGen++;
    loosePhoto = null;
    looseEnhanced = null;
    notice = null;
    try {
      looseOriginal = await _decode(picked.bytes);
    } catch (_) {
      looseOriginal = null;
    }
    notifyListeners();
    try {
      final up = await api.uploadPhoto(
        bytes: picked.bytes,
        filename: picked.mime == 'image/png' ? 'photo.png' : 'photo.jpg',
        mime: picked.mime,
        source: picked.source,
        colour: posterPhotoColours.contains(colour) ? colour : 'keep',
      );
      await showLoosePhoto(up.photo, original: picked.bytes);
      return up.photo;
    } on PosterApiException catch (e) {
      notice = e.friendly("The photo couldn't be cleaned up right now.");
      notifyListeners();
      return null;
    } finally {
      _adding = false;
    }
  }

  /// Photo mode: the same photo in its own colours, black and white or
  /// sepia (a photo on its own keeps its colour on the photo itself).
  Future<void> recolourLoosePhoto(String colour) async {
    final ph = loosePhoto;
    if (ph == null || !posterPhotoColours.contains(colour) || ph.colour == colour) return;
    try {
      final updated = await api.recolourPhoto(ph.id, colour);
      await showLoosePhoto(updated);
    } on PosterApiException catch (e) {
      notice = e.friendly("The colours couldn't be changed just now.");
      notifyListeners();
    }
  }

  /// Keeps the clearer photo in his documents.
  Future<bool> keepLoosePhoto() async {
    final ph = loosePhoto;
    if (ph == null) return false;
    try {
      await api.keepPhoto(ph.id, ph.variants.contains('enhanced') ? 'enhanced' : 'original');
      notice = 'Saved in My documents.';
      notifyListeners();
      return true;
    } on PosterApiException catch (e) {
      notice = e.friendly("Couldn't save it just now.");
      notifyListeners();
      return false;
    }
  }

  /// "Make a card with it".
  Future<void> cardFromLoosePhoto({String occasion = 'birthday'}) async {
    final ph = loosePhoto;
    if (ph == null) return;
    try {
      final p = await api.create(occasion: occasion, photoId: ph.id);
      await open(p);
    } on PosterApiException catch (e) {
      notice = e.friendly("The card couldn't be started just now.");
      notifyListeners();
    }
  }

  // ── leaving ────────────────────────────────────────────────────────────

  /// Forgets every card, photo and signature this controller holds — on
  /// sign-out or a deleted account, so the next account on this phone never
  /// sees the last one's daughter, words or signature.
  void reset() {
    _gen++;
    _looseGen++;
    _retry?.cancel();
    _retry = null;
    _retries = 0;
    mode = 'poster';
    poster = null;
    _server = null;
    photo = null;
    _photoId = null;
    _photoKey = null;
    _photoLoad = null;
    _photoTone = 'keep';
    photoLoading = false;
    photoFailed = false;
    loosePhoto = null;
    looseOriginal = null;
    looseEnhanced = null;
    signature = null;
    needs = const [];
    notice = null;
    offline = false;
    limitReached = false;
    busy = false;
    _pendingPhoto = null;
    _pendingFinal = null;
    _prepared = null;
    _preparedFor = null;
    _history.clear();
    _queue.clear();
    _localBytes.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  static bool _wired = false;

  /// Signing out, a rejected session and a deleted account also clear the
  /// card feature's memory and the signature kept on this phone (review,
  /// 2026-09-26: both outlived sign-out and met the next account).
  static void wireSignOut() {
    if (_wired) return;
    _wired = true;
    AuthService.instance.onSignOut(forgetAccount);
  }

  static Future<void> forgetAccount() async {
    await SignatureStore.instance.delete();
    instance.reset();
  }
}
