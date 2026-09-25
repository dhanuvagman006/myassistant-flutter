import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../models/news_item.dart';
import '../screens/news_story_screen.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  THE NEWS DECK (2026-09-25). Owner: "update how we read the news and how
///  it is dispayed now need card style with images.stacked swipe to see or
///  tap to explan".
///
///  One story per card with the next two peeking behind it. Swipe LEFT for
///  the next story, RIGHT to bring the previous one back (at the first card
///  it springs back); after the last story, "You're all caught up". The
///  card tilts a little as it is dragged and flies off when let go. Tap it
///  for the whole story. Small ‹ › buttons and "3 of 10" underneath.
///
///  Cheap to move: every card is built once and only its transform
///  changes while a finger drags it; nothing ticks once the deck is still.
///  With "Remove animations" on, nothing tilts or flies — the next card
///  simply fades in.
/// ─────────────────────────────────────────────────────────────────────────

/// Moves a [NewsDeck] from outside: the follow-along, news_focus, tests.
class NewsDeckController extends ChangeNotifier {
  NewsDeckController({int index = 0}) : _index = index;

  int _index;
  _NewsDeckState? _deck;

  /// The story at the front; `items.length` is the "all caught up" card.
  int get index => _index;

  /// Bring story [i] to the front: a swipe when it is the next or the
  /// previous card, a quick fade for a longer jump.
  void show(int i) {
    final d = _deck;
    if (d == null) {
      _set(math.max(0, i));
    } else {
      d._show(i);
    }
  }

  /// Where a NEW deck (a new list of stories) starts. No move: the deck
  /// built for that list simply opens there.
  void startAt(int i) => _set(math.max(0, i));

  void next() => _deck?._step(1);
  void previous() => _deck?._step(-1);

  void _set(int i) {
    if (_index == i) return;
    _index = i;
    notifyListeners();
  }
}

/// The picture for [url], decoded at [cacheWidth] px: the card and the
/// precache must ask for the same thing, or the precache is wasted.
ImageProvider newsImageProvider(String url, int? cacheWidth) =>
    ResizeImage.resizeIfNeeded(cacheWidth, null, NetworkImage(url));

/// The request that asks the assistant to read [item] out and explain it
/// — the same turn a spoken "read me that story" takes.
String listenRequest(NewsItem item) =>
    'Read me this news story and tell me what it says: '
    '"${item.title}"${item.url.isNotEmpty ? ' — ${item.url}' : ''}';

class NewsDeck extends StatefulWidget {
  const NewsDeck({
    super.key,
    required this.items,
    this.controller,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 16),
    this.onOpen,
    this.onListen,
    this.onRefresh,
    this.onUserMove,
    this.now,
  });

  final List<NewsItem> items;
  final NewsDeckController? controller;

  /// Around the cards and the controls. The voice deck leaves room here
  /// for the mic that rises over the dock.
  final EdgeInsets padding;

  /// Tapping the front card. Default: the full story, grown from the tap.
  final void Function(NewsItem item, Offset from)? onOpen;

  /// Listen on the full story.
  final ValueChanged<NewsItem>? onListen;

  /// Refresh on the "all caught up" card; no button when null.
  final VoidCallback? onRefresh;

  /// The user moved the deck (a swipe or a button): the follow-along
  /// gives way to them for a while.
  final VoidCallback? onUserMove;

  /// "2 h ago" is measured from this (tests); from the clock otherwise.
  final DateTime? now;

  @override
  State<NewsDeck> createState() => _NewsDeckState();
}

class _NewsDeckState extends State<NewsDeck>
    with SingleTickerProviderStateMixin {
  late NewsDeckController _ctl;

  /// The horizontal travel on screen, in dp. Below zero the front card is
  /// leaving to the left (next); above zero the previous card is coming
  /// back from the left. At rest: 0, and the controller is stopped.
  late final AnimationController _move =
      AnimationController.unbounded(vsync: this);

  int _index = 0;
  double _drag = 0; // the finger's own travel since it went down
  int _jumps = 0; // a jump (or any move with animations off) fades afresh
  double _width = 360;
  int? _cacheWidth;
  VoidCallback? _afterMove;

  int get _n => widget.items.length;
  double get _fly => _width + 48; // fully off screen, tilt and all

  // How far a card may lean at a full card-width of travel (~7°).
  static const double _tilt = 0.12;
  // Past this share of the width, or thrown this fast, a swipe counts.
  static const double _swipeShare = 0.28;
  static const double _flingSpeed = 650;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller ?? NewsDeckController());
  }

  void _attach(NewsDeckController c) {
    _ctl = c;
    _ctl._deck = this;
    _index = _ctl._index.clamp(0, _n);
    _ctl._index = _index;
  }

  @override
  void didUpdateWidget(NewsDeck old) {
    super.didUpdateWidget(old);
    final c = widget.controller;
    if (c != null && !identical(c, _ctl)) {
      if (identical(_ctl._deck, this)) _ctl._deck = null;
      _attach(c);
    } else if (!identical(old.items, widget.items)) {
      // A new list under the same deck: whatever was moving stops where
      // it is, and the deck opens where the controller says.
      if (_move.isAnimating) _move.stop();
      _afterMove = null;
      _move.value = 0;
      _index = _ctl._index.clamp(0, _n);
      _ctl._index = _index;
    }
  }

  @override
  void dispose() {
    if (identical(_ctl._deck, this)) _ctl._deck = null;
    _move.dispose();
    super.dispose();
  }

  bool get _still => Motion.reduced(context);

  /// A move in flight ends where it was going, at once.
  void _finish() {
    if (_move.isAnimating) _move.stop();
    final done = _afterMove;
    _afterMove = null;
    done?.call();
  }

  void _commit(int i) {
    if (!mounted) return;
    setState(() {
      _index = i;
      _move.value = 0;
    });
    _ctl._set(i);
    _precache();
  }

  void _animate(double to, Curve curve, VoidCallback then) {
    _afterMove = then;
    _move.animateTo(to, duration: Motion.short, curve: curve).whenCompleteOrCancel(() {
      if (identical(_afterMove, then)) {
        _afterMove = null;
        then();
      }
    });
  }

  /// One card on or back, as a swipe would do it.
  void _step(int dir, {bool byUser = false}) {
    _finish();
    final target = _index + dir;
    if (target < 0 || target > _n) return;
    if (byUser) widget.onUserMove?.call();
    if (_still) {
      setState(() => _jumps++);
      _commit(target);
    } else if (dir > 0) {
      // The front card leaves: it eases off, then goes.
      _animate(-_fly, Motion.easeExit, () => _commit(target));
    } else {
      // The previous card arrives: fast, then it settles.
      _animate(_fly, Motion.easeEnter, () => _commit(target));
    }
  }

  void _show(int i) {
    final target = i.clamp(0, _n);
    if (target == _index) return;
    if ((target - _index).abs() == 1) {
      _step(target - _index);
      return;
    }
    _finish();
    setState(() => _jumps++);
    _commit(target);
  }

  void _dragStart(DragStartDetails d) {
    _finish();
    _drag = 0;
  }

  void _dragUpdate(DragUpdateDetails d) {
    _drag += d.primaryDelta ?? d.delta.dx;
    // With animations off the card stays put; the swipe still counts.
    if (_still) return;
    _move.value = _shape(_drag);
  }

  /// The finger's travel as screen travel: free where there is a card to
  /// reveal, a firm resistance where there is none (before the first
  /// story, after the last card).
  double _shape(double raw) {
    if (raw < 0 && _index >= _n) return raw * 0.3;
    if (raw > 0 && _index <= 0) return raw * 0.3;
    return raw.clamp(-_fly, _fly);
  }

  void _dragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final far = _width * _swipeShare;
    final next = _drag <= 0 && (_drag < -far || v < -_flingSpeed) && _index < _n;
    final back = _drag >= 0 && (_drag > far || v > _flingSpeed) && _index > 0;
    if (_drag.abs() > 8 || next || back) widget.onUserMove?.call();
    if (next || back) {
      final target = _index + (next ? 1 : -1);
      if (_still) {
        setState(() => _jumps++);
        _commit(target);
        return;
      }
      // A thrown card carries on: fast, then gone.
      _animate(next ? -_fly : _fly, Motion.easeEnter, () => _commit(target));
      return;
    }
    if (_move.value != 0) {
      // Not far enough: it springs back, with no bounce.
      _animate(0, Motion.easeMove, () {});
    }
  }

  void _dragCancel() {
    if (_move.value != 0) _animate(0, Motion.easeMove, () {});
  }

  /// The pictures of the cards coming up, decoded at the card's size
  /// before they are needed.
  void _precache() {
    if (!mounted) return;
    for (var i = _index + 1; i <= _index + 3 && i < _n; i++) {
      for (final url in widget.items[i].imageUrls.take(1)) {
        precacheImage(newsImageProvider(url, _cacheWidth), context,
            onError: (_, __) {});
      }
    }
  }

  void _open(Offset from) {
    _finish(); // a tap mid-move opens the card that is arriving, not the one leaving
    if (_index >= _n) return;
    final item = widget.items[_index];
    final open = widget.onOpen;
    if (open != null) {
      open(item, from);
    } else {
      openNewsStory(context, item,
          from: from, onListen: widget.onListen, now: widget.now);
    }
  }

  bool _warmed = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final pad = widget.padding;
      final w = math.max(1.0, c.maxWidth - pad.horizontal);
      final avail = math.max(0.0, c.maxHeight - pad.vertical);
      final text = MediaQuery.textScalerOf(context);
      final controlsH = math.max(48.0, text.scale(NeonType.footnote) * 1.4 + 20);
      final controls = avail >= controlsH + 8 + 140;
      final peek = math.min(10.0, avail * 0.04);
      // A card keeps a card's shape (at most 1.4 times as tall as it is
      // wide) on a tall screen, and the deck sits in the middle of it.
      final cardH = math.min(
          w * 1.4, math.max(0.0, avail - (controls ? controlsH + 8 : 0) - peek * 2));
      _width = w;
      _cacheWidth = (w * MediaQuery.devicePixelRatioOf(context)).round();
      if (!_warmed) {
        _warmed = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _precache());
      }
      return Padding(
        padding: pad,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: w,
              height: cardH + peek * 2,
              child: _cards(w, cardH, peek),
            ),
            if (controls) ...[
              const SizedBox(height: 8),
              SizedBox(width: w, height: controlsH, child: _controls()),
            ],
          ],
        ),
      );
    });
  }

  Widget _cards(double w, double h, double peek) {
    // Every card is built here once per move, never per frame: the
    // animation below only changes where each one is drawn.
    final built = <int, Widget>{
      for (var pos = math.max(0, _index - 1); pos <= math.min(_index + 3, _n); pos++)
        pos: RepaintBoundary(
          child: pos == _n
              ? _CaughtUpCard(onRefresh: widget.onRefresh)
              : NewsCard(
                  item: widget.items[pos],
                  cacheWidth: _cacheWidth,
                  now: widget.now,
                ),
        ),
    };
    final title = _index < _n ? widget.items[_index].title : "You're all caught up";
    Widget stack = AnimatedBuilder(
      animation: _move,
      builder: (context, _) {
        final dx = _move.value;
        final ahead = dx < 0 && _index < _n ? (-dx / _fly).clamp(0.0, 1.0) : 0.0;
        final behind = dx > 0 && _index > 0 ? (dx / _fly).clamp(0.0, 1.0) : 0.0;
        final layers = <Widget>[];
        for (var k = 3; k >= 1; k--) {
          final pos = _index + k;
          if (pos > _n) continue;
          final depth = k - ahead + behind;
          if (depth >= 3) continue;
          layers.add(_placed(pos, built[pos]!, w, h, peek, depth: depth));
        }
        if (behind > 0) {
          layers.add(_placed(_index, built[_index]!, w, h, peek, depth: behind));
          // The previous card comes back in from the left, following the finger.
          layers.add(_placed(_index - 1, built[_index - 1]!, w, h, peek,
              front: true, dx: dx - _fly));
        } else {
          layers.add(_placed(_index, built[_index]!, w, h, peek, front: true, dx: dx));
        }
        return Stack(clipBehavior: Clip.none, children: layers);
      },
    );
    stack = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => _open(d.globalPosition),
      onHorizontalDragStart: _dragStart,
      onHorizontalDragUpdate: _dragUpdate,
      onHorizontalDragEnd: _dragEnd,
      onHorizontalDragCancel: _dragCancel,
      child: stack,
    );
    // A jump — or any move with animations off — fades the deck in afresh.
    stack = KeyedSubtree(
      key: ValueKey(_jumps),
      child: _jumps == 0
          ? stack
          : EnterOnce(duration: Motion.short, child: stack),
    );
    return Semantics(
      container: true,
      label: 'News stories',
      value: _counter,
      hint: _index < _n ? title : null,
      customSemanticsActions: {
        if (_index < _n)
          const CustomSemanticsAction(label: 'Next story'): () =>
              _step(1, byUser: true),
        if (_index > 0)
          const CustomSemanticsAction(label: 'Previous story'): () =>
              _step(-1, byUser: true),
      },
      child: stack,
    );
  }

  /// One card on the table. [front]: at the front, moved [dx] and leaning
  /// with it; otherwise [depth] cards back — smaller, lower and dimmer,
  /// its bottom edge showing under the card in front. The same widgets
  /// in the same order either way, so a card coming forward is never
  /// built again.
  Widget _placed(int pos, Widget card, double w, double h, double peek,
      {bool front = false, double dx = 0, double depth = 0}) {
    final Matrix4 m;
    var dim = 0.0;
    var opacity = 1.0;
    if (front) {
      m = Matrix4.identity()
        ..translateByDouble(dx, 0, 0, 1)
        ..rotateZ(dx / math.max(1, _width) * _tilt);
    } else {
      final s = 1 - 0.05 * depth;
      m = Matrix4.identity()
        ..translateByDouble(0, peek * depth, 0, 1)
        ..scaleByDouble(s, s, 1, 1);
      dim = (0.16 * depth).clamp(0.0, 0.5);
      opacity = depth <= 2 ? 1.0 : (3 - depth).clamp(0.0, 1.0);
    }
    final atFront = front && pos == _index;
    return Positioned(
      key: ValueKey(pos),
      left: 0,
      top: 0,
      width: w,
      height: h,
      child: IgnorePointer(
        ignoring: !atFront,
        child: ExcludeSemantics(
          excluding: !atFront,
          child: Opacity(
            opacity: opacity,
            child: Transform(
              transform: m,
              alignment: Alignment.bottomCenter,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  card,
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Neon.bg.withValues(alpha: dim),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _counter => '${math.min(_index + 1, _n)} of $_n';

  Widget _controls() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous story',
          onPressed: _index > 0 ? () => _step(-1, byUser: true) : null,
          icon: Icon(Icons.chevron_left_rounded, color: Neon.textLo),
        ),
        Expanded(
          child: Center(
            child: Text(
              _counter,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                  .copyWith(
                color: Neon.textLo,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Next story',
          onPressed: _index < _n ? () => _step(1, byUser: true) : null,
          icon: Icon(Icons.chevron_right_rounded, color: Neon.textLo),
        ),
      ],
    );
  }
}

/// One story as a card: the picture across the top, the publisher's icon
/// and name, "2 h ago", the headline in bold and two lines of summary.
/// Lines are counted to fit the card, so large text shortens the summary
/// and the picture before anything is cut.
class NewsCard extends StatelessWidget {
  const NewsCard({super.key, required this.item, this.cacheWidth, this.now});

  final NewsItem item;
  final int? cacheWidth;
  final DateTime? now;

  static const double _padTop = 12, _padBottom = 14;
  static const double _gapMeta = 8, _gapTitle = 6;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final text = MediaQuery.textScalerOf(context);
      final h = c.maxHeight.isFinite ? c.maxHeight : 420.0;
      final w = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      double line(double size, double height) => text.scale(size) * height;
      final meta = line(NeonType.footnote, 1.3);
      final titleLine = line(NeonType.title3, 1.22);
      final summaryLine = line(NeonType.body, 1.4);
      // The picture takes half the card (never taller than 16:10), and
      // gives way when the words need the room.
      final wantWords = meta + _gapMeta + titleLine * 2 + _gapTitle + summaryLine;
      var picture = math.min(h * 0.5, w * 0.62);
      final room = h - _padTop - _padBottom;
      if (room - picture < wantWords) {
        picture = math.max(h * 0.28, room - wantWords);
      }
      if (picture < 56) picture = 0;
      final words = room - picture;
      final titleLines =
          ((words - meta - _gapMeta) / titleLine).floor().clamp(1, 3);
      // Two lines of summary on a card; a tall one (Hub → News) uses its
      // room for more rather than leaving it blank.
      final summaryLines = ((words - meta - _gapMeta - titleLines * titleLine - _gapTitle) /
              summaryLine)
          .floor()
          .clamp(0, h >= 480 ? 6 : 2);
      final ageText = item.ageLabel(now);
      final metaText = [item.source, ageText].where((s) => s.isNotEmpty).join(' · ');
      return Semantics(
        container: true,
        button: true,
        label: item.title,
        hint: 'Opens the story',
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Neon.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Neon.line),
            boxShadow: Neon.cardShadow,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (picture > 0)
                  SizedBox(
                    height: picture,
                    child: NewsImage(item: item, cacheWidth: cacheWidth),
                  ),
                Expanded(
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(16, _padTop, 16, _padBottom),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                NewsFavicon(item: item),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    metaText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: NeonType.manrope(
                                            NeonType.footnote, FontWeight.w600)
                                        .copyWith(
                                            color: Neon.textLo, height: 1.3),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: _gapMeta),
                            Text(
                              item.title,
                              maxLines: titleLines,
                              overflow: TextOverflow.ellipsis,
                              style: NeonType.manrope(
                                      NeonType.title3, FontWeight.w800)
                                  .copyWith(
                                color: Neon.textHi,
                                height: 1.22,
                                letterSpacing: -0.3,
                              ),
                            ),
                            if (summaryLines > 0 && _summary.isNotEmpty) ...[
                              const SizedBox(height: _gapTitle),
                              Text(
                                _summary,
                                maxLines: summaryLines,
                                overflow: TextOverflow.ellipsis,
                                style: NeonType.manrope(
                                        NeonType.body, FontWeight.w500)
                                    .copyWith(color: Neon.textLo, height: 1.4),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  String get _summary =>
      [item.snippet, ...item.extra].where((s) => s.isNotEmpty).join(' ');
}

/// A story's picture: the full one, then the small copy, then the
/// gradient with the publisher's initial. Fades in when it arrives.
class NewsImage extends StatefulWidget {
  const NewsImage({super.key, required this.item, this.cacheWidth});

  final NewsItem item;
  final int? cacheWidth;

  @override
  State<NewsImage> createState() => _NewsImageState();
}

class _NewsImageState extends State<NewsImage> {
  int _attempt = 0; // which of item.imageUrls is being tried

  @override
  void didUpdateWidget(NewsImage old) {
    super.didUpdateWidget(old);
    if (old.item.key != widget.item.key) _attempt = 0;
  }

  void _failed(int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _attempt == attempt) setState(() => _attempt++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final urls = widget.item.imageUrls;
    final ground = NewsPlaceholder(item: widget.item);
    if (_attempt >= urls.length) return ground;
    final attempt = _attempt;
    final still = Motion.reduced(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ground,
        Image(
          key: ValueKey(urls[attempt]),
          image: newsImageProvider(urls[attempt], widget.cacheWidth),
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, sync) {
            if (sync || still) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: Motion.short,
              curve: Motion.easeFadeIn,
              child: child,
            );
          },
          errorBuilder: (context, _, __) {
            _failed(attempt);
            return const SizedBox.shrink();
          },
        ),
      ],
    );
  }
}

/// No picture: a soft gradient in the theme colour with the publisher's
/// initial, so a card without one still looks like a card.
class NewsPlaceholder extends StatelessWidget {
  const NewsPlaceholder({super.key, required this.item});

  final NewsItem item;

  @override
  Widget build(BuildContext context) {
    final a = Color.lerp(Neon.surface, Neon.violet, 0.55)!;
    final b = Color.lerp(Neon.surface, Neon.pink, 0.40)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [a, b],
        ),
      ),
      child: Center(
        child: FractionallySizedBox(
          heightFactor: 0.42,
          child: FittedBox(
            child: Text(
              item.initial,
              style: NeonType.manrope(NeonType.largeTitle, FontWeight.w800)
                  .copyWith(color: Neon.textOn(Color.lerp(a, b, 0.5)!)),
            ),
          ),
        ),
      ),
    );
  }
}

/// The publisher's icon, or its initial in a small round when there is
/// none (or it will not load).
class NewsFavicon extends StatelessWidget {
  const NewsFavicon({super.key, required this.item, this.size = 18});

  final NewsItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: Neon.violet, shape: BoxShape.circle),
      child: FittedBox(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Text(
            item.initial,
            style: NeonType.manrope(NeonType.caption, FontWeight.w800)
                .copyWith(color: Neon.onAccent),
          ),
        ),
      ),
    );
    if (item.favicon.isEmpty) return fallback;
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image(
        image: newsImageProvider(item.favicon, px),
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

/// After the last story.
class _CaughtUpCard extends StatelessWidget {
  const _CaughtUpCard({this.onRefresh});

  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Neon.line),
        boxShadow: Neon.cardShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Center(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_rounded, size: 44, color: Neon.violet),
                const SizedBox(height: 12),
                Text(
                  "You're all caught up",
                  textAlign: TextAlign.center,
                  style: NeonType.manrope(NeonType.title3, FontWeight.w800)
                      .copyWith(color: Neon.textHi),
                ),
                const SizedBox(height: 6),
                Text(
                  "That's every story for now.",
                  textAlign: TextAlign.center,
                  style: NeonType.manrope(NeonType.body, FontWeight.w500)
                      .copyWith(color: Neon.textLo),
                ),
                if (onRefresh != null) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: onRefresh,
                    style: FilledButton.styleFrom(
                      backgroundColor: Neon.violet,
                      foregroundColor: Neon.onAccent,
                      minimumSize: const Size(48, 48),
                      textStyle:
                          NeonType.manrope(NeonType.rowTitle, FontWeight.w600),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Refresh'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
