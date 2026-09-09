import 'package:flutter/material.dart';

import '../design/apple_kit.dart';
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
      backgroundColor: Neon.bg,
      appBar: appleAppBar(context, 'Market & Stocks Hub'),
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

    final invest = _data!['invest'] as List;
    final sell = _data!['sell'] as List;
    final news = _data!['news'] as List;
    final summary = _data!['summary'] as String?;
    final indices = (_data!['indices'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
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
            child: _card(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.insights_rounded,
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
        const GroupLabel('Top Picks to Invest (Buy)'),
        ...invest.map((e) => _stockCard(e, true)),
        const SizedBox(height: 24),
        const GroupLabel('Stocks to Sell or Avoid'),
        ...sell.map((e) => _stockCard(e, false)),
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
                  e['symbol'],
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
                    e['reason'],
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

  Widget _indexChip(Map i) {
    final change = (i['change'] ?? '') as String;
    final up = !change.startsWith('-');
    final color = up ? AppleColors.green : AppleColors.red;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(i['name'] ?? '',
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
              e['headline'],
              style: TextStyle(color: Neon.textHi, fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  e['source'],
                  style: const TextStyle(color: AppleColors.blue, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  e['time'],
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
