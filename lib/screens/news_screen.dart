import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/log.dart';
import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart'
    show NeonEmptyState, NeonErrorState, NeonLoader, NeonScaffold;
import '../features/assistant/state/assistant_engine.dart';
import '../models/news_item.dart';
import '../services/news_feed.dart';
import '../widgets/news_deck.dart';

/// Where the stories for a topic come from ('' = top stories). Null when
/// they could not be fetched.
typedef NewsFeedLoader = Future<List<NewsItem>?> Function(String topic);

/// HUB → NEWS (2026-09-25): the deck of story cards, by topic, full screen.
/// Owner: "need card style with images.stacked swipe to see or tap to
/// explan".
///
/// It opens at once from the last copy kept on the phone for that topic
/// (so it works offline too), then refreshes; a failed refresh keeps the
/// saved stories and says so.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key, this.loader, this.now});

  /// Tests pass their own; the app asks the server (GET /news/feed).
  final NewsFeedLoader? loader;
  final DateTime? now;

  /// The chips: label, and the topic the server is asked for.
  static const topics = <(String, String)>[
    ('Top', ''),
    ('India', 'india'),
    ('World', 'world'),
    ('Business', 'business'),
    ('Tech', 'tech'),
    ('Sports', 'sports'),
    ('Entertainment', 'entertainment'),
    ('Science', 'science'),
    ('Health', 'health'),
  ];

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  static const _topicPref = 'news_topic';

  final _deck = NewsDeckController();
  String _topic = '';
  List<NewsItem> _items = const [];
  bool _loading = true;
  bool _stale = false; // showing the saved stories: the refresh failed
  bool _failed = false; // nothing to show at all
  int _gen = 0; // a newer request wins over a slower older one

  @override
  void initState() {
    super.initState();
    AssistantEngine.instance.newsFocus.addListener(_focus);
    unawaited(_start());
  }

  @override
  void dispose() {
    AssistantEngine.instance.newsFocus.removeListener(_focus);
    _deck.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    var topic = '';
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString(_topicPref) ?? '';
      if (NewsScreen.topics.any((t) => t.$2 == saved)) topic = saved;
    } catch (_) {}
    if (mounted) await _open(topic);
  }

  Future<void> _open(String topic) async {
    final gen = ++_gen;
    _deck.startAt(0);
    setState(() {
      _topic = topic;
      _items = const [];
      _loading = true;
      _stale = false;
      _failed = false;
    });
    unawaited(SharedPreferences.getInstance()
        .then((p) => p.setString(_topicPref, topic))
        .catchError((_) => false));
    final saved = await NewsFeedCache.load(topic);
    if (!mounted || gen != _gen) return;
    if (saved != null) {
      _deck.startAt(0);
      setState(() {
        _items = saved.items;
        _loading = false;
      });
    }
    await _refresh(gen);
  }

  /// A loader that throws is a failed fetch (null), never a stuck spinner.
  Future<List<NewsItem>?> _fetch(String topic) async {
    try {
      return await (widget.loader ?? NewsFeed.fetch)(topic);
    } catch (e) {
      AppLog.add('news', 'feed load failed: $e');
      return null;
    }
  }

  Future<void> _refresh(int gen) async {
    final topic = _topic;
    final fresh = await _fetch(topic);
    if (!mounted || gen != _gen) return;
    if (fresh != null && fresh.isNotEmpty) {
      // Reading the saved copy when the fresh one lands: stay on the same
      // story if it is still there, rather than jumping back to the top.
      final i = _deck.index;
      final at = i < _items.length ? _items[i].key : null;
      final keep = at == null ? -1 : fresh.indexWhere((n) => n.key == at);
      _deck.startAt(math.max(0, keep));
      setState(() {
        _items = fresh;
        _loading = false;
        _stale = false;
        _failed = false;
      });
      unawaited(NewsFeedCache.save(topic, fresh));
    } else {
      // null = the fetch failed; [] = a good answer with no stories.
      final failed = fresh == null;
      setState(() {
        _loading = false;
        _stale = failed && _items.isNotEmpty;
        _failed = failed && _items.isEmpty;
      });
    }
  }

  void _refreshNow() {
    final gen = ++_gen;
    setState(() {
      _failed = false;
      _loading = _items.isEmpty;
    });
    unawaited(_refresh(gen));
  }

  /// "Read me the second one" asked from here: that card comes forward.
  void _focus() {
    final want = AssistantEngine.instance.newsFocus.value;
    if (want == null) return;
    final i = _items.indexWhere((n) => n.key == want.id);
    if (i >= 0) _deck.show(i);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    // 2026-09-30: under the app's sky.
    return NeonScaffold(
      appBar: appleAppBar(context, 'News', actions: [
        IconButton(
          tooltip: 'Refresh',
          onPressed: _refreshNow,
          icon: Icon(Icons.refresh_rounded, color: Neon.textLo),
        ),
      ]),
      body: Column(
        children: [
          _chips(),
          if (_stale)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
              child: Text(
                "Couldn't refresh — showing the stories saved earlier.",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: NeonType.manrope(NeonType.caption, FontWeight.w500)
                    .copyWith(color: Neon.textDim),
              ),
            ),
          Expanded(
            child: LoadSwitch(
              loading: _loading && _items.isEmpty,
              spinner: const NeonLoader.page(label: 'Loading the news…'),
              child: _items.isEmpty
                  ? _empty()
                  : NewsDeck(
                      key: ObjectKey(_items),
                      items: _items,
                      controller: _deck,
                      now: widget.now,
                      padding: EdgeInsets.fromLTRB(16, 10, 16, 12 + bottom),
                      onRefresh: _refreshNow,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chips() {
    final text = MediaQuery.textScalerOf(context);
    final height = math.max(48.0, text.scale(NeonType.footnote) * 1.35 + 22);
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: NewsScreen.topics.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (label, topic) = NewsScreen.topics[i];
          final on = topic == _topic;
          // THE CHOSEN TOPIC IS LIT (2026-09-30): the accent's fill and
          // its light; the others are dark glass with a thin rim. Each dips
          // under the finger.
          return Center(
            child: Semantics(
              selected: on,
              button: true,
              child: PressScale(
                scale: 0.95,
                child: AnimatedContainer(
                  duration: Motion.reduced(context) ? Duration.zero : Motion.short,
                  curve: Motion.easeMove,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Neon.rPill),
                    boxShadow: Neon.halo(Neon.violet, strength: on ? 0.8 : 0),
                  ),
                  child: Material(
                    color: on
                        ? Neon.accentFill
                        : Color.alphaBlend(
                            Neon.violet.withValues(alpha: 0.06), Neon.surface),
                    shape: StadiumBorder(
                        side: BorderSide(
                            color: on ? Neon.violet : Neon.lineBright)),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: on ? null : () => _open(topic),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: height - 8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              label,
                              style: NeonType.manrope(
                                      NeonType.footnote, FontWeight.w700)
                                  .copyWith(
                                      color: on ? Neon.onAccent : Neon.textHi),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty() {
    if (_failed) {
      return NeonErrorState(
          message: "Couldn't load the news", onRetry: _refreshNow);
    }
    // The theme's lit primary (2026-09-30): its glow comes from the theme.
    return NeonEmptyState(
      icon: Icons.newspaper_rounded,
      title: 'No stories right now',
      body: 'Check your connection, then try again.',
      action: FilledButton.icon(
        onPressed: _refreshNow,
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          textStyle: NeonType.manrope(NeonType.rowTitle, FontWeight.w600),
        ),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text('Try again'),
      ),
    );
  }
}
