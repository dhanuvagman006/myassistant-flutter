import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/neon_tokens.dart';
import '../services/api_service.dart';

/// ─────────────────────────────────────────────────────────────────────────
///  UPDATES TAB — all the news, out of the home screen's way.
///
///  Home is for the user's OWN life (agenda, promises, calendar); the
///  world's headlines live here. Tap any story to read it in the browser.
/// ─────────────────────────────────────────────────────────────────────────
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _Story {
  final String title;
  final String source;
  final String link;
  const _Story(this.title, this.source, this.link);
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  List<_Story> _stories = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final j = await ApiService.getJson('/tools/news?max=20');
    if (!mounted) return;
    final list = ((j?['headlines'] as List?) ?? const [])
        .whereType<Map>()
        .map((h) => _Story(
              (h['title'] as String?) ?? '',
              (h['source'] as String?) ?? '',
              (h['link'] as String?) ?? '',
            ))
        .where((s) => s.title.isNotEmpty)
        .toList();
    setState(() {
      _stories = list;
      _loading = false;
      _failed = j == null;
    });
  }

  Future<void> _open(_Story s) async {
    final uri = s.link.isNotEmpty
        ? Uri.tryParse(s.link)
        : Uri.parse(
            'https://news.google.com/search?q=${Uri.encodeComponent(s.title)}');
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: Neon.textHi,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 120),
          children: [
            Text('Updates',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 27,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: Neon.textHi,
                )),
            const SizedBox(height: 4),
            Text('The headlines, while you were busy.',
                style: TextStyle(color: Neon.textLo, fontSize: 13.5)),
            const SizedBox(height: 18),
            if (_loading)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Neon.textLo)),
              )
            else if (_stories.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Center(
                  child: Text(
                    _failed
                        ? 'Couldn\'t load the news. Pull down to retry.'
                        : 'No headlines right now. Pull down to refresh.',
                    style:
                        TextStyle(color: Neon.textDim, fontSize: 13.5),
                  ),
                ),
              )
            else
              for (final s in _stories) _storyTile(s),
          ],
        ),
      ),
    );
  }

  Widget _storyTile(_Story s) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: InkWell(
          onTap: () => _open(s),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Neon.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Neon.line),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title,
                    style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        height: 1.35)),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.source.isEmpty ? 'News' : s.source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Neon.textDim, fontSize: 12),
                      ),
                    ),
                    Icon(Icons.open_in_new_rounded,
                        size: 14, color: Neon.textDim),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
