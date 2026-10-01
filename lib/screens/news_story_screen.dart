import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/log.dart';
import '../design/apple_kit.dart';
import '../design/motion.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart' show NeonScaffold;
import '../features/assistant/state/assistant_engine.dart';
import '../models/news_item.dart';
import '../services/app_feedback.dart';
import '../widgets/news_deck.dart';

/// Opens [item] full screen, grown from [from] (where the card was
/// tapped) rather than slid in from the side: the story is the card,
/// opened up (2026-09-25). With [heroTag] ([newsHeroTag]) the card's
/// picture flies to the top of the story, which shows the card's decoded
/// copy ([previewWidth]) until its own sharper one arrives (2026-09-30).
Future<void> openNewsStory(BuildContext context, NewsItem item,
    {Offset? from,
    ValueChanged<NewsItem>? onListen,
    DateTime? now,
    Object? heroTag,
    int? previewWidth}) {
  final size = MediaQuery.sizeOf(context);
  final at = from ?? size.center(Offset.zero);
  final origin = Alignment(
    (at.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
    (at.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
  );
  final still = Motion.reduced(context);
  return Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: still ? Motion.out : Motion.pageIn,
    reverseTransitionDuration: still ? Motion.out : Motion.pageBack,
    pageBuilder: (_, __, ___) => NewsStoryScreen(
        item: item,
        onListen: onListen,
        now: now,
        heroTag: heroTag,
        previewWidth: previewWidth),
    transitionsBuilder: (context, animation, _, child) {
      final fade = CurvedAnimation(
        parent: animation,
        curve: Motion.easeFadeIn,
        reverseCurve: Motion.easeFadeOut,
      );
      if (still) return FadeTransition(opacity: fade, child: child);
      final grow = CurvedAnimation(
        parent: animation,
        curve: Motion.easeEnter,
        reverseCurve: Motion.easeExit.flipped,
      );
      return FadeTransition(
        opacity: fade,
        child: ScaleTransition(
          scale: Tween(begin: 0.9, end: 1.0).animate(grow),
          alignment: origin,
          // A snapshot while it grows, so the words are not drawn again at
          // every step (the motion rules in lib/design/motion.dart).
          filterQuality: FilterQuality.medium,
          child: child,
        ),
      );
    },
  ));
}

/// The whole story: the big picture, where it is from and when, the
/// headline, its summary and the extra snippets — and Listen, Open
/// article, Share.
class NewsStoryScreen extends StatelessWidget {
  const NewsStoryScreen(
      {super.key,
      required this.item,
      this.onListen,
      this.now,
      this.heroTag,
      this.previewWidth});

  final NewsItem item;

  /// The tag the card's picture flies in on ([newsHeroTag]); none from a
  /// plain push.
  final Object? heroTag;

  /// The card's decoded width, drawn under the full picture while it loads.
  final int? previewWidth;

  /// Listen. Default: the assistant reads the story out and explains it.
  final ValueChanged<NewsItem>? onListen;

  final DateTime? now;

  Future<void> _listen(BuildContext context) async {
    final listen = onListen;
    if (listen != null) {
      listen(item);
      return;
    }
    try {
      // The turn runs until the reading ends, so the note goes up as it
      // starts; a failure replaces it.
      final turn = AssistantEngine.instance.askAssistant(listenRequest(item));
      AppFeedback.toast('Reading it out…', tone: FeedbackTone.progress);
      await turn;
    } catch (e) {
      AppLog.add('news', 'listen failed: $e');
      AppFeedback.toast("Couldn't read that out. Try again.",
          tone: FeedbackTone.error);
    }
  }

  Future<void> _share() async {
    try {
      await Share.share(
        item.url.isNotEmpty ? '${item.title}\n${item.url}' : item.title,
        subject: item.title,
      );
    } catch (e) {
      AppLog.add('news', 'share failed: $e');
      AppFeedback.toast("Couldn't share that.", tone: FeedbackTone.error);
    }
  }

  Future<void> _openArticle() async {
    final uri = Uri.tryParse(item.url);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    if (!ok) AppFeedback.toast("Couldn't open the article.");
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final meta = [item.source, item.ageLabel(now)].where((s) => s.isNotEmpty).join(' · ');
    final body = [item.snippet, ...item.extra].where((s) => s.isNotEmpty).toList();
    final canOpen = item.url.isNotEmpty;
    final picture = NewsImage(
      item: item,
      cacheWidth: (width * media.devicePixelRatio).round(),
      previewWidth: previewWidth,
    );
    final tag = heroTag;
    // 2026-09-30: under the app's sky, the words on the night ground.
    return NeonScaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (tag == null)
                    picture
                  else
                    Hero(
                      tag: tag,
                      flightShuttleBuilder: newsPictureFlight,
                      child: picture,
                    ),
                  // A soft shade under the status bar so the back button
                  // reads on any picture: the night ground, not grey-black.
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.center,
                          colors: [
                            Neon.bg.withValues(alpha: 0.55),
                            Neon.bg.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SafeArea(
                    bottom: false,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: IconButton(
                          tooltip: 'Back',
                          onPressed: () => Navigator.of(context).maybePop(),
                          style: IconButton.styleFrom(
                            backgroundColor: Neon.bg.withValues(alpha: 0.55),
                            side: BorderSide(color: Neon.lineBright),
                          ),
                          icon: Icon(Icons.arrow_back_rounded,
                              color: Neon.textHi),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    NewsFavicon(item: item, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NeonType.manrope(NeonType.footnote, FontWeight.w600)
                            .copyWith(color: Neon.textLo),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  item.title,
                  style: NeonType.manrope(NeonType.title2, FontWeight.w800)
                      .copyWith(color: Neon.textHi, height: 1.2, letterSpacing: -0.4),
                ),
                for (final p in body) ...[
                  const SizedBox(height: 14),
                  Text(
                    p,
                    style: NeonType.manrope(NeonType.rowTitle, FontWeight.w500)
                        .copyWith(color: Neon.textHi, height: 1.5),
                  ),
                ],
                if (body.isEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Tap Listen and I will read it to you, or open the article.',
                    style: NeonType.manrope(NeonType.body, FontWeight.w500)
                        .copyWith(color: Neon.textLo, height: 1.45),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Neon.bg,
            border: Border(top: BorderSide(color: Neon.lineBright)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ApplePrimaryButton(
                  label: 'Listen',
                  icon: Icons.graphic_eq_rounded,
                  onPressed: () => _listen(context),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _SecondaryButton(
                        label: 'Open article',
                        icon: Icons.open_in_new_rounded,
                        onPressed: canOpen ? _openArticle : null,
                        tooltip: canOpen ? null : 'No link for this story',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SecondaryButton(
                        label: 'Share',
                        icon: Icons.ios_share_rounded,
                        onPressed: _share,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton(
      {required this.label,
      required this.icon,
      this.onPressed,
      this.tooltip});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Said on long-press; for a button that is off, why.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Neon.textHi,
        minimumSize: const Size.fromHeight(48),
        side: BorderSide(color: Neon.lineBright),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: NeonType.manrope(NeonType.body, FontWeight.w600),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
