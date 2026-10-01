// GOOGLE'S SEARCH SUGGESTIONS — what a Google-Search-grounded answer must
// show beside it (Gemini API grounding terms): the searchEntryPoint's
// renderedContent. It is a small piece of HTML with one
// <a class="chip" href="https://www.google.com/search?q=…">query</a> per
// suggestion; the app has no web view on that screen, so the chips are
// shown as a row of tappable chips that open the same Google links.

class SearchSuggestion {
  const SearchSuggestion({required this.label, required this.url});

  /// The query, as Google wrote it on the chip.
  final String label;

  /// The Google search page the chip opens.
  final String url;

  @override
  bool operator ==(Object other) =>
      other is SearchSuggestion && other.label == label && other.url == url;

  @override
  int get hashCode => Object.hash(label, url);

  @override
  String toString() => '$label <$url>';
}

final _anchor = RegExp(r'<a\b([^>]*)>([\s\S]*?)</a>', caseSensitive: false);
final _href = RegExp(r'''href\s*=\s*(?:"([^"]*)"|'([^']*)')''', caseSensitive: false);
final _class = RegExp(r'''class\s*=\s*(?:"([^"]*)"|'([^']*)')''', caseSensitive: false);
final _tag = RegExp(r'<[^>]*>');

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ');

/// The chips in [html] (Google's renderedContent), in order; empty when
/// there are none or [html] is null. Only https links are kept.
List<SearchSuggestion> parseSearchSuggestions(String? html) {
  if (html == null || html.trim().isEmpty) return const [];
  final out = <SearchSuggestion>[];
  for (final a in _anchor.allMatches(html)) {
    final attrs = a.group(1) ?? '';
    final cls = _class.firstMatch(attrs);
    final classes = (cls?.group(1) ?? cls?.group(2) ?? '').split(RegExp(r'\s+'));
    if (!classes.contains('chip')) continue;
    final h = _href.firstMatch(attrs);
    final url = _unescape((h?.group(1) ?? h?.group(2) ?? '').trim());
    final label = _unescape((a.group(2) ?? '').replaceAll(_tag, ' '))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (label.isEmpty || !url.startsWith('https://')) continue;
    final s = SearchSuggestion(label: label, url: url);
    if (!out.contains(s)) out.add(s);
  }
  return out;
}
