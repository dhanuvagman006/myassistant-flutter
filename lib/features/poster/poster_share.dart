import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/log.dart';

/// Where the card went.
enum ShareOutcome {
  /// WhatsApp opened with the card; he picks the person and presses Send.
  whatsapp,

  /// The phone's share menu opened (WhatsApp missing, or he asked for it).
  sheet,

  /// Saved into his Photos only.
  saved,

  /// Nothing sent: the card's photo has not arrived on this phone yet.
  /// Sending then would draw the card without it (or with the card opened
  /// before it), so it waits and he is told plainly.
  photoMissing,
  failed,
}

/// ONE TAP TO WHATSAPP (2026-09-26), with the share menu as the fallback.
///
/// Native side: PosterShareBridge.kt on the "hari/intent" channel. The
/// file is written to the app's cache folder "posters/", the only folder
/// its FileProvider exposes.
class PosterShare {
  PosterShare({MethodChannel? channel, Future<Directory> Function()? tempDir, this.sheet})
      : _ch = channel ?? const MethodChannel('hari/intent'),
        _tempDir = tempDir ?? getTemporaryDirectory;

  final MethodChannel _ch;
  final Future<Directory> Function() _tempDir;

  /// The share menu; replaceable in tests.
  final Future<void> Function(XFile file, String subject)? sheet;

  static PosterShare instance = PosterShare();

  /// "Happy 25th Birthday Ananya.png" — a name that means something in his
  /// gallery or a WhatsApp chat.
  static String fileName(String headline, String name) {
    final raw = '$headline $name'.trim();
    final clean = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final short = clean.length > 60 ? clean.substring(0, 60).trim() : clean;
    return '${short.isEmpty ? 'Card' : short}.png';
  }

  Future<File> _write(Uint8List png, String name) async {
    final dir = Directory('${(await _tempDir()).path}/posters');
    await dir.create(recursive: true);
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(png, flush: true);
    return f;
  }

  Future<void> _openSheet(File f, String name) async {
    final file = XFile(f.path, mimeType: 'image/png', name: name);
    final subject = name.replaceAll('.png', '');
    if (sheet != null) return sheet!(file, subject);
    await Share.shareXFiles([file], subject: subject);
  }

  /// Saves into Photos (Android 10+). Returns false when this phone cannot.
  Future<bool> saveToPhotos(Uint8List png, String name) async {
    try {
      final r = await _ch.invokeMethod<String>(
          'saveImageToGallery', {'bytes': png, 'name': name});
      return r == 'ok';
    } catch (e) {
      AppLog.add('poster', 'save to photos failed: $e');
      return false;
    }
  }

  /// Sends the card: straight to WhatsApp when [app] is 'whatsapp' (then
  /// WhatsApp Business), else — or if neither is installed — the share
  /// menu. [saveToPhotos] also keeps a copy in his Photos.
  Future<ShareOutcome> share(Uint8List png,
      {required String name, String app = 'whatsapp', bool saveToPhotos = false}) async {
    try {
      final f = await _write(png, name);
      if (saveToPhotos) {
        final saved = await this.saveToPhotos(png, name);
        // Older phones cannot save without a storage permission: the share
        // menu (which has "Save to device" on most) stands in.
        if (!saved && app != 'whatsapp') {
          await _openSheet(f, name);
          return ShareOutcome.sheet;
        }
      }
      if (app == 'whatsapp') {
        String? r;
        try {
          r = await _ch.invokeMethod<String>(
              'shareImageTo', {'path': f.path, 'mime': 'image/png', 'pkg': 'com.whatsapp'});
        } on MissingPluginException {
          r = 'unsupported';
        } catch (e) {
          AppLog.add('poster', 'whatsapp share failed: $e');
          r = 'failed';
        }
        if (r == 'ok') return ShareOutcome.whatsapp;
        AppLog.add('poster', 'whatsapp share → $r; opening the share menu');
      }
      await _openSheet(f, name);
      return ShareOutcome.sheet;
    } catch (e) {
      AppLog.add('poster', 'share failed: $e');
      return ShareOutcome.failed;
    }
  }
}
