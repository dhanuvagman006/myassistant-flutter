import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../models/news_item.dart';
import 'api_service.dart';

/// Hub → News: GET /news/feed, and the last feed per topic kept on the
/// phone so the screen opens instantly — and offline — from what was
/// there last time, then refreshes (2026-09-25).
abstract final class NewsFeed {
  /// Stories for [topic] ('' = top stories), or null when the server
  /// could not be reached or said no.
  static Future<List<NewsItem>?> fetch(String topic, {int count = 12}) async {
    final query = Uri(queryParameters: {
      if (topic.isNotEmpty) 'topic': topic,
      'count': '$count',
    }).query;
    // The server may look up a few pictures before it answers (about
    // three seconds at most): the 6 s default is too tight.
    final j = await ApiService.getJson('/news/feed?$query',
        timeout: const Duration(seconds: 15));
    if (j == null || j['ok'] != true) return null;
    return parse(j['items']);
  }

  static List<NewsItem> parse(Object? raw) => (raw is List ? raw : const [])
      .whereType<Map<String, dynamic>>()
      .map(NewsItem.fromJson)
      .where((n) => n.title.isNotEmpty)
      .toList(growable: false);
}

/// The last feed per topic, as the server sent it.
abstract final class NewsFeedCache {
  static String _key(String topic) =>
      'news_feed_v1_${topic.isEmpty ? 'top' : topic}';

  static Future<({List<NewsItem> items, DateTime savedAt})?> load(
      String topic) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(topic));
      if (raw == null) return null;
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final items = NewsFeed.parse(j['items']);
      final at = DateTime.tryParse('${j['savedAt'] ?? ''}');
      if (items.isEmpty || at == null) return null;
      return (items: items, savedAt: at);
    } catch (e) {
      AppLog.add('news', 'cached feed unreadable: $e');
      return null;
    }
  }

  static Future<void> save(String topic, List<NewsItem> items) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _key(topic),
          jsonEncode({
            'savedAt': DateTime.now().toUtc().toIso8601String(),
            'items': [for (final n in items) n.toJson()],
          }));
    } catch (e) {
      AppLog.add('news', 'feed not cached: $e');
    }
  }
}
