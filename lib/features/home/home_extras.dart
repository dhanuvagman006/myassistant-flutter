import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/brief.dart';
import '../../models/news_item.dart';
import '../../services/news_feed.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  ALWAYS USEFUL (2026-09-30, owner). With nothing personal to show, Home
///  was a greeting, "You're all clear" and a lot of empty screen. Below the
///  personal cards there is now a short fallback, in the owner's order:
///
///    1. PERSONAL  — the Now and Also cards (home_feed.dart)
///    2. CONTEXT   — the weather worth knowing about (rain on its way,
///                   heat, strong sun), what is left on the shopping list
///    3. DISCOVERY — two headlines, from the topic the user reads in News
///                   (top stories otherwise), and one thing to try asking
///
///  Room for them shrinks as the day fills: three personal cards (or two
///  and the day's list) leave none; nothing personal leaves two. Every
///  one is real data or a real capability with a button; nothing is
///  invented to fill space, and headlines are marked as the news they are.
/// ─────────────────────────────────────────────────────────────────────────

enum HomeExtraKind { weather, shopping, news, tip }

/// Something the assistant can really do, and how to try it. [ask] is the
/// request a tap sends — only for tips that change nothing (a question);
/// tips that would act (add, remind, send, record) open the mic instead,
/// so a tap never adds "milk" to someone's list.
class HomeTip {
  const HomeTip(this.id, this.say, this.why, {this.ask});
  final String id;
  final String say;
  final String why;
  final String? ask;
}

class HomeExtra {
  const HomeExtra.weather(WeatherNote this.weather)
      : kind = HomeExtraKind.weather,
        id = 'weather',
        toBuy = 0,
        toBuyNames = const [],
        news = const [],
        tip = null;
  const HomeExtra.shopping(this.toBuy, this.toBuyNames)
      : kind = HomeExtraKind.shopping,
        id = 'shopping',
        weather = null,
        news = const [],
        tip = null;
  const HomeExtra.news(this.news)
      : kind = HomeExtraKind.news,
        id = 'news',
        weather = null,
        toBuy = 0,
        toBuyNames = const [],
        tip = null;
  HomeExtra.tip(HomeTip this.tip)
      : kind = HomeExtraKind.tip,
        id = 'tip:${tip.id}',
        weather = null,
        toBuy = 0,
        toBuyNames = const [],
        news = const [];

  final HomeExtraKind kind;
  final String id;
  final WeatherNote? weather;
  final int toBuy;
  final List<String> toBuyNames;
  final List<NewsItem> news;
  final HomeTip? tip;
}

abstract final class HomeExtras {
  /// Headlines on the card.
  static const maxNews = 2;

  /// Real capabilities only. A question can be tried with one tap; an
  /// action is said by the user, in their own words.
  static const tips = [
    HomeTip('brief', 'Brief me for today', 'Your day, your messages and the weather in one go.',
        ask: 'Give me my brief for today.'),
    HomeTip('promises', 'What did I promise?', 'I keep track of what you tell people you will do.',
        ask: 'What have I promised anyone recently?'),
    HomeTip('shopping', 'Add milk to my shopping list', 'One list for anything to buy, from any conversation.'),
    HomeTip('meeting', 'Record this meeting', 'I write the minutes, the decisions and who does what.'),
    HomeTip('remind', 'Remind me to call Amma at 6', 'Reminders that ring, or call you, at the time.'),
    HomeTip('news', 'Read me the news', 'Today\'s stories, read out, and explained if you ask.',
        ask: 'Read me today\'s top news.'),
    HomeTip('weather', 'Will it rain this evening?', 'The weather where you are, hour by hour.',
        ask: 'Will it rain this evening?'),
    HomeTip('message', 'Tell Priya I\'m running late', 'Messages sent for you — I always check with you first.'),
  ];

  /// Today's tip: a different one each day, the same one all day.
  static HomeTip tipFor(DateTime day) {
    final n = DateTime.utc(day.year, day.month, day.day)
        .difference(DateTime.utc(day.year))
        .inDays;
    return tips[n % tips.length];
  }

  /// How many fallback cards fit under what is personal: a full day leaves
  /// none; an empty one three (on the owner's phone two left half the
  /// screen bare, 2026-09-30).
  static int room({required int personal, required bool hasDay}) =>
      personal == 0 && !hasDay ? 3 : (3 - personal - (hasDay ? 1 : 0)).clamp(0, 2);

  /// The fallback cards, context before discovery, at most [room] of them.
  static List<HomeExtra> pick({
    required int room,
    required DateTime now,
    WeatherNote? weather,
    int toBuy = 0,
    List<String> toBuyNames = const [],
    List<NewsItem> news = const [],
    bool newsOn = true,
    Set<String> hidden = const {},
  }) {
    if (room <= 0) return const [];
    final tip = tipFor(now);
    final all = <HomeExtra>[
      if (weather != null && weather.text.isNotEmpty) HomeExtra.weather(weather),
      if (toBuy > 0) HomeExtra.shopping(toBuy, toBuyNames),
      if (newsOn && news.isNotEmpty) HomeExtra.news(news.take(maxNews).toList()),
      HomeExtra.tip(tip),
    ];
    return [for (final e in all) if (!hidden.contains(e.id)) e].take(room).toList();
  }
}

/// The headlines Home shows: the topic the user last read in News (saved
/// on the phone, refreshed in the background at launch), else the brief's
/// top headlines. Never fetched just for Home, and never made up.
class HomeNews extends ChangeNotifier {
  HomeNews._();
  static final HomeNews instance = HomeNews._();

  List<NewsItem> _saved = const [];
  DateTime? _loadedAt;

  /// Reads the saved copy (cheap; at most once a minute).
  Future<void> load() async {
    final now = DateTime.now();
    if (_loadedAt != null && now.difference(_loadedAt!) < const Duration(minutes: 1)) return;
    _loadedAt = now;
    try {
      final p = await SharedPreferences.getInstance();
      final topic = p.getString('news_topic') ?? '';
      final saved = await NewsFeedCache.load(topic) ??
          (topic.isEmpty ? null : await NewsFeedCache.load(''));
      final items = saved?.items ?? const <NewsItem>[];
      if (!listEquals(items.map((i) => i.url).toList(), _saved.map((i) => i.url).toList())) {
        _saved = items;
        notifyListeners();
      }
    } catch (_) {/* the brief's headlines stand in */}
  }

  /// What to show, given the brief's own headlines as the fallback.
  List<NewsItem> itemsWith(List<Headline> headlines) {
    if (_saved.isNotEmpty) return _saved;
    return [
      for (final h in headlines)
        if (h.title.isNotEmpty && h.url.isNotEmpty)
          NewsItem(title: h.title, url: h.url, source: h.source),
    ];
  }

  @visibleForTesting
  void debugSet(List<NewsItem> items) {
    _saved = items;
    _loadedAt = DateTime.now();
    notifyListeners();
  }
}
