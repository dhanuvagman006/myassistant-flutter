import 'dart:async';

import '../../core/log.dart';
import 'poster_controller.dart';
import 'poster_models.dart';
import 'poster_share.dart';
import 'signature/signature_model.dart';

/// What the assistant's card actions need from the app around them — the
/// engine in the app, a fake in tests.
abstract class PosterHost {
  /// Hands a [SYSTEM] line to the live conversation.
  Future<void> tellModel(String line);

  /// Holds the microphone shut while [body] owns the screen (a picker, the
  /// signature pad) — otherwise the next turn is shutter noise.
  Future<T> holdMic<T>(Future<T> Function() body);

  /// Brings the card screen up (or keeps it up).
  void showPoster();

  /// Asks for a photo: 'ask' offers "From my photos" / "Take a picture";
  /// null when he closes it. Throws [PhotoAccessDenied] when the camera (or
  /// his photos) are switched off for the app — the screen then shows the
  /// way to Settings.
  Future<PickedPhoto?> pickPhoto(String source);

  /// Opens the signature pad; null when he closes it.
  Future<SignatureData?> openSignaturePad();
}

/// The [SYSTEM] lines, word for word as the contract fixture has them
/// (test/fixtures/poster_contract.json → systemLines). None of them lets
/// the model say the card is "made" or "ready": it is ON HIS SCREEN.
abstract final class PosterLines {
  static String photoAddedMissing(int posterId, List<String> missing) =>
      '[SYSTEM] The photo is on the card now (poster $posterId). Still needed: '
      '${missing.map(fieldLabel).join(', ')}. Ask ONE short question for them. '
      'Do not say the card is made or ready.';

  static String photoAddedComplete(int posterId) =>
      '[SYSTEM] The photo is on the card now and the card is on the screen '
      '(poster $posterId). Read the words back exactly as written, spell the '
      'name letter by letter, and ask if it is right. Do not say it is made or ready.';

  static const pickerClosed =
      '[SYSTEM] The photo picker was closed without choosing a photo. Nothing '
      'was made. Ask briefly whether to try again or make the card without a photo.';

  /// Carries the photo's id: the upload went straight from the phone, so
  /// this line is the model's only way to keep it or put it on a card.
  static String photoShown(int photoId) =>
      '[SYSTEM] The cleaned-up photo is on the screen next to the original '
      '(photo $photoId). Ask ONE question: keep the clearer one, or make a card '
      'with it? Never call it repaired or restored.';

  static String tooLongOnCard(String field) {
    final words = fieldLabel(field);
    return '[SYSTEM] $words does not fit on the card even at the smallest size. '
        'Nothing was cut. Ask for a shorter $words.';
  }

  static const signatureSaved =
      '[SYSTEM] Signature saved on this phone; it is on the card now.';

  static const shared =
      '[SYSTEM] WhatsApp is open with the card. The user picks the person and presses Send.';

  static const shareFallback =
      '[SYSTEM] The share menu is open with the card. The user picks where it '
      'goes and presses Send.';

  // Not in the fixture: failures the app reports honestly.
  static const signClosed =
      '[SYSTEM] The signature page was closed without signing. Nothing changed. '
      'Ask briefly whether to try again.';

  static const photoFailed =
      '[SYSTEM] ERROR: that photo could not be used. Nothing was made. Ask him '
      'to pick another photo; never say the photo was bad.';

  static const shareFailed =
      '[SYSTEM] ERROR: the card could not be shared just now. Nothing was sent. '
      'Say so plainly and offer to try again.';

  static const noCard =
      '[SYSTEM] ERROR: there is no card on this phone to share yet. Nothing was sent.';

  static const cardNotOpened =
      '[SYSTEM] ERROR: that card could not be opened on this phone just now, so '
      'nothing was sent or changed. Say so plainly and offer to try again.';

  static const photoNotReady =
      '[SYSTEM] ERROR: the photo on the card has not arrived on this phone yet, '
      'so nothing was sent. Say so plainly and offer to try again in a moment.';

  /// The camera (or his photos) are switched off for this app. Asking "try
  /// again?" would fail the same way, so the model says where to switch it on.
  static String accessOff(String source) {
    final what = source == 'camera' ? 'The camera is' : 'Access to photos is';
    return '[SYSTEM] ERROR: $what switched off for this app, so no photo was '
        'picked and nothing was made. A message on the screen offers to open '
        'Settings to allow it. Say that briefly'
        '${source == 'camera' ? ', or offer to choose a photo from the gallery instead' : ''}.';
  }
}

/// Handles the four card actions the server's voice tools send
/// (contract §4): poster_pick_photo, poster_show, poster_share, poster_sign.
class PosterDeviceActions {
  PosterDeviceActions(this.host, {PosterController? controller})
      : c = controller ?? PosterController.instance;

  final PosterHost host;
  final PosterController c;

  static const types = {'poster_pick_photo', 'poster_show', 'poster_share', 'poster_sign'};

  static int? _id(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  Future<void> handle(Map<String, dynamic> e) async {
    try {
      switch (e['type']) {
        case 'poster_pick_photo':
          await _pick(e);
        case 'poster_show':
          await _show(e);
        case 'poster_share':
          await _share(e);
        case 'poster_sign':
          await _sign(e);
      }
    } catch (err) {
      AppLog.add('poster', '${e['type']} failed: $err');
    }
  }

  Future<void> _pick(Map<String, dynamic> e) async {
    final purpose = (e['purpose'] ?? 'poster').toString();
    final source = (e['source'] ?? 'ask').toString();
    // "…in black and white": the colour asked for with the photo. 'keep' is
    // also the default, so on a card it leaves the card's colour as it is.
    final asked = e['colour']?.toString();
    final colour = posterPhotoColours.contains(asked) ? asked! : 'keep';
    await host.holdMic(() async {
      if (purpose == 'poster' && !await c.ensure(_id(e['poster_id']))) {
        await host.tellModel(PosterLines.cardNotOpened);
        return;
      }
      PickedPhoto? picked;
      try {
        picked = await host.pickPhoto(source);
      } on PhotoAccessDenied catch (denied) {
        await host.tellModel(PosterLines.accessOff(denied.source));
        return;
      }
      if (picked == null) {
        await host.tellModel(PosterLines.pickerClosed);
        return;
      }
      if (purpose == 'photo') {
        host.showPoster();
        final shown = await c.addLoosePhoto(picked, colour: colour);
        await host.tellModel(
            shown != null ? PosterLines.photoShown(shown.id) : PosterLines.photoFailed);
        return;
      }
      host.showPoster();
      final ok = await c.addPhoto(picked, colour: colour == 'keep' ? null : colour);
      if (!ok) {
        await host.tellModel(PosterLines.photoFailed);
        return;
      }
      final id = c.poster?.id ?? 0;
      final missing = missingLines(c.spec);
      await host.tellModel(missing.isEmpty
          ? PosterLines.photoAddedComplete(id)
          : PosterLines.photoAddedMissing(id, missing));
    });
  }

  Future<void> _show(Map<String, dynamic> e) async {
    if (e['mode'] == 'photo' && e['photo'] is Map) {
      host.showPoster();
      await c.showLoosePhoto(PosterPhoto.fromJson((e['photo'] as Map).cast<String, dynamic>()));
      return;
    }
    final p = e['poster'];
    if (p is! Map) return;
    await c.open(Poster.fromJson(p.cast<String, dynamic>()));
    host.showPoster();
    // "With my signature" and none drawn yet: the pad comes first.
    if (c.spec.signature && c.signature == null) {
      final s = await host.holdMic(host.openSignaturePad);
      if (s != null) {
        c.useSignature(s);
        await host.tellModel(PosterLines.signatureSaved);
      } else {
        await host.tellModel(PosterLines.signClosed);
      }
    }
    final needs = c.prepared.needs;
    if (needs.isNotEmpty) await host.tellModel(PosterLines.tooLongOnCard(needs.first.field));
  }

  Future<void> _share(Map<String, dynamic> e) async {
    // Never another card in its place: "send Ananya's card" must not send
    // the son's because hers did not load.
    if (!await c.ensure(_id(e['poster_id']))) {
      await host.tellModel(PosterLines.cardNotOpened);
      return;
    }
    if (c.poster == null) {
      await host.tellModel(PosterLines.noCard);
      return;
    }
    final needs = c.allNeeds;
    if (needs.isNotEmpty) {
      host.showPoster();
      await host.tellModel(PosterLines.tooLongOnCard(needs.first.field));
      return;
    }
    final out = await host.holdMic(() => c.share(
          app: (e['app'] ?? 'whatsapp').toString(),
          saveToPhotos: e['save_to_photos'] == true,
        ));
    await host.tellModel(switch (out) {
      ShareOutcome.whatsapp => PosterLines.shared,
      ShareOutcome.sheet => PosterLines.shareFallback,
      ShareOutcome.saved => PosterLines.shareFallback,
      ShareOutcome.photoMissing => PosterLines.photoNotReady,
      ShareOutcome.failed => PosterLines.shareFailed,
    });
  }

  Future<void> _sign(Map<String, dynamic> e) async {
    if (!await c.ensure(_id(e['poster_id']))) {
      await host.tellModel(PosterLines.cardNotOpened);
      return;
    }
    final s = await host.holdMic(host.openSignaturePad);
    if (s == null) {
      await host.tellModel(PosterLines.signClosed);
      return;
    }
    c.useSignature(s);
    await host.tellModel(PosterLines.signatureSaved);
  }
}
