import 'package:flutter/material.dart';
import '../design/neon_tokens.dart';
import '../design/neon_widgets.dart';
import '../services/api_service.dart';

class StocksScreen extends StatefulWidget {
  const StocksScreen({super.key});

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
      final res = await ApiService.fetchStocks();
      if (mounted) setState(() => _data = res);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load market data.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackdrop(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Neon.textHi),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Text(
                      'Market & Stocks Hub',
                      style: TextStyle(
                        color: Neon.textHi,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _body(),
              ),
            ],
          ),
        ),
      ),
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

    final invest = _data!['invest'] as List;
    final sell = _data!['sell'] as List;
    final news = _data!['news'] as List;
    final summary = _data!['summary'] as String?;
    final indices = (_data!['indices'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: [
        if (indices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                for (final i in indices.take(2)) ...[
                  Expanded(child: _indexChip(i as Map)),
                  const SizedBox(width: 10),
                ],
              ]..removeLast(),
            ),
          ),
        if (summary != null && summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: GlassCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.insights_rounded,
                      size: 18, color: Neon.cyan),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      summary,
                      style: const TextStyle(
                          color: Neon.textHi, fontSize: 13.5, height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SectionHeader('Top Picks to Invest (Buy)'),
        ...invest.map((e) => _stockCard(e, true)),
        const SizedBox(height: 12),
        const SectionHeader('Stocks to Sell or Avoid'),
        ...sell.map((e) => _stockCard(e, false)),
        const SizedBox(height: 12),
        const SectionHeader('Important Market News'),
        ...news.map((e) => _newsCard(e)),
      ],
    );
  }

  Widget _stockCard(Map e, bool isBuy) {
    final color = isBuy ? const Color(0xFF35C48D) : Neon.pink;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        borderGradient: LinearGradient(colors: [color.withValues(alpha: 0.5), color.withValues(alpha: 0.1)]),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  e['symbol'],
                  style: const TextStyle(
                      color: Neon.textHi, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    e['change'],
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              e['price'] != null
                  ? "${e['name']} · ₹${e['price']}"
                  : e['name'],
              style: const TextStyle(color: Neon.textLo, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(isBuy ? Icons.trending_up : Icons.trending_down, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    e['reason'],
                    style: const TextStyle(color: Neon.textHi, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _indexChip(Map i) {
    final change = (i['change'] ?? '') as String;
    final up = !change.startsWith('-');
    final color = up ? const Color(0xFF35C48D) : Neon.pink;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(i['name'] ?? '',
              style: const TextStyle(color: Neon.textDim, fontSize: 11.5)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${i['price'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
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
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              e['headline'],
              style: const TextStyle(color: Neon.textHi, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  e['source'],
                  style: const TextStyle(color: Neon.cyan, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  e['time'],
                  style: const TextStyle(color: Neon.textDim, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader(this.title, {super.key});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 8),
      child: Text(
        title,
        style: const TextStyle(
            color: Neon.textDim, fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5),
      ),
    );
  }
}
