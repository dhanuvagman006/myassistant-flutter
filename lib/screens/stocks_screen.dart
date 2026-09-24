import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';

class StocksScreen extends StatefulWidget {
  const StocksScreen({super.key, this.loader = ApiService.fetchStocks});

  /// Where the data comes from — the server, or a test's own map.
  final Future<Map<String, dynamic>> Function() loader;

  @override
  State<StocksScreen> createState() => _StocksScreenState();
}

class _StocksScreenState extends State<StocksScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await widget.loader();
      if (mounted) setState(() => _data = res);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load market data.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Markets'),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_error != null) {
      return NeonErrorState(
        message: _error!,
        onRetry: () {
          setState(() {
            _error = null;
            _data = null;
          });
          _load();
        },
      );
    }
    if (_data == null) return const Center(child: NeonLoader());

    // Tolerant reads: a field the server leaves out means an empty section,
    // not a red crash screen (these were hard `as List` / `as String` casts).
    List<Map> maps(String key) =>
        ((_data![key] as List?) ?? const []).whereType<Map>().toList();
    final invest = maps('invest');
    final sell = maps('sell');
    final news = maps('news');
    final summary = _data!['summary']?.toString();
    final indices = maps('indices');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        // NOT ADVICE. This screen used to head its lists "Top Picks to
        // Invest (Buy)" and "Stocks to Sell" with no qualification — a
        // recommendation, to Indian retail users, from something that is
        // not a SEBI-registered adviser.
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _card(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: Neon.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'For information only — not investment advice. This app is not a '
                    'SEBI-registered adviser, and prices may be delayed. Do your own '
                    'research or consult a registered adviser before you invest.',
                    style: TextStyle(color: Neon.textLo, fontSize: 12.5, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (indices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                for (final i in indices.take(2)) ...[
                  Expanded(child: _indexChip(i)),
                  const SizedBox(width: 10),
                ],
              ]..removeLast(),
            ),
          ),
        if (summary != null && summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.insights_rounded,
                      size: 18, color: AppleColors.blue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      summary,
                      style: TextStyle(
                          color: Neon.textHi, fontSize: 13.5, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (invest.isNotEmpty) ...[
          const GroupLabel('Gaining momentum'),
          ...invest.map((e) => _stockCard(e, true)),
          const SizedBox(height: 24),
        ],
        if (sell.isNotEmpty) ...[
          const GroupLabel('Losing momentum'),
          ...sell.map((e) => _stockCard(e, false)),
          const SizedBox(height: 24),
        ],
        const SizedBox(height: 24),
        const GroupLabel('Important Market News'),
        ...news.map((e) => _newsCard(e)),
      ],
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Neon.line),
        ),
        child: child,
      );

  Widget _stockCard(Map e, bool isBuy) {
    final color = isBuy ? AppleColors.green : AppleColors.red;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _s(e, 'symbol'),
                  style: TextStyle(
                      color: Neon.textHi, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _s(e, 'change'),
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              e['price'] != null
                  ? "${_s(e, 'name')} · ₹${e['price']}"
                  : _s(e, 'name'),
              style: TextStyle(color: Neon.textLo, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(isBuy ? Icons.trending_up : Icons.trending_down, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _s(e, 'reason'),
                    style: TextStyle(color: Neon.textHi, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A field as text, whatever the server sent (or didn't).
  static String _s(Map e, String key) => (e[key] ?? '').toString();

  Widget _indexChip(Map i) {
    final change = _s(i, 'change');
    final up = !change.startsWith('-');
    final color = up ? AppleColors.green : AppleColors.red;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(i, 'name'),
              style: TextStyle(color: Neon.textDim, fontSize: 11.5)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${i['price'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: Neon.textHi,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
              ),
              Text(change,
                  style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _newsCard(Map e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _s(e, 'headline'),
              style: TextStyle(color: Neon.textHi, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  _s(e, 'source'),
                  style: TextStyle(color: AppleColors.blue, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  _s(e, 'time'),
                  style: TextStyle(color: Neon.textDim, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
