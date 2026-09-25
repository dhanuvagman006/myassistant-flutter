import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/dock_metrics.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../models/news_item.dart';
import '../services/app_feedback.dart';
import '../services/news_feed.dart';
import '../services/news_follow.dart';
import 'news_deck.dart';

/// TODAY'S HEADLINES, ON SCREEN.
///
/// Ten headlines read aloud takes over a minute and nobody remembers the
/// fourth. So the stories go here while the assistant says one line and
/// covers the top three — the panel is the answer, the narration is a
/// summary of it.
///
/// A DECK OF CARDS since 2026-09-25 (it was a numbered list): "update how
/// we read the news and how it is dispayed now need card style with
/// images.stacked swipe to see or tap to explan". While the assistant
/// reads the headlines the deck follows along — the card being read comes
/// to the front — and "read me the second one" brings that card forward
/// (read_news_story's news_focus). A swipe of their own wins: the deck
/// stops following for a while.
class NewsPanel extends StatefulWidget {
  const NewsPanel({super.key});

  /// How long a swipe of the user's own holds off the follow-along.
  static const followPause = Duration(seconds: 10);

  /// How long a story brought forward on request stays in front while it
  /// is summarised, before the follow-along may move the deck again.
  static const focusHold = Duration(seconds: 30);

  @override
  State<NewsPanel> createState() => _NewsPanelState();
}

class _NewsPanelState extends State<NewsPanel> {
  final engine = AssistantEngine.instance;
  final _deck = NewsDeckController();
  List<NewsItem> _items = const [];
  // While this runs the follow-along leaves the deck alone. The latest
  // hold replaces the one before: a swipe during a summary hands the deck
  // back to the user for ten seconds, a new summary holds it for thirty.
  Timer? _hold;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _items = engine.newsItems;
    engine.addListener(_sync);
    engine.caption.addListener(_follow);
    engine.newsFocus.addListener(_focus);
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    engine.caption.removeListener(_follow);
    engine.newsFocus.removeListener(_focus);
    _hold?.cancel();
    _deck.dispose();
    super.dispose();
  }

  /// A new set of stories starts at its first card.
  bool _adopt() {
    final items = engine.newsItems;
    if (identical(items, _items)) return false;
    _items = items;
    _deck.startAt(0);
    _hold?.cancel();
    _hold = null;
    return true;
  }

  void _sync() {
    if (!mounted) return;
    if (_adopt() || _items.isEmpty) setState(() {});
  }

  void _holdFor(Duration d) {
    _hold?.cancel();
    _hold = Timer(d, () {});
  }

  /// The card whose headline is being spoken comes to the front.
  void _follow() {
    final line = engine.caption.value;
    if (line == null || line.speaker != 'hari' || _items.isEmpty) return;
    if (_hold?.isActive ?? false) return;
    final i = NewsFollow.next(_items, line.text, current: _deck.index);
    if (i != null) _deck.show(i);
  }

  /// read_news_story: that story comes forward and stays while it is read.
  void _focus() {
    final want = engine.newsFocus.value;
    if (want == null) return;
    final changed = _adopt();
    final i = _items.indexWhere((n) => n.key == want.id);
    if (i >= 0) {
      _holdFor(NewsPanel.focusHold);
      // A deck that is only now opening simply opens on that story.
      if (changed) {
        _deck.startAt(i);
      } else {
        _deck.show(i);
      }
    }
    if (changed && mounted) setState(() {});
  }

  void _close() => engine.clearNews();

  /// "You're all caught up" → Refresh: fresh stories for the same topic,
  /// quietly — no new turn, nothing spoken.
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    final topic = engine.newsTopic;
    final fresh = await NewsFeed.fetch(topic == 'today' ? '' : topic);
    _refreshing = false;
    if (!mounted) return;
    if (fresh == null || fresh.isEmpty) {
      AppFeedback.toast("Couldn't refresh the news — try again in a moment.");
      return;
    }
    engine.showNews(fresh, topic: topic);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) return const SizedBox.shrink();
    final media = MediaQuery.of(context);

    // IT OPENS LIKE A SHEET, NOT IN ONE FRAME (2026-09-24). The scrim fades
    // in and the sheet fades in as it grows from 96%, anchored where its
    // content ends — the dock's top edge, which the deck must never cross,
    // not even mid-animation. Closing stays instant: Back and ✕ take it
    // away at once.
    return Positioned.fill(
      child: LayoutBuilder(builder: (context, c) {
        // A fixed share of the screen for the deck (the cards need a
        // height to lay out in), never more than the room there is.
        final height = (media.size.height * 0.78)
            .clamp(0.0, c.maxHeight - media.padding.top - 8)
            .toDouble();
        return Stack(
          children: [
            // Tap anywhere outside to dismiss — the panel is an answer,
            // not a task, and should never trap anyone.
            GestureDetector(
              onTap: _close,
              child: EnterOnce(
                duration: Motion.short,
                child: Container(color: Colors.black.withValues(alpha: 0.55)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: EnterOnce(
                duration: const Duration(milliseconds: 280),
                scaleFrom: 0.96,
                alignment: Alignment.bottomCenter,
                origin: Offset(0, -media.padding.bottom),
                child: Container(
                  height: height,
                  // The deck ends at the dock's top edge; below it is plain
                  // ground, so nothing shows through the ring around the mic.
                  padding: EdgeInsets.only(bottom: media.padding.bottom),
                  decoration: BoxDecoration(
                    color: Neon.bg,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(22)),
                    border: Border.all(color: Neon.line),
                  ),
                  child: Column(
                    children: [
                      _header(),
                      Expanded(
                        child: NewsDeck(
                          key: ObjectKey(items),
                          items: items,
                          controller: _deck,
                          // The ‹ 3 of 10 › row sits clear above the mic,
                          // which rises over the dock's top edge.
                          padding: const EdgeInsets.fromLTRB(
                              16, 4, 16, Dock.orbRise + 12),
                          onUserMove: () => _holdFor(NewsPanel.followPause),
                          // Listen goes back to the deck, where the words
                          // are shown as the assistant reads them.
                          onListen: (item) {
                            Navigator.of(context).maybePop();
                            engine.askAssistant(listenRequest(item));
                          },
                          onRefresh: _refresh,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _header() {
    final topic = engine.newsTopic;
    final title = topic.isEmpty || topic == 'today'
        ? "Today's headlines"
        : 'News · $topic';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 8, 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: Neon.pink, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          IconButton(
            onPressed: _close,
            icon: Icon(Icons.close_rounded, color: Neon.textLo),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}
