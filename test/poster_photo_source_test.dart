import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myassistant/features/poster/photo_source_sheet.dart';
import 'package:myassistant/features/poster/poster_controller.dart';

import 'poster_fakes.dart';

/// A picker whose camera permission was refused (image_picker reports it
/// as a PlatformException, not as "closed").
class _DenyPicker extends ImagePicker {
  _DenyPicker(this.code);
  final String code;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async =>
      throw PlatformException(code: code, message: 'The user did not allow camera access.');
}

/// PICKING THE PHOTO (review, 2026-09-26): a camera switched off in the
/// phone's settings is told apart from "closed the picker", and a photo
/// from anywhere is made into one the server takes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the camera switched off: the way to Settings, not "try again?"', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        ctx = c;
        return const Scaffold(body: SizedBox());
      }),
    ));
    Object? error;
    try {
      await PhotoSourceSheet.pick(ctx, 'camera', picker: _DenyPicker('camera_access_denied'));
    } catch (e) {
      error = e;
    }
    expect(error, isA<PhotoAccessDenied>());
    expect((error! as PhotoAccessDenied).source, 'camera');
    await tester.pumpAndSettle();
    expect(find.text('The camera is switched off'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('The camera is switched off'), findsNothing);

    // Any other picker failure is still "nothing picked".
    final none = await PhotoSourceSheet.pick(ctx, 'gallery', picker: _DenyPicker('already_active'));
    expect(none, isNull);
  });

  test('a JPEG, PNG or WebP of a sensible size goes as it is', () async {
    final png = await tinyPng(w: 40, h: 30);
    final out = await PhotoSourceSheet.normalise(png);
    expect(out.mime, 'image/png');
    expect(identical(out.bytes, png), isTrue);
    expect(PhotoSourceSheet.kindOf(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), 'image/jpeg');
    expect(
        PhotoSourceSheet.kindOf(Uint8List.fromList('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits)),
        'image/webp');
  });

  test('any other kind the phone can open is redrawn as a PNG (a shared GIF or HEIC)', () async {
    // The classic 1×1 GIF: not a kind the server takes.
    final gif = Uint8List.fromList([
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0xFF, 0xFF,
      0xFF, 0x00, 0x00, 0x00, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
      0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    ]);
    expect(PhotoSourceSheet.kindOf(gif), isNull);
    final out = await PhotoSourceSheet.normalise(gif);
    expect(out.mime, 'image/png');
    expect(PhotoSourceSheet.kindOf(out.bytes), 'image/png');
  });

  test('a giant picture is brought down to 2048 on its long side', () async {
    final big = await tinyPng(w: 5000, h: 20);
    final out = await PhotoSourceSheet.normalise(big);
    final codec = await ui.instantiateImageCodec(out.bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 2048);
  });

  test('bytes the phone cannot open are refused, not passed on', () async {
    expect(() => PhotoSourceSheet.normalise(Uint8List.fromList(List.filled(64, 7))),
        throwsA(anything));
  });
}
