import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/home/home_cards.dart';
import 'package:myassistant/features/home/home_memory.dart';
import 'package:myassistant/features/home/weather_card.dart';
import 'package:myassistant/features/home/weather_forecast.dart';
import 'package:myassistant/models/brief.dart';
import 'package:myassistant/services/brief_service.dart';
import 'package:myassistant/services/missed_calls_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Home's weather card and its instant buttons (owner, 2026-09-30: "need
/// weather card in the home page"; "some buttons are laggy… like umbrella
/// reminder").

final now = DateTime(2026, 9, 30, 14, 35);

Map<String, dynamic> sample({String? rainFrom = '16:00'}) => {
      'label': 'Indiranagar',
      'now': {'tempC': 27.9, 'feelsC': 31.3, 'humidity': 58, 'windKmh': 2.1, 'uv': 2.2, 'code': 51, 'isDay': true},
      'hours': [
        for (var i = 0; i < 24; i++)
          {'at': '2026-09-30T${((14 + i) % 24).toString().padLeft(2, '0')}:00', 'hour': (14 + i) % 24,
           'tempC': 28 - i * 0.3, 'rainChance': i < 6 ? 60 : 10, 'mm': 0.2, 'code': 61, 'isDay': i < 4},
      ],
      'days': [
        for (var d = 0; d < 7; d++)
          {'date': '2026-${d < 1 ? '09-30' : '10-0$d'}', 'maxC': 28 + d % 3, 'minC': 19.5 + d % 2, 'mm': d.isEven ? 11.9 : 0,
           'rainChance': 70, 'code': d.isEven ? 81 : 2},
      ],
      if (rainFrom != null) 'rainWindow': {'from': rainFrom, 'to': '20:00', 'peak': 90},
    };

Forecast fc({String? rainFrom = '16:00'}) => Forecast.fromJson(sample(rainFrom: rainFrom), fetchedAt: now)!;

Future<void> card(WidgetTester t, Forecast f) async {
  t.view.physicalSize = const Size(400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: WeatherCard(forecast: f, clock: () => now))),
  ));
  await t.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the forecast reads the server\'s shape; the sky follows the WMO code', () {
    final f = fc();
    expect(f.label, 'Indiranagar');
    expect(f.now.tempC, 27.9);
    expect(f.now.sky, Sky.drizzle);
    expect(f.hours, hasLength(24));
    expect(f.days, hasLength(7));
    expect(f.rainFrom, '16:00');
    expect(skyOf(0), Sky.clear);
    expect(skyOf(95), Sky.storm);
    expect(skyWords(Sky.clear, day: false), 'Clear');
  });

  testWidgets('the card: the sky in words, the temperature, the facts, the rain', (t) async {
    WeatherForecastService.instance.debugSet(fc());
    await card(t, fc());
    expect(find.text('Drizzle'), findsOneWidget);
    expect(find.text('28°'), findsWidgets);
    expect(find.textContaining('Indiranagar'), findsOneWidget);
    expect(find.text('Humidity'), findsOneWidget);
    expect(find.text('Rain likely 4 pm – 8 pm'), findsOneWidget);
    expect(find.text('Next 24 hours'), findsNothing, reason: 'the owner: only this much is enough');
  });

  testWidgets('Remind me is set on the touch, before the server answers; a failure puts it back',
      (t) async {
    final svc = WeatherForecastService.instance..debugSet(fc());
    final gate = Completer<bool>();
    final made = <(String, DateTime)>[];
    WeatherForecastService.createReminder = (text, due) {
      made.add((text, due));
      return gate.future;
    };
    await card(t, fc());
    await t.tap(find.text('Remind me'));
    await t.pump();
    expect(find.text('Set for 3:30 pm'), findsOneWidget, reason: 'answered on the touch');
    expect(made.single.$2, DateTime(2026, 9, 30, 15, 30), reason: 'half an hour before the rain');
    expect(made.single.$1, contains('umbrella'));
    gate.complete(false);
    await t.pump();
    await t.pump();
    expect(find.text('Remind me'), findsOneWidget, reason: 'the server said no: the button is back');
    expect(svc.umbrellaSetFor, isNull);
    await t.pump(const Duration(seconds: 6));
  });

  test('no umbrella reminder once the rain is here', () {
    final svc = WeatherForecastService.instance..debugSet(fc(rainFrom: '14:00'));
    expect(svc.umbrellaTime(now), isNull);
    svc.debugSet(fc(rainFrom: '16:00'));
    expect(svc.umbrellaTime(now), DateTime(2026, 9, 30, 15, 30));
  });

  test('Done takes the card away at once, and puts it back where it was if the server says no',
      () async {
    final a = AgendaItem(id: 7, kind: 'reminder', title: 'Call the bank', atMs: now.millisecondsSinceEpoch);
    final b = AgendaItem(id: 8, kind: 'reminder', title: 'Pay rent', atMs: now.millisecondsSinceEpoch);
    final svc = BriefService.instance..debugShow(TodayBrief(agenda: [a, b]));
    final going = svc.completeReminder(a);
    expect(svc.brief.agenda, [b], reason: 'gone on the tap');
    final ok = await going; // no server in tests: it fails
    expect(ok, isFalse);
    expect(svc.brief.agenda, [a, b], reason: 'back in its place');
  });

  testWidgets('Home shows the weather card, and no second rain row', (t) async {
    SharedPreferences.setMockInitialValues({});
    HomeMemory.instance.debugSet(firstSeen: now.subtract(const Duration(days: 30)));
    MissedCallsService.instance.pending.value = const [];
    WeatherForecastService.instance.debugSet(fc());
    BriefService.instance.debugShow(const TodayBrief(
        weatherNote: WeatherNote(kind: 'rain', text: 'Rain likely 4 pm to 8 pm', from: '16:00')));
    t.view.physicalSize = const Size(400, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HomeFeedView(
          leading: const Text('Good afternoon'),
          padding: const EdgeInsets.all(20),
          clock: () => now,
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 800));
    expect(find.byType(WeatherCard), findsOneWidget);
    expect(find.text('Rain likely 4 pm to 8 pm'), findsNothing, reason: 'the card says it');
    WeatherForecastService.instance.debugSet(null);
  });
}
