import 'dart:convert';

import 'package:crypto/crypto.dart';

/// One story: a card in the news deck (voice and Hub → News).
///
/// The server sends the same shape from show_news and GET /news/feed
/// (2026-09-25). Older servers sent no id, picture fields or time; those
/// stay empty and the card falls back to its gradient.
class NewsItem {
  /// First 12 hex of sha1(url) — the server's id, derived here the same
  /// way when an older server did not send one, so news_focus still finds
  /// the card.
  final String id;
  final String title;
  final String url;
  final String source; // publication hostname, "www." already stripped
  final String age; // "3 hours ago", as the index reported it
  final int? ageMins;
  final DateTime? publishedAt; // exact, when the index knows it
  final String snippet;
  final List<String> extra;
  final String image; // the publisher's full picture
  final String thumbnail; // a small copy, tried when the full one fails
  final String favicon; // the publisher's icon

  const NewsItem({
    this.id = '',
    required this.title,
    required this.url,
    this.source = '',
    this.age = '',
    this.ageMins,
    this.publishedAt,
    this.snippet = '',
    this.extra = const [],
    this.image = '',
    this.thumbnail = '',
    this.favicon = '',
  });

  /// The picture to try first: the full one, else the small copy.
  String get imageUrl => image.isNotEmpty ? image : thumbnail;

  /// Every picture worth trying, best first.
  List<String> get imageUrls => [
        if (image.isNotEmpty) image,
        if (thumbnail.isNotEmpty && thumbnail != image) thumbnail,
      ];

  /// The id to match a news_focus against — never empty.
  String get key => id.isNotEmpty ? id : idFor(url.isNotEmpty ? url : title);

  static String idFor(String url) =>
      sha1.convert(utf8.encode(url)).toString().substring(0, 12);

  factory NewsItem.fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] is String) ? (j[k] as String) : '';
    final url = s('url');
    final title = s('title');
    final mins = j['ageMins'];
    final extra = j['extra'];
    return NewsItem(
      id: s('id').isNotEmpty ? s('id') : idFor(url.isNotEmpty ? url : title),
      title: title,
      url: url,
      source: s('source'),
      age: s('age'),
      ageMins: mins is num ? mins.round() : null,
      publishedAt: DateTime.tryParse(s('publishedAt'))?.toUtc(),
      snippet: s('snippet'),
      extra: (extra is List ? extra : const [])
          .whereType<String>()
          .toList(growable: false),
      image: s('image'),
      thumbnail: s('thumbnail'),
      favicon: s('favicon'),
    );
  }

  /// For the per-topic cache on the phone (Hub → News opens from it).
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'source': source,
        'age': age,
        'ageMins': ageMins,
        'publishedAt': publishedAt?.toUtc().toIso8601String(),
        'snippet': snippet,
        'extra': extra,
        'image': image,
        'thumbnail': thumbnail,
        'favicon': favicon,
      };

  /// "2 h ago" from the exact time when there is one; otherwise the
  /// index's own words, which were true when the list was fetched.
  String ageLabel([DateTime? now]) {
    final at = publishedAt;
    if (at == null) return age;
    final mins = (now ?? DateTime.now()).toUtc().difference(at).inMinutes;
    if (mins < 1) return 'just now';
    if (mins < 60) return '$mins min ago';
    final hours = mins ~/ 60;
    if (hours < 24) return '$hours h ago';
    final days = hours ~/ 24;
    return days == 1 ? 'yesterday' : '$days days ago';
  }

  /// The publisher's initial, for the gradient card with no picture.
  String get initial {
    final name = source.isNotEmpty ? source : title;
    final m = RegExp(r'[A-Za-z0-9]').firstMatch(name);
    return m == null ? '•' : m.group(0)!.toUpperCase();
  }
}

/// A request from the assistant to bring one story to the front of the
/// deck (read_news_story → news_focus). A new object per request, so
/// asking for the same story twice still moves the deck.
class NewsFocusRequest {
  final String id;
  NewsFocusRequest(this.id);
}
