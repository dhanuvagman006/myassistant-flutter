import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart' show openAppSettings;

import '../../core/log.dart';
import '../../design/neon_tokens.dart';
import 'poster_controller.dart';

/// "From my photos" or "Take a picture of a printed photo" — two big
/// choices, nothing else (an old print is usually in a drawer, not in the
/// phone's gallery).
abstract final class PhotoSourceSheet {
  /// 'gallery' | 'camera', or null when he closes it.
  static Future<String?> ask(BuildContext context) => showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        backgroundColor: Neon.surface,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Which photo?',
                    style: NeonType.manrope(NeonType.title3, FontWeight.w700)
                        .copyWith(color: Neon.textHi)),
                const SizedBox(height: 14),
                _choice(ctx, Icons.photo_library_rounded, 'From my photos', 'gallery'),
                const SizedBox(height: 12),
                _choice(ctx, Icons.photo_camera_rounded, 'Take a picture of a printed photo',
                    'camera'),
                const SizedBox(height: 10),
                Text('For a printed photo: lay it flat near a window, no flash.',
                    style: TextStyle(color: Neon.textLo, fontSize: NeonType.callout)),
              ],
            ),
          ),
        ),
      );

  static Widget _choice(BuildContext ctx, IconData icon, String label, String value) =>
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: FilledButton.icon(
          onPressed: () => Navigator.of(ctx).pop(value),
          icon: Icon(icon, size: 28),
          label: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(label,
                style: NeonType.manrope(NeonType.rowTitle + 2, FontWeight.w700),
                textAlign: TextAlign.center),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: Neon.violet,
            foregroundColor: Neon.onAccent,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      );

  /// A single photo shared into the app from WhatsApp or the gallery:
  /// "Make a birthday card" or "Just save it" ('card' | 'save' | null).
  static Future<String?> askShared(BuildContext context) => showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        backgroundColor: Neon.surface,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('What shall I do with this photo?',
                    style: NeonType.manrope(NeonType.title3, FontWeight.w700)
                        .copyWith(color: Neon.textHi)),
                const SizedBox(height: 14),
                _choice(ctx, Icons.card_giftcard_rounded, 'Make a birthday card', 'card'),
                const SizedBox(height: 12),
                _choice(ctx, Icons.save_alt_rounded, 'Just save it', 'save'),
              ],
            ),
          ),
        ),
      );

  /// Opens the gallery or camera. [source] 'ask' shows the two choices
  /// first. Null when he backs out at any point. When the camera (or his
  /// photos) are switched off for the app, a message offering Settings is
  /// shown and [PhotoAccessDenied] thrown — it is not "closed the picker":
  /// trying again would only fail the same way (review, 2026-09-26).
  static Future<PickedPhoto?> pick(BuildContext context, String source,
      {ImagePicker? picker}) async {
    var from = source;
    if (from != 'gallery' && from != 'camera') {
      final chosen = await ask(context);
      if (chosen == null) return null;
      from = chosen;
    }
    if (!context.mounted) return null;
    final nav = Navigator.of(context, rootNavigator: true);
    try {
      final shot = await (picker ?? ImagePicker()).pickImage(
        source: from == 'camera' ? ImageSource.camera : ImageSource.gallery,
        // The server keeps 2048 px on the long side; more is only upload.
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 92,
      );
      if (shot == null) return null;
      final bytes = await shot.readAsBytes();
      final usable = await normalise(bytes);
      return PickedPhoto(usable.bytes, mime: usable.mime, source: from);
    } on PlatformException catch (e) {
      if (e.code == 'camera_access_denied' || e.code == 'photo_access_denied') {
        AppLog.add('poster', 'picker: ${e.code}');
        if (nav.mounted) unawaited(_accessHelp(nav.context, from));
        throw PhotoAccessDenied(from);
      }
      AppLog.add('poster', 'picker failed: $e');
      return null;
    } catch (e) {
      AppLog.add('poster', 'picker failed: $e');
      return null;
    }
  }

  /// "The camera is switched off for this app" — and one big button to the
  /// app's page in Settings, where he (or his daughter) can allow it.
  static Future<void> _accessHelp(BuildContext context, String from) {
    final camera = from == 'camera';
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: Neon.surface,
        title: Text(camera ? 'The camera is switched off' : 'Photos are switched off',
            style: NeonType.manrope(NeonType.title3, FontWeight.w700).copyWith(color: Neon.textHi)),
        content: Text(
          camera
              ? 'To take a picture, please allow the camera for this app in Settings. '
                  'Or choose a photo from your gallery instead.'
              : 'To choose a photo, please allow photos for this app in Settings.',
          style: TextStyle(color: Neon.textHi, fontSize: NeonType.rowTitle, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: TextButton.styleFrom(minimumSize: const Size(64, 56)),
            child: const Text('Not now', style: TextStyle(fontSize: 18)),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              unawaited(openAppSettings());
            },
            style: FilledButton.styleFrom(minimumSize: const Size(120, 56)),
            child: const Text('Open Settings', style: TextStyle(fontSize: 18)),
          ),
        ],
      ),
    );
  }

  /// The kind of picture the bytes ARE (not what the file is called):
  /// the three the server takes, or null.
  static String? kindOf(Uint8List b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return 'image/png';
    }
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  /// A photo from anywhere — the picker, or shared in from WhatsApp or the
  /// gallery — made into what the server takes: a JPEG, PNG or WebP of a
  /// sensible size. A HEIC, a GIF or a giant camera file is redrawn at
  /// 2048 px on the long side as a PNG (review, 2026-09-26: a shared HEIC
  /// showed on the card while the server refused it). Throws when the
  /// phone itself cannot open it.
  static Future<({Uint8List bytes, String mime})> normalise(Uint8List bytes) async {
    final kind = kindOf(bytes);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final desc = await ui.ImageDescriptor.encoded(buffer);
    try {
      final long = math.max(desc.width, desc.height);
      if (kind != null && long <= 4096 && bytes.length <= 12 * 1024 * 1024) {
        return (bytes: bytes, mime: kind);
      }
      final k = long > 2048 ? 2048 / long : 1.0;
      final codec = await desc.instantiateCodec(
        targetWidth: math.max(1, (desc.width * k).round()),
        targetHeight: math.max(1, (desc.height * k).round()),
      );
      final frame = await codec.getNextFrame();
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return (bytes: png!.buffer.asUint8List(), mime: 'image/png');
    } finally {
      desc.dispose();
      buffer.dispose();
    }
  }
}
