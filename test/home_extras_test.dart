import 'package:flutter_test/flutter_test.dart';
import 'package:myassistant/features/home/home_extras.dart';
import 'package:myassistant/models/brief.dart';
import 'package:myassistant/models/news_item.dart';

/// Always useful Home (2026-09-30): under the personal cards, context and
/// then discovery — as much as there is room for, never invented.

final day = DateTime(2026, 9, 30, 15);
const rain = WeatherNote(kind: 'rain', text: 'Rain likely 5 pm to 7 pm', from: '17:00');
const story = NewsItem(title: 'Monsoon reaches the coast', url: 'https://example.org/a', source: 'example.org');

void main() {
  test('room shrinks as the day fills: none for a full day, two for an empty one', () {
    expect(HomeExtras.room(personal: 0, hasDay: false), 3);
    expect(HomeExtras.room(personal: 1, hasDay: false), 2);
    expect(HomeExtras.room(personal: 1, hasDay: true), 1);
    expect(HomeExtras.room(personal: 2, hasDay: false), 1);
    expect(HomeExtras.room(personal: 2, hasDay: true), 0);
    expect(HomeExtras.room(personal: 3, hasDay: false), 0);
  });

  test('context before discovery: weather, the list, then news, then a tip', () {
    final all = HomeExtras.pick(room: 2, now: day, weather: rain, toBuy: 3,
        toBuyNames: const ['milk', 'eggs', 'bread'], news: const [story]);
    expect([for (final e in all) e.kind], [HomeExtraKind.weather, HomeExtraKind.shopping]);
    final quiet = HomeExtras.pick(room: 2, now: day, news: const [story]);
    expect([for (final e in quiet) e.kind], [HomeExtraKind.news, HomeExtraKind.tip]);
  });

  test('with nothing else there is always the tip; with no room, nothing', () {
    expect([for (final e in HomeExtras.pick(room: 2, now: day)) e.kind], [HomeExtraKind.tip]);
    expect(HomeExtras.pick(room: 0, now: day, weather: rain, news: const [story]), isEmpty);
  });

  test('news off means no headlines; a tip put away today stays away', () {
    final off = HomeExtras.pick(room: 2, now: day, news: const [story], newsOn: false);
    expect([for (final e in off) e.kind], [HomeExtraKind.tip]);
    final tipId = 'tip:${HomeExtras.tipFor(day).id}';
    expect(HomeExtras.pick(room: 2, now: day, hidden: {tipId}), isEmpty);
  });

  test('two headlines at most', () {
    final many = List.generate(6, (i) => NewsItem(title: 'Story $i', url: 'https://e.org/$i'));
    expect(HomeExtras.pick(room: 1, now: day, news: many).single.news, hasLength(2));
  });

  test('a different tip each day, the same one all day; a tap never acts', () {
    final a = HomeExtras.tipFor(DateTime(2026, 9, 30, 8));
    expect(HomeExtras.tipFor(DateTime(2026, 9, 30, 22)).id, a.id);
    expect(HomeExtras.tipFor(DateTime(2026, 10, 1, 8)).id, isNot(a.id));
    for (final t in HomeExtras.tips) {
      final acts = RegExp(r'^(Add|Record|Remind|Tell|Send)').hasMatch(t.say);
      expect(t.ask == null, acts, reason: '"${t.say}": only questions run with a tap');
    }
  });

  test('the brief reads the weather note, and its absence', () {
    final b = TodayBrief.fromJson({
      'weather_note': {'kind': 'rain', 'text': 'Rain likely 5 pm to 7 pm', 'from': '17:00'},
    });
    expect(b.weatherNote!.from, '17:00');
    expect(TodayBrief.fromJson({'weather_note': null}).weatherNote, isNull);
  });
}
