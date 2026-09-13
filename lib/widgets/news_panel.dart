import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../design/neon_tokens.dart';
import '../features/assistant/state/assistant_engine.dart';
import '../models/news_item.dart';

/// TODAY'S HEADLINES, ON SCREEN.
///
/// Ten headlines read aloud takes over a minute and nobody remembers the
/// fourth. So the list goes here, scrollable, while the assistant says one
/// line and covers the top two or three — the panel is the answer, the
/// narration is a summary of it.
///
/// Tapping a headline expands it and asks the assistant to read that
/// story. That goes through the ordinary turn pipeline (read_webpage),
/// which means the article lands in the conversation history and any
/// follow-up question about it just works, with nothing special wired up.
class NewsPanel extends StatefulWidget {
  const NewsPanel({super.key});

  @override
  State<NewsPanel> createState() => _NewsPanelState();
}

class _NewsPanelState extends State<NewsPanel> {
  final engine = AssistantEngine.instance;
  int? _open; // which headline is expanded

  @override
  void initState() {
    super.initState();
    engine.addListener(_sync);
  }

  @override
  void dispose() {
    engine.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    // A fresh set of headlines collapses whatever was open — the index
    // it referred to belongs to the old list.
    if (engine.newsItems.isEmpty) _open = null;
    setState(() {});
  }

  void _close() {
    engine.clearNews();
    setState(() => _open = null);
  }

  void _tap(int i, NewsItem item) {
    setState(() => _open = _open == i ? null : i);
    if (_open != i || item.url.isEmpty) return;
    // The assistant reads it. Phrased as a request rather than a command
    // so the model reaches for read_webpage and answers naturally; the
    // URL is what makes it read THIS story rather than search for it.
    engine.askAssistant(
      'Read me this news story and tell me what it says: '
      '"${item.title}" — ${item.url}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = engine.newsItems;
    if (items.isEmpty) return const SizedBox.shrink();
    final media = MediaQuery.of(context);

    return Positioned.fill(
      child: Stack(
        children: [
          // Tap anywhere outside to dismiss — the panel is an answer, not
          // a task, and should never trap anyone.
          GestureDetector(
            onTap: _close,
            child: Container(color: Colors.black.withValues(alpha: 0.55)),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              constraints: BoxConstraints(
                maxHeight: media.size.height * 0.78,
              ),
              decoration: BoxDecoration(
                color: Neon.bg,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
                border: Border.all(color: Neon.line),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(items.length),
                  Flexible(
                    child: ListView.separated(
                      padding: EdgeInsets.fromLTRB(
                          16, 4, 16, 16 + media.padding.bottom),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 18,
                        thickness: 1,
                        color: Neon.line,
                      ),
                      itemBuilder: (_, i) => _row(i, items[i]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(int n) {
    final topic = engine.newsTopic;
    final title = topic.isEmpty || topic == 'today'
        ? "Today's headlines"
        : 'News · $topic';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
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
              style: GoogleFonts.spaceGrotesk(
                color: Neon.textHi,
                fontSize: 19,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ),
          Text(
            '$n stories',
            style: GoogleFonts.spaceGrotesk(
              color: Neon.textDim,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
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

  Widget _row(int i, NewsItem item) {
    final open = _open == i;
    return InkWell(
      onTap: () => _tap(i, item),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The number is the only ordering signal a reader gets
                // once they are scrolling, and it matches what was said.
                SizedBox(
                  width: 24,
                  child: Text(
                    '${i + 1}',
                    style: GoogleFonts.spaceGrotesk(
                      color: open ? Neon.pink : Neon.textDim,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    item.title,
                    style: GoogleFonts.spaceGrotesk(
                      color: Neon.textHi,
                      fontSize: 15.5,
                      height: 1.32,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
                Icon(
                  open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 20,
                  color: Neon.textDim,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Text(
                [item.source, item.age].where((s) => s.isNotEmpty).join(' · '),
                style: GoogleFonts.spaceGrotesk(
                  color: Neon.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (open) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 4),
                child: Text(
                  [item.snippet, ...item.extra]
                      .where((s) => s.isNotEmpty)
                      .join(' '),
                  style: GoogleFonts.spaceGrotesk(
                    color: Neon.textLo,
                    fontSize: 13.5,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq_rounded, size: 15, color: Neon.pink),
                    const SizedBox(width: 6),
                    Text(
                      'Reading this out — ask me anything about it',
                      style: GoogleFonts.spaceGrotesk(
                        color: Neon.pink,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
