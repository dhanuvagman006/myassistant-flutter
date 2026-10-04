import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/live_voice.dart';
import 'package:myassistant/screens/voice_picker_screen.dart';
import 'package:myassistant/services/audio/pcm_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _voices = [
  VoiceCatalogItem(
    id: 'gleam',
    name: 'Gleam',
    gender: 'female',
    accent: 'North American',
    tagline: 'Warm and conversational',
  ),
  VoiceCatalogItem(
    id: 'willow',
    name: 'Willow',
    gender: 'female',
    accent: 'Irish',
    tagline: 'Expressive and bright',
  ),
  VoiceCatalogItem(
    id: 'ripple',
    name: 'Ripple',
    gender: 'male',
    accent: 'Australian',
    tagline: 'Warm and conversational',
  ),
];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveVoicePrefs.enabled = true;
    LiveVoicePrefs.chosenVoice = null;
  });

  Future<ValueNotifier<String?>> open(
    WidgetTester t, {
    Future<Uint8List?> Function(String id)? sampleLoader,
    PcmPlayer? player,
  }) async {
    final picked = ValueNotifier<String?>(null);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              picked.value = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => VoicePickerScreen(
                    voices: _voices,
                    selectedId: 'gleam',
                    sampleLoader: sampleLoader,
                    player: player,
                  ),
                ),
              );
            },
            child: const Text('Open voice picker'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('Open voice picker'));
    await t.pumpAndSettle();
    return picked;
  }

  testWidgets('lists compact OpenAI male and female voice groups', (t) async {
    await open(t);
    expect(find.text('GPT Live voice'), findsOneWidget);
    expect(find.text('Female voices'), findsOneWidget);
    expect(find.text('Male voices'), findsOneWidget);
    expect(find.text('Gleam'), findsNothing);
    expect(find.text('Sulafat'), findsNothing);
    expect(find.text('Callirrhoe'), findsNothing);
    expect(find.text('Fola'), findsNothing);

    await t.tap(find.text('Female voices'));
    await t.pumpAndSettle();
    expect(find.text('Gleam'), findsOneWidget);
    expect(find.text('Willow'), findsOneWidget);
    expect(find.text('Ripple'), findsNothing);

    await t.tap(find.text('Male voices'));
    await t.pumpAndSettle();
    expect(find.text('Ripple'), findsOneWidget);
  });

  testWidgets('plays the OpenAI voice sample from the catalog entry',
      (t) async {
    String? sampled;
    final output = SilentOutput();
    final player = PcmPlayer(output: output, gain: 1);
    await open(
      t,
      player: player,
      sampleLoader: (id) async {
        sampled = id;
        return _wavSample();
      },
    );
    await t.tap(find.text('Female voices'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Play a sample of Willow'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(sampled, 'willow');
    expect(output.written, isNotEmpty);
  });

  testWidgets('returns the selected GPT Live voice id', (t) async {
    final picked = await open(t);
    await t.tap(find.text('Female voices'));
    await t.pumpAndSettle();
    await t.tap(find.text('Willow'));
    await t.pumpAndSettle();
    expect(picked.value, 'willow');
  });

  test('ignores a saved Gemini voice when GPT Live voices are configured', () {
    LiveVoicePrefs.chosenVoice = 'Sulafat';
    const live = AiLive(
      transport: 'gpt-live',
      voice: 'gleam',
      voices: ['gleam', 'willow'],
    );
    expect(LiveVoicePrefs.voiceFor(live), 'gleam');

    LiveVoicePrefs.chosenVoice = 'willow';
    expect(LiveVoicePrefs.voiceFor(live), 'willow');
  });
}

Uint8List _wavSample() {
  final wav = Uint8List(48);
  final data = ByteData.sublistView(wav);
  void text(int offset, String value) {
    wav.setRange(offset, offset + value.length, value.codeUnits);
  }

  text(0, 'RIFF');
  data.setUint32(4, 40, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 48000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, 4, Endian.little);
  data.setInt16(44, 100, Endian.little);
  data.setInt16(46, -100, Endian.little);
  return wav;
}
