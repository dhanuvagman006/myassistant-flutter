// THE VOICE SCREEN (2026-09-30): the fast live voice's switch (on unless
// turned off, kept on the phone) and its own voices, beside the classic
// voice list that still picks the cascade's voice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/live_voice.dart';
import 'package:myassistant/screens/voice_picker_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveVoicePrefs.enabled = true;
    LiveVoicePrefs.chosenVoice = null;
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(
      home: VoicePickerScreen(voices: [
        ('', 'Fola', 'Expressive · Female · the default'),
        ('Kore', 'Kore', 'Warm · Female'),
      ], selectedId: ''),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('the fast voice is on by default, with its voices', (t) async {
    await open(t);
    expect(find.text('Fast live voice'), findsOneWidget);
    final sw = t.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);
    for (final v in AiLive.defaultVoices.take(3)) {
      expect(find.text(v), findsWidgets);
    }
    expect(find.byTooltip('Play a sample of Callirrhoe'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Fola'), 300);
    expect(find.text('CLASSIC VOICE'), findsOneWidget);
    expect(find.text('Fola'), findsOneWidget);
  });

  testWidgets('turned off: kept, and the Live voices step aside', (t) async {
    await open(t);
    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();
    expect(LiveVoicePrefs.enabled, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(LiveVoicePrefs.onKey), isFalse);
    expect(find.text('LIVE VOICE'), findsNothing);
    expect(find.text('Achernar'), findsNothing);
  });

  testWidgets('a Live voice is picked on the phone; the classic list still pops', (t) async {
    await open(t);
    await t.tap(find.text('Achernar'));
    await t.pumpAndSettle();
    expect(LiveVoicePrefs.chosenVoice, 'Achernar');
    expect((await SharedPreferences.getInstance()).getString(LiveVoicePrefs.voiceKey), 'Achernar');
    expect(LiveVoicePrefs.voiceFor(const AiLive()), 'Achernar');
    expect(find.byType(VoicePickerScreen), findsOneWidget, reason: 'a Live pick does not leave');
  });
}
