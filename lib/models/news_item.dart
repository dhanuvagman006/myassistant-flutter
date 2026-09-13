/// One headline in the news panel.
class NewsItem {
  final String title;
  final String url;
  final String source; // publication hostname, "www." already stripped
  final String age; // "3 hours ago", as the index reported it
  final String snippet;
  final List<String> extra;
  final String thumbnail;

  const NewsItem({
    required this.title,
    required this.url,
    this.source = '',
    this.age = '',
    this.snippet = '',
    this.extra = const [],
    this.thumbnail = '',
  });

  factory NewsItem.fromJson(Map<String, dynamic> j) => NewsItem(
        title: (j['title'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        source: (j['source'] as String?) ?? '',
        age: (j['age'] as String?) ?? '',
        snippet: (j['snippet'] as String?) ?? '',
        extra: ((j['extra'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        thumbnail: (j['thumbnail'] as String?) ?? '',
      );
}
