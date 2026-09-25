import 'dart:math' as math;

import '../models/news_item.dart';

/// FOLLOW-ALONG (2026-09-25). While the assistant reads the headlines out,
/// the card whose headline is being spoken comes to the front of the deck,
/// matched from the live captions.
///
/// The test is deliberately plain: the significant words of a headline,
/// against the latest ~30 words heard. It must survive the assistant
/// saying a headline in a shorter line of its own ("the monsoon has
/// arrived early in Kerala"), so words are compared by a light stem, and
/// it must never jump on a single shared word, so a match needs 60% of
/// the headline's words (of at most eight) and two of them at least.
abstract final class NewsFollow {
  /// Share of a headline's significant words that must have been heard.
  static const double threshold = 0.6;

  /// How many of the latest words heard are compared.
  static const int window = 30;

  static const _stop = {
    'the', 'and', 'for', 'with', 'from', 'that', 'this', 'these', 'those',
    'are', 'was', 'were', 'has', 'have', 'had', 'will', 'would', 'can',
    'could', 'into', 'onto', 'over', 'after', 'before', 'about', 'than',
    'then', 'its', 'his', 'her', 'their', 'our', 'your', 'you', 'they',
    'them', 'what', 'when', 'where', 'who', 'why', 'how', 'all', 'any',
    'not', 'but', 'out', 'off', 'per', 'via', 'amid', 'also', 'just',
    'here', 'there', 'now', 'today', 'says', 'said', 'say', 'news',
    'latest', 'live', 'update', 'updates', 'breaking', 'headline',
    'headlines', 'story', 'stories', 'report', 'reports', 'top', 'india',
    'indian', 'first', 'second', 'third', 'fourth', 'fifth', 'next',
    'finally', 'last', 'one', 'two', 'three', 'sir', 'maam', 'madam',
  };

  /// "Wickets" and "wicket", "arrives" and "arrived", are one word here.
  static String stem(String w) {
    var s = w;
    if (s.length > 5 && s.endsWith('ing')) {
      s = s.substring(0, s.length - 3);
    } else if (s.length > 4 && (s.endsWith('ed') || s.endsWith('es'))) {
      s = s.substring(0, s.length - 2);
    } else if (s.length > 3 && s.endsWith('s') && !s.endsWith('ss')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.length > 4 && s.endsWith('e')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// Lower-case words, apostrophes' "s" dropped, punctuation gone.
  static List<String> words(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r"['’]s\b"), '')
      .replaceAll(RegExp(r"[^\p{L}\p{N}\s]", unicode: true), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);

  /// The words that tell one headline from another: no function words,
  /// no "news"/"today", no bare numbers (a spoken "six" is not "6").
  static Set<String> significant(Iterable<String> ws) => {
        for (final w in ws)
          if (w.length >= 3 &&
              !_stop.contains(w) &&
              !RegExp(r'^\d+$').hasMatch(w))
            stem(w),
      };

  /// How much of [headline] is in [heard]: 0..1.
  static double score(String headline, Set<String> heard) {
    final t = significant(words(headline));
    if (t.isEmpty || heard.isEmpty) return 0;
    final hit = t.where(heard.contains).length;
    if (hit < math.min(2, t.length)) return 0;
    return hit / math.min(t.length, 8);
  }

  /// The story being read, when it lies AFTER [current] — the deck only
  /// ever follows forward, so a headline heard again (or an earlier one
  /// still in the window) never pulls it back. Null when nothing matches.
  static int? next(List<NewsItem> items, String spoken, {required int current}) {
    final all = words(spoken);
    if (all.isEmpty) return null;
    final heard =
        significant(all.length > window ? all.sublist(all.length - window) : all);
    int? best;
    var bestScore = threshold - 1e-9;
    for (var i = math.max(0, current + 1); i < items.length; i++) {
      final s = score(items[i].title, heard);
      if (s > bestScore) {
        best = i;
        bestScore = s;
      }
    }
    return best;
  }
}
